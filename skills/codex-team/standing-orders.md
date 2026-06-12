---
STANDING ORDERS (auto-appended to every work order; binding; the task-specific order above takes precedence only where it explicitly overrides)

S1. TOOL-INVENTORY FIRST. Before working: inventory the tools actually available in this session (built-ins, MCP servers such as node_repl, repo instruments named in TOOLBOX, anything you discover in the repo). Write a 3-6 line TOOL PLAN mapping subtasks to tools. Prefer existing tools over hand work at every step; a bare manual approach (ad-hoc script, eyeballed arithmetic, raw grep where a structured tool exists) requires a stated reason. Use node_repl for numeric verification instead of mental arithmetic. If an instrument you need is missing or broken: report it; never silently rebuild it inline.

S2. CODE IS TRUTH. Prior audits, design docs, and reports are hints only — re-verify every load-bearing claim against current code at your base commit before acting on it. Recorded performance numbers are presumed unreproducible until reproduced. List every stale claim you correct (high value).

S3. STRUCTURAL RAILS.
- No unauthorized compatibility layers: shims/wrappers/fallbacks exist only when the order explicitly commands one with a named sunset. Default is REPLACE, not wrap. If you feel a wrapper/fallback is needed: STOP and surface — chief-engineer decision.
- Module budgets: one responsibility per module, target ≤300 lines, justify-or-split above 500. No utils.py dumping grounds.
- No duplicated logic: reuse, or supersede-and-delete. Copy-paste-then-diverge is rejected at review.
- Deletion is a deliverable: code you replace dies in the same change set when in scope; net-negative diffs are welcomed.
- Respect the dependency directions declared in the order; add no import that violates them.

S4. GATE DISCIPLINE (signal-path work). No alpha-side gate/threshold/confluence condition without evidence it improves trade-level expectancy; safety clamps exempt. No silent drops: every killed signal records gate id + reason. Gates are declared census entries, never inline ifs.

S5. STUCK PROTOCOL. The same approach failing twice with the same signature = you are in a loop. Breakout: (1) re-read the failure output as DATA — quote the exact line contradicting your assumption; (2) name that assumption; (3) list 2-3 STRUCTURALLY different alternatives (different layer or mechanism, not parameter tweaks) and pick one with a reason; (4) after two structural failures, or >15 minutes on one item: STOP and surface with — approaches tried, verbatim failures, current hypothesis, smallest unblocking question. FORBIDDEN loop exits: weakening/re-marking/skipping a failing gate or test; adding a fallback to route around the failure; deleting the failing assertion; random retries. A surfaced stall costs one round trip; a masked failure costs the program. When in doubt, surface.

S6. HONEST FAILURE HANDLING. A failing test/check you did not cause: verify it fails at your base commit, then report it as pre-existing with that evidence — leave it untouched unless the order says otherwise. Never reclassify, skip, or weaken a shared gate to make your acceptance pass.

S7. TRANSPARENCY REPORT (final message) always includes: Summary; commit hashes; files changed; commands run with acceptance gate outputs verbatim; executed TOOL PLAN (tools actually used; instruments discovered beyond the TOOLBOX); design notes / alternatives considered; RISKS — name the potential damage surface of this change (what could this break, where would it show); stale-doc corrections; pre-existing failures with base-SHA evidence; explicit statement of anything skipped or violating an invariant, with reason; SUGGESTED NEXT TASK (your view of the most valuable next step — advisory, chief engineer decides). Performance/accuracy numbers only from actually executed runs, labeled with their scope (e.g. PRELIMINARY, n=1 day).

S8. SCOPE. Work only within the order's stated scope. Out-of-scope problems you notice go into the report. If an item conflicts with the plan/invariants: STOP and surface BEFORE committing. Commit locally with the ordered prefix; never push.
---
