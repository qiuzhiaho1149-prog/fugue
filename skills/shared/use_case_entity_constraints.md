# Shared constraints: use_case & entity (code-as-design core)

Hard rules shared by the skills `clean-architecture`, `write-use-case`, `review-use-case`.
Every skill that touches core business code MUST load this file first.
If a repo's own lint rules (e.g. a forbidden-dependencies config) conflict, the repo wins — report the conflict, don't silently pick one.

## Layer model

Engineering names (left) and a typical mapping onto a Python service (right — adapt to the live repo):

| Canonical | Clean Architecture | Typical path |
|---|---|---|
| `core.entity` | Entities | `domain/` (pure models + engines, no I/O) |
| `core.use_case` | Use Cases | `application/use_case/` (legacy alias: `application/services/`) |
| `adapter.inbound` | Controllers | `api/` (HTTP routers, CLI, event consumers) |
| `adapter.outbound` | Gateways / Presenters / Repos | `infra/` (DB repos, HTTP clients, publishers) |
| `infra` | Frameworks & Drivers | third-party libs themselves — not a project directory |
| composition root | Main | app factory / DI wiring (`main.py`, app startup) |

## Dependency rules (non-negotiable)

- Source dependency: `inbound -> use_case -> entity`; `outbound -> port <- use_case`; `outbound -> infra`.
- Call flow: `inbound -> executor(use_case) -> outbound -> infra`.
- `use_case` never imports DB / HTTP / SDK / ORM / framework modules. State arrives pre-loaded as `GivenState`.
- `use_case` never calls another `use_case`. Cross-use-case cooperation lives in a higher orchestration layer (composition root / process), never inside a use case.
- `entity` does not know `Command`, does not depend on any `use_case`, and is reusable by many use cases (many-to-one). An entity designed as the private flow-object of a single use case is a violation.
- `entity` must carry domain-semantic methods (invariants, state transitions), not just fields. Anemic field-bags are a violation.
- `inbound` only translates external input into a Command; it carries zero business rules.
- `outbound` only implements ports defined by the use case side; it never defines ports.

## Use-case shape (Python contract)

The canonical contract lives in the skill resource
`~/.claude/skills/write-use-case/references/use_case_contract.py` and, once installed,
in the target repo (single small dependency-free module). The repo copy is the truth;
the skill copy is the seed.

- `role()` — business-game actor (the "role" of four-color domain modeling), used for authz + audit. Never a framework/module name.
- `pre_check_command(cmd)` — cheap checks on the command alone. Raises a typed domain error.
- `validate_against_state(cmd, state)` — business invariants that need loaded state.
- `compute_output_and_events(cmd, state) -> UseCaseOutput` — the core method:
  - `output` is a typed, pure business result reusable in-process.
  - `events` are replayable domain facts, **derived from output** — never a second independent derivation, never transport replies.
  - Deterministic for the same `(cmd, state)`. No wall clock, no RNG, no I/O inside. Time enters as a field of `cmd` or `state`.
- Idempotency key is `command_id` (stable across retries). `trace_id` is observability-only — never use it for dedup.
- `party_id` belongs to the business command, not to `CommandMeta`.

## What stays OUT of the use case

- load/persist/replay/publish → outbound port implementation (`load_state`, `persist_and_publish`).
- mapping events to HTTP/API replies → `ReplyMapper` in adapter layer.
- latency measurement, tracing spans → executor.
- wide `try/except` swallowing errors → forbidden everywhere, doubly so in core.

## Ports

- A port `Protocol` is owned by the use-case side; every implementation (real adapter, in-memory
  stub, test double) must pass the SAME contract test suite, shipped next to the port definition.
  A stub that only satisfies the spec tests but not the port contract is a drift source.

## Two tracks: research vs delivery (spec mutability)

- **Delivery track** (use cases shipping behavior): spec is FROZEN once committed; behavior change
  = new reviewed spec commit first. All rules in this file apply.
- **Research track** (hypotheses, factors, measurements): the spec equivalent is a pre-registered
  **hypothesis card** — claim, falsification criterion, measurement procedure (the ruler), and
  expiry — committed BEFORE the experiment runs. Cards are versioned-mutable via a supersedes
  chain, never edited in place after results exist (that is p-hacking by git).
- **Promotion gate** is the only door between tracks: a hypothesis becomes a delivery-track use
  case only with evidence pointers attached; any constant in a `GivenState`/threshold that came
  from research must cite its evidence file. No promotion without a surviving falsification
  attempt. Refuted cards stay in the ledger — they are the highest-value entries.

## Code-as-design discipline (anti-drift)

- The use-case file (types + spec tests) IS the design document. Do not write a parallel markdown
  design doc for use-case-scoped work; prose docs drift, executable specs don't.
- Any behavior change starts by changing the spec test, then the implementation.
- Work orders to executors (Codex) reference the contract file by `path:line` + "make these tests pass";
  they never restate the business rules in prose.
