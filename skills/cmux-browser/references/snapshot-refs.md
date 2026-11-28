# Snapshot and Refs

Instead of dumping the DOM and guessing selectors, snapshot the page and act on
the returned refs (`e1`, `e2`, …). Related: [commands.md](commands.md),
[../SKILL.md](../SKILL.md).

Set `TAB` from creation or [surface discovery](surface-discovery.md) first.

```bash
cmux browser "$TAB" snapshot
cmux browser "$TAB" snapshot --interactive
cmux browser "$TAB" snapshot --interactive --max-depth 3

cmux browser "$TAB" fill e10 "$APP_USERNAME"
cmux browser "$TAB" fill e11 "$APP_PASSWORD"
cmux browser "$TAB" click e12
```

`@e12` works the same as `e12`.

## Ref lifecycle

Refs go stale when the page structure changes. Snapshot before interacting and
again after navigation or a modal opening or closing. There is no
`--snapshot-after`; run `snapshot` as its own command.

## Troubleshooting

- **`not_found` or a stale ref**: take a fresh `snapshot --interactive`.
- **Element not there yet**: waits and scrolling are not supported yet. Take a
  new snapshot later, or report that the element is missing.
- **Too many elements**: scope the snapshot, for example
  `snapshot --selector "form#checkout" --interactive`.
