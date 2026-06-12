---
name: review-use-case
description: >
  Review and score business use cases. Use when reviewing a Codex-implemented use case,
  scoring an existing application/use_case (or application/services) module against the
  code-as-design contract, or when the user says "review this use case" / "is this service
  compliant". Returns a violation table + verdict (merge / rework / re-spec).
  Skip for writing new use cases (use write-use-case).
---

# Review Use Case

Read `~/.claude/skills/shared/use_case_entity_constraints.md` first; that file is the rulebook —
this skill is only the procedure.

## Procedure

1. Read the use-case file + its spec tests + the diff (if reviewing a Codex delivery, read the FULL diff, not the worker's summary).
2. Run the acceptance pytest yourself. A green report from the worker counts for nothing.
3. Check, in order (each is a named violation):

| # | Check | Violation name |
|---|---|---|
| 1 | spec tests modified/weakened/deleted by the implementer | `SPEC_TAMPERED` (auto-reject) |
| 2 | I/O, DB, HTTP, SDK, clock, RNG inside core methods | `CORE_IMPURE` |
| 3 | events built independently of Output, or shaped like transport replies | `EVENT_DRIFT` |
| 4 | use_case imports/calls another use_case | `UC_COUPLING` |
| 5 | port defined in outbound instead of use-case side | `PORT_INVERTED` |
| 6 | entity anemic, or private to this one use case | `ENTITY_DEGENERATE` |
| 7 | reply mapping / persistence / latency measurement inside core | `CONCERN_LEAK` |
| 8 | stringly errors, wide try/except, trace_id used for idempotency | `CONTRACT_SLOPPY` |
| 9 | unauthorized compatibility layer / fallback added | `STRUCTURE_DISEASE` (stop-and-report per standing rails) |
| 10 | rejection paths or cmd×state matrix uncovered by tests | `SPEC_GAP` |

## Output contract

1. Violation table: `# | name | file:line | one-line evidence` (empty table = state it explicitly).
2. Acceptance command + your own run result, verbatim exit status.
3. Verdict: **merge** / **rework** (list items, ≤2 rounds) / **re-spec** (the spec itself was wrong — route back to write-use-case phase 1; never fix spec drift in the implementation).
