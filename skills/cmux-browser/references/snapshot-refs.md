# Snapshot and Refs

Instead of dumping the DOM and guessing selectors, snapshot the page and act on the returned refs (`e1`, `e2`, ...). Related: [commands.md](commands.md), [../SKILL.md](../SKILL.md).

```bash
cmux browser surface:7 snapshot
cmux browser surface:7 snapshot --interactive
cmux browser surface:7 snapshot --interactive --compact --max-depth 3

cmux browser surface:7 fill e10 "user@example.com"
cmux browser surface:7 fill e11 "password123"
cmux browser surface:7 click e12
```

## Ref lifecycle

Refs are invalidated when page structure changes. Snapshot before interacting, re-snapshot after navigation and modal open/close, and use `--snapshot-after` on mutating actions so the fresh snapshot comes back with the result.

## Troubleshooting

- **`not_found` / stale ref**: take a fresh `snapshot --interactive`.
- **Element missing on visibility or timing**: `wait --selector "#target" --timeout-ms 10000`, or `scroll --dy 400`, then re-snapshot.
- **Too many elements**: scope the snapshot, e.g. `snapshot --selector "form#checkout" --interactive`.
