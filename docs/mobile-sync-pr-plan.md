# Mobile Sync PR Plan

Goal: ship iOS and iPadOS support as a sequence of production-ready PRs. The iOS app mirrors and controls real workspaces hosted by the open Mac app. The implementation stays in-process Swift and uses Tailscale as the only production network path.

## Invariants

- The Mac app owns all real workspace, terminal, PTY, and Ghostty state.
- iOS never creates a standalone PTY. New workspace and new terminal actions call the Mac app and create normal cmux workspaces and terminals.
- The Mac app must be open. We do not support waking or daemon-hosting sessions while cmux is closed.
- `cmux ios` and the Settings toggle are the opt-in entrypoints. When disabled, no mobile listener accepts connections.
- Production pairing only advertises Tailscale addresses. LAN addresses are not advertised or accepted.
- Simulator testing uses an explicit test-only loopback transport. That path must be disabled in release builds and guarded by launch environment or debug-only flags.
- Terminal contents come from Ghostty state, including true scrollback. VT replay is not an acceptable source for mobile terminal state.
- Key input flows iOS -> Mac -> PTY -> Ghostty -> iOS. iOS renders server state, not an independent terminal emulator state.
- Resize follows tmux semantics: every active attachment votes its size, and the smallest columns and rows win. Votes are removed immediately when an attachment disconnects or leaves a terminal.
- macOS shows the remotely constrained active terminal area while iOS is attached.

## Phase 1: Tailscale-Only Opt-In Control Plane

Build the production gate before any live terminal control.

Scope:
- Keep `mobile_sync.status`, `mobile_sync.enable`, and `mobile_sync.disable` as the shared action path for CLI and Settings.
- Make `cmux ios` enable the feature, print listener state, and render a QR code only when a Tailscale address is available.
- Refuse production listener start when no Tailscale address exists.
- Add copy that clearly says the Mac app must be open and the iOS device must be on the same tailnet.
- Persist the enabled flag, but never listen until cmux is open and the setting is enabled.

Self verification:
- Unit: `MobileSyncModelTests` covers Tailscale detection, no-LAN selection, enabled-without-Tailscale state, and persisted enable/disable.
- CLI integration: `CLIMobileSyncTests` proves `cmux ios`, `cmux ios status`, and `cmux ios off` call the v2 socket commands and render production-safe status.
- UI: `AutomationSocketUITests/testMobileSyncSettingsTogglePersists` proves the Settings toggle persists and uses the same setting.
- Manual probe: run a tagged macOS build with and without a Tailscale interface, then verify `cmux ios` never advertises `192.168.*`, `10.*`, or `172.16/12` addresses.
- Merge gate: macOS build, unit tests in CI, and relevant hosted XCUITest class green.

## Phase 2: Pairing QR and Transport Skeleton

Add the first real connection path without terminal streaming.

Scope:
- `cmux ios` shows a QR payload with Mac app identity, Tailscale address, port, protocol version, and a listener nonce for correlation only.
- No long-lived auth token. Trust is delegated to Tailscale identity and network policy.
- iOS can scan or enter the QR payload and connect to the open Mac app.
- The Mac listener accepts only Tailscale remote addresses in production.
- Add a debug-only simulator loopback pairing path.
- The first protocol can be simple JSON over WebSocket or newline-delimited JSON. Pick the one that minimizes Swift complexity and makes reconnection deterministic.

Self verification:
- Unit: pairing payload encode/decode rejects non-Tailscale production hosts and accepts debug loopback only when the test flag is enabled.
- CLI integration: `cmux ios --json` returns the same payload rendered in the QR code.
- Transport integration: a headless client test connects, receives `hello`, sends `ping`, and observes `pong` plus server capability fields.
- iOS simulator: hosted `test-ios.yml` runs iPhone and iPad pairing tests using the debug loopback payload.
- Manual probe: connect from another tailnet device and confirm server logs include remote Tailscale address and app-open lifecycle.

## Phase 3: Workspace and Terminal Inventory

Make iOS show real Mac-hosted state before allowing mutation.

Scope:
- Add protocol messages for workspace list, selected workspace, terminal list, focused terminal, and titles.
- Send initial snapshot on connect and incremental updates after Mac state changes.
- iOS replaces preview host data with remote-backed state.
- Preserve sign-in gate before pairing.

Self verification:
- Unit: snapshot models are Codable, versioned, and tolerate unknown future fields.
- Mac integration: a socket test creates a workspace and terminal through existing Mac APIs, subscribes, and asserts the remote inventory updates.
- iOS package tests: store reducers apply initial and incremental inventory without duplicating workspaces or terminals.
- iOS simulator: existing workspace list and terminal dropdown UI tests run against debug loopback remote data on iPhone and iPad.
- Manual probe: create, rename, focus, and close terminals on Mac, then confirm iOS updates without relaunch.

## Phase 4: Real Workspace and Terminal Creation From iOS

Turn iOS controls into real cmux actions.

Scope:
- iOS `New Workspace` calls the Mac app and creates a normal workspace with a real terminal.
- iOS `New Terminal` calls the Mac app and appends a real terminal to the active workspace.
- Terminal dropdown selects among real terminals and focus changes are mirrored back to Mac.
- Reuse existing Mac workspace and terminal creation paths so persistence, shell setup, and cwd behavior stay normal.

Self verification:
- Unit: command validation rejects missing workspace IDs, stale terminal IDs, and malformed client IDs.
- Mac integration: socket tests call create workspace, create terminal, focus terminal, and assert the resulting `TabManager`/workspace model state.
- iOS simulator: UI test taps `New Workspace`, opens the terminal dropdown, adds a terminal, selects it, and verifies the remote inventory update.
- Manual probe: create from iPad simulator, then inspect the Mac UI and session snapshot to confirm the workspace is not a preview object.
- Regression check: relaunch Mac after creation and verify normal session persistence handles the new workspace.

## Phase 5: Ghostty Snapshot Export

Ship a verifiable terminal-content artifact before live streaming.

Scope:
- Add a Mac-side exporter that builds the shared `MobileTerminalGhosttySnapshot` from live Ghostty state.
- Use `ghostty_surface_read_text` and Ghostty surface size APIs for viewport and scrollback.
- Remove mobile/session snapshot dependency on VT screen-file export for scrollback.
- Include active screen metadata when Ghostty exposes it. If the current C API cannot expose alt-screen state yet, add a small Ghostty API in the fork and commit the submodule update in the same phase.
- Add a v2/debug command that returns a snapshot for a given terminal so the artifact is inspectable before iOS rendering depends on it.

Self verification:
- Unit: row splitting, truncation, encoding, and schema validation cover primary screen, scrollback, and alternate screen snapshots.
- Mac integration: launch a terminal, print sentinel scrollback lines, run a TUI-style alternate-screen fixture, request the snapshot command, and assert the expected visible and scrollback rows.
- TUI behavior: while alt screen is active, iOS snapshot shows the alternate screen. After `Ctrl-C` exits alt mode, the next snapshot shows the restored primary screen plus preserved scrollback.
- Manual probe: compare `cmux read-screen --scrollback` and the mobile snapshot command for a real terminal with known sentinel lines.
- Performance: capture large scrollback and assert bounded latency and payload size with truncation metrics.

## Phase 6: Live Terminal Streaming and Input

Make iOS control a terminal through the Mac app.

Scope:
- iOS sends key events, paste, resize votes, focus, and disconnect.
- Mac applies input to the real terminal and streams Ghostty updates back.
- Stream initial snapshot, then incremental updates or coalesced full snapshots depending on what is simpler and fast enough.
- Add connection IDs and monotonically increasing sequence numbers so reconnect can resume from the latest committed server state.
- Keep the protocol deterministic enough for test clients to replay.

Self verification:
- Unit: input encoder covers printable text, return, tab, escape, arrows, modifiers, paste, and `Ctrl-C`.
- Mac integration: a fake mobile client sends keys to `cat` or a shell prompt and waits for streamed output containing the typed sentinel.
- iOS simulator: type into the terminal view and verify the rendered output came back from Mac.
- Network resilience: test client disconnects mid-stream, reconnects with last seen sequence, and receives a coherent current snapshot without duplicate terminal creation.
- Manual probe: use a real iPad or iPhone over Tailscale to type, paste, interrupt with `Ctrl-C`, and switch terminals.

## Phase 7: Resize Votes and Active-Area Overlay

Make remote constraints visible and reversible.

Scope:
- Every iOS terminal attachment reports its grid size.
- Mac applies smallest-active columns and rows per terminal.
- When the active mobile attachment exits, disconnects, backgrounds, or switches terminals, its vote is removed immediately.
- macOS draws the active-area outline over the terminal when a remote attachment constrains the local terminal.

Self verification:
- Unit: `TerminalSizeCoordinator` covers per-axis smallest-wins, stale vote removal, terminal switch removal, and multi-device votes.
- UI: `MobileSizeOverlayUITests/testLaunchHookShowsActiveAreaOverlay` proves the overlay appears with the expected geometry.
- Integration: a mobile client changes size, Mac receives resize, Ghostty reports the constrained grid, then disconnect restores local size.
- Manual probe: connect iPhone and iPad with different sizes, confirm smallest size wins, then close one device and see the Mac terminal resize back promptly.

## Phase 8: Production Hardening

Make the feature supportable before broad dogfood.

Scope:
- Add protocol versioning, structured errors, reconnect backoff, connection lifecycle logs, and metrics.
- Add UI states for Tailscale unavailable, Mac unreachable, cmux closed, protocol mismatch, and reconnecting.
- Add payload size limits and input rate limits.
- Confirm settings, CLI, QR copy, and iOS screens use localized strings.
- Document tailnet requirement and simulator testing path.

Self verification:
- Unit: malformed payloads, oversized frames, stale sequence numbers, and protocol mismatch return typed errors.
- Hosted iOS: iPhone and iPad run sign-in, pairing, workspace, terminal dropdown, creation, and input smoke tests.
- Hosted macOS XCUITest: Settings opt-in, overlay, and socket lifecycle tests pass.
- Manual tailnet matrix: same Mac plus iPhone, iPad, and simulator; Tailscale on/off; cmux closed/open; Mac feature disabled/enabled.
- Release checklist: no listener when disabled, no LAN advertisement, no dev secret, no token storage, no unlocalized UI strings, no local-only test gates in release.

## First Verifiable PR

The best next PR is Phase 5, Ghostty snapshot export. It creates a concrete artifact that can be inspected from CLI/socket tests before live iOS streaming exists, and it directly resolves the highest-risk terminal requirement: true Ghostty scrollback and TUI/alt-screen behavior.

Definition of done:
- A command returns a mobile terminal snapshot for the active real terminal.
- The snapshot is built from Ghostty state, not VT replay.
- Tests prove scrollback, visible viewport, and TUI alt-screen behavior.
- The iOS preview can consume the same snapshot schema.
- Tagged macOS and iOS reloads succeed, with hosted CI green before merge.
