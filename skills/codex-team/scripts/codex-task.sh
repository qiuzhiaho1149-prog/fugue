#!/usr/bin/env bash
# codex-task.sh — orchestrator dispatch wrapper for OpenAI Codex CLI workers
# Usage: codex-task.sh <subcommand> [args...]
set -euo pipefail

CODEX_BIN="${CODEX_BIN:-/Applications/Codex.app/Contents/Resources/codex}"
RUNS_BASE="${RUNS_BASE:-$HOME/.claude/codex-team/runs}"

die() { echo "ERROR: $*" >&2; exit 1; }

require_slug() {
  [[ -n "${1:-}" ]] || die "slug required"
  echo "$1"
}

runs_dir() { echo "$RUNS_BASE/$1"; }
meta_file() { echo "$RUNS_BASE/$1/meta.json"; }

read_meta_field() {
  local slug="$1" field="$2"
  jq -r ".$field // empty" "$(meta_file "$slug")"
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

##############################################################################
# new
##############################################################################
cmd_new() {
  local slug="" repo="" base="HEAD" model="" effort="" net=0 sandbox="workspace-write" prompt_file=""

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
      *)
        if [[ -z "$slug" ]]; then slug="$1"; shift
        else die "unknown arg: $1"; fi ;;
    esac
  done

  [[ -n "$slug" ]]        || die "slug required"
  [[ -n "$repo" ]]        || die "--repo required"
  [[ -n "$prompt_file" ]] || die "--prompt-file required"
  [[ -f "$prompt_file" ]] || die "prompt file not found: $prompt_file"

  local runs; runs=$(runs_dir "$slug")
  [[ ! -d "$runs" ]] || die "slug '$slug' already exists at $runs — use resume or choose a new slug"

  mkdir -p "$runs"
  cp "$prompt_file" "$runs/prompt.md"
  # Auto-append standing orders (single doctrine source; update standing-orders.md, not prompts)
  local standing="$(dirname "${BASH_SOURCE[0]}")/../standing-orders.md"
  [[ -f "$standing" ]] && { printf '\n\n' >> "$runs/prompt.md"; cat "$standing" >> "$runs/prompt.md"; }

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
  [[ -n "$model" ]]  && codex_args+=(-m "$model")
  [[ -n "$effort" ]] && codex_args+=(-c "model_reasoning_effort=\"$effort\"")
  [[ $net -eq 1 ]]   && codex_args+=(-c "sandbox_workspace_write.network_access=true")
  [[ ${search:-0} -eq 1 ]] && codex_args+=(--search)

  touch "$runs/events.jsonl"

  local exit_code=0
  "$CODEX_BIN" "${codex_args[@]}" "$prompt_text" \
    | tee -a "$runs/events.jsonl" \
    || exit_code=$?

  local finished; finished=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  local thread_id; thread_id=$(extract_thread_id "$runs/events.jsonl")
  local status="done"
  [[ $exit_code -eq 0 ]] || status="failed"

  update_meta "$runs/meta.json" \
    --arg tid "$thread_id" \
    --arg fin "$finished" \
    --argjson ec "$exit_code" \
    --arg st "$status" \
    '.thread_id=$tid | .finished=$fin | .exit_code=$ec | .status=$st'

  echo "CODEX-TASK $slug exit=$exit_code thread=$thread_id worktree=$worktree last=$runs/last.md"
  exit $exit_code
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
  [[ -f "$standing" ]] && { printf '\n\n' >> "$runs/prompt.${n}.md"; cat "$standing" >> "$runs/prompt.${n}.md"; }

  local git_common_dir
  git_common_dir=$(git -C "$worktree" rev-parse --git-common-dir)
  if [[ "$git_common_dir" != /* ]]; then
    git_common_dir="$(cd "$worktree" && cd "$git_common_dir" && pwd)"
  fi

  local prompt_text; prompt_text=$(cat "$runs/prompt.${n}.md")

  # exec resume only supports a subset of flags (no -C, -s, --add-dir)
  local codex_args=()
  codex_args+=(exec resume "$thread_id")
  codex_args+=(-c 'approval_policy="never"')
  codex_args+=(--json)
  codex_args+=(-o "$runs/last.md")
  codex_args+=(--skip-git-repo-check)

  local exit_code=0
  # cd into worktree so exec resume inherits the correct CWD (it doesn't support -C)
  (cd "$worktree" && "$CODEX_BIN" "${codex_args[@]}" "$prompt_text") \
    | tee -a "$runs/events.jsonl" \
    || exit_code=$?

  local finished; finished=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  local status="done"
  [[ $exit_code -eq 0 ]] || status="failed"

  update_meta "$(meta_file "$slug")" \
    --arg fin "$finished" \
    --argjson ec "$exit_code" \
    --arg st "$status" \
    '.finished=$fin | .exit_code=$ec | .status=$st'

  echo "CODEX-TASK $slug resume exit=$exit_code thread=$thread_id worktree=$worktree last=$runs/last.md"
  exit $exit_code
}

##############################################################################
# status
##############################################################################
cmd_status() {
  local slug="${1:-}"; [[ -n "$slug" ]] || die "slug required"
  local runs; runs=$(runs_dir "$slug")
  [[ -d "$runs" ]] || die "no run found for slug '$slug'"

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
  local slug="${1:-}"; [[ -n "$slug" ]] || die "slug required"
  local worktree base_sha
  worktree=$(read_meta_field "$slug" worktree)
  base_sha=$(read_meta_field "$slug" base_sha)

  [[ -d "$worktree" ]] || die "worktree not found: $worktree"

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
  local worktree base_sha
  worktree=$(read_meta_field "$slug" worktree)
  base_sha=$(read_meta_field "$slug" base_sha)
  [[ -d "$worktree" ]] || die "worktree not found: $worktree"
  local range="${base_sha}..HEAD"

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
    jq -r '[.slug, .status, .started, .thread_id] | @tsv' "$meta"
  done
  [[ $found -eq 1 ]] || echo "(no runs)"
}

##############################################################################
# dispatch
##############################################################################
subcmd="${1:-}"; shift || true

case "$subcmd" in
  new)    cmd_new    "$@" ;;
  resume) cmd_resume "$@" ;;
  status) cmd_status "$@" ;;
  diff)   cmd_diff   "$@" ;;
  review) cmd_review "$@" ;;
  clean)  cmd_clean  "$@" ;;
  list)   cmd_list   "$@" ;;
  *)      die "unknown subcommand '$subcmd'. Valid: new resume status diff clean list" ;;
esac
