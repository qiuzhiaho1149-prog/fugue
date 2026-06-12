---
name: codex-prompt-craft
description: Use this skill when the user asks to draft a Codex prompt, hand off a coding task to Codex / openai codex-cli, write an execution prompt for "let Codex do X", produce a minimal-context high-precision prompt for an LLM coding agent that operates on a worktree, or when in orchestrator mode you need to format a work-order for a downstream executor. Trigger keywords: "Codex prompt", "draft execution prompt", "craft codex prompt", "slim codex prompt", "let Codex execute", "write a prompt for Codex", "codex work order", "give Codex this task", "codex direct execution". Produces a fenced-markdown work-order following the design principles described herein. Skip this skill when the change is cross-service > 10 files, contract-changing, or the user asks for "full / comprehensive / detailed" prompt with rationale — use audited long-form instead.
---

# Codex Prompt Craft

Minimal-context, high-precision Codex execution prompts. Treats the prompt as a **work order**, not an audit trail.

## Core principle

Codex CLI has limited internal context window. Long prompts → slow + lose focus. Only include what Codex **needs to act**, not what you needed to **decide**. Information density ≈ 3× compared to staging-file documentation style.

## What Codex already has (do NOT include in prompt)

Codex CLI auto-knows:
- Worktree path, current branch, git state (`git status / log / show / diff` available)
- File system (can `ls / cat / find / grep` itself)
- Pytest / ruff / lint invocation patterns (engineering judgment)
- Recent commit history (`git log -50` is one tool call away)
- Worktree-internal docs (`docs/design-docs/RFC-*.md`, `docs/runbooks/`, `contracts/`)

These cost prompt tokens for zero value if Codex would re-derive them anyway. **Skip them.**

## What Codex DOES need (MUST include)

- **WHAT**: precise `file:line` OR pattern (better than "find the relevant code"). For multi-location change, list each location.
- **WHY 1 line**: prevents Codex engineering-judgment second-guessing (e.g., "this except looks intentional, do I really change it?"). Brief rationale per item, max 1 line.
- **HARD INVARIANTS**: any boundary that must NOT shift — `<contract_hash>`, schema field positions, contract enums, migration revision IDs, etc. Put at top of prompt, in bold, with "STOP and surface BEFORE committing" instruction if violated.
- **Acceptance binary**: objective pass/fail commands. Examples: `pytest <path> -q clean`, `grep "<pattern>" returns 0`, `git diff --check passes`. Avoid subjective "verify reasonable".
- **Constraints**: explicit do-not list. Examples: "no fingerprint change", "no migration", "no V1 touch", "no `git add -A`".
- **Commit message verbatim**: full text including subject + body + Co-Authored-By. Codex should not have to draft wording.

## What Codex does NOT need (cuts context bloat)

- ❌ Full audit history / subagent reports / decision rationale paragraphs
- ❌ Cross-RFC reference chains (Codex can `grep "RFC-XXX"` itself)
- ❌ File path lists that Codex can `ls` itself in < 2 seconds
- ❌ Same acceptance gate repeated in multiple sections — say once
- ❌ References to docs OUTSIDE the worktree (e.g., `~/Documents/<project>-audits/*`, `~/.claude/*`) — Codex doesn't auto-load these and cannot read them
- ❌ Verbose pre-flight discussion of edge cases unless > 50% likely to materialize
- ❌ "Predecessor context" beyond commit hash + 1-line summary
- ❌ Multi-paragraph background about why this matters strategically

## Required structure (template)

````markdown
# Task: <one-line goal>

Branch `<branch-name>` (push allowed). Predecessor: `<commit-hash>` (<one-line>).

**HARD INVARIANTS**: <hash / schema / contract constraints that must not change>. If any change violates → STOP and surface BEFORE committing.

## Item 1 — <one-line summary>

<file:line OR grep pattern>: <before> → <after>. **Why**: <1 line>.

<additional small bits: tests to add, sentinels, verifications if non-obvious>

## Item 2 — ...
(same pattern)

## Item N — ...

## Acceptance (all binding)

```bash
<pytest commands>
<ruff command>
<grep verification>
git diff --check
```

All must pass clean.

**Acceptance-modality rule**: acceptance checks must live in the same modality as the defect space.
Code → tests/lint. Visual deliverables (SVG/UI/plots) → render-level geometry checks shipped WITH the
order (e.g. a bounding-box pairwise-overlap script that applies `<g transform>` chains — raw x/y
attributes lie under transforms). Data artifacts → schema + row-count + checksum. XML-parses /
grep-clean NEVER proves a visual layout is correct; a defect only a human eye can catch means the
order's acceptance section was under-specified.

## Transparency report (at end)

1. Final commit hash
2. <invariant verification result, e.g., hash recompute>
3. <any conditional outcomes, e.g., orphan-delete vs retain>
4. Pre-existing test failures NOT introduced by this commit (list explicitly)
5. Any item triggering unexpected behavior (esp. <specific risk if any>)

## Commit

```
<prefix>: <one-line summary including key items>

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
```

Single atomic commit (or split if <specific condition> — surface BEFORE committing).

::git-stage{cwd="<absolute worktree path>"}
::git-commit{cwd="<absolute worktree path>"}
::git-push{cwd="<absolute worktree path>" branch="<branch>"}
````

## Commit prefix selection

- `[contract-change] <phase>: <summary>` — used when a core contract file (e.g. `<schema>.yaml`) content actually changes OR canonical fingerprints regenerate. MUST also include baseline regen + freeze test baseline update IN THE SAME COMMIT.
- `<phase>: <summary>` — used for code / test / docs only, no contract shape touch, no yaml content change.
- Never `--amend` — always create a new commit.
- Never `git push --force` to feature branch — surface for confirmation if needed.

## Anti-patterns (DO NOT)

- ❌ Long preamble explaining "why this matters strategically" — Codex doesn't need motivation, it needs spec
- ❌ "See `~/Documents/<project>-audits/*` for context" — Codex cannot read external paths
- ❌ Repeated acceptance criteria across multiple sections — say once
- ❌ "Codex engineering judgment decides scope X / Y / Z" without bounds — leaves Codex to invent acceptance
- ❌ Pre-flight discussion of edge cases unless > 50% likely to occur
- ❌ File-path lists that Codex can `grep`/`ls` itself in < 2 seconds
- ❌ Acceptance gates that aren't binary (e.g., "verify reasonable" — define "reasonable")
- ❌ Multi-paragraph rationale per item — 1 line each max
- ❌ Commit message draft as "draft a commit message" instead of supplying verbatim text
- ❌ Missing `HARD INVARIANTS` block when the change is at all hash / schema / contract-adjacent
- ❌ Forgetting to specify which fixtures / freeze tests need updating in same commit as a contract-change

## Self-check checklist (run BEFORE rendering to user)

1. **Token budget**: prompt ≤ 100 lines? If > 150, find what to cut. Re-read every line and ask "can Codex derive this?"
2. **Codex re-derivation test**: for each piece of context, would Codex grep / ls / cat / git-log to find it anyway? If yes, cut it.
3. **WHY presence**: every Item has ≤ 1-line rationale? Not missing AND not bloated.
4. **HARD INVARIANTS at top**: yes, not buried mid-prompt.
5. **Acceptance binary**: every gate has a binary pass/fail command? No "verify reasonable" / "ensure quality"?
6. **Commit message verbatim**: subject + body + Co-Authored-By all written, no "draft a message" hand-wave?
7. **External doc refs removed**: no `~/Documents/<project>-audits/*`, no `~/.claude/*` references? (Codex can't read these.)
8. **Conditional logic clarity**: every "if X then Y else Z" is explicit, not left to "Codex engineering judgment"?
9. **Contract discipline**: if contract-shape-changing, did you mandate fixture regen + freeze test update in SAME commit? If not contract-changing, did you assert hash stability in acceptance?
10. **Branch + push directive**: branch name correct? push allowed (or explicitly disabled if sensitive)?

## When to escalate (DO NOT use slim format)

Use a longer audited prompt format (audit-before-paste pattern from S12 / S13 / S14) when ANY of:

- Cross-service refactor with > 10 file blast radius
- Envelope-fingerprint-changing commit with > 5 downstream consumer files
- First-time-introduced architectural pattern (new module, new sub-policy, new RFC realization)
- Critical migration with atomic ordering constraint (e.g., V2 normalizer + migration drop columns)
- V1 / legacy deletion involving multi-service coordination
- User explicitly asks for "full / comprehensive / detailed prompt with rationale"

In escalation cases, fall back to staging-file approach: write a full audit-first prompt with grep pre-flight, blast-radius enumeration, explicit file lists, file-by-file disposition. Reference the S12/S13/S14 audited prompts as template precedent.

## Output discipline

- Render the final prompt in a **quadruple-backtick** fenced markdown block so the user can one-click copy without ambiguity (per memory `codex-prompts-delimited-block`).
- Prompt body in **English only** (per memory `codex-prompts-always-english`); the orchestrator-side rationale / explanation around the prompt may be in the user's preferred language.
- Default to **push allowed** on feature branches (per memory `codex-prompts-default-allow-push`); only restrict push when (a) spike branch, (b) sensitive data, or (c) ACL unclear.
- After rendering, briefly note (1-2 lines max) the **design choices** that distinguish this prompt from a longer-form one, so the user understands the deliberate slimness. Example: "HARD INVARIANTS at top; 5 items each with 1-line rationale; all acceptance gates binary."

## Reference examples

- Your own audit/staging file for a task (250+ lines, audit-trail style); compare against the slim prompt produced in chat for the same task to see compression ratio.
- Long-form audited prompts you have written before — use these as precedent when ESCALATING; do not copy verbatim into slim prompts.

## Failure modes observed (lessons logged)

1. **Under-scoping blast radius** (estimated 3-file scope; reality 17 files). Always grep-verify scope before committing prompt to "minimal" presentation if the change is at all schema-adjacent.
2. **Wrong path in acceptance command** (e.g., wrong `/healthz` endpoint path). Acceptance commands must be verified before inclusion, or marked "Codex verify path via inspection."
3. **External-doc reference Codex can't read** (e.g., `~/Documents/<project>-audits/*`). Always inline the needed snippet or move it to a worktree-internal location.
4. **YAML comment hash assumption** (would yaml comments change content_hash?). Specify the verification command inline rather than assert "should be unchanged"; Codex must verify, not assume.
5. **Codex prompt typo on magic constants** (e.g., wrong hex length). Cross-check magic constants against codebase BEFORE including in prompt; Codex's "engineering judgment against codebase" may rescue it but costs a transparency-report cycle.
6. **Grep scope omits top-level tooling** (e.g., `lint/` dir). When prompting orphan-delete decisions via `grep -rn "<pattern>" services/ tests/ tools/ examples/ docs/ contracts/`, the scope **MUST also include** `lint/` (e.g., `lint/spec_lint.py` may enforce `REQUIRED_FILES`) and any other top-level tooling directories. Updated default scope for `grep -rn` in orphan-delete prompts: `services/ tests/ tools/ examples/ docs/ contracts/ lint/ scripts/`.
7. **macOS system `python3` is 3.9 (no `StrEnum`)** — when prompts include `python3 -c "..."` recompute commands that may use Python ≥ 3.10 features (StrEnum, structural pattern matching, etc.), explicitly specify `/opt/homebrew/bin/python3.11` or equivalent.
