# iOS Sidebar Terminal Living Spec

Last updated: 2026-03-15
Owners: iOS app team

## Goal
Build a stack-auth-gated iOS main screen that mirrors the cmux desktop sidebar mental model:
- left list of workspaces/sessions (iMessage-like list affordance),
- right/detail pane showing the terminal for the selected session,
- terminals powered by libghostty.

## Non-Goals (current phase)
- Full parity with desktop tab/workspace protocol behavior.
- Advanced terminal actions (split tree management, command palette, etc.).

## Architecture (current)
1. Auth gate:
   - Keep existing Stack Auth sign-in flow as the only default entry into the app.
2. Main surface:
   - `TerminalSidebarRootView` is the authenticated root.
   - The home view is an iMessage-like inbox with pinned servers and persisted workspaces.
3. Terminal runtime:
   - `GhosttyRuntime` wraps `ghostty_init`, `ghostty_app_new`, and wakeup->tick routing.
   - Clipboard and open-url are minimally wired for iOS.
4. Terminal view:
   - `GhosttySurfaceView` is a `UIView` with `CAMetalLayer` backing.
   - Surface creation uses `GHOSTTY_PLATFORM_IOS`, manual I/O, and dynamic grid-size sync.
5. Session and persistence:
   - `TerminalSidebarStore` owns saved hosts, persisted workspaces, selection, and reconnect.
   - `TerminalDirectDaemonTransport` is now the preferred path for discovered `cmuxd-remote` hosts.
   - Direct daemon sessions use short-lived tickets, connect over TLS, and fall back to SSH only for reachability-class failures when host policy allows it.
   - Malformed or unparseable daemon-ticket responses now fail closed instead of silently downgrading the selected workspace to SSH.
   - Manual hosts that opt into `cmuxd-remote` but do not have team-scoped ticketing now go straight to the SSH bootstrap daemon carrier when SSH credentials exist, instead of showing a spurious direct-fallback notice first.
   - Manual `cmuxd-remote` hosts without team-scoped ticketing are only considered configured when the selected SSH auth method has a saved credential, because SSH bootstrap is their only viable daemon carrier.
   - Custom-host editing now exposes transport choice, SSH fallback policy, and direct TLS pins for manual `cmuxd-remote` setups.
   - Discovery refreshes now preserve the user-edited bootstrap command for an existing discovered host instead of resetting it back to the team metadata default.
   - Discovery refreshes now preserve the user-edited SSH auth mode for an existing discovered host instead of resetting it back to the metadata default.
   - Discovery refreshes that backfill team-scoped host metadata now also reserve backend identity and start backend metadata observation for existing workspaces on that host, instead of waiting for a later reopen.
   - Discovery refreshes that move a discovered host to a different team scope now clear the stale backend identity and metadata link first, then reserve and observe against the new team scope.
   - Raw SSH first contact and host-key replacement both fail closed, store a pending host key for review, and let the server editor pin or clear SSH trust explicitly.
   - Parking a daemon-backed workspace now detaches the current daemon attachment instead of closing the server-side session, so reconnects reuse the same terminal when the remote session still exists.
   - `TerminalSSHTransport` remains the legacy/manual-host path and the fallback carrier.
   - Inactive workspace controllers park their transport and surface, preserve daemon resume state, and reconnect on selection or foreground.

## Milestones

### M1: libghostty embed (implemented)
- [x] Link `../GhosttyKit.xcframework` into `ios/project.yml`.
- [x] Add iOS runtime wrapper (`GhosttyRuntime`).
- [x] Add iOS metal-backed surface view (`GhosttySurfaceView`).
- [x] Render terminal in detail pane of sidebar root view.

### M2: Sidebar UX and persistence (implemented)
- [x] Persist saved servers, workspace ordering, and selection across launches.
- [x] Add unread/activity status model and pinned server affordances.
- [x] Keep the iPhone terminal detail view compact and edge-aligned.

### M3: Transport and interaction hardening (next)
- [x] Add SSH transport plumbing with tmux attach-or-create bootstrap.
- [x] Add ticket-backed direct `cmuxd-remote` transport with SSH fallback policy.
- [x] Add network path loss and path-change recovery for the selected terminal workspace, including in-flight reconnects.
- [x] Add robust iOS text input pipeline for terminal typing/IME.
- [x] Add per-session launch templates through saved host bootstrap commands.
- [x] Expand auth beyond password-based SSH.
- [x] Add crash-safe recovery for failed terminal surface creation.

### M4: Desktop model convergence (future)
- [x] Map sidebar sessions to real backend workspace/session identities.
- [x] Workspace metadata via daemon sync.
- [x] Share model contracts with desktop.

## Risks / Open Questions
- iOS process sandboxing can constrain shell/process behavior across device/simulator.
- Current runtime action callback handles URL opens, ring-bell attention, show-on-screen-keyboard requests, and copy-title-to-clipboard using the hosted surface title cache, but more Ghostty actions still need app-side routing.
- Keyboard, IME, software accessory keys, software control and alt latches, software accessory meta-prefix, word-nav and delete shortcuts, hardware control, shifted control aliases, control-digit and control-symbol aliases, navigation, option-word-movement, plus option-delete behavior now have unit coverage, but real device validation for hardware and third-party keyboards is still pending.
- Reconnect UX, network path recovery, and surface-close recovery are test-covered, but real device validation for ticket issuance, direct TLS policy, and Wi-Fi or cellular handoff is still pending.
- SSH bootstrap and raw SSH now rely on explicit host-key review only. Unknown keys fail closed and are not auto-pinned after connect.
- Workspace parking is unit-covered, and workspace close now releases the hosted terminal surface in unit tests, but extended manual validation for repeated session switching is still pending.

## Validation Checklist
- [x] `xcodegen generate` succeeds after adding GhosttyKit dependency.
- [x] iPhone build/install run with sidebar + terminal visible.
- [x] Simulator unit tests pass for the iOS app target.
- [x] Reconnect banner and recovery flow have a dedicated UI test fixture path.
- [x] First-time server setup has a dedicated UI test fixture path.
- [x] Inbox list ordering, unread badges, status labels, and swipe actions have a dedicated UI test fixture path.
- [x] Inbox workspace selection has a dedicated UI test fixture path.
- [x] Software keyboard typing and accessory actions have a dedicated UI test fixture path.
- [x] Network loss restoration and reachable path changes reconnect the selected workspace, including in-flight connects, in unit tests.
- [x] Direct daemon connect and handshake timeouts fail fast instead of hanging the selected workspace in unit tests.
- [x] SSH remote-daemon bootstrap times out instead of hanging the workspace during fallback setup in unit tests.
- [x] Direct and SSH authentication failures fail closed instead of entering reconnect loops in unit tests.
- [x] Surface-close recovery rebuilds and reconnects a fresh terminal host in unit tests.
- [x] Workspace switches replace the hosted terminal surface cleanly in unit tests.
- [x] Inactive workspaces park their terminal surface and reconnect with saved daemon resume state in unit tests.
- [ ] Terminal input works well on software/hardware keyboard and IME.
- [ ] Session switching preserves terminal surfaces without leaks under extended manual testing.
