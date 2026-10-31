# Running binary identity

Release tooling queries the exact executable it has already verified:

```sh
./bin/cmux server status --binary-only --json
```

The standalone equivalent is `cmux-server status --binary-only --json`.
This mode runs before server layout, configuration, service or store access.
It needs no home directory, installation or daemon. Ordinary `server status`
keeps its existing response and reader contract.

The schema-1 object has `kind: "cmux.server.binary"`, the running binary's
`version`, its compiled release `target`, and `release_keys`. Each key entry
has its baked `id` and `sha256`: lowercase hex SHA-256 of the raw 32 public
key bytes, not of their hex text. Entries are ordered by ID. An unkeyed build
reports an empty array; runtime environment variables cannot add keys.

These are build facts, not a readiness verdict or an execution grant. A release
gate must first verify the candidate's signed archive and native publisher,
then compare these facts with separately approved version, target and public
roots. Build provenance and publication approval remain separate checks.

This is an operator build-inspection mode of the existing CLI status verb,
not a new server operation. It adds no RPC, MCP tool, palette action, setting,
relay permission or UI text. The output fields and switch are invariant machine
identifiers; no localized human copy is introduced.
