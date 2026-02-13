# Snapshot and Refs

Element refs from snapshots make browser automation compact and reliable.

**Related**: [commands.md](commands.md), [SKILL.md](../SKILL.md)

## Contents

- [How Refs Work](#how-refs-work)
- [The Snapshot Command](#the-snapshot-command)
- [Using Refs](#using-refs)
- [Ref Lifecycle](#ref-lifecycle)
- [Best Practices](#best-practices)
- [Troubleshooting](#troubleshooting)

## How Refs Work

Classic flow:

```text
full DOM/HTML -> selector guessing -> action
```

cmuxterm flow:

```text
snapshot -> refs (e1/e2/...) -> direct action
```

## The Snapshot Command

```bash
cmuxterm browser surface:7 snapshot
cmuxterm browser surface:7 snapshot --interactive
cmuxterm browser surface:7 snapshot --interactive --compact --max-depth 3
```

## Using Refs

```bash
cmuxterm browser surface:7 click e6
cmuxterm browser surface:7 fill e10 "user@example.com"
cmuxterm browser surface:7 fill e11 "password123"
cmuxterm browser surface:7 click e12
```

## Ref Lifecycle

Refs are invalidated when page structure changes.

```bash
cmuxterm browser surface:7 snapshot --interactive
# e1 is "Next"

cmuxterm browser surface:7 click e1

# page changed, take a fresh snapshot
cmuxterm browser surface:7 snapshot --interactive
```

## Best Practices

1. Snapshot before interacting.
2. Re-snapshot after navigation/modal/open-close flows.
3. Use `--snapshot-after` on mutating actions.
4. Scope snapshots with `--selector` for very large pages.

## Troubleshooting

### not_found / stale ref

```bash
cmuxterm browser surface:7 snapshot --interactive
```

### Element missing due visibility/timing

```bash
cmuxterm browser surface:7 wait --selector "#target" --timeout-ms 10000
cmuxterm browser surface:7 scroll --dy 400
cmuxterm browser surface:7 snapshot --interactive
```

### Too many elements

```bash
cmuxterm browser surface:7 snapshot --selector "form#checkout" --interactive
```
