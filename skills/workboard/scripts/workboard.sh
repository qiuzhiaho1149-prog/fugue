#!/usr/bin/env bash
# Read-only Fugue workboard inspector.
# Usage: workboard.sh <repo-path>
set -euo pipefail

RUNS_BASE="${RUNS_BASE:-$HOME/.claude/codex-team/runs}"
NOW_EPOCH=$(date -u +%s)
FLAGS=()

die() { echo "ERROR: $*" >&2; exit 1; }

repo_arg="${1:-}"
[[ -n "$repo_arg" && $# -eq 1 ]] || die "usage: workboard.sh <repo-path>"
[[ -d "$repo_arg" ]] || die "not a git repo: $repo_arg"

repo_abs=$(cd "$repo_arg" 2>/dev/null && pwd -P) || die "not a git repo: $repo_arg"
git -C "$repo_abs" rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "not a git repo: $repo_arg"
repo_top=$(git -C "$repo_abs" rev-parse --show-toplevel)
git_common=$(git -C "$repo_top" rev-parse --path-format=absolute --git-common-dir)
repo_common="$repo_top"
if [[ "$(basename "$git_common")" == ".git" ]]; then
  repo_common=$(dirname "$git_common")
fi

short_rev() {
  git -C "$repo_top" rev-parse --short "$1" 2>/dev/null || echo "-"
}

branch_exists() {
  local branch="$1"
  [[ -n "$branch" ]] && git -C "$repo_top" rev-parse --verify --quiet "refs/heads/$branch" >/dev/null
}

merge_base() {
  local left="$1" right="$2" mb=""
  if mb=$(git -C "$repo_top" merge-base "$left" "$right" 2>/dev/null); then
    echo "$mb"
  else
    echo ""
  fi
}

is_ancestor() {
  git -C "$repo_top" merge-base --is-ancestor "$1" "$2" >/dev/null 2>&1
}

tip_rev() {
  git -C "$repo_top" rev-parse "$1" 2>/dev/null || echo ""
}

mainline_ref=""
origin_head=$(git -C "$repo_top" symbolic-ref -q --short refs/remotes/origin/HEAD 2>/dev/null || true)
if [[ -n "$origin_head" ]]; then
  mainline_ref="$origin_head"
  mainline_name="${origin_head#origin/}"
elif branch_exists "main"; then
  mainline_ref="main"
  mainline_name="main"
elif branch_exists "master"; then
  mainline_ref="master"
  mainline_name="master"
else
  die "could not determine mainline (origin/HEAD, main, or master)"
fi
mainline_sha=$(short_rev "$mainline_ref")

commit_epoch() {
  local rev="$1" epoch=""
  if epoch=$(git -C "$repo_top" log -1 --format=%ct "$rev" 2>/dev/null); then
    echo "$epoch"
  else
    echo ""
  fi
}

age_days() {
  local rev="$1" epoch=""
  epoch=$(commit_epoch "$rev")
  if [[ -z "$epoch" ]]; then
    echo "-"
  else
    echo $(( (NOW_EPOCH - epoch) / 86400 ))
  fi
}

iso_epoch() {
  local started="$1" epoch=""
  [[ -n "$started" ]] || { echo ""; return; }
  if epoch=$(date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$started" +%s 2>/dev/null); then
    echo "$epoch"
  elif epoch=$(date -u -d "$started" +%s 2>/dev/null); then
    echo "$epoch"
  else
    echo ""
  fi
}

dirty_state() {
  local path="$1"
  if [[ -d "$path" ]] && [[ -n "$(git -C "$path" status --porcelain 2>/dev/null || true)" ]]; then
    echo "yes"
  else
    echo "no"
  fi
}

classify_parentage() {
  local branch="$1" base="" best="" best_base="" best_ambiguous=0 other="" mb="" tip="" other_base="" other_tip=""
  [[ -n "$branch" ]] || { echo "detached"; return; }
  branch_exists "$branch" || { echo "mainline"; return; }
  [[ "$branch" == "$mainline_name" ]] && { echo "mainline"; return; }

  base=$(merge_base "$branch" "$mainline_ref")
  [[ -n "$base" ]] || { echo "mainline"; return; }
  tip=$(tip_rev "$branch")
  [[ -n "$tip" ]] || { echo "mainline"; return; }

  while IFS= read -r other; do
    [[ -n "$other" ]] || continue
    [[ "$other" == "$branch" || "$other" == "$mainline_name" ]] && continue
    [[ "$branch" != codex/* && "$other" == codex/* ]] && continue
    mb=$(merge_base "$branch" "$other")
    [[ -n "$mb" && "$mb" != "$base" ]] || continue
    is_ancestor "$base" "$mb" || continue
    [[ "$mb" != "$tip" ]] || continue
    is_ancestor "$mb" "$tip" || continue
    other_base=$(merge_base "$other" "$mainline_ref")
    other_tip=$(tip_rev "$other")
    local ambiguous=0
    if [[ -n "$other_base" && -n "$other_tip" && "$mb" != "$other_base" && "$mb" != "$other_tip" ]] \
      && is_ancestor "$other_base" "$mb" && is_ancestor "$mb" "$other_tip"; then
      ambiguous=1
    fi
    if [[ -z "$best" ]]; then
      best="$other"
      best_base="$mb"
      best_ambiguous="$ambiguous"
    elif [[ "$best_base" != "$mb" ]] && is_ancestor "$best_base" "$mb"; then
      best="$other"
      best_base="$mb"
      best_ambiguous="$ambiguous"
    elif [[ "$best_base" == "$mb" && "$best" == codex/* && "$other" != codex/* ]]; then
      best="$other"
      best_base="$mb"
      best_ambiguous="$ambiguous"
    fi
  done < <(git -C "$repo_top" branch --list --format='%(refname:short)')

  if [[ "$branch" == codex/* ]]; then
    while IFS= read -r other; do
      [[ -n "$other" ]] || continue
      [[ "$other" == "$branch" || "$other" == "$mainline_name" || "$other" == codex/* ]] && continue
      mb=$(merge_base "$branch" "$other")
      [[ "$mb" == "$tip" && "$mb" != "$base" ]] || continue
      is_ancestor "$base" "$mb" || continue
      best="$other"
      best_base="$mb"
      best_ambiguous=0
      break
    done < <(git -C "$repo_top" branch --list --format='%(refname:short)')
  fi

  if [[ -n "$best" ]]; then
    if [[ "$best_ambiguous" -eq 1 ]]; then
      echo "stacked-on:$best (ambiguous)"
    else
      echo "stacked-on:$best"
    fi
  else
    echo "mainline"
  fi
}

worktree_registered() {
  local want="$1" line="" path=""
  while IFS= read -r line; do
    case "$line" in
      worktree\ *)
        path="${line#worktree }"
        [[ "$path" == "$want" ]] && return 0
        ;;
    esac
  done < <(git -C "$repo_top" worktree list --porcelain)
  return 1
}

print_worktree_row() {
  local path="$1" head="$2" branch="$3"
  local branch_label="${branch:-detached}" head_short base base_short parentage age dirty branch_ok
  head_short=$(short_rev "$head")
  base=$(merge_base "$head" "$mainline_ref")
  base_short="-"
  [[ -n "$base" ]] && base_short=$(short_rev "$base")
  parentage=$(classify_parentage "$branch")
  age=$(age_days "$head")
  dirty=$(dirty_state "$path")
  printf "%-78s | %-28s | %-7s | %-7s | %-32s | %-4s | %s\n" \
    "$path" "$branch_label" "$head_short" "$base_short" "$parentage" "$age" "$dirty"

  branch_ok=0
  [[ -n "$branch" ]] && branch_exists "$branch" && branch_ok=1
  if [[ ! -d "$path" || ( -n "$branch" && "$branch_ok" -eq 0 ) ]]; then
    FLAGS+=("ORPHAN-WORKTREE: $path branch=${branch_label}")
  fi
  [[ "$parentage" == stacked-on:* ]] && FLAGS+=("TANGLED: $branch_label $parentage")
  if [[ "$age" != "-" && "$age" -gt 7 && -n "$branch" ]]; then
    FLAGS+=("STALE: $branch age=${age}d")
  fi
  if [[ "$dirty" == "yes" && "$age" != "-" && "$age" -gt 2 ]]; then
    FLAGS+=("DIRTY-PARKED: $branch_label age=${age}d")
  fi
}

print_worktrees() {
  local line="" path="" head="" branch="" seen=0
  echo "WORKTREES:"
  printf "%-78s | %-28s | %-7s | %-7s | %-32s | %-4s | %s\n" \
    "path" "branch" "head" "base" "parentage" "age" "dirty"
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ -z "$line" ]]; then
      if [[ -n "$path" ]]; then
        print_worktree_row "$path" "$head" "$branch"
        seen=1
      fi
      path=""; head=""; branch=""
      continue
    fi
    case "$line" in
      worktree\ *) path="${line#worktree }" ;;
      HEAD\ *) head="${line#HEAD }" ;;
      branch\ refs/heads/*) branch="${line#branch refs/heads/}" ;;
      detached) branch="" ;;
    esac
  done < <(git -C "$repo_top" worktree list --porcelain; printf '\n')
  [[ "$seen" -eq 1 ]] || echo "(none)"
}

repo_matches_meta() {
  local meta_repo="$1"
  [[ "$meta_repo" == "$repo_top" || "$meta_repo" == "$repo_abs" || "$meta_repo" == "$repo_common" ]]
}

print_codex_runs() {
  local meta="" slug="" status="" meta_repo="" branch="" worktree="" started="" bexists wexists epoch age_hours found=0
  echo "CODEX RUNS:"
  printf "%-28s | %-10s | %-13s | %s\n" "slug" "status" "branch-exists" "worktree-exists"
  if [[ ! -d "$RUNS_BASE" ]]; then
    echo "(RUNS_BASE missing: $RUNS_BASE)"
    return
  fi
  if ! command -v jq >/dev/null 2>&1; then
    echo "(jq missing; codex run metadata skipped)"
    return
  fi
  for meta in "$RUNS_BASE"/*/meta.json; do
    [[ -f "$meta" ]] || continue
    meta_repo=$(jq -r '.repo // empty' "$meta" 2>/dev/null || echo "")
    repo_matches_meta "$meta_repo" || continue
    slug=$(jq -r '.slug // empty' "$meta")
    status=$(jq -r '.status // empty' "$meta")
    branch=$(jq -r '.branch // empty' "$meta")
    worktree=$(jq -r '.worktree // empty' "$meta")
    started=$(jq -r '.started // empty' "$meta")
    bexists="no"; branch_exists "$branch" && bexists="yes"
    wexists="no"; [[ -n "$worktree" ]] && worktree_registered "$worktree" && [[ -d "$worktree" ]] && wexists="yes"
    printf "%-28s | %-10s | %-13s | %s\n" "$slug" "$status" "$bexists" "$wexists"
    found=1
    if [[ "$status" == "running" ]]; then
      epoch=$(iso_epoch "$started")
      if [[ -n "$epoch" ]]; then
        age_hours=$(( (NOW_EPOCH - epoch) / 3600 ))
        [[ "$age_hours" -gt 24 ]] && FLAGS+=("ZOMBIE-RUN: $slug running ${age_hours}h")
      fi
    fi
  done
  [[ "$found" -eq 1 ]] || echo "(none)"
}

echo "MAINLINE:"
printf "%-12s %s\n" "$mainline_name" "$mainline_sha"
echo
print_worktrees
echo
print_codex_runs
echo
if [[ "${#FLAGS[@]}" -eq 0 ]]; then
  echo "FLAGS: none"
  exit 0
else
  echo "FLAGS:"
  for flag in "${FLAGS[@]}"; do
    echo "$flag"
  done
  exit 2
fi
