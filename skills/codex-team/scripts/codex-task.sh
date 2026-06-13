#!/usr/bin/env bash
# codex-task.sh — orchestrator dispatch wrapper for OpenAI Codex CLI workers
# Usage: codex-task.sh <subcommand> [args...]
set -euo pipefail

CODEX_BIN="${CODEX_BIN:-/Applications/Codex.app/Contents/Resources/codex}"
RUNS_BASE="${RUNS_BASE:-$HOME/.claude/codex-team/runs}"

STALL_TIMEOUT="${CODEX_STALL_TIMEOUT:-900}"  # seconds with no new events.jsonl output => stuck, kill
STALL_POLL=30
AUTO_RESUME="${CODEX_AUTO_RESUME:-1}"        # auto-resume attempts after a stall kill (0 disables)

# Anti-hang config, per-invocation only — NEVER edit ~/.codex/config.toml globally
# (notify/SkyComputerUseClient is needed by the desktop app; only headless runs override it):
# - notify=[]: SkyComputerUseClient orphans (openai/codex#26293) keep headless exec from exiting
# - stream idle/retries: a stalled SSE otherwise holds the process 5min x 5 retries silently
# - figma MCP off: remote HTTP server with no startup timeout = unbounded startup hang
# - startup_timeout caps: node_repl stays enabled (S1 numeric work) but 120s -> 30s
ANTI_HANG_ARGS=(
  # model_verbosity=low: API-level cut of narrative/reassurance filler in reports
  # (binary-verified key; ignored gracefully if the model lacks verbosity support)
  -c 'model_verbosity="low"'
  -c 'notify=[]'
  -c 'stream_idle_timeout_ms=60000'
  -c 'stream_max_retries=3'
  -c 'mcp_servers.figma.enabled=false'
  -c 'mcp_servers.node_repl.startup_timeout_sec=30'
  -c 'mcp_servers.codegraph.startup_timeout_sec=15'
)

die() { echo "ERROR: $*" >&2; exit 1; }

usage() {
  cat <<'EOF'
Usage: codex-task.sh <subcommand> [args...]

Subcommands:
  new <slug> --repo <root> [--base <ref>] [--model <m>] [--effort low|medium|high|xhigh] [--net] [--search] [--sandbox <mode>] --prompt-file <f> [--order <order.json>]
  preflight --repo <root> [--cap N] <order.json> [<order.json>...]
  resume <slug> --prompt-file <f>
  review <slug>
  merge-next --repo <root>
  violations [<slug>]
  status <slug>
  diff <slug> [--since-review]
  clean [--force] <slug>
  list

preflight checks schema, capacity (default 2, max 3), batch-internal footprint overlap,
in-flight footprint overlap, and depends_on state. Batch overlap is approximate:
patterns overlap when equal after stripping glob suffixes, or when one stripped
pattern is a directory prefix of the other.
EOF
}

require_slug() {
  [[ -n "${1:-}" ]] || die "slug required"
  echo "$1"
}

runs_dir() { echo "$RUNS_BASE/$1"; }
meta_file() { echo "$RUNS_BASE/$1/meta.json"; }

sha256_file() {
  python3 - "$1" <<'PY'
import hashlib
import sys

path = sys.argv[1]
h = hashlib.sha256()
with open(path, "rb") as f:
    for chunk in iter(lambda: f.read(1024 * 1024), b""):
        h.update(chunk)
print(h.hexdigest())
PY
}

read_meta_field() {
  local slug="$1" field="$2"
  python3 - "$(meta_file "$slug")" "$field" <<'PY'
import json
import sys

path, field = sys.argv[1], sys.argv[2]
with open(path, encoding="utf-8") as f:
    data = json.load(f)
value = data.get(field, "")
if value is None:
    value = ""
if isinstance(value, (dict, list)):
    print(json.dumps(value, separators=(",", ":")))
else:
    print(value)
PY
}

# Extract thread id from events.jsonl: jq fast path, grep/sed fallback
extract_thread_id() {
  local events_file="$1"
  local tid=""
  if command -v jq &>/dev/null; then
    tid=$(jq -r 'select(.type=="thread.started") | .id // .thread_id // empty' "$events_file" 2>/dev/null | head -1)
  fi
  if [[ -z "$tid" ]]; then
    # grep fallback: {"type":"thread.started",...,"id":"<id>",...}
    tid=$(grep -m1 '"thread\.started"' "$events_file" 2>/dev/null \
      | sed -E 's/.*"id"\s*:\s*"([^"]+)".*/\1/' || true)
  fi
  echo "$tid"
}

update_meta() {
  local meta="$1"; shift
  local tmp; tmp=$(mktemp)
  jq "$@" "$meta" > "$tmp" && mv "$tmp" "$meta"
}

# Run one codex invocation under a stall watchdog.
# Args: <runs_dir> <workdir> <argv...>. Sets WD_EXIT, WD_STUCK (1 = killed for stalling).
run_with_watchdog() {
  local runs="$1" workdir="$2"; shift 2
  WD_EXIT=0; WD_STUCK=0
  ( cd "$workdir" && exec "$@" ) \
    >> "$runs/events.jsonl" 2>> "$runs/stderr.log" </dev/null &
  local pid=$!
  update_meta "$runs/meta.json" --argjson pid "$pid" '.pid=$pid'
  while kill -0 "$pid" 2>/dev/null; do
    sleep "$STALL_POLL"
    local now mtime age
    now=$(date +%s)
    mtime=$(stat -f %m "$runs/events.jsonl" 2>/dev/null || echo "$now")
    age=$(( now - mtime ))
    if (( age >= STALL_TIMEOUT )); then
      WD_STUCK=1
      echo "WATCHDOG: no output for ${age}s (limit ${STALL_TIMEOUT}s) — killing pid $pid" >> "$runs/stderr.log"
      kill -TERM "$pid" 2>/dev/null || true
      sleep 5
      kill -KILL "$pid" 2>/dev/null || true
      break
    fi
  done
  wait "$pid" 2>/dev/null && WD_EXIT=0 || WD_EXIT=$?
}

# Watchdog + auto-resume-on-stall loop. Sets RC_EXIT, RC_STUCK, RC_RESTARTS.
run_codex_task() {
  local runs="$1" workdir="$2"; shift 2
  run_with_watchdog "$runs" "$workdir" "$@"
  RC_EXIT=$WD_EXIT; RC_STUCK=$WD_STUCK; RC_RESTARTS=0
  while [[ $RC_STUCK -eq 1 && $RC_RESTARTS -lt $AUTO_RESUME ]]; do
    RC_RESTARTS=$((RC_RESTARTS + 1))
    local tid; tid=$(extract_thread_id "$runs/events.jsonl")
    [[ -n "$tid" ]] || break  # no thread yet (stalled during startup) — nothing to resume
    echo "WATCHDOG: auto-resume attempt $RC_RESTARTS/$AUTO_RESUME thread=$tid" >> "$runs/stderr.log"
    run_with_watchdog "$runs" "$workdir" "$CODEX_BIN" exec resume "$tid" \
      -c 'approval_policy="never"' --json -o "$runs/last.md" --skip-git-repo-check \
      "${ANTI_HANG_ARGS[@]}" \
      "WATCHDOG RESTART: your previous run was killed after ${STALL_TIMEOUT}s with no output (stall). Re-read your order, continue from the last completed step, and finish. If genuinely blocked, STOP and write the S5 surface report instead of stalling."
    RC_EXIT=$WD_EXIT; RC_STUCK=$WD_STUCK
  done
}

# Self-heal zombie metas: status "running" but the recorded pid is gone => "died".
heal_meta() {
  local meta="$1"
  [[ -f "$meta" ]] || return 0
  local st pid
  st=$(python3 - "$meta" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as f:
    print(json.load(f).get("status", "") or "")
PY
)
  [[ "$st" == "running" ]] || return 0
  pid=$(python3 - "$meta" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as f:
    value = json.load(f).get("pid", "")
print("" if value is None else value)
PY
)
  if [[ -z "$pid" || "$pid" == "null" ]] || ! kill -0 "$pid" 2>/dev/null; then
    python3 - "$meta" <<'PY'
import json
import os
import sys

path = sys.argv[1]
with open(path, encoding="utf-8") as f:
    data = json.load(f)
data["status"] = "died"
data["pid"] = None
tmp = "%s.tmp.%s" % (path, os.getpid())
with open(tmp, "w", encoding="utf-8") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
os.replace(tmp, path)
PY
  fi
}

meta_file_field() {
  local meta="$1" field="$2"
  python3 - "$meta" "$field" <<'PY'
import json
import sys

path, field = sys.argv[1], sys.argv[2]
with open(path, encoding="utf-8") as f:
    data = json.load(f)
value = data.get(field, "")
if value is None:
    value = ""
print(value)
PY
}

order_validate() {
  python3 - "$@" <<'PY'
import json
import os
import sys

def validate(path):
    errors = []
    if not os.path.isfile(path):
        return ["%s: file not found" % path]
    try:
        with open(path, encoding="utf-8") as f:
            data = json.load(f)
    except json.JSONDecodeError as exc:
        return ["%s: invalid JSON at line %s column %s: %s" % (path, exc.lineno, exc.colno, exc.msg)]
    except OSError as exc:
        return ["%s: %s" % (path, exc)]

    if not isinstance(data, dict):
        return ["%s: root must be a JSON object" % path]

    for key in ("slug", "acceptance"):
        if not isinstance(data.get(key), str) or not data.get(key).strip():
            errors.append("%s: %s must be a non-empty string" % (path, key))

    allowed = data.get("allowed_paths")
    if not isinstance(allowed, list) or not allowed:
        errors.append("%s: allowed_paths must be a non-empty array" % path)
    elif any(not isinstance(item, str) or not item.strip() for item in allowed):
        errors.append("%s: allowed_paths entries must be non-empty strings" % path)

    for key in ("depends_on", "forbidden_paths"):
        value = data.get(key, [])
        if value is None:
            value = []
        if not isinstance(value, list):
            errors.append("%s: %s must be an array when present" % (path, key))
        elif any(not isinstance(item, str) or not item.strip() for item in value):
            errors.append("%s: %s entries must be non-empty strings" % (path, key))

    return errors

all_errors = []
for path in sys.argv[1:]:
    all_errors.extend(validate(path))

if all_errors:
    for error in all_errors:
        print("SCHEMA FAIL %s" % error)
    sys.exit(1)
PY
}

order_prompt_line() {
  python3 - "$1" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as f:
    data = json.load(f)
allowed = data["allowed_paths"]
forbidden = data.get("forbidden_paths") or []
print("Allowed paths: %s. Forbidden: %s. Changes outside allowed paths will be rejected at review." % (
    ", ".join(allowed),
    ", ".join(forbidden) if forbidden else "none",
))
PY
}

order_batch_overlap() {
  python3 - "$@" <<'PY'
import json
import sys

def load(path):
    with open(path, encoding="utf-8") as f:
        data = json.load(f)
    return {
        "path": path,
        "slug": data["slug"],
        "allowed": data["allowed_paths"],
    }

def strip_glob_suffix(pattern):
    pattern = pattern.replace("\\", "/")
    while pattern.startswith("./"):
        pattern = pattern[2:]
    specials = [i for i, ch in enumerate(pattern) if ch in "*?["]
    if not specials:
        return pattern.rstrip("/")
    return pattern[:min(specials)].rstrip("/")

def approximate_overlap(left, right):
    a = strip_glob_suffix(left)
    b = strip_glob_suffix(right)
    if a == b:
        return True
    if not a or not b:
        return True
    return a.startswith(b + "/") or b.startswith(a + "/")

orders = [load(path) for path in sys.argv[1:]]
hits = []
for i in range(len(orders)):
    for j in range(i + 1, len(orders)):
        for left in orders[i]["allowed"]:
            for right in orders[j]["allowed"]:
                if approximate_overlap(left, right):
                    hits.append((orders[i]["slug"], left, orders[j]["slug"], right))

if hits:
    for a_slug, a_pat, b_slug, b_pat in hits:
        print("BATCH-OVERLAP %s:%s %s:%s" % (a_slug, a_pat, b_slug, b_pat))
    sys.exit(1)
PY
}

order_inflight_match() {
  # The heredoc below delivers the PROGRAM on stdin, so the script must run from a
  # temp file: otherwise `for raw in sys.stdin` reads the (already-consumed) heredoc
  # instead of the piped change list, and the overlap check silently passes everything.
  local _prog _rc
  _prog=$(mktemp)
  cat >"$_prog" <<'PY'
import fnmatch
import json
import sys

def norm(value):
    value = value.replace("\\", "/")
    while value.startswith("./"):
        value = value[2:]
    return value

def norm_pattern(value):
    value = norm(value)
    while "**" in value:
        value = value.replace("**", "*")
    return value

def matches(path, pattern):
    return fnmatch.fnmatchcase(norm(path), norm_pattern(pattern))

orders = []
for path in sys.argv[1:]:
    with open(path, encoding="utf-8") as f:
        data = json.load(f)
    orders.append((data["slug"], data["allowed_paths"]))

hits = []
for raw in sys.stdin:
    raw = raw.rstrip("\n")
    if not raw:
        continue
    branch, changed = raw.split("\t", 1)
    for slug, patterns in orders:
        for pattern in patterns:
            if matches(changed, pattern):
                hits.append((slug, pattern, branch, changed))

if hits:
    for slug, pattern, branch, changed in hits:
        print("IN-FLIGHT-OVERLAP %s:%s conflicts-with %s:%s" % (slug, pattern, branch, changed))
    sys.exit(1)
PY
  python3 "$_prog" "$@"
  _rc=$?
  rm -f "$_prog"
  return $_rc
}

order_dep_pairs() {
  python3 - "$@" <<'PY'
import json
import sys

for path in sys.argv[1:]:
    with open(path, encoding="utf-8") as f:
        data = json.load(f)
    for dep in data.get("depends_on") or []:
        print("%s\t%s" % (data["slug"], dep))
PY
}

order_dep_list() {
  python3 - "$1" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as f:
    data = json.load(f)
for dep in data.get("depends_on") or []:
    print(dep)
PY
}

order_review_footprint() {
  # Same heredoc-vs-stdin hazard as order_inflight_match: run the program from a temp
  # file so the diff list piped on stdin reaches `for raw in sys.stdin`.
  local _prog _rc
  _prog=$(mktemp)
  cat >"$_prog" <<'PY'
import fnmatch
import json
import sys

def norm(value):
    value = value.replace("\\", "/")
    while value.startswith("./"):
        value = value[2:]
    return value

def norm_pattern(value):
    value = norm(value)
    while "**" in value:
        value = value.replace("**", "*")
    return value

def matches(path, pattern):
    return fnmatch.fnmatchcase(norm(path), norm_pattern(pattern))

with open(sys.argv[1], encoding="utf-8") as f:
    data = json.load(f)
allowed = data["allowed_paths"]
forbidden = data.get("forbidden_paths") or []

for raw in sys.stdin:
    path = raw.strip()
    if not path:
        continue
    allowed_hit = any(matches(path, pattern) for pattern in allowed)
    forbidden_hit = any(matches(path, pattern) for pattern in forbidden)
    if not allowed_hit or forbidden_hit:
        print("OUT-OF-FOOTPRINT %s" % path)
PY
  python3 "$_prog" "$1"
  _rc=$?
  rm -f "$_prog"
  return $_rc
}

record_review_violations() {
  local slug="$1" findings="$2"
  [[ -s "$findings" ]] || return 0
  local runs ledger ts line detail
  runs=$(runs_dir "$slug")
  ledger="$runs/violations.jsonl"
  ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  while IFS= read -r line; do
    case "$line" in
      OUT-OF-FOOTPRINT\ *)
        detail="${line#OUT-OF-FOOTPRINT }"
        python3 - "$ts" "$slug" "$detail" >> "$ledger" <<'PY'
import json
import sys

ts, slug, detail = sys.argv[1:4]
print(json.dumps({
    "ts": ts,
    "slug": slug,
    "rule": "OUT-OF-FOOTPRINT",
    "detail": detail,
}, separators=(",", ":")))
PY
        ;;
    esac
  done < "$findings"
}

count_running_runs() {
  local running=0 meta st
  for meta in "$RUNS_BASE"/*/meta.json; do
    [[ -f "$meta" ]] || continue
    heal_meta "$meta"
    st=$(meta_file_field "$meta" status)
    if [[ "$st" == "running" ]]; then
      running=$((running + 1))
    fi
  done
  echo "$running"
}

detect_primary_branch() {
  local repo="$1"
  if git -C "$repo" show-ref --verify --quiet refs/heads/main; then
    echo "main"
  elif git -C "$repo" show-ref --verify --quiet refs/heads/master; then
    echo "master"
  else
    die "repo has neither main nor master branch: $repo"
  fi
}

collect_inflight_changes() {
  local repo="$1" primary="$2"
  local line branch mb ahead file
  while IFS= read -r line; do
    case "$line" in
      branch\ refs/heads/*)
        branch="${line#branch refs/heads/}"
        mb=$(git -C "$repo" merge-base "$primary" "$branch")
        ahead=$(git -C "$repo" rev-list --count "$mb..$branch")
        if (( ahead > 0 )); then
          while IFS= read -r file; do
            [[ -n "$file" ]] || continue
            printf '%s\t%s\n' "$branch" "$file"
          done < <(git -C "$repo" diff --name-only "$mb...$branch")
        fi
        ;;
    esac
  done < <(git -C "$repo" worktree list --porcelain)
}

dep_satisfied() {
  local dep="$1"
  local meta="$RUNS_BASE/$dep/meta.json"
  [[ -f "$meta" ]] || return 1
  heal_meta "$meta"

  local st repo branch primary
  st=$(meta_file_field "$meta" status)
  [[ "$st" == "cleaned" || "$st" == "merged" ]] && return 0

  repo=$(meta_file_field "$meta" repo)
  branch=$(meta_file_field "$meta" branch)
  [[ -n "$repo" && -n "$branch" ]] || return 1

  if primary=$(detect_primary_branch "$repo" 2>/dev/null); then
    git -C "$repo" merge-base --is-ancestor "$branch" "$primary" 2>/dev/null && return 0
  fi
  git -C "$repo" merge-base --is-ancestor "$branch" HEAD 2>/dev/null && return 0
  return 1
}

##############################################################################
# new
##############################################################################
cmd_new() {
  local slug="" repo="" base="HEAD" model="" effort="" net=0 sandbox="workspace-write" prompt_file="" order_file=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --repo)      repo="$2";        shift 2 ;;
      --base)      base="$2";        shift 2 ;;
      --model)     model="$2";       shift 2 ;;
      --effort)    effort="$2";      shift 2 ;;
      --net)       net=1;            shift   ;;
      --search)    search=1;         shift   ;;
      --sandbox)   sandbox="$2";     shift 2 ;;
      --prompt-file) prompt_file="$2"; shift 2 ;;
      --order)     order_file="$2";  shift 2 ;;
      *)
        if [[ -z "$slug" ]]; then slug="$1"; shift
        else die "unknown arg: $1"; fi ;;
    esac
  done

  [[ -n "$slug" ]]        || die "slug required"
  [[ -n "$repo" ]]        || die "--repo required"
  [[ -n "$prompt_file" ]] || die "--prompt-file required"
  [[ -f "$prompt_file" ]] || die "prompt file not found: $prompt_file"
  if [[ -n "$order_file" ]]; then
    [[ -f "$order_file" ]] || die "order file not found: $order_file"
    order_validate "$order_file" || exit 1
  fi

  local runs; runs=$(runs_dir "$slug")
  [[ ! -d "$runs" ]] || die "slug '$slug' already exists at $runs — use resume or choose a new slug"

  mkdir -p "$runs"
  cp "$prompt_file" "$runs/prompt.md"
  if [[ -n "$order_file" ]]; then
    cp "$order_file" "$runs/order.json"
    printf '\n\n%s\n' "$(order_prompt_line "$runs/order.json")" >> "$runs/prompt.md"
  fi
  # Auto-append standing orders (single doctrine source; update standing-orders.md, not prompts)
  local standing="$(dirname "${BASH_SOURCE[0]}")/../standing-orders.md"
  local standing_sha=""
  if [[ -f "$standing" ]]; then
    standing_sha=$(sha256_file "$standing")
    printf '\n\n' >> "$runs/prompt.md"
    cat "$standing" >> "$runs/prompt.md"
  fi

  # Resolve repo absolute path
  repo=$(cd "$repo" && pwd)

  # Create worktree on a fresh branch
  local worktree="$repo/.claude/worktrees/codex-$slug"
  local branch="codex/$slug"
  local base_sha
  base_sha=$(git -C "$repo" rev-parse "${base}")

  mkdir -p "$repo/.claude/worktrees"
  git -C "$repo" worktree add "$worktree" -b "$branch" "$base_sha"

  # Determine git common dir (critical for nested worktree git ops)
  local git_common_dir
  git_common_dir=$(git -C "$worktree" rev-parse --git-common-dir)
  # Make absolute if relative
  if [[ "$git_common_dir" != /* ]]; then
    git_common_dir="$(cd "$worktree" && cd "$git_common_dir" && pwd)"
  fi

  local started; started=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

  # Write initial meta
  cat > "$runs/meta.json" <<EOF
{
  "slug": "$slug",
  "repo": "$repo",
  "worktree": "$worktree",
  "branch": "$branch",
  "base_sha": "$base_sha",
  "thread_id": "",
  "started": "$started",
  "finished": "",
  "exit_code": null,
  "status": "running"
}
EOF
  if [[ -n "$standing_sha" ]]; then
    update_meta "$runs/meta.json" --arg sha "$standing_sha" '.standing_orders_sha=$sha'
  fi

  # Build codex exec command
  local prompt_text; prompt_text=$(cat "$runs/prompt.md")
  local codex_args=()
  codex_args+=(exec)
  codex_args+=(-C "$worktree")
  codex_args+=(-s "$sandbox")
  codex_args+=(-c 'approval_policy="never"')
  codex_args+=(--json)
  codex_args+=(-o "$runs/last.md")
  codex_args+=(--add-dir "$git_common_dir")
  codex_args+=(--skip-git-repo-check)
  codex_args+=("${ANTI_HANG_ARGS[@]}")
  [[ -n "$model" ]]  && codex_args+=(-m "$model")
  [[ -n "$effort" ]] && codex_args+=(-c "model_reasoning_effort=\"$effort\"")
  [[ $net -eq 1 ]]   && codex_args+=(-c "sandbox_workspace_write.network_access=true")
  [[ ${search:-0} -eq 1 ]] && codex_args+=(--search)

  touch "$runs/events.jsonl"

  run_codex_task "$runs" "$worktree" "$CODEX_BIN" "${codex_args[@]}" "$prompt_text"
  local exit_code=$RC_EXIT

  local finished; finished=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  local thread_id; thread_id=$(extract_thread_id "$runs/events.jsonl")
  local status="done"
  if [[ $RC_STUCK -eq 1 ]]; then status="stuck"
  elif [[ $exit_code -ne 0 ]]; then status="failed"; fi

  update_meta "$runs/meta.json" \
    --arg tid "$thread_id" \
    --arg fin "$finished" \
    --argjson ec "$exit_code" \
    --argjson rs "$RC_RESTARTS" \
    --arg st "$status" \
    '.thread_id=$tid | .finished=$fin | .exit_code=$ec | .status=$st | .restarts=$rs | .pid=null'

  echo "CODEX-TASK $slug status=$status exit=$exit_code restarts=$RC_RESTARTS thread=$thread_id worktree=$worktree last=$runs/last.md"
  exit $exit_code
}

##############################################################################
# preflight
##############################################################################
cmd_preflight() {
  local repo="" cap=2
  local orders=()

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --repo) repo="$2"; shift 2 ;;
      --cap)  cap="$2";  shift 2 ;;
      --help|-h) usage; return 0 ;;
      -*)
        die "unknown preflight arg: $1" ;;
      *)
        orders+=("$1"); shift ;;
    esac
  done

  [[ -n "$repo" ]] || die "preflight requires --repo <root>"
  [[ ${#orders[@]} -gt 0 ]] || die "preflight requires at least one order.json"
  [[ "$cap" =~ ^[0-9]+$ ]] || die "--cap must be an integer"
  (( cap >= 1 )) || die "--cap must be >= 1"
  (( cap <= 3 )) || die "--cap max is 3"

  repo=$(cd "$repo" && pwd)

  order_validate "${orders[@]}" || exit 1
  echo "SCHEMA OK (${#orders[@]} orders)"

  local running n
  running=$(count_running_runs)
  n=${#orders[@]}
  if (( running + n > cap )); then
    echo "CAPACITY FAIL running ${running}+${n}/${cap}"
    exit 1
  fi
  echo "CAPACITY OK (${running}+${n}/${cap})"

  order_batch_overlap "${orders[@]}" || exit 1
  echo "BATCH-INTERNAL OK"

  local primary changed_tmp
  primary=$(detect_primary_branch "$repo")
  changed_tmp=$(mktemp)
  collect_inflight_changes "$repo" "$primary" > "$changed_tmp"
  if ! order_inflight_match "${orders[@]}" < "$changed_tmp"; then
    rm -f "$changed_tmp"
    exit 1
  fi
  rm -f "$changed_tmp"
  echo "IN-FLIGHT OK"

  local dep_tmp blocked line order_slug dep
  dep_tmp=$(mktemp)
  order_dep_pairs "${orders[@]}" > "$dep_tmp"
  blocked=0
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    order_slug="${line%%	*}"
    dep="${line#*	}"
    if ! dep_satisfied "$dep"; then
      echo "BLOCKED $order_slug waits-for $dep"
      blocked=1
    fi
  done < "$dep_tmp"
  rm -f "$dep_tmp"
  if (( blocked != 0 )); then
    exit 1
  fi
  echo "DEPENDS OK"

  echo "PREFLIGHT OK (${n} orders, capacity ${running}+${n}/${cap})"
}

##############################################################################
# resume
##############################################################################
cmd_resume() {
  local slug="" prompt_file=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --prompt-file) prompt_file="$2"; shift 2 ;;
      *)
        if [[ -z "$slug" ]]; then slug="$1"; shift
        else die "unknown arg: $1"; fi ;;
    esac
  done

  [[ -n "$slug" ]]        || die "slug required"
  [[ -n "$prompt_file" ]] || die "--prompt-file required"
  [[ -f "$prompt_file" ]] || die "prompt file not found: $prompt_file"

  local runs; runs=$(runs_dir "$slug")
  [[ -d "$runs" ]] || die "no run found for slug '$slug'"

  local thread_id worktree sandbox
  thread_id=$(read_meta_field "$slug" thread_id)
  worktree=$(read_meta_field "$slug" worktree)
  sandbox=$(read_meta_field "$slug" status)  # re-read sandbox from meta if stored; fallback
  sandbox="workspace-write"  # default; could store in meta for full fidelity

  # meta.json only gets thread_id at completion; fall back to the live event stream
  [[ -n "$thread_id" ]] || thread_id=$(extract_thread_id "$runs/events.jsonl")
  [[ -n "$thread_id" ]] || die "thread_id not in meta.json nor events.jsonl — cannot resume"
  if [[ ! -d "$worktree" ]]; then
    # Self-heal: a cleaned task retains its branch — recreate the worktree from it
    local repo branch
    repo=$(read_meta_field "$slug" repo)
    branch=$(read_meta_field "$slug" branch)
    git -C "$repo" rev-parse --verify "refs/heads/$branch" >/dev/null 2>&1 \
      || die "worktree gone and branch $branch missing — cannot resume"
    mkdir -p "$(dirname "$worktree")"
    git -C "$repo" worktree add "$worktree" "$branch"
    echo "NOTE: worktree recreated from retained branch $branch"
  fi

  # Number resume prompt
  local n=2
  while [[ -f "$runs/prompt.${n}.md" ]]; do ((n++)); done
  cp "$prompt_file" "$runs/prompt.${n}.md"
  # Standing orders ride along on resumes too (thread may have compacted them away)
  local standing="$(dirname "${BASH_SOURCE[0]}")/../standing-orders.md"
  if [[ -f "$standing" ]]; then
    local standing_sha prior_standing_sha short_standing_sha
    standing_sha=$(sha256_file "$standing")
    prior_standing_sha=$(read_meta_field "$slug" standing_orders_sha)
    short_standing_sha="${standing_sha:0:8}"
    printf '\n\n' >> "$runs/prompt.${n}.md"
    if [[ "$standing_sha" == "$prior_standing_sha" ]]; then
      printf 'Standing orders unchanged since dispatch (sha %s); they remain in force.\n' "$short_standing_sha" >> "$runs/prompt.${n}.md"
    else
      printf 'Standing orders UPDATED since dispatch — re-read in full:\n' >> "$runs/prompt.${n}.md"
      cat "$standing" >> "$runs/prompt.${n}.md"
      update_meta "$(meta_file "$slug")" --arg sha "$standing_sha" '.standing_orders_sha=$sha'
    fi
  fi

  local git_common_dir
  git_common_dir=$(git -C "$worktree" rev-parse --git-common-dir)
  if [[ "$git_common_dir" != /* ]]; then
    git_common_dir="$(cd "$worktree" && cd "$git_common_dir" && pwd)"
  fi

  local prompt_text; prompt_text=$(cat "$runs/prompt.${n}.md")

  # exec resume only supports a subset of flags (no -C, -s, --add-dir);
  # run_codex_task cd's into the worktree so resume inherits the correct CWD
  local codex_args=()
  codex_args+=(exec resume "$thread_id")
  codex_args+=(-c 'approval_policy="never"')
  codex_args+=(--json)
  codex_args+=(-o "$runs/last.md")
  codex_args+=(--skip-git-repo-check)
  codex_args+=("${ANTI_HANG_ARGS[@]}")

  update_meta "$(meta_file "$slug")" '.status="running" | .finished=""'
  run_codex_task "$runs" "$worktree" "$CODEX_BIN" "${codex_args[@]}" "$prompt_text"
  local exit_code=$RC_EXIT

  local finished; finished=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  local status="done"
  if [[ $RC_STUCK -eq 1 ]]; then status="stuck"
  elif [[ $exit_code -ne 0 ]]; then status="failed"; fi

  update_meta "$(meta_file "$slug")" \
    --arg fin "$finished" \
    --argjson ec "$exit_code" \
    --argjson rs "$RC_RESTARTS" \
    --arg st "$status" \
    '.finished=$fin | .exit_code=$ec | .status=$st | .restarts=$rs | .pid=null'

  echo "CODEX-TASK $slug resume status=$status exit=$exit_code restarts=$RC_RESTARTS thread=$thread_id worktree=$worktree last=$runs/last.md"
  exit $exit_code
}

##############################################################################
# status
##############################################################################
cmd_status() {
  local slug="${1:-}"; [[ -n "$slug" ]] || die "slug required"
  local runs; runs=$(runs_dir "$slug")
  [[ -d "$runs" ]] || die "no run found for slug '$slug'"

  heal_meta "$(meta_file "$slug")"
  echo "=== meta.json ==="
  cat "$(meta_file "$slug")"
  echo ""
  echo "=== last 5 lines of last.md ==="
  if [[ -f "$runs/last.md" ]]; then
    tail -5 "$runs/last.md"
  else
    echo "(no last.md yet)"
  fi
}

##############################################################################
# diff
##############################################################################
cmd_diff() {
  local slug="" since_review=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --since-review) since_review=1; shift ;;
      *)
        if [[ -z "$slug" ]]; then slug="$1"; shift
        else die "unknown arg: $1"; fi ;;
    esac
  done
  [[ -n "$slug" ]] || die "slug required"

  local worktree base_sha
  worktree=$(read_meta_field "$slug" worktree)
  base_sha=$(read_meta_field "$slug" base_sha)

  [[ -d "$worktree" ]] || die "worktree not found: $worktree"

  if [[ $since_review -eq 1 ]]; then
    local reviewed_sha
    reviewed_sha=$(read_meta_field "$slug" reviewed_sha)
    if [[ -n "$reviewed_sha" ]]; then
      echo "# delta since reviewed_sha ${reviewed_sha:0:8}"
      git -C "$worktree" diff "${reviewed_sha}..HEAD"
      return 0
    fi
    echo "# no prior review; showing full diff"
  fi

  echo "=== git diff HEAD ==="
  git -C "$worktree" diff HEAD
  echo ""
  echo "=== git status --short ==="
  git -C "$worktree" status --short
  echo ""
  echo "=== git log ${base_sha}..HEAD ==="
  git -C "$worktree" log --oneline "${base_sha}..HEAD"
}

##############################################################################
# review — mechanical structural checks (chief engineer still reads the diff)
##############################################################################
cmd_review() {
  local slug="${1:-}"; [[ -n "$slug" ]] || die "slug required"
  local runs worktree base_sha
  runs=$(runs_dir "$slug")
  worktree=$(read_meta_field "$slug" worktree)
  base_sha=$(read_meta_field "$slug" base_sha)
  [[ -d "$worktree" ]] || die "worktree not found: $worktree"
  local range="${base_sha}..HEAD"

  if [[ -f "$runs/order.json" ]]; then
    echo "=== order footprint (advisory) ==="
    local footprint_tmp
    footprint_tmp=$(mktemp)
    git -C "$worktree" diff --name-only "${base_sha}...HEAD" | order_review_footprint "$runs/order.json" > "$footprint_tmp"
    if [[ -s "$footprint_tmp" ]]; then
      cat "$footprint_tmp"
      record_review_violations "$slug" "$footprint_tmp"
    else
      echo "  clean"
    fi
    rm -f "$footprint_tmp"
    echo ""
  fi

  echo "=== commits ==="
  git -C "$worktree" log --oneline "$range"
  echo ""
  echo "=== diff stat ==="
  git -C "$worktree" diff "$range" --stat | tail -15
  echo ""
  echo "=== uncommitted leftovers (should be empty) ==="
  git -C "$worktree" status --short
  echo ""
  echo "=== whitespace (git diff --check) ==="
  git -C "$worktree" diff "$range" --check && echo "clean"
  echo ""
  echo "=== new files over 300 lines (module budget) ==="
  local f n hits=0
  while IFS= read -r f; do
    [[ -f "$worktree/$f" ]] || continue
    n=$(wc -l < "$worktree/$f")
    if (( n > 300 )); then echo "  $f: $n lines"; hits=1; fi
  done < <(git -C "$worktree" diff "$range" --name-only --diff-filter=A)
  (( hits == 0 )) && echo "  none"
  echo ""
  echo "=== suspicious patterns in added lines (compat/fallback/shim/legacy/broad-except/skip) ==="
  git -C "$worktree" diff "$range" -U0 | grep -E '^\+' | grep -nE 'compat|fallback|shim|legacy_|except Exception|except:|pytest\.mark\.(skip|integration)|# *type: *ignore' \
    | head -20 || echo "  none"
  echo ""
  echo "=== utils dumping grounds ==="
  git -C "$worktree" diff "$range" --name-only --diff-filter=A | grep -E '(utils|helpers)\.py$' || echo "  none"
  echo ""
  echo "REVIEW NOTE: mechanical checks only — read the full diff, verify acceptance commands, check import directions per the order."

  local reviewed_sha
  reviewed_sha=$(git -C "$worktree" rev-parse HEAD)
  update_meta "$(meta_file "$slug")" --arg sha "$reviewed_sha" '.reviewed_sha=$sha'
}

##############################################################################
# merge-next
##############################################################################
cmd_merge_next() {
  local repo=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --repo) repo="$2"; shift 2 ;;
      --help|-h) usage; return 0 ;;
      *) die "unknown merge-next arg: $1" ;;
    esac
  done

  [[ -n "$repo" ]] || die "merge-next requires --repo <root>"
  [[ -d "$repo" ]] || die "repo not found: $repo"
  repo=$(cd "$repo" && pwd)

  local primary current status
  primary=$(detect_primary_branch "$repo")
  current=$(git -C "$repo" rev-parse --abbrev-ref HEAD)
  if [[ "$current" != "$primary" ]]; then
    die "merge-next: checkout $primary first (on $current)"
  fi
  status=$(git -C "$repo" status --porcelain)
  if [[ -n "$status" ]]; then
    die "merge-next: mainline has uncommitted changes — commit/stash first"
  fi

  local meta st slug meta_repo meta_repo_abs branch order_file dep dep_tmp
  local best_slug="" best_branch="" best_meta="" blocked=0 deps_ok blocked_deps
  for meta in "$RUNS_BASE"/*/meta.json; do
    [[ -f "$meta" ]] || continue
    heal_meta "$meta"

    st=$(meta_file_field "$meta" status)
    [[ "$st" == "done" ]] || continue

    slug=$(meta_file_field "$meta" slug)
    [[ -n "$slug" ]] || slug=$(basename "$(dirname "$meta")")
    meta_repo=$(meta_file_field "$meta" repo)
    branch=$(meta_file_field "$meta" branch)
    [[ -n "$meta_repo" && -n "$branch" ]] || continue
    if ! meta_repo_abs=$(cd "$meta_repo" 2>/dev/null && pwd); then
      continue
    fi
    [[ "$meta_repo_abs" == "$repo" ]] || continue
    git -C "$repo" rev-parse --verify "refs/heads/$branch" >/dev/null 2>&1 || continue
    if git -C "$repo" merge-base --is-ancestor "$branch" "$primary" 2>/dev/null; then
      continue
    fi

    deps_ok=1
    blocked_deps=""
    order_file="$(dirname "$meta")/order.json"
    if [[ -f "$order_file" ]]; then
      dep_tmp=$(mktemp)
      if ! order_dep_list "$order_file" > "$dep_tmp"; then
        rm -f "$dep_tmp"
        die "merge-next: failed to read depends_on: $order_file"
      fi
      while IFS= read -r dep; do
        [[ -n "$dep" ]] || continue
        if ! dep_satisfied "$dep"; then
          deps_ok=0
          blocked_deps="${blocked_deps}${blocked_deps:+,}$dep"
        fi
      done < "$dep_tmp"
      rm -f "$dep_tmp"
    fi
    if (( deps_ok == 0 )); then
      echo "BLOCKED $slug waits-for $blocked_deps"
      blocked=$((blocked + 1))
      continue
    fi

    if [[ -z "$best_slug" || "$slug" < "$best_slug" ]]; then
      best_slug="$slug"
      best_branch="$branch"
      best_meta="$meta"
    fi
  done

  if [[ -z "$best_slug" ]]; then
    echo "merge-next: nothing ready (${blocked} blocked by deps)"
    return 0
  fi

  if ! git -C "$repo" merge --no-ff "$best_branch" -m "merge codex/$best_slug via merge-next"; then
    git -C "$repo" merge --abort
    echo "SLICE-COLLISION $best_slug: $best_branch conflicts with $primary — footprints overlapped, re-slice (do NOT hand-resolve)"
    exit 1
  fi

  update_meta "$best_meta" --arg st merged '.status=$st'
  echo "MERGED $best_slug: $best_branch -> $primary"
  echo "REBASE-NEXT: remaining in-flight worktrees should rebase onto the new $primary before their next review."
}

##############################################################################
# clean
##############################################################################
cmd_clean() {
  local slug="" force=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --force) force=1; shift ;;
      *)
        if [[ -z "$slug" ]]; then slug="$1"; shift
        else die "unknown arg: $1"; fi ;;
    esac
  done
  [[ -n "$slug" ]] || die "slug required"

  local worktree repo
  worktree=$(read_meta_field "$slug" worktree)
  repo=$(read_meta_field "$slug" repo)

  # Guard: premature clean severs the rework channel before user-level acceptance.
  # Refuse unless the task branch is already merged into the repo's current HEAD.
  local branch
  branch=$(read_meta_field "$slug" branch)
  if [[ $force -eq 0 ]] && git -C "$repo" rev-parse --verify "refs/heads/$branch" >/dev/null 2>&1; then
    if ! git -C "$repo" merge-base --is-ancestor "$branch" HEAD 2>/dev/null; then
      die "branch $branch not merged into HEAD — deliverable may still need rework (clean only after user-level acceptance). Use --force to override"
    fi
  fi

  if [[ -d "$worktree" ]]; then
    if [[ $force -eq 1 ]]; then
      git -C "$repo" worktree remove --force "$worktree"
    else
      # Check dirty
      if ! git -C "$worktree" diff --quiet || ! git -C "$worktree" diff --cached --quiet; then
        die "worktree is dirty — use --force to remove anyway"
      fi
      git -C "$repo" worktree remove "$worktree"
    fi
    echo "Worktree removed: $worktree"
  else
    echo "Worktree already gone: $worktree"
  fi

  update_meta "$(meta_file "$slug")" --arg st cleaned '.status=$st'
  echo "Status set to cleaned. Branch codex/$slug retained."
}

##############################################################################
# list
##############################################################################
cmd_list() {
  local found=0
  for meta in "$RUNS_BASE"/*/meta.json; do
    [[ -f "$meta" ]] || continue
    found=1
    heal_meta "$meta"
    python3 - "$meta" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as f:
    data = json.load(f)
fields = [
    data.get("slug", ""),
    data.get("status", ""),
    data.get("started", ""),
    str(data.get("restarts", 0)),
    data.get("thread_id", ""),
]
print("\t".join("" if value is None else str(value) for value in fields))
PY
  done
  [[ $found -eq 1 ]] || echo "(no runs)"
}

##############################################################################
# violations
##############################################################################
cmd_violations() {
  local slug="${1:-}"
  [[ $# -le 1 ]] || die "usage: violations [<slug>]"

  if [[ -n "$slug" ]]; then
    local ledger
    ledger="$(runs_dir "$slug")/violations.jsonl"
    if [[ -f "$ledger" ]]; then
      cat "$ledger"
    else
      echo "(no violations recorded for $slug)"
    fi
    return 0
  fi

  python3 - "$RUNS_BASE" <<'PY'
import collections
import glob
import json
import os
import sys

runs_base = sys.argv[1]
paths = sorted(glob.glob(os.path.join(runs_base, "*", "violations.jsonl")))
counts = collections.Counter()
total = 0
for path in paths:
    with open(path, encoding="utf-8") as f:
        for raw in f:
            raw = raw.strip()
            if not raw:
                continue
            data = json.loads(raw)
            counts[data["rule"]] += 1
            total += 1
for rule, count in sorted(counts.items(), key=lambda item: (-item[1], item[0])):
    print("%s  %s" % (count, rule))
print("total: %s violations across %s runs" % (total, len(paths)))
PY
}

##############################################################################
# dispatch
##############################################################################
subcmd="${1:-}"; shift || true

case "$subcmd" in
  new)    cmd_new    "$@" ;;
  preflight) cmd_preflight "$@" ;;
  resume) cmd_resume "$@" ;;
  status) cmd_status "$@" ;;
  diff)   cmd_diff   "$@" ;;
  review) cmd_review "$@" ;;
  merge-next) cmd_merge_next "$@" ;;
  violations) cmd_violations "$@" ;;
  clean)  cmd_clean  "$@" ;;
  list)   cmd_list   "$@" ;;
  help|--help|-h) usage ;;
  *)      die "unknown subcommand '$subcmd'. Valid: new preflight resume status diff review merge-next violations clean list" ;;
esac
