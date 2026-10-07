# D3 `dogfood`: parity, device checklist, UI tests, runbook

Status: parity refresh 2026-10-07 on `feat-cmux-next-ios` at `bd9dc02a3c` (B1 rate limits, B2, C3,
C12, C14, D1b, E3, E4, E5 and F1 are in this ancestry). Plan: [PLAN.md](PLAN.md) D3. No tagged build,
simulator or device run is recorded: the dedicated build host and fleet slot were unavailable, so
the matrix below separates implementation evidence from the still-pending live-pair gate.

The first-pass matrix was recorded at `afbc8c69b3b` and is retained in
[research-and-scope-2026-10.md](research-and-scope-2026-10.md) as historical context. This refresh
reconciles the rows with the landed C14, D1b, E3, E4, E5 and SSH/browser follow-ups; it does not
turn package or static checks into device evidence.

## 1. Parity matrix

Every capability from [a1-shell.md](a1-shell.md) section 1, status on `feat-cmux-next-ios`:
**done** (built, tested in its package, device-unverified unless said), **mocked** (UI over a mock
seam with no real owner yet), **seam only** (protocol or hook, no UI or no owner), **missing**,
**dropped** (removed by design).

| 1.x | Capability | Lane | Status |
| --- | --- | --- | --- |
| 1.1 | Composition root, scene, lifecycle diagnostics | A1, C16 | done |
| 1.1 | Root auth gate and restore screen | kept | done |
| 1.1 | NotificationService extension | C7 | done (extension target typechecked, not compiled by Xcode) |
| 1.1 | CloudVPN packet-tunnel extension | C12 | dropped (c12-cloud.md 3: VM attach rides `CmuxLink`) |
| 1.1 | Remote feature flags | C16 | done (authenticated `/v1/mobile/config` source; cached, fail-closed refresh; realtime `config.snapshot` remains a carrier follow-up) |
| 1.1 | App Review demo mode | C16 | done (DEBUG `CMUX_IOS_DEMO`; remote trigger waits on B1) |
| 1.1 | Multiple scenes | - | dropped (out of scope) |
| 1.1 | Pointer, indirect input, 120 Hz | A2, D1 | done |
| 1.2 | `attach` / `pair` QR grammars, update-app error | B6, C16 | done |
| 1.2 | Notification tap to workspace on a Mac, parked until attach | C7, C16, C5 | done (surface focus missing, C15 gap) |
| 1.2 | Deferred open of URLs until signed in (`ShellRoute`) | C16 | done |
| 1.3 | Categories, inline Reply, time-sensitive, clear on foreground, remote dismiss | C7 | done |
| 1.3 | Background inline reply under a background task | C7 | done |
| 1.3 | Mac-to-phone end-to-end push keys | C7 | done (kept `CmuxPhonePush` path) |
| 1.4 | Apple, Google, GitHub, email code, passkey errors | kept | done |
| 1.4 | Account deletion, team switcher | C11 | done |
| 1.4 | Deferred sign-in (SSH without an account) | C16, E5 | done (guest shell, sync offer; e5-extras.md 5) |
| 1.5 | Onboarding stages, push opt-in, pairing, connect, replay | C10, B6 | done |
| 1.5 | Keep-awake onboarding card | C10, C16, E5 | mocked (flag `keepAwake` off; Mac control is D1b) |
| 1.5 | Cloud onboarding | C12 | done (`cloudOnboarding` step) |
| 1.5 | One-time migration sheets | - | dropped (no iroh) |
| 1.6 | QR scanner, manual add, setup help | B6, B4 | done |
| 1.6 | Same-account zero-touch connect, registry, presence | B6, B1 | done |
| 1.6 | Tailscale / LAN direct transport | B4, D1 | done |
| 1.6 | Multi-Mac aggregation | B6, C5 | done |
| 1.6 | Mac compatibility and version gate UI | C16 | mocked (`MacCapabilitiesSource` mock until B5 serves caps) |
| 1.6 | Paired-Mac store and server backup | B6 | done (`UserDO`/`PairingDO`) |
| 1.6 | Computers list with routes and ping, detail, forget | C11, D1 | done (`AccountLinkDiagnostics`) |
| 1.6 | Hidden computers and order | C5 | done |
| 1.6 | Connection recovery banner, reconnect backoff | A3, D1 | done |
| 1.6 | Keep Mac Awake per Mac | C16 | mocked (no Mac power assertion, B5/D1b) |
| 1.7 | Tabs (Home, Feed, Workspaces, Compose, Hosts, Settings), floating compose | A1, C8 | done |
| 1.7 | Legacy Notifications tab | - | dropped (Feed) |
| 1.7 | Cloud tab | C12 | done (live CloudDO ops) |
| 1.7 | Search tab | C15 | done |
| 1.7 | Disconnected / no-Mac shell | C5, C10 | done |
| 1.8 | Previews, unread, machine colors, filters, sorts, view options | C5 | done |
| 1.8 | New workspace | C8, C5 | done (composer workspace picker) |
| 1.8 | Groups: collapse, rename, drag reorder across groups | C5, E3 | done (E3; collapse is phone view state) |
| 1.8 | Row actions read, rename, close | C5 | done |
| 1.8 | Customize sheet (color, icon) | E3 | done (name, nine palette colors, SF Symbol icon) |
| 1.8 | SSH computers and their workspaces in the list | C9, C5, E3 | done (E3: tmux sessions and windows, screen, cmux-tui sessions; attach only; no create/kill) |
| 1.8 | Cloud machines in the list | C12 | seam only (`cloudWorkspaces` flag off until the VM Rust host, c12 4) |
| 1.8 | Presence announce of the viewed workspace | C5 | done |
| 1.9 | Detail container, title menu, terminal picker | C5, D1 | done |
| 1.9 | Terminal surface | A2, C1, D1 | done (D1b host wiring is landed; tagged-pair verification is pending) |
| 1.9 | Browser stream surface | C2 | done (D1b `BrowserPageHost` adapter is landed; tagged-pair verification is pending) |
| 1.9 | In-app WKWebView browser, mode picker, Mac/SSH tunnel | C14 | done (implementation and focused tests; live WKWebView, Mac/SSH tunnel, and direct-host verification pending) |
| 1.9 | Simulator stream surface | C14 | done (implementation and focused tests; live ScreenCaptureKit/HID verification pending) |
| 1.9 | Markdown and file-preview surfaces | C13 | done |
| 1.9 | Todo surface | C13, E4 | done (E4: workspace todo file, read only; no daemon checklist op) |
| 1.9 | Changes hint banner, action toasts | C13, C16 | done |
| 1.10 | Ghostty Metal surface, render recovery, background suspend | A2 | done |
| 1.10 | Snapshot output path, exactly-once input, send status | C1 | done |
| 1.10 | Shared sizing with the Mac, alt-screen notice | C1, D1 | done |
| 1.10 | Key bar, modifiers, symbols, shortcut customization | A2, D1, C11 | done |
| 1.10 | Hardware keyboard and IME | A2, D1 | done (ios-keyboard audit failures need a re-run) |
| 1.10 | Gestures: tap to focus, pinch zoom HUD, pixel scroll | A2, D1 | done |
| 1.10 | Selection and copy, links | A2, D1 | done |
| 1.10 | Keyboard docking and safe areas | D1 | done (unverified; audit found Home composer failures) |
| 1.10 | Terminal composer with attachments, image paste | C8, C4, E4 | done (E4 composer bar; task composer attach still unwired) |
| 1.10 | Theme sync from the Mac, font, scrollback | C11, A2 | done (Match Mac uses the host theme) |
| 1.10 | Drafts per terminal | D1, E4 | done (E4) |
| 1.10 | Files chip and transfer list | C4 | done (artifact gallery missing) |
| 1.11 | Artifact viewer: highlight, go to line, search, Markdown, images, PDF, share | C13 | done |
| 1.12 | Changes chip, file tree, diff pager, copy line/hunk | C13 | done (Refresh only, no git change stream) |
| 1.13 | Composer: agent, model, effort, machine, directory, name, prompt | C8 | done (Mac runner over acpmux is D1b: seam only on the Mac) |
| 1.13 | Drafts, templates, failure recovery, model catalog, dictation | C8 | done |
| 1.13 | Composer attachments | C8, C4 | seam only (uploader not wired) |
| 1.14 | Feed, Needs Input filter, inline decisions, multi-question, quoted reply | C6 | done |
| 1.14 | Push coordinator, readiness, repair, Allow Push, DEBUG diagnostics | C7, C11 | done |
| 1.15 | Hosts with jump host, key, idle timeout, TOFU, changed-key prompt | C9 | done |
| 1.15 | Keys: Secure Enclave, Ed25519, copy, install with password | C9 | done (import UI missing; stores support it) |
| 1.15 | Workspaces over SSH (tmux control mode, screen, cmux-tui) | C9 | missing (tmux control-mode hydration and safe attach are landed for single-pane matching-grid windows; multi-pane/history/parser-state parity and lifecycle mutations remain) |
| 1.15 | SFTP browser | C4, C9, E5 | done (browse, view, upload, download, New Folder, Rename, Delete) |
| 1.15 | SOCKS proxy and local port forward | C14 | done (credentialed generic SOCKS route is wired into `WebRoute`; loopback uses the route tunnel, non-loopback is default-deny with an explicit direct-backend seam; live device/reconnect verification pending) |
| 1.16 | Cloud VM lifecycle and quota (create, start, pause, delete, plan) | C12 | done (`vm_hours_used` 0 until metering) |
| 1.16 | Cloud VM terminal and files attach | C12 | seam only (needs the phase-2 Rust host on the VM) |
| 1.16 | StoreKit plans, purchase, restore | C16 | mocked (`MockBillingStore`, `PlansView` stub) |
| 1.17 | Account, sign out, delete account, team | C11 | done |
| 1.17 | What's New archive and post-update sheet | C16 | done |
| 1.17 | Connection and computers | B6, C11 | done |
| 1.17 | Networking diagnostics (path badge, RTT) | C11, D1 | done (V1 RTT sampled at connect only, B2 F3) |
| 1.17 | Terminal and display options, scrollback | C11 | done |
| 1.17 | Haptics toggle | C11, E5 | done |
| 1.17 | Privacy (telemetry consent) | C11, C16 | done |
| 1.17 | Diagnostics: verbose log, export, clear, copy support info | C16 | done |
| 1.17 | Legal, support links, version | C11 | done |
| 1.17 | Erase all data on this device | C11, E5 | done (sandbox-wide plan, e5-extras.md 3) |
| 1.17 | DEBUG Developer section | A1 | done |
| 1.18 | Structured diagnostic log, terminal latency trace | C16, C1 | done |
| 1.18 | Analytics uploader | C16 | seam only (`NoopAnalytics`) |
| 1.18 | Crash reporting (Sentry, hangs) | C16 | done (session replay off until masks are listed, section 4) |
| 1.18 | DEBUG Copy Logs, Send Feedback | C16 | done (diagnostics share) |
| 1.19 | Toast center | C16 | done |
| 1.19 | Accessibility, Dynamic Type, Reduce Motion | all | done with fixes in section 4 |
| 1.19 | Localization (en, ja translated) | all | done (section 4) |
| 1.19 | Background modes, protected data | kept, C7, A2 | done |

Counts (98 rows): done 84, mocked 4, seam only 5, missing 1, dropped 4. (Rows with partial notes
count under their main status. “Done” means implementation and package/static evidence; it remains
device-unverified unless the row says otherwise.)

Open implementation gaps, grouped by owner:
- C9: tmux control-mode discovery, epoch validation, hydration and live output are landed for
  single-pane matching-grid windows. Multi-pane geometry, history, complete parser-state restore,
  and SSH create/rename/kill remain explicit gaps; E3 still supplies the screen and cmux-tui paths.
- C14: local port forwarding, simulator/browser seams and the credentialed generic SOCKS route are
  landed. `CmuxMobileTunnel` is now a direct `CmuxiOSWebCore` dependency; `WebRoute.startSocks` keeps
  loopback routing on the authenticated machine tunnel and requires an explicit direct backend for
  non-loopback destinations. Package and route-focused tests pass; live device/reconnect evidence is
  still required.
- Mocked rows: Mac capabilities/version gate, Keep Mac Awake (onboarding and per-Mac power assertion),
  and StoreKit plans remain behind their DEV/mock owners.
- Seam-only rows: remote feature flags (B1 config read), Cloud machines in the workspace list, Cloud
  VM terminal/files attach, task composer attachments, and analytics upload.

## 2. Device verification checklist

Ordered by risk: what blocks the most, or fails silently, first. Each line names the lane note it
comes from. Steps run on the tagged pair `nxd3` (section 6).

### 2.1 Blockers before any real-Mac path works

1. A tagged Mac+iPhone build and pairing run are still required. D1b now supplies
   `InstallHostAccount`, `MobileLinkHostRunner`, `MobileLinkService`, and the C2/C4/C8/C13/C14
   adapters; the old “no `MobileLinkHostAccount`” blocker is resolved in source but has no live
   build evidence yet (d1b-mac-integration.md 1–4).
2. Host-role TURN credentials still need deployment: configure
   `CLOUDFLARE_TURN_KEY_ID` / `CLOUDFLARE_TURN_KEY_API_TOKEN` and verify
   `POST /v1/realtime/turn` returns `turn:` URLs. Until then a host socket falls back to STUN
   (d1b-mac-integration.md 2; b2 12.1).
3. The Mac app's task dispatch and terminal spawn switches are off by default. A live composer/task
   check must explicitly use the DEV switches after acpmux is available; otherwise the host reports
   `spawn_unverified` (d1b-mac-integration.md 3; c8 7).
4. Pairing, Secure Enclave signing, direct/relay route selection, and all C2/C4/C14 media and
   tunnel adapters remain unverified until the tagged pair is available (checklist 2.2 and 2.5).

### 2.2 Trust, pairing, carriers (security and connectivity)

5. Same-account pairing: Mac and phone on one Stack account, `auth status` matches, the Mac appears
   trusted without a QR; QR pairing for a second account; revoke kicks a live session (b6, b5 3).
6. Secure Enclave install key signs hello and WebRTC bindings; the Keychain direct key publishes
   before first dial (d1 2).
7. V1: same Wi-Fi badge `p2p`; DEV Force TURN badge `turn`; roam Wi-Fi to cellular mid-terminal keeps
   the session or resumes with no gap; a relay rewriting SDP fingerprints fails with `auth` (b2 12).
8. V3: Tailscale `100.x` and LAN address; Bonjour `_cmux._tcp` browse; the Local Network prompt
   appears once (Info.plist has the keys; `_cmux-iroh._udp` is stale) (b4 8).
9. V2 is DEV-only and needs a `wg` cert publish op (B6); skip unless D2 keeps V2 (d1 7, b3 10).
10. Large frames over V1 on a real network: 64 B echo p99 stays low under a C4 download (d2 F1).

### 2.3 Terminal (D1, C1, A2)

11. Workspaces > tagged Mac > workspace > terminal: snapshot appears, typing echoes once in order,
    rotate and keyboard show/hide resize the grid (READY), badge and banner states on Wi-Fi off/on.
12. Load Older History (Command-Up) reads as unavailable on cmux-tui (`proto.unsupported`), no retry loop.
13. Echo prediction DEV switch (`CMUX_IOS_TERMINAL_PREDICTION=1`): confirm and rollback look right.
14. Renderer: 120 Hz during scroll, pinch zoom HUD, link tap, edit menu, selection (a2 4).
15. Hardware keyboard: Esc/Ctrl/Option reach the program, Command keys do not; Cmd-K skipped while a
    terminal hides the tab bar (d1 4, c15 9).
16. Re-run the ios-keyboard audit (`KeyboardAuditUITests`): composer rides keyboard, rotation,
    hardware Return, Home key commands, terminal tap focus (ios-keyboard.md 1).
17. Benchmark `CMUX_IOS_TERMINAL_BENCH=htop|flood|vim` numbers (`terminal-bench.json`).

### 2.4 Notifications and feed (C7, C6)

18. Token registration and push delivery on the tagged build; the NotificationService extension's
    decisions on real pushes (expired drop, category).
19. Lock-screen actions Allow/Deny, Allow Once/Session, Reply, plan Approve/Request Changes under the
    background budget; "Answered elsewhere" and "Answer not sent" notices.
20. Remote dismiss and foreground badge sync; Live Activity rendering and push updates (needs
    `com.cmux.app.AgentActivityWidget` registered for release signing).
21. Feed on real `FeedDO`: inline approve, multi-question answer, quoted reply, read state.

### 2.5 Features over the link

22. C2 browser: ScreenCaptureKit capture of a CEF pane, VideoToolbox encode/decode, gestures, IME
    commit, latency numbers.
23. C4 files: 200 MB download, resume after backgrounding and after a session drop; upload from Photos.
24. C8 composer: dictation on device; live spawn check (real Macs refuse `spawn_unverified` until D1b);
    receipt and stream.
25. C9 SSH: trust alert, changed key, key install with password, PTY resize, reconnect, keepalive
    drop detection, Secure Enclave key.
26. C13 viewers: Markdown, image, PDF, diff pager against a real repo.

### 2.6 Shell, settings, platform

27. C10 onboarding on a fresh install: every step, permission priming (notifications, local network,
    camera), Not Now is respected at the next launch.
28. C11: Delete Account failure copy, team switcher, device rename and revoke, notification prefs.
29. C16: toast overlay, diagnostics export share sheet, What's New once per update, Mac gate (once B5
    serves caps), keep-awake and plans stubs DEV-only.
30. C15: search hardware arrows over the field; Cmd-K after a field resigns.
31. C5: coalescing under a real event burst (one snapshot per frame); offline/sleeping reasons.
32. Accessibility on device: VoiceOver pass over every tab, Dynamic Type AX5, Reduce Motion
    (section 4 lists what the static audit fixed and what remains).

### 2.7 Measurements (D2)

33. The D2 device re-measure plan (d2-bakeoff.md 6): needs F2 split mode (`cmux-link-bench serve` and
    the iOS DEV Link bench screen), which is not built. Until then, record C1 `TerminalLatencyReport`
    (echo p50/p95, frame age) idle and under `yes | head -c 500M`, and a 10 min Power Profiler trace
    per carrier (section 6.5).

## 3. UI tests

New classes in `ios/cmuxUITests` (target `cmuxUITests`, scheme `cmux-ios`, registered in
`project.pbxproj`). `NextUITestSupport.launchShell(tab:)` sets `CMUX_IOS_HOME_PREVIEW=1`,
`CMUX_IOS_SOURCES=mock`, `CMUX_IOS_ONBOARDING=0`, `CMUX_IOS_FLAG_{FEED,WORKSPACES,COMPOSE,HOSTS,SEARCH,CLOUD}_TAB=1`
and `CMUX_IOS_SHELL_TAB=<tab>`; `launchOnboarding(step:)` sets `CMUX_IOS_ONBOARDING=1` (and
`CMUX_IOS_ONBOARDING_STEP`) signed out. English locale, predicate waits, no sleeps.

| Class | Tests | Switches |
| --- | --- | --- |
| `NextOnboardingUITests` | tour walk-through to sign-in, Deny also unlocks Continue, Have an Account, header Skip, Back | `CMUX_IOS_ONBOARDING=1`, `_STEP=approve` |
| `NextShellTabsUITests` | every `CMUX_IOS_SHELL_TAB` value, tab bar selects every tab (iPhone, More fallback) | shell |
| `NextFeedUITests` | mock list, Allow, Deny, suggestion chip, reply composer send | tab `feed` |
| `NextWorkspacesUITests` | both Macs listed, list -> detail -> terminal (mock host), detail -> Changes | tab `workspaces` |
| `NextComposerUITests` | send on mock, floating button opens composer | tabs `compose`, `feed` |
| `NextHostsUITests` | fixture hosts, Add SSH Host form, Keys screen | tab `hosts` |
| `NextSettingsUITests` | account and version, device detail, Terminal, Notifications, Privacy, What's New, Developer sources, Demo page, Replay tour | tab `settings`, `CMUX_IOS_DEMO=1` |
| `NextSearchUITests` | Cmd-K opens search, query -> results -> open a hit | tabs `settings`, `search` |
| `NextDiagnosticsUITests` | Diagnostics rows, Copy Support Info, Clear Log confirms, terminal bench reports | tab `settings`, `CMUX_IOS_TERMINAL_BENCH=flood` |
| `NextCloudUITests` | mock machines listed, New Machine creates one | tab `cloud`, `CMUX_IOS_FLAG_CLOUD_TAB=1` |

Identifiers added (no behavior change): `home.screen`, `terminal.screen`, `terminal.view`,
`onboarding.signIn.title`, `feed.action.{allow,deny,allowOptions,reply}`, `feed.suggestion.<text>`,
`feed.resolution`, `feed.composer.send`, `platform.diagnostics.lines`.

Verification: `xcrun --sdk iphonesimulator swiftc -typecheck -target arm64-apple-ios17.0-simulator
-F $P/Library/Frameworks -I $P/usr/lib -swift-version 6 ios/cmuxUITests/*.swift` (`P` = the simulator
platform's `Developer` dir) is clean; the package-side identifier lines were not compiled
(single modifier or property set each). Not run: no simulator here (section 6.4 runs them).

Known risks for the first run: feed inline buttons in list cells are VoiceOver custom actions that
XCUITest cannot press, so the tests answer from the item detail; the Add SSH Host `UIMenu` action is
found by its English title; Cmd-K assumes the shell is first responder on Settings; the onboarding
tests need a fresh simulator keychain (a restored session skips to the signed-in steps); the
`composer.outcome` and Clear Log dialog lookups assume the mock and system presentation.

## 4. Static audits

Commits on this branch: `e007e274b45` (l10n), `4a8a7408bcf`, `c06733cd04d`, `ae07aef5b51`,
`566f244d094` (a11y).

1. Localization. `scripts/cmux-next/check-l10n.sh` scans only `Packages/macOS/CmuxNext`; a copy
   pointed at `ios/CmuxiOS/Sources` and `Packages/Shared` found no key missing en or ja and no bare UI
   literal, but 1,104 errors in seven catalogs (App, Files, LiveActivity, Pairing, PairingCore, Push,
   Workspaces): 1,064 missing `needs_review` copies of the 19 untranslated languages, and 40 from
   `workspaces.row.panes` / `workspaces.machine.count` stored as plain strings ("1 panes"). Fixed: 0
   errors in `ios/` (remaining errors are in legacy `CMUXMobileCore` and `CmuxMessagesLab`). Backlog:
   1,150 `needs_review` keys per non-ja language, 31 for ja.
2. Concurrency. `check-concurrency.sh` on `ios/CmuxiOS` and each of the 16 new Shared packages: 124
   hits (about 55 unbounded `AsyncStream` buffers, 45 sleeps, 25 loops). No `asyncAfter`,
   `Timer.scheduledTimer`, RunLoop polling or sync poll loop in runtime code; sleeps are cancellable
   deadlines, backoffs and debounces on injected clocks. The one `Timer` is kept Home code
   (`HomeRunLoopDeadline`); NetLab timers are DEBUG.
3. iOS package lint: exit 0, 94 warnings, no violations; its scope excludes `ios/CmuxiOS`.
4. Crash safety: wire decoders (LinkFrame, DirectRecord, Rd, LaneFrame, OverlayDatagram,
   H264AccessUnit, FeedWireFrame) bounds-check before indexing and convert integers safely; remaining
   `precondition`/`as!`/`!` are programmer invariants or constant URLs.
5. VoiceOver and Dynamic Type, fixed: unread badge and chip font did not follow live Dynamic Type
   (`ShellTypography` chip font through `UIFontMetrics`); workspace detail's ellipsis menu had no label
   ("Workspace Actions"); transfer rows did not say Upload or Download and formatted percent by hand;
   the SSH import selection glyph was read twice; the composer mock chip had a fixed font; Cloud
   size rows read "Checkmark" and "Lock" on top of the selected and disabled states.

Left for owners, most severe first:
- Medium (A3/B2/B3/B1): unbounded buffers on network ingress with no back-pressure:
  `CmuxLinkWebRTC/Datagram/WebRTCDatagramChannel.swift:20`, `CmuxLinkWebRTC/Peer/WebRTCPeer.swift:50`,
  `CmuxLinkDirect/Transport/DirectTransport.swift:32`, `CmuxControlPlane/ControlPlaneClient.swift:37,71,149`,
  `CmuxMobileLink/Binding/MobileChannel.swift:30,62`, `CmuxLinkWG/Transport/WireGuardLinkTransport.swift:91`,
  `CmuxiOSBrowserCore/Link/LinkBrowserStreamSession.swift:23`. `bufferingNewest` would also drop the
  closed and path-changed events these streams carry, so the fix is a split stream.
- Low (C13): `ChangesViewController.swift:184` derives the +/- font from the current footnote size
  without `UIFontMetrics`; `LineNumberGutterView.swift:12` has an unused fixed 11 pt default.
- Tooling (fixed by E2): `check-l10n.sh --mobile`, `check-concurrency.sh --mobile`,
  `check-crash-safety.sh --mobile` and the package lint scan `ios/CmuxiOS` and every root in
  `scripts/cmux-next/mobile-scan-roots.txt`; `cmux-next-ios.yml` runs them in CI.
- Session replay masks (C16 decision): Metal and video surfaces to mask before enabling replay are
  `GhosttyTerminalView` (CmuxiOSTerminal), `BrowserVideoView` and `BrowserCanvasView` (CmuxiOSBrowser), and
  `ImageViewController` and `PDFViewController` content (CmuxiOSViewers).
- `ios/Config/Info.plist` still lists `_cmux-iroh._udp` in `NSBonjourServices` (iroh is dropped).

F1 hygiene (2026-10-07, branch `feat-cmux-next-ios-f1-hygiene` off `feat-cmux-next-ios` at `32d4627b0da`),
every check on the merged tree, before -> after:

| check | before | after |
| --- | --- | --- |
| `scripts/lint-ios-package-conventions.sh` | exit 1: 2 lock (`NSLock` in `SFTPProgressCounter`, `MemoryTerminalComposePersistence`), 3 namespace-type (`BrowserCDPInput`, `AcpmuxCatalog`, `MobileWorkspaceRoots`), 1 namespace-enum (`TerminalComposeText`) | exit 0, no violations (147 warnings, unchanged) |
| `check-concurrency.sh --mobile` | exit 1: 2 unbounded `AsyncStream` (`HostSocketLease.swift:75`, `SharedHostSocket.swift:143`), 2 `NSLock` | exit 0; baseline 51 files / 63 hits -> 28 files / 31 hits |
| `check-crash-safety.sh --mobile` | exit 1: ratchet +1 unchecked SFTPCore, +1 unchecked TerminalComposeCore, +1 force_unwrap CmuxiOSTerminal, +3 force_unwrap and +2 iuo CmuxiOSTerminalCompose, +1 unowned CmuxiOSApp | exit 0 (one reviewed `crash-allow`: the `UITextView.text: String!` override) |
| `check-l10n.sh --mobile` | exit 0: 28 tables, 1396 keys, 0 errors | same |
| `check-workspace-package-groups.py` | OK | OK |

Fixes: the shared host socket gives each lease a `StreamUpdateBuffer` at the client's backlog limit and,
on overflow, drops the backlog, skips events and resubscribes so the lease repairs from a snapshot. Every
acceptor's `incoming` (direct, WebRTC, WG over WebRTC, merged, loopback, datagram and underlay listeners)
holds 64 transports and closes one past that. `SignalRouter` caps a session inbox at 256 signals and ends a
session that outruns its reader; an offer past an acceptor's 64 pending sessions is refused without
registering an inbox (before, `bufferingNewest(64)` silently dropped an `Incoming` and leaked its inbox).
`PathSelector` sizes its outcome stream to its attempts; the in-memory signaling hub and underlay network
doubles are bounded. Left in the concurrency baseline: app-layer streams (CmuxiOS sources, mocks,
CmuxMobileHost remote desktop/simulator, CmuxMobileSSH, CmuxRemoteDesktop, CmuxBrowserStream client) and
the `DirectTransport.close` drain race (the socket is cut inside the group, so the loser finishes).
The crash ratchet reports 11 lower counts in Mac and Rust modules this lane did not touch; its baseline
was left for those owners.

Tests: CmuxControlPlane 21 (new `aLeaseThatStopsReadingIsBoundedAndResyncsFromASnapshot`), CmuxLink 43,
CmuxLinkWebRTC 39 (new `routerBounds`), CmuxLinkDirect 25, CmuxLinkWG 41, CmuxMobileConnect 10; scratch
macOS package over CmuxiOSSFTPCore + CmuxiOSTerminalComposeCore 47; scratch package over CmuxNextMobileLink
+ CmuxNextMobileHostUI 17 (Daemon/Wakeups in Swift 5 mode, as D1b); CmuxiOSApp builds for
`arm64-apple-ios17.0-simulator`.

## 5. Package tests and current-head evidence

The table below is the **historical first-pass** package run from the pre-E3/E4/E5/D1b integration
state (`b3cffeafeda`, identical to `afbc8c69b3b` after C12). It is useful coverage evidence, but is
not a test result for current HEAD `bd9dc02a3c`.

| Package | Tests | Result |
| --- | --- | --- |
| CmuxLink | 37 | pass |
| CmuxMobileWire | 21 | pass |
| CmuxControlPlane | 11 | pass |
| CmuxFeedPushCore | 40 | pass |
| CmuxTerminalRenderCore | 46 | pass |
| CmuxLinkDirect | 25 | pass |
| CmuxLinkWG | 40 | pass |
| CmuxMobileLink | 1 | pass |
| CmuxBrowserStream | 22 | pass |
| CmuxPairing | 16 | pass |
| CmuxMobileHost | 109 | pass |
| CmuxMobileFiles | 12 | pass |
| CmuxTerminalLink | 33 | pass |
| CmuxLinkWebRTC | 37 | pass (includes `LargeFrameTests`) |
| CmuxLinkBench | 2 | pass |
| CmuxMobileConnect | 8 | pass |
| **Total** | **460** | **16/16 packages, 0 failures** |

Not run here: the `ios/CmuxiOS` test targets (iOS-only package; lanes ran them on macOS through
scratch packages), native CmuxMobileTunnel tests (the local CLT lacks TestingMacros), and Rust
(no cargo on this Mac). The current-head backend slice has `26` focused Vitest tests and a clean
TypeScript typecheck at `bd9dc02a3c`.

Current-head evidence is static plus the focused backend checks above: Swift syntax parsing, scoped iOS package-convention lint,
`git diff --check`, `check-concurrency.sh`, `check-crash-safety.sh`, and `check-theme-scope.sh`
pass for the follow-up changes. Native Swift tests, the tagged iOS/Mac build, UI tests, and live
network/device journeys remain blocked by the unavailable dedicated build host/fleet slot; do not
read the historical 460-test total or the agent-reported package test runs as current-head device
verification.

## 6. Runbook: tagged pair `nxd3`

Run from the hq root (`HQ_ROOT`), worktree `worktrees/feat-cmux-next-ios` (`WT`). Physical
iPhone = Aziz `4A52829D-6427-599F-A166-4058881D2DF4`, auth profile `personal`.

### 6.1 Preflight

```bash
./scripts/macfleet-doctor.sh report --probe          # must show a free direct slot (needs ~/.config/macfleet/hosts.json)
./scripts/dev-backend.sh status                      # dev backend VM reachable
./scripts/ios-dogfood-doctor.sh --checkout worktrees/feat-cmux-next-ios
gh auth status                                       # pushes and workflow dispatch need it
```

The real-Mac paths in 2.2 to 2.5 need a tagged build from this current integration branch and the
host-role TURN deployment in 2.1. Without those, the pair still verifies mock flows, onboarding,
settings, SSH and push, but cannot provide live Mac/media evidence.

### 6.2 Build and install

```bash
cd worktrees/feat-cmux-next-ios
./scripts/reload-cloud.sh --tag nxd3 --direct-backend --launch
./ios/scripts/reload-cloud.sh --tag nxd3 --device-id 4A52829D-6427-599F-A166-4058881D2DF4 --wait
CMUX_TAG=nxd3 scripts/cmux-debug-cli.sh auth status    # signed in, email = the account mobile-dev-launch printed
scripts/iphone-install-queue.sh list                  # empty, or drain if the phone was unreachable
```

If the phone lands on login: `./scripts/mobile-dev-launch.sh --tag nxd3 --device --device-id
4A52829D-6427-599F-A166-4058881D2DF4 --ensure-mac --auth-profile personal --credentials-file
"$HOME/.secrets/cmuxterm-dev.env"` (from hq). The iOS launch must print `trusted-paired` and `usable
RPC session established`. For API-backed dogfood start `cd web && CMUX_PORT=<printed> bun dev` and warm
`/`, `/handler/sign-in`, `/handler/after-sign-in`.

### 6.3 D1 terminal steps

1. Mac: the tagged app runs with `CMUX_NEXT_MOBILE_LINK=1` (Debug default) and D1b's account seam;
   check the debug log for `MobileLinkHostRunner` start and the direct cert publish.
2. Phone: Settings > Devices shows the Mac trusted with a route badge (`direct` on LAN, `p2p`/`turn` off LAN).
3. Workspaces > the `nxd3` Mac > any workspace > terminal: checklist items 11 to 15.
4. Toggle Wi-Fi off and on during `yes`; the banner reads Reconnecting then clears with no duplicate
   or lost input (type a counter before and after).
5. Shake > DEV: Force TURN, then repeat 3 and 4; `CMUX_IOS_LINK_WG=1` only if V2 is still in the race.

### 6.4 UI tests on a CI simulator

`.github/workflows/ios-next-uitests.yml` (E2) builds the app for testing, creates a simulator for the
run, runs each test in its own xcodebuild with a screen recording and an xcresult (through
`ios/scripts/keyboard-uitests.sh`), uploads them as the `ios-next-uitests` artifact with
`summary.txt`, and deletes the simulator. An empty `test_filter` runs every `Next*UITests` class.
`workflow_dispatch` only finds workflows that are on main, so until it lands there dispatch it
through `test-ios.yml`, which calls it with `ui_tests=true` (the simulator build runs alongside):

```bash
gh workflow run test-ios.yml --repo manaflow-ai/cmux --ref feat-cmux-next-ios -f ui_tests=true
gh workflow run test-ios.yml --repo manaflow-ai/cmux --ref feat-cmux-next-ios -f ui_tests=true \
  -f test_filter="cmuxUITests/NextShellTabsUITests NextFeedUITests/testMockItemsList KeyboardAuditUITests"
gh run list --repo manaflow-ai/cmux --workflow test-ios.yml --limit 3
gh run download --repo manaflow-ai/cmux <run-id> -n ios-next-uitests -D artifacts/d3-uitests
# once ios-next-uitests.yml is on main:
gh workflow run ios-next-uitests.yml --repo manaflow-ai/cmux --ref <branch> [-f test_filter=...]
```

A pull request runs the same set while it carries the `ios-uitests` label. Without `gh` auth, run
the script on a leased isolated simulator instead (`scripts/verify-remote.sh capacity`, then in a
checkout of this branch on the leased Mac, with `NX_SIM_UDID` = its per-lease simulator):

```bash
KBD_TESTS="NextShellTabsUITests NextOnboardingUITests NextFeedUITests NextWorkspacesUITests \
  NextComposerUITests NextHostsUITests NextSettingsUITests NextSearchUITests \
  NextDiagnosticsUITests NextCloudUITests KeyboardAuditUITests" \
  NX_ARTIFACTS=artifacts/d3-uitests ios/scripts/keyboard-uitests.sh
```

The Shared packages' `swift test`, the static checks over `ios/CmuxiOS` and the new packages, and
the protocol vitest run on every pull request that touches them (`.github/workflows/cmux-next-ios.yml`).

### 6.5 D2 device re-measure

Follow d2-bakeoff.md section 6 on the `nxd3` pair once F2 exists; until then:

```bash
# Power and memory, 10 min per carrier, phone on battery, screen on:
xcrun xctrace record --template "Power Profiler" --device 4A52829D-6427-599F-A166-4058881D2DF4 \
  --attach "cmux DEV nxd3" --time-limit 10m --output artifacts/d3-power-<carrier>.trace
```

Record `TerminalLatencyReport` lines from the device log (idle, typing, under a 500 MB flood in a
second pane, during a 200 MB C4 download) per network in d2-bakeoff.md 6.3, and commit the JSON under
`plans/cmux-next/ios-next/bakeoff/device/`. Pass bars: d2-bakeoff.md 6.7.

### 6.6 Teardown

`pkill -f "cmux DEV nxd3"` on the Mac, `scripts/verify-remote.sh release <lease>`, and remove the
worktree's scratch (`/tmp/cmux-nxd3`, `artifacts/d3-*`) after the evidence is committed or uploaded.
