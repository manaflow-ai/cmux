# Device and session catalog

Status: phase-one local contract.

The catalog discovers independent mux sessions. It does not own workspace
trees, terminal processes, live client connections, or frontend focus.

## Identity

`CatalogSessionKey` is `(CatalogDeviceId, CatalogSessionId)`. A local device
uses its durable `MachinePublicId`. A local session uses its durable
`SessionPublicId`. Provider routes use the provider id, scope id, stable
machine id, and an explicit protocol-v1 singleton session id.

The verified resource address is `(MachinePublicId, SessionPublicId)`. It is
separate from the route key because a provider route can exist before a
connection reveals the mux identities. After the first verified connection,
reconnect must produce the same resource address. A name, array index,
hostname, socket path, process id, and owner generation are never identities.

Several route keys can resolve to one resource address. A client can present
one row and retain the other routes as connection fallbacks. One route key
cannot change its verified resource address.

## Local store

The local authority is `catalog.sqlite3` beside `machine-id` in the workspace
state root. Per-session registries cannot list stopped sibling sessions.

The catalog stores:

- the public machine and session ids;
- the registry id;
- one immutable internal owner key;
- a mutable display name;
- exact routing aliases;
- immutable session storage, terminal-host, socket, and remote-state locators;
- deterministic creation order;
- `creating`, `ready`, `deleting`, or `failed` repair state;
- revision and deletion tombstones.

It does not store `running`, process id, owner generation, transport tickets,
credentials, pending switches, or live leases. Running state always needs a
live endpoint probe.

Display names are Unicode labels and can be duplicates. Routing aliases are
case-sensitive exact strings and are unique on one device. New aliases are 1
through 128 ASCII bytes from `[A-Za-z0-9_.:-]`. Import preserves every legacy
`--session` name. An unsafe legacy name also receives a generated safe primary
alias. Rename does not change an owner key, alias, or locator. After deletion,
the exact alias and owner locator can identify a new `SessionPublicId`; the old
row remains a tombstone and cannot become live again.

## Legacy import

Import scans direct child directories only. It ignores files, symbolic links,
terminal-host directories, reset staging, and lock directories because they
do not contain a direct regular `workspace-registry.sqlite3` file.

For each registry, import reads `session_name`, `registry_id`, and
`session_public_id`. It verifies that the directory is the current exact
storage component for the stored name. An old registry without a public
session id is first opened through `WorkspaceRegistry`, outside a catalog
transaction, and then scanned again. Import never mints a replacement id.

The first import order is `main`, then exact alias byte order, then session id.
Filesystem time is not an ordering input. The full import is one transaction.
Duplicate public ids, registry ids, aliases, or locators fail without partial
import. Repeated import is an idempotent identity check.

An interrupted create can leave a complete registry without a catalog row.
The next import adds that registry. An interrupted delete stays `deleting`
while its immutable storage exists. When exact storage is gone, repair writes
one session and alias tombstone revision.

## Owner and endpoint

The selected ownership design is one detached owner process per session. The
catalog can start or stop that exact owner, but it never owns the mux. Several
windows can attach to one owner. Selection or disconnect never sends owner
shutdown.

Before commit, a connector reads public `session.get` from the endpoint and
private `identify`. It requires the expected machine id, session id, registry
id, response request id, matching owner generation, and
`lifecycle_ready=true`. An initial provider route can bind its first verified
resource address. A later mismatch fails closed. A name match is not
sufficient.

Phase one supplies this identity fence as a transport-independent helper. The
independent-owner work will supply the final local socket handoff. This phase
does not change startup and does not add a Sessions user interface.

## Source snapshots

A catalog source publishes a full ordered snapshot with one source id,
generation, revision, devices, sessions, capability flags, and source order.
Change events are invalidations. A consumer fetches a new full snapshot.
The durable local `ready` repair phase maps to an unavailable runtime owner
state until a live endpoint probe succeeds.

Machine provider protocol v1 has no session list. Its adapter publishes one
explicit singleton session for each provider machine. It keeps the provider's
stable machine id and source order. Provider multi-session discovery requires
a later advertised capability. A v1 client must not send that future request.

The mux-local `cmux.protocol/2` contract does not change. `session.list` still
returns only the session owned by that endpoint. A future network catalog uses
a separate `cmux.catalog/1` contract.

## Client state

Descriptors and flat presentation order are process-wide. Committed and
pending selection, saved view state, and live leases are keyed by stable
frontend `WindowId`. Two windows can select different sessions.

A switch keeps the old session visible and attached while the target is
prepared. Commit is valid only for the latest `SwitchIntentId`. Commit gives
geometry authority to the new connection, stores the prior view state, and
returns only the old window lease for release. Failure keeps the old committed
session. Re-selecting the committed session is a no-op. Re-selecting the same
pending session shares the pending intent.

Disconnect keeps last-known rows, flat order, committed selection, and saved
view state. Reconnect resolves the exact catalog key and identity. It never
selects a same-name row or the provider default. Hiding a Sessions column does
not alter a lease.

Client persistence contains last-known descriptors, flat order, committed
per-window selection, saved per-session view state, verified route bindings,
and column visibility. Restored descriptors start unavailable until their
source reconnects. A route binding cannot change its public resource address
or registry id. Persistence never contains a pending intent, live lease,
ticket, credential, process id, or owner generation.

The native cmux workspace row is not a TUI catalog session. A native frontend
can use a presentation route variant keyed by native device and window id.
That rule keeps the existing per-window `TabManager` ownership.

## Deferred integration

The independent-owner change must land before local startup resolves aliases
and attaches through this catalog. Later work will add owner lifecycle calls,
CLI alias resolution, session rows, and a provider session-catalog capability.
This phase does not claim that session switching is visible in the TUI.
