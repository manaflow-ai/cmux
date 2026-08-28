# Cloud VMs on the cmux-tui remote daemon

Design for replacing the Go `cmuxd-remote` daemon in Cloud VMs with the
cmux-tui remote daemon, validated by a working transport spike
(`scripts/spike-cmux-tui-blaxel.sh`). North star: every cloud terminal is a
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

All steps are automated in `scripts/spike-cmux-tui-blaxel.sh` and were run
against a live Blaxel sandbox:

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

## Local repro without Blaxel credentials

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

## Per-provider replacement

One artifact replaces `cmuxd-remote-linux-amd64` everywhere:
`cmux-tui-x86_64-unknown-linux-musl` from the existing package lane, pinned by
sha256 exactly as `CMUX_VM_BLAXEL_DAEMON_URL`/`_SHA256` pin the Go binary
today. The per-provider delivery mechanisms stay what they are:

| provider | today | change |
| --- | --- | --- |
| blaxel | gzip+base64 runtime injection at create | same path, chunked upload or URL fetch (binary is ~4x larger); start `server start --remote-ws` instead of `serve --ws` |
| e2b | baked into template by `web/scripts/build-cloud-vm-images.ts` | swap the copied binary and start command |
| daytona | baked into snapshot, entrypoint restarts it | same swap; the driver's repair exec restarts `server start` |
| freestyle | systemd unit in the VM snapshot | same swap in the unit file |

The daemon's remote state dir must live on the persistent volume (the machine's
home: `/home/cmux` on blaxel — the daemon and every terminal pane run as the
non-root `cmux` user with passwordless sudo; sandboxes created before that
change keep their volume at `/root` and stay root until resurrected — hence the
HOME-derived default `~/.local/state/cmux/remote` already qualifies)
so daemon identity and enrolled devices survive sandbox resurrection. Session
state (`--state`) lives there too, so workspace layout restores from the
journal checkpoint after a daemon restart; running processes do not survive a
restart, and clients see the generation change instead of a silent new shell.

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
provider machinery it needs is already shared in `cmux-remote`.

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

## Rollout

Phase 1: ship the cmux-tui daemon alongside cmuxd-remote (second port,
blaxel first since it needs no image rebake), attach-endpoint returns both
transports, macOS opts in behind a feature flag. Phase 2: default new
attaches to `cmux-remote`, keep `websocket` as fallback for one release.
Phase 3: delete the Go daemon path per provider, then the `daemon/remote`
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
  workspaces/
    <name>  ws_…  *              cmux-tui workspace (focused marked *)
      ● term_…  <title>  <cwd>  [agent claude running]  (open: surface:3)
  desktop                        noVNC screen (Mac-side synthetic node)
  ports/
    3000  http                   forwarded port (Mac-side synthetic node)
```

The app keeps one headless `cmux-tui remote connect --headless` link per
awake machine and reads `session current snapshot --json` plus the
`session current events --jsonl` stream over that link's local socket; the
tree is push-updated, never polled. Desktop and ports are not cmux-tui
resources — they are the Mac's own nodes backed by `vm.desktop_open` /
`vm.port_open` (the same `open-port` + browser-pane path as before).

Socket methods (the CLI, the sidebar tree, and agents all go through them):

| Method | Params | Result |
| --- | --- | --- |
| `vm.tree` | `{id?, refresh?}` | `{machines: [{id, status, image, desktop, memory_mb?, disk_mb?, link: {state, error?}, workspaces: [{id, name, focused, terminals: [{id, title, cwd?, lifecycle, agent?: {state, source}, open_surface_id?}]}], ports: [{port, label?}]}]}` |
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
`vm.desktop_open` projects `<id>/screen/display:1`; `vm.port_open` projects
`<id>/browser/port:<n>`, registering the port first when the probe has not
seen it). CLI: `cmux surface ls|open|new-terminal` and `cmux vm tree|open`.

