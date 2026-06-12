---
name: write-use-case
description: >
  Code as design: writing a business use case IS writing the design. Use when planning or
  implementing any new business action, when the user says "write a use case" / "model this" /
  "plan then generate the code" / "make this a composable brick", or when a Codex work order
  needs an executable spec instead of a prose design doc. Produces a typed use-case contract
  file + Given/When/Then spec tests, then dispatches "make these tests pass" to Codex.
  Skip for pure infra/adapter work with no business rule (use codex-prompt-craft directly).
---

# Write Use Case (code-as-design, auto-codegen)

> One business action = one use case file = the design document. The spec tests are the model;
> Codex's job degenerates to "make these tests pass". No intermediate markdown design docs.

Read first:
- `~/.claude/skills/shared/use_case_entity_constraints.md` (hard rules)
- The repo's installed contract module if present (`application/use_case/contract.py` or equivalent);
  if absent, seed it from `references/use_case_contract.py` (this is the first work order).
- To critique/score an existing use case, use the sibling skill `review-use-case` instead.

## Phase 1 — MODEL (Claude, the design act)

This phase is the deliverable of "/plan". Output is code, not prose.

1. Name the business action as a sentence: `AdmitIncomingOrderUseCase`, `ReleaseSettlementBatchUseCase`.
   Place it: `application/use_case/<workflow>/<use_case>.py` (workflow = business line grouping,
   e.g. `billing/`, `ingest/`, `execution/`).
2. Define types **in this order** in the use-case file:
   - `Error` — typed `DomainError` subclasses (one per rejection reason; no stringly errors)
   - `Cmd` — frozen pydantic model; business input incl. `party_id` if a party issues it; time as a field
   - `GivenState` — a domain snapshot (frozen model), NOT a repository handle
   - `Output` — typed in-process business result
   - event types — frozen replayable facts, derived from `Output`
   - `UseCase` — implements `role()`, `pre_check_command`, `validate_against_state`,
     `compute_output_and_events` (may be `raise NotImplementedError` at this phase)
   - optional `ReplyMapper` (adapter layer file, not in core)
   - port `Protocol`s the use case needs (defined here, implemented in `infra/`)
3. Write the spec tests — THIS is the modeling step. File:
   `tests/use_case/test_<workflow>_<use_case>.py`, Given/When/Then style:
   - happy paths: one test per business scenario, asserting exact `Output` + `events`
   - rejection paths: every `Error` subclass triggered via `pre_check_command` / `validate_against_state`
   - cmd × state matrix for `compute_output_and_events`
   - one executor test (happy + one rejection) with a stub outbound
   - determinism is structural (time injected via cmd/state), add a property test only for real invariants
4. Self-check against the shared constraints file. Common drift: I/O sneaking into core,
   events shaped like HTTP replies, a second events-derivation path, use_case calling use_case,
   anemic entity. If a business rule will be reused by another use case → entity method, not inline.

## Phase 2 — DISPATCH (auto-codegen via Codex)

1. Commit the contract + failing spec tests on a work branch (the spec is now immutable input).
2. Dispatch with the `codex-team` skill. The work order (codex-prompt-craft format) contains ONLY:
   - pointer: contract file + spec test file, `path:line`, branch + SHA
   - pointer: shared constraints file path (copy it into the repo or inline the 10 hard rules)
   - acceptance: the exact pytest command, binary
   - do-not list: don't edit spec tests / don't weaken assertions / don't add fallback layers /
     stuck-twice = stop and report
   It must NOT restate business rules in prose — the tests are the spec.
3. On return, gate with `review-use-case` + run acceptance yourself. Rework ≤2 rounds.

## Drift control (why this kills drift)

- Behavior change ⇒ change a spec test first, in a reviewed commit, then re-dispatch. Never patch
  implementation against an unchanged spec.
- Work orders carry pointers, not restatements — one source of truth, zero copy-drift.
- Each use case is an independent brick: no use_case→use_case imports means N use cases
  can be built/replaced/audited by N independent workers in parallel without decision collisions.

## Spec quality gates (the spec itself is now the drift surface)

- **Mutation check**: a weak spec passes garbage. After phase 2, run mutation testing (`mutmut` or
  hand-mutate 3-5 core branches: flip a comparison, drop a guard, off-by-one a threshold) — every
  mutant the spec tests fail to kill is a hole in the design, not in the implementation. Surviving
  mutants → strengthen the spec test, re-dispatch.
- **Port contract tests**: every port `Protocol` the use case defines ships ONE contract test suite
  that ALL implementations (real adapter in `infra/` AND the stub used in spec tests) must pass.
  Without it, stub and real adapter drift apart and green specs lie about production.

## Done when

- [ ] Contract file type-checks; spec tests fail only on `NotImplementedError` (phase 1) or all pass (phase 2)
- [ ] No prose design doc was produced for this scope
- [ ] Acceptance pytest re-run by the reviewer, not trusted from the worker's report
- [ ] Mutation check run; no surviving mutants on core branches
- [ ] Each new port has a contract test suite that both stub and real impl pass
