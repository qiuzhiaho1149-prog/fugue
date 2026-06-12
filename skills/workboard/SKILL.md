---
name: workboard
description: >
  Work-in-flight inspector and triage. Use when the user says the worktrees are a mess, asks
  "which branch belongs to what", "盘点一下任务", "工作树乱了", wants to know what's half-done,
  or before starting any NEW requirement while other work is in flight. Renders a registry derived
  from git itself (worktrees × branch lineage × codex runs), flags orphans/tangles/stale work,
  and drives park/kill/supersede verdicts.
---

# Workboard — in-flight work registry & triage

> The registry is derived, not maintained: git already knows every worktree, branch, and fork
> point; codex-team runs know every worker. This skill reads that truth and forces verdicts on
> the mess. It never relies on a hand-edited status file that would itself drift.

## Inspect

```bash
~/.claude/skills/workboard/scripts/workboard.sh <repo-root>
```

Sections: MAINLINE / WORKTREES (with parentage per branch) / CODEX RUNS / FLAGS.
Exit 2 = flags present. Flags and their meaning:

| flag | meaning | default verdict |
|---|---|---|
| `ORPHAN-WORKTREE` | worktree dir and branch no longer match | prune after zero-unique-commit check |
| `TANGLED` | branch forked from another task branch, not mainline | rebase onto mainline OR declare stacked explicitly |
| `STALE` | no commit >7 days | park-or-kill verdict required |
| `DIRTY-PARKED` | uncommitted changes sitting >2 days | commit as WIP to its branch, or discard consciously |
| `ZOMBIE-RUN` | codex run "running" >24h | inspect events.jsonl tail, resume or mark failed |

## Triage protocol (the intake side — run BEFORE opening any new line of work)

A new requirement (including mid-conversation "better ideas") never goes straight to a worktree:

1. **Classify**: `bug` / `feature` (delivery track) / `probe` (research track) / **`pivot`**
   (replaces work currently in flight) / `unrelated` (different project entirely).
2. **Verdict**: **queue** (default — note it, finish current slice first) · **parallel-now**
   (only if file-disjoint AND worker capacity exists) · **supersede** (pivot case, below).
3. **Supersede discipline** — the half-done-work rule:
   - The OLD line gets an explicit verdict first: **park** (commit WIP to its branch, one-line
     note in the commit message: `wip: parked, superseded by <new-slug>`) or **kill** (branch
     deleted only after the zero-unique-commit check).
   - The NEW line branches **from mainline**, never from the half-done branch — forking from
     abandoned work is how parentage gets tangled.
4. **Base discipline**: every task branch forks from mainline (or an explicitly declared
   integration branch). Stacking on another task branch must be declared in the work order;
   undeclared stacking = the `TANGLED` flag.

## Cleanup verdicts (safety rails)

- Never delete a branch without verifying zero unique commits
  (`git log mainline..branch --oneline` empty).
- Dirty worktrees: back up (WIP commit) before removal.
- Codex worktrees: `codex-task.sh clean` (it refuses unmerged branches without `--force`).
- Remote deletions always need explicit user confirmation.

## Cadence

Run the inspector at every session start in a repo with in-flight work, and before every
dispatch. FLAGS must trend to zero; a flag surviving two sessions becomes a queued task itself.
