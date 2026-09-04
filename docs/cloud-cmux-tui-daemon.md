# Cloud VMs on the cmux-tui remote daemon

Design for replacing the Go `cmuxd-remote` daemon in Cloud VMs with the
cmux-tui remote daemon, validated by a working transport spike. North star:
every cloud terminal is a
cmux-tui terminal, the macOS app renders it through the Ghostty manual-IO
surface, and any cmux-tui terminal (cloud, ssh, local) can be attached by
dragging it out of the right pane.

## System boundary

The daemon is the Cloud data-plane component. It owns authenticated remote
links, workspaces, terminals, processes, event lanes, replay cursors, and
terminal snapshots. It does not own account login, team policy, billing,
machine lifecycle, DNS, TLS, or CodeRouter account management.

Those control-plane responsibilities belong to the Rust Cloud client and the
versioned contract in
[docs/cloud-rust-system-design.md](cloud-rust-system-design.md). The desktop
app may project the same resources into panes, but a Cloud CLI or agent can
use the control and data planes without opening the app. Every attach token
or route is scoped by the control plane to a stable machine, session, and
machine-generation fence before the daemon accepts it.

The implementation sequence and compatibility obligations are in
[plans/feat-cloud-rust-cli/DESIGN.md](../plans/feat-cloud-rust-cli/DESIGN.md).

Machine creation is optimized outside the daemon protocol. The control plane
claims a scrubbed warm image, starts one daemon-ready probe, and returns the
machine route without a discovery round trip. A cold image returns an operation
immediately. The daemon only reports readiness and transport state;
it does not decide billing, placement, or account policy.

## Why replace cmuxd-remote

`daemon/remote/cmd/cmuxd-remote` speaks an ad-hoc protocol on `/terminal`: a
JSON auth frame, then raw PTY bytes, with reattach implemented as a raw-byte
scrollback replay (1 MiB cap) that can begin mid-escape-sequence and corrupt
the client grid. Auth is a lease file the web tier writes into the VM before
every attach. When the daemon restarts, `pty.attach` with
`require_existing=false` silently respawns a fresh shell, which users read as
losing their session. Duplicated deployment drivers used to carry their own
copy of the injection and repair logic; the new boundary centralizes it.

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

Historical record. The spike ran against a temporary sandbox and a
deployment-specific image. Those mechanics are retired. The transport
conclusions below still describe how every cmux Cloud machine works, while the
image and gateway details are intentionally implementation-neutral:

1. A static musl `cmux-tui` (55 MB stripped, built on a Blacksmith testbox in
   1m47s warm) runs unmodified in a Cloud microVM.
2. Injection works through the sandbox filesystem API: gzip+base64, followed by
   a decode exec. The encoded payload (~30 MB) exceeds the API body cap, so the
   script uploads 8 MB chunks and concatenates in the VM.
3. `cmux-tui server start --session cloud --remote-ws 0.0.0.0:1337
   --remote-ws-insecure-bind` under the sandbox process supervisor
   (`keepAlive`, `restartOnFailure`) serves `/v1/link` behind the managed TLS
   edge.
4. The single exposed HTTPS port works as-is: a private preview for port 1337
   plus a short-lived query token. The managed gateway accepts the token, and
   the Rust dialer
   (`DirectWebSocket`, plain `tokio-tungstenite` connect) passes the
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

## Local repro without deployment credentials

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

## Deployment image and daemon rollout

One artifact replaces `cmuxd-remote-linux-amd64` everywhere:
`cmux-tui-x86_64-unknown-linux-musl` from the existing package lane, pinned by
sha256, from the artifacts manifest. The managed image uses a systemd unit in
the VM snapshot running the `cmux-devbox-boot` supervisor, with the pinned
binary baked at `/root/.cmux/bin/cmux-tui`. If the image is a memory image, the
supervisor binds daemon identity to the instance identity and mints a fresh
identity on a clone. The bake parks the daemon before snapshotting so no live
identity is shared. Create therefore runs no guest bootstrap. Older image
paths used their own template entrypoints; they are not part of the contract.

The daemon's remote state dir must live on the persistent volume (the machine's
home; the managed image runs the daemon as root with `HOME=/root`, so the
HOME-derived default `~/.local/state/cmux/remote` already qualifies. The
non-root layout described below (`CMUX_CLOUD_LAYOUT`) is retained as a seam
but no driver selects it today.)
so daemon identity and enrolled devices survive sandbox resurrection. Session
state (`--state`) lives there too, so workspace layout restores from the
journal checkpoint after a daemon restart; running processes do not survive a
restart, and clients see the generation change instead of a silent new shell.

On a layout machine, the daemon watches the bindfs home view for mount events.
If the view disappears, the supervisor stops the user daemon and exits with a
restartable failure code. The supervisor starts the command again, which reruns
the idempotent user setup and repairs the view before selecting the non-root
daemon. If repair fails, it detects the still-mounted `/cmux/home` backing path
and runs the daemon there as root. Active terminals therefore do not continue
writing into the disposable rootfs directory. The layout is kept for a future
non-root cloud home.

## Lease/auth integration with the attach-endpoint flow

`POST /api/vm/[id]/attach-endpoint` today returns
`{transport:"websocket", url, headers, token, session_id, ...}` where `token`
is a single-use lease the web tier wrote into the VM. With the cmux-tui
daemon the endpoint returns `{transport:"cmux-remote", route, invitation?}`:

- `route` is the tokenized preview URL
  (`wss://<preview-host>/v1/link?bl_preview_token=<token>`). The preview
  token keeps its current minting and TTLs (12 h attach, 7 d open-port) and
  its current role: it gates who can reach the listener at all. It is not the
  session auth. Invitation route hints must be credential-free
  (`credential_free_route_hints` rejects them), so the tokenized URL travels
  only in the endpoint response, never inside an invitation.
- `invitation` is present only when this client device is not yet enrolled
  with this VM's daemon. The endpoint execs `remote enroll create --ttl 300`
  in the VM (exactly where it writes lease files today) and returns the
  single-use `cmux://enroll/...` URI. The control plane then approves the
  pending enrollment it just invited: poll `remote enroll pending` and
  approve the matching `invitation_id`, which is what the spike script does.
  A follow-up in cmux-remote makes this a non-racy single step: an
  owner-created invitation with approval pre-granted (`approval_required` is
  currently hardcoded `true` in `identity.rs`; the cloud control plane is the
  owner, so pre-approval is the honest encoding of "the web tier already
  authenticated this user").
- After first enrollment the device key lives in the Mac's client state and
  reattach needs only the fresh route. Revocation maps to the existing
  ledger: revoking an attach revokes the device (`remote enroll revoke`) and
  the preview token.

Per-VM daemon identity plus per-user device keys give cloud attach the same
model as every other cmux-tui remote (ssh, iroh, relay), which is what makes
the right-pane drag UX (below) uniform.

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
transport machinery it needs is already shared in `cmux-remote`.

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
shared resource catalog rather than a cloud-specific action. Multi-attach is safe:
daemon-side terminals accept multiple attachments and size to the minimum
grid, matching current cmuxd-remote semantics.

## Rollout

Phase 1: ship the cmux-tui daemon alongside cmuxd-remote (second port),
attach-endpoint returns both
transports, macOS opts in behind an explicit rollout flag. Phase 2: default new
attaches to `cmux-remote`, keep `websocket` as fallback for one release.
Phase 3: delete the Go daemon path per deployment path, then the `daemon/remote`
tree. Each phase is revertible by flipping the transport default; the two
daemons share nothing in the VM but the process supervisor.

Open items, in order: pre-approved invitations in `cmux-remote`; wire the
attach endpoint (`web/services/vms/drivers/*.ts`) to inject and start the new
daemon; land `feat-tui-manual-io`'s pump against a `remote connect
--headless` socket; the right-pane catalog. The spike deliberately excludes
all four.


## Cloud tree and agent routing (2026-08-26)

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
tree is push-updated, never polled. VNC display and forwarded-port rows are
backend catalog resources outside a workspace's terminal layout; their
open verbs use the shared `surface.project` path (with `vm.desktop_open` /
`vm.port_open` as the CLI equivalents) and the same tokened browser-pane flow.
Those rows are displays owned by the Cloud machine. They do not grant the VM
access to a local Mac browser, file, clipboard, or accessibility surface.

Socket methods (the CLI, the sidebar tree, and agents use these for remote
machine resources):

The `surface_id`, `workspace_id`, and `panel_id` fields in host-side projection
receipts are local-only. The guest-facing daemon strips them and returns the
remote resource and remote workspace IDs. This prevents a remote agent from
turning a projection receipt into a host lookup.

| Method | Params | Result |
| --- | --- | --- |
| `vm.tree` | `{id?, refresh?}` | `{machines: [{id, status, image, has_desktop, memory_mb?, disk_mb?, link_state, remote_workspaces?}], resources: [{id, machine, kind: terminal\|display\|browser, key, title, detail?, lifecycle, agent?, remote_workspace?, remote_views?, port?, url?, open_surface_ids}], projections: [{resource, workspace_id, panel_id}]}` — the renderer orders each machine as Workspaces, Ports, VNC Displays, then Terminals |
| `vm.terminal_open` | `{id, terminal_id, workspace_id?, placement?, focus?}` | `{surface_id, workspace_id, reused}` — `workspace_id` is the local target; an existing pane showing the terminal is focused instead of duplicated |
| `vm.terminal_new` | `{id, workspace_id?: ws_…, command?: [string], cwd?, name?, open?}` | `{terminal_id, workspace_id, surface_id?}` — a detached terminal in the machine's session |
| `vm.desktop_open` | `{id, workspace_id?, focus?}` | `{surface_id, url}` |
| `vm.port_open` | `{id, port, workspace_id?}` | `{surface_id, url}` |
| `vm.link_socket` | `{id}` | `{socket_path, session}` — the headless link's local mux socket |

CLI addresses are the tree's lines: `cmux vm tree`, then
`cmux vm open <machine>[/<ws>[/<term>]]`, `cmux vm open <machine>:desktop`,
`cmux vm open <machine>:port/<n>`. A terminal opens locally as a pane running
`cmux-tui attach --terminal <term_…>` against the link socket, so one remote
terminal renders in one pane with no session chrome.

Agents route work with the same remote primitives: `cmux vm route` prints the machine
`vm run` would choose (sticky per directory → idle pool machine → sleeper →
provision) without running anything; `cmux vm agent --agent <claude|codex|opencode|pi>
-- <prompt>` starts the agent as a detached terminal in the chosen machine's
session (so it survives the pane and reattaches from any device); `cmux vm run`,
`exec`, `push`/`pull`, and `wait` stay the headless verbs. CodeRouter is
orthogonal: it routes model credentials, not compute. The control plane issues
a short-lived route authority for each agent action; the guest stores only an
endpoint and placeholders, and the handoff library injects the authority for
the process lifetime. The `skills/cmux-cloud-vm` skill teaches this policy to
Claude Code, Codex, OpenCode, and Pi.

The remote daemon is the only authority for a Cloud workspace. Its topology
methods accept a machine-scoped session lease and remote workspace ID, then
return only remote IDs. They support workspace, tab, pane, terminal, browser,
and layout list, create, rename, move, reorder, and close operations. `current`
is evaluated in that daemon. The daemon rejects a local machine selector,
host surface ID, host path, or request without the leased workspace. A local
projection binding is created by the host after attach and is never visible to
the guest.

Topology mutations follow one direction: the agent calls the VM-local socket,
the daemon validates the lease and mutates its graph, then emits an event or
snapshot. The host reconciler mirrors that remote state into the dedicated
Cloud workspace. User input travels through the binding back to the daemon.
The guest never sends a direct host-layout mutation.

The guest image sets the daemon socket explicitly and omits the host socket,
host home directory, host environment, clipboard, keychain, and SSH agent. The
host opens the authenticated remote link. A missing or expired lease fails
closed; it never falls back to a local socket. Browser processes and file
readers are guest services. They return VM-owned frames or bounded snapshots,
not host paths or host UI state.

The minimum guest-facing operation set is:

| Method | Scope and result |
| --- | --- |
| `workspace.list`, `workspace.create`, `workspace.rename`, `workspace.close` | Lease-scoped remote workspace IDs and revisions; a created workspace joins the lease |
| `surface.list`, `surface.create`, `surface.move`, `surface.rename`, `surface.close` | Lease-scoped remote tab, pane, terminal, browser, file, diff, and Markdown surfaces |
| `layout.get`, `layout.apply` | Revision-fenced atomic layout for the leased workspace |
| `file.open`, `diff.open`, `markdown.open` | VM-root path resolution and bounded immutable viewer snapshots |
| `browser.open`, `browser.navigate`, `browser.input`, `browser.state` | VM browser process, VM network policy, and remote frame/state stream; DOM and script results stay on the guest agent channel |

Every mutating method carries `machine_id`, `session_id`, `workspace_id`,
`request_id`, `nonce`, `expires_at`, `expected_revision`, and an idempotency
key. The daemon rejects a missing scope before parsing a path or URL. It never
returns a host placement ID.

## Surface catalog

Terminals, VNC screens and Cloud browsers are *resources*; panes and
workspaces are *projections* of them. On the Mac, `SurfaceCatalog`
(`Sources/Surfaces/`) is the one owner of resource identities
(`<machine>/<kind>/<key>`, machine = `local` or a Cloud machine ID) and
projections (resource, workspace, panel). Adapters push resources in:
`LocalSurfaceAdapter` (this Mac's trusted terminals and browsers) and one
`CmuxTuiSurfaceAdapter` per Cloud machine (its cmux-tui workspaces/terminals
from the headless link, its noVNC screen `display:1`, its forwarded ports).
`catalog.project(resource, into:)` is the single local open path for trusted
desktop clients. A Cloud agent cannot enumerate or project `machine:local`
resources. When a Cloud resource is attached, the host broker creates a local
projection binding and reuses the placement and viewer adapters. The remote
principal receives only the remote resource receipt, never the host surface ID.
This preserves code reuse for placement and receipts without sharing host read
or control authority.

Socket (worker lane, like `vm.*`):

| Method | Params | Result |
| --- | --- | --- |
| `surface.catalog` | `{machine?: "local"\|<id>, refresh?}` | `{machines: [{id, local, name, status, image, has_desktop, memory_mb, disk_mb, link_state, link_error, cpu_percent, memory_used_mb, disk_used_mb}], resources: [{id, machine, kind, key, title, detail, lifecycle, agent?, remote_workspace?, port?, url?, open, open_surface_ids, open_workspace_ids}], projections: [{resource, workspace_id, surface_id}]}` |
| `surface.project` | `{resource, workspace_id?, pane_id?, direction?: left\|right\|up\|down, tab_index?, placement?: split\|tab, focus? (true), reuse? (true)}` | `{surface_id, workspace_id, reused, resource}` — `pane_id` + `direction` splits that pane on that side; `pane_id` + `tab_index`/`placement: tab` tabs into it; else the workspace's focused pane |
| `surface.new_terminal` | `{machine, command?: [string], cwd?, name?, remote_workspace_id?, open? (true), + the destination params}` | `{resource, terminal_id, machine, remote_workspace_id, workspace_id?, surface_id?}` |

`surface.catalog` with `machine: local` is a desktop-only operation. A Cloud
principal cannot use it to enumerate host files or host browser tabs. A
`surface.project` result for a Cloud resource may create a local display, but
the remote principal receives no host surface ID or readback authority. Host
file and host-browser actions are not part of the remote agent protocol. A
local user may open a host item independently or perform an explicit bounded
file transfer to a VM.

The local display adapter must not interpret a VM URL by calling the host
browser. It renders VM browser frames and sends explicit pointer and keyboard
events back to the VM. VM network policy is enforced in the guest namespace and
at the browser proxy: VM loopback, assigned interface addresses, and exact peer
IPs from directed VPC grants may be allowed, while
the host gateway, Mac LAN, metadata, link-local, and unapproved private ranges
are denied. Address checks canonicalize IPv4, IPv6, mapped, integer, and DNS
forms before each connection. VPC reachability does not authorize a second
VM's daemon.

The `vm.tree`, `vm.terminal_open`, `vm.terminal_new`, `vm.desktop_open`,
`vm.port_open` and `vm.link_socket` verbs keep their shapes and are wrappers
over the same catalog (`vm.tree` is the catalog restricted to cloud machines;
`vm.desktop_open` projects `<id>/display/display:1`; `vm.port_open` projects
`<id>/browser/port:<n>`, registering the port first when the probe has not
seen it). CLI: `cmux surface ls|open|new-terminal` and `cmux vm tree|open`.
