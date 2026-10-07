# A1 `shell`: parity inventory and app shell

Status: landed on `feat-cmux-next-ios-a1-shell`, 2026-10-06. Binding: PLAN.md (this directory),
ios-rewrite.md (app shell, auth, Home, budgets), OWNERSHIP-PRINCIPLES.md, REWRITE.md visual rules,
motion.md.

## 1. Parity inventory of the shipping app

Source: `repo/ios`, `repo/Packages/iOS`, iOS-only parts of `repo/Packages/Shared` (read-only). Each
line names the capability and the lane in PLAN.md that owns it. **UNASSIGNED** means no lane covers
it today; section 1.20 lists those gaps. "Drop" means the new architecture removes the need.

### 1.1 App shell and extensions
- Composition root, scene, lifecycle diagnostics: A1 (done here; diagnostics with Sentry, 3.7).
- Root auth gate and restore screen: kept code (ios-rewrite.md section 2), A1 wires it.
- NotificationService extension (decrypt, set category, drop expired): C7.
- CloudVPN packet-tunnel extension (Cloud System VPN): **UNASSIGNED** (Cloud).
- Remote feature flags from ClientConfig (30 min refresh): A1 has local flags only; remote config
  over the control plane is **UNASSIGNED** (B1 could serve it).
- Demo content mode for App Review accounts (canned workspaces, feed, fake terminal): **UNASSIGNED**.
- Multiple scenes, pointer and indirect input, 120 Hz: multi-window out of scope (PLAN.md); pointer
  and 120 Hz per screen lane (A2, D1).

### 1.2 Deep links and URL scheme
- `attach` / `pair` QR grammars, update-app error for unknown versions: B6.
- Notification tap to a workspace or surface on a given Mac, parked until attach: C7 + C5.
- Deferred open of other URLs until signed in: A1 follow-up (a `ShellRoute` router; not built yet).

### 1.3 Notifications
- Categories `cmux.terminal`, `cmux.terminal.reply` (inline Reply), time-sensitive level, clear on
  foreground, remote dismiss sync: C7.
- Background inline reply under a background task: C7.
- Mac-to-phone push key exchange (end-to-end push): C7 with B1.

### 1.4 Auth and account
- Sign in with Apple, Google, GitHub, email code, billing recovery, passkey errors: kept code.
- Account deletion, team switcher: C11.
- Deferred sign-in (SSH hosts usable without an account): **UNASSIGNED** (C9 and A1 must agree; the
  new shell gates everything behind sign-in today).

### 1.5 Onboarding
- Stages agents, notifications, push opt-in, pairing, connect; keep-awake card; replay from
  Settings: C10.
- Cloud onboarding: **UNASSIGNED** (Cloud).
- One-time migration sheets (auto-connect, Tailscale prompt): Drop (no iroh, T1).

### 1.6 Pairing, discovery, connection
- QR scanner, manual add, setup help: B6 (manual address: B4).
- Same-account zero-touch connect, device registry, presence: B6 + B1.
- Tailscale direct transport and status: B4.
- Multi-Mac aggregation: B6 (list) + C5 (workspaces across Macs).
- Mac build compatibility and version gating, update hints: **UNASSIGNED** (B5 negotiates
  capabilities in A0; the user-facing gate has no owner).
- Paired-Mac store and server backup: B6 (the registry is now owned by `UserDO`/`PairingDO`).
- Computers list with routes and ping, Mac detail, forget: B6 + C11 (diagnostics).
- Hidden computers and order: C5.
- Connection recovery banner and reconnect backoff: A3 (state machine) + D1 (UI).
- Keep Mac Awake per Mac: **UNASSIGNED**.

### 1.7 Primary navigation
- Tabs Workspaces, Feed, Notifications (legacy), Cloud, Search; floating compose button: A1 (Home,
  Feed, Workspaces, Compose, Hosts, Settings). Legacy Notifications: Drop (Feed supersedes). Cloud
  tab: **UNASSIGNED**. Search tab across feed and workspaces: **UNASSIGNED**.
- Disconnected / no-Mac shell: C5 (empty states) + C10.

### 1.8 Workspace list
- Live preview lines, unread dot, machine colors, filters and sorts, view options: C5.
- New workspace and groups, group collapse and rename, drag reorder across groups: C5.
- Row actions (read state, rename, customize, close, reconnect), customize sheet: C5.
- SSH computers and their workspaces in the list: C9 + C5.
- Cloud machines in the list: **UNASSIGNED** (Cloud).
- Presence announce of the viewed workspace: C5 over B1.

### 1.9 Workspace detail and surfaces
- Detail container, title menu, terminal picker menu: C5 + D1.
- Terminal surface: A2 + C1 + D1.
- Browser stream surface: C2.
- In-app WKWebView browser, browser mode picker, Mac/SSH tunnel: **UNASSIGNED**.
- Simulator stream surface: **UNASSIGNED** (closest is C3 rd).
- Todo, Markdown and file-preview surfaces: **UNASSIGNED** (C4 moves bytes; nobody renders these).
- Changes hint banner, action toasts: C5 (banner); toasts in A1 design follow-up.

### 1.10 Terminal
- Ghostty Metal surface, render recovery, background suspend: A2.
- Replay / snapshot output path, exactly-once input, send-status pill: C1.
- Shared sizing with the Mac, size sheet, alt-screen notice: C1 (protocol) + D1 (UI).
- Key bar with modifiers, symbols, agent launchers; arrow nub; shortcut customization: D1 (the
  current `TerminalKeyBar` in `CmuxiOSTerminal` is the start).
- Hardware keyboard and IME: A2 (encoder) + D1.
- Gestures (tap to focus, folder tap, pinch zoom with HUD, pixel scroll): D1.
- Selection and copy ("View as Text"), links: D1.
- Keyboard docking and safe areas: D1.
- Terminal composer with attachments and dictation, paste with images: C8 + C4.
- Theme sync from the Mac, font, scrollback size: A2 + C11.
- Drafts per terminal: D1 (client view state).
- Files chip and artifact gallery: C4.

### 1.11 Artifact viewer
- Text with syntax highlight, go to line, search; Markdown; images, PDF, media, Quick Look; share:
  **UNASSIGNED** (C4 downloads; no lane renders).

### 1.12 Changes and diff viewer
- Changes chip, changed-files tree, per-file diff pager with intra-line highlight, copy line or
  hunk: **UNASSIGNED**.

### 1.13 Task composer
- Agent, model, effort, machine, directory picker, group, name, prompt, attachments limits: C8.
- Drafts, templates, failure recovery, model catalog refresh, dictation: C8.

### 1.14 Feed and push alerts
- Feed of agent events with Needs Input filter, full text, inline decisions (permission variants,
  plan approval variants), multi-question answers, quoted reply: C6.
- Legacy notifications feed: Drop (C6).
- Push coordinator, readiness, repair, Allow Push toggle; DEBUG delivery diagnostics: C7 + C11.

### 1.15 SSH
- Hosts with jump host, key, idle timeout, TOFU and changed-key prompt: C9.
- Keys: Secure Enclave generation, import, copy, install with password: C9.
- Workspaces over SSH (plain, tmux control mode, screen, cmux-tui with auto install): C9.
- SFTP browser (preview, download, upload, rename, delete, insert path): C9 + C4.
- SOCKS proxy and local port forward for the browser: **UNASSIGNED** (pairs with the in-app browser).

### 1.16 Cloud VMs and billing
- Cloud tab, create/pause/resume/delete, quota, terminal attach, System VPN: **UNASSIGNED**.
- StoreKit plans, purchase, restore: **UNASSIGNED**.

### 1.17 Settings
- Account, sign out, delete account, team: C11 (A1 ships account, devices, version, sign out).
- What's New archive and post-update sheet: **UNASSIGNED**.
- Connection and computers: B6 + C11.
- Networking (iroh relays and paths): Drop (T1); transport diagnostics (path badge, RTT): C11 + A3.
- Terminal, haptics, display options, scrollback: C11 (+ D1 for terminal toggles).
- Privacy (telemetry consent): A1 (Sentry) + C11 (toggle).
- Diagnostics (verbose log, export, clear, copy support info): **UNASSIGNED** (A1 can own the log
  sink with Sentry; the export UI belongs to C11).
- Legal and support links, erase all data, version: C11.
- DEBUG Developer section and labs: A1 (DEV screen here).

### 1.18 Diagnostics, analytics, crash reporting
- Structured diagnostic log, latency trace: A1 follow-up + C1 (terminal latency).
- Analytics (consent-gated events, uploader, connection outcome reporters): **UNASSIGNED**.
- Crash reporting (Sentry, hang tracking, replay masking): A1 follow-up (3.7).
- DEBUG Copy Logs and Send Feedback: A1 follow-up.

### 1.19 Toasts, accessibility, localization, background
- Toast center (styles, haptics, accessibility): **UNASSIGNED** (should be A1 design system).
- Accessibility labels, Dynamic Type, Reduce Motion, identifiers: every UI lane; audit in D3.
- Localization: shipping app has 9 languages; new catalogs carry the 21 languages of the existing
  CmuxiOS catalogs with en and ja translated and the rest `needs_review`.
- Background: remote-notification mode only; inline reply (C7); render suspend (A2); protected
  data gating (kept auth code).

### 1.20 Gaps no lane covers

1. Cloud VMs: tab, machine lifecycle, quota, Cloud terminal, System VPN extension, Cloud onboarding.
2. Billing (StoreKit plans, purchase, restore).
3. Changes / diff viewer.
4. Artifact and file viewer (syntax-highlighted text, Markdown, images, PDF, Quick Look).
5. In-app browser (WKWebView) with Mac and SSH tunnels (SOCKS, port forward), browser mode picker.
6. Simulator streaming.
7. Todo and Markdown surfaces.
8. Search tab across feed and workspaces.
9. Mac compatibility and version gate UI.
10. Keep Mac Awake.
11. What's New.
12. Analytics, diagnostics export UI, toasts.
13. Remote feature flags (ClientConfig) and App Review demo mode.
14. Deferred sign-in for SSH-only use.

Recommendation: fold 9 into B6, 12 and 13 into A1 follow-ups, 4 and 7 into a new viewer lane with
3, and decide Cloud (1, 2) with the cloud lead. 5 and 6 can wait for D2's transport choice.

## 2. Shell design

### 2.1 Modules (ios/CmuxiOS)

| Module | Owns | Imports |
| --- | --- | --- |
| `CmuxiOSFeatureKit` | seam protocols, value types, mocks, `FeatureSources`, `RealFeatureFactories` | Foundation only |
| `CmuxiOSShell` | `ShellRootController`, `ShellTab`, placeholder screens, Settings, DEV sources, flags | UIKit, SwiftUI, FeatureKit, Design |
| `CmuxiOSDesign` | Home tokens plus `ShellPalette`, `ShellMetrics`, `ShellTypography` | UIKit |
| `CmuxiOSApp` | composition root: `AppContainer`, `RootViewController`, `ShellComposition`, shake DEV menu | everything |

Feature lanes add their module (for example `CmuxiOSFeed`) that imports `CmuxiOSFeatureKit` and
`CmuxiOSDesign`, never a transport and never `CmuxiOSShell`.

### 2.2 Navigation

Signed out: the kept sign-in screen. Signed in: `ShellRootController` (UITabBarController) with
Home, Feed, Workspaces, Compose, Hosts, Settings. On iOS 18 the tabs are `UITab`s and the
controller uses `.tabSidebar` when the `iPadSidebar` flag is on, so iPad gets the sidebar with no
extra code and iPhone keeps the tab bar; iOS 17 uses classic view controllers. Each tab's root is
built once on first selection and kept, so a flag change never rebuilds Home. Selection is client
view state; `select(_:)` is the one entry for pushes and launch arguments. Tint is the label color
(no blue), unselected is secondary label.

### 2.3 Seams

Every seam streams `SourceSnapshot<Value>` (revision, value, connection) and takes intents with an
`IntentKey`, answering with `IntentReceipt` (committed at a revision, or refused). The real
implementation keeps the mirror, resyncs on a revision gap, overlays pending intents and coalesces
to one snapshot per change batch, so screens only diff snapshots by id. While the connection is not
live, intents throw `FeatureSourceError.offline` and nothing queues (U5).

| Seam | Lane | File | Mock |
| --- | --- | --- | --- |
| `FeedSource` | C6 | `CmuxiOSFeatureKit/Feed/FeedSource.swift` | `MockFeedSource` |
| `WorkspaceSource` | C5 | `CmuxiOSFeatureKit/Workspaces/WorkspaceSource.swift` | `MockWorkspaceSource` |
| `TaskComposerSink` | C8 | `CmuxiOSFeatureKit/Composer/TaskComposerSink.swift` | `MockTaskComposerSink` |
| `HostsStore` | B4, C9 | `CmuxiOSFeatureKit/Hosts/HostsStore.swift` | `MockHostsStore` |
| `DeviceRegistry` | B6, C11 | `CmuxiOSFeatureKit/Devices/DeviceRegistry.swift` | `MockDeviceRegistry` |
| `FileTransfer` | C4 | `CmuxiOSFeatureKit/Files/FileTransfer.swift` | `MockFileTransfer` |
| `BrowserStreamSource` (+ `BrowserStreamSession`) | C2 | `CmuxiOSFeatureKit/Browser/` | `MockBrowserStreamSource` |

Mocks share `MockFixtures` (two Macs, one asleep; four feed items; two agents; an SSH host; four
devices) and `MockSnapshotHub`, a public actor lanes reuse for their own mocks: newest-only
buffering, a change runs on a copy so a thrown `MockRefusal` leaves value and revision unchanged,
and `setConnection` previews offline states. `MockFileTransfer` steps progress with
`Task.yield()` (no clock) and can fail after N chunks to exercise resume.

Ownership: every seam is a projection. Feed items belong to `FeedDO`, workspaces to each host's
workspace store, devices to the account registry, SSH and direct host records to the account's
synced store (secrets stay in the device Keychain), browser tab records to the workspace store,
transfers to the session host. Drafts and selection are client view state.

### 2.4 Container and the mock/real switch

`AppContainer` owns `FeatureFlagStore`, `FeatureSourceModeStore` and `realFactories`
(`RealFeatureFactories`, one optional factory per seam). `featureSources(for:)` resolves the modes
once per account: a seam uses its real factory when the mode is real and the slot is filled, else
its mock; `FeatureSources.resolved` records the outcome so screens can mark mock data. A mode change
drops the sources and rebuilds the shell (Home's store survives). Sign-out drops them.

A lane plugs in by filling its slot in `AppContainer.realFactories` and replacing its placeholder
in `ShellContent.controller(for:)`. Nothing else in the shell changes.

Mode precedence: `CMUX_IOS_SOURCE_<SEAM>=mock|real`, then `CMUX_IOS_SOURCES=mock|real`, then the
device's DEV choice, then the build default (mock in DEBUG, real in Release).

### 2.5 Feature flags

`ShellFeatureFlag`: `feedTab`, `workspacesTab`, `composeTab`, `hostsTab` (on in DEBUG, off in
Release until the lane ships) and `iPadSidebar` (on). Precedence: `CMUX_IOS_FLAG_<NAME>=0|1`,
device override from the DEV screen, build default. Flags are client state, never synced. A flag is
deleted when its surface ships. Release builds therefore show Home and Settings only.

### 2.6 DEV surfaces

Settings shows a Developer row in DEBUG; the shake menu gains Feature Sources and Flags. Both open
`DevSourcesView`: a mock/real picker per seam with its lane (and "not registered, serving mock"),
flag toggles (locked when the environment pins them), and Simulate Offline for the mock owners.
`CMUX_IOS_SHELL_TAB=<tab>` selects a tab at launch for screenshots.

### 2.7 Placeholder screens

Each feature tab shows `FeaturePlaceholderViewController`: a UIKit list (compositional list,
diffable, reconfigure on change) built from its seam through `PlaceholderSnapshot.stream`. The first row
names the lane, a one-line summary and the connection state ("Live · mock · Mock data"). The seam
is subscribed in `viewWillAppear` and cancelled in `viewDidDisappear`, so hidden tabs do no work
and idle CPU stays 0%. Settings is a SwiftUI form (low frequency): account, devices from
`DeviceRegistry`, version with DEV tag, sign out with confirmation.

### 2.8 Design tokens

`ShellPalette`: selection and badges are the label color, fills are system grays, status glyphs use
muted system green, orange, red and tertiary label, only on small glyphs. `ShellMetrics`: 4 pt grid
insets and row padding, chip geometry, the sidebar breakpoint. `ShellTypography`: Dynamic Type
styles only. Motion stays on `HomeMotion` (Reduce Motion fades); placeholder diffs do not animate
under Reduce Motion.

### 2.9 Verification

- `CmuxiOSFeatureKitTests` (13 Swift Testing tests: hub revision and coalescing, refusal keeps
  revision, offline refuses without queueing, each mock's rules, factory fallback). They are
  platform-neutral and pass with `swift test` on macOS through a scratch package that links the
  same sources.
- `CmuxiOSShellTests` (flag precedence and visible tabs, mode precedence and persistence,
  placeholder stream mapping): compile for the iOS simulator; they run in CI or on the fleet.
- The whole `CmuxiOSApp` target compiles for `arm64-apple-ios17.0-simulator` with SwiftPM.
- Tagged build `nxa1` through `ios/scripts/reload-cloud.sh`: BLOCKED on 2026-10-06. The same-tag Mac
  leg failed first on the dev backend VM (`cmux-dev-backend-1` SSH timeout), then, with
  `CMUX_DEV_BACKEND_MODE=local`, on fleet capacity (this machine has no
  `~/.config/macfleet/hosts.json`, so the reload fell back to a local build) and the local build
  refused at 33 GiB free (floor 40 GiB). No install, no screenshot. Rerun the same command when a
  fleet slot or disk is available.

### 2.10 Not done here

- Sentry and the diagnostic log sink (PLAN.md lists them under A1): next A1 change, after D3's
  privacy decision on replay masking for Metal and video surfaces.
- URL router for deferred deep links (1.2).
- Toast center (1.19).
- iPad multi-window (out of scope in PLAN.md).
