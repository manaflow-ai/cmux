# Windows Port Feasibility

Tracking issue: https://github.com/manaflow-ai/cmux/issues/3794

## Status

cmux does not currently have a Windows build. A Windows version is feasible, but
not as a direct compile target for the current app. The current product is a
native macOS host around shared concepts: workspaces, surfaces, terminal
automation, browser automation, agent hooks, and remote sessions.

The practical path is to extract and stabilize those shared contracts, then
build a separate Windows host that implements them with Windows-native UI,
terminal, browser, notification, and packaging primitives.

## Current Platform Boundary

The current app is intentionally macOS-native:

1. The primary product artifact is `cmux-macos.dmg`, plus Homebrew cask
   installation and Sparkle updates.
2. `GhosttyTabs.xcodeproj` builds macOS targets with
   `MACOSX_DEPLOYMENT_TARGET = 14.0` and `SDKROOT = macosx`.
3. The app entry point in `Sources/cmuxApp.swift` imports AppKit, SwiftUI, and
   Darwin, and uses `NSApplicationDelegateAdaptor`.
4. Terminal hosting in `Sources/GhosttyTerminalView.swift` is deeply tied to
   `NSView`, `NSWindow`, AppKit responder routing, backing-scale conversion,
   drag and drop, IME handling, and `NSWorkspace`.
5. Browser panes use WebKit and `WKWebView`, including macOS-specific process,
   focus, proxy, and popup behavior.
6. The CLI in `CLI/cmux.swift` uses Darwin sockets, POSIX file descriptors,
   process groups, signals, and macOS bundle discovery.
7. The Ghostty integration is consumed as `GhosttyKit.xcframework`, and the fork
   notes in `docs/ghostty-fork.md` currently focus on macOS and iOS framework
   behavior.

Those dependencies mean a Windows version should not start as an attempt to make
the existing Swift/AppKit app compile on Windows.

## Reusable Pieces

These parts are candidates for reuse or protocol-level compatibility:

1. The public CLI and socket command model documented in `docs/cli-contract.md`.
2. The browser automation command shape documented in
   `docs/agent-browser-port-spec.md`.
3. Agent hook definitions and environment policies under `CLI/` and
   `Packages/CMUXAgentLaunch/`.
4. The Go remote daemon in `daemon/remote`, which already has a cleaner
   platform boundary than the macOS host.
5. The web docs, changelog renderer, and backend services under `web/`.

## Recommended Architecture

Build Windows as a sibling native host around a stable cmux protocol boundary.

1. Freeze the v2 JSON-RPC/socket contract for workspaces, surfaces, browser
   panes, notifications, focus, and layout mutations.
2. Separate macOS host concerns from portable domain concepts. The first useful
   split is protocol-facing state transitions versus AppKit/Ghostty/WebKit
   adapters.
3. Implement a Windows host with Windows-native primitives:
   - WinUI, WPF, or direct Win32 for shell UI and window management.
   - ConPTY for local terminal sessions.
   - WebView2 for browser panes and automation.
   - Windows notifications for agent attention events.
   - Named pipes or loopback TCP for the control endpoint.
   - MSIX, winget, or an installer/update path for distribution.
4. Port the CLI transport layer so commands can talk to either Unix sockets on
   macOS or named pipes/TCP on Windows.
5. Add Windows release artifacts only after the host can open a workspace, run a
   local terminal, show an attention notification, and execute a small browser
   automation flow.

## Portability Boundary

The portable product surface should be the protocol, not the current macOS
controller implementation.

1. Treat the v2 JSON-RPC method set as the cross-platform source of truth. The
   canonical references are `docs/v2-api-migration.md`, `docs/cli-contract.md`,
   and `docs/agent-browser-port-spec.md`.
2. Treat `Sources/TerminalController.swift` as the current macOS server for that
   contract, not as code to port wholesale. It currently owns Unix-socket
   transport, request dispatch, security checks, AppKit focus policy, and calls
   into workspace, terminal, browser, notification, Feed, and VM adapters.
3. Before writing a Windows UI, extract protocol fixtures and compatibility
   tests that can run against any endpoint. The same tests should be able to
   target the macOS Unix socket, a Windows named-pipe or TCP endpoint, and a
   narrow in-process harness.
4. Keep host adapters behind explicit boundaries:
   - macOS: AppKit/SwiftUI, `NSView` terminal hosting, `WKWebView`,
     `NSUserNotification`/UserNotifications, Unix sockets, Sparkle, DMG.
   - Windows: WinUI/WPF/Win32, ConPTY, WebView2, Windows notifications, named
     pipes or loopback TCP, MSIX/winget/installer.
5. Keep shared state transitions value-oriented and protocol-shaped. Do not let
   Windows and macOS grow separate command semantics for workspace selection,
   surface movement, focus intent, browser automation, notifications, or Feed
   decisions.

## macOS Extraction Rules

Any preparatory Swift work should make the bad port shape unrepresentable
instead of adding compatibility branches throughout the app.

1. Keep one `@MainActor` owner for UI lifecycle facts. Cross-platform protocol
   work should call that owner through a small action surface instead of
   duplicating focus, selection, or window state.
2. Prefer `async`/`await` boundaries over new `DispatchQueue` or semaphore glue
   when lifting protocol operations away from AppKit. Existing socket hot paths
   can remain until they are deliberately migrated.
3. Use immutable request/response value types and explicit phase enums for new
   portable seams. Avoid adding platform booleans that let Windows and macOS
   silently diverge.
4. Keep timing repairs out of the portability layer. No sleeps, retry loops, or
   notification waits should be required for the shared contract to be correct.
5. Rows, tabs, and other SwiftUI list subtrees should continue to receive value
   snapshots plus action closures only. Portability work must not reintroduce
   store references below those snapshot boundaries.

## Minimum Viable Windows Definition

A Windows build should not be called supported until it satisfies the same
agent-facing contract that scripts and hooks depend on today.

1. `cmux ping`, `cmux capabilities`, `cmux identify`, workspace list/create,
   surface list/create/focus, and terminal send-key/send-text work through the
   Windows endpoint.
2. A local ConPTY terminal pane receives the same `CMUX_WORKSPACE_ID`,
   `CMUX_SURFACE_ID`, and socket/endpoint environment semantics as macOS panes.
3. Browser automation covers the P0 command subset from
   `docs/agent-browser-port-spec.md` through WebView2 with documented
   `not_supported` errors for WebView2 gaps.
4. Notifications and Feed events use the same v2 payloads and produce native
   Windows attention behavior.
5. CLI transport selection is automatic or explicit, and scripts do not need to
   know whether the target host is using a Unix socket, named pipe, or TCP.
6. CI builds signed or unsigned Windows artifacts and runs the transport-agnostic
   protocol compatibility suite against the Windows host or harness.

## First Milestones

1. Create a platform inventory that classifies source areas as shared protocol,
   macOS host, remote daemon, web, or test-only.
2. Move protocol fixtures and command contract tests behind a transport-agnostic
   harness so future Windows code can prove compatibility without launching the
   macOS app.
3. Teach `daemon/remote` to build and test Windows artifacts if product scope
   includes controlling remote Windows machines.
4. Prototype the Windows control endpoint and CLI transport before building the
   full UI.
5. Prototype one terminal pane and one browser pane in a Windows host.

## Open Questions

1. Should the first Windows deliverable be a full desktop app, a CLI/controller
   for remote or cloud workspaces, or a smaller companion for agent hooks?
2. Should the Windows terminal renderer use ConPTY plus a Windows-native
   frontend first, or wait for a production-ready Ghostty renderer path on
   Windows?
3. Should browser automation compatibility prioritize WebView2 parity with the
   current `WKWebView` API, or a narrower command subset first?
4. What update and signing channel should be used: MSIX, winget, a standalone
   installer, or a managed enterprise distribution path?

## Non-Goals For The First Pass

1. Do not promise that the current Swift/AppKit app can be compiled for Windows.
2. Do not introduce Electron or Tauri solely to get a quick shell unless product
   direction explicitly accepts that tradeoff.
3. Do not fork core behavior into two products. Shared behavior should remain
   protocol-driven so macOS and Windows hosts stay compatible.
