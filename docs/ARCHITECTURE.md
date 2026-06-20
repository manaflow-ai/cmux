# cmux — Master Architecture

cmux is a **native macOS terminal multiplexer** (Swift / AppKit — **not** Electron) built on **libghostty**, the Ghostty terminal engine, vendored as the `ghostty/` git submodule and consumed as `GhosttyKit.xcframework` for GPU-accelerated rendering. It targets developers running **many parallel AI coding-agent sessions**: a vertical-tab sidebar surfaces each workspace's git branch, PR status, open ports, and latest notification; a notification ring lights panes that need attention; an embedded scriptable browser; an AI agent chat / session surface; a Kanban board for autonomous agent dispatch; and a full CLI + Unix-socket control plane for automation.

This document is the authoritative cross-cutting reference for cmux architecture: layer boundaries, key runtime flows, and invariants. See [CONTRIBUTING.md](../CONTRIBUTING.md) for setup steps and `../CLAUDE.md` for the contributor rules. Sections 1–4 build the mental model; section 5 is the "Where do I find X?" index; section 6 collects the non-negotiable invariants. Per-topic specs in this `docs/` directory (linked throughout) own the authoritative detail — this document maps how they fit together.

---

## 1. What cmux is + the Runtime Model

The UI is a strict containment hierarchy. Every CLI handle (`window:N`, `workspace:N`, `pane:N`, `surface:N`) maps onto a node in this tree:

```
Window (NSWindow / CmuxMainWindow)
  └── MainWindowContext         per-window state bundle (windowId, TabManager, SidebarState, CmuxConfigStore)
       └── TabManager           @MainActor; owns the workspace list + groups for this window
            └── Workspace        one sidebar tab (≈ tmux session). Cmd+1–8 switches. BonsplitController + Panel registry.
                 └── Pane        a node in the split tree (Bonsplit). Holds surfaces as horizontal tabs.
                      └── Surface      one tab. Contains exactly one Panel. Ctrl+1–8 jumps within a pane.
                           └── Panel   the content type (see enum below)
```

- **Window** — a native `NSWindow`. Multiple windows supported; each has its own `MainWindowContext`, `TabManager`, and control-socket routing.
- **Workspace** — tmux-session-like container; Cmd+1–8. Mutable metadata: name, description, color, cwd, status, progress, log, git branch, PR badge. Can belong to a collapsible **workspace group** (one **anchor** workspace owns the group header).
- **Pane** — a split region inside a workspace (the Bonsplit split tree).
- **Surface** — a tab inside a pane; corresponds to exactly **one** Ghostty terminal surface (or a non-terminal panel). **`surface_id` is the stable automation handle and must never change across move/reorder.**
- **Panel** — the content rendered inside a surface.

### Panel types (`PanelType` enum)

Defined in `Sources/Panels/Panel.swift`; the persistence/wire mirror is `SurfaceKind` in `Packages/macOS/CmuxWorkspaces/SurfaceKind.swift`. SwiftUI dispatch on the type is in `Sources/Panels/PanelContentView.swift`.

| Case | Content |
|---|---|
| `terminal` | A Ghostty terminal (`TerminalSurface`) — the default, typing-latency-critical path. |
| `browser` | Embedded WKWebView browser tab (`BrowserPanel`). |
| `markdown` | Read-only live-watched markdown render (WKWebView). |
| `filePreview` (raw `filepreview`) | PDF / image / file preview. |
| `rightSidebarTool` | Right-sidebar tool surface. |
| `agentSession` | AI agent chat/session surface rendered in a WKWebView (React/Solid). |
| `project` | Xcode-project browser panel. |
| `extensionBrowser` | Sidebar-extension-hosted browser. |
| `kanban` | Autonomous-agent Kanban board (WKWebView). |

`PanelType.init(from:)` is intentionally **case-insensitive / fail-tolerant** for several legacy raw values — do not "simplify" the decoder by dropping branches without a regression test.

---

## 2. Layer / Dependency Map

cmux is one git repo containing several independently-deployed artifacts. They communicate over wire protocols (Unix socket, JSON-RPC, TCP/WebSocket, deep links), **not** by importing each other across the Swift/TS boundary.

```
                      ┌───────────────────────────────────────────────┐
                      │  web/  (Next.js on Vercel)                     │  cloud control plane + marketing/docs
                      │  workers/presence/ (Cloudflare DO)            │  realtime presence + device sync
                      └───────────────▲───────────────▲───────────────┘
                                      │ HTTPS/WS       │ HTTPS/WS
                                      │                │
   ┌──────────────┐   Unix socket   ┌┴────────────────┴────────────┐    JSON-RPC over SSH stdio / WS
   │  CLI/ (cmux) │ ───────────────▶│  Sources/ (macOS app target)  │◀──────────────┐
   └──────────────┘   v1 text / v2  │  the composition root         │               │
        ▲              JSON-RPC     └───────────┬───────────────────┘        ┌───────┴────────────────┐
        │  also: tmux shim,                     │ depends on                  │ daemon/remote/         │
        │  agent hooks                          ▼                             │ cmuxd-remote (Go)      │
        │                          ┌────────────────────────────┐            │ remote PTY / proxy     │
   AI agent runtimes               │ Packages/macOS/*  (SPM)     │            └────────────────────────┘
   (Claude/Codex/…)                │ Packages/Shared/* (SPM)     │
                                   └────────────┬───────────────┘
   ┌──────────────────────┐                     │ Shared used by both apps
   │ webviews/ (Vite)     │ WKWebView bridge    ▼
   │ Kanban / agentSession│◀──────────┐  ┌────────────────────────────┐
   │ / diff panels        │           └──│ ios/ + Packages/iOS/* (SPM)│  iOS companion app
   └──────────────────────┘  loaded by    └────────────────────────────┘  (paired Mac over Tailscale/iroh)
        the macOS app & iOS
```

### Who depends on whom

- **`CLI/`** (the bundled `cmux` binary) depends on a few `Packages/macOS` value types (e.g. `CmuxControlSocket` wire types, `CmuxSettings` socket-path policy, `CMUXAgentLaunch`) and shares some pure files with the app/test targets, but it is a **separate process**. It reaches the app only over the Unix socket.
- **`Sources/`** (the macOS app target, the **single composition root**) depends downward on `Packages/macOS/*` and `Packages/Shared/*`. No package imports the app target back — coupling is inverted through injected protocol seams.
- **`Packages/macOS/*`** — macOS-app-only SPM packages (terminal model, control socket, sidebar, workspaces, browser, canvas, Kanban engine, remote SSH, settings, updater). May depend on each other and on `Packages/Shared/*` and `Packages/macOS/CmuxFoundation` (bottom of the graph). They depend on **`any Protocol`** seams, never on concrete app types.
- **`Packages/Shared/*`** — cross-platform packages used by **both** the macOS app and the iOS app. Pure Swift 6, no AppKit/UIKit/Ghostty. Owns the agent-chat domain model, transcript parsing, auth value types, mobile sync protocol.
- **`Packages/iOS/*`** + **`ios/`** — the iOS companion app only. Depends on `Packages/Shared/*` (and `Packages/iOS/*`). Mirror-surface terminal: the Mac owns the real PTY; bytes stream to the iOS Ghostty surface.
- **`web/`** — standalone Next.js app on Vercel. No Swift dependency; talks to the Mac only over the cmux:// deep-link protocol or cloud APIs.
- **`webviews/`** — separate Vite build producing static JS/CSS chunks loaded by the macOS app (and iOS) inside WKWebView. Communicates with native via `WKScriptMessageHandlerWithReply`.
- **`daemon/remote/`** — Go `cmuxd-remote` binary uploaded to a remote SSH host; serves JSON-RPC over stdio/WebSocket. The app's `Packages/macOS/CmuxRemoteSession` / `CmuxRemoteWorkspace` drive it.
- **`workers/presence/`** — Cloudflare Worker + Durable Object. Consumed by the iOS app (`PresenceClient`) and the Mac (`PresenceHeartbeatClient`).

### Package-group rules (enforced by CI)

Every Swift package lives physically under exactly **one** group folder, and `cmux.xcworkspace/contents.xcworkspacedata` mirrors that folder shape exactly:

- **`Packages/Shared/<pkg>`** → used by **both** apps (macOS + iOS).
- **`Packages/iOS/<pkg>`** → **iOS app only**.
- **`Packages/macOS/<pkg>`** → **macOS app only**.

The folder is the source of truth. To move a package between groups: `git mv` the directory, then `python3 scripts/check-workspace-package-groups.py --write`. Cross-group deps use `.package(path: "../../<Group>/<Name>")`. CI runs `--check` and fails on drift. New packages go in the group folder matching their consumers.

---

## 3. Per-Layer Summary

### CLI/ — the bundled `cmux` binary
- Single Swift executable; 150+ subcommands talking to the app over a Unix socket (v1 line-text or v2 JSON-RPC).
- Hosts the **AI agent hook system** (install/route hooks for many agent runtimes — see [agent-hooks.md](agent-hooks.md) for the authoritative integration list), **auto-naming** engine, **tmux compatibility shim**, and `cmux ssh` / `cmux vm` remote PTY entry points.
- Entry points: `CLI/cmux.swift` (the CLI monolith — `CMUXCLI`, `SocketClient`, `ClaudeHookSessionStore`, `@main CMUXTermMain`), `CLI/cmux_open.swift` (`cmux open` / `cmux diff`), `CLI/CMUXCLI+AgentHookDefinitions.swift` (the `agentDefs` registry), `CLI/CLISocketPathResolver.swift`.

### Sources/ — the macOS app target (composition root)
- Wires every SPM package + Ghostty into a runnable app; owns app lifecycle, window management, session persistence, keyboard routing, the panel pipeline, the control plane host, cloud/auth, AI agent surfaces, and window chrome.
- The historical god-files (`AppDelegate.swift`, `Workspace.swift`, `TerminalController.swift`, `ContentView.swift`, `BrowserPanel.swift`) are being decomposed into the `Packages/macOS` packages; treat them as work-in-progress, not reference design.
- Entry points: `Sources/cmuxApp.swift` (`@main CmuxMain`), `Sources/AppDelegate.swift`, `Sources/TabManager.swift`, `Sources/Workspace.swift`, `Sources/TerminalController.swift`, `Sources/Panels/Panel.swift`.

### Packages/macOS/* — decomposed macOS units
- Focused, independently-testable packages: `CmuxTerminal`/`CmuxTerminalCore` (Ghostty surface model), `CmuxControlSocket` (socket server + RPC dispatch), `CmuxWorkspaces` (workspace/group lifecycle), `CmuxSidebar`/`CmuxSidebarGit` (sidebar + git/PR badges), `CmuxKanbanCore` (Kanban dispatch engine), `CmuxRemoteSession`/`CmuxRemoteWorkspace` (SSH remote), `CmuxSettings` (typed settings), `CmuxBrowser`, `CmuxCanvas`/`CmuxCanvasUI`, `CmuxCommandPalette`, `CmuxUpdater`.
- Architecture rules are strict (see §6): Swift 6 concurrency only, no singletons holding runtime state, no free functions, one major type per file, DocC on every public symbol, constructor injection only.
- Entry points: `Packages/macOS/CmuxControlSocket/.../ControlCommandCoordinator.swift`, `Packages/macOS/CmuxTerminal/.../TerminalSurface.swift`, `Packages/macOS/CmuxKanbanCore/.../KanbanEngine.swift`, `Packages/macOS/CmuxSettings/.../CmuxStateDirectory.swift`.

### Packages/Shared/* — cross-platform (both apps)
- The "intelligence" layer: `CmuxAgentChat` (transcript parsing + live `ChatConversationStore`), `CMUXMobileCore` (pairing/transport/render-grid wire), `CMUXAuthCore` + `CmuxAuthRuntime` (auth value types + browser sign-in), `CmuxSyncStore` (local-first SQLite sync), `CMUXAgentLaunch` (agent launch sanitization shared with CLI).
- Pure Swift 6, `swiftLanguageMode(.v6)`, no AppKit/UIKit/Ghostty, no external SPM deps in the core chat package.
- Entry points: `Packages/Shared/CmuxAgentChat/Store/ChatConversationStore.swift`, `Packages/Shared/CmuxAgentChat/Parsing/ClaudeTranscriptParser.swift`, `Packages/Shared/CMUXMobileCore/CmxTransport.swift`.

### Packages/iOS/* + ios/ — the iOS companion app
- Bridges a paired Mac's multiplexer state to mobile: pairing/reconnect, live Ghostty terminal mirroring over JSON-RPC, agent-chat UI, presence, push, in-app browser, QR pairing.
- Single god-store `MobileShellComposite` (`CMUXMobileShellStore`) drives every view; strict dependency chain `CmuxMobileShellModel ← CmuxMobileShell ← CmuxMobileShellUI`.
- Entry points: `ios/cmux/cmuxApp.swift`, `ios/cmux/AppCompositionRoot.swift`, `Packages/iOS/CmuxMobileShell/MobileShellComposite.swift`, `Packages/iOS/CmuxMobileTerminal/GhosttySurfaceView.swift`.

### web/ — Next.js cloud control plane
- Public site (marketing/docs/changelog/community) + Cloud VM control plane (Effect.ts over E2B/Freestyle) + iOS services (APNs push, device registry, analytics proxy).
- Locale-prefixed App Router (`app/[locale]/`); VM layer is all Effect.ts (`runVmWorkflow`); Postgres (Drizzle) is the source of truth for VM lifecycle.
- Entry points: `web/app/[locale]/layout.tsx`, `web/services/vms/workflows.ts`, `web/app/db/client.ts`, `web/proxy.ts`.

### webviews/ — WKWebView panels
- Separate Vite build; single `main.tsx` dispatcher detects the surface kind from DOM data attributes and lazy-imports `kanban` / `agent-session` / `diff` chunks.
- Native bridge via `createNativeBridge` (request/reply + push events); board/session state is **native-authoritative** (every reply or event replaces the whole model).
- **Build with `./scripts/build-webviews-app.sh`, not bare `bun run build`** — the latter has `emptyOutDir: true` and deletes the HTML shells. See §6.
- Entry points: `webviews/src/main.tsx`, `webviews/src/kanban/react/main.tsx`, `webviews/src/agent-session/shared/sessionModel.ts`, `webviews/src/shared/nativeBridge.ts`.

### daemon/remote/ — Go cmuxd-remote
- Runs on a remote SSH host: JSON-RPC over stdio (`cmux ssh`) or WebSocket (`--ws`); PTY session multiplexing, TCP proxy streams, CLI relay, tmux-compat shim, agent-launch wrappers.
- Entry points: `daemon/remote/cmd/cmuxd-remote/main.go` (`rpcServer`), `cli.go` (CLI relay), `agent_launch.go`, `tmux_compat.go`, `ws_pty.go`. Full spec: [remote-daemon-spec.md](remote-daemon-spec.md).

### workers/presence/ — Cloudflare presence Worker
- One `TeamPresence` Durable Object per team; heartbeat-driven device presence (15s interval, 45s offline) fanned to WebSocket (hibernation) + SSE subscribers; hosts a local-first `sync/v1` device-list substrate.
- Entry points: `workers/presence/src/index.ts`, `do.ts` (`TeamPresence`), `core.ts`, `sync.ts`. Full spec: [presence-service.md](presence-service.md).

---

## 4. Key Cross-Cutting Flows

### (a) Keystroke → Ghostty terminal (and the typing-latency paths to protect)

1. The keystroke enters via an `NSEvent` local monitor and the swizzles in `Sources/AppDelegate.swift` (`cmux_applicationSendEvent`, `cmux_performKeyEquivalent`, `cmux_makeFirstResponder`). cmux-owned shortcuts are matched in `handleCustomShortcut(event:)` (chord state machine); everything else falls through.
2. Routing hits `WindowTerminalHostView.hitTest()` in `Sources/TerminalWindowPortal.swift` — **called on every event including keyboard**. All divider/sidebar/drag work is gated behind the `isPointerEvent` guard.
3. The event reaches the focused `GhosttyTerminalView` (`Sources/GhosttyTerminalView.swift`) → the AppKit portal surface → `TerminalSurface` (`Packages/macOS/CmuxTerminal/.../TerminalSurface+Input.swift`) → `ghostty_surface_*` C APIs (always guarded by `liveSurfaceForGhosttyAccess(reason:)` before touching the raw `ghostty_surface_t`).
4. Ghostty's renderer schedules its own wakeup and draws into the `GhosttyMetalLayer` → `CAMetalLayer`. **Never add an app-level display link or manual `ghostty_surface_draw` loop** — a second draw loop causes typing lag.

**Protect these hot paths (read before editing):**
- `WindowTerminalHostView.hitTest()` — no work outside the `isPointerEvent` guard.
- `TabItemView` in `Sources/ContentView.swift` — keeps `Equatable` + `.equatable()` to skip body re-eval during typing. No `@EnvironmentObject`/`@ObservedObject` (besides `tab`)/`@Binding` without updating `==`; don't read `tabManager`/`notificationStore` in the body.
- `TerminalSurface.forceRefresh()` in `Sources/GhosttyTerminalView.swift` — called every keystroke; no allocations, file I/O, or formatting.
- `CmuxWebView.performKeyEquivalent` (browser) — also on the typing path; no allocations.

### (b) CLI → running app over the Unix control socket

1. `cmux <subcommand>` → `CMUXCLI(args:).run()` in `CLI/cmux.swift`. Socket path resolved by `CLISocketPathResolver.resolve()` (stable `~/.local/state/cmux/cmux.sock` > marker file > explicit > tagged-debug discovery), credential by `SocketPasswordResolver`.
2. `SocketClient` connects (verifies `st_uid == getuid()`), then sends either **v1** (`"command args\n"` → line response) or **v2** (`{"id",method,params}` → JSON). Ref handles like `workspace:2` are normalized to UUIDs via a v2 `resolve` round-trip.
3. App side: `SocketControlServer` (`Packages/macOS/CmuxControlSocket`) accepts the connection; `ControlClientLineReader` frames lines; `ControlCommandExecutionPolicy` classifies each method `mainActor` vs `socketWorker`; `ControlCommandCoordinator.handle(_:)` dispatches to one of **13** domain handlers.
4. The handler implementations live in `ControlCommandCoordinator+*.swift` files inside the `CmuxControlSocket` package. Each handler calls back through the `ControlCommandContext` umbrella protocol, whose **witness conformances** live across the **21** `Sources/TerminalController+Control*.swift` files. `TerminalController.shared` is the current in-app host (being decomposed — see §3). Result → `ControlResponseEncoder` → single-line JSON.
5. **Focus invariant:** socket commands must not steal app focus or move workspace/pane/surface selection unless they are on the explicit focus-intent allowlist (e.g. `window.focus`, `workspace.select`, `surface.focus`, `pane.focus`, browser focus commands). High-frequency telemetry (`report_*`, status/progress) must parse and coalesce off-main, then schedule only minimal UI mutation with `.main.async` — never `DispatchQueue.main.sync`. The full allowlist and audit status live in [socket-focus-steal-audit.todo.md](socket-focus-steal-audit.todo.md). For the CLI/socket API surface see [cli-contract.md](cli-contract.md).

### (c) AI agent session launch + render

1. A surface with `Panel.panelType == .agentSession` mounts `AgentSessionWebRendererCoordinator` (`Sources/Panels/AgentSessionWebRendererCoordinator.swift`), which owns a WKWebView (loads the `agent-session` webview chunk over `file://`) and an `AgentSessionProcessStore`.
2. The webview boots (`webviews/src/main.tsx` → `mountAgentSessionSurface`), installs `window.cmuxAgentBridge`, and calls native `app.context` for config/copy/theme, then `provider.start`.
3. Native handles `provider.start` by spawning the agent subprocess in `AgentSessionProcessStore` (`Sources/Panels/AgentSessionProcessStore.swift`) — `Process` + `Pipe`, provider chosen from `AgentSessionProviderID` (codex/claude/opencode; claude runs `-p --output-format stream-json --input-format stream-json` over stdin and reports `shouldAutoStartSession == false`). Launch args/env are sanitized through `CMUXAgentLaunch` (shared with the CLI).
4. Output is fanned out via `AgentSessionEventFanOut` to the primary sink **plus** keyed additional observers — this is how `CmuxLiveBackend` (Kanban live cards) observes a shared store. The bridge pushes `provider.*` events back to the webview, which the Solid/React `sessionModel.ts` reducer applies.
5. The live transcript domain model itself (`ChatConversationStore`, parsers) lives in `Packages/Shared/CmuxAgentChat` and is shared with iOS. See [agent-hooks.md](agent-hooks.md) for the full agent integration table, session hook file locations, and sanitizer rules.

### (d) Sidebar: git branch / PR status / open ports / notifications

1. `TabManager` conforms to `SidebarGitHosting` (`Sources/TabManager+SidebarGitHosting.swift`). On workspace appearance it calls `SidebarGitMetadataService` (`Packages/macOS/CmuxSidebarGit`), which reads git metadata **directly from on-disk repo files** via `CmuxGit.GitMetadataService` (no `git` subprocess for index parsing) on a background `Task.detached`, gated by the process-wide `WorkspaceGitMetadataProbeLimiter`. Results apply on `MainActor` → `host.updatePanelGitBranch`. FSEventStream watchers re-probe on `.git/` changes.
2. **PR badges:** `PullRequestPollService` runs `PullRequestProbeService` (`CmuxGit`): seed → candidate resolution from git remotes → GitHub REST (paged, cached) → match. **10s selected / 60s background** poll. Applies via `host.updatePanelPullRequest`.
3. **Open ports:** for remote workspaces, `CmuxRemoteSession`'s port-scan script reports ports back through `RemoteSessionHosting.publishPortsSnapshot`; the sidebar metadata model surfaces them.
4. **Notifications:** `TerminalNotificationStore` (§e) publishes the coalesced `SidebarUnreadModel`. The sidebar observes `SidebarUnreadModel`, **not** the full store, to avoid the issue #2586 CPU spin.
5. All of this writes into `WorkspaceSidebarMetadataModel` (`Packages/macOS/CmuxSidebar`), which dual-writes each property to a `CurrentValueSubject` in `didSet` (the `sidebarObservationPublisher` chain depends on these subjects). For the event stream sidebar components subscribe to, see [events.md](events.md); for CLI commands that read/write workspace metadata, see [cli-contract.md](cli-contract.md).

### (e) Notification rings (OSC 9/99/777)

1. The agent emits an OSC 9/99/777 escape (or `cmux notify` over the socket) into the terminal PTY. Ghostty surfaces it; cmux routes it to `TerminalNotificationStore.applyNotification()` (`Sources/TerminalNotificationStore.swift`).
2. `TerminalNotificationPolicyEngine` (`Sources/TerminalNotificationPolicy.swift`) runs any configured hook scripts via `posix_spawn` (non-blocking, 750ms grace before SIGKILL, 1 MiB stdout cap; JSON patch on stdout).
3. The store then drives: `UNUserNotificationCenter` banner → dock badge (`NSApp.dockTile.badgeLabel`) → `SidebarUnreadModel` publish (lights the pane/sidebar ring) → 512-slot tombstone ring (UserDefaults) → `PhonePushClient.forward(_:badgeCount:)` to mirror to iOS push.
4. Delivery is serialized through `TerminalMutationBus` (`Sources/TerminalNotificationQueue.swift`), which batches at most 16 mutations per drain onto the main actor. See [notifications.md](notifications.md) for CLI usage, hook configuration, and per-agent setup.

### (f) Kanban / agentSession webview ↔ native bridge

1. The native coordinator (`Sources/Kanban/KanbanWebRendererCoordinator.swift` or `AgentSessionWebRendererCoordinator.swift`) hosts a WKWebView whose `WKWebViewConfiguration` sets the SPI keys `allowFileAccessFromFileURLs` + `allowUniversalAccessFromFileURLs` (via the shared `allowFileURLAccess(_:)` helper) — **required** for React/Solid ES modules over `file://`; removing them silently blanks the panel.
2. The webview bundle (`webviews/`) installs `window.cmuxKanbanBridge` / `window.cmuxAgentBridge` (via `createNativeBridge`) synchronously at module eval. JS→native calls go through `window.webkit.messageHandlers.<name>.postMessage`; native→JS pushes call `window.cmux*Bridge.receive(event)`.
3. State is **native-authoritative**: every reply or `boardUpdated`/agent event replaces the whole board/session model in the JS reducer (`kanban/shared/boardModel.ts`, `agent-session/shared/sessionModel.ts`). The native side is the single source of truth.
4. For Kanban, `KanbanWebRendererCoordinator` lazily creates the `KanbanEngine` (`Packages/macOS/CmuxKanbanCore`, an actor) plus both `DispatchBackend`s: `CmuxNativeBackend` (headless per-card agent) and `CmuxLiveBackend` (observes a shared `AgentSessionProcessStore` owned by a visible surface — it **must not** call `store.start()`). Theme must be applied eagerly in `loadInitialBoard` because native applies theme before the bridge is registered.

### (g) `cmux ssh` remote PTY via the Go daemon

1. `cmux ssh <host>` → `SSHCommandOptions` parsed in `CLI/cmux.swift`; the app's `RemoteSessionCoordinator` (`Packages/macOS/CmuxRemoteSession`) probes the remote platform, acquires the `cmuxd-remote` binary (env override → manifest cache → download → dev go-build), uploads it, and runs `hello` (capability handshake; missing capabilities trigger reinstall+rehello).
2. It establishes a local TCP relay (loopback) and a reverse SSH relay (`ssh -O forward` on a ControlMaster, falling back to `ssh -N -R`) so the remote can call back into the local cmux CLI.
3. The app sends `surface.new` with `relay_host`/`relay_port`; a `TerminalSurface` is created backed by the relay PTY. `cmuxd-remote` (`daemon/remote/cmd/cmuxd-remote/main.go`) serves `session.*` / `pty.*` JSON-RPC; PTY resize uses **smallest-screen-wins** (`min` cols/rows across attachments).
4. `SSHPTYResizeMonitor` (a Swift actor in `CLI/SSHPTYResizeMonitor.swift`) watches SIGWINCH and forwards resizes via `workspace.remote.pty_resize`, coalescing rapid changes.
5. On the remote, agent-launch wrappers (`agent_launch.go`) install a fake `tmux` shim (`tmux_compat.go`) that translates tmux subcommands into cmux JSON-RPC, and seed `CMUX_WORKSPACE_ID`/`CMUX_SURFACE_ID`/`CMUX_SOCKET_PATH` from `system.identify` before `syscall.Exec`-ing the real agent. Full implementation status, acceptance tests, and open TODOs: [remote-daemon-spec.md](remote-daemon-spec.md).

---

## 5. "Where do I find X?" Navigation Index

Rows cite the source file(s); the **See also** column links the dedicated `docs/` spec that owns the authoritative detail for that topic.

| Question | File / area | See also |
|---|---|---|
| The app entry point / `@main` | `Sources/cmuxApp.swift` (`CmuxMain`) | — |
| App lifecycle, window registry, keyboard swizzles | `Sources/AppDelegate.swift` (+ `Sources/AppDelegate+*.swift`, `Sources/App/AppDelegate+*.swift`) | — |
| Panel type enum + SwiftUI dispatch | `Sources/Panels/Panel.swift`, `Sources/Panels/PanelContentView.swift` | — |
| The Unix-socket RPC dispatcher | `Packages/macOS/CmuxControlSocket/.../ControlCommandCoordinator.swift`; in-app host `Sources/TerminalController.swift` + `Sources/TerminalController+Control*.swift` | [cli-contract.md](cli-contract.md) |
| CLI subcommand dispatch (150+ cases) | `CLI/cmux.swift` (`CMUXCLI.run()`); socket path: `CLI/CLISocketPathResolver.swift` | [cli-contract.md](cli-contract.md) |
| How to add an AI agent integration / hooks | `CLI/CMUXCLI+AgentHookDefinitions.swift` (`agentDefs`); classifier `CLI/FeedEventClassifier.swift` | [agent-hooks.md](agent-hooks.md) |
| The Ghostty terminal surface model | `Packages/macOS/CmuxTerminal/.../TerminalSurface.swift` (+ `+Input`, `+Renderer`, `+RuntimeLifecycle`) | [ghostty-fork.md](ghostty-fork.md) |
| Ghostty config parsing | `Packages/macOS/CmuxTerminalCore/GhosttyConfig.swift` | — |
| Workspace / group lifecycle (decomposed) | `Packages/macOS/CmuxWorkspaces/WorkspacesModel.swift`, `WorkspaceGroupCoordinator.swift`; in-app god-class `Sources/Workspace.swift` | [workspace-groups.md](workspace-groups.md), [workspace-auto-naming.md](workspace-auto-naming.md) |
| Sidebar git branch / PR badges | `Packages/macOS/CmuxSidebarGit/SidebarGitMetadataService.swift`, `PullRequestPollService.swift`; git reader `Packages/macOS/CmuxGit` | — |
| Notification ring / OSC routing | `Sources/TerminalNotificationStore.swift`, `Sources/TerminalNotificationPolicy.swift`, `Sources/TerminalNotificationQueue.swift` | [notifications.md](notifications.md) |
| Phone push mirroring | `Sources/Cloud/PhonePushClient.swift` | — |
| Agent session subprocess + fan-out | `Sources/Panels/AgentSessionProcessStore.swift` (`AgentSessionEventFanOut`) | [agent-hooks.md](agent-hooks.md) |
| Agent session webview bridge | `Sources/Panels/AgentSessionWebRendererCoordinator.swift` | — |
| Kanban engine (board state, WIP, dispatch) | `Packages/macOS/CmuxKanbanCore/KanbanEngine.swift`, `KanbanBoard.swift`; backends `Sources/Kanban/CmuxNativeBackend.swift`, `CmuxLiveBackend.swift` | — |
| Webview surface dispatch (Kanban/agent/diff) | `webviews/src/main.tsx`, `webviews/src/router.tsx`, `webviews/src/shared/nativeBridge.ts` | — |
| Live agent chat domain model / transcript parsers | `Packages/Shared/CmuxAgentChat/Store/ChatConversationStore.swift`, `Parsing/ClaudeTranscriptParser.swift`, `CodexTranscriptParser.swift` | — |
| Remote SSH session orchestration | `Packages/macOS/CmuxRemoteSession/RemoteSessionCoordinator.swift` (+ extensions) | [remote-daemon-spec.md](remote-daemon-spec.md) |
| Remote daemon (Go) RPC server | `daemon/remote/cmd/cmuxd-remote/main.go` | [remote-daemon-spec.md](remote-daemon-spec.md) |
| Settings storage (typed, JSONC, secrets) | `Packages/macOS/CmuxSettings/*` (`JSONConfigStore`, `UserDefaultsSettingsStore`, `SecretFileStore`); state dir `CmuxStateDirectory.swift` | [configuration.md](configuration.md), [vault.md](vault.md) |
| Keyboard shortcut actions / recorder | `Sources/KeyboardShortcutSettings.swift`, `Packages/macOS/CmuxSettings/ShortcutAction.swift`, `Sources/KeyboardShortcutRecorder.swift` | — |
| Session persistence / restore | `Sources/SessionPersistence.swift`, `Sources/RestorableAgentSession.swift`, `Packages/macOS/CmuxWorkspaces/SessionSnapshotRepository.swift` | — |
| Window chrome / glass / titlebar | `Packages/macOS/CmuxAppKitSupportUI/*`; portal `Sources/TerminalWindowPortal.swift`, `Sources/BrowserWindowPortal.swift` | — |
| Cloud VM control plane (web) | `web/services/vms/workflows.ts`, `web/services/vms/drivers/*` | [cloud-vm-backend-rollout-todo.md](cloud-vm-backend-rollout-todo.md) |
| iOS companion god-store | `Packages/iOS/CmuxMobileShell/MobileShellComposite.swift`; iOS Ghostty surface `Packages/iOS/CmuxMobileTerminal/GhosttySurfaceView.swift` | [ios-swift-mobile-plan.md](ios-swift-mobile-plan.md) |
| Presence worker (Cloudflare DO) | `workers/presence/src/do.ts` (`TeamPresence`), `core.ts` | [presence-service.md](presence-service.md) |
| Dev build script (tagged) | `scripts/reload.sh`; tagged CLI dogfood `scripts/cmux-debug-cli.sh` | — |
| Release pipeline / version bump | `scripts/build-sign-upload.sh`, `scripts/sign-cmux-bundle.sh`, `scripts/bump-version.sh`, `scripts/release-pretag-guard.sh` | — |
| Command palette fuzzy search | `Packages/macOS/CmuxCommandPalette/*`; Rust FFI `Native/CommandPaletteNucleoFFI/src/lib.rs` | — |

---

## 6. Top Gotchas & Invariants (every contributor MUST know)

**Build & dev workflow**
- **Always build with a tag.** `./scripts/reload.sh --tag <slug>`. Never run bare `xcodebuild` or open an untagged `cmux DEV.app` — untagged builds share the default debug socket and bundle ID, conflicting with other agents and stealing focus. For CLI/socket dogfood use `CMUX_TAG=<tag> scripts/cmux-debug-cli.sh` (never `/tmp/cmux-cli`). If the Zig build fails for the app target (newer macOS/zig combinations have broken the Ghostty CLI-helper link), set `CMUX_SKIP_ZIG_BUILD=1` for app-target builds (see `scripts/reload.sh` for the skip logic).
- **Webview assets: `./scripts/build-webviews-app.sh`, never bare `bun run build`.** Vite's `emptyOutDir: true` deletes the HTML shells (`agent-session.html`, `kanban.html`) that the wrapper writes post-Vite. Verify byte-for-byte with `--check` (a CI guard).

**Typing-latency paths** (read before touching)
- `WindowTerminalHostView.hitTest()` (`Sources/TerminalWindowPortal.swift`) — all routing gated to `isPointerEvent`; no work outside the guard.
- `TabItemView` (`Sources/ContentView.swift`) — keep `Equatable` + `.equatable()`; don't add `@EnvironmentObject`/`@ObservedObject`/`@Binding` without updating `==`; don't read stores in the body.
- `TerminalSurface.forceRefresh()` (`Sources/GhosttyTerminalView.swift`) — no allocations/IO/formatting; called every keystroke.
- Never add an app-level display link or manual `ghostty_surface_draw` loop.
- **Terminal find layering:** `SurfaceSearchOverlay` must be mounted from `GhosttySurfaceScrollView` in `Sources/GhosttyTerminalView.swift` (AppKit portal layer), never from a SwiftUI panel container.

**SwiftUI architecture invariants**
- **Snapshot-boundary rule** (issues #2586, #4529): no view below a `LazyVStack`/`LazyHStack`/`List`/`ForEach` boundary may hold a reference to any `@Observable`/`ObservableObject` store (no `@ObservedObject`, `@EnvironmentObject`, `@StateObject`, `@Bindable`, or even a plain `let store`). Rows get **immutable value snapshots + closure action bundles** only. Reference pattern: `IndexSectionActions`/`SectionGapActions` in `Sources/SessionIndexView.swift`. Violation = 100% CPU spin thrashing `LazyLayoutViewCache`.
- **No state mutation inside view-body computations.** A function called from `body` must not write `@Published`/`@Observable` state, schedule `Task { @MainActor in store.x = … }`, or `DispatchQueue.main.async` a store write. State-changing work belongs in `reload()` completions, `didSet`, or property observers.
- New cmux-owned code uses `@Observable` + async/await, **not** Combine/`@Published`/`ObservableObject`. No `NSLock`/`DispatchSemaphore`-as-mutex, no `DispatchQueue.main.sync` on socket/terminal/render paths, no blocking sleeps for settling/racing.

**Testing & project integrity**
- **pbxproj test wiring.** Every `.swift` file in `cmuxTests/` (or `cmuxUITests/`) needs a `PBXFileReference` + `PBXSourcesBuildPhase` entry in `cmux.xcodeproj/project.pbxproj`, or Xcode silently ignores it (CI reports "Executed 0 tests"). CI guard: `./scripts/lint-pbxproj-test-wiring.sh`. After any pbxproj edit, run `scripts/normalize-pbxproj.py` + `scripts/check-pbxproj.sh` (objectVersion must be 60 for Xcode 26).
- **Two-commit red/green regression policy.** Commit 1 = failing test only (CI red); Commit 2 = the fix (CI green). New unit tests use Swift Testing (`import Testing`, `@Test`, `#expect`); UI tests stay on XCTest/XCUIApplication.
- `reload.sh` does **not** compile the test target — run the `cmux-unit` scheme (`./scripts/test-unit.sh`) before pushing package/refactor changes.

**Localization**
- All user-facing strings localized via `String(localized: "key", defaultValue: "English")`; keys in `Resources/Localizable.xcstrings` (English + Japanese), web in `web/messages/{en,ja}.json`. `defaultValue` is **not** a completed localization. A **localization audit is required for every UI-touching change** and must be stated in the handoff.

**Shared-behavior & multi-entrypoint**
- When a behavior is reachable from multiple entrypoints (shortcut, palette, context menu, CLI, settings, debug menu), implement **one** shared action/model path; don't duplicate logic per surface. New keyboard shortcuts must be added to `KeyboardShortcutSettings`, editable in Settings, supported in `~/.config/cmux/cmux.json`, and documented.

**Submodule & dependency hygiene**
- **Ghostty: push-before-pointer.** When changing the `ghostty/` submodule, push the submodule commit to its remote `main` (manaflow fork) **before** committing the updated pointer in the parent repo. Never commit on a detached HEAD. Verify: `cd ghostty && git merge-base --is-ancestor HEAD origin/main`. GhosttyKit/cmuxd are always built `-Doptimize=ReleaseFast`.
- **Package.resolved policy.** Do not ignore cmux-owned `Package.resolved` files; a package-local lockfile is the source of truth for its standalone resolution. CI: `python3 scripts/check-package-resolved-policy.py`.
- **Workspace package-group mirroring.** Packages live under exactly one of `Packages/{Shared,iOS,macOS}/`; `cmux.xcworkspace/contents.xcworkspacedata` mirrors that folder shape. Move via `git mv` then `check-workspace-package-groups.py --write`. CI: `--check`.

**Misc landmines**
- WKWebView panels loading code-split ES modules over `file://` **must** set `allowFileAccessFromFileURLs` + `allowUniversalAccessFromFileURLs` SPI keys, or they blank silently.
- `CmuxStateDirectory` = `~/.local/state/cmux`, **not** `~/Library/Application Support` (avoids macOS Sequoia TCC prompts for the separately-signed CLI; issue #5146).
- `CMUX_SOCKET` is intentionally set to `""` in the surface env so child shells don't inherit the parent cmux socket. `surface_id` must stay stable across move/reorder.
- macOS API semantics drift silently between major versions (e.g. `URL` normalization on macOS 26). Test on the **reporter's** macOS before declaring a repro disproven; AWS M4 Pro builders are on macOS 15.7.4.
- Release: bump minor by default; run `scripts/release-pretag-guard.sh` before tagging (CURRENT_PROJECT_VERSION must increase monotonically for Sparkle); `sign-cmux-bundle.sh` must **not** `--deep`-sign the main bundle (amfi errno 163 on notarized macOS 26).

---

## 7. Glossary

| Term | Meaning |
|---|---|
| **Window** | A native `NSWindow` (`CmuxMainWindow`). CLI ref `window:N`. Holds a `MainWindowContext` + `TabManager`. |
| **Workspace** | tmux-session-like container; Cmd+1–8. CLI ref `workspace:N`. Has name/desc/color/cwd/status/progress/branch/PR. |
| **Workspace group** | Collapsible, optionally-pinned sidebar grouping; the **anchor** workspace's header row represents it. Closing the anchor dissolves the group. |
| **Pane** | A node in the Bonsplit split tree; holds surfaces as horizontal tabs. CLI ref `pane:N`. |
| **Surface** | One tab = one Ghostty terminal (or non-terminal panel). CLI ref `surface:N`; `surface_id` is the stable automation handle. |
| **Panel** | Content type of a surface (`PanelType`: terminal/browser/markdown/filePreview/rightSidebarTool/agentSession/project/extensionBrowser/kanban). |
| **SurfaceKind** | Frozen wire/persistence identifier mirroring panel types for Bonsplit serialization (`CmuxWorkspaces`). |
| **libghostty / GhosttyKit** | The Ghostty terminal engine, vendored as the `ghostty/` submodule, consumed as `GhosttyKit.xcframework` (built `ReleaseFast`). GPU-accelerated. |
| **Bonsplit** | Vendored split-tree / tab-bar engine (`vendor/bonsplit`) used for pane layout. |
| **cmuxd** | Zig sidecar daemon for on-device process/resource monitoring over its own socket. |
| **cmuxd-remote** | Go remote daemon for `cmux ssh`: JSON-RPC over SSH stdio / WebSocket for PTY, proxy streams, CLI relay, tmux shim. |
| **CmuxControlSocket** | SPM package owning the Unix-socket listener, transport, and RPC dispatch (`ControlCommandCoordinator`). |
| **v1 / v2 protocol** | v1 = line-oriented text (`command args\n` → response). v2 = JSON-RPC (`{id,method,params}` → `{id,result/error}`). |
| **ref / `kind:N`** | Human-readable global stable handle (`workspace:2`, `surface:4`); normalized to UUID before socket use. Never reused until daemon restart. |
| **TerminalController** | In-app singleton hosting the socket control plane; being decomposed into `ControlCommandCoordinator` + per-domain witness extensions. |
| **TerminalSurface** | The Swift model owning one `ghostty_surface_t` lifecycle (one terminal tab/pane). |
| **GhosttySurfaceCallbackContext** | Retained userdata pointer passed to `ghostty_surface_new`; recovered in libghostty C callbacks. |
| **MANUAL I/O mode** | Ghostty surface mode where cmux drives output via `ghostty_surface_process_output` (used for remote/mirror surfaces). |
| **OSC 9/99/777** | Terminal escape sequences for notifications; light the notification ring and sidebar badge. |
| **Notification ring** | The ring on a pane/sidebar tab when an agent posts a notification (OSC or `cmux notify`). |
| **SidebarUnreadModel** | Coalesced projection the sidebar observes instead of the full `TerminalNotificationStore` (prevents #2586 CPU spin). |
| **Feed** | Inline AI-decision approval surface (PermissionRequest/ExitPlanMode/AskUserQuestion). The socket worker parks on a `DispatchSemaphore` awaiting the user; the caller-supplied `wait_timeout_seconds` is hard-capped at 120s (values above are rejected as invalid_params). |
| **AgentSessionProcessStore** | Owns an agent subprocess lifecycle; fans events to a primary sink + keyed observers via `AgentSessionEventFanOut`. |
| **CmuxLiveBackend / CmuxNativeBackend** | Kanban `DispatchBackend`s — live observes a shared visible-surface store (never spawns); native runs a headless per-card agent. |
| **KanbanEngine** | Actor; single serialized source of truth for board state, WIP limits, and backend dispatch. |
| **WIP slot / occupiesWipSlot** | A Kanban column counting against `wipLimit` (`.building` + `.testing`; default limit 2). |
| **ChatConversationStore** | `@MainActor @Observable` live agent-session store (reconnect, pagination, send queue) in shared `CmuxAgentChat`. |
| **ChatEventSource** | Transport seam between `ChatConversationStore` and any backend (Mac surface, iOS RPC, fixtures). |
| **Snapshot boundary** | The rule that no view below a lazy-list `ForEach` may hold a store reference — only immutable value snapshots + closures. |
| **CMUXMobileShellStore** | Typealias for `MobileShellComposite`, the iOS companion god-store every view depends on. |
| **effectiveGrid / letterbox** | iOS terminal mirror: daemon-authoritative min cols×rows across devices; the surface pins its render and letterboxes the rest. |
| **CmuxControlSocket vs CmuxRemoteSession** | Local Unix-socket control plane vs SSH remote workspace orchestration. |
| **DispatchBackend** | Protocol `KanbanEngine` calls to run a card; backends report raw lifecycle facts, the engine owns column-transition policy. |
| **CmuxStateDirectory** | `~/.local/state/cmux` — canonical runtime state dir (socket, markers); avoids TCC prompts for the separately-signed CLI. |
| **CMUX_TAG** | Env var isolating a tagged debug build's socket (`/tmp/cmux-debug-<tag>.sock`), bundle ID, and DerivedData path. |
| **reload.sh** | Primary dev build script — builds a tagged Debug app, kills same-tag instances, prints the app path. Does **not** compile tests. |
| **tmux shim** | Fake `tmux` binary on PATH translating tmux subcommands into cmux v2 socket/RPC calls (for agents that drive tmux). |
| **TeamPresence DO** | Cloudflare Durable Object (one per team) tracking device presence + local-first device-list sync. |
| **TerminalMutationBus** | Thread-safe batched (≤16/drain) main-actor mutation bus serializing notification delivery. |
| **Composition root** | The macOS app target (`cmuxApp` + `AppDelegate`) — the single place concrete Services/Repositories are constructed and injected. |
