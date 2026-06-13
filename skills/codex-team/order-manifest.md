---
name: order-manifest
role: codex-team work-order schema
tldr: order.json records a worker slug, footprint, dependencies, and acceptance command.
---

```json
{
  "slug": "exec-retry-fix",
  "allowed_paths": ["src/exec/**"],
  "acceptance": "pytest -x",
  "depends_on": [],
  "forbidden_paths": ["src/risk/**"]
}
```

- `slug`: required non-empty worker id matching `^[a-z0-9][a-z0-9-]*$`.
- `allowed_paths`: required non-empty list of non-empty glob strings the worker may touch.
- `acceptance`: required non-empty binary acceptance command.
- `depends_on`: optional list of prerequisite order slugs; defaults to `[]`.
- `forbidden_paths`: optional list of non-empty glob strings the worker must not touch; defaults to `[]`.

Multi-worker dispatch must pass preflight (step 1b) before launch; order.json is the machine-checkable footprint.
