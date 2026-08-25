# Handles and Identify

Most v2-backed commands accept a UUID, a short ref (`window:N`, `workspace:N`, `pane:N`, `surface:N`), or an index where legacy index-based commands still allow it.

```bash
cmux identify --json                                  # focused topology + caller resolution
cmux identify --workspace workspace:2                 # route relative actions from a known anchor
cmux identify --workspace workspace:2 --surface surface:8

cmux --json --id-format both identify                 # refs plus UUIDs
cmux --json --id-format uuids identify
```

`identify` keeps the server's `focused` context separate from its `caller`
context. With no explicit selector, `caller` is resolved from the calling
terminal. `--workspace <handle>` is an explicit workspace-only caller selector;
it intentionally returns a workspace identity with `surface_*`, `tab_*`, and
`pane_*` fields set to `null`, because a workspace does not identify one unique
surface. Use `--surface <handle>` (optionally with `--workspace`) when a surface
identity is required. Do not use `caller.workspace_ref` from an explicitly aimed
call as the shell's own workspace; use unflagged `cmux identify --json` for that.
