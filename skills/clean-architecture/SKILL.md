---
name: clean-architecture
description: >
  Clean Architecture Q&A and review. Use when the user asks about architecture design,
  code layering, refactoring, dependency management, tech-stack choices, over-engineering,
  module placement, dependency direction, interface/port design, component boundaries, or
  decoupling. Use for: layering review, dependency-direction analysis,
  where-does-this-module-belong, over-engineering detection, minimal restructuring advice.
  Answers always use the core / adapter / infra vocabulary mapped onto the actual repo layout.
---

# Clean Architecture

> Purpose: answer every architecture question in `core / adapter / infra` terms while keeping
> Clean Architecture dependency rules exact — grounded in the repo's REAL current layout, never a remembered snapshot.

## Before answering

1. Read `~/.claude/skills/shared/use_case_entity_constraints.md` (the hard rules; do not restate them from memory).
2. Ground in the live repo — check the actual structure of whatever service is under discussion:
   ```bash
   find <service>/src -maxdepth 4 -type d | sort
   ```
   Map onto the existing convention (commonly `api/ → application/ → domain/ → infra/` per service,
   often with import discipline in a lint config); do not invent a parallel tree.

## Design rules

1. Express everything in three layers: `core` (`use_case` + `entity`), `adapter` (`inbound` + `outbound`), `infra`.
2. `workflow` = a grouping boundary under `use_case` for one business line
   (e.g. `application/use_case/billing/`, `application/use_case/ingest/`).
   A workflow is NOT a use case and NOT cross-use-case orchestration code.
3. Translate legacy names before reasoning: `controller` / `service` / `repository` / `model` /
   `business layer` / `data layer` / `infrastructure` are implementation patterns, not layers —
   identify their real architectural role first. `application/services/` directories are
   use cases (or fat orchestration that should be split into use cases).
4. When microservices / Kafka / Redis / K8s / extra abstraction layers come up, apply in order:
   **Question → Delete → Simplify → Accelerate → Automate**. Most additions die at Delete.
5. Context check: before recommending an audit checklist or layering, determine the domain context
   (data frequency, criticality, the component's role — e.g. ingest vs decision vs execution) — defaults differ.

## Output contract

Answer in this order, every time:

1. **Layer Mapping** — Core (`use_case` / `entity` split out) / Adapter (`inbound` / `outbound` split out) / Infra, with real file paths.
2. **Architecture Views** — responsibility view, source dependency view, call flow view. If violated, name WHICH view is confused.
3. **Violations** — mandatory checks:
   - core importing DB / HTTP / SDK / ORM / framework
   - `use_case` calling `use_case`
   - entity as a single-use-case private flow object (breaks many-to-one)
   - anemic entity (fields only, no domain-semantic methods)
4. **Minimal restructuring advice** — the smallest move that satisfies the current goal. Never a big-bang rewrite; respect active exec-plans (check `docs/exec-plans/` or equivalent for in-flight work before proposing moves).

## Testing placement

- `core/use_case`: unit tests, outbound ports stubbed, no I/O, <10ms. Live next to the use case (`tests/use_case/test_<workflow>_<use_case>.py`).
- `core/entity`: pure rule/invariant tests — cheapest, most numerous.
- `adapter/inbound`: input-translation tests (HTTP → Command parse/validate).
- `adapter/outbound`: port-implementation integration tests (testcontainers / in-memory DB).
- `infra`: no dedicated tests — covered indirectly via outbound integration + e2e.
- Pyramid: unit 70% / integration 20% / e2e 10%.

## Done when

- [ ] Output contract order followed
- [ ] No rule in the shared constraints file violated by the advice itself
- [ ] Advice is minimal restructuring, anchored to real `file:line`, deconflicted with active exec-plans
