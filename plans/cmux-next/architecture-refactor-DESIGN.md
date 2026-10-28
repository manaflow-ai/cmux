# cmux NEXT architecture refactor: layers, composition root, signals, Release signposts

Status: design (PL-arch, 2026-10-23), executing in slices (section 9). Lawrence: "let's take this
chance to do the hard refactors and cleanups... I want you to really care about improving this
codebase." Binding rules this applies: repo CLAUDE.md "Package architecture", "Refactor
architecture", "Modern Swift concurrency", "Testability". State ownership between Rust, Swift and
TypeScript is [layer-ownership.md](layer-ownership.md) and [architecture.md](architecture.md); this
file is only about the Swift package graph of `Packages/macOS/CmuxNext`. Perf rows it serves:
[perf-lead.md](perf-lead.md) faults F4, F5 and section 3 cause 6. The inventory and the pre-push
ratchet are PL-guardrails' `codebase-health.md` (not repeated here; when it lands, its numbers win).

Every number below is from tip `184fa32532c` (feat-cmux-next, 2026-10-23), reproduced with
`scripts/cmux-next/arch-layers.py --counts` (manifest only, no build; a report, not a CI gate).

## 1. Baseline

| Measure | Value |
|---|---|
| Swift lines in `Packages/macOS/CmuxNext/Sources` | 589,534 in 6,296 files, 98 targets in one Package.swift |
| `CmuxNextApp` (the executable's library) | 141,651 lines, 1,445 files, 91 package dependencies |
| `CmuxNextApp` files that import no AppKit/SwiftUI/WebKit/QuartzCore | 861 files, 66,470 lines (47 %) |
| `CmuxNextApp` files that name no hub type (section 4) | 670 files, 51,938 lines |
| Hard layer violations (core/service/domain target depends on a ui target) | 32 edges |
| Soft layer violations (service depends on domain) | 12 edges |
| Targets that mix layers (domain or service code next to views) | 23 of 44 ui targets |
| `static let/var shared` declarations | 148 (1,759 `.shared` reads incl. system ones; DesignSettings 170, CEFRuntime 70, ThemeStore 40, GhosttyRuntime 39, CmuxToastCenter 38, LinkRouter 36, CmuxDialogCenter 36) |
| `MainActor.assumeIsolated` | 290: 122 inside `queue: .main` NotificationCenter blocks, 77 in `deinit`, 26 C/run-loop callbacks, 65 other |
| NotificationCenter observer sites | 163 (13 app-defined names; the rest AppKit window/app notifications observed per view instance) |
| `#if DEBUG` blocks | 398 (CmuxNextApp 181) |
| `OSSignposter` users | 6 files, 4 categories; every `debug.*` socket timer is DEBUG-only (AppControl registers none in Release) |

## 2. Target layered graph

Five layers, edges only point down (CLAUDE.md "Refactor architecture"). The layer of each target is
in [architecture-layers.json](architecture-layers.json); a target that mixes layers is placed at
its highest layer and lists the rest under `mixes`.

| Layer | Holds | Targets today (lines) | End state |
|---|---|---|---|
| 1 core | `Sendable` values, IDs, protocol seams, pure rules; may import Foundation/os/CoreGraphics and, for platform value types only, AppKit | 13 (24k): Compat, Wakeups, Actions, Focus, TerminalGeometry, CopyMode, TerminalFind, AgentCursorVisibility, ProcessEnvironment, MallocZone, WorkspaceNaming, TestExitTrace, CCmuxAppFFI | + DesignTokens (from Design), BrowserCore (from Browser), Signposts (new, section 7) |
| 2 service | actors and repositories against the outside world: daemon, sockets, files, cloud, Chromium/WebKit engines | 35 (94k): Daemon, DaemonService, Control, Cloud, Remote, CodeRouter, Mobile, MobileHost, BrowserImport, BrowserHistory, BrowserAutomation, BrowserHost, ChromiumRuntime, ChromiumWarmup, Dictation, ErrorJournal, CrashReporting, RemoteFetch, RemoteLocalhost(+Service), ServerHelper(+Daemon), VSCodeServer, HostPressure, KeepAwake, PhoneAccess, ComputerUse, Stash, AgentUpdates, AgentIntegrations, WorkspaceRepair, WebUpdates, Files, CLIInstall, HostedChief, Diff | + BrowserCEF, BrowserWebKit (two engines behind BrowserCore's protocol, section 8) |
| 3 domain | `@MainActor @Observable` models and Coordinators, one package per feature domain | 5 (31k): Settings, Bridge, ImportSuggestions, AgentCursor, NowPlaying | + Appearance (DesignSettings, ThemeStore), the model halves of Sidebar, Tabs, Layout, Palette, History, Bookmarks, Tasks, Feed, Apps, and the domains lifted out of CmuxNextApp (section 4) |
| 4 ui | AppKit/SwiftUI views; depend on their domain package + core, never on a service | 44 (299k), 23 of them mixed | each UI package depends on its domain package; Design is the UI kit only |
| 5 app | `@main`, AppDelegate, AppServices as the one composition root | CmuxNextApp (142k) | wiring only: constructs concretes, conforms to the host protocols with one-line forwards |

### Measured violations (fix with each slice that touches the edge)

Hard (32), grouped by cause:

1. **Design is three layers in one target** (core values + domain state + UI kit, 39.5k lines; 43
   targets import it). Settings uses 102 Design types, 86 of them from files that import no UI
   framework (DensityPreset, TitlebarStyle, ThemeSpec, Tunable, ...). Edges it causes: Settings,
   WorkspaceNaming, AgentCursor, MobileHost -> Design. Fix: `CmuxNextDesignTokens` (core: values,
   tunables, theme specs; 183 UI-free files, 12.9k lines) and `CmuxNextAppearance` (domain:
   DesignSettings, ThemeStore, backdrop selection) under Design; Design re-exports both
   (`@_exported public import`) while consumers move their imports, then the re-export goes.
2. **Browser is engine + UI in one target** (46.8k): BrowserAutomation, BrowserHistory,
   BrowserHost, ChromiumWarmup, RemoteLocalhostService, NowPlaying -> Browser. Fix: section 8.
3. **Pages and AgentPane are hosts + views**: AgentIntegrations, AgentUpdates, Diff, MobileHost,
   WebUpdates, DaemonService, NowPlaying -> Pages / AgentPane. Fix: the page bridge protocol and
   provider registry (`PageProvider`, `PageRouter`) lift to a `CmuxNextPagesCore` core target; the
   WKWebView/CEF host stays in Pages (ui).
4. **View models live inside UI packages**: Bridge -> Layout, Sidebar, Tabs, Icons;
   DaemonService -> Layout, Apps; ComputerUse -> AgentActivity; Stash -> History; HostedChief ->
   HomeEngine; WebUpdates -> Updater. Fix: the model files (Sidebar `Model/Store/Logic`, Tabs
   items, Layout topology values, History model) move into their domain package; the view package
   depends on it.
`arch-layers.py` also lists each core-labeled target that holds runtime state or I/O (a shared
instance, stored static state, a lock, file or defaults I/O, a notification observation, observable
state) with the first file:line of each kind: a label is what the target holds, never what it
imports (72673e48762 labeled DesignTokens core by its imports, and the report dropped an edge that
had not changed). On 2026-10-23 that list is Actions, Compat, DesignTokens, Signposts, TerminalFind
and Wakeups: each has its state moved out (or is relabeled with the code change that moves it, as the
pre-push layer gate requires) in the slice that touches it. A label is never changed alone.

Soft (12): Control, Diff, KeepAwake, MobileHost, PhoneAccess, RemoteLocalhostService, WebUpdates,
AgentIntegrations, AgentUpdates, ComputerUse -> Settings; DaemonService, KeepAwake -> Bridge.
Settings is a repository (cmux.json load, watch, apply) plus a schema: the schema and value
types go to core with DesignTokens' values, the file repository stays a service; then these edges
are core edges.

Upward (3, 2026-10-23; edges from core to a service or domain target, which the first count missed):
WorkspaceNaming -> Bridge, WorkspaceNaming -> Daemon, AgentCursorVisibility -> AgentCursor.
WorkspaceNaming -> DesignTokens is core -> core by label, but DesignTokens is on the impure-core list
(row B2): the edge is real debt until TunableStore leaves DesignTokens. Core
depends on nothing above core, so the types these targets read move down to core (or behind a core
protocol the higher target conforms to). arch-layers.py lists them, the arch ratchet counts them
(`layer_upward`) and the pre-push layer gate refuses a new one.

## 3. Rules every slice keeps

- Behavior-preserving. A move is `git mv` (history follows) plus access changes. Moved symbols
  that only the App uses become `package` (one SwiftPM package: no `public` surface, no DocC
  burden); `public` only where another Swift package uses them.
- Small pushes: one directory or one seam per commit, landed the same hour (others rebase on us).
- Each slice compiles the `cmux` app and the CmuxNext test targets on the fleet
  (`cmux-ci compile-check --ref SHA --app --package macOS/CmuxNext`), runs the moved code's unit
  tests (`cmux-ci run` / `nx-remote`), regenerates `ci-target-graph.json` when a target is added,
  and runs the existing perf gate on a fleet GUI host when it touches panes, tabs, workspaces or
  themes.
- Off-limits until the owner lands (brief): PL-cef-tab (PaneBrowserTabOpener, TabContentCache,
  CEFSpareWindow, ChromiumWarmup, CEFPaneHost), PL-motion-cef (CEFHostView, WindowOverlayLayer,
  WindowOverlayHost, DividerMouseCatchers, CEFTab), PL-motion-core (ScreenContentView+Motion/+Dock,
  LayoutRootView*, PaneHostView, DisplayLinkDriver), PL-switch (switch paths), PL-typing (Home
  composer, terminal key path, TypingLatencyProbe), PL-ghostty (Terminal integration),
  PL-daemon, PL-engine (WebKit removal steps), a590 (all of CmuxNextSidebar). A hook we need in
  their file is a one-line protocol seam that we send them.
- Each move updates `architecture-layers.json`, the Package.swift header comment and
  `plans/cmux-next/OWNERS.md` (PL-guardrails) in the same push.

## 4. Decomposing CmuxNextApp

### Why it is one target

CmuxNextApp is held together by five hub types, not by its files (which are already small: the
largest top-level file is 582 lines):

| Hub | References | Role today | End state |
|---|---|---|---|
| `AppServices` | 948 in 434 files; 62 `services: self` | service locator: 80+ lazy properties, every feature takes `services:` | composition root: builds concretes once, conforms to each domain's `Host` protocol in `AppServices+<Domain>Host.swift` |
| `AppActionContext` | 191 files (134 of 185 Handlers) | the action handlers' context (services + window + target) | each domain's handlers take `any <Domain>ActionHost`; the context conforms |
| `WindowController` / `WindowManager` | 121 / 37 files | per-window owner | Workbench domain coordinator (last) |
| `PaneController`, `WorkspaceContentController`, `TabContentCache` | 101 / 49 files | pane, workspace and tab content coordinators | Workbench domain (owned by PL-switch, PL-cef-tab: last) |
| `DaemonService` | 115 files | one machine's daemon | already a package; consumers take `any` narrower protocols |

### The seam: one Host protocol per domain

The repo already has the pattern: `StashHost`, `OnboardingServices`, `AccountsServices` ("the App
supplies X"). A domain package declares the narrowest protocol of what it needs from the app; the
App target conforms with one-line forwards; the feature's `init(services: AppServices)` becomes
`init(host: any FooHost)`. Tests pass a fake host (CLAUDE.md "Testability"). No new singleton, no
global container.

### Destination map (directory -> package)

Columns: lines, App types it names outside itself (from a type cross-reference scan), destination.

| App directory | Lines | Outside App types | Destination |
|---|---|---|---|
| TextBox | 384 | 0 | CmuxNextTerminal (ui) |
| Hibernation | 1,100 | 2 | CmuxNextHibernation (domain: the planner, probe answers, the benefit of the doubt, neighbor tabs; moved 2026-10-24); the BrowserHibernation coordinator, snapshots and wakes follow TabContentCache (Workbench) |
| SleepyMode | 328 | 0 | CmuxNextFloating (ui: its overlay windows), its keep-awake hold behind a KeepAwake protocol |
| IconAssets | 291 | 0 | CmuxNextIcons (ui) |
| ServerUpdates | 159 | 0 | CmuxNextDaemonService (presenter seam) |
| LinkHints, Refusals | 190 | 0 | CmuxNextBrowser UI / FocusUI |
| Router, Process | 180 | 0 | CmuxNextHomeEngine / CmuxNextCompat |
| GlobalSearch | 490 | 1 | CmuxNextPalette |
| ErrorJournal, Crash | 1,363 | 1-2 | CmuxNextErrorJournal, CmuxNextCrashReporting (+ a small UI file to Design) |
| Usage, PaletteUsage, Billing, ClipboardReads, WebAuth, GlobalHotKeys, ComputerUse, Popups, Share, SidebarSnapshot | 2.9k | 1 (AppServices only) | their packages, each behind a Host protocol |
| Quit, Vault, Permissions, QuickComposer, SessionTransfer, Pairing | 3.4k | 2-4 | CmuxNextQuit (new, domain), Vault -> History domain, the rest to their packages |
| Cloud, Server, Remote, RemoteView | 11.1k | 8-19 | CmuxNextCloud / CmuxNextServer / CmuxNextRemote / CmuxNextRemoteView |
| Home, Feed, Notifications, History, Bookmarks, Passwords, Apps, Onboarding, Settings, Themes | 23.5k | 6-28 | their domain packages (Notifications and Passwords new), behind Host protocols |
| Pages (providers), TopPages, InternalPages | 9.1k | 10-34 | each provider moves with its domain; PageFactory/InternalPageProvider seam to PagesCore |
| Handlers | 17.8k | 193 | split by domain, moved with the domain against `<Domain>ActionHost` |
| Control (debug and control socket) | 10.1k | 105 | CmuxNextAppControl (above domains, below App): diagnostics only |
| Focus, InputVerification, Drag, Windows, top-level controllers | 39k | 33-354 | Workbench domain + UI (last; owners PL-switch, PL-typing, PL-motion-*) |

Order: leaf-first by "outside App types" (the zero rows first), skipping owned files. Each row is
one to three pushes. Target: CmuxNextApp below 100k lines after the leaf rows and the per-domain
Host protocols, below 40k after Handlers/Pages/Control, and wiring only after the Workbench.

Later item, WebAuth (moved to `CmuxNextPopups/WebAuth` behind `WebAuthHost`, no new package
edge): Popups is a ui package, but it now also holds the WebAuth domain (the request, the
callback rule, the broker Coordinator) and the system Service adapter (`WebAuthSessionHandler` on
the OS `sessionHandler`). Move those to a WebAuth domain/service package below Popups; the
sign-in window stays in Popups as its UI, because it reuses `BrowserPopupWindow`. Open seam
until then: `WebAuthSessionWindows` takes `OffTheRecordProfiles` and `CEFSignInCallbacks` by
`init`, but CEFEngine/CEFRuntime still read `.shared`, so only AppDelegate passing `.shared`
keeps one instance (two sources of truth). The fix (inject both into the engine from
AppServices, then pass the same instances to the sign-in windows) is in the PL-cef area,
routed to session cmux-b6.

## 5. Singletons to injection

148 `shared` declarations at the baseline, three kinds:

1. **Name catalogs and stateless handles** (ContextMenuCatalog, OSSignposter holders): declarations,
   allowed by CLAUDE.md. The daemon capability catalog is `enum DaemonCapability: String,
   CaseIterable` (one case per wire name, 503 reads as `DaemonCapability.name.rawValue`): its
   `tier` is an exhaustive `switch` without a `default`, so `required`, `optional` and
   `unservedByBundledDaemon` are derived from `allCases` and the compiler places every new case.
   This replaced cc7a964ef61's static catalog, whose hand-kept lists were checked by a source regex
   that missed a typed constant (`let name: String = "..."`) and statics in extensions;
   check-daemon-capabilities-fresh.py now reads the cases and the `tier` arms and refuses a
   `default` arm. The lists are closed; the gates are not. `supports`, `require`,
   `missingCapabilities` and `RefusalStrings.needsDaemonCapability` still take any String, so a
   capability that is not a case still compiles at a gate and is in no list: the export,
   check-daemon-capabilities.sh and DaemonCompatibility never see it. catalog_strays
   (check-daemon-capabilities-fresh.py) and rule 4 (check-app-capability-references.py) refuse the
   String statics of the catalog they can read lexically. They are a stopgap with known gaps, not
   the fix: a static in a type nested in an `extension DaemonCapability`, a `typealias` of String,
   a brace inside a string literal in the catalog body (it ends the body early), and a gate that
   names a two-part type (`DaemonCapability.More.orphan`) all pass. The fix is slice B6 (typed
   gates, section 9); when it lands, rule 4 and catalog_strays are deleted. Until the sidebar
   owner (a590) agrees to the rename, the sidebar's six reads use
   `CmuxNextDaemon/Connection/DaemonCapabilities.swift`, a deprecated interim struct that forwards
   four case raw values and declares no capability; a590's follow-up deletes it. Its one piece of
   state, the locked `echoesPlacementShift` static, is gone (review 2): it is a
   `DaemonConnectionConfiguration` field the composition root sets.
2. **Process-wide state** (DesignSettings 170, CEFRuntime 70, ThemeStore 40, GhosttyRuntime 39,
   CmuxToastCenter 38, LinkRouter 36, CmuxDialogCenter 36, NewTerminalTrace, WakeupLedger,
   ExpectedActivity, TunableStore, KeepAwakeService, caches with mutable state): constructed once
   in AppServices, passed by `init`. Transition per singleton: (a) the composition root constructs
   it and passes it to the top owners; (b) readers move to the injected value package by package
   (the PL-guardrails ratchet counts `.shared` reads so none come back); (c) `shared` is deleted.
   Engine runtimes (CEFRuntime, GhosttyRuntime) are owned by PL-cef-* / PL-ghostty: they get the
   injected instance from us, they migrate their readers.
3. **Debug-only state** (DebugCrashes, DebugWindowTransition, UpdateHarnessProbe, LaunchMarkSink):
   owned by the debug control object that registers the `debug.*` methods.

Order: unowned, highest-read first: DesignSettings and ThemeStore (with the Appearance split, so
the injected type lives in a domain package), CmuxToastCenter and CmuxDialogCenter (one
per-window presenter, which also removes O(windows) global scans), LinkRouter, then the per-package
caches.

## 6. NotificationCenter broadcasts to targeted signals

Today a change is broadcast and every instance that registered re-checks itself: O(all) per event
(F5). The 163 sites fall in three classes, each with one replacement primitive:

| Class | Examples (sites) | Cost today | Replacement |
|---|---|---|---|
| A. Point-to-point work sent as a broadcast | `browserChildWindowPagesNeedUpdate` (3 posts from the layout and overlay code, observed by every `CEFHostView` in the window and every floating card) | O(page hosts in the window) per motion frame; the main F4/row-2 cost with Chromium | the poster already knows which hosts moved: a per-window `ChildPageGeometryRegistry` (hosts register on show) and the layout calls `geometryChanged()` on the dirty set only. Files are PL-motion-cef's: design handed to them, not edited by us |
| B. Window/app state observed per view instance | `TerminalSurfaceView` (4 window notifications per surface), `StatusIndicatorView` occlusion (per indicator), `didBecomeKey/ResignKey`, `willClose`, `frameDidChange`, `didBecomeActive` (15 sites) | O(views in the window) per key or occlusion change (Cmd-Tab, row 8) | `WindowEvents`: one observer per window and name, owned by the window, fanning out to subscribers that are on screen; a view subscribes when shown and unsubscribes when hidden; a hidden view reads the current value on show. Lives in Wakeups (core), injected through the window |
| C. Global settings changes | `reduceMotionDidChange` (5), `accessibilityDisplayOptionsDidChange` (9), `speedDidChange`, `inactiveDimDidChange`, `hoverCardsDidChange`, `configDidChange` | O(all pages, terminals, fields) per change, hidden ones included | an `@Observable` value in Appearance read by the view's update path; hidden views are not on the update path and read on show (the "hidden views cost 0" rule, perf-lead F3/F8) |

Mechanical part, for all classes: `addObserver(forName:object:queue: .main) { MainActor.assumeIsolated
{ ... } }` plus the `deinit { MainActor.assumeIsolated { removeObserver } }` pair becomes
`MainActorObservation` (Compat): a token whose closure is `@MainActor` (it asserts main delivery
once, inside the type) and that removes itself when released (`removeObserver` is thread-safe, so
no isolated `deinit`, which macOS 14 cannot back-deploy). That removes up to 199 of the 290
`assumeIsolated` and every hand-written observer `deinit`.

## 7. Release-grade instrumentation (signposts)

Today the frame and action timers exist only in DEBUG builds (`debug.*` methods are not
registered in Release), so nothing can be measured in what users run, and the fleet measures an
unoptimized build. Plan:

- New core target **`CmuxNextSignposts`** (no dependencies): one subsystem
  `com.cmuxterm.app.next`, fixed categories `action`, `motion`, `key`, `switch`, `create`, `cef`,
  `launch`, `stall`, and a catalog of interval names as `StaticString` constants
  (`SignpostName.actionPerform`, `motionFrame`, `keyToFrame`, `switchWorkspace`, `switchTab`,
  `createTab`, `cefPump`, `cefCreateBrowser`, ...). The catalog is the one list of names: the
  Debug benches, the Release benches and PL-telemetry's opt-in nightly hang reports use the same
  strings. The `OSSignposter` values are immutable handles (like `Logger`): `static let`
  declarations, no runtime state of ours, no singleton.
- **Always on.** Signposts of a custom subsystem are enabled by default, so every interval goes to
  the log system in every build, recorder attached or not (about a microsecond per begin or end).
  Messages pass their fields to the `OSLogMessage` interpolation (`ActionSignpostMessage`), so the
  log system formats them only when something reads them. Placed per user event or per frame,
  never per pane per frame. No in-process ring, no socket method, nothing leaves the Mac (no user
  telemetry; PL-telemetry's reports are opt-in and its own design).
- **Synchronous perform to the next commit.** `CommitBoundary` ends an interval at the end of the
  next Core Animation commit: a one-shot main run-loop observer at order 2,000,001, after Core
  Animation's commit observer (2,000,000), installed only while an interval is open (a real
  signal, no sleep). `CommitBoundaryAudit` reads the main run loop's display, layout and commit
  observers (Core Animation's and AppKit's) and flags any after the boundary: `SignpostsTests` in
  a bare process, `CommitBoundaryAppKitTests` with `NSApplication` and a window, and
  `debug.commit_boundary` in the running app, on each macOS major. A boundary asked for inside the
  turn's commit pass sees the wake first and ends with `commit=missed`; readers drop those.
  `ActionRegistry` wraps every run that does work (handler, key window route, a preview revert it
  needs) in `action.perform` (the handler's synchronous time) and `action.commit` (to that
  commit), with `input_age_ms` of the OS event being dispatched for a `user` run, -1 otherwise.
  A gate (confirmation presenter, the palette asking for an argument) is `action.gate`, never the
  action's own interval and never enclosing the run it lets through; it stamps the press's
  timestamp into the invocation (`inputTimestamp`), so a run confirmed in a later turn still
  reports that press's age. The registry gets its timing at the composition root
  (`AppServices` passes `SignpostActionRunTiming`); a test's registry records nothing. This is NOT input to the frame that
  shows the result: work a handler defers (daemon replies, Chromium `CreateBrowser`, later
  SwiftUI updates, a frame client's next frame) commits later. Input-to-result numbers and the
  10 ms budget come from each action's own end signal (`create.*`, `switch.*`, reserved in the
  catalog until their lanes emit them).
- **Paths owned by other lanes** get a one-line hook they add themselves (API in the package,
  message to the owner): motion frame (PL-motion-core, DisplayLinkDriver), key to frame
  (PL-typing), switch (PL-switch, `SwitchFrameTimer` gains the signpost so DEBUG numbers and
  signposts agree), create (PL-cef-tab), CEF pump and window create (PL-motion-cef / PL-cef-tab).
  The existing `stalls`, `tab-switch` and `pane-focus` signposters move onto the catalog.
- **Reader.** `scripts/cmux-next/perf-signposts.py` runs `log stream --signpost --style ndjson`
  for the app's pid during a scenario, pairs begin/end by signpost id and prints p50/p95/max per
  name and argument, the same on a Debug and a Release build (fleet GUI host, report the refresh
  rate). DEBUG counters (`debug.layout_counters` etc.) stay as they are.

## 8. Browser packages: two engines behind one protocol

Lawrence (2026-10-23, via the lead): keep WebKit and Chromium for browser tabs. The protocol
already exists (`BrowserEngine`, `BrowserTab` and 17 capability protocols in `Browser/Engine`).
Target: `CmuxNextBrowserCore` (core: the engine protocols, tab intents, values; no AppKit, no CEF,
no WebKit), `CmuxNextBrowserCEF` and `CmuxNextBrowserWebKit` (service: each engine implements the
protocol), `CmuxNextBrowser` (ui: omnibox, page info, chrome over `any BrowserTab`). The six
service/domain targets that import Browser today depend on BrowserCore only. Most of `CEF/` is
owned by PL-cef-tab, PL-motion-cef and PL-cef-layer, and PL-engine (adb3f74c6afc36a44) works in
the WebKit/engine seam: this split starts after they land, coordinated with PL-engine first.

## 9. Slices, in order

Ordered by perf impact, then risk, then collisions (unowned areas first).

| # | Slice | Perf | Risk | Collides with | Status |
|---|---|---|---|---|---|
| A1 | This doc, `architecture-layers.json`, `arch-layers.py` | - | none | - | landed 415ee799b49 |
| A2 | `CmuxNextSignposts` + `CommitBoundary` + `action.perform` in ActionRegistry + `perf-signposts.py`; existing signposters onto the catalog | high: Release numbers for every action | low | none (Actions unowned); hooks for owners by message | action.perform/commit landed; owner hooks and old signposters open |
| A3 | `MainActorObservation` (Compat) and migration of unowned observer sites | medium (code health, -assumeIsolated) | low | skip owned files | 42 files done; left: queue:nil observers and the no-activate guard (moving them to queue:.main changes when they run), owned files |
| A4 | (WindowKeyFamily landed: one key tracker per window for the inactive wash) `WindowEvents` per-window fan-out; migrate unowned class-B sites (StatusIndicatorView, Design, Pages, AgentPane); hand TerminalSurfaceView and Sidebar sites to PL-ghostty and a590 | medium (row 8 Cmd-Tab O(views)) | medium | Terminal, Sidebar by message | |
| A5 | Class C: reduceMotion / accessibility / speed / inactive-dim as Appearance observables, hidden views off the path | medium (F3/F8 hidden cost) | medium | none for Design/Pages/AgentPane leaf files | |
| B1 | CmuxNextApp leaf directories (zero-outside rows of section 4) | - (lines) | low | none | TextBox, Router, Refusals, Process done (SleepyMode stays: its raw font sizes are baselined at the App path) |
| B2 | `CmuxNextDesignTokens` split of Design (re-exported) | - (unblocks 4 hard edges) | medium (43 importers, but re-export keeps sources) | WindowOverlayHost stays in Design | landed 72673e48762 (117 files, 6.6k lines); WorkspaceNaming off Design. DesignTokens stays labeled core, but it is not core by what it holds, and arch-layers.py lists it under impure core: it holds TunableStore.shared behind a lock with its file writer, RecoveryDraftStore (FileManager), LowPowerMode (a shared instance and a NotificationCenter observation), MuseumArtSearch (URLSession) and BackdropRevision (@Observable). It becomes core when those move out (TunableStore injected per the lead decision, RecoveryDraftStore to the Quit domain, BackdropRevision to Appearance). That slice changes DesignTokens' code, so it can relabel it in the same push if any state stays; until then WorkspaceNaming -> DesignTokens (WorkspaceAutoNameTunables reads a Tunable) is a core -> core edge into a stateful target |
| B3 | `CmuxNextAppearance` with injected DesignSettings/ThemeStore (singletons 2 of 148, 210 reads) | low | medium | theme paths: run perf gate theme scenario | BackdropRevision owned by ThemeStore (bc6284f47b6); ThemeStore/ThemeScope injection next |
| B4 | Host protocols + moves for the AppServices-only rows, then Quit, Cloud, Server, Remote, History, Feed, Bookmarks, Notifications | - | medium | check owners per directory | |
| B5 | Handlers and page providers by domain | - | medium | Handlers touched by PL-cef-tab (BrowserHandlers, PaneTabBarHandlers, HomeDockOpens, ChatColumnPlacement, TabLifecycle): those last | |
| C1 | Browser split (section 8) | enables engine work | high | PL-cef-*, PL-motion-cef, PL-engine | after they land |
| C2 | Workbench domain (WindowController, PaneController, WorkspaceContentController, TabContentCache) | - | high | PL-switch, PL-cef-tab, PL-motion-* | after they land |
| C3 | Sidebar model/view split | - | medium | a590 owns: proposal to them | by a590 |
| B6 | Typed capability gates: `supports(_: DaemonCapability)` and `DaemonCapability` overloads of `require`, `missingCapabilities`, `RefusalStrings.needsDaemonCapability` and `ActionFailure.needsDaemonCapability`; String only at the wire decode and for PEERS (other servers' capabilities); then delete rule 4 of check-app-capability-references.py and catalog_strays (review of arch-b3, 2026-10-23: the regex checkers have gaps, section 5) | - (closes the capability hole) | medium: about 270 gate sites (266 pass `DaemonCapability.<name>.rawValue` today), many in owned areas (sidebar, new-tab path, Home, Notifications) | a590 (sidebar reads; deletes DaemonCapabilities.swift first), PL-cef-tab (PaneBrowserTabOpener), each gate site's owner by message | open: routed to session cmux-b6 (PL-arch) |

## 10. Results

Before/after per batch (CmuxNextApp lines, singletons, assumeIsolated, observers, hard/soft
violations), sha ranges on feat-cmux-next:

| Date | Batch | sha range | App lines | shared | assumeIsolated | observers | hard / soft |
|---|---|---|---|---|---|---|---|
| 2026-10-23 | baseline | 184fa32532c | 141,651 | 148 | 290 | 163 | 32 / 12 |
| 2026-10-23 | 1: A2 signposts, B1 4 dirs, A3 24 files | 1549981b654..5846e103ece | 141,393 | 148 | 253 | 130 | 32 / 12 |
| 2026-10-23 | 2: review-1 fixes, A3 18 files, B1 53 leaf files, A4 WindowKeyFamily | this push | 139,814 | 148 | 228 | 108 | 32 / 12 |
| 2026-10-23 | 3: DaemonCapabilities static, B2 CmuxNextDesignTokens, Release-test compiler crash fixes, generic-class deinit rule, bench config, signpost port, B3 BackdropRevision | cc7a964ef61..bc6284f47b6 | 140,765 (base grew) | 147 | 231 | 106 | 31 / 12 |
| 2026-10-23 | 3 recounted: every edge to a higher layer counts (core -> service/domain as upward); core targets that hold state are listed (DesignTokens among them) | review fix of 72673e48762 | 141,345 | - | - | - | 31 / 12, 3 upward |

App lines are measured at each tip, so other lanes' additions count too (the base grew about 1,000
lines during batch 2; batch 2 moved 2,399 lines out). The hard/soft edges are unchanged so far:
the moves only used existing edges by design (B2, the DesignTokens split, removes the first four).
Batch 3's 31 did not tell the whole story: B2 relabeled an edge instead of removing it (WorkspaceNaming
-> Design became WorkspaceNaming -> DesignTokens, with DesignTokens called core while it holds state),
and the report never counted a core target's edges to service or domain targets. The batch 3 tip has
31 hard edges into ui targets and 3 upward edges (arch_counts' class for core -> service or domain):
WorkspaceNaming -> Bridge, Daemon and AgentCursorVisibility -> AgentCursor. WorkspaceNaming ->
DesignTokens is not counted as upward because DesignTokens keeps its core label (the layer gate
accepts a relabel only with the code change that moves the target). The impure-core list reports
DesignTokens instead, and the edge leaves when TunableStore moves out (row B2). Graph read statically
from Package.swift with arch_counts.parse_manifest.
