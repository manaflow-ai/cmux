# Snapshot and Refs

Instead of dumping the DOM and guessing selectors, snapshot the page and act on the returned refs (`e1`, `e2`, ...). Related: [commands.md](commands.md), [../SKILL.md](../SKILL.md).

Set `SURFACE` from creation or
[surface discovery](surface-discovery.md) before taking the snapshot.

```bash
cmux browser --surface "$SURFACE" snapshot
cmux browser --surface "$SURFACE" snapshot --interactive
cmux browser --surface "$SURFACE" snapshot --interactive --compact --max-depth 3

cmux browser --surface "$SURFACE" fill e10 "$APP_USERNAME"
cmux browser --surface "$SURFACE" fill e11 "$APP_PASSWORD"
cmux browser --surface "$SURFACE" click e12
```

## Ref lifecycle

Refs are invalidated when page structure changes. Snapshot before interacting, re-snapshot after navigation and modal open/close, and use `--snapshot-after` on mutating actions so the fresh snapshot comes back with the result.

## Troubleshooting

- **`not_found` / stale ref**: take a fresh `snapshot --interactive`.
- **Element missing on visibility or timing**: `wait --selector "#target" --timeout-ms 10000`, or `scroll --dy 400`, then re-snapshot.
- **Too many elements**: scope the snapshot, e.g. `snapshot --selector "form#checkout" --interactive`.
