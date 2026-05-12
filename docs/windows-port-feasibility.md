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
