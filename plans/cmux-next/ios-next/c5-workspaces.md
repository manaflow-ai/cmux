# C5 `workspaces`: the realtime workspace list on the phone

Status: lane C5 of PLAN.md, 2026-10-06. Branch `feat-cmux-next-ios-c5-workspaces` off
`feat-cmux-next-ios` (A0, A1, A2, A3, C9, C10, C16 merged there). Binding: PLAN.md section 4,
OWNERSHIP-PRINCIPLES.md, a1-shell.md (2.3 `WorkspaceSource`, parity 1.6 hidden computers, 1.8, 1.9),
a0-rpc.md (5.2 workspace family), b1-control-do.md (host socket, mirror, op forwarding), a2-ghostty.md
(`TerminalByteSource`), c9-ssh.md (`ShellContent(screens:)`).

## 1. Ownership

| State | Owner | On the phone |
| --- | --- | --- |
| Workspaces, panes, tabs, names, pins, groups, colors, order | each Mac's workspace store (`workspace:<host>` stream, mirrored by `HostDO`) | confirmed mirror per host + one ordered intent log |
| Tab status and unread | the Mac (session host facts rolled up by its store) | mirror only |
| Preview line of a tab | the Mac (session host fact, published by the store) | mirror only |
| Host presence (`online`, `sleeping`, ...) | `HostDO` (`host:<host>`) | channel connection state |
| Which Macs are paired | B6 registry (`DeviceRegistry`) | host directory |
| Hidden machines, machine order, filter, sort, collapsed sections, selection | this client (view state) | `UserDefaults`, never synced |

The phone never infers a close or a read: mark read and close are ops; the row leaves the list on
the owner's `workspace.remove` echo (the intent log hides it meanwhile).

## 2. Wire additions (A0 catalog, additive)

The family in a0-rpc.md 5.2 has no close, no read and no preview. Added to `schemas/mobile-rpc`
(catalog, schemas, fixtures), `CmuxMobileWire` (`MobileCatalog.v1`) and `@cmux/protocol`
(`mobileCatalog`), all in one commit so the catalog equality tests hold:

- op `workspace.close {workspace}`: the owner closes every tab and removes the workspace
  (`workspace.remove` echo). Errors `workspace.not_found`.
- op `workspace.read {workspace}`: the owner clears unread on every tab of the workspace
  (`workspace.status.set` echoes). Errors `workspace.not_found`.
- owner `workspace.preview.set {tab, preview}`: the tab's last meaningful output line or agent
  message, at most 400 characters, sanitized of control sequences by the Mac. The Mac sends it
  only while `host:` reports `viewers > 0`, at most once per second per tab, so an idle phone
  costs no DO requests.
- optional fields: `Tab.preview` (string), `Workspace.group {id, name}` (the sidebar group the
  workspace is filed in), `Workspace.activity_at` (ms, last output or status change).

Caps (`hello.ok.caps`): `workspace.close`, `workspace.read`, `workspace.preview`. The phone shows
Close and Mark as Read only when the host socket negotiated the cap; without `workspace.preview`
rows show the tab title as their subtitle.

## 3. Modules

| Module | Owns | Imports |
| --- | --- | --- |
| `CmuxiOSWorkspacesCore` | wire decode, `HostWorkspaceMirror`, `WorkspaceIntentLog`, `ControlPlaneWorkspaceSource`, `WorkspaceControlChannel` seam, host directory, `WorkspaceListModel` (filter, sort, sections), machine colors, view preferences, `WorkspaceTerminalSourceFactory` seam, picker choices | Foundation, FeatureKit, CmuxMobileWire, CmuxTerminalRenderCore |
| `CmuxiOSWorkspaces` | Workspaces tab (list, detail, machines sheet, rename/close UI), frame coalescer, mock terminal factory, workspace picker screen | UIKit, Core, Design, CmuxiOSTerminal |

FeatureKit gains (additive, defaults keep every caller compiling): `WorkspacePane`,
`WorkspaceSurface`, `WorkspaceSurfaceKind`, `WorkspaceGroup`, `WorkspaceHostKind`;
`WorkspaceSummary.panes/preview/isPinned/group/color/order`; `HostWorkspaces.kind/capabilities/
offlineReason`; `WorkspaceIntent.markRead`; `WorkspaceCapabilities`; `WorkspacePickerRequest`,
`WorkspaceSelection`.

## 4. The control-plane seam

B1's `ControlPlaneClient` is uncommitted on its branch, so Core codes against a protocol whose
shape is that client's, one instance per host socket:

```swift
public protocol WorkspaceControlChannel: Sendable {
    func states() async -> AsyncStream<WorkspaceChannelState>     // connecting, live(path, caps), offline(reason)
    func updates() async -> AsyncStream<WorkspaceStreamUpdate>    // .snapshot(SnapshotFrame) | .event(EventFrame)
    func submit(_ op: OpFrame) async throws -> WorkspaceOpOutcome // .applied(ResultFrame) | .rejected(RejectFrame)
    func requestSnapshot() async
}
```

The adapter over B1 is mechanical: `states` maps `ControlPlaneState` (`connected(hello)` gives the
caps), `updates` is `subscribe("workspace:<host>")` with `StreamUpdate` cases renamed, `submit` is
`submit(_:)` with `OpOutcome` renamed, `requestSnapshot` resubscribes. B1 fills
`AppContainer.workspaceChannels` (a `WorkspaceChannelFactory`); until then the real source shows
every paired Mac as offline with the reason "Control plane unavailable", which is the truth.

`WorkspaceHostDirectory` streams the hosts to mirror: `DeviceRegistryHostDirectory` maps trusted
Macs from B6's `DeviceRegistry`. SSH hosts (tmux, cmux-tui sessions over C9's connection) enter
later as descriptors of kind `.ssh` with their own channel from the same factory; the list already
groups and colors by host kind.

## 5. `ControlPlaneWorkspaceSource` (the real `WorkspaceSource`)

One actor. Per host: a channel, a `HostWorkspaceMirror` and a `WorkspaceIntentLog`.

- Snapshot replaces the mirror at its `seq` and settles every pending intent named in `decided`.
- Event: applied only when `seq == mirror.seq + 1`; a jump is a gap: the mirror keeps showing its
  last state, marks itself resyncing and calls `requestSnapshot()` once; events are dropped until
  the snapshot arrives. An event at or below the mirror seq is a duplicate and is ignored.
- Visible state is mirror + pending intents (rename shows the new name, close hides the row, read
  clears unread). An intent leaves the log on its result (once the mirror reached the result's
  revision) or reject (receipt `.refused`), never on a timer.
- Intents to a host whose channel is not live throw `FeatureSourceError.offline` and nothing is
  logged (U5). A submit that throws (socket closed mid-flight) removes the overlay and throws
  `.offline`; the B1 client resends the frame with the same key on reconnect and the owner dedupes.
- Every change bumps one aggregate revision and yields one snapshot into a newest-only buffer, so
  a burst of events costs the UI one diff; the list then coalesces to one apply per display frame.

## 6. List model and screens

`WorkspaceListModel.make(hosts, options, preferences)` is pure. Options: filter (`all`, `unread`,
`needsInput`, `running`), sort (`owner order` with pinned first, `recent activity`, `name`),
grouping (`by machine`, `flat`). Preferences: hidden machine ids, machine order. Output: sections
with stable ids (`host:<id>`, then `host:<id>/pinned`, `host:<id>/group:<g>`, `host:<id>/all`, or
`flat`) and rows carrying title, preview, status, unread, machine name and color, reachability.
Status rolls up tabs by severity (`failed > waitingForInput > running > idle`), as
status-indicators.md section 3 orders them.

Workspaces tab (UIKit, compositional list, diffable, reconfigure on change, subscribed in
`viewWillAppear`, cancelled in `viewDidDisappear`):

- Machine header: color dot, name, offline reason, workspace count. Rows: status glyph, title,
  preview line (secondary, one line), unread badge, disclosure. In flat grouping the subtitle
  leads with the machine name.
- Swipe and context menu: Mark as Read, Rename (alert with a text field), Close (destructive
  confirmation). Each is a `WorkspaceIntent` with a fresh `IntentKey`; a refused or offline result
  shows an alert. Actions are disabled on offline hosts and when the cap is missing.
- Toolbar menu: filter, sort, grouping, Machines (sheet: show/hide toggles and reorder).
- States through `UIContentUnavailableConfiguration`: loading, no paired Mac, every Mac offline,
  filter matches nothing, all workspaces on hidden machines.
- Detail: one section per pane, one row per surface (kind glyph, title, status, unread, preview);
  live while visible; a closed workspace shows "This workspace was closed". Tapping a terminal
  surface asks the `WorkspaceTerminalSourceFactory` for a `TerminalByteSource` and pushes A2's
  `TerminalViewController`. Browser and agent surfaces show their record (C2 and the agent GUI
  later).
- Accessibility: rows read "title, machine, status, N unread, preview"; custom actions mirror the
  swipe actions; Dynamic Type through text styles; headers are `.header` traits.
- Coalescing: `FrameCoalescer` keeps the newest snapshot and arms a one-shot `CADisplayLink`
  only while a value is pending; idle costs zero wakeups.

## 7. Seams for other lanes

- C1 terminal: `WorkspaceTerminalSourceFactory.makeSource(for: WorkspaceTerminalTarget)`
  (`hostID`, `workspaceID`, `surfaceID` `tab_…`, `terminalID` `term_…`, `title`). C1 sets
  `AppContainer.terminalSources`; the default is `MockWorkspaceTerminalSourceFactory`
  (A2's mock session host).
- C8 composer: `WorkspacesFeature.makePicker(request:completion:)` returns a view controller to
  present; `WorkspacePickerRequest {hostID?, allowsNewWorkspace}` and `WorkspaceSelection
  {hostID, workspaceID?}` (nil workspace = new) are FeatureKit types, so C8 receives the closure
  from `ShellComposition` and never imports this module. `WorkspacePickerModel.choices` is the
  pure list behind it.
- C7 notify / C16 router: `WorkspacesFeature.open(hostID:workspaceID:)` selects and pushes a
  workspace detail (deep link `workspace` route).
- C15 search: `WorkspaceListModel` rows are the search corpus.

## 8. Tests (Swift Testing, `CmuxiOSWorkspacesCoreTests`)

Wire decode of the A0 fixture state; mirror events (upsert, remove, tab upsert and remove, status,
preview), duplicate and gap detection; intent log overlay and settlement (result, reject, decided
in snapshot); source end to end over a fake channel (snapshot then events, gap triggers exactly
one resync, rename overlay then echo, reject refuses and restores, offline refuses without
logging, host removal from the directory); list model (filters, sorts, pinned and group sections,
hidden machines, machine order, status roll-up, flat grouping); machine colors are stable; picker
choices. They run with `swift test` on macOS through a scratch package that links the same sources,
and compile for the simulator.

## 9. Not here

Presence announce of the viewed workspace (B1's `presence.set` has no workspace field; needs an
A0 field), new workspace from the phone (ops exist for create only), Cloud machines in the list
(C12). Group collapse and rename, drag reorder, the customize sheet and SSH session workspaces
landed in E3 (e3-workspaces.md).

## 10. Status (2026-10-06)

Done: wire additions (catalog, schemas, fixtures, Swift and TS catalogs; `CmuxMobileWire` tests 16
green, TS vitest not run here: no `node_modules`), FeatureKit types, `CmuxiOSWorkspacesCore` and
`CmuxiOSWorkspaces` as above, wired into the shell (`ShellContent(screens:)` `.workspaces`;
`AppContainer.realFactories.workspaces` is `ControlPlaneWorkspaceSource` over the resolved device
registry with `UnavailableWorkspaceChannelFactory`; DEBUG defaults to the mock, so use
`CMUX_IOS_SOURCE_WORKSPACES=real` or the DEV switch). 50 Swift Testing tests in
`CmuxiOSWorkspacesCoreTests` pass with `swift test` on macOS through a scratch package (plus the 13
FeatureKit tests); `CmuxiOSApp`, `CmuxiOSWorkspacesCoreTests`, `CmuxiOSShellTests` and
`CmuxiOSFeatureKitTests` compile for `arm64-apple-ios17.0-simulator` with SwiftPM.

Seams for other lanes: B1 swaps `UnavailableWorkspaceChannelFactory` in `AppContainer` for a
`WorkspaceChannelFactory` over `ControlPlaneClient`; C1 sets `AppContainer.terminalSources`; C8
calls `WorkspacesFeature.makePicker(request:completion:)` (passed from `ShellComposition`); C7/C16
call `WorkspacesFeature.open(hostID:workspaceID:)`.

Unverified: everything visual (no simulator run), VoiceOver and Dynamic Type at large sizes, the
per-frame coalescing under a real event burst, the B1 adapter (written against B1's uncommitted
`ControlPlaneClient` shape), and the Mac side of the new ops (B5 must implement `workspace.close`,
`workspace.read`, `workspace.preview.set` and advertise the caps). Tagged build not attempted
(known blocked: no fleet manifest, dev backend VM unreachable).

### Update after merging B1/B5 (2026-10-06)

- `ControlPlaneWorkspaceChannelFactory` replaces `UnavailableWorkspaceChannelFactory` whenever an
  API origin exists: one `ControlPlaneClient` per paired Mac on `/v1/wire/host/<host>` as this
  install, subscribing `workspace:<host>` and `host:<host>`. Live = negotiated socket and Mac
  `online`; caps come from the Mac's `host.caps.set`; sleeping/paused/offline show their reason;
  undecided ops are resent when the Mac returns; `presence.set {active: true}` while subscribed.
- `epoch` (B5): optional on `snapshot`, `event`, `subscribe` in A0 (Swift, TS, schemas). The mirror
  drops its state when an event carries another epoch than its snapshot and takes the next one.
  Gap: `HostDO` stores snapshot state only, so it drops the epoch on snapshots, and B1's client
  dedupes by seq before the phone sees the epoch; both need a B1 follow-up.
- CmuxMobileHost serves `workspace.close`, `workspace.read` (policy-scoped, no command params) and
  `workspace.preview.set` (sanitized, throttled 1/s per tab with a trailing flush) and advertises the
  three caps. Viewer gating of previews (send only while `host:` viewers > 0) is not implemented:
  the uplink does not mirror `host:`.
