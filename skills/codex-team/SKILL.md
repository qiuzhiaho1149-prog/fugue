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
4. **Dispatch**: `codex-task.sh new <slug> ... --prompt-file <f>` via background Bash. Never block; completion auto-notifies.
5. **Review gate** (every iteration; "it works" never suffices):
   a. `codex-task.sh review <slug>` — mechanical checks (budgets, compat/fallback/skip patterns, whitespace, leftovers).
   b. Read the FULL diff (`codex-task.sh diff <slug>`); check import directions + the order's invariants.
   c. Re-run acceptance commands yourself (or verification subagent) — never trust the report alone.
   d. Worker claims of "pre-existing failure" → verify on the clean base before ruling.
   e. Any new gate/threshold/state machine → justify like a new dependency.
   f. Trust-anchor code (measurement/risk/money paths) → cross-family adversarial audit before merge.
6. **Rework**: ruling + concrete feedback (file:line, expected vs actual) → `codex-task.sh resume <slug>`. ~2 rounds max; still failing → the spec was wrong: re-spec or take over.
7. **Merge & clean**: merge into the integration branch only after the gate; `codex-task.sh clean <slug>`; log outcome + failed approaches to the program ledger.

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
codex-task.sh new <slug> --repo <root> [--base <ref>] [--model <m>] [--effort low|medium|high|xhigh] [--net] [--search] [--sandbox <mode>] --prompt-file <f>
codex-task.sh resume <slug> --prompt-file <f>   # rework, same thread (standing orders re-appended)
codex-task.sh review <slug>                     # mechanical review-gate checks
codex-task.sh status|diff|list|clean <slug>
```

Verified facts (codex-cli 0.137.0-alpha.4, 2026-06-11):
- Binary: `/Applications/Codex.app/Contents/Resources/codex` (npm `codex` on PATH is BROKEN); wrapper handles via `CODEX_BIN`.
- Wrapper passes `-s workspace-write -c 'approval_policy="never"' --json -o last.md --add-dir <git-common-dir>` (without add-dir, `git commit` in a worktree is sandbox-blocked). No `-a` flag exists in this version.
- `</dev/null` REQUIRED on any non-TTY `codex exec` — else it blocks on "Reading additional input from stdin...".
- Thread id: first `thread.started` event (`thread_id`); `exec resume` rejects `-C/-s/--add-dir` (wrapper cd's into the worktree).
- User config defaults `danger-full-access` + `xhigh` — wrapper overrides sandbox; ALWAYS set `--effort` (low mechanical / medium normal / high design-heavy).
- `--net` only for installs/APIs (workspace-write blocks network); `--search` enables the web-search tool for research-flavored orders.
- MCP channel (`codex`/`codex-reply`, workspace-write-locked) exists for quick synchronous micro-tasks; NEVER parallelize via MCP (hang bugs, openai/codex#6664).

## 5. Parallelism & quota

- Fan out only homogeneous, file-disjoint tasks; never two workers on the same files.
- Default ≤2 concurrent, max 3 — ChatGPT-plan auth shares ONE 5-hour reasoning window (N workers ≈ N× drain); flag to the user before >2.
- Heterogeneous/converging design: serial with checkpoints (memo → ratify → slices), never parallel.

## 6. Failure modes

- Auth expired: worker fails immediately → user runs `codex login` interactively.
- Worker hangs: kill the shell, read `events.jsonl` tail, resume with a narrower instruction.
- Sandbox denials in events.jsonl → fix with `--net`/rescoping, never `danger-full-access`.
- Quota exhausted: the thread persists; resume later, same slug.
- Killed mid-flight: worktree keeps uncommitted work, thread keeps context → inspect state, resume with a closeout order; never redispatch blind.
