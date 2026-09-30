# cmux next: Cloud and iOS on cmux-tui

Research note for `REWRITE.md` decision D4 ("Cloud and iOS must keep working
seamlessly. They may be rewritten so both ride cmux-tui"). Paths are relative
to the `feat-cmux-next` worktree (base `fde44232c35`, read 2026-09-28). `T/` =
`cmux-tui/`. Sibling notes: `cmux-tui-contract.md` (local daemon contract),
`inventory.md` (package keep/delete table).

## 0. Summary

1. Cloud already rides cmux-tui. Every Freestyle VM runs one `cmux-tui` daemon
   (session `cloud`, CMXR protocol 5 on `ws://<vpc-ip>:1337/v1/link`,
   trusted-carrier mode). The Mac spawns one headless `cmux-tui remote
   connect` per machine through an app-owned userspace WireGuard hub, and
   renders panes in Ghostty manual-IO mode from the link's local v12 socket.
   The cmux-next Cloud work is a frontend rewrite, not a transport rewrite.
2. iOS does not ride cmux-tui for Mac terminals. It speaks a Mac-app-specific
   RPC dialect (about 90 `mobile.*` methods plus `terminal.*`/`workspace.*`
   events) over the irx Iroh transport (ALPN `cmux/irx/1`). Admission is a
   per-team v2 directory of permitted phones at the irx layer (the
   same-account gate). Terminal bytes come from a PTY tee inside the
   Mac app's own Ghostty surfaces. That source disappears in cmux-next because
   PTYs move into the daemon.
3. The shipping iOS app already contains a Swift cmux-tui v12 client
   (`CmuxTUIControl`, 2,110 lines) that it uses for SSH hosts. The target iOS
   app reuses that client and swaps the SSH carrier for a cmux-remote
   (Noise over Iroh) carrier.
4. Target: one model, "every machine is a cmux-tui daemon". The Mac frontend
   shows the local daemon and each cloud daemon as sibling trees. iOS attaches
   to the Mac's local daemon over cmux-remote Iroh, and to cloud daemons
   directly or relayed through the Mac. The Mac-app mobile RPC survives only
   as a compat shim for shipped iOS builds, re-backed onto the daemon.
5. Missing daemon pieces: account-bound admission (same-account gate) for the
   Iroh listener, an iOS-usable client library (Swift CMXR or the
   `cmux-terminal-client` C ABI), a push-notification relay, a cross-daemon
   aggregate (today done in the Mac app), and features that have no daemon
    equivalent (browser streaming, simulator streaming, agent chat, changes,
   artifacts, todos).
6. Migration order keeps the shipping iOS app working: shim first, new iOS
   transport behind a capability, then retire the shim after the iOS app
   ships and old builds age out.

## 1. Cloud today

### 1.1 Create

- UI "New Machine" spawns the bundled CLI `cmux vm new`
  (`Sources/Cloud/NewMachineModel.swift:412`,
  `Sources/CloudVMActionLauncher.swift:309-311`). Lifecycle and fencing live in
  `CloudMachineCreateCoordinator` (package `CmuxCloudMachines`), wrapped by
  `Sources/Cloud/MachineCreateCoordinator.swift:68`.
- The CLI calls socket method `vm.create` (`CLI/CMUXCLI+VMTransfer.swift:1383`)
  which runs `VMClient.create` → `POST /api/vm` with an `Idempotency-Key`
  (`Sources/Cloud/VMClientSocketCommands.swift:215-240`,
  `Packages/macOS/CmuxCloud/Sources/CmuxCloud/VMClient/VMClient.swift:1546-1565`).
- Server: `web/app/api/vm/route.ts:233,303` → `createVm`
  (`web/services/vms/workflows.ts:871`): VPC resolve, row insert, credit
  reservation, coderouter model plane (edge TLS rules, `:941`), then
  `providers.create` (`:971-992`).
- `FreestyleProvider.create` makes one `fs.vms.create({snapshotId, vpcs,
  tls:{rules}, ...})` call and stamps `cmuxTuiContract:"snapshot-v2"`
  (`web/services/vms/drivers/freestyle.ts:939-952,1009-1014`). No guest exec
  during create (`:102-124`). The coderouter token lives only in the edge rule
  (`:126-135`).
- The image is a baked Freestyle snapshot listed in
  `web/services/vms/images/manifest.json`, built by
  `web/scripts/build-devbox-freestyle.ts` (unit env `CMUX_TUI_REMOTE_WS_BIND`,
  `:543`).

### 1.2 What runs on the VM

- `web/services/vms/images/devbox/cmux-devbox-boot:242` runs
  `cmux-tui server start --session cloud --remote-ws ${bind:-0.0.0.0:1337}
  --remote-ws-insecure-bind --remote-ws-trusted-carrier` as user `cmux`
  (uid 1000), or root on old layouts (`docs/cloud-cmux-tui-daemon.md:92-121`,
  `web/services/vms/drivers/cmuxTuiDaemon.ts:23-33`).
- Session `cloud`; the in-guest `cmux` shim runs `cmux-tui --session cloud`
  (`web/services/vms/guestCli.ts`, `docs/cloud-cmux-tui-daemon.md:721-723`).
- Each terminal is a `__terminal-host` process that a replacement daemon
  adopts. State lives in `~/.local/state/cmux/remote`
  (`docs/cloud-guest-upgrades.md:52-63`).
- Durable notification ledger, 256 rows, per-client `read_by`,
  `notification.ack {client_id}`; agent hooks post notifications from the
  journal fold (`docs/cloud-cmux-tui-daemon.md:549-611`, `:701-717`).
- Upgrade rule: only the `cmux-tui` binary reaches running machines
  (`web/scripts/upgrade-fleet-cmux-tui.ts`). The daemon argv, env, systemd
  units, and `cmux-devbox-boot` are bake-only. A new daemon must run correctly
  with the old argv, adopt old terminal hosts (terminal-host protocol 4), and
  keep CMXR protocol 5 compatible (`docs/cloud-guest-upgrades.md:28-72`).
  This rule constrains every cloud-side change proposed below.

### 1.3 Attach and render

- `CloudMachineLinkManager` (actor,
  `Packages/macOS/CmuxCloud/Sources/CmuxCloud/Link/CloudMachineLinkManager.swift:15`)
  keeps one link per awake machine. First contact calls
  `POST /api/vm/[id]/attach-endpoint {transport:"cmux-remote"}`
  (`VMClient.swift:1990-2010`); the route
  (`web/app/api/vm/[id]/attach-endpoint/route.ts:53-78`,
  `freestyle.ts:1358-1405`) returns `{transport, route, token,
  expiresAtUnix, session:"cloud", trustedCarrier:true, networkAddresses}`.
  Route preference is VPC IPv4, VPC IPv6, public IPv6 (`freestyle.ts:314-338`).
- `CloudMachineLink.connect` spawns the bundled `cmux-tui remote connect
  <route> --headless --json --exit-with-parent --lanes single --carrier
  --wireguard-hub <sock>` and reads the local mux socket path from its first
  stdout line
  (`Packages/macOS/CmuxCloud/Sources/CmuxCloud/Link/CloudMachineLink.swift:197-270`,
  argv from `Packages/macOS/CmuxCloudTui/Sources/CmuxCloudTui/CloudTuiCommandLine.swift:31-50`).
- Tree state: `session current snapshot --json` plus `session current events
  --jsonl --generation --revision` (resource API v2 `session.events`) over that
  socket (`CloudTuiCommandLine.swift:73-86`). Stored in
  `CloudVMState.document`, a canonical JSON-fragment document with a
  `(generation, revision)` cursor, owned by `SurfaceCatalog`
  (`docs/cloud-cmux-tui-daemon.md:125-170`, `Sources/Surfaces/SurfaceCatalog.swift:5-46`).
- Panes: `CloudTuiManualMirrorSession` connects to the link socket, sends v12
  `attach-surface`, and feeds VT bytes into a Ghostty manual-IO surface
  (`Sources/Cloud/CloudTuiManualMirrorSession.swift:10-17`,
  `Packages/macOS/CmuxCloudTui/Sources/CmuxCloudTui/CloudTuiManualIOCommand.swift:31-213`).

### 1.4 Transports and auth

Bytes and control share one path:
`Ghostty pane ⇄ v12 JSON lines on local Unix socket ⇄ headless cmux-tui link ⇄
SOCKS5 ⇄ cmux-tui wg hub (cmux-wg) ⇄ WireGuard ⇄ Freestyle VPC ⇄ daemon :1337
/v1/link (Noise)` (`docs/cloud-userspace-wireguard.md:24-38`,
`T/docs/remote.md` "Share one WireGuard tunnel").

- Control plane: Stack Auth bearer plus refresh token on every `/api/vm/*`
  call (`VMClient.swift:2326-2327`, `web/services/vms/auth.ts:500-563`).
- WireGuard enrollment: `POST /api/vm/tunnel` with the Mac's public key; the
  private key never leaves the Mac (`web/app/api/vm/tunnel/route.ts:45-107`,
  `VMTunnelManager.swift:9-40`). Two identities: the app hub
  (`mac-<uuid>-app`) and the `cmux vpn up` Network Extension
  (`TunnelExtension/`, `CmuxCloudTunnelCore`).
- Daemon admission: reachability on the private network. The cloud listener is
  a trusted carrier, so there is no device enrollment. Noise still encrypts and
  binds the client key. Revocation deletes the Mac's WireGuard peer
  (`docs/cloud-cmux-tui-daemon.md:344-377`).
- Not on the Cloud path today: cmux-relay, Iroh, Freestyle SSH (only
  `scp-endpoint` for push/pull), Go `cmuxd-remote` (only `cmux ssh`), pty
  WebSocket (legacy branch still present but unreachable:
  `attach-endpoint/route.ts:80-100`, `CLI/cmux.swift:5090`).

### 1.5 Swift packages and app code

| Unit | Lines | Role today |
| --- | --- | --- |
| `CmuxCloud` | 23.5k | `VMClient` REST, `VMTunnelManager`, `CloudWireGuardHub`, `CloudMachineLink(Manager)`, port forward and browser proxy, notification sync, rename coordinator |
| `CmuxCloudTui` | 2.3k | argv builders for `remote connect`, `wg hub`, `browser-proxy`, `session current *`; v12 manual-IO client |
| `CmuxCloudMachines` | 1.4k | create, delete, pin coordinators |
| `CmuxCloudTunnelCore`, `CmuxCloudBannerCore`, `CmuxCloudImagePaste` | 0.7k | Network Extension shared code, banner state, chunked image paste |
| `CmuxRemoteDaemon/Session/Workspace` | 20.4k | `cmux ssh` on Go `cmuxd-remote`; not Cloud (residue: `managedCloudVMID`) |
| `Sources/Cloud` | 20.8k | Cloud tree UI (`CloudTreeOutlineView`, `MachinesPanelView`), `vm.*` socket methods |
| `Sources/Surfaces` | 16.2k | `SurfaceCatalog`, `CmuxTuiSurfaceProvider` per machine, layout translator, projection coordinator |
| `Sources/RemoteTui` | 1.0k | SSH cmux-tui machines on the same link manager, `WorkspaceCloudVMBinding` |

The Mac app is already the cross-daemon aggregator: `SurfaceCatalog` owns
resource ids `<machine>/<kind>/<key>` for `local` and each cloud machine, and
a local workspace is bound to one remote `ws_…` by `WorkspaceCloudVMBinding`
(`Sources/RemoteTui/WorkspaceCloudVMBinding.swift:5-12`,
`Sources/Surfaces/CloudWorkspaceProjectionCoordinator.swift:5-7`). The local
machine is not a daemon today; it is the Mac app's own terminal model.

### 1.6 Stale docs to fix later (found during this read)

- `docs/cloud-cmux-tui-daemon.md:367-373` says `trustedCarrier` can be false;
  `freestyle.ts:1395` hard-codes true.
- `docs/cloud-cmux-tui-daemon.md:385-405` still describes the removed
  `vm-pty-connect` bridge and an `attach --pipe-io` pump; code connects
  directly (`CloudTuiManualIOConnection`).
- `T/docs/remote.md:5` says WebSocket always uses device auth and omits
  `--remote-ws-trusted-carrier`, which Cloud depends on.
- `daemon/remote/README.md:14` still claims a Cloud role for `cmuxd-remote`.
- `CloudMachineLinkManager.swift:216` defaults `session = "cmux"`; the server
  uses `cloud` (harmless, only passed for `ssh://`).

## 2. iOS today

### 2.1 App and packages

- `ios/cmux/cmuxApp.swift` builds the runtime: `MobileIrxRuntimeComposition`
  always (`:55`), `.iroh` routes to irx, `.tailscale` (and DEBUG loopback) as
  fallbacks (`:76-95`), terminal/event/artifact lanes on irx (`:101-110`).
  `ios/cmuxPackage` is the composition root. `ios/NotificationService`
  decrypts E2E push payloads (`ios/NotificationService/NotificationService.swift:56`).
- `Packages/iOS`: `CmuxMobileShell` (domain layer, `MobileShellComposite`,
  SSH providers), `CmuxMobileShellUI` (SwiftUI, `MobilePushCoordinator`),
  `CmuxMobileRPC` (`MobileCoreRPCClient`, multiplexed RPC and lane
  connections), `CmuxMobileTransport` (legacy Tailscale TCP), `CmuxMobileTerminal`
  (libghostty surfaces), `CmuxMobileTerminalKit` (input logic),
  `CmuxMobilePairedMac` (SQLite paired-Mac store), `CmuxMobileWorkspace`
  (layout and gating policy), `CmuxMobileSSH` (SSH, SFTP, and a cmux-tui v12
  client), `CmuxMobileTunnel` (loopback SOCKS whose exit is SSH or the paired
  Mac), feature packages (BrowserStream, SimulatorStream, Changes,
  AgentChatUI, Camera for QR), and support packages.
- `Packages/Shared`: `CMUXMobileCore` (wire DTOs, frame codec,
  `MobileTerminalRenderGridFrame`), `CmuxIrohTransport` (legacy
  `cmux/mobile/1` contracts), `CmuxIrxTransport` (current transport, ALPN
  `cmux/irx/1`: peer engine, admission, relay-credential autopilot, v2 control
  service, per-surface event lanes, tunnel host), `CMUXAuthCore` (Stack Auth
  model). `CmuxSyncStore` has no consumer (orphan; delete candidate).

### 2.2 Pairing, transport, and the account gate

- irx is the only Mac Iroh runtime: "The sole Mac IROH owner for a selected
  Stack team and opted-in installation"
  (`Sources/Mobile/MobileHostIrxRuntime.swift:20-22`). The `cmux.irx.enabled`
  flag is gone; `docs/irx-transport-design.md:55-66` (off by default, not in
  Release) is stale.
- Old phones: `MobileHostIrxLegacyDialectServer` serves `cmux/mobile/1` on the
  same irx endpoint and identity, default on
  (`Sources/Mobile/MobileHostIrxLegacyDialectServer.swift:6-22`).
- Pairing v2 has no QR: the Mac must be signed in and opted in; identity is
  the account plus device (`Sources/Mobile/Pairing/MobilePairingModel.swift:8-11`,
  `docs/iroh-v2/IMPLEMENTATION.md:20,55`). Attach tickets and the QR scanner
  still exist as legacy code (`MobileHostService.swift:1036-1100`).
- Same-account gate, as it works now: admission at the irx layer. The Mac
  holds a per-team v2 directory with explicit inbound phone permissions
  (`Packages/Shared/CmuxIrxTransport/Sources/CmuxIrxTransport/V2/V2InboundAdmissionAuthority.swift:4-6`);
  an admitted peer arrives as `.irohAdmission(peer)`
  (`Sources/Mobile/MobileHostTransportAuthorization.swift:15-18`,
  `MobileHostIrxRuntime.swift:1026-1040`) and the per-RPC check returns nil
  (`MobileHostService.swift:1002-1003`). Grants are Ed25519, bound to both
  endpoints and ALPN, 7-day, re-checked every 30 s; Stack tokens never cross
  Iroh (`docs/iroh-app-transport-architecture.md:82-102`).
- The per-RPC Stack bearer gate with `account_mismatch`
  (`MobileHostService.swift:1233-1266`) is only reachable on
  `.stackBearer` connections, and every live `acceptTransport` caller passes
  `.irohAdmission`. It is dead on the Mac side; iOS still handles the code.
- Relays: managed fleet `*.relay.cmux.dev`
  (`config/iroh/managed-relay-catalog.json`), 5-minute endpoint-bound relay
  JWTs from `POST /api/relay/token`
  (`docs/iroh-app-transport-architecture.md:116-148`).
- Compatible tags (PR 10619, DEBUG only): `MobileCompatibleMacTags`
  (`MobileHostService.swift:103-158`), edited only through the local socket
  (`Sources/TerminalController.swift:1785-1788`), pushed as
  `mobile.compatible_tags.changed`.

### 2.3 RPC surface

Wire: JSON `{id, method, params, auth}` (`Sources/Mobile/MobileHostRPC.swift:37-160`).
`acceptTransport` handles `mobile.host.status` and `phone_push.keys.exchange`
(`MobileHostService.swift:934-944`); everything else goes to
`TerminalController.mobileHostHandleRPC` (`Sources/TerminalController.swift:14857-15035`).
Canonical list: `MobileHostService.irohReleaseGateRPCMethods`
(`Sources/Mobile/MobileHostService+Capabilities.swift:12-110`), mirrored on the
phone in `MobileIrohReleaseGateRPCMethodInventory.swift`.

| Group | Methods | Daemon equivalent exists? |
| --- | --- | --- |
| Host/session | `mobile.host.status`, `mobile.events.{probe,subscribe,unsubscribe}`, `mobile.attach_ticket.create`, `caffeine.*`, `dogfood.feedback.submit` | `identify`, `subscribe` |
| Workspace/sidebar | `mobile.workspace.list`, `mobile.sync.fetch` + `mobile.sync.delta`, `workspace.{create,close,action,move}`, `workspace.group.*`, `mobile.surface.focus`, `mobile.status.*`, `mobile.todo.*` | Tree yes; groups/status/todos no (contract note decision 5) |
| Terminal | `mobile.terminal.{create,input,paste,paste_image,replay,viewport,scroll,mouse,close,rename}` (+ `terminal.*` aliases); events `terminal.bytes`, `terminal.render_grid`, `terminal.set_font` | Yes: `create-terminal`, `send`, `attach-surface bytes|render`, resize leases, `close-terminal`; image paste has a cloud capability (`CmuxCloudImagePaste`) |
| Artifacts | `mobile.terminal.artifact.*`, `mobile.panel.artifact.*` | Partly (`workspace-rpc` file reads) |
| Files/changes | `mobile.workspace.changes.*`, `mobile.directory.{list,search}`, `mobile.task.*` | Partly (`workspace-rpc` stat/read/search/git diff) |
| Agent chat | `mobile.chat.*` (reads Claude/Codex transcripts, `Sources/Mobile/AgentChat/`) | No |
| Browser stream | `mobile.browser.*`, events `browser.*` | Different model (daemon CDP browser tabs) |
| Simulator stream | `mobile.simulator.*`, events `simulator.*` | No |
| Notifications/push | `notification.{dismiss,reconcile}`, `notification.feed.*`, `phone_push.*` | Ledger + ack yes; push no |

### 2.4 Terminal rendering

- iOS links the same libghostty (`CmuxGhosttyKit`) and feeds bytes into
  `ghostty_surface_process_output`
  (`Packages/iOS/CmuxMobileTerminal/Package.swift:33-35`,
  `GhosttySurfaceView.swift:3809`).
- Bytes come from the Mac app's in-process Ghostty PTYs through the fork's
  `ghostty_surface_set_pty_tee_cb`, before the parser
  (`Sources/Mobile/MobileTerminalByteTee.swift:12-23`), with a per-surface
  sequence and replay ring.
- Output mode is negotiated: `renderGrid` (Mac offers `terminal.render_grid.v1`
  + `screen_anchor.v1`), `hybrid`, or `rawBytes`
  (`Packages/iOS/CmuxMobileShell/Sources/CmuxMobileShell/TerminalOutputTransportSelection.swift:4-32`).
  Render-grid frames are snapshots of the Mac surface
  (`Sources/Mobile/MobileTerminalRenderObserver.swift`,
  `Packages/Shared/CMUXMobileCore/Sources/CMUXMobileCore/MobileTerminalRenderGrid.swift:13-15`)
  that the phone converts back to VT bytes (`:480-507`).
- Input: length-prefixed frames on the irx terminal lane, which replays from
  the tee then streams live (`Sources/Mobile/MobileHostIrxTerminalLaneServer.swift:6-10`);
  one QUIC stream per surface's output (`IrxSurfaceEventLanes.swift:3-8`).

### 2.5 State read from the Mac, and push

- Workspace rows come from `TabManager` and `workspaceGroups`, with agent
  status per terminal (`Sources/TerminalController+MobileWorkspaceList.swift:36-110,217-241`),
  observed by `MobileWorkspaceListObserver` and published as versioned deltas
  by `MobileStateSync` (`docs/mobile-state-sync-v2.md`).
- Notifications come from `TerminalNotificationStore`
  (`Sources/TerminalController+MobileNotificationSync.swift:21`), which
  already includes cloud-VM notifications attributed by the Mac
  (`docs/cloud-cmux-tui-daemon.md:746-764`).
- Nothing in `Sources/Mobile` reads a cmux-tui daemon. Cloud workspaces reach
  the phone only as Mac workspaces.
- APNs path: `TerminalNotificationStore` → `PhonePushClient.forward`
  (`Sources/TerminalNotificationStore.swift:1711`) → encrypted envelope to
  `/api/notifications/push/e2e` (`Sources/Cloud/PhonePushClient.swift:471`) →
  `web/services/apns/sender.ts` → NotificationService extension. Keys are
  pinned over the authenticated device connection (`docs/phone-push-e2e.md:1-22`).

### 2.6 iOS and cmux-tui today

- No Cloud API use on iOS. The phone reaches cmux-tui only over its own SSH:
  `CmuxTUIRemote` runs `server ensure` and `cmux-tui relay` over an SSH exec
  channel (`Packages/iOS/CmuxMobileSSH/Sources/CmuxMobileSSH/CmuxTUI/CmuxTUIRemote.swift:3-8`),
  `CmuxTUIControl` speaks v12 JSON lines, attach uses `bytes` mode with
  geometry claimed only while visible, and browser tabs are supported
  (`Packages/iOS/CmuxMobileShell/Sources/CmuxMobileShell/MobileSSHCmuxTUIProvider.swift:6-16`,
  `CmuxTUIBrowser.swift:3-7`). The phone owns session `cmux-ios` and never
  takes over a desktop session it did not start (`MobileSSHCmuxTUIProvider.swift:20-22`).
- This is the seed of the target iOS client.

### 2.7 Stale iOS docs

`docs/irx-transport-design.md` (activation model), `docs/iroh-app-transport-architecture.md:5,13,57`
(Tailscale TCP path described as live; the Mac listener is gone),
`docs/iroh-offline-pairing-v1.md` (QR flow, pre-v2), `docs/ios-swift-mobile-plan.md` (historical).

## 3. Target design

### 3.1 One model: every machine is a daemon

```
            ┌──────────── cmux-next Mac frontend ────────────┐
            │ sidebar: Local ▸ workspaces   Cloud vm-a ▸ ... │
            └──────┬──────────────────────────┬──────────────┘
          unix v12 │                          │ unix v12 (link socket)
         ┌─────────▼─────────┐     ┌──────────▼───────────┐
         │ local cmux-tui    │     │ headless remote link │── WG hub ── VM daemon (cloud)
         │ daemon (session   │     └──────────────────────┘
         │ cmux or tag)      │
         │                   │◀── unix splice ── Mac irx endpoint ◀── irx lane (L3) ── iPhone
         │  (+ cmux-remote   │                                          (CmuxTUIControl,
         │   Iroh, L1 later) │◀────────── Noise over Iroh (L1) ───────── v12 JSON lines)
         └───────────────────┘
```

- Machine = one cmux-tui daemon session. The Mac frontend holds N daemon
  connections: the local session (`cmux-tui-contract.md` section 1) and one
  per cloud or SSH machine. Each connection speaks the same raw v12 protocol
  (or resource API v2) over a Unix socket. For remote machines the socket is
  the headless `remote connect` link that exists today. One Swift tree client,
  instantiated per machine, replaces `CloudVMState.document`,
  `CmuxTuiSurfaceProvider`, `CloudTuiManualMirrorSession`, and the local
  Ghostty terminal model.
- Sidebar: top-level machine sections, each rendering its daemon's workspace
  tree verbatim. A cloud workspace is a daemon workspace, not a local
  workspace bound to a remote one. `WorkspaceCloudVMBinding`, the layout
  translator, and the projection coordinator disappear because there is no
  second (local) tree to reconcile.
- Terminals everywhere render the same way: `attach-surface mode:"bytes"`
  into a Ghostty manual-IO surface (contract note decision 3).
- Aggregation stays client-side. The daemon has no federation
  (`T/spec/resource-api-v2.md:34-37,652-657`: one endpoint = one session,
  cross-machine discovery is "reserved for a later broker protocol"). The
  frontend merges machine lists from `/api/vm` (cloud), local config (SSH), and
  the local daemon. Do not wait on a daemon broker.
- Cross-machine placement (a cloud terminal inside a local workspace) is not
  in the model. Put it behind a later decision (section 4, R6). Today's
  drag-a-cloud-terminal-into-a-local-split works because both trees are the
  Mac app's; in cmux-next it needs either a cross-daemon projection in the
  frontend's `personal` projection or a daemon-side foreign-terminal
  reference.

### 3.2 iOS attaches to daemons, not to the Mac app

Target path for Mac terminals. The protocol is fixed; the carrier has two
options (section 3.3 picks one):

1. Protocol: the phone speaks raw v12 JSON lines (the `mux-control` service
   payload, `T/spec/remote-daemon.md` "Services",
   `T/crates/cmux-remote/src/services.rs:444`) to the Mac's local daemon.
   Terminal bytes use v12 `attach-surface mode:"bytes"` or, later,
   `terminal-bytes-v1` (CMTH frames, snapshot then live bytes,
   `T/apps/macos/TerminalBytesDemo/README.md` "Protocol contract").
2. Carrier L3 (first): a new irx lane. The Mac frontend accepts the admitted
   irx peer and splices the lane to the local daemon's Unix socket.
   Carrier L1 (later): the daemon runs its own cmux-remote Iroh provider
   (`--iroh`, ALPN `dev.cmux.remote/1`,
   `T/crates/cmux-remote/src/provider/iroh_config.rs:5`) and the phone opens a
   Noise session to it directly.
3. iOS runs the existing `CmuxTUIControl` on that stream. Today it is bound to
   `SSHSessionChannel`
   (`Packages/iOS/CmuxMobileSSH/Sources/CmuxMobileSSH/CmuxTUI/CmuxTUIControl.swift:26,55-80`);
   extract a carrier protocol (line in, line out, close) so SSH, the irx lane,
   and CMXR all implement it. `MobileSSHCmuxTUIProvider` then generalizes to "cmux-tui
   provider over any carrier".
4. Rendering stays libghostty on iOS, fed with bytes (it already renders SSH
   cmux-tui workspaces that way).

Target path for cloud terminals on iOS, two options:

- A (recommended first): relay through the Mac. The Mac frontend publishes
  its machine list to the phone and splices one irx lane per machine to that
  machine's socket (local daemon socket, or the headless link socket, which
  already speaks v12). Works only while the Mac is awake.
- B (later): direct. The phone needs its own cloud reach. The VM listener is
  private-network trusted-carrier only, and iOS allows one packet-tunnel VPN
  (`docs/iroh-app-transport-architecture.md` "iOS normally permits one active
  packet-tunnel VPN"). Options: embed `cmux-wg` userspace in the iOS client
  (the Rust client already supports `--wireguard-config` in process), or add an
  Iroh listener on the VM with enrolled-device auth. Both need a new bake,
  because daemon argv and env are bake-only (`docs/cloud-guest-upgrades.md:32`),
  unless the listener is enabled by a config file the new binary reads when
  present.

### 3.3 Transport library for iOS

Two stacks exist and do not interoperate:

| | Mac-app mobile (today) | cmux-tui remote |
| --- | --- | --- |
| Iroh binding | Swift, `iroh-ffi` fork `1.2.0-cmux.1.ios17` (`Packages/Shared/CmuxIrohTransport/Package.swift:19-22`) | Rust `iroh 1.0.3` (`T/Cargo.toml:143`) |
| ALPN | `cmux/irx/1`, legacy `cmux/mobile/1` | `dev.cmux.remote/1` |
| Identity and admission | broker-registered endpoint, pair-grant JWS, Stack same-account gate | Noise device key, invitation + owner approval, or trusted carrier |
| Relays | cmux relay fleet with broker-minted tokens (`docs/irx-transport-design.md:48`) | `iroh RelayMode::Default` or configured relay |
| Session layer | framed RPC + lanes (irx) | CMXR frames, 4 lanes, replay cursors, 120 s resume |

Options:

- L1: link the Rust client into iOS. `T/crates/cmux-terminal-client` is a
  C-ABI staticlib (Iroh-only today) that already does enrollment, Noise,
  lanes, CMTH, and a local ghostty-vt parser
  (`T/crates/cmux-terminal-client/include/cmux_terminal_client.h`).
  Extend it with a `mux-control` byte stream so `CmuxTUIControl` rides it.
  Cost: a second Iroh stack in the iOS binary (size, two endpoints, two relay
  configs, memory), and the Rust toolchain in the iOS build.
- L2: implement CMXR + Noise in Swift over the existing irx endpoint. One Iroh
  stack, but a second implementation of a security protocol. Not recommended.
- L3: keep irx as the phone-Mac carrier and add a new irx lane that pipes a
  daemon `mux-control` stream: the Mac frontend terminates irx
  (irx v2 admission unchanged) and splices bytes to the local daemon's
  Unix socket. No new crypto, one Iroh stack, the account gate is reused
  as-is. The Mac app stays in the path (it must be running, but it is running
  whenever the daemon is useful to a phone today).

Recommendation: L3 first. It changes only the payload behind an already
proven, already account-gated transport, and it removes all Mac-app
per-feature RPC for terminals and trees. Move to L1 when phones must reach a
daemon without a Mac frontend (headless Linux box, cloud direct). The
precedent for adding a dialect on one endpoint exists:
`Sources/Mobile/MobileHostIrxLegacyDialectServer.swift` serves
`cmux/mobile/1` beside `cmux/irx/1` on one endpoint and one identity.

### 3.4 Missing daemon capabilities

| Capability | Today | Needed |
| --- | --- | --- |
| Account-bound admission | Daemon knows device keys or carriers only; every client has full authority (`T/docs/remote.md:3`, `T/spec/remote-daemon.md:7-9`) | For L3: none (irx v2 admission stays the gate). For L1: an admission hook that accepts the broker's Ed25519 grant (what `V2InboundAdmissionAuthority` checks) as enrollment, so a same-account phone needs no invitation approval |
| Scoped or read-only clients | None; `programmability.md:70-78` lists `whoami`, scoped capabilities as targets | Not required for parity (the Mac RPC also grants full control). Flag for a "view only" share later |
| Push notifications | Daemon ledger + `notification.ack`; no push. Journal hook subscriptions can exec a program per event (`T/spec/session-journal.md` "Hook subscriptions") | Keep the Mac frontend as the APNs forwarder (it holds the E2E push keys, `docs/phone-push-e2e.md:1-20`), sourcing from the daemon ledger for local and cloud machines. Cloud-direct push without a Mac needs a daemon-side hook to the backend with a VM principal; defer |
| Per-device projection | `put-frontend-projection scope:"personal"` keyed by subject; per-client focus (`client-focus-v1`); per-client `read_by` | Use them: phone = its own `client_id` and personal projection; phone focus never moves the Mac view. Geometry: the phone claims geometry only while visible (already how `MobileSSHCmuxTUIProvider` works, D33) |
| Device and session catalog | Open intent (`T/docs/TECH-DEBT-BOARD.md:1068`, `USER-INTENT-BOARD.md` UI-10 "no-go"/open) | Enough for v1: the phone learns machines from the Mac (L3) or `/api/vm` (direct) |
| Group, unread, status, sort order in the tree | Mac-app sidebar state feeds `mobile.sync` records (`docs/mobile-state-sync-v2.md`) | Already planned in `cmux-tui-contract.md` decision 5 (groups, pin, color, notification ack in the daemon). The phone reads the same fields |
| Browser streaming, simulator streaming, agent chat, changes/diff, artifacts, todos, directory search, image paste | Mac-app RPC only | Stay Mac-frontend services. Carry them on their own irx lanes as today (L3). Some have daemon analogues (`workspace-rpc` files/diff/git, daemon browser tabs via `cmux-browser` CDP provider, `CmuxTUIBrowser.swift`), which a later iOS rewrite can adopt |

### 3.5 What becomes deletable in the Mac app

After the shim is retired (phase 5 below):

- Terminal plumbing for mobile: `MobileTerminalByteTee`,
  `MobileTerminalRenderObserver`, `MobileTerminalFramePacer`,
  `MobileTerminalRenderGridAnchorRegistry`, `MobileHostTerminalInputApplier`,
  `MobileHostIrxTerminalLaneServer`, `DeviceTerminalGridPublisher`,
  `MobileViewportApplyGovernor` (all under `Sources/Mobile/` or
  `Packages/macOS/CmuxMobileHost/`).
- Workspace sync: `MobileWorkspaceListObserver`, `MobileStateSync`,
  `MobileWorkspaceEmissionCoalescer`, the `mobile.workspace.*`,
  `mobile.sync.*`, `mobile.terminal.*`, `mobile.surface.focus` handlers.
- `MobileHostIrxLegacyDialectServer` and the `cmux/mobile/1` path once no
  supported build uses it.
- Dead today, deletable now: the `.stackBearer` per-RPC gate in
  `MobileHostService` (no live acceptor passes it), the Tailscale TCP client
  path on iOS if the Mac listener stays removed, and the orphan
  `Packages/Shared/CmuxSyncStore`.

Immediately in cmux-next (no shim dependency):

- `CmuxCloudTui` manual-IO client and `CloudTuiManualMirrorSession`
  (superseded by the shared daemon tree and attach client). Keep the argv
  builders for `remote connect` and `wg hub` or fold them into the link
  manager.
- `Sources/Surfaces` projection layer (`SurfaceCatalog` cloud providers,
  `CloudWorkspaceLayoutTranslator`, `CloudWorkspaceProjectionCoordinator`,
  `WorkspaceCloudVMBinding`, `CloudRenameCoordinator` fan-out logic): the
  daemon tree is shown directly.
- `CmuxRemoteDaemon/Session/Workspace` and Go `daemon/remote` once SSH moves
  to `cmux-tui remote ssh` (inventory D5; parity gate: SSH, port forward,
  reverse notification relay).
- Legacy Cloud residue: `VMClient.openAttach`, `vm-pty-connect`,
  `managedCloudVMID`, the `websocket` branch of `attach-endpoint`.

Keep: `VMClient`, `VMTunnelManager`, `CloudWireGuardHub`,
`CloudMachineLinkManager` (process lifecycle for links), port forward and
browser proxy, `CmuxCloudMachines`, irx/iroh transports, pairing UI,
`CmuxPhonePush`, and the Mac-side services for browser/simulator/chat/changes.

### 3.6 Migration order

Invariant: a shipped iOS build keeps working against every cmux-next Mac build
until the user decides to drop it.

1. **P0, Cloud parity in cmux-next (Mac only).** New tree client per machine
   over the existing headless links. Cloud workspaces appear as a machine
   section. No iOS change. Deletes the Surfaces projection layer and
   `CmuxCloudTui` mirror. Exit: create, attach, rename, notifications, ports,
   desktop parity against `cmux-legacy`.
2. **P1, compat shim.** Keep `MobileHostService` and the irx endpoint in
   cmux-next. Re-back the handlers onto the daemon:
   - `mobile.workspace.list`, `mobile.sync.fetch/delta` → daemon tree
     (local and cloud machine sections) mapped to the existing row shape.
   - `terminal.bytes`/`mobile.terminal.replay` → a per-terminal daemon
     `attach-surface mode:"bytes"` (replay = `vt-state`).
   - `terminal.render_grid` → daemon `attach-surface mode:"render"`
     (`T/spec/render.md:7-33`) converted to the existing grid frame, or the
     Mac's manual-IO Ghostty surface read back (choose by fidelity test).
   - `mobile.terminal.input/paste/mouse/scroll/viewport/create/close/rename`
     → `send`, `send-key`, `resize-attached-view`, `create-terminal`,
     `close-terminal`, tab rename.
   - Notifications feed → daemon ledgers with the phone's `client_id`.
   Keep browser, simulator, chat, changes, artifacts, todos on their current
   Mac implementations. Exit: the shipping TestFlight and App Store builds pass
   the iOS dogfood contract against a cmux-next Mac.
3. **P2, daemon-protocol lane (L3).** Add an irx capability and lane that
   splices a daemon `mux-control` stream, per machine (local, and cloud via
   the Mac's link socket). Advertise it in `mobile.host.status`
   capabilities. Old phones never ask for it.
4. **P3, iOS rewrite on cmux-tui.** Generalize `CmuxTUIControl` over a carrier
   protocol; route Mac and cloud machines through the P2 lane; drop the
   `mobile.terminal.*` and `mobile.workspace.*` client code. Non-terminal
   features stay on their RPCs. Ship behind the capability check with
   fallback to the shim.
5. **P4, retire the shim** after a minimum-version gate (the iOS app shows
   "update the app" for builds without P3). Delete the section 3.5 list.
6. **P5 (optional), Mac-less reach.** Link `cmux-terminal-client` (L1) or
   equivalent, add Stack-grant admission to cmux-remote, and give cloud VMs an
   Iroh or userspace-WireGuard route for phones. Needs a bake.

## 4. Risks and decisions for the user

- **R1. `terminal.render_grid` fidelity.** The shipping phone replays from a
  Mac-rendered grid, not bytes, because "a byte tail is not a complete screen
  state for TUIs" (`Sources/Mobile/MobileTerminalByteTee.swift:11-16`). The
  shim must produce equivalent grids from the daemon (render mode or a
  mirror surface). This is the highest-risk part of P1.
- **R2. The shim is not small.** `Sources/Mobile` is 17.1k lines and
  `CmuxMobileHost` 4.3k. Keeping it in cmux-next contradicts REWRITE goal 9
  ("do not port old Swift"). Porting it is the lazy-looking but safe choice;
  a clean rewrite of the shim still has to reproduce the exact wire shapes.
- **R3. Simulator pane conflict.** `inventory.md` D1 proposes deleting
  `CmuxSimulator`. `Sources/Mobile/MobileSimulatorStream*` and
  `MobileWorkspaceListObserver` import it, and the phone calls
  `mobile.simulator.*`. Deleting it breaks a shipped iOS feature.
- **R4. Two Iroh stacks.** irx (Swift, iroh-ffi 1.2.0 fork) and cmux-remote
  (Rust iroh 1.0.3) differ in ALPN, admission, and relay config. L1 puts both
  in the phone. Wire compatibility between the two iroh versions is unproven.
- **R5. Cloud changes are bake-gated.** Any new VM listener (Iroh, enrolled
  auth for phones) reaches only machines baked after the change, unless it is
  enabled by a file the upgraded binary reads when present.
- **R6. Cross-machine placement.** Today a cloud terminal can sit in a local
  split. The daemon-tree model makes each machine's layout its own. Decide if
  mixed workspaces are required for v1.
- **R7. Mac-awake dependency.** L3 and cloud option A need the Mac app
  running and awake. Same as today for Mac terminals; new for cloud terminals
  on iOS only if the user expects phone-to-VM without a Mac.
- **R8. Authority.** Every daemon client has full authority. irx v2 admission
  is the only phone admission today; if L1 bypasses the Mac, the daemon must
  enforce an equivalent account-bound check. Do not ship a direct phone listener that relies on
  invitation approval alone for normal users.
- **R9. Splice authority.** The daemon classes Unix clients as trusted
  local (`T/crates/cmux-tui-core/src/server.rs:3644-3656`), so a phone spliced
  onto the Unix socket could call local-admin commands such as
  `shutdown-daemon`. The splice must either filter local-admin commands or the
  daemon must learn a "remote via frontend" transport class. WebSocket
  clients already get everything except local-admin
  (`T/spec/transports.md:288-290`); reuse that class.
- **R10. Session identity.** The contract note uses session `cmux-dev-<tag>`
  for dev builds; the iOS compatible-tags grant (PR 10619) binds a phone to a
  Mac tag. Map tag → daemon session in the shim so tag grants keep meaning.

Decisions:

- **Q1.** Approve L3 (irx lane splicing daemon `mux-control`) as the iOS
  transport, with L1 deferred? Recommended: yes.
- **Q2.** Keep the mobile RPC compat shim in cmux-next (port or rewrite about
  21k lines) until a minimum iOS version gate? Recommended: yes; the
  alternative is breaking every shipped iOS build on the first cmux-next
  release.
- **Q3.** Keep `CmuxSimulator` in v1 because iOS depends on it (overrides
  inventory D1)? Recommended: keep the stream service, drop the Mac pane UI.
- **Q4.** Mixed-machine workspaces in v1 (R6)? Recommended: no; machine
  sections only, add cross-machine projection later.
- **Q5.** Phone-to-cloud without a Mac (P5) in scope for the first iOS
  rewrite? Recommended: no.
- **Q6.** Minimum iOS version policy for retiring the shim (P4): time-based or
  install-share-based?

## 5. Remote daemon compatibility (2026-09-30)

A Cloud machine keeps the cmux-tui its image baked until someone upgrades it
in place, so the Mac talks to daemons of many builds at once. This section is
the contract for that.

### 5.1 Negotiation

The attach reply is the remote daemon's own `identify`: the headless
`remote connect` link forwards every line unchanged, so the app reads the VM's
`protocol`, `version`, `build_commit`, `capabilities`, `session` (name) and
`registry_id` (the session UUID, created once in the session's SQLite `meta`
table and stable across restarts, upgrades and host adoption; every deployed
build reports it). `generation` fences one boot and is not an identity.

`DaemonCompatibility` (CmuxNextDaemon) turns that into one level per machine:

| Level | Meaning | App |
| --- | --- | --- |
| current | every capability the app uses | normal |
| limited | the 7 required capabilities, some of `DaemonCapabilities.optional` missing | features behind the missing ones are off; header "Update available", tooltip lists build and missing capabilities; a refused action says "update this Cloud machine" |
| incompatible | a required capability, the protocol or the app is wrong | header "Update needed" with the reason; the connect loop waits for an event (app activation, network change, the link socket changing) and connects to the updated build behind the same link; no timer |

`cloud.machines` (control socket) and Cloud Diagnostics report session id,
session name, protocol, version, commit, level and missing capabilities per
machine. `MachineRegistry.daemon(session:)` finds a daemon by session UUID.
The data-model agent owns the later `session-identity-v1` alias and qualified
IDs (`plans/cmux-next/data-model.md`); the app works without them.

### 5.2 Inventory

Local = the pinned cmux-tui (`scripts/cmux-next/cmux-tui.pin`, `51b6863`
on 2026-09-30). Cloud today = image `tui3412812` (this branch's web) or
`tui02dac3c` (main's web, the production default since 2026-09-30). Cloud
after = in-place upgrade to the pin (5.3).

| Feature | Daemon dependence | Local | Cloud today | Cloud after |
| --- | --- | --- | --- | --- |
| Attach, tree, terminals, splits, columns, undo | 7 required capabilities | yes | yes | yes |
| Session identity | `registry_id` in `identify` | yes | yes | yes |
| Parallel host start | 8-worker pool, no capability | yes | no: serial launch; a burst can hit the 5 s start deadline (typed `terminal may appear`) | yes |
| Typed start deadline | app only | yes | yes | yes |
| Latest active client holds geometry | `set-client-sizing exclusive`, `view-attachment-lease-v1` | yes | 3412812 yes; 02dac3c maps the claim onto its shared-sizing reducer (`use_only_client_size`), not verified end to end | yes |
| Reply order (a later request may answer before `new-tab`) | app matches replies by id; the link uses one lane | yes | yes | yes |
| Window records, a window has a workspace | app only, local personal projection | yes | not sent to remote | not sent to remote |
| Closing the last tab closes the workspace | app (drag path `close-workspace`, empty-workspace repair) | yes | yes | yes |
| Reopen Closed Tab (terminal kept 30 s) | `terminal-reap-v1`, `terminal.project` | yes | no: a close ends the terminal, reopen starts a new shell | yes |
| Agent roster fenced by hook session | daemon only | yes | no | yes |
| Workspace groups, metadata, tab metadata (pin), app browser tabs, tab drag, notification ack, tab groups, saved tab groups, terminal env, placement env, batch close | optional capabilities | yes | no, gated per capability | yes |
| Per-terminal resource queries | none yet (`process-info` only) | no | no | no |
| `loopback-forward-v1` (in progress, another agent) | optional capability | when landed | no | after the next pin |

iOS in cmux-next splices only to the Mac's local daemon (`DaemonLanePolicy`,
resource `local`); it does not reach a Cloud daemon yet.

### 5.3 Version and update path

- A new machine runs its image's cmux-tui (`cmuxTuiCommit` in
  `web/services/vms/images/manifest.json`); nothing installs one at create.
  Matching the pin for new machines needs a bake from the pin.
- A running machine takes the pin in place without losing terminals:

  ```bash
  cd web
  FREESTYLE_API_KEY=... bun scripts/upgrade-fleet-cmux-tui.ts --vm <vm-id> \
    --commit "$(awk -F= '$1=="commit"{print $2}' ../scripts/cmux-next/cmux-tui.pin)"
  ```

  The guest script SIGTERMs only the daemon; the supervisor starts the new
  binary, which adopts every `__terminal-host`. Cost: the link drops and
  resumes, bytes written while no daemon runs come back as a snapshot (not
  byte-exact), per-connection geometry claims and attach leases are
  re-established by the app on reconnect, and reap and idle clocks restart
  (a close can be late, never early). The script rolls back when the new
  daemon does not serve. The pin and main both use registry schema 15 (the
  pin adds tables); that a main build opens a registry the pin has written
  is not tested, so treat the upgrade as one-way.
- The pin lacks main's 18 cmux-tui commits after `fde44232` (shared terminal
  sizing, replay resume inside escape sequences, SSH hardening), and main
  lacks the branch's. Upgrading a machine that legacy Macs also use drops
  those for them. Converge cmux-tui (merge main's `cmux-tui/` into this
  branch, then re-pin) before any production machine takes the pin.
- `files.cmux.com` serves binaries with `cf-cache-status: DYNAMIC` (no edge
  cache); on 2026-09-30 a VM fetched the 42 MB musl binary at 6-130 KB/s and
  one run failed with an HTTP/2 stream error (the script left the machine
  unchanged). Fleet upgrades need an edge cache rule or a resumable fetch.
