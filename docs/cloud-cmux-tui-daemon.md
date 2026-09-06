# Cloud VMs on the cmux-tui remote daemon

Design for replacing the Go `cmuxd-remote` daemon in Cloud VMs with the
cmux-tui remote daemon, validated by a working transport spike. North star:
every cloud terminal is a
cmux-tui terminal, the macOS app renders it through the Ghostty manual-IO
surface, and any cmux-tui terminal (cloud, ssh, local) can be attached by
dragging it out of the right pane.

## Why replace cmuxd-remote

`daemon/remote/cmd/cmuxd-remote` speaks an ad-hoc protocol on `/terminal`: a
JSON auth frame, then raw PTY bytes, with reattach implemented as a raw-byte
scrollback replay (1 MiB cap) that can begin mid-escape-sequence and corrupt
the client grid. Auth is a lease file the web tier writes into the VM before
every attach. When the daemon restarts, `pty.attach` with
`require_existing=false` silently respawns a fresh shell, which users read as
losing their session. Each provider driver carries its own copy of the
injection and repair logic.

The cmux-tui stack already solves each of these on `main`:

- `cmux-remote` (Rust library, embedded in the single `cmux-tui` binary) runs
  an authenticated daemon over versioned binary frames (`CMXR`, protocol 5,
  48 KiB frames, four lanes with per-lane replay cursors).
- Transport auth is an end-to-end Noise session against enrolled device keys,
  not a bearer token on the socket. The direct-WebSocket listener serves one
  route, `/v1/link`, and rejects any upgrade carrying an `Origin` header.
- Reattach is structured: a dropped carrier resumes within the daemon's
  resume lease (default 120 s) by replaying reliable lanes from the client's
  cursors; beyond the lease, clients resynchronize from terminal snapshots
  (ghostty-vt state: styled rows, cursor, colors, `through_sequence`), never
  from raw byte replay. A daemon restart changes the daemon generation and is
  reported to the client instead of silently handing it a new shell.
- The daemon and the interactive client are the same binary, and the release
  lane (`.github/workflows/cmux-tui-build-package.yml`) already produces the
  needed artifact: a static `x86_64-unknown-linux-musl` build.

## What the spike proved (2026-08-26)

Historical record. The spike ran against a live Blaxel sandbox; Blaxel has
since been removed as a provider (its driver, images, and build scripts are
gone) and Freestyle on the public platform is the default. The transport
conclusions below still describe how every cmux Cloud machine works, but the
Blaxel-specific mechanics are history, not current code:

1. A static musl `cmux-tui` (55 MB stripped, built on a Blacksmith testbox in
   1m47s warm) runs unmodified in a `blaxel/base-image` microVM.
2. Injection works through the same channel `blaxel.ts` uses for
   `cmuxd-remote`: gzip+base64 through the sandbox filesystem API, then a
   decode exec. The encoded payload (~30 MB) exceeds the API body cap, so the
   script uploads 8 MB chunks and concatenates in the VM.
3. `cmux-tui server start --session cloud --remote-ws 0.0.0.0:1337
   --remote-ws-insecure-bind` under the sandbox process supervisor
   (`keepAlive`, `restartOnFailure`) serves `/v1/link` behind Blaxel's TLS.
4. The single exposed HTTPS port works as-is: a private preview for port 1337
   plus a preview token passed as `?bl_preview_token=...`. The Blaxel gateway
   accepts the token as a query parameter, and the Rust dialer
   (`DirectWebSocketProvider`, plain `tokio-tungstenite` connect) passes the
   URL through verbatim, so no header-injection change was needed. Requests
   without the token get 401 from the gateway; requests with it reach the
   daemon.
5. Enrollment over that URL: invitation created in the VM, `remote connect
   --invite-file` from the Mac, approval in the VM, device enrolled.
6. Reconnect with state restored via the snapshot path: spawn a PTY bash over
   workspace RPC, echo a marker, SIGKILL the client, connect fresh, and
   `snapshot-process-terminal` returns the full styled grid with both the
   pre-kill and post-reconnect markers and an advanced `through_sequence`.
   The interactive TUI (`remote connect`) was also driven over the same URL.

An Aug-20 client binary interoperated with a daemon built from `main` tip,
consistent with the protocol-version gate doing its job (both protocol 5).

## Local repro without provider credentials

`scripts/spike-cmux-tui-local.sh` runs the same protocol loop with a local
`server start --remote-ws 127.0.0.1:<port>` process standing in for the VM:
`up` (isolated daemon state, enrollment, approval), `evidence` (spawn PTY
bash over workspace RPC, write a marker, SIGKILL the client link, connect
fresh, assert the new connection's snapshot still carries the pre-kill marker
with an advanced `through_sequence`), `attach` (interactive remote TUI),
`down`. Evidence is self-checking and was verified against a debug build
(2026-08-26, `through_sequence 4 -> 7` across the kill).

One semantic both spike scripts encode: RPC-spawned processes must use
`lifetime: "detached"`. A `workspace`-lifetime process is tied to the
client's workspace lease and is killed when that client's connection drops,
which is exactly the drop the spike (and any cloud client) must survive.
Cloud-owned terminals live in the daemon's cmux-tui session (or detached),
never on a connection-scoped lease.

## Freestyle delivery and state ownership

Freestyle is the only active provider. One pinned
`cmux-tui-x86_64-unknown-linux-musl` artifact is installed by the Freestyle
driver at create or restore time, then started by the snapshot's systemd unit.
The active snapshot and its provenance are recorded in
`web/services/vms/images/manifest.json`. There is no provider-specific daemon
protocol or alternate image selector.

The daemon's remote state dir must live on the persistent volume (the machine's
home; Freestyle runs the daemon as root with `HOME=/root`, so the
HOME-derived default `~/.local/state/cmux/remote` already qualifies. The
non-root layout described below (`CMUX_CLOUD_LAYOUT`) is retained as a seam
but no driver selects it today. This is what lets daemon identity and enrolled
devices survive sandbox resurrection. Session state (`--state`) lives there
too, so workspace layout restores from the journal checkpoint after a daemon
restart. Running processes do not survive a restart, and clients see the
generation change instead of a silent new shell.

On a layout machine, the daemon watches the bindfs home view for mount events.
If the view disappears, the supervisor stops the user daemon and exits with a
restartable failure code. The provider starts the command again, which reruns
the idempotent user setup and repairs the view before selecting the non-root
daemon. If repair fails, it detects the still-mounted `/cmux/home` backing path
and runs the daemon there as root. Active terminals therefore do not continue
writing into the disposable rootfs directory. No provider selects this layout
today; it is kept for a future non-root cloud home.

## State model and synchronization invariants

`CloudVMState.document` is the one canonical local document for the daemon graph.
It stores top-level values and each array row as canonical JSON fragments, with a
stable order list for every collection. This preserves fields that the app does
not know yet and lets a delta replace one row without parsing or re-encoding
unrelated rows. `rawSnapshot` remains a compatibility export, materialized only
when a caller crosses a snapshot or agent-export boundary. The typed workspace,
screen, pane, tab, terminal, browser, agent, and opaque-entity values are
projections of the document. A materialized ID and relationship index is built
with each accepted snapshot and updated only for entities named by an accepted
delta. The index is a cache, excluded from encoded state, and is never an
independent write source. `SurfaceCatalog` stores that state with the derived
surface rows in one main-actor transaction. No sidebar, CLI, or pane keeps a
second remote graph.

Each raw collection also builds a non-persisted identity index at snapshot
boundaries. It maps daemon `id` values and the legacy agent `terminal_id`
relationship to the canonical row key, including rows that still use a
positional storage key. Replacing a row updates the index incrementally, so
steady-state delta lookup is O(1) and snapshot import is O(rows). Duplicate
identities remain a list and fail closed. The compatibility API can scan an
unrecognized alternate field, but no payload field becomes an identity merely
because it happens to contain a string.

The document's collection order preserves snapshot and export order only.
Semantic layout order comes from each row's `index` and relationship IDs. Code
must not infer identity, parentage, or pane placement from JSON array position
when an index is present. The compatibility parser may retain daemon order for
legacy one-shot rows that omit an index; the authoritative state path still
requires complete graph collections before it can publish or mutate state.

The state has an explicit synchronization mode. Current daemons use `journaled`
mode and publish a `(generation, revision)` cursor. A generation change means a
daemon restart or replacement, so revision numbers are never compared across
generations. A delta is accepted only when its generation matches, its
`previous_revision` is the installed revision, its revision is exactly one
higher, and its changes have a complete sequence. Any unknown, malformed, or
out-of-order event triggers one coalesced snapshot repair. Recovery has a finite
budget and exposes an error state when the feed remains incompatible. The link
models recovery as one phase, `healthy`, `recovering`, `exhausted`, or
`snapshot_only`. A valid event does not immediately forgive a failed stream. It
starts a ten-second stability window; only a stream that remains healthy for the
whole window resets the consecutive-failure count. The first exhausted run has
one snapshot-recovery allowance, which starts one final stream without erasing
the spent budget. A later failed run stays exhausted, so routine snapshot
refreshes cannot cause an unbounded spawn loop. A new authenticated connection
is an explicit reset boundary.

The client applies deltas only for resource kinds whose snapshot storage shape
is known. A newly added daemon kind is therefore a synchronization barrier, not
an event the client guesses how to pluralize or identify. The next complete
snapshot still retains that kind losslessly in the document. This fail-closed
choice protects identity and ordering at the cost of one bounded snapshot read
when the daemon grows its schema.

Every mutating RPC returns a `(generation, revision)` receipt when the daemon
supports journaled state. A creation response also returns the exact
`CreatedTerminalPath`, including its terminal, workspace, screen, pane, and tab
ids. The provider keeps that receipt as a transient read-your-write overlay
until an accepted snapshot or delta reaches the receipt. It never edits the
canonical document from the response. This lets an immediate tab rename use
the exact tab id while the event feed catches up, and lets a later authoritative
graph retire the overlay. A generation change retires an old receipt. Agents
see active overlays as `pending_writes`, so they can distinguish a committed
remote mutation that is not yet present in the last graph from a failed write.
An incoming graph from a known older generation is rejected. A graph before a
pending receipt revision is also rejected. A graph at the exact receipt cursor
is accepted only when the named workspace or tab has the requested name. This
receipt fence prevents a delayed or contradictory snapshot from erasing a write
that the daemon already acknowledged. The complete graph is held back in that
case because publishing unrelated new rows beside a stale target would present
one false machine state to agents.

Older daemons may return the same complete graph without a cursor. The app
keeps that graph in `snapshot_only` mode, exports it to agents, and suspends the
event reader. It does not apply deltas or send revision-fenced workspace or tab
renames because their ordering cannot be proven. The machine reports the
upgrade requirement instead of silently losing rows or sending an unsafe write.
An explicit `null` cursor has the same meaning as an omitted cursor. A malformed
non-null cursor rejects the document.

Derived-row work follows an explicit boundary. A title, lifecycle, agent badge,
focus, index, or same-placement tab-name change rebuilds only the affected
resource rows through the materialized joins. A workspace, screen, pane,
relationship, create, delete, move, or content change rebuilds all rows. The raw
graph is committed first in both cases, so a small update and a full update have
the same source of truth. A malformed relationship still rejects the complete
delta and enters bounded snapshot recovery.

Identity is always an ID, never a display name. A persisted
`WorkspaceCloudVMBinding.remoteWorkspaceID` identifies the daemon workspace
behind a local workspace. A persisted surface projection keeps its exact
`remoteTabID`. When old state lacks either value, the app writes only if one
unambiguous placement can be proved. Otherwise it leaves the local edit intact
and reports the remote action as unavailable.

Binding is reconciled by the projection lifecycle, not by one UI entry point.
After a pane is recorded, restored, or moved, the catalog can fill a missing
binding only when all identity-bearing cloud panes point to one
`(machine, remote_workspace_id)` and the local workspace has no local pane.
Cloud displays, port browsers, and pool terminals with no workspace placement
are neutral. A local pane, an ambiguous placement, or two remote workspaces
leaves the workspace unbound. An explicit `workspace.cloud_vm_bind` value stays
authoritative through disconnects and temporary absence of rows. This prevents
an existing-target open, a restore, or a pane move from losing the rename target.

The process-wide `CloudRenameCoordinator` serializes all remote rename writes
for one machine in one lane across windows. Its pending-intent map remains
keyed by `(machine, scope, remote ID)`, so each local projection can retain its
own optimistic label while workspace, exact-tab, and terminal fan-out writes
still respect the daemon's machine-wide revision cursor. `SurfaceCatalog` is
the sole application-level mutation entrypoint; provider methods only perform
the transport operation. Workspace renames use a daemon revision compare-and-set.
`tab rename` changes one tab placement. The explicit `terminal rename`
compatibility operation fans out to every tab placement of a terminal, fences
each write, and compensates only when a fresh revision proves that no other
client changed the completed tabs. A transport failure can still leave a
partial fan-out, so the operation returns an explicit partial-operation error
instead of silently claiming success.

Local owner lookup and projection reconciliation live in the constructable
`CloudWorkspaceRenameService`. `AppDelegate` injects its workspace and tab-manager
environment into the catalog at launch. The service has no static runtime state, and
tests can provide an isolated environment. This keeps `SurfaceCatalog` as the owner
of ordering and accepted state while leaving the executable as the composition root.
The existing `SurfaceCatalog.shared` is retained as a legacy app seam; new rename
state must not add another singleton or bypass the catalog.

Names have an explicit clear value. A non-empty name is a custom label, and an
empty string clears the custom label so the daemon can publish its generated
title again. `nil` means that a caller did not provide a name and is not a
clear request. Workspace names remain non-empty at the app boundary because
the workspace row and local binding use that label as a required identity
display value.

The daemon name is canonical for a projected cloud workspace or tab. A local
user edit is an optimistic intent only while its mutation is pending. A later
accepted remote observation replaces it without echoing another write. Local
aliases would need a separate field and product contract; this design does not
hide an alias inside the daemon-owned title.

The socket rename handlers use one 120-second operation deadline for refresh,
compare-and-set, retry, compensation, and final reconciliation. Each individual
cmux-tui command remains bounded at 30 seconds. A deadline response is therefore
an honest client result, while the canonical graph and the next refresh remain
the authority if an already-running provider command finishes after the client
has timed out.

The local coordinator is not a distributed lock. The backend serializes every
Freestyle tunnel mutation with `cloud_vm_tunnel_enrollment_locks`, keyed by
`(user_id, device_fingerprint)`: enrollment, read-with-attachment-heal, revoke,
and account-cleanup deletion all acquire the same owner-token lease. The lease
expires after ten minutes, renews before and after provider calls, and releases
only when the owner token still matches. A live lease returns a retryable `409`;
missing lease support returns `503`, so a deployment cannot silently run the
old race after code rollout. Apply the migration before deploying the route.
Freestyle tunnel requests use a 60-second provider client timeout, well below
the lease duration. A process paused during an already-running provider request
can still finish that external request after expiry because Freestyle has no
conditional mutation token; the post-call renewal fences all later local writes,
and deterministic tunnel slugs plus idempotent delete/create recovery bound the
remaining drift.

Freestyle is the active provider. A private-network VM is reached through its
VPC address and requires the owner's WireGuard tunnel. The client prefers the VPC
IPv4 address and uses VPC IPv6 when IPv4 is absent. A legacy or public-network VM
is reached through its public IPv6 address. All managed sessions use the direct
`cmux-remote` Noise session on `/v1/link`; Freestyle's scoped SSH proxy is an
unmanaged provider diagnostic path, not a fallback transport. The backend and the
app treat the route as opaque, and the daemon's enrolled device key is the session
authority.

This model keeps all daemon fields available to agents through the redacted
`surface.catalog` export while keeping credentials out of the export. It costs
one immutable graph decode per accepted snapshot and a full rebuild at topology
boundaries. Row-local deltas pay only for the changed fragments and affected
typed rows. Swift copy-on-write still copies collection metadata when a fragment
map changes, but it does not parse or re-encode unrelated row payloads. These
costs are intentional: an unbounded event log would make recovery and export
grow with VM lifetime, while a row cache without one canonical document would
create divergent IDs, stale placement decisions, and unsafe rename targets.

An authoritative snapshot must contain every modeled graph collection, even when
the collection is empty. The client rejects a missing or non-array collection
and requests bounded full-snapshot recovery instead of interpreting absence as
deletion. Unknown top-level collections remain optional and stay in the
canonical document, so protocol growth remains visible without weakening the
graph identity boundary.

### Design decision record

The canonical fragment document is the authority, the typed graph is a
projection, and the ID/relationship index is a cache. Every accepted mutation
updates these three layers in one local transaction. This is the smallest model
that lets an agent inspect unknown future fields, address exact IDs, and apply a
row-local rename without rebuilding the whole VM graph.

The raw collection identity index is part of that cache boundary. It is rebuilt
from canonical bytes after decoding and is never serialized. This makes a
restarted client derive the same lookup behavior from the same document, while
keeping positional legacy rows addressable and rejecting ambiguous identities.

The rejected alternatives are explicit:

- A full JSON blob per delta is simpler, but it parses and encodes every remote
  row for a one-tab rename. That cost grows with unrelated VM state and makes a
  busy VM compete with the UI for CPU.
- An unbounded event log is useful for audit, but it makes recovery and agent
  export depend on VM lifetime. The daemon journal remains the bounded ordering
  source; the client document is the current state, not a second history.
- Separate provider, UI, and agent caches make individual reads look cheap, but
  they allow identity and placement to diverge. Freestyle-specific transport
  code therefore ends at the daemon link, and all consumers read the same
  catalog transaction.
- A linear row scan for every delta is simple, but it repeatedly decodes
  unrelated VM state and makes rename cost grow with the number of rows. A
  separately persisted row index is faster, but it creates a second source of
  truth and can survive a crash out of sync. The derived raw-collection index
  keeps the O(1) lookup and the single-document authority together.

## Lease/auth integration with the attach-endpoint flow

`POST /api/vm/[id]/attach-endpoint` returns
`{transport:"cmux-remote", route, token, expiresAtUnix, session, trustedCarrier}`.
The route is a direct Freestyle private IPv4 address on port 1337 when available,
then private IPv6 for machines with a VPC, or the machine's public IPv6 for legacy
public-network machines.
The provider route token is recorded as a hash in the lease ledger and is not
used as daemon session authentication. Private-network machines are reachable
only when the owner's WireGuard tunnel is active, and that reachability is the
admission: the daemon's cloud listener runs in trusted-carrier mode
(`--remote-ws-trusted-carrier`, or `CMUX_TUI_REMOTE_WS_TRUSTED_CARRIER=1` from
the driver's systemd drop-in), so every link that reaches it is granted carrier
authentication keyed by the client's own key. There is no device enrollment,
no invitation, and no approval on the cloud path. The Noise handshake still
runs for encryption and key binding; only the authorization check changed.
Every other transport on the same daemon (unix, ssh, relay, iroh) keeps the
enrollment model, and plain network evidence on an untrusted listener is still
refused, so the flag is a property of that one listener.

- `route` is a `ws://[address]:1337/v1/link` endpoint. It must never be copied
  into a durable invitation or log. The route posture is read from the VM, so
  changing the private-network feature flag cannot strand an existing VM.
- `trustedCarrier` is true when the machine's daemon serves the trusted
  listener; the Mac then dials `remote connect <route> --carrier`. The endpoint
  brings a daemon from an older bake to the pinned build and restarts it with
  the drop-in, except under a device that is already enrolled there (the
  restart would end its sessions); that device keeps dialing with its stored
  key, and `trustedCarrier` is false for it until the machine is restarted for
  another reason.
- Revocation is the private network's: deleting a Mac's WireGuard peer ends
  every connection from it at once. `POST /cmux-remote/approve` remains as a
  no-op that answers `approved` for older Mac builds and is deleted once they
  have rolled.

The trusted listener is what gives cloud attach one trust layer: the private
network. The right-pane drag UX (below) stays uniform because the daemon still
names every connection by the client's key.

## macOS integration: manual IO instead of a PTY bridge

Today the app bridges `/terminal` into a local PTY by spawning `cmux
vm-pty-connect` as the surface command. The replacement renders remote bytes
directly: the Ghostty manual-IO surface mode
(`GHOSTTY_SURFACE_IO_MANUAL`, `ghostty_surface_process_output`,
`TerminalManualIOWrite.swift`, all on `main` via the ghostty fork) lets the
app feed terminal bytes and receive keyboard/mouse writes without any local
shell.

The `feat-tui-manual-io` branch already implements the pump for the local
daemon case: `cmux attach --terminal <id> --pipe-io` (a renderer-less relay:
stdout carries VT bytes with a full-reset prefix on non-first replays, stdin
takes JSON `{"input"}`/`{"resize"}` lines, exit codes distinguish
terminal-ended from daemon-lost) driven by `TuiManualIOPump.swift` feeding
`TerminalRemoteOutputFeed`. Cloud reuses that contract unchanged: `cmux-tui
remote connect <route> --headless` maintains the authenticated link (with its
own unlimited-attempt reconnect, heartbeats, lane replay, and snapshot
resync) and exposes the standard local control socket; the pump's `attach
--pipe-io` targets that socket. The app never re-implements the remote
protocol, and `cmux-terminal-client` (today iroh-only, C-ABI) can later
subsume the sidecar by adding `ws`/`wss` to its accepted schemes; the
provider machinery it needs is already shared in `cmux-remote`.

## macOS: private-network machines dial through one WireGuard hub

A machine on the owner's private network is reachable only inside the VPC. The
app does not require `cmux vpn up` for that: when the bundled client advertises
`wireguard-hub` (`remote-probe --json`) and the route host is a literal address
inside the tunnel's `AllowedIPs` (before enrollment, inside the RFC 1918 / RFC
4193 private ranges), the link is spawned with `--wireguard-hub <socket>` and
dials through `cmux-tui wg hub`, one process per app that owns the in-process
WireGuard tunnel and serves SOCKS5 on `~/.cmuxterm/wireguard/hub-<pid>.sock`.
Public hosts and older clients dial directly, exactly as before.

The hub has its own tunnel identity (`VMTunnelManager.Identity.app`:
`mac-<uuid>-app`, `app.key`, `cmux-app.conf`), never the `cmux vpn up` key,
because one WireGuard key supports one live session. `CloudWireGuardHub` owns
the lifecycle: the first link starts it (enroll, write config, spawn, wait for
the socket to accept), links hold leases, and it stops 10 s after the last
release. An unexpected exit while leased restarts it with 1/2/4/8/16 s backoff;
the links' own reconnect loops then find the socket again. A `cmux vm tui` pane
execs its own client the app cannot watch, so `vm.cmux_remote_info` pins the
hub for the rest of the app session when it hands that pane a
`wireguard_hub_socket`. Sign-out and revoke stop it; app termination kills it.
`vm.tunnel_status` reports the hub under `app_tunnel`.

## Drag-from-right-pane UX

The right pane gains a "terminals" catalog: for each known daemon
(`remote known-daemons`: the local session, ssh remotes, every cloud VM the
attach endpoint enrolled) it lists live terminals from the daemon's catalog
(`cmux terminal list` over the same authenticated link the pump uses).
Dragging an entry into the split tree creates a manual-IO surface bound to
that terminal: the drag payload is a declared UTType carrying
`(daemon fingerprint, route, terminal id)`; the drop handler ensures a
headless link to that daemon exists, then starts a pump on `attach
--terminal <id> --pipe-io`. Because the payload names a daemon and terminal
rather than a VM, the same drag works for a cloud VM, an ssh box, and another
local cmux-tui session; "arbitrary cmux TUI terminals" falls out of the
shared catalog rather than a cloud-specific feature. Multi-attach is safe:
daemon-side terminals accept multiple attachments and size to the minimum
grid, matching current cmuxd-remote semantics.

## Rollout status

Cloud machine opens now require the cmux-tui daemon. The app does not retry
through public WebSocket or SSH transport when the private cmux-tui link fails.
Provider migration must deploy cmux-tui before the provider is enabled for users.

Remaining rollout work is operational: run authenticated preview and staging
create/attach/browser-proxy smoke after each deployment, measure Vercel create
duration, rotate provider credentials, and finish browser-proxy and cleanup
hardening. These checks must use the Mock provider in ordinary CI and the real
Freestyle provider only in the explicit staging smoke job.

The live provider smoke does not replace the client route check. A tagged Mac
must have its owner's WireGuard tunnel up before a private VM can be opened. If
the route is down, the catalog keeps the VM visible with an explicit link error
and does not issue rename writes. The rollout record must keep this client check
separate from API create/attach success.


## Cloud tree and agent routing (2026-09-02)

The right sidebar's Cloud tab and the CLI share one view of a machine, built
from the daemon's own session model rather than a cloud-specific catalog:

```
<machine>                        status · memory · disk · link
  workspaces/                    one machine, many cmux-tui workspaces
    <name>  ws_…  *              cmux-tui workspace (focused marked *)
      ● term_…  <title>  <cwd>  [agent claude running]  (open: surface:3)
    <name>  ws_…                 another workspace on the same machine
  ports/
    3000  http                   forwarded port (Mac-side synthetic node)
  VNC Displays/
    ● display:1  Desktop  noVNC  (cmux surface open <machine>/display/display:1)
  terminals/                     every terminal resource the machine owns
    ● term_…  <title>             terminal shown in a workspace
    (detached — …)               live terminal in no workspace's layout
      ● term_…  <title>
```

A machine is the big box and its workspaces are rows under it, never machines
of their own. The sidebar's Cloud tab renders the same order as four groups:
the machine's Workspaces group first (always its own row, with a ＋ that is
`cmux vm workspace new`; an empty machine shows "No workspaces yet" under it;
a workspace folder is exactly its layout — a terminal whose tab closed is gone
from it), then Ports, VNC Displays (one row per screen), and last, its own
Terminals section (every terminal resource the machine owns, always present;
live zero-view ones are greyed as "detached"). Exited records with stale,
unresolved tab ids remain ordinary exited rows rather than being called detached.

The app keeps one headless `cmux-tui remote connect --headless` link per
awake machine and reads `session current snapshot --json` plus the
`session current events --jsonl` stream over that link's local socket; the
tree is push-updated, with a bounded full-snapshot repair for a cursor gap or
unknown event. Desktop and ports are Mac-owned nodes backed by
`vm.desktop_open` and `vm.port_open`.

VNC display and forwarded-port rows are provider-backed catalog resources
outside a workspace's terminal layout. Their open verbs use the shared
`surface.project` path and the same tokened browser-pane flow.

The remote graph is keyed by stable daemon IDs. A resource may have several
`remote_views`, so a terminal shown in two tabs is represented twice with
`workspace_id` and `tab_id`, while the terminal identity stays one resource.
The catalog exports its cursor, `sync_mode`, and freshness state. A stale graph
can be rendered for diagnosis but cannot authorize a new open or rename. A
`snapshot_only` graph can be opened for inspection, but rename commands return
an upgrade error until a journaled daemon snapshot is available.

Socket methods (the CLI, the sidebar tree, and agents all go through them):

| Method | Params | Result |
| --- | --- | --- |
| `vm.tree` | `{id?, refresh?}` | `{machines: [{id, status, image, has_desktop, memory_mb?, disk_mb?, link_state, remote_workspaces?}], cloud_states: [{machine, sync_mode, cursor?, freshness, pending_writes?}], resources: [{id, machine, kind: terminal\|display\|browser, key, title, detail?, lifecycle, agent?, remote_workspace?, remote_views: [{tab_id, workspace: {id, name, index, focused}, screen_id?, pane_id?, name?, index?, focused?}], port?, url?, open_surface_ids}], projections: [{resource, workspace_id, panel_id}]}`. The renderer orders each machine as Workspaces, Ports, VNC Displays, then Terminals; empty workspaces and exact multi-tab placements remain visible. |
| `vm.terminal_open` | `{id, terminal_id, remote_workspace_id?, remote_tab_id?, workspace_id?, placement?, focus?}` | `{surface_id, workspace_id, reused}` — exact remote placement is preserved; an existing pane with the same IDs is focused instead of duplicated |
| `vm.terminal_new` | `{id, workspace_id?: ws_…, command?: [string], cwd?, name?, open?}` | `{terminal_id, workspace_id, surface_id?}` — a detached terminal in the machine's session |
| `vm.desktop_open` | `{id, workspace_id?, focus?}` | `{surface_id, url}` |
| `vm.port_open` | `{id, port, workspace_id?}` | `{surface_id, url}` |
| `vm.link_socket` | `{id}` | `{socket_path, session}` — the headless link's local mux socket |
| `vm.tab_rename` | `{id, tab_id, name}` | Renames one exact remote tab placement and publishes the resulting daemon event. `name: ""` clears its custom label. |
| `vm.terminal_rename` | `{id, terminal_id, name}` | Explicit compatibility fan-out that renames every tab view of one terminal. `name: ""` clears the custom label on every view. |

CLI addresses are the tree's lines: `cmux vm tree`, then
`cmux vm open <machine>[/<ws>[/<term>]]`, `cmux vm open <machine>:desktop`,
`cmux vm open <machine>:port/<n>`. A workspace name is accepted only when it
is unique; IDs always win. A terminal opens locally as a pane running
`cmux-tui attach --terminal <term_…>` against the link socket, with the exact
remote workspace and tab IDs retained in the projection.

Agents route work with the same primitives: `cmux vm route` prints the machine
`vm run` would choose (sticky per directory → idle pool machine → sleeper →
provision) without running anything; `cmux vm agent --agent <claude|codex|opencode|pi>
-- <prompt>` starts the agent as a detached terminal in the chosen machine's
session (so it survives the pane and reattaches from any device); `cmux vm run`,
`exec`, `push`/`pull`, and `wait` stay the headless verbs. CodeRouter is
orthogonal: it routes model credentials, not compute, and is configured inside
the machine the same way as locally. The `skills/cmux-cloud-vm` skill teaches
this policy to Claude Code, Codex, OpenCode, and Pi.

## Surface catalog

Terminals, VNC screens and browsers are *resources*; panes and workspaces are
*projections* of them. On the Mac, `SurfaceCatalog` (`Sources/Surfaces/`) is the
one owner of resource identities (`<machine>/<kind>/<key>`, machine = `local` or
a cloud machine id) and projections (resource, workspace, panel). Providers push
resources in: `LocalSurfaceProvider` (this Mac's terminals and browsers) and one
`CmuxTuiSurfaceProvider` per cloud machine (its cmux-tui workspaces/terminals
from the headless link, its noVNC screen `display:1`, its forwarded ports).
`catalog.project(resource, into:)` is the single open path — the sidebar tree,
drag and drop, the CLI and agents all go through it — so an already-open
resource is focused instead of duplicated, a closed pane never destroys a
remote resource, and restored panes re-project when their provider reports the
resource again.

Socket (worker lane, like `vm.*`):

| Method | Params | Result |
| --- | --- | --- |
| `surface.catalog` | `{machine?: "local"\|<id>, refresh?}` | `{machines: [{id, local, name, status, image, has_desktop, memory_mb, disk_mb, link_state, link_error, cpu_percent, memory_used_mb, disk_used_mb}], resources: [{id, machine, kind, key, title, detail, lifecycle, agent?, remote_workspace?, port?, url?, open, open_surface_ids, open_workspace_ids}], projections: [{resource, workspace_id, surface_id}]}` |
| `surface.project` | `{resource, workspace_id?, pane_id?, direction?: left\|right\|up\|down, tab_index?, placement?: split\|tab, focus? (true), reuse? (true)}` | `{surface_id, workspace_id, reused, resource}` — `pane_id` + `direction` splits that pane on that side; `pane_id` + `tab_index`/`placement: tab` tabs into it; else the workspace's focused pane |
| `surface.new_terminal` | `{machine, command?: [string], cwd?, name?, remote_workspace_id?, open? (true), + the destination params}` | `{resource, terminal_id, machine, remote_workspace_id, workspace_id?, surface_id?}` |

The `vm.tree`, `vm.terminal_open`, `vm.terminal_new`, `vm.desktop_open`,
`vm.port_open` and `vm.link_socket` verbs keep their shapes and are wrappers
over the same catalog (`vm.tree` is the catalog restricted to cloud machines;
`vm.desktop_open` projects `<id>/display/display:1`; `vm.port_open` projects
`<id>/browser/port:<n>`, registering the port first when the probe has not
seen it). CLI: `cmux surface ls|open|new-terminal` and `cmux vm tree|open`.
