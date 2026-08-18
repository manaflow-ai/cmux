# Machine Provider Aggregation

This document specifies how one cmux-tui client presents machines from several
providers in the machines column at the same time. It extends
[Machine Provider Contract](machine-provider.md).

## Problem

The machines column is the leftmost native rail, and `sidebar.views` selects it
by default. The catalog behind that column supports exactly one source. The
client rejects more than one of `--machine-provider`,
`--machine-provider-command`, and `--cloud`, and it refuses a static `machines`
array together with a socket or command provider. The only composition that
exists is a special case that stacks the static v0 catalog over one v1 cloud
catalog, using a hardcoded key split at `2^63`.

A user with SSH remotes and several sandbox vendors therefore has to choose one
source per launch.

## Scope

Aggregation is a client concern. The wire contract does not change: every
provider still speaks `machine-provider-v1`, negotiates its own version, and
owns its own bearer. This document adds a client-side registry, a key
namespace, per-provider failure isolation, and provider-scoped capabilities. A
provider written against the existing contract works unchanged under an
aggregating client.

## Provider registry

`~/.config/cmux/cmux-tui.json` gains an ordered `machine_providers` array:

```json
{
  "machine_providers": [
    {"id": "ssh", "kind": "builtin-ssh", "name": "SSH"},
    {"id": "cloud", "kind": "ssh", "name": "cmux Cloud", "host": "cmux.cloud"},
    {
      "id": "e2b",
      "kind": "command",
      "name": "E2B",
      "command": ["cmux-provider-e2b"],
      "env_passthrough": ["E2B_API_KEY"]
    },
    {"id": "lab", "kind": "unix", "socket": "/run/cmux/provider.sock"}
  ]
}
```

`id` is stable, matches `[a-z0-9-_]+`, and must be unique. It names the provider
in state paths and diagnostics. `kind` is one of `builtin-ssh`, `unix`,
`command`, or `ssh`, matching the existing connectors.

`env_passthrough` is an allowlist of variable names, never values. A provider
process starts with a minimal environment plus exactly those inherited
variables. API keys stay in the user's environment or in the provider's own
credential file. They never enter `cmux-tui.json`, the client, or diagnostics.

Compatibility: an enabled `machine_provider.cloud` desugars into one `kind:
"ssh"` entry with id `cloud`. A `machines` array desugars into the
`builtin-ssh` provider. `--machine-provider`, `--machine-provider-command`, and
`--cloud` each append one process-local entry instead of selecting the single
mode, so the mutual-exclusion error is removed. Explicit `machine_providers`
plus legacy keys is an error, because the intended order would be ambiguous.

## Key namespace

`MachineKey` stays a process-local `u64` that is never persisted. Its layout
becomes a slot in the high 16 bits and a per-provider ordinal in the low 48
bits. Slot 0 is reserved for the built-in current-session entry, so the local
machine keeps its position at the top of the column. Slots 1 upward follow
registry order. This replaces the `2^63` overlay split.

Reconciliation across snapshots uses the pair of slot and provider-stable id.
Two providers may return the same opaque id, and the slot keeps them distinct.

## Isolation

Each registry entry owns one control generation, one bearer, one connector, and
one private SSH control directory. Failure is contained:

- A provider that cannot connect renders its own group with an error row. Other
  groups still render, and the client still attaches machines from them.
- `snapshot_changed` invalidates only the emitting provider. The aggregator
  refetches that provider's snapshot and leaves the others untouched.
- A control timeout, a disconnect, or a decode failure drops one generation.
  The aggregator retries that entry with a bounded backoff.
- One slow provider must not delay the first paint. The column renders each
  group as it arrives.

## Capabilities and actions

Capabilities are per provider today but are read as if they were global. The
aggregator scopes them: capability checks, provider actions, scopes, and
lifecycle mutations resolve through the slot of the row they act on. The footer
shows the union of enabled creation and connection actions, and each entry
routes to its own provider. An action from one provider can never be sent to
another.

Exactly one machine is attached at a time, because `RemoteSession` is single.
The aggregator holds one active key, so at most one provider has an active
machine.

## Presentation

The column groups rows by provider, in registry order, with the provider `name`
as a group header. A registry with one entry renders without a header, so a
single-provider setup looks exactly as it does today. Group headers collapse.
Rows keep the existing status, subtitle, and rename behavior.

## SSH as a provider

The static v0 catalog becomes a built-in provider behind the same client-side
trait as the wire client, so the aggregator has one code path. It keeps
`~/.ssh/config` discovery including `Include` following, keeps wildcard and
negated pattern omission, keeps process-local temporary targets, and implements
the footer through `connect_external_machine`. It does not serialize to JSON,
because it runs in process.

The v0 name is retained in [Machine Provider Contract](machine-provider.md) for
the historical record. After this change there is one provider abstraction.

## State ownership

Session state lives in the sandbox. `open_machine` returns a one-use ticket, and
that transport becomes an ordinary protocol-v12 stream for `RemoteSession`, so
the headless mux runs on the machine and owns its workspaces, panes, scrollback,
and journal. A provider that can attach persistent storage must place the mux
`--state-dir` on it, so a stop and start preserves the journal.

Catalog state lives in the vendor. A provider derives its snapshot from the
vendor's list operation on every refresh, and it tags the sandboxes it creates
through vendor metadata or labels. It must filter to its own tag, and it must
never act on an untagged row, because those accounts hold sandboxes owned by
other work.

Tombstones are the one exception and already exist in the contract. When a
vendor reclaims a sandbox, the machine becomes recoverable rather than absent,
through `machine_lifecycle_snapshot`, `restore_machine`, and `purge_machine`.
That record is the only client-side state, and it lives under
`~/.local/state/cmux/machine-providers/<id>/`.

Credentials live in the provider process only.

## Guest requirement

A machine is connectable only when it runs a cmux-tui whose protocol matches the
client. A provider satisfies this in one of two ways:

1. It bakes the pinned cmux-tui into its vendor template, snapshot, or image.
   This is the fast path, and the image tag moves with each cmux release.
2. It falls back to the existing probe. `remote-probe --json` reports a missing
   or incompatible binary, and `SshBootstrapConfig` installs the pinned npm
   build at `~/.local/bin/cmux-tui`. Installation is gated on
   `CMUX_TUI_NPM_BOOTSTRAP_VERSION`, so packaged releases self-install and
   source builds refuse.

A provider reports a machine whose guest cannot be made compatible as
`unavailable` with a subtitle, instead of failing at attach time.

## Distribution

`cmux-plugin.toml` accepts `kind = "machine-provider"` in addition to
`kind = "sidebar"`. Install, name validation, build, and the executable check are
unchanged. A machine-provider install writes its resolved absolute command into
a `machine_providers` entry instead of `sidebar.plugin`. One manifest format and
one installer then cover both plugin kinds.

## Security

A provider process is a trust boundary. The client passes it no cmux
credentials, no other provider's bearer, and no environment beyond the
allowlist. Bearer values, external-machine specifiers, and mux authorities stay
redacted in diagnostics, per the base contract. A provider cannot enumerate or
address another provider's machines, because keys are slot-scoped and every
request routes through the owning entry.
