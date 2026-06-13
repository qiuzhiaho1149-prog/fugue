---
name: codex-team
description: Use this skill when the user wants Claude to act as lead engineer and directly dispatch coding work to OpenAI Codex CLI workers — spawning headless `codex exec` threads, reviewing their diffs, sending them back for rework, and merging. Trigger keywords: "dispatch to codex", "codex worker", "let codex implement", "codex do it", "have codex write this", "spin up a codex thread", "send to codex", "codex exec this". Also applies whenever a coding task has a clear spec (≤10 files, single service) and Claude decides to delegate implementation instead of writing code itself. Skip when the task is research/audit/design (use Claude subagents) or cross-service >10 files (decompose first).
---

# codex-team — Claude as chief engineer, Codex as worker fleet

Two files rule this system. THIS file = how the chief engineer operates. `standing-orders.md` (same dir) = the worker-facing law, **auto-appended to every prompt by the wrapper** — never copy its content into work orders; to change worker doctrine, edit that file once.

## 1. Roles & routing

- **Claude (main session)** = chief engineer: understand intent, decompose, write orders, dispatch, review, decide merges. Owns all architecture and quality decisions. The user talks only to Claude.
- **Codex worker** = default executor for coding with a clear spec, and for bulk in-repo investigation (`codex exec -C <repo> -s read-only`, low/medium effort, no worktree, `</dev/null`).
- **Claude subagents** = web research, cross-family audit of Codex output, Anthropic-side tools.
- Workers never: decide architecture, touch production/risk parameters, merge their own branch, or earn trust before the review gate.
- One task = one worktree = one branch = one resumable thread.

## 2. Lifecycle

0. **Phase plan (when the request spans multiple WOs)**: before any dispatch, emit the chief-engineer phase plan and (for programs) commit it as the plan-of-record:

   ```
   Phase: [name]            Objective: [this phase's goal]
   Tasks: [decomposed, each one WO-sized]
   Constraints: [phase-level invariants]
   Expected Output: [phase deliverables; risk analysis; next-phase recommendation]
   Codex Tasks: [the minimal task orders, in execution sequence]
   ```

   Standard phase sequence for rebuild-class work: audit → inventory → calibrate (ruler) → refactor → verify → docs/CI hardening.
1. **Preflight**: confirm repo + base SHA; root `AGENTS.md` exists.
2. **Author the order** (§3) — task-specific content ONLY; standing clauses ride along automatically.
3. **Pre-dispatch verification (MANDATORY — order defects are the #1 drift source)**: on the BASE commit verify: paths exist; file:line matches (re-grep; never trust memory or prior audits); SHAs exist; provenance accurate (committed vs on-disk); acceptance commands runnable on this host (`python3.11`, not `python`); invariants don't contradict items; TOOLBOX instruments actually exist.
4. **Dispatch**: one native subagent per worker — `Agent(subagent_type="general-purpose", model="haiku", run_in_background=true, description="codex: <slug>")`. NEVER raw background Bash from the main session (task panel renders it as an unlabeled raw box and it can zombie). The babysitter subagent's prompt must be self-contained:
   - Run `~/.claude/skills/codex-team/scripts/codex-task.sh new <slug> --repo <root> ... --prompt-file <f>` via Bash `run_in_background=true`, then WAIT for the completion notification — no polling, no sleep loops.
   - On completion: read `~/.claude/codex-team/runs/<slug>/meta.json` and the tail of `last.md`, then return EXACTLY: slug, exit_code, status, thread_id, worktree path, ≤10-line summary of the worker report, plus any sandbox-denial lines from `events.jsonl`. Summary = delta-only anchored facts (file:line / hashes / numbers / surprises & deviations); drop the worker's process narration and self-assessment adjectives verbatim — do not relay filler upward.
   - The subagent must NOT review, fix, or re-dispatch — babysit and report only; the review gate stays with the chief engineer.
   Same pattern for `resume`. Stuck worker → TaskStop the subagent, then §6.
5. **Review gate** (every iteration; "it works" never suffices):
   a. `codex-task.sh review <slug>` — mechanical checks (budgets, compat/fallback/skip patterns, whitespace, leftovers).
   b. Read the FULL diff (`codex-task.sh diff <slug>`); check import directions + the order's invariants.
   c. Re-run acceptance commands yourself (or verification subagent) — never trust the report alone.
   d. Worker claims of "pre-existing failure" → verify on the clean base before ruling.
   e. Any new gate/threshold/state machine → justify like a new dependency.
   f. Trust-anchor code (measurement/risk/money paths) → cross-family adversarial audit before merge.
   g. Report density (S7b): over budget, unanchored claims, or process-narration padding → counts as a rework finding like a failing test; the resume order quotes S7b.
6. **Rework**: ruling + concrete feedback (file:line, expected vs actual) → `codex-task.sh resume <slug>`. ~2 rounds max; still failing → the spec was wrong: re-spec or take over.
7. **Merge & clean**: after the gate, run `merge-next --repo <root>` from mainline — it merges one ready branch per call (a `SLICE-COLLISION` means footprints overlapped → re-slice, don't hand-resolve), so remaining worktrees rebase before their next review; log outcome + failed approaches to the program ledger. **Clean timing**: `clean <slug>` only after USER-level acceptance, not after the chief-engineer gate — for user-visible deliverables (visuals/UI/copy) the chief gate passing does not end rework probability. The wrapper enforces this (refuses to clean an unmerged branch without `--force`); `resume` self-heals a missing worktree from the retained branch.

## 3. Authoring a work order

Format (user-mandated; all prompts — Codex, Claude subagents, self; always English):

```
You are [role], an expert in [domain].
BACKGROUND:
- [why this WO exists / where the program is heading — intent before items]
- [state anchors: base SHA, predecessor, law documents to read first]
GOALS:
- [what done looks like, measurable; success criteria]
CONSTRAINTS:
- [task-specific HARD INVARIANTS, each with its reason]
- [ALLOWED scope: files/dirs the worker may touch]
- [FORBIDDEN scope: files/modules that must not change — name them explicitly]
- [dependency directions for THIS order]
- [autonomy grant: worker decides X; chief engineer reserves Y]
TOOLBOX:
- [repo instruments for THIS task: project-specific CLIs/validators, pytest/ruff invocations, runbooks]
- [grants: --search allowed for <purpose>? node_repl emphasis for numeric work?]
EXAMPLES:
<example>(only when a shape is hard to describe — omit if N/A)</example>
OUTPUT:
- [deliverables: commits w/ prefix, files]
- [binding acceptance commands — all must pass]
- [report sections beyond the standing ones, if any]
END
```

Authoring principles (the content discipline):
- **Intent before items** — a worker with only steps optimizes the letter of steps; that gap is drift.
- **Constrain WHAT + WHY, free the HOW** — reasons attached to invariants let the worker generalize them; pin implementation only when load-bearing; sketches labeled "adapt to code reality".
- **Explicit autonomy grant** — ambiguity of authority produces timid half-work or rogue improvisation.
- **TOOLBOX is the floor, not the ceiling** — standing order S1 makes the worker inventory + plan its tools; name what you know, expect it to find more.
- **Design forks decided consciously** — "pick and justify in the report".
- Don't restate standing orders (S1-S8 ride along automatically); don't write micro-checklists for decomposable tasks; don't copy audit text as gospel.

For heterogeneous design work: dispatch a read-only DESIGN MEMO order first (current-state map with file:line, proposal, forks with picks), ratify/overturn forks as chief engineer, commit the memo, then slice implementation orders against it.

## 4. Tooling reference

Wrapper: `~/.claude/skills/codex-team/scripts/codex-task.sh` (state: `~/.claude/codex-team/runs/<slug>/`).

```bash
codex-task.sh preflight --repo <root> [--cap N] <order.json> [<order.json>...]
codex-task.sh new <slug> --repo <root> [--base <ref>] [--model <m>] [--effort low|medium|high|xhigh] [--net] [--search] [--sandbox <mode>] --prompt-file <f> [--order <order.json>]
codex-task.sh resume <slug> --prompt-file <f>   # rework, same thread (standing orders compacted when unchanged)
codex-task.sh review <slug>                     # mechanical review-gate checks
codex-task.sh merge-next --repo <root>           # serial mainline merge, one ready branch per call
codex-task.sh violations [<slug>]               # raw per-run ledger, or aggregate repeat rules across runs
codex-task.sh diff <slug> [--since-review]
codex-task.sh status|list|clean <slug>
```

`new` records the standing-orders sha; `resume` sends a one-line unchanged marker unless that file changed, then re-appends it in full.
`review` records `reviewed_sha`; `diff --since-review` prints only the delta since the last review, falling back to the full diff when no review is recorded.
`SLICE-COLLISION` from `merge-next` means footprints overlapped; re-slice instead of hand-resolving (preflight's in-flight check should have caught it).
`review` also writes `violations.jsonl`; use `violations` to spot repeat-offender rules before proposing standing-order patches.

### Order manifest & preflight

For multi-worker dispatch, create one `order.json` next to each prompt and run `preflight`; multi-worker dispatch MUST pass preflight first.
Schema: `{"slug":"exec-retry-fix","depends_on":[],"allowed_paths":["src/exec/**"],"forbidden_paths":["src/risk/**"],"acceptance":"pytest ..."}`.
Required: `slug`, non-empty `allowed_paths`, `acceptance`; optional `depends_on`/`forbidden_paths` default to `[]`.
`preflight --repo <root> [--cap N] <order.json>...` checks schema, capacity (default 2, max 3), batch/in-flight footprint overlap, and dependencies.
Attach the manifest with `new --order <order.json>`; `review` prints `OUT-OF-FOOTPRINT` for advisory scope violations.

Liveness (built into the wrapper):
- **Stall watchdog**: no new `events.jsonl` output for `CODEX_STALL_TIMEOUT` (default 900s) → kill the worker, **auto-resume the same thread once** (`CODEX_AUTO_RESUME`, default 1) with a restart nudge; still stalling → final `status="stuck"`, non-zero exit. meta.json records `pid` while running and `restarts` at the end.
- **Zombie self-heal**: `list`/`status` check the recorded pid; a "running" entry whose process is gone is rewritten to `status="died"` on the spot. Status vocabulary: `running | done | failed | stuck | died | merged | cleaned`.
- **Per-dispatch `-c` overrides** baked into every dispatch (never edits `~/.codex/config.toml` — desktop Codex keeps its own settings): `model_verbosity="low"` (API-level cut of narrative filler in reports; pairs with S7b register law), `notify=[]` (SkyComputerUseClient orphan bug openai/codex#26293), `stream_idle_timeout_ms=60000` + `stream_max_retries=3`, figma MCP disabled, node_repl/codegraph startup timeouts capped.
- Babysitter subagents must surface `status`/`restarts` from the final `CODEX-TASK` line verbatim; `stuck`/`died` → chief engineer decides resume vs re-spec (the wrapper already burned its one auto-restart).

Verified facts (codex-cli 0.137.0-alpha.4, 2026-06-11):
- Binary: `/Applications/Codex.app/Contents/Resources/codex` (npm `codex` on PATH is BROKEN); wrapper handles via `CODEX_BIN`.
- Wrapper passes `-s workspace-write -c 'approval_policy="never"' --json -o last.md --add-dir <git-common-dir>` (without add-dir, `git commit` in a worktree is sandbox-blocked). No `-a` flag exists in this version.
- `</dev/null` REQUIRED on any non-TTY `codex exec` — else it blocks on "Reading additional input from stdin...". The wrapper now adds this itself (and writes codex output straight to `events.jsonl`, stderr to `stderr.log` — no tee pipe, so no zombie reader); only bare `codex exec` calls outside the wrapper still need it manually.
- Thread id: first `thread.started` event (`thread_id`); `exec resume` rejects `-C/-s/--add-dir` (wrapper cd's into the worktree).
- User config defaults `danger-full-access` + `xhigh` — wrapper overrides sandbox; ALWAYS set `--effort` (low mechanical / medium normal / high design-heavy).
- `--net` only for installs/APIs (workspace-write blocks network); `--search` enables the web-search tool for research-flavored orders.
- MCP channel (`codex`/`codex-reply`, workspace-write-locked) exists for quick synchronous micro-tasks; NEVER parallelize via MCP (hang bugs, openai/codex#6664).

## 5. Slicing, parallelism & quota

**Slice taxonomy** — every WO declares its type; type sets the defaults:

| type | shape | effort | parallel? |
|---|---|---|---|
| `mechanical` | rename / migration / config sweep, fully specified | low | ✓ fleet |
| `spec-implement` | make frozen spec tests pass (one use case / brick) | medium | ✓ if file-disjoint |
| `design-memo` | read-only current-state map + proposal + forks | high | ✗ serial; ratify before slicing |
| `probe` | read-only investigation / measurement → evidence file | low/medium | ✓ fleet |

Slice by **acceptance boundary**, not by code layer: one slice = one binary acceptance command set = one worktree. If a slice needs two unrelated acceptance suites, it is two slices. Size budget: ≤10 files, ≤1 sitting of worker time.

- Fan out only homogeneous, file-disjoint tasks; never two workers on the same files.
- Default ≤2 concurrent, max 3 — ChatGPT-plan auth shares ONE 5-hour reasoning window (N workers ≈ N× drain); flag to the user before >2.
- Heterogeneous/converging design: serial with checkpoints (memo → ratify → slices), never parallel.

## 6. Failure modes

- Auth expired: worker fails immediately → user runs `codex login` interactively.
- Worker hangs: the wrapper watchdog kills + auto-resumes once on its own; `status="stuck"` means that already failed — read `events.jsonl` + `stderr.log` tail, then resume with a narrower instruction (don't just re-poke). Babysitter unresponsive → TaskStop it; `list` will self-heal the meta to `died`.
- Sandbox denials in events.jsonl → fix with `--net`/rescoping, never `danger-full-access`.
- Quota exhausted: the thread persists; resume later, same slug.
- Killed mid-flight: worktree keeps uncommitted work, thread keeps context → inspect state, resume with a closeout order; never redispatch blind.
