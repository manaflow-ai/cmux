# Desktop cmx Backend Migration Plan

Goal: replace the macOS app's Swift-owned backend completely with the Rust
`cmx` runtime. The final architecture has one authoritative backend for desktop,
iOS, CLI/TUI, remote, and future web clients. Swift/AppKit remains the native UI
renderer and macOS integration layer, but it stops owning workspace, pane,
terminal, persistence, socket API, and command state.

## Target Architecture

`cmx` owns:

- Workspace, space, pane, panel/tab, terminal, notification, activity, and
  persistence state.
- PTY lifecycle, shell environment, scrollback, terminal resize arbitration,
  session restore, and detach/reattach.
- The public command model currently exposed through `cmux` socket v2 and CLI
  commands.
- tmux-compat translation targets, agent integrations, hook state, buffers, and
  command responses.
- Remote/VM/iroh/WebSocket session plumbing at the model layer.

The macOS app owns:

- Windows, menus, Settings UI, AppKit focus, local pasteboard integration, file
  dialogs, drag/drop, and native system permissions.
- Rendering native views from `cmx` snapshots.
- Local renderer workers that cannot live inside the headless Rust daemon, such
  as WKWebView browser panes and GhosttyKit surfaces.
- A thin compatibility socket during migration, eventually forwarding to `cmx`
  or being replaced by the `cmx` socket with the existing `cmux` CLI contract
  preserved.

The important rule is one-way authority: Swift renders `cmx` state and sends
commands; it does not mutate an independent app model for the same behavior.

Desktop does not expose `cmx` spaces as a separate UI concept in the first
cutover. Every desktop workspace maps to exactly one default `cmx` space. The
protocol and Rust model may keep spaces internally for iOS/TUI/future clients,
but the desktop projection treats the active space as an implementation detail.

The migration uses a hard cutover feature flag:

- Enabled: all new desktop terminal workspaces/panels are `cmx` backed.
- Disabled: the app falls back to the current Swift backend so incremental
  development can continue without blocking the rest of the app.
- The flag must be easy to disable through an environment/defaults path and
  should be tag-scoped in debug builds.

## State Ownership And Storage

Rust `cmx` is the ground truth for durable and shared state. Swift may keep
transient projections and renderer-local caches, but it must not persist or
mutate a competing durable model for migrated behavior.

`cmx` owns durable state:

- Workspaces, the single default space for each desktop workspace, panes,
  splits, panel trees, surface/tab identity, stable IDs, UUID/ref mapping, and
  command-resolution state.
- Terminal PTY lifecycle, cwd, title, process metadata, ports, scrollback,
  read-screen/capture-pane data, replay, resize arbitration, and relaunch
  restore.
- Command model, hooks, buffers, tmux compatibility, agent integration state,
  notifications, activity, unread markers, progress, and log metadata.
- Browser panel model: URL, title, history cursor, profile ID, proxy context,
  worker lease, sidebar metadata, and restore policy.

The macOS app owns only native and renderer-local state:

- `NSWindow` objects, menus, toolbar/menu validation, AppKit focus, first
  responder state, pasteboard, dialogs, drag/drop, local permissions, and other
  OS-only integration points.
- GhosttyKit renderer instances derived from `PtyBytes` replay/live bytes.
- WKWebView instances plus local WebKit data, caches, and cookies keyed by
  `cmx` browser profile ID.
- Transient UI state such as hover, temporary selection affordances, local
  inspector expansion, and in-flight native worker tasks.

State storage must be explicit:

- The existing Rust snapshot path
  (`$XDG_STATE_HOME/cmux-cli/snapshot.json` or
  `~/.local/state/cmux-cli/snapshot.json`) is useful scaffolding only. It is
  structure-only today and does not capture enough scrollback, environment, live
  shell, replay, or browser restore state for desktop cutover.
- Local macOS release builds should launch `cmx` with a platform state directory
  such as `~/Library/Application Support/cmux/cmx/`.
- Tagged debug builds should launch `cmx` with an isolated tag-scoped state
  directory, for example `/tmp/cmux-cmx-<tag>/cmx-state/`. Do not use
  `/tmp/cmux-<tag>` because `reload.sh` reserves that as a DerivedData
  compatibility symlink.
- Remote/Linux `cmx` keeps durable state on the backend host under its platform
  state directory. The macOS app does not mirror durable backend state locally.
- Local socket paths must stay short and tag-scoped because of AF_UNIX path
  limits, for example `/tmp/cmux-cmx-<tag>/native.sock`.

Migration is one-way:

- On first `cmx` backend launch, Swift reads the old desktop session snapshot
  once and sends an import command to Rust.
- Rust writes an import marker/fingerprint, stores a read-only backup reference
  to the old file, and owns all future persistence.
- After import there is no dual-write path. Disabling the hard cutover flag is a
  development fallback only, not supported bidirectional sync.

## IPC Contract

Core state IPC should not be XPC or FFI. Local macOS uses AF_UNIX with
4-byte big-endian length-prefixed MessagePack frames. The same versioned
message schema should be usable over WebSocket and iroh for remote/Linux
backends.

Use two local sockets:

- Internal native socket: Swift desktop client to Rust `cmx` daemon. This socket
  carries `HelloNative`, `Welcome`, `NativeSnapshotV2`, `PtyBytes`,
  `NativeInput`, `NativeLayout`, `Command`, `CommandReply`,
  `WorkerRequest`, `WorkerReply`, `Ping`, `Pong`, and structured errors. It is
  0600 and tag-scoped.
- External compatibility socket: the existing `CMUX_SOCKET_PATH` contract for
  the `cmux` CLI and socket API. The final target is
  `cmux CLI -> Rust cmx compat socket -> Rust state`. A thin Swift proxy is
  acceptable only as a temporary migration layer.

Handshake and command flow:

- Swift sends `HelloNative` with `protocol_version`, `client_kind = desktop`,
  `client_id`, `window_id`, and capabilities such as `libghostty_pty_bytes`,
  `webview_worker`, `pasteboard`, `notifications`, and `file_picker`.
- The macOS bridge now passes the real `MainWindowContext.windowId` when it
  connects. Rust stores that ID on the native view and compatibility bridge
  registration, so `system.capabilities.nativeBridge.clients` and `window.list`
  expose the AppKit window UUID instead of only the synthetic `window:0` ID.
- Rust native snapshots carry the window ID used to build the projection, and
  compatibility payloads such as `surface.list`, `pane.list`, and `debug.layout`
  report that same window ID.
- Rust keeps a transient native window projection map keyed by the AppKit window
  UUID. Compatibility snapshots can resolve explicit `window_id` parameters
  against that map, `window.list` reports the selected workspace for each known
  native window, and local refs such as `window:1` resolve to the connected
  native UUID instead of leaking synthetic IDs.
- Rust persists that native-window projection in its `snapshot.json` and writes
  a small `native-windows.json` sidecar for Swift startup. Swift uses those
  Rust-owned window IDs when creating the first and additional desktop windows,
  while old Swift session data is limited to geometry/sidebar restore under the
  cutover flag.
- `workspace.select` and `workspace.move_to_window focus=true` update that Rust
  native-window projection map, and connected native sessions adopt their saved
  projection on model changes. Tagged smokes verify that `window.list` and
  `debug.layout` reflect the selected workspace after those commands.
- Debug terminal compatibility payloads also use the snapshot window UUID, so
  `debug.terminals` no longer mixes real AppKit window IDs with synthetic
  `window:0`-style values.
- Rust-local compatibility command payloads now consistently use the resolved
  native window UUID instead of synthetic window IDs. Focused smokes cover
  `system.identify`, `system.top`, `surface.send_text`, `surface.move`,
  `surface.split_off`, `surface.refresh`, `surface.clear_history`, and
  `workspace.remote.status`.
- App termination waits for the native connection to close and for
  `CmxDesktopDaemon.stop()` to complete before replying to AppKit termination,
  so tagged desktop-cmx runs do not leave a stale `cmx` child holding the
  native/compat sockets.
- Rust replies with `Welcome` and the first full `NativeSnapshotV2` carrying a
  revision.
- UI commands carry a `request_id` and, where useful, an `expected_revision`.
  Rust sends `CommandReply` and then the authoritative snapshot/event. Swift
  applies revisions; it does not complete mutations from a local model.

Terminal byte flow:

- Rust sends `PtyBytes(surface_id, bytes, seq)` from replay and live PTY output.
- Swift feeds those bytes into a GhosttyKit manual IO renderer path.
- Swift sends `NativeInput(surface_id, bytes)`, `NativeLayout` for visible
  terminals, and `RequestPtyReplay(surface_id, from_seq?)`.
- Resize arbitration remains Rust-owned, with the existing
  smallest-visible-client-wins policy as the single rule.

Native worker flow:

- Swift registers platform capabilities. Rust sends `WorkerRequest` messages for
  browser eval/click/screenshot/download/dialog operations plus native
  file/pasteboard/notification operations.
- Swift replies with `WorkerReply`. Browser metadata events flow Swift to Rust,
  and Rust decides the durable state transition.

## Swift Concurrency And Actor Isolation

New Swift integration code follows the `swift-guidance` concurrency model:

- Use Swift concurrency first: `async`/`await`, stored `Task` handles,
  `AsyncSequence`/`AsyncThrowingStream` for inbound frames, and actors for
  shared mutable state.
- Long-lived connection, daemon, renderer, and worker loops must keep explicit
  `Task` handles and cancel them from the owning lifecycle boundary. Do not
  start untracked fire-and-forget tasks for backend work.
- Do not use ad hoc `DispatchQueue.main.async`, background `DispatchQueue`, or
  callback-style coordination in app logic. If an Apple or C callback requires a
  queue, hide it inside the lowest-level transport/renderer adapter and cross
  into app state with `await MainActor.run` or `Task { @MainActor in ... }`.
- `CmxConnection` should be an `actor` that owns transport state, frame
  sequencing, reconnect, ping/pong, and cancellation.
- `CmxDesktopStore` and UI/renderer view models should be `@MainActor`
  projection objects. They apply Rust revisions and expose immutable snapshots
  plus command closures to SwiftUI/AppKit.
- Wire DTOs, snapshots, commands, and command replies should be `Sendable` value
  types. In MainActor-by-default targets, mark pure DTOs and protocol
  definitions `nonisolated` so they do not inherit UI isolation accidentally.
- Protocols with async requirements should be `nonisolated`, allowing actor
  implementations to run on their own executor rather than the main actor.
- If a Swift 6 async helper is intentionally off-actor, mark that explicitly
  with `@concurrent` instead of relying on `nonisolated async` semantics.
- Use `Logger`/unified logging for bridge diagnostics, with file-scoped logger
  constants marked `nonisolated`. Do not add `print()` debugging to shipped app
  code.
- Renderer and native-worker callbacks must enqueue into an actor or
  `AsyncStream`; they must not mutate stores directly from C callbacks or view
  body computations.
- SwiftUI projections must remain read-only. A function used by `body`,
  `ForEach`, `List`, or lazy row construction must not write state, schedule a
  `Task { @MainActor in ... }`, or call `DispatchQueue.main.async`.
- Snapshot list boundaries must pass immutable row values plus action closures,
  not `ObservableObject`, `@Observable`, store, or binding references that can
  invalidate every row on unrelated backend changes.
- The first implementation PR must include a compile gate for the new Swift
  package/transport/store with no strict-concurrency or actor-isolation warnings.

Swift-guidance implementation gates:

- `CMUXCmxProtocol` and any shared desktop/iOS bridge package should be built
  with strict concurrency. Wire DTOs, protocol envelopes, command replies, and
  snapshot value types are `Sendable` and explicitly `nonisolated`.
- Service protocols with async requirements must be `nonisolated` so actor
  implementations run on their own executor instead of inheriting MainActor from
  app build settings.
- `CmxConnection`, daemon supervision, compatibility-socket forwarding, and
  browser/native worker routing are actors or actor-owned async loops, not
  callback-driven coordinators.
- Any long-lived loop has an owning lifecycle object with a stored task handle
  and a cancellation path. `Task { ... }` without storage is acceptable only for
  a narrow UI handoff that cannot outlive the current event.
- If an Apple framework, Network callback, or C callback requires a
  `DispatchQueue`, the queue is contained in the adapter file. That adapter
  emits values into an actor or `AsyncStream`; it does not mutate app state,
  stores, or SwiftUI projections directly.
- UI-bound projection objects are `@MainActor @Observable` and apply Rust
  revisions in explicit methods. View `body`, row builders, `ForEach`, `List`,
  and lazy-stack projections stay pure and never schedule state mutation.
- Snapshot projection setters are idempotent. Workspace title, description,
  color, and similar projection fields return early when the value already
  matches Rust state, avoiding repeated `@Published` writes on every revision.
- File-scoped diagnostics use `nonisolated private let logger = Logger(...)`
  or the existing debug log shim. Do not introduce `print()` debugging into
  shipped bridge/app code.
- Off-actor async helper work that is intentionally CPU or IO bound uses
  explicit `@concurrent` where the project toolchain supports it, rather than
  depending on changing `nonisolated async` executor semantics.
- Code review for every bridge PR includes a Swift-guidance pass over
  concurrency, actor isolation, logging, and SwiftUI projection boundaries.

## Current Baseline

- The existing desktop app still uses `TabManager`, `Workspace`, `TerminalPanel`,
  and `TerminalController` as the authoritative backend.
- `cmx` already has the Rust daemon, MessagePack protocol, PTY model,
  multi-workspace/multi-space/pane tree, WebSocket transport, native snapshots,
  native terminal layout, and iOS `HelloNative`/`NativeInput`/`NativeLayout`
  clients.
- `rust/cmux-cli/clients/swift` is only a scaffold for macOS. Its attach loop is
  not implemented.
- iOS has the best working Swift client path today; desktop should reuse that
  protocol shape rather than the older scaffold that mentions `libghostty-vt`.
- The desktop renderer must use the same GhosttyKit/libghostty PTY-byte path as
  iOS: `cmx` sends PTY replay/live `PtyBytes`; Swift feeds those exact bytes into
  GhosttyKit.

## Non-Negotiable Cutover Requirements

- A visible `cmx`-backed terminal must be fully usable before the branch is
  considered useful: type, paste, resize, scrollback/read-screen, focus, split,
  close, sidebar metadata, and relaunch restore.
- Session restore must be implemented in `cmx` and must import existing desktop
  restore data once. This feature cannot ship until restore parity is proven.
- Existing `cmux` socket API and CLI behavior are compatibility contracts. Text
  output, JSON output, refs, UUIDs, env defaults, password behavior, and
  tmux-compat flows must remain compatible.
- Browser panel state is owned by `cmx` at the lifecycle/session/proxy level,
  even though WKWebView execution stays in the macOS app.
- Ghostty terminal appearance is part of the terminal contract. The visible
  cmx-backed GhosttyKit surface must respect the backend Ghostty config for
  theme, font, cursor shape, and cursor blink behavior, including shell
  integration cursor resets during typing.

## Migration Phases

### Phase 0: Contract Freeze

Produce a written contract before moving app behavior:

- Define `NativeSnapshot` v2 for desktop: windows, workspaces, spaces, panel
  tree, selected IDs, panel tabs, terminal metadata, browser metadata,
  notifications, activity, progress, logs, unread markers, pinned state, colors,
  descriptions, and command availability.
- Define `ClientCapability` messages for desktop-only renderer workers:
  browser execution, file picker, pasteboard, notifications, and optional
  screenshot/export operations.
- Define stable IDs and CLI handle mapping. Existing `workspace:N`, `pane:N`,
  `surface:N`, `window:N`, and UUID outputs must continue to work even if `cmx`
  internally uses numeric IDs.
- Freeze the state ownership and storage contract: Rust `cmx` owns durable
  state; Swift owns native/renderer-local state; import is one-way.
- Define desktop state directory selection for release, tagged debug, and remote
  backends, including short tag-scoped AF_UNIX socket paths.
- Freeze the two-socket IPC model: internal native socket for Swift desktop and
  external `CMUX_SOCKET_PATH` compatibility socket for the existing API/CLI.
- Decide the compatibility boundary for old session files and settings.
- Define the desktop one-space mapping: each imported/restored desktop workspace
  creates or selects a single default `cmx` space, and all desktop commands
  operate in that space unless a future desktop spaces UI is explicitly added.
- Define browser panel state ownership:
  - `cmx` persists browser panel identity, URL, title, history cursor, user
    title, pinned/unread/sidebar metadata, proxy context, and restoration
    policy.
  - The macOS app persists only local renderer storage keyed by `cmx` browser
    panel/profile IDs, such as WKWebsiteDataStore/cache/cookie containers.
  - `cmx` owns the proxy/network context for remote/Linux-hosted workspaces and
    tells the macOS WebView worker which proxy profile to use.
- Define Ghostty config propagation:
  - `cmx` reads the backend Ghostty config/theme/font/cursor defaults and sends
    a sanitized terminal appearance fragment in native snapshots.
  - Swift applies that fragment to cmx-backed GhosttyKit surfaces after local
    cmux keybind/shell overrides, so `CSI 0 q` resets land on the backend's
    configured cursor style and blink behavior.
  - Server-side libghostty-vt snapshots normalize default cursor resets against
    the same config so PTY replay tails do not override the visible cursor
    preference after reconnect.
- Freeze Swift concurrency requirements for the desktop bridge: actor-based
  transport, `@MainActor` projection store, `Sendable`/`nonisolated` wire DTOs,
  stored task lifecycle, explicit `@concurrent` use for intentional off-actor
  async work, unified logging, no app-logic `DispatchQueue` coordination, and no
  state mutation from SwiftUI body/projection code.

Exit criteria:

- A versioned protocol doc under `rust/cmux-cli` and a desktop migration doc in
  this repo.
- CI protocol round-trip tests for every new message shape on both native and
  compatibility sockets.

### Phase 1: Desktop cmx Transport

Implement a real macOS client library by lifting the proven iOS code into a
shared Swift package/module:

- MessagePack codec for `HelloNative`, `NativeSnapshot`, `PtyBytes`,
  `NativeInput`, `NativeLayout`, `Command`, `Ping/Pong`, and errors.
- AF_UNIX transport for local desktop using length-prefixed MessagePack.
- WebSocket and iroh transport reuse where useful, but local desktop starts
  with AF_UNIX for latency and simplicity.
- A `CmxDesktopSession` that can start or attach to a tag-scoped local `cmx`
  daemon.
- A `CmxConnection` actor that owns socket lifetime, inbound frame streaming,
  outbound sequencing, reconnect, ping/pong, and cancellation.
- An `@MainActor` `CmxDesktopStore` projection that applies Rust revisions and
  exposes immutable value snapshots to UI.
- No app-logic `DispatchQueue` bridge. Queue-based C/Apple callbacks, if
  unavoidable, stay inside low-level adapters and hop into actors or MainActor
  explicitly.
- Shared protocol/transport code should be reused with iOS where practical. This
  means shared Swift wire/session code, not shared UI. The desktop and iOS apps
  remain separate apps with different navigation and rendering shells.

Exit criteria:

- With the hard cutover flag enabled, the desktop app can create a visible
  `cmx`-backed terminal workspace, receive a native snapshot, send input, render
  PTY bytes through GhosttyKit, and reconnect after app relaunch.
- With the flag disabled, the old Swift backend still runs.

### Phase 2: Terminal Panel Replacement

Create `CmxTerminalPanel` as the first real desktop surface:

- Rust owns the PTY and scrollback.
- Swift owns GhosttyKit rendering and feeds exact `PtyBytes` into the surface.
- Use a cmx-specific Ghostty manual IO renderer/surface path rather than
  changing old `TerminalSurface` assumptions in-place. Existing WIP
  DispatchQueue-based manual IO sketches should be replaced with the actor/async
  bridge described above before this path becomes authoritative.
- Input, paste, key equivalents, focus intent, terminal size, and visible layout
  report back through `NativeInput` and `NativeLayout`.
- Terminal title, cwd, git branch, TTY, ports, process state, and unread markers
  come from `cmx` snapshots/events.
- Relaunch restore is part of this phase, not a later polish item. The terminal
  panel must reattach to restored `cmx` terminal state after app restart.

Exit criteria:

- Typing, paste, resize, clear, read-screen/capture-pane, and scrollback work
  through `cmx`.
- The user can quit and relaunch the tagged app and get the same `cmx` workspace,
  pane tree, selected terminal, terminal cwd/title metadata, and live/restored
  terminal state according to the `cmx` restore contract.
- CI covers protocol behavior; app build verification uses tagged reload only.

### Phase 3: Swift Model Becomes a Projection

Replace authoritative `TabManager`/`Workspace` mutations with a read-only
projection of `cmx` state:

- Introduce `CmxDesktopStore`, built from `NativeSnapshot`.
- Convert sidebar, workspace switcher, pane tree, tab strip, command palette,
  notifications, right sidebar, and restore UI to value snapshots plus command
  closures.
- Every UI action sends a `cmx Command` and reconciles from the next snapshot.
- Keep old Swift types temporarily as view adapters if that reduces churn, but
  strip their ability to own durable state.

Exit criteria:

- Workspace create/select/close/rename/reorder, pane split/focus/resize,
  surface create/move/reorder/close, and tab actions all round-trip through
  `cmx`.
- No dual-write paths for migrated behavior.

### Phase 4: CLI and Socket API Move to cmx

Move the command authority behind the existing `cmux` CLI contract to `cmx`:

- Implement `cmux` v2 socket methods in `cmx`, or add a compatibility adapter
  that is mechanically thin and stateless.
- Serve the final compatibility socket from Rust `cmx` state. A Swift-hosted
  proxy is allowed only while bridging the migration and must not become command
  authority.
- Preserve current CLI text/JSON output, refs, id formats, env defaults, and
  socket password behavior.
- Retarget tmux-compat, agent launchers, hooks, browser commands, notifications,
  and remote commands to the `cmx` command model.
- Keep the app socket only as a temporary discovery/proxy layer if needed.
- Commands that mention spaces internally must still present desktop-compatible
  workspace/pane/surface semantics externally.

Exit criteria:

- Existing socket/CLI/tmux-compat CI suites pass against the `cmx` backend.
- Non-focus socket command policy is enforced in the Rust command layer.

### Phase 5: Browser, Markdown, Feed, and Native Workers

Model non-terminal panels in `cmx` without moving platform-bound rendering into
Rust:

- `cmx` owns panel lifecycle, metadata, ordering, persistence, selection,
  unread state, and command routing for browser/markdown/feed/custom panels.
- `cmx` owns browser network/proxy context. For a Linux or remote `cmx` backend,
  it provides the proxy endpoint/profile that the macOS WKWebView worker uses
  so localhost/private-network browser traffic resolves from the backend's
  context, not the user's Mac by default.
- Browser creation paths inherit the workspace's current `workspace.remote.status`
  proxy endpoint into the browser snapshot. Swift publishes browser metadata
  back to Rust when the local remote proxy endpoint changes, so restored browser
  state does not retain a stale proxy after reconnect.
- The macOS app registers local worker capabilities for WKWebView automation,
  screenshots, DOM snapshots, downloads, cookies/storage, markdown rendering,
  and native dialogs.
- Browser automation commands become `cmx` commands that delegate execution to
  the active macOS renderer worker and return structured results.
- Browser durable state is split deliberately:
  - `cmx`: browser panel identity, restored URL, history model, title, sidebar
    metadata, proxy/network profile, worker lease, and command results.
  - macOS app: platform WebKit storage blobs keyed by `cmx` browser profile ID.
  - Future portability: add explicit cookie/storage export/import commands if
    browser state needs to move across devices/backends.

Exit criteria:

- Browser panes are restorable/detachable at the `cmx` model layer.
- Creating a browser tab/split in a remote workspace records the inherited
  browser proxy in `cmx` state, and subsequent remote proxy changes update the
  browser snapshot through the native bridge.
- Existing browser CLI/API parity tests pass with `cmx` command authority.

### Phase 6: Remote, VM, and iroh Unification

Unify remote session handling around `cmx` transports:

- Local desktop `cmx` is the coordinator for SSH, VM, WebSocket, and iroh
  sessions.
- Remote terminals appear as the same Rust-owned terminal/panel model, regardless
  of transport.
- Existing cloud VM and SSH control-plane APIs remain, but their terminal/session
  state is represented through `cmx`.
- Remove duplicate Swift remote terminal lifecycle state after parity.
- `vm.*` now routes through Rust's HTTP client instead of Swift `VMClient`.
  Rust asks Swift only for a private `__cmx.vm.auth_context` native sidecar
  response containing the app's VM API base URL plus current Stack/Auth header
  tokens. The public socket API remains `vm.list/create/destroy/exec/ssh_info/
  attach_info`, with payload keys preserved (`exit_code`, `private_key_pem`,
  `session_id`, `expires_at_unix`). The durable VM lifecycle source of truth
  remains the backend database; cmx now owns the desktop command execution path.

Exit criteria:

- Remote workspace reconnect/disconnect, port detection, browser proxy routing,
  and session end behavior are all represented in `cmx` snapshots/commands.

### Phase 7: Persistence and Migration

Move durable app state to `cmx`:

- Workspaces/spaces/panes/tabs/terminals.
- Layouts and split divider positions.
- Terminal session restore metadata.
- Sidebar metadata: titles, descriptions, pins, colors, unread, progress, logs,
  notifications.
- Browser panel metadata and persisted browser session references where safe.

Migration strategy:

- On first `cmx` backend launch, import the old Swift session snapshot into the
  Rust store.
- Each imported desktop workspace gets one default `cmx` space.
- Keep a read-only backup of the old session file.
- Write an import marker/fingerprint in the `cmx` state directory so import is
  idempotent and cannot silently re-run against a changed old store.
- Do not keep writing both stores after import.
- The hard cutover flag may be disabled during development, but shipping the
  feature requires import/restore parity with no fallback writes to the old
  store.

Exit criteria:

- Relaunch restores through `cmx`.
- Old Swift persistence can be deleted or kept only as an importer.

### Phase 8: Delete Legacy Backend

Remove the old authoritative backend after parity:

- Delete Swift-owned terminal PTY/session lifecycle.
- Delete app-side socket command implementations except tiny proxy/discovery
  code that still has a reason to live in AppKit.
- Delete old session persistence writers.
- Delete duplicated tab/workspace mutation code.
- Keep UI components only after they consume `CmxDesktopStore` snapshots and
  command closures.

Exit criteria:

- The desktop app cannot create or mutate a workspace/pane/surface without
  sending a `cmx` command.
- All shipped entrypoints use the same Rust command path.

## First PR Stack

1. Add this migration plan plus protocol, state ownership, IPC, and Swift
   concurrency inventory.
2. Extract shared Swift `cmx` protocol/session code from iOS into a package that
   builds for macOS and iOS, with `Sendable`/`nonisolated` DTOs and strict
   concurrency enabled for the new package.
3. Replace or back out premature existing-`TerminalSurface` manual IO edits and
   implement a cmx-specific Ghostty renderer path that is actor/async driven.
4. Add a hard-cutover desktop feature flag with an easy disable path.
5. Add Rust state-directory selection, import marker/fingerprint, and
   session-restore support for existing desktop session data.
6. Add Rust two-socket IPC: native desktop socket plus compatibility
   `CMUX_SOCKET_PATH` socket preserving the current API/CLI contract.
7. Add Rust protocol gaps found by desktop: window IDs, panel metadata, command
   replies, browser-worker capability placeholders, and replay requests.
8. Add Swift `CmxConnection` actor and `@MainActor` `CmxDesktopStore`
   projection.
9. Add the visible `CmxTerminalPanel` path behind the flag.
10. Convert one non-terminal-mutation UI path to send a `cmx Command` and render
    from snapshot.
11. Propagate Ghostty theme/font/cursor config through native snapshots and
    verify cursor shape/blink behavior through shell integration and replay.

## Risks

- ID compatibility is the main scripting risk. Preserve external UUID/ref
  behavior even if Rust uses compact IDs internally.
- State migration is high risk. Import must be idempotent and one-way, with no
  hidden dual-write or stale Swift restore path after the cutover flag is
  enabled.
- IPC split-brain is high risk. The native desktop socket and compatibility
  socket must resolve to the same Rust command/state layer, or CLI and UI will
  drift.
- Swift concurrency regressions are likely if the bridge uses ad hoc
  `DispatchQueue` hops. The new transport/store/renderer code should compile
  cleanly under strict concurrency and use actor/MainActor boundaries
  deliberately.
- Browser automation cannot be fully headless in `cmx` while it depends on
  WKWebView. Treat browser rendering/execution as a registered desktop worker,
  with Rust still owning the command and lifecycle state.
- Resize semantics must stay deterministic across desktop, iOS, TUI, and remote.
  The existing "smallest visible client wins" model should become the only rule.
- SwiftUI performance regressions are likely if snapshot boundaries are ignored.
  Lists must receive immutable row snapshots and closure action bundles only.
- Socket focus policy must move with the command authority. Non-focus commands
  must never activate windows or steal in-app focus.

## Verification Strategy

Follow the repo policy: do not run E2E/UI tests locally. Use CI for broad suites.

- Rust protocol/unit coverage in `rust/cmux-cli`.
- Protocol round-trip tests for the native desktop socket and the compatibility
  socket.
- Import/restore tests covering old Swift snapshot data into the Rust store and
  relaunch restore from that store.
- Swift unit coverage for codec, store projection, command dispatch, and snapshot
  reconciliation.
- Swift compile gate for the new package/transport/store with no
  strict-concurrency or actor-isolation warnings.
- Existing Python socket tests retargeted to a `cmx` backend fixture.
- Tagged macOS debug builds with `./scripts/reload.sh --tag desktop-cmx-backend`
  for compile verification.
- Dogfood gates: local terminal, multi-window, tmux-compat agent teams, browser
  automation, SSH/VM remote terminal, relaunch restore, and iOS simultaneous
  attach to the same `cmx` state.

## Current Branch Verification Notes

Tagged build/smoke evidence from `feat-desktop-cmx-backend`:

- `cargo check -p cmux-cli-server -p cmx` and
  `cargo build -p cmx -p cmux-cli-server` pass.
- The optimized Rust dogfood gate
  `cargo build --release -p cmx -p cmux-iroh-bridge` passes.
- `CMUX_DESKTOP_CMX_BACKEND=1 ./scripts/reload.sh --tag desktop-cmx-backend`
  builds the Debug desktop app successfully.
- Tagged `reload.sh --launch` now uses `open -n -g` for isolated debug apps.
  `CMUX_DESKTOP_CMX_BACKEND=1 ./scripts/reload.sh --tag desktop-cmx-backend
  --launch` succeeds end-to-end instead of failing Launch Services with `-600`.
- Tagged app bundles now persist the launch tag and CMX backend flag in
  `LSEnvironment`, and Swift also infers the runtime tag from
  `com.cmuxterm.app.debug.<tag>` if `CMUX_TAG` is missing. A normal `.app`
  launch of `cmux DEV desktop-cmx-backend.app` without shell CMX env restored
  the tag-scoped `/tmp/cmux-cmx-desktop-cmx-backend` state instead of falling
  back to the default `~/Library/Application Support/cmux/cmx` state.
- The tagged app launches with Rust as backend:
  `/tmp/cmux-cmx-desktop-cmx-backend/native.sock` and
  `/tmp/cmux-debug-desktop-cmx-backend.sock` are both present, and
  `cmux capabilities` reports `"backend": "cmx-rust"`.
- Swift now maintains one native CMX session per live `MainWindowContext`.
  Terminal surfaces, layouts, replay requests, and PTY byte delivery are keyed
  by `(window_id, terminal_id)`, while only the primary compatibility window
  advertises `socket_compatibility_bridge`. Workspace, tab, browser, split, and
  surface commands pass their owning AppKit window ID into Rust so duplicate
  visible terminal IDs in different windows do not collide.
- Rust ignores late native snapshots from closed windows by tombstoning closed
  native window IDs. A tagged close smoke opened a second window, verified its
  dedicated native session in the debug log, ran `close-window --window <uuid>`,
  and confirmed `list-windows` returned only the primary window after Swift
  unregistered the closed context.
- Desktop-launched `cmx` now receives the parent app PID through a hidden env
  var and exits if that parent disappears. A forced-termination smoke killed the
  tagged app process with `KILL` and verified the bundled `cmx` child also
  exited, then relaunched the `.app` and restored the same workspace/tree.
- Desktop session import is now idempotent on the actual CMX state store:
  Rust records a one-way import marker and refuses to overwrite an existing
  `<state-dir>/snapshot.json`, preventing old Swift restore data from
  overwriting Rust-owned state on later relaunches.
- Desktop session import startup now skips on Rust's
  `desktop-session-import.json` marker instead of skipping purely because
  `<state-dir>/snapshot.json` exists. This lets Rust write the
  `skipped_existing_cmx_snapshot` marker/fingerprint for production states that
  already have CMX data but no import marker, while still preserving Rust-owned
  `snapshot.json`.
- Workspace-scoped CLI smoke passes without stealing focus:
  `new-workspace --focus false`, `new-surface --workspace ... --focus false`,
  `new-pane --workspace ... --focus false`,
  `tab-action --workspace ... --action new-terminal-right --focus false`, and
  `close-surface --workspace ... --surface ...` mutate the target inactive
  workspace while `current-workspace` stays unchanged.
- Workspace-scoped focus-intent smoke passes: `focus-pane --workspace ...` and
  `focus-panel --workspace ... --panel <surface>` select the requested
  workspace/pane/surface, and explicit `select-workspace` returns to the
  original workspace.
- `tab-action pin` / `unpin` are Rust-local, return `tab_ref` and `pinned`, and
  pinned tab state is included in the native snapshot and survives relaunch.
- `move-tab-to-new-workspace` / `tab.action move_to_new_workspace` are
  Rust-local, preserve the moved surface ref, create a new cmx workspace, reject
  moving the only tab in a workspace, and keep the current workspace unchanged
  when `--focus false`.
- `move-surface --workspace ... --pane ... --focus false` is Rust-local for
  same-window workspace-scoped moves. It moves surfaces between panes in an
  inactive workspace without stealing focus and returns the legacy
  surface/workspace/window aliases used by CLI text output.
- `surface.move` now treats `workspace_id` / known `window_id` as destination
  scope while resolving the source surface globally when needed, and when a
  destination workspace is supplied it can materialize an unknown valid window
  UUID through Rust window state instead of delegating to Swift. Tagged smokes
  moved surface `c0de0002-c0de-4000-8000-001a00000001` from workspace
  `c0de0001-c0de-4000-8000-00000000001a` into
  `c0de0001-c0de-4000-8000-00000000001b`, then moved surface
  `c0de0002-c0de-4000-8000-008b00000001` into destination workspace
  `c0de0001-c0de-4000-8000-00000000008c` on materialized window
  `45C54AA9-04CE-486C-B2AA-25456660D939`; the destination trees contained the
  exact same surface IDs and source workspaces kept their remaining terminals
  selected.
- Rust now keeps native-window projections in its own window state map:
  `native_window_ids()` includes registered projection keys, `window.create` is
  Rust-local, allocates/registers the UUID with the active workspace, and
  advertises all CMX-owned window IDs through native snapshots. Swift reconciles
  that `native_window_ids` list by creating any missing AppKit windows without a
  blocking native-worker RPC. `window.close` is also Rust-local now: it removes
  the Rust window projection, wakes snapshots, and Swift reconciles the missing
  ID by closing the corresponding AppKit window. Legacy `new-window` /
  `list-windows` / `current-window` no longer use hardcoded placeholder IDs.
  `window.focus` resolves local aliases in Rust and delegates the actual AppKit
  focus operation to Swift. Tagged smokes verified v2
  `window.create`/`window.list`/`window.focus`/`window.close` and legacy
  `new-window`/`list-windows`/`close-window` round-trip with real UUIDs.
- `send --workspace ... --surface ...` and
  `send-key --workspace ... --surface ...` resolve their target in Rust, write
  to the requested PTY in an inactive workspace, and can be read back with
  `read-screen --workspace ... --surface ... --scrollback` without changing the
  current workspace.
- `browser open-split --workspace ... --focus false` is Rust-local for the
  same-window path. It creates the browser surface and split pane in the target
  inactive workspace, returns CLI-compatible surface/pane aliases, and preserves
  the current workspace. The Rust path now treats known native windows as local
  targets and returns the workspace's containing native window instead of the
  current-window fallback. A tagged smoke on moved workspace `...0050` verified
  `browser.open_split` returned destination window
  `271A6538-6E77-4D75-83A6-C6E70BC76452` and did not reattach the workspace to
  the source window.
- When the target workspace already has a right-side sibling pane,
  `browser open-split --workspace ... --surface ... --focus false` now matches
  Swift placement by reusing that pane as a browser tab stack. The smoke kept
  pane count stable at two, returned `created_split=false` with
  `placement_strategy=reuse_right_sibling`, and preserved current workspace.
- Rust `browser.open_split` now also honors
  `respect_external_open_rules` by reading the desktop defaults
  `browserExternalOpenPatterns` key and matching Swift's plain-substring plus
  `re:` regex pattern forms before returning the existing
  `placement_strategy=external` payload. The ordinary non-external path was
  smoke-tested after the change and still creates a right split with
  `opened_externally=false` without stealing focus.
- `browser.tab.new`, `browser.tab.switch`, and `browser.tab.close` are now
  Rust-local model mutations for existing browser surfaces instead of focusing
  a pane and then calling the generic first-window runner. They preserve the
  containing native window and return window/workspace/surface context in the
  v2 response. A tagged live socket smoke on moved workspace `...003b` created
  browser surfaces `...003b00000001` and `...003b00000002`, switched back to
  the first tab, closed the second, and verified the workspace stayed absent
  from source window `55CAA023-C3F6-40A3-B956-32AC96F2926F` and present in
  destination window `28A8098C-074D-4930-B068-EB12BCE534F2`.
- `browser.tab.list` now uses the same browser-surface/window resolution path
  as tab creation/switch/close. Listing by `surface_id` on a moved workspace
  builds the destination window's workspace snapshot, returns top-level
  `window_id/window_ref`, and keeps bare `id/ref` compatibility by falling back
  to workspace lookup only when the value is not a browser surface. A tagged
  smoke on workspace `...0042` in destination window
  `E02B2C53-5F84-45E8-B7DD-423046DAB866` listed browser surfaces
  `...004200000001` and `...004200000002` by `surface_id` and verified the
  source window did not regain the workspace.
- Unsupported browser network methods preserve the Swift WKWebView response
  shape: `browser.network.route` / `unroute` record attempted requests per
  browser surface, and `browser.network.requests` returns them in the
  `not_supported` error data.
- `tab-action --action close-right` is Rust-local for workspace-scoped tab
  stacks. It closes the expected tabs in an inactive workspace, reports the
  closed count, skips pinned tabs, and preserves the current workspace.
- `workspace.action`, `surface.action`, and `tab.action` are advertised as
  Rust-local rather than conditional-local. Workspace action smokes cover
  hyphenated `clear-name`
  normalization and named palette color resolution (`Blue` -> `#1565C0`) without
  changing the current workspace.
- `workspace.move_to_window` is conditional-local. Moving a workspace to the
  local synthetic cmx window (`window:0`), a known connected native window, or
  an unknown valid window UUID is served by Rust; local/native/materialized
  targets update Rust's durable per-window workspace membership and
  selected-workspace projection even when `focus=false`, and `--focus true`
  additionally updates the global active workspace. A tagged CLI smoke moved
  workspace `...0023` to window `E3523B99...` without `--focus`, verified
  `list-windows` updated only that target window, confirmed
  `current-workspace` remained `...0024`, then moved `...0022` back into the
  same window. Later v2 and legacy smokes materialized unknown target windows
  directly from Rust-owned state.
- Rust now persists/restores native-window workspace membership, not just each
  window's selected workspace. Native snapshots, TUI sidebar rendering,
  `window.list`, `list-windows`, and v2 `workspace.list/window_id` all use the
  window-scoped workspace projection. Fresh tagged smokes created workspaces
  `...002d` and `...002e`, moved `...002d` from window
  `55CAA023-C3F6-40A3-B956-32AC96F2926F` to
  `E3523B99-D41E-40EC-BDF8-57AFECAB2D6F`, and verified window 0 no longer
  reported `...002d` while window 1 reported it. After a tagged reload,
  `window.list` restored the same membership split (`45` workspaces in window
  0 and `2` in window 1), proving the sidecar/snapshot path survives relaunch.
- Window-scoped `workspace.next` and `workspace.previous` now use the same
  Rust membership model. A tagged smoke on window
  `E3523B99-D41E-40EC-BDF8-57AFECAB2D6F` cycled only
  `["...0022", "...002d"]`, moving active index `1 -> 0 -> 1` without pulling
  in the global workspace list.
- `workspace.select` now infers the containing native window when the caller
  selects by explicit workspace ID/title without a `window_id`, instead of
  defaulting to the first native window. Index-style selection keeps the old
  current-window behavior, and the Python v2 test helper now passes explicit
  `window_id` when a test intends to mutate a specific AppKit window. A tagged
  smoke moved workspace `...0034` from window
  `55CAA023-C3F6-40A3-B956-32AC96F2926F` to
  `E3523B99-D41E-40EC-BDF8-57AFECAB2D6F`, then selected it by workspace ID
  only and verified it stayed absent from the source window while remaining
  selected in the destination window. The legacy v1 `select_workspace <id>`
  command now routes through the same Rust selector; a raw socket smoke on
  workspace `...0037` returned `OK` and preserved destination-only membership.
- The same containing-window rule now covers indirect focus paths. Rust runs
  `surface.focus`, `pane.focus`, `pane.resize`, and
  `debug.notification.focus` through a
  window-scoped command runner instead of reconstructing the first window from
  global state. `surface.split`/`pane.create` also return the created
  `surface_id` while preserving the richer snapshot payload, so v2 clients and
  legacy helper wrappers agree on the new surface identity. A tagged live socket
  smoke created workspace `...003a`, added a right split returning surface
  `...003a00000001`, moved the workspace from
  `55CAA023-C3F6-40A3-B956-32AC96F2926F` to
  `B9D6C7C2-3F3A-4F61-BB90-1726CBC6D767`, and verified
  `workspace.select`, legacy `select_workspace`, `surface.focus`, `pane.focus`,
  and `debug.notification.focus` all kept it absent from the source window and
  present in the destination window.
- A follow-up tagged smoke on workspace `...003e` split a scoped workspace,
  moved it to window `B536B870-488E-45D4-B2A0-EA787B298E80`, then resized pane
  `0` with `pane.resize` and verified the response reported the destination
  window and did not reattach the workspace to source window
  `55CAA023-C3F6-40A3-B956-32AC96F2926F`.
- `pane.join`, `pane.swap`, and `pane.break` now use direct Rust workspace
  model operations instead of `run_command`/`WindowState::new`. A tagged smoke
  on moved workspace `...003f` in destination window
  `FA2F946C-6843-46E6-BDEE-EDED41C78135` swapped panes `0`/`1`, joined a
  surface back into pane `0`, then broke that surface into new workspace
  `...0040`; both original and created workspaces stayed absent from source
  window `55CAA023-C3F6-40A3-B956-32AC96F2926F`, and the created workspace was
  present in the destination window.
- `surface.move` now infers the destination workspace's native window when no
  `window_id` is supplied. A tagged smoke on moved workspace `...0041` moved
  surface `...004100000001` to pane `0` and verified the response reported
  destination window `D4109C16-1674-4FCA-962C-002C3E7E2209` while the source
  window did not regain the workspace.
- `split-off --workspace ... --surface ... --focus false` is Rust-local. It
  moves a tab-stack surface into a new split pane in the inactive target
  workspace and preserves the current workspace. `surface.split_off` now also
  updates/reports the workspace's containing native window for moved
  workspaces.
- `surface.drag_to_split` is Rust-local for workspace-scoped same-window
  requests. It resolves source and target surfaces in the requested workspace,
  creates the split in Rust, preserves current workspace when `focus` is
  false, and updates/reports the containing native window for moved
  workspaces. A tagged smoke on workspace `...0045` in destination window
  `58BBA81F-6D5E-431C-ABDD-139C156DBD25` verified `surface.split_off` and
  `surface.drag_to_split` stayed in the destination window and did not reattach
  the workspace to the source window.
- A follow-up moved-workspace smoke on workspace `...0046` in destination
  window `EA8C4086-EFBD-462D-8045-1858A963ABA3` expanded the same coverage to
  `surface.health`, `surface.refresh`, `surface.clear_history`, and
  `surface.trigger_flash`; each response reported the destination window and
  kept the source window free of the moved workspace.
- Window inference for moved workspaces now uses the same normalized
  window-scoped workspace projection as `window.list` instead of raw cached
  window state. This fixed a stale-primary-window route exposed by the expanded
  surface smoke; the rerun passed on workspace `...0049` in destination window
  `F6CBE7AC-5351-48AF-B59C-CC4683BC589D` and also covered
  `surface.send_text`, `surface.reorder`, and `surface.close`.
- Rust-local `tab.action` responses now include the inferred native window and
  `move_to_new_workspace` adds the created workspace to the source workspace's
  containing native window. The moved-workspace smoke passed with rename,
  `new_terminal_right`, and `move_to_new_workspace` coverage on workspace
  `...004e` in destination window `EE550022-55B0-488C-B520-B58DCCE9D9BD`.
- `reorder-surface --workspace ... --surface ... --index 0 --focus false` is
  Rust-local for inactive workspace tab stacks. It keeps the surface count
  stable, moves the requested surface to the target index, returns legacy
  surface/pane/workspace aliases, and preserves the current workspace.
- Swift-side state ownership audit now covers the old persistence entrypoints
  and the main desktop UI mutation paths touched by workspaces/tabs/focus:
  `saveSessionSnapshot` and autosave return early under the cmx flag;
  workspace reorder/top/notification-top sends a native cmx
  `move-workspace-to-index` command instead of mutating `TabManager.tabs`;
  clearing a workspace title under the cmx flag sends Rust's default title
  (`main` / `ws-<id>`) instead of locally clearing Swift state; and Bonsplit
  tab selection / pane focus send native `select-tab-in-panel` / `focus-panel`
  commands while snapshot application is guarded to avoid command echoes.
- Latest tagged smoke after that audit created a new cmx workspace, added a
  right split plus an additional tab in the original pane, and verified the tree
  had two panes and three terminal surfaces. `reorder-workspace --index 1`
  moved that workspace without changing `current-workspace`, and
  `workspace-action clear-name` normalized the title to `ws-15`.
- Latest post-multi-window-fix smoke created workspace
  `c0de0001-c0de-4000-8000-000000000024`, added a right split and another
  terminal surface, and verified the Rust tree has one desktop space, two panes,
  and three terminal surfaces (`pane 0` with two surfaces, `pane 1` with one).
- `workspace.create` now handles the existing `cmux` layout schema directly in
  Rust. It validates pane/split nodes before creation, applies split ratios,
  creates terminal/browser surfaces, honors per-surface cwd/env/title/command
  fields, and lands focus on the requested surface. The raw v2
  `initial_command`/`initial_env` path is also Rust-owned for SSH/VM workspace
  creation flows. Tagged smokes after reload verified
  `cmux new-workspace --layout` on workspace `...002a` created one default
  desktop space, two panes, and three terminal surfaces with focus on
  `right-tab`; `RIGHT_TAB_OK` appeared in PTY scrollback; a layout env var
  expanded as `LAYOUT_ENV_left`; and raw `workspace.create` on workspace
  `...0028` expanded `initial_env` as `RAW_INIT_OK`.
- A layout-created browser smoke on workspace `...002c` verified Rust creates a
  browser surface from the same schema, preserves its `data:` URL in
  `surface.list`, materializes `should_render_webview=true`, and reports the
  focused browser tab in `tree`.
- Direct incremental split/tab creation now updates Rust's native-window focus
  projection when `focus=true`. A tagged smoke on workspace `...0029` ran
  `new-split right --focus true` and `new-surface --pane 1 --focus true`,
  then verified `pane 1` was focused and its second surface was selected in
  both `list-panes` and `tree`.
- The latest current-build split/tab smoke created workspace `...002f` through
  raw `workspace.create` with an `initial_command`, added a right split, then
  added another terminal surface to pane `1`. `tree` reported exactly two panes
  and three terminal surfaces, with pane `1` focused and surface
  `...002f00000002` selected; `read-screen` on the seed terminal showed the
  wrapped `CURRENT_SPLIT_TAB_OK` output from Rust's initial-command path.
- Direct Bonsplit same-pane drag/drop now routes through
  `BonsplitController.moveTab(...)` so the app receives a move callback instead
  of silently mutating `PaneState`. Workspace translates that callback into a
  cmx `move-tab-to-panel` command. Drag-to-split of an existing tab now sends
  cmx `move-tab-to-split` using the original pane as the target panel and the
  post-split geometry to infer left/right/top/bottom.
- `workspace.remote.*` is now routed through Rust first instead of being
  advertised as a native-worker method. Rust stores the durable
  `workspace.remote.status` payload on the workspace snapshot as
  `remote_status_json`; native Swift still performs the SSH/proxy side effects
  and publishes status updates back to cmx via `set-workspace-remote-status`.
  A tagged socket smoke created an inactive workspace, added a right split and
  another tab in the original pane, verified a two-pane/three-terminal tree, and
  confirmed `workspace.remote.configure`/`workspace.remote.status`/
  `workspace.remote.disconnect` round-tripped through the Rust cache while
  preserving the active workspace.
- `workspace.remote.configure` with `auto_connect=false` is now a pure
  Rust-owned model mutation. It validates destination/port/proxy/relay fields,
  stores the disconnected remote status without calling the Swift native
  worker, returns `configuredBy: "cmx-rust"`, and persists through tagged app
  reload. A smoke on workspace
  `c0de0001-c0de-4000-8000-000000000025` verified destination
  `example.invalid`, port `2222`, `local_proxy_port` `43210`, identity/SSH
  option flags, and `invalid_params` for port `70000`. The same smoke verified
  `workspace.remote.disconnect` stays Rust-local for this idle Rust-owned
  status, preserves the configuration when `clear=false`, and clears it when
  `clear=true`.
- `workspace.remote.configure` with `auto_connect=true` is now also Rust-local
  for the side-effect-free model paths that Swift already treated as connected
  without starting a live SSH/proxy worker: `transport=websocket` without a
  daemon WebSocket endpoint, and `skip_daemon_bootstrap=true` without a daemon
  WebSocket endpoint. Rust marks these as `connection_owner="cmx-rust-model"`,
  reports `connected_by="cmx-rust"`, keeps proxy unavailable, synthesizes the
  baked VM daemon readiness for the VM no-proxy path, and keeps
  `workspace.remote.status`/`disconnect`/`reconnect` Rust-local. A tagged
  socket smoke covered both model-connected paths plus reconnect and clear
  cleanup. A reload smoke then restored workspace
  `c0de0001-c0de-4000-8000-00000000009d` with destination
  `restore-vm-rust-model.example.com`, connected state, baked daemon metadata,
  and proxy-unavailable status intact from the CMX snapshot.
- `workspace.remote.configure` with a daemon WebSocket endpoint is now
  Rust-owned for the live proxy path. Rust authenticates to the daemon
  WebSocket, calls `hello`, requires `proxy.stream.push`, starts a loopback
  SOCKS5/HTTP CONNECT listener, and forwards streams with
  `proxy.open`/`proxy.stream.subscribe`/`proxy.write`/pushed
  `proxy.stream.*` events. The endpoint token/session headers stay in memory
  only and are not written to `remote_config_json`; `disconnect`, `clear`,
  reconnect within the same process, terminal-session demotion, and workspace
  close all stop the Rust proxy handle. It also mirrors Swift's loopback browser
  rewrite for the remote alias: egress HTTP headers rewrite
  `cmux-loopback.localtest.me` to `localhost`, response headers rewrite
  `localhost` back to the alias, and daemon `proxy.open` still dials
  `127.0.0.1`. The tagged socket smoke now includes a stdlib fake daemon
  WebSocket and verifies WebSocket auth, `hello` metadata in
  `workspace.remote.status`, a ready local proxy, SOCKS5 forwarding through the
  pushed stream path, loopback alias normalization and header rewriting,
  Rust-local disconnect, in-process reconnect, and post-connect daemon
  WebSocket failure propagation to `state="error"` with
  `proxy.error_code="proxy_unavailable"`.
- Rust-owned `workspace.remote.configure/status/disconnect` responses now use
  the workspace's containing native window instead of the current first-window
  fallback. A tagged smoke moved workspace `...0043` to window
  `ABE0A375-812C-445A-9162-E4A029B15558`, configured it with
  `auto_connect=false`, queried status, disconnected it, and verified all three
  responses reported the destination window while the source window did not
  regain the workspace.
- Rust-owned offline remote state now also mirrors Swift's initial remote
  terminal-session seeding for `terminal_startup_command`: if the workspace has
  exactly one terminal surface, CMX stores `active_terminal_sessions = 1`, the
  tracked surface ID, and the relay port. `workspace.remote.terminal_session_end`
  is Rust-local for disabled/Rust-owned idle remotes, clears the tracked surface
  on relay-port match, and demotes a no-browser workspace back to local state
  when the last Rust-owned remote terminal ends. Live SSH/proxy cleanup remains
  delegated to Swift until CMX owns those side effects. Fresh-tag smokes verified
  this path plus multi-window workspace creation, split creation, tab creation,
  split-off, and drag-to-split window scoping.
- Rust now also persists non-secret remote reconnect config in
  `remote_config_json`, separate from the public remote status payload. The
  tagged smoke verified simple SSH config is saved in `snapshot.json`, relay
  token-bearing config deliberately leaves `remote_config_json` null,
  endpoint-bearing WebSocket config stays non-persisted, side-effect-free
  WebSocket/VM model config reconnects locally in Rust, and real live
  connection config can still be replayed through the native side-effect worker
  before cleanup with `disconnect clear=true`.
- Rust now also keeps secret-bearing remote config in an in-memory-only
  `remote_ephemeral_configs` map for same-process reconnect and foreground-auth
  handoff, without writing relay/auth/WebSocket secrets to snapshots. The
  tagged smoke covers `workspace.remote.foreground_auth_ready`: a wrong token
  is a Rust-local no-op, and the matching token reconnects a Rust-owned
  disconnected WebSocket model config through the Rust command path.
- A fresh tagged secret-policy smoke configured an SSH remote with
  `relay_port`, `relay_id`, and a 64-byte `relay_token` using
  `auto_connect=false`. Rust returned `configuredBy="cmx-rust"`, the workspace
  snapshot kept `remote_config_json = null`, and
  `/tmp/cmux-cmx-desktop-cmx-backend/cmx-state/snapshot.json` contained neither
  the relay token value nor the `relay_token` key.
- ControlMaster cleanup is scoped to the reverse-relay path. Rust bootstrap,
  daemon-proxy, scp upload, and drop-upload subprocesses force
  `ControlMaster=no`, so they do not create persistent masters. The relay path
  is the only path that intentionally reuses a configured `ControlPath`; its
  handle cleanup cancels the reverse `-R` forwarding command before removing
  remote relay metadata.
- The desktop app now passes bundled remote-daemon release metadata to the
  child `cmx` process at launch (`CMUX_REMOTE_DAEMON_MANIFEST_JSON`,
  `CMUX_REMOTE_DAEMON_APP_VERSION`, build, and commit). Rust parses and owns
  that metadata for the running daemon, computes the same remote-daemon cache
  path used by Swift, checks cache SHA-256 when present, and exposes the result
  through the new Rust protocol/CLI command `cmx remote-daemon-status`. Tagged
  app smoke verified the command over the native socket; the current Debug app
  has version/build/commit/fallback metadata but no embedded release manifest,
  which is expected for this build.
- Rust also now derives the SSH bootstrap binary plan from that same metadata:
  release manifests map to the verified cache path, explicit dev binaries are
  honored when local-build fallback is enabled, and Debug/local fallback derives
  a source-fingerprinted daemon version plus the planned local Go-build output
  and remote install path. The hidden `cmx remote-daemon-bootstrap-plan` smoke
  over the tagged compatibility socket returned
  `0.63.2-dev-2c3db357183c` for `linux/arm64` with remote path
  `.cmux/bin/cmuxd-remote/0.63.2-dev-2c3db357183c/linux-arm64/cmuxd-remote`.
  The heavier Rust helper for resolving the actual local binary can download
  a manifest asset, verify SHA-256 with the same live-manifest fallback Swift
  used, or run the dev-only Go build.
- Rust now has a hidden SSH bootstrap executor behind
  `cmx remote-daemon-ssh-bootstrap`. It mirrors Swift's SSH/scp argument
  defaults, probes the remote OS/arch and existing daemon version, uploads the
  metadata-selected binary when missing/stale, finalizes the install path with
  chmod/mv, runs `serve --stdio` hello, and reinstalls if the existing daemon
  does not report `proxy.stream.push`.
- Normal SSH `workspace.remote.configure` now enters a Rust-owned bootstrap
  state instead of immediately delegating to Swift. Rust returns
  `connection_owner="cmx-rust-ssh-bootstrap"` to the socket caller, stores the
  durable/ephemeral reconnect config, performs probe/upload/hello in a
  background task, then starts the Rust SSH proxy when the proxy/stack path is
  enabled. If Rust proxying is explicitly disabled, it passes
  `cmx_prebootstrapped_daemon` to the native sidecar so the still-Swift
  relay/proxy controller can skip its first daemon bootstrap and use the
  Rust-resolved remote path. Set
  `CMUX_REMOTE_SSH_BOOTSTRAP_IN_RUST_DISABLED=1` to fall back to the previous
  Swift-owned bootstrap while this path is being dogfooded.
- The Rust daemon proxy now also has an SSH stdio transport in addition to the
  daemon WebSocket transport. With `CMUX_REMOTE_SSH_PROXY_IN_RUST=1`, the
  post-bootstrap path starts `/usr/bin/ssh -T ... <remote-path> serve --stdio`,
  performs `hello`, binds the same loopback SOCKS5/HTTP CONNECT listener, and
  drives `proxy.open`/`proxy.stream.subscribe`/`proxy.write` over newline JSON
  on SSH stdio.
- Rust-owned remote SSH bootstrap/proxy failures now schedule daemon-local
  reconnect attempts from the same stored or secret-bearing ephemeral remote
  config. The published daemon/proxy error detail includes the retry number and
  delay, matching the Swift-side user-visible contract, and pending retries are
  cancelled on explicit reconnect, disconnect, terminal-session cleanup, or
  workspace removal. Remote fixture proof is still required before deleting the
  Swift sidecar fallback.
- `CMUX_REMOTE_SSH_STACK_IN_RUST=1` (alias:
  `CMUX_REMOTE_SSH_FULL_IN_RUST=1`) now enables the Rust SSH proxy, reverse
  CLI relay, TTY-scoped port scan, and workspace/ad-hoc detected-SSH drop
  upload together. The desktop hard cutover flag `CMUX_DESKTOP_CMX_BACKEND=1`
  now implies this Rust SSH stack for the child `cmx` daemon unless
  `CMUX_REMOTE_SSH_STACK_IN_RUST_DISABLED=1` is set. The per-feature
  `CMUX_REMOTE_SSH_*_IN_RUST_DISABLED=1` flags still override it so individual
  pieces can be backed out while dogfooding the combined stack.
- The Rust SSH proxy path now has a reverse CLI relay behind
  `CMUX_REMOTE_SSH_RELAY_IN_RUST=1`, the combined stack flag, or the desktop
  cutover flag. It binds a local authenticated loopback
  relay, starts the SSH `-R` forward, installs the same remote wrapper,
  socket_addr, daemon_path, and auth metadata as Swift, forwards authenticated
  CLI requests to the local cmux Unix socket, keeps reconnect state in Rust
  memory, and cleans up relay metadata on stop.
- The Rust reverse CLI relay now mirrors Swift's ControlPath reuse path: when
  SSH options include a non-`none` `ControlPath`, Rust first tries
  `ssh -O forward -R ...` against the existing control master and records the
  forward spec; relay stop/drop cancels it with `ssh -O cancel -R ...` before
  cleaning remote metadata. If the control-master forward is unavailable, Rust
  falls back to the existing long-running `ssh -R` child process path.
- The Rust SSH proxy/relay path now also has a TTY-scoped port scanner behind
  `CMUX_REMOTE_SSH_PORT_SCAN_IN_RUST=1`, the combined stack flag, or the
  desktop cutover flag. Relay-backed shell integration
  can report a remote TTY, `ports_kick` schedules the scan, Rust runs the same
  `ss`/`lsof` TTY-filtered script over SSH, writes per-surface listening ports,
  and republishes aggregate `remote.detected_ports`. Rust also accepts
  workspace-scoped v2 `surface.report_ports` telemetry and mirrors those ports
  into both the surface row and aggregate remote status. When no TTY has been
  reported yet, the same flag starts a Rust host-wide fallback poller that
  publishes aggregate detected ports until the TTY-scoped path takes over.
- Workspace remote file drop upload is now Rust-owned behind
  `CMUX_REMOTE_SSH_DROP_UPLOAD_IN_RUST=1` and the combined
  `CMUX_REMOTE_SSH_STACK_IN_RUST=1` flag; desktop cmx cutover enables it by
  default unless the stack/drop-upload disable flags are set. Swift still owns
  AppKit paste/drop planning, the progress indicator, and final Ghostty text
  insertion, but it now calls cmx v2 methods for the SSH subprocess work:
  `workspace.remote.upload_dropped_files`,
  `workspace.remote.cancel_drop_upload`, and
  `workspace.remote.cleanup_dropped_files`. Rust validates local regular files,
  generates `/tmp/cmux-drop-...` remote paths, runs `scp`, cleans partially
  uploaded files on failure, and keeps operation IDs cancellable through the
  compatibility socket. A tagged smoke against an intentionally closed SSH port
  reached the Rust `scp` path and returned the expected connection error; a
  successful remote-fixture upload still needs CI/VM coverage.
- Ad-hoc detected-SSH terminal file drop upload is now Rust-owned behind the
  same drop-upload/stack flags. Swift still detects the foreground SSH command
  for a local terminal and preserves its parsed destination, port, identity,
  config file, jump host, control path, address-family, agent forwarding,
  compression, and `ssh_options`, but the SSH subprocess work now goes through
  cmx v2 methods:
  `terminal.detected_ssh.upload_dropped_files`,
  `terminal.detected_ssh.cancel_drop_upload`, and
  `terminal.detected_ssh.cleanup_dropped_files`. A tagged smoke verified
  `system.capabilities` advertises those methods and an intentionally closed
  `127.0.0.1:1` upload reached the Rust `scp` path with the expected
  connection error; a successful real SSH fixture upload still needs CI/VM
  coverage.
- Restored terminal tabs are now lazy at the PTY boundary. Rust imports/restores
  the full workspace/pane/tab model, cwd/title/replay metadata, and libghostty
  render state immediately, but it does not allocate a macOS PTY or spawn the
  shell until a TUI/native client reports the terminal as visible. A tagged
  restore run that previously created 374 child shells and hit `openpty`
  exhaustion now starts with 5 child shells after reload while preserving the
  restored model.
- Post-lazy-restore tagged smokes passed across the Rust native and
  compatibility sockets: `remote-daemon-status --json` on the native socket,
  hidden `remote-daemon-bootstrap-plan --json --os linux --arch arm64`,
  `tests_v2/test_remote_rust_state.py` on the compatibility socket, and a
  focused workspace/split/tab compatibility exercise that created a new
  workspace, added one same-pane terminal tab and one right split, and observed
  exactly three terminal surfaces across two panes in that workspace.
- Relaunch restore through `cmx` has been smoke-verified for terminal scrollback
  and pinned tab state. The old Swift autosave path logs
  `session.save.skipped reason=desktopCmxBackendEnabled`.
- A full tagged reload/relaunch restore smoke preserved a cmx workspace by its
  external ID with a tab stack plus right split: two panes before/after, three
  surfaces before/after, the workspace title restored, and a PTY marker written
  through `surface.send_text`/`surface.send_key` remained visible through
  `read-screen --scrollback`.
- A fresh post-window-fix restart smoke created workspace
  `c0de0001-c0de-4000-8000-00000000001c`, split it twice, added a terminal tab
  to the focused pane, restarted the tagged app, and verified Rust restored one
  desktop space, four terminal surfaces, three panes with surface counts
  `[1, 1, 2]`, and Ghostty cursor style `bar`.
- A fresh import-once and tagged-app-launch smoke created workspace
  `c0de0001-c0de-4000-8000-00000000001f` titled
  `cmx-post-launch-005624`, added a right split plus another terminal tab in
  the focused pane, quit the tagged app, relaunched the `.app` path without
  shell CMX env, and verified `current-workspace` restored that workspace with
  exactly one default desktop space, two panes, three terminal surfaces, and the
  same split tree persisted in
  `/tmp/cmux-cmx-desktop-cmx-backend/cmx-state/snapshot.json`.
- `debug.layout` reports the Ghostty-derived terminal cursor config in the
  native snapshot, for example `"terminalCursor": { "style": "bar" }`.
- A fresh CMX-backed typing smoke created a new workspace, sent
  `echo CMX_CURSOR_TYPED` through `surface.send_text`, verified the marker was
  visible through `surface.read_text`, and confirmed `debug.layout` preserved
  `"terminalCursor": { "style": "bar" }` before and after typing.
- An isolated `cmx` daemon launched with a temporary Ghostty config containing
  `cursor-style = underline` and `cursor-style-blink = false` reported
  `"terminalCursor": { "style": "underline", "blink": false }` through
  `debug.layout`, proving the Rust socket path preserves both cursor shape and
  blink behavior when the backend config specifies them.
- Visual cursor smoke on a CMX-backed tagged app captured native
  `debug.panel_snapshot` PNGs and pixel-diffed the blinking caret. The default
  config produced a bar-shaped delta (`1x28` bbox), while a bundle-local
  Ghostty config with `cursor-style = underline` produced an underline-shaped
  delta (`14x1` bbox) and `debug.layout` reported
  `"terminalCursor": { "style": "underline", "blink": true }`.
- Ghostty shell-integration cursor behavior now respects the backend cursor
  config instead of forcing a bar prompt. Rust only enables Ghostty's
  `cursor:blink` / `cursor:steady` shell feature when the configured cursor
  style is `bar`; otherwise cmux's own bash/zsh hooks emit `CSI 0 q` on
  prompt/preexec so the terminal resets to the configured default shape/blink.
  An isolated underline/steady smoke verified
  `terminalCursor={"style":"underline","blink":false}` and a spawned shell env
  of `GHOSTTY_SHELL_FEATURES=path,title` plus
  `CMUX_GHOSTTY_CURSOR_RESET=1`, with no Ghostty prompt bar override.
- A fresh tagged restore smoke after adding Rust native window projection state
  created workspace `c0de0001-c0de-4000-8000-000000000014`, added one tab and a
  right split, relaunched, and verified one default space, three terminal
  surfaces, two panes with surface counts `[2, 1]`, real AppKit window UUIDs in
  `window.list`/`surface.list`/`pane.list`/`debug.layout`, and Ghostty cursor
  style `bar`. Sending `echo CMX_RESTORE_OK` and `echo CMX_VISIBLE_OK` through
  the restored PTY was visible through `read-screen --scrollback`.
- Browser model restore smoke created a cmx browser split with URL
  `http://127.0.0.1:9777/cmx-browser-restore`, relaunched, and verified
  `surface.list` restored the browser surface with the same URL and
  `should_render_webview=true`. The Rust snapshot persisted the browser tab as
  `kind=browser` with `browser.url_string` set to that URL.
- Browser proxy inheritance is now model-owned in Rust: browser tab/split
  creation reads the workspace's durable `remote_status_json` and stores a
  `BrowserProxySnapshot` when a valid proxy host/port is present. The Swift
  remote proxy endpoint update path also republishes browser metadata to cmx,
  so reconnects can replace stale browser proxy state in the Rust snapshot.
- `workspace.create focus=true` now updates the native window projection before
  Swift's next native snapshot can reconcile focus back to the old AppKit
  workspace. A clean-env tagged smoke created workspace
  `c0de0001-c0de-4000-8000-000000000021`, verified `current-workspace` and
  `system.identify.focused.workspace_id` both reported that workspace, then ran
  `browser open-split` without an explicit workspace and confirmed the browser
  landed in the same workspace instead of the previously focused one.
- A fresh tagged cutover smoke after Rust reconnect work verified
  `terminalCursor.style="bar"`, created workspace
  `c0de0001-c0de-4000-8000-0000000000db`, split right to surface
  `c0de0002-c0de-4000-8000-00db00000001`, created a second terminal tab in the
  first pane through `surface.create`, and observed two panes with three total
  terminal surfaces. The same pass fixed and verified the preserved
  `surface_id`/`surface_ref` aliases on `surface.create` responses.
- After the Swift-guidance completion-handoff cleanup, tagged reload
  `desktop-cmx-backend` succeeded and a focused socket smoke repeated the same
  workspace/split/tab path: Rust backend, workspace
  `c0de0001-c0de-4000-8000-0000000000db`, split surface
  `c0de0002-c0de-4000-8000-00db00000001`, new tab surface
  `c0de0002-c0de-4000-8000-00db00000002`, `surface.create` aliases
  `surface_id`/`surface_ref`/`tab_id`/`tab_ref`, two panes with surface counts
  `[1, 2]`, three total terminal surfaces, and
  `"terminalCursor": { "style": "bar" }`.
- After replacing remote-session state publication `DispatchQueue.main.async`
  calls with explicit MainActor handoffs, tagged reload `desktop-cmx-backend`
  succeeded again. A fresh socket smoke created workspace
  `c0de0001-c0de-4000-8000-0000000000de`, split right to
  `c0de0002-c0de-4000-8000-00de00000001`, created tab surface
  `c0de0002-c0de-4000-8000-00de00000002`, observed two panes with surface
  counts `[1, 2]`, three terminal surfaces, Rust backend, ten explicit
  unsupported browser methods, and `"terminalCursor": { "style": "bar" }`.
- Added CMX-backed real-drag UI coverage artifacts:
  `BonsplitTabDragUITests.testCmxBackendMinimalModeKeepsTabReorderWorking`
  launches with `CMUX_DESKTOP_CMX_BACKEND=1`,
  `CMUX_REMOTE_SSH_STACK_IN_RUST=1`, and an isolated `CMUX_TAG`; the app-side
  setup waits for the native CMX connection/snapshot before creating the second
  terminal tab, records `desktopCmxBackendEnabled=1`, and the XCUITest performs
  the same Beta-before-Alpha drag gesture while asserting the Bonsplit recorder
  reports the reordered tab stack.
  `testCmxBackendMinimalModeDragToSplitCreatesPane` uses the same CMX-backed
  setup and drags the Beta tab to the pane's right edge, then asserts the
  app-side recorder sees a higher pane count and Alpha/Beta in different panes.
  Per repo policy these UI tests were compiled by tagged reloads but still need
  CI/VM execution.
- The post-UI-test tagged reload succeeded. A focused socket smoke then created
  workspace `c0de0001-c0de-4000-8000-0000000000df`, created one same-pane
  terminal surface and one right split, verified `current-workspace` stayed on
  that workspace, observed two panes with surface counts `[2, 1]`, confirmed the
  native bridge was connected with ten explicit unsupported browser methods,
  and saw `"terminalCursor": { "style": "bar" }` in `debug.layout`.
- Another Swift-guidance cleanup pass made the desktop CMX startup task's
  MainActor isolation explicit, converted the asynchronous quit-confirmation UI
  handoff to `Task { @MainActor ... }`, and replaced two close-confirmation
  follow-up `DispatchQueue.main.async` calls with MainActor tasks. The tagged
  reload succeeded afterward, `git diff --check` passed, and the live socket
  still reported a connected native bridge, ten explicit unsupported browser
  methods, and `"terminalCursor": { "style": "bar" }`.
- The VM-oriented `scripts/run-tests-v2.sh` runner now has an explicit CMX
  backend mode: set `CMUX_TESTS_V2_DESKTOP_CMX_BACKEND=1` to launch the
  `tests-v2` tagged app with `CMUX_DESKTOP_CMX_BACKEND=1` and
  `CMUX_REMOTE_SSH_STACK_IN_RUST=1`. By default it also clears
  `/tmp/cmux-cmx-tests-v2` between launches for isolated Rust state
  (`CMUX_TESTS_V2_RESET_CMX_STATE=0` preserves it for restore-focused
  debugging), and `CMUX_TESTS_V2_FILTER` can run targeted subsets before the
  full suite. `CMUX_TESTS_V2_DIAGNOSTICS_DIR` now snapshots tagged debug logs,
  last-socket markers, and `/tmp/cmux-cmx-tests-v2` before cleanup so failed VM
  runs retain Rust state evidence. `CMUX_TESTS_V2_FAIL_ON_SKIP=1` turns any
  successful test that reports `SKIP:` into a failure, which the remote fixture
  workflow uses to avoid false proof from missing Docker/Go/terminal
  prerequisites. This creates a concrete VM path for the broad Python socket
  suite against CMX; the suite itself still must run on the VM/CI per policy.
- Added a manual `Desktop CMX tests_v2` GitHub Actions workflow at
  `.github/workflows/desktop-cmx-tests-v2.yml`. It checks out a selected ref,
  downloads the GhosttyKit xcframework for the checked-out submodule SHA,
  starts the repo virtual display helper, and invokes
  `scripts/run-tests-v2.sh` with
  `CMUX_TESTS_V2_ALLOW_NON_VM=1`,
  `CMUX_TESTS_V2_DESKTOP_CMX_BACKEND=1`, and a dispatch-time
  `CMUX_TESTS_V2_FILTER`. The workflow uploads the diagnostics directory
  captured by the runner. Local validation covered shell syntax, YAML parsing,
  and `git diff --check`; the workflow still needs a GitHub run on a pushed ref.
- Added `tests_v2/test_desktop_cmx_workspace_split_tab.py` and included it in
  the workflow's default targeted subset. This CMX-only artifact creates a new
  Rust-backed workspace, asserts it starts with one terminal surface and one
  default space, creates an incremental same-pane terminal tab, splits that tab
  right, checks that `pane.list` and `debug.layout` agree on `[1, 2]` pane
  surface counts / three terminal surfaces / `spaceCount=1`, verifies Ghostty
  cursor style `bar`, and sends a PTY marker through the split terminal. It
  returns a skip in non-CMX runs so the existing legacy `tests_v2` default glob
  does not fail outside the cutover workflow. Local validation covered Python
  compilation only; per repo policy the socket test itself still needs the
  tagged CI/VM runner.
- Added a manual `Desktop CMX UI tests` workflow at
  `.github/workflows/desktop-cmx-ui.yml` for the CMX-backed Bonsplit XCUITest
  artifacts. The default `only_testing` list runs
  `BonsplitTabDragUITests/testCmxBackendMinimalModeKeepsTabReorderWorking` and
  `BonsplitTabDragUITests/testCmxBackendMinimalModeDragToSplitCreatesPane`
  under a virtual display, with downloadable `.xcresult`, tagged debug log, and
  `/tmp/cmux-cmx-ui-bonsplit-cmx-*` diagnostics artifacts. Local validation
  covered YAML parsing and `git diff --check`; the workflow still needs a
  GitHub run on a pushed ref.
- Added a manual `Desktop CMX remote fixtures` workflow at
  `.github/workflows/desktop-cmx-remote-fixtures.yml`. It runs the CMX-backed
  `tests_v2` launcher against the Rust remote-state model test, SSH CLI
  metadata, cmuxd-remote stdio resize semantics, and the Docker-backed SSH
  bootstrap/relay/forwarding/reconnect/port/proxy/shell-integration fixtures.
  The workflow fails early if Docker or Go is unavailable so a skipped fixture
  cannot be mistaken for remote proof, and it uploads the same tagged CMX
  diagnostics directory as the broad `tests_v2` workflow. It sets
  `CMUX_TESTS_V2_FAIL_ON_SKIP=1`, so fixture-level skips fail the run instead of
  silently passing. It also has an explicit `run_external_ssh` path for
  host-backed SSH fixtures, sourcing
  `CMUX_SSH_TEST_HOST`, optional port/options/web-port, and optional
  base64-encoded identity material from repository secrets. Local validation
  covered YAML parsing and dispatcher dry-run command construction; the workflow
  itself must run on a pushed ref with a Docker-capable macOS runner, plus a
  configured external SSH host when that optional path is enabled.
- Added `scripts/dispatch-desktop-cmx-ci.sh` as the branch handoff command for
  the external gates. It refuses to dispatch without a pushed ref/upstream,
  supports `--dry-run`, and launches main `ci.yml`,
  `desktop-cmx-tests-v2.yml`, `desktop-cmx-remote-fixtures.yml`, and
  `desktop-cmx-ui.yml` with the targeted CMX defaults. The tests_v2 default
  subset now includes direct workspace split/tab creation, workspace layout
  creation, browser CLI parity, tmux compatibility, remote Rust state, browser
  worker/unsupported matrix, and window/pane/split scoping. The remote fixture
  default subset covers the Docker/SSH matrix separately from the broad socket
  suite, with `--skip-remote`, `--remote-filter`, `--include-external-ssh`, and
  `--external-ssh-filter` available for runner limitations or targeted re-runs.
  Local validation covered `bash -n`,
  `--dry-run --ref feat-desktop-cmx-backend`, the all-skipped guard path, YAML
  default parsing, and `git diff --check`.
- Added `tests/test_shell_integration_cursor_reset.py` to CI's no-socket
  regression step. The test sources the bundled bash and zsh cmux shell
  integrations, verifies `_cmux_reset_ghostty_cursor_if_needed` emits
  Ghostty's `CSI 0 q` default-cursor reset only when
  `CMUX_GHOSTTY_CURSOR_RESET=1`, and verifies the preexec/prompt hooks reset
  before and after foreground commands. Local validation covered Python
  compilation, CI YAML parsing, and `git diff --check`; per repo policy the
  test itself still needs CI execution.
- Finalized the feature's submodule dependencies for CI checkout. The Ghostty
  display-link fallback is committed and pushed as
  `f78039e19e3c67948b42b308d7b8d1f548bdc074` on
  `manaflow-ai/ghostty` branch `task-desktop-cmx-displaylink-fallback`; the
  matching `GhosttyKit.xcframework.tar.gz` was built with ReleaseFast,
  validated, published as
  `xcframework-f78039e19e3c67948b42b308d7b8d1f548bdc074`, and pinned in
  `scripts/ghosttykit-checksums.txt`. The Bonsplit same-pane tab-move callback
  fix is committed and pushed as
  `77d3f7a7a5ecc33b51918332bb7f0422c0eea577` on
  `manaflow-ai/bonsplit` branch `task-desktop-cmx-tab-move-callbacks`. Parent
  submodule pointers now reference reachable SHAs instead of dirty detached
  worktrees.
- Added a Rust import-once regression artifact,
  `import_desktop_session_preserves_existing_cmx_snapshot_and_writes_skip_marker`,
  in `rust/cmux-cli/crates/cmux-cli-server/src/snapshot.rs`. It pre-creates a
  Rust-owned `snapshot.json`, imports a valid Swift desktop session snapshot,
  verifies the Rust snapshot bytes are preserved, verifies no source backup is
  written, verifies the marker status is `skipped_existing_cmx_snapshot`, and
  verifies a second import returns `AlreadyImported`. Local validation covered
  `cargo fmt -p cmux-cli-server` and `git diff --check`; the Rust test itself
  still needs CI execution.
- After adding the workflow, tagged reload
  `CMUX_DESKTOP_CMX_BACKEND=1 CMUX_REMOTE_SSH_STACK_IN_RUST=1
  ./scripts/reload.sh --tag desktop-cmx-backend --launch` succeeded. A focused
  socket smoke created workspace `c0de0001-c0de-4000-8000-0000000000e0`, added
  same-pane terminal surface `c0de0002-c0de-4000-8000-00e000000001`, split right
  to `c0de0002-c0de-4000-8000-00e000000002`, observed one default space, two
  panes with surface counts `[1, 2]`, three terminal surfaces, a connected
  native bridge, ten explicit unsupported browser methods, visible PTY output
  for `CMX_LIVE_SMOKE_260508`, and `"terminalCursor": { "style": "bar" }`.
- The same tagged cutover smoke configured an unreachable SSH remote on
  workspace `c0de0001-c0de-4000-8000-0000000000dc` and observed Rust-owned
  `connection_owner="cmx-rust-ssh-bootstrap"` with daemon detail
  `Remote daemon bootstrap failed: failed to query remote platform (retry 1 in
  4s)`, proving retry count surfacing on the local failure path.
- Durable multi-window active workspace restore now survives tagged app/daemon
  restart. A clean-env smoke used two AppKit window UUIDs
  `55CAA023-C3F6-40A3-B956-32AC96F2926F` and
  `E3523B99-D41E-40EC-BDF8-57AFECAB2D6F`, selected different CMX workspaces in
  each (`...0023` and `...0022`), verified `native-windows.json`, relaunched via
  `CMUX_DESKTOP_CMX_BACKEND=1 ./scripts/reload.sh --tag desktop-cmx-backend
  --launch`, and confirmed `list-windows` restored exactly those two windows
  with their distinct selected workspaces and no extra bootstrap window.
- Worker-backed browser automation is active through the cmx command path for
  WKWebView-capable methods. The same smoke opened a `data:` URL browser
  surface `c0de0002-c0de-4000-8000-002100000001`, then verified
  `browser wait --function`, `browser eval 'document.title'`,
  `browser get text body`, and `browser snapshot --compact --max-depth 3`
  returned the expected `CMXBrowserWorkerFix` / `OK` content through the
  Rust compatibility socket and native WebView worker.
- `browser.input_keyboard` is now Rust-local as a compatibility alias for
  `browser.press`, `browser.keydown`, and `browser.keyup`; raw CDP keyboard
  injection is still not claimed. A tagged smoke verified
  `system.capabilities.unsupportedMethods` no longer contains
  `browser.input_keyboard`, opened data URL browser surface
  `c0de0002-c0de-4000-8000-002400000003`, then confirmed
  `browser input keyboard A` emitted `keydown:A,keypress:A,keyup:A` and
  `browser input_keyboard keydown Shift` / `keyup Shift` emitted
  `keydown:Shift,keyup:Shift` through the cmx compatibility socket.
- `browser.input_mouse` is now Rust-local for WKWebView-compatible DOM mouse
  events at viewport coordinates. A tagged smoke opened a `data:` URL browser,
  ran `browser input mouse click 20 20`, verified the worker routed through
  `browser.eval`, observed
  `mousemove:20,20,mousedown:20,20,mouseup:20,20,click:20,20`, and confirmed
  `system.capabilities.unsupportedMethods` no longer contains
  `browser.input_mouse`. Raw CDP mouse injection is still not claimed.
- `browser.input_touch` is now Rust-local for WKWebView-compatible DOM
  pointer/touch events at viewport coordinates. A tagged smoke on restored
  browser surface `c0de0002-c0de-4000-8000-002600000001` ran
  `browser input touch tap 20 20`, verified it routed through `browser.eval`,
  and observed `pointerdown`/`pointerup`/`click` events with pointer type
  `touch`. Raw CDP touch injection is still not claimed.

## Completion Audit

Objective: implement a complete desktop cutover from the Swift-owned backend to
Rust `cmx`, preserving the existing `cmux` CLI/socket contract while keeping the
macOS app as the native renderer/OS integration layer.

Current requirement-to-evidence checklist:

- Rust is ground truth for workspace/pane/surface/terminal state: substantially
  implemented under the cutover flag. Evidence: workspace create/select/close,
  split, tab stack, surface move/reorder/split-off/drag-to-split, notifications,
  status/progress/log metadata, remote status, browser model, and VM command
  smokes are served from Rust and documented above. Remaining blocker: legacy
  Swift backend deletion is not complete.
- Visible CMX-backed terminal works through Ghostty PTY bytes: implemented for
  local desktop smokes. Evidence: tagged reloads render restored GhosttyKit
  surfaces, PTY replay/live bytes are delivered by terminal ID plus window ID,
  input/send-key/read-screen paths work, and relaunch restore preserves pane
  trees plus scrollback markers. The VM `tests_v2` runner can now launch its
  tagged app with the CMX backend enabled. Remaining blocker: broad
  CI/socket/E2E suites still need VM/GitHub execution per repo policy.
- Session restoration and import-once: implemented for the tagged desktop path.
  Evidence: CMX `snapshot.json` is the post-import authority, legacy Swift
  import is skipped once that file exists, old Swift autosave is skipped under
  the flag, and relaunch/forced-parent-termination smokes restored the same
  CMX workspace/tree. The Swift startup wrapper now lets Rust write an explicit
  `skipped_existing_cmx_snapshot` import marker when CMX state already exists
  without a marker, and the Rust unit artifact now asserts that path preserves
  the existing Rust snapshot and avoids writing a backup of stale Swift state.
  Remaining blocker: the new unit artifact and production restore matrix still
  need CI/VM verification before shipping.
- Desktop spaces: implemented as one default CMX space per desktop workspace.
  Evidence: restore and creation smokes inspect `spaceCount: 1` in the Rust
  snapshot for new desktop workspaces.
- Hard cutover flag with easy disable: implemented. Evidence:
  `CMUX_DESKTOP_CMX_BACKEND=1` enables the path, `CMUX_DESKTOP_CMX_BACKEND_DISABLED`
  wins, tag-scoped defaults are supported, tagged bundles persist the flag
  and tag in `LSEnvironment` for normal `.app` relaunches, and Swift passes the
  enabled bit into the child `cmx` daemon even when the app setting came from
  defaults/tag state rather than the launch environment. The desktop flag also
  implies the Rust SSH stack unless stack/per-feature disable flags are set.
- IPC between Swift and Rust: implemented for local desktop via AF_UNIX
  length-prefixed MessagePack native socket plus Rust-served compatibility
  socket. Evidence: Swift `CmxConnection`/`CmxDesktopDaemon` connect to the
  native socket, Rust serves `/tmp/cmux-debug-<tag>.sock`, and the existing CLI
  talks to Rust while native snapshots/PTY/browser updates flow over the
  native channel.
- Preserve existing `cmux` socket API and CLI: mostly implemented for the
  covered command surface. Evidence: `system.capabilities` advertises Rust
  local/delegated/browser-worker/native-worker/unsupported methods, and focused
  smokes cover core workspace, pane, surface, tab, terminal, browser model,
  browser worker, remote, VM, notification, feed, debug methods,
  `cmux new-workspace --layout`, raw `workspace.create initial_command` /
  `initial_env`, and direct split/tab creation focus semantics. Remaining
  blocker: unsupported WKWebView/CDP-equivalent browser methods
  (viewport/geolocation/offline/trace/network/screencast/raw CDP input beyond
  the DOM input aliases) and
  broad CI parity suites still gate the claim that every API is preserved.
- Browser state and proxy ownership: implemented at the CMX model layer.
  Evidence: browser tabs/splits persist URL/title/profile/proxy fields in Rust,
  browser restore survives relaunch, remote proxy state is inherited into the
  browser snapshot, and worker-backed WebView methods run through the Rust
  compatibility command path. Remaining blocker: some browser automation
  methods are explicit `not_supported` responses because WKWebView has no
  equivalent API.
- Multi-window state: implemented for connected native windows and durable
  active-workspace restore. Evidence: Swift opens one native CMX session per
  AppKit window, Rust tracks native window projections and closed-window
  tombstones, real AppKit UUIDs are exposed through window/list payloads,
  close-window smokes no longer resurrect closed windows, and a tagged relaunch
  restored two AppKit window IDs with distinct selected workspaces from Rust's
  `native-windows.json`. Rust also persists per-window workspace membership and
  window-scoped next/previous/select behavior. Latest evidence:
  `workspace.last` now uses window-local history and `pane.last` resolves the
  target workspace/window before focusing the alternate pane; moved-workspace
  socket coverage asserts both commands stay in the destination AppKit window.
  Rust window-state merges now preserve Rust-owned active workspace/history and
  durable membership across native snapshot updates, reject stale source-window
  claims after a move, and restore CMX workspace UUIDs without reusing existing
  external IDs from non-contiguous snapshots. Focused smokes passed for
  `tests_v2/test_windows_api.py`,
  `tests_v2/test_surface_split_window_scope.py`, and
  `tests_v2/test_pane_window_scope.py` against the tagged CMX backend socket.
  A fresh `desktop-cmx-restore` tag created CMX-owned window
  `9F8B91B1-90AF-44CF-A7E5-7DEF517A3565`, verified it was written to
  `native-windows.json`, reloaded the same tag, and confirmed `window.list` and
  `debug.layout.native_window_ids` restored it (`windows=2`, `native_ids=2`).
  A post-`window.close` smoke created CMX-owned window
  `1F188D42-5633-497A-8CFE-B423713FE4AD`, observed Swift reconcile/create the
  AppKit window from `native_window_ids`, then called Rust-local `window.close`;
  the window disappeared from `window.list`/`debug.layout.native_window_ids`,
  Swift logged `desktopCmxBackend.window.reconcile.close`, and the native close
  callback sent an idempotent `close-window-by-id` command back to Rust.
  `workspace.move_to_window` now materializes unknown valid window UUIDs in
  Rust instead of delegating to Swift: a smoke moved workspace
  `c0de0001-c0de-4000-8000-000000000082` to new window
  `3E830EA2-CCE8-4CFF-8284-10DBB9798380`, Swift reconciled the AppKit window
  from `native_window_ids`, stale native snapshots were ignored by revision
  gating, and Rust-local `window.close` removed it. The legacy
  `move_workspace_to_window` line protocol also returned `OK` for new window
  `B9CF0704-C8A8-49BA-A1C1-11084B762CAB`.
  `surface.move` now shares that materialization path when the request includes
  a destination workspace: a smoke moved surface
  `c0de0002-c0de-4000-8000-008b00000001` to workspace
  `c0de0001-c0de-4000-8000-00000000008c` on new window
  `45C54AA9-04CE-486C-B2AA-25456660D939`, observed
  `desktopCmxBackend.window.reconcile.create` / stale-snapshot skips /
  `desktopCmxBackend.window.reconcile.close`, and verified Rust-local close
  removed the materialized window.
  Remaining blocker: AppKit window instantiation and teardown remain Swift
  reconciliation side effects because `NSWindow` itself is native UI.
- Ghostty cursor shape/behavior: implemented in the protocol/config path and
  visually/runtime-smoked with CI coverage added for shell reset behavior.
  Evidence: Rust parses `cursor-style` and
  `cursor-style-blink` into `NativeTerminalCursor`, server-side replay/default
  cursor code normalizes blink/style against that config, Swift emits the
  received cursor config into Ghostty config fragments, and local runtime smoke
  verified `cursor-style = "bar"` appears as
  `"terminalCursor": { "style": "bar" }` for CMX-backed surfaces. An isolated
  daemon smoke with a temp Ghostty config also verified blink propagation via
  `"terminalCursor": { "style": "underline", "blink": false }`. Tagged visual
  PNG smokes verified the default bar caret and a bundle-configured underline
  caret render with the expected pixel-delta shape. The new no-socket CI test
  executes the bundled bash/zsh integration hooks and asserts they emit
  `CSI 0 q` only under `CMUX_GHOSTTY_CURSOR_RESET=1`, so shell prompt/preexec
  no longer forces Ghostty's bar cursor when the backend config says otherwise.
  Remaining blocker: broad UI/VM coverage still needs to run this across
  restore and remote-backed sessions.
- Swift-guidance constraints: partially implemented. Evidence: new bridge code
  uses actor/task/MainActor boundaries, and the workspace/detected-SSH
  drop-upload completion path plus remote-session status/proxy/port/heartbeat
  publication paths now use narrow `Task { @MainActor in ... }` handoffs instead
  of ad hoc `DispatchQueue.main.async`. The CMX daemon startup task now declares
  `@MainActor` explicitly, and the nearby asynchronous quit/close-confirmation
  UI handoffs use MainActor tasks. The routing keeps state mutation out of
  SwiftUI/view-body paths; blocking SSH/process/socket work is still isolated
  behind the existing low-level adapters. Remaining blocker: older app code and
  low-level socket adapters still contain DispatchQueue usage; a full
  strict-concurrency cleanup is not complete.
- Forced lifecycle cleanup: implemented for the tagged desktop child. Evidence:
  Swift passes the parent PID to the bundled `cmx`, Rust exits when that parent
  disappears, and a `KILL` smoke stopped both the app and child before relaunch
  restore.
- Native-worker method audit: current live `system.capabilities` reports
  `delegatedMethods=0` and `nativeWorkerMethods=27`. The remaining native
  workers are platform/auth/UI/debug boundaries rather than backend state
  owners: `auth.begin_sign_in`, `auth.sign_out`, `auth.status`; app/window
  focus and screenshots; browser address-bar/favicon inspection; command
  palette, right-sidebar, sidebar, shortcut, and debug typing helpers;
  feedback/settings/file/markdown openers. No `workspace.*`, `pane.*`,
  `surface.*`, terminal PTY, persistence, or remote-state authority remains in
  the native-worker list. These Swift workers can remain as the desktop-native
  integration surface while the old backend model is deleted.

Known remaining gaps before this can be considered a 100% cutover:

- CI/VM execution is currently blocked from this checkout: the local branch is
  `feat-desktop-cmx-backend` with no configured upstream, so GitHub Actions
  cannot run the unpushed local changes; and the local `cmux-vm` SSH alias does
  not resolve from this machine. The next verification step is to commit/push
  this branch or otherwise place the worktree on the VM, then run
  `scripts/dispatch-desktop-cmx-ci.sh --ref feat-desktop-cmx-backend` to
  dispatch main CI, `Desktop CMX tests_v2`, `Desktop CMX remote fixtures`, and
  `Desktop CMX UI tests`.
- Remote fixture proof: remote command/status authority,
  non-connecting remote configuration/disconnect, side-effect-free VM/WebSocket
  model auto-connect/disconnect/reconnect, daemon-WebSocket live proxying,
  non-secret remote reconnect config, VM command execution, same-process
  foreground-auth handoff, remote-daemon release/cache metadata, SSH bootstrap
  binary/path planning, hidden SSH probe/upload/hello, normal SSH
  `workspace.remote.configure` first-attempt bootstrap, SSH stdio daemon proxy,
  reverse CLI relay, TTY-scoped port scans, workspace remote drop upload, and
  ad-hoc detected-SSH-session drop upload are Rust-owned when
  `CMUX_DESKTOP_CMX_BACKEND=1` is active. The manual
  `Desktop CMX remote fixtures` workflow now gates the Docker/SSH subset with
  Docker/Go preflight checks and has an optional external-SSH-host job path;
  the remaining blocker is a successful run on a pushed ref with the required
  runner/tools/secrets.
- Some browser automation methods are preserved as explicit unsupported
  WKWebView errors rather than CDP-compatible implementations:
  viewport/geolocation/offline/trace/network/screencast.
  `browser.input_keyboard`, `browser.input_mouse`, and `browser.input_touch`
  are handled only as DOM event compatibility aliases, not as full raw CDP input
  injection.
- Direct Bonsplit drag/drop UI paths still need CI/VM execution against cmx
  snapshots. The same-pane reorder and drag-to-split paths now have targeted
  CMX-backed XCUITest artifacts that perform real drag gestures, plus a manual
  `Desktop CMX UI tests` workflow to run them under a virtual display; these
  must pass in the CI/VM UI environment before deleting the legacy backend.
- The broad Python E2E/socket suites have not been run locally per repo policy;
  they need CI/VM runs against the cmx backend fixture. The VM runner and
  manual `Desktop CMX tests_v2` workflow now support that mode with
  `CMUX_TESTS_V2_DESKTOP_CMX_BACKEND=1 ./scripts/run-tests-v2.sh`, plus
  optional targeted subsets such as
  `CMUX_TESTS_V2_FILTER="test_remote_rust_state.py test_browser_api_p0.py"`.
- Legacy Swift backend deletion is not complete; this branch is still a hard
  cutover flag path rather than a removed-old-backend path.
