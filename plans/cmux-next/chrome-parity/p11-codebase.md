# p11-codebase: a Chrome-style component codebase for cmux-next (F13)

Program owner: p11 fixer. Measured at `/Users/lawrence/fun/wt/chrome-parity`, tip `772cdfc45ac`
(2026-10-25), with rg, find and git only. This spec applies the three adversarial reviews to the
p11 design. Each review finding is listed in "Review disposition" with what was done.

Goal: CmuxNextApp (143,911 lines, 1,409 files) becomes a composition root of at most 10k lines in
four directories (Composition/, Hosts/, Launch/, Menus/). There are 0 stateful singletons, 0
app-internal broadcast names, 0 broadcast observers outside one Environment adapter, 0 hard, soft
or upward layer edges, 0 mixed-layer targets, and a Chrome-style checkdeps refuses each regression
before push. Outcome (F13): an incremental Debug build after a leaf edit takes < 30 s on the
fleet, measured by a new edit-loop bench that runs at hour 0 and at the end.

---

## 1. Chrome reference

1. **checkdeps / DEPS** (buildtools/checkdeps/README.md). "DEPS files specify which files the
   sources in a directory tree may include". `include_rules` use `+` (allow), `-` (deny, with a
   narrower `+` re-allow) and `!` (allowed for now; presubmit warns on each NEW include that only
   `!` permits). `specific_include_rules` map file regexes to rules and apply first. A DEPS file
   covers its subtree with an implicit allow of its own directory; `noparent=True` drops inherited
   rules; `new_usages_require_review=True` makes an OWNER approve each new entry. In Chrome, a
   moved file is checked under the rules of its new directory.
2. **gn check** (gn docs/reference.md). Includes must match `deps`/`public_deps`; headers outside
   `public` are private; `visibility` says who may depend on a target; `assert_no_deps` forbids
   transitive edges; `testonly` targets cannot be linked into production.
3. **//components/README.md**. Components "cannot depend on the higher layers"; they split by
   process first (`browser/`, `common/`, `renderer/`, plus `core/`), and "These subdirectories
   should have DEPS files with the relevant restrictions in place". Code shared with iOS gets its
   dependencies injected; "It is not an acceptable solution to conditionally depend".
4. **docs/chrome_browser_design_principles.md**. "Do NOT add to //chrome/browser/BUILD.gn:browser"
   (the god target is closed). "Global functions that access non-global state are disallowed"
   (`browser_finder`, `chrome::FindLastActive` cannot be called from modularized features).
   "Lazy instantiation is an anti-pattern". "Dependencies should be injected during
   construction". "Don't use class Browser ... god-object". A tab can move between windows, so
   tab-scoped state must not hold window-scoped state.
5. **Scoped composition roots**. `GlobalFeatures` (process; Init / PostBrowserProcessInit /
   PostMainMessageLoopRun; protected `Create*()` hooks; `ReplaceGlobalFeaturesForTesting`),
   profile-keyed services (`KeyedService`, built per BrowserContext), `BrowserWindowFeatures`
   (per window; `TearDownPreBrowserWindowDestruction`) and `TabFeatures` ("Do not add more public
   accessors. Instead use the UnownedUserData design pattern"). Feature code sees
   `BrowserWindowInterface` / `TabInterface` (public/ targets), never `Browser`. The one sanctioned
   process global is `g_browser_process`, which owns GlobalFeatures.
6. **Singletons and static init**. base/memory/singleton.h: "PLEASE READ: Do you really need a
   singleton?". `-Wglobal-constructors`, `-Wexit-time-destructors`,
   `tools/mac/dump-static-initializers.py`. PRESUBMIT.py `_BANNED_CPP_FUNCTIONS` /
   `_BANNED_OBJC_FUNCTIONS` (BanRule: regex, paths, error or warning), the model for symbol_rules.
   Deferred start-up work runs through `AfterStartupTaskUtils` (queued, prioritized), not in one turn.
7. **Broadcast removal**. Chromium deleted `content::NotificationService` (crbug.com/268984) for
   typed observers on the owner: `base/observer_list.h` (default policy `ALL`, default reentrancy
   `kDisallowReentrancy`, `check_empty`, `CheckedObserver`), `base/scoped_observation.h` ("When a
   ScopedObservation is destroyed, it unregisters the observer"), `ObserverListThreadSafe` (posts
   to each observer's sequence) and `base::RepeatingCallbackList` with subscription tokens.
   Per-object observers (`WebContentsObserver`, `views::ViewObserver`) stay; only the process-wide bus
   went. Hidden pages still get lifecycle transitions (freeze, resume, discard); only work is throttled.
   File watching goes through one `base::FilePathWatcher`; the clipboard through `ui::Clipboard`;
   the command line and features are parsed once (`base::CommandLine::Init`, `base::FeatureList`).
8. **Build speed**. docs/component_build.md: "many changes only require that the local shared
   library be linked"; debug defaults to `is_component_build=true`; and duplicated globals across
   components "will wreak havoc". Swift analogues: small modules, `package` access with
   InternalImportsByDefault (on), MemberImportVisibility (SE-0444),
   `--explicit-target-dependency-import-check=error` (our `gn check`), mergeable libraries in
   Debug (our component build).

## 2. cmux today (verified at 772cdfc45ac)

- **Size.** Sources has 112 target dirs; Package.swift is 1,789 lines, 157 target constructors.
  CmuxNextApp: 143,911 physical lines, 1,409 files, 246 top-level files, 85 subdirectories
  (Handlers 18,704/191 files, Control 10,701, Pages 7,787, Windows 7,026, Focus 6,794, Cloud
  5,679, Home 4,491, ...). App tests: CmuxNextAppTests 1,086 files, 117,446 lines; 587 files use
  `@testable import CmuxNextApp`; 191 `AppServices(environment:` constructions in tests.
- **App-size cap.** `scripts/cmux-next/app-size-baseline.txt` = 135,848 < 143,911 physical.
  `check-app-size.sh` passes in `--base` mode when source lines did not grow (line ~77), so the
  base is not red, but the App grew about 8k lines in five days under that rule.
- **Hubs.** `AppServices` 1,022 refs/477 files; 872 `services: AppServices` params;
  AppServices.swift has 90 `lazy var`; the whole App has **155** `lazy var` (HomeService 10,
  WindowController 5, ViewerService 5, DiffPageService 4, WindowManager 3, TabContentCache 3,
  WorkspaceContentController 3, ...). AppActionContext in 199 files; 530 `registry.bind(` calls
  in Handlers. WindowController 243 refs/127 files, PaneController 251/109, TabContentCache
  81/53, WorkspaceContentController 63/32, WindowManager 67/39. Ambient "current" state:
  `routedDaemon`/`activeDaemon` 75 refs in 31 files; `NSApp.keyWindow/mainWindow` 76 refs.
- **CmuxNextAppCore** (5 files, #25042/#25048, 2026-10-24): an `AppServicesProviding`
  god-protocol plus narrow seams (MachineWorkspaceProviding, PageActionProviding, WorkspaceClose,
  WorkspaceSpawn); not in architecture-layers.json; depends on ui targets AgentPane and Sidebar.
- **Singletons.** 134 `static (let|var) shared` declarations in 34 targets; arch_counts
  `stateful_singletons` 199, `global_mutable_statics` 476 (172 in MessagesLab Vendor). Names other
  than `shared` exist (`SidebarDocStore.current`, `TerminalEnvironment.instance`,
  `UpdateHarness.current`, `ChiefProfilePageRelay.shared(for:)`, `LowPowerMode.system`).
  `AppProcessRoot.shared` (11 refs) is the entry-point root. OS globals: `NSApp` 304 lines,
  `NSWorkspace.shared` 167, `ProcessInfo.processInfo.environment` 170, `NSPasteboard.general` 56,
  `Bundle.main`/`UserDefaults.standard` 146, `FileManager.default` 792.
- **Broadcasts.** 12 `Notification.Name(` in CmuxNext (11 app names + distributed
  `com.apple.accessibility.api`), 2 more in first-party Shared (MessagesLab reduceMotionDidChange
  x2). 27 `.post(name:` sites. Observer registrations about 190 (arch_counts observer_sites 340
  incl. Shared): of these, about 80 are broadcast registrations (no `object:` or `object: nil`);
  the rest are object-scoped (a window, a scroll view, KVO on one WKWebView/AVPlayer) and are the
  ScopedObservation analogue (`CmuxNextCompat/MainActorObservation.swift`). Ad-hoc buses:
  ControlEventBus, TreeChangeBroadcaster, PresentationChangeSubscribers, 61 callback-array
  subscriber lists, 7 file-watcher implementations. 202 `MainActor.assumeIsolated` (151 outside adapters).
- **Layers.** 33 hard, 12 soft, 3 upward edges; **29** targets carry `mixes` (incl.
  CmuxNextPages). Import checking already exists: `scripts/cmux-next/check-package-dependency-lists.py`
  (IMPORT_BASELINE of about 37 pairs incl. CmuxNextBridge->CmuxNextDesign; CI step
  cmux-next.yml:1650) and a `// sorted:` marker on 2 dependency lists. 5 `@_exported`.
  MemberImportVisibility off. Swift settings: `uiSwiftSettings` has `.defaultIsolation(MainActor.self)`,
  `daemonSwiftSettings` does not. SwiftPM warns on unhandled files in target dirs (Package.swift:1048
  already excludes a README for that reason).
- **Strings.** CmuxNextApp has 44 xcstrings tables and 721 `bundle: .module` lookups; `.module`
  rebinds to the new target's bundle on a move, and a missing key falls back silently.
- **Path-keyed baselines.** About 700 entries name CmuxNext source paths (crash-allowlist.json,
  main-actor-work-baseline.json, localization-debt-baseline.json, no-swiftui-allowlist.txt,
  lint-namespace-types-ratchet.txt, swift-type-scale-baseline.tsv, check-menu-actions-baseline.txt,
  state-roots-baseline.tsv, env-write-allowlist.json, perf-hot-benches.json, OWNERS.md,
  scripts/ci/cmux_next_route.py, cmux-next-motion-golden.yml paths, check-crash-safety.sh,
  check-no-bench-hooks.sh).
- **Guardrails.** guardrails.py ROOT_FILE matches only top-level AppDelegate/CmuxNextApp/AppServices
  files; MOVE_SHARE = 0.8 credits a new file as a move only when 80% of its lines moved.
  lint_swift_namespaces.py refuses all-static `public`/`package` types (App has ~476 enums, 95
  `enum XHandlers { static func bind }`).
- **Cycles.** A regex type-reference scan puts 169 of 216 App directory/family groups in one SCC
  (115 after removing the 6 hubs). Swift has no cross-module forward declarations: a leaf-first
  order by hub count does not compile without explicit cycle cuts.
- **Chromium.** cef-helper-app-DESIGN.md moves Chromium out of process; the wire prototype is in
  `CmuxNextBrowser/CEF/ChromiumHost/` (Frame, Launcher, Connection, Session, PageView).
- **Rust.** cmux-tui has 77 crates, no crate layering check; cmux-tui-core about 385k lines; 245
  global statics. The crate-split lane (refactor-log/crate-split.md) idle since 2026-10-11.
- **Build.** No leaf-edit measurement exists. hq-11 estimate: App re-emit about 8.7 s at 144k lines
  before type checking.

## 3. Target design

### A. Layers (base < components < content < chrome/browser < ui)

Keep core < service < domain < ui < app from architecture-layers.json, the strict DAG, and the
counted rules (hard, soft, upward = 0). ui -> service stays legal (Chrome ui -> components/core).
Every `mixes` target is split: the UI-free half goes to `<Feature>Model` (domain) or
`<Feature>Core` (core). Inside a mixed target, UI-free subdirectories get a DEPS with
`-AppKit -SwiftUI -WebKit -QuartzCore` on day 1 (Chrome's components/foo/core DEPS), before the
target split. Process is the first split axis for Chromium: `CmuxNextChromiumWire` (core) holds
the frames both the app and the host process use.

New targets are created in one push (task 007) only where no existing target at the right layer
fits (resolved by task 000a and written into architecture-refactor-DESIGN.md section 4):

- core: CmuxNextSignals, CmuxNextSettingsSchema, CmuxNextPagesCore, CmuxNextIconsCore,
  CmuxNextDaemonWire, CmuxNextActionsCatalog, CmuxNextChromiumWire.
- domain: CmuxNextAppearance, CmuxNextEnvironment, CmuxNextWorkbenchInterface, CmuxNextAgentPaneModel,
  CmuxNextLayoutModel, CmuxNextTabsModel, CmuxNextSidebarModel, CmuxNextHistoryModel,
  CmuxNextHomeModel, CmuxNextAgentActivityModel, CmuxNextQuit, CmuxNextWorkbench.
- service: CmuxNextSettingsStore.
- ui: CmuxNextWorkbenchUI, CmuxNextAgentTabs, CmuxNextBrowserFeatures, CmuxNextCloudFeatures
  (CmuxNextCloud is service; views cannot go there), CmuxNextRemoteMachines (same for
  CmuxNextRemote), CmuxNextNotifications, CmuxNextAppControl, CmuxNextPresenters.
- Test-support (testonly): CmuxNext{DaemonService,Workbench,BrowserFeatures,CloudFeatures,AgentTabs}TestSupport.
- Not created: CmuxNextInput (Focus model goes to CmuxNextFocus, views to CmuxNextFocusUI);
  a "ChromiumRuntime" type (the injected instance stays `CEFRuntime`; CmuxNextChromiumRuntime is
  the installer); HostPressure goes to existing CmuxNextHostPressure.
- Each target that receives former App code keeps `uiSwiftSettings` (default MainActor
  isolation) unless a pre-pass adds explicit `@MainActor`, so no isolation changes silently.
- Test targets are declared only in the commit that moves real tests into them (no empty smoke
  tests; CLAUDE.md "never add CI tests").

### B. Composition by scope (GlobalFeatures / KeyedService / BrowserWindowFeatures / TabFeatures)

CmuxNextApp keeps four directories, at most 10k lines:

- `Composition/`: `AppFeatures` (process), `MachineFeatures` (one per daemon connection, built per
  MachineRegistry entry like a KeyedService), `WindowFeatures` (per window: ToastPresenter,
  DialogPresenter, WindowEvents, overlay hosts, key router), `WorkspaceFeatures`/`TabFeatures`
  (per workspace and tab, survive a tab move between windows, hold no window state). Each scope
  has `init` (construct only), explicit phases, `tearDown()` before its view goes, and a written
  destruction order. The action-target resolver lives here.
- `Hosts/`: `AppFeatures+<Domain>Host.swift`, one-expression forwards only, and only for
  embedder-to-feature (upward) calls (Chrome's FooDelegate/FooClient). Feature-to-feature
  dependencies are a Package.swift edge on the other package's public interface, or a
  `FeatureSlots` lookup (`Foo.from(tab)`, UnownedUserData). A Hosts forward that calls another
  feature's controller is refused.
- `Launch/`: main, AppDelegate, CmuxApplication, `ProcessRoot` (the one sanctioned process
  global, like `g_browser_process`; it owns AppFeatures; readable only from Launch/ and named C
  trampolines), launch phases.
- `Menus/`: main menu built from per-domain menu contributions.

Rules:

1. Stateful objects are built once by their scope. No `lazy var`; `init` does no I/O and no
   static initializer runs I/O. Phases: construct, didFinishLaunching, afterFirstFrame,
   willTerminate. `afterFirstFrame` enqueues each `start()` as its own background-priority main
   task, at most one per frame (AfterStartupTaskUtils), so the turn after the first frame stays <= 4 ms.
2. Tests replace one feature through `AppFeatures.Factory` (a struct of per-feature closures,
   production by default; Chrome's `Create*()` hooks), or the whole object
   (`ReplaceGlobalFeaturesForTesting`). The default test factory stubs CEF, Ghostty, the daemon
   and web bundles.
3. Each domain package declares `<Domain>Host` / `<Domain>ActionHost` (consumer-owned, narrow).
   Feature code uses `WindowInterface`/`TabInterface`/`PaneInterface` from
   CmuxNextWorkbenchInterface, never WindowController, PaneController, TabContentCache,
   WorkspaceContentController or WindowManager. Handlers are instance types:
   `struct CloudActions { let host: any CloudActionHost; func bind(into: ActionRegistry) }`
   (never caseless static enums, which the namespace lint refuses once `package`).
4. No ambient lookups: no stateful globals by any name, no `?? .app`, no `static func app(`, no
   `routedDaemon`/`activeDaemon`, no `NSApp.keyWindow`/`mainWindow` outside the resolver and the
   Environment adapter. An action invocation carries its target window, machine and tab, resolved
   once by the registry. OS globals (NSApp, NSWorkspace.shared, NSPasteboard.general,
   ProcessInfo environment, Bundle.main, UserDefaults.standard) are read only in
   CmuxNextEnvironment adapters (and Launch/) and reach features through their Host.
5. `AppServices` and `AppActionContext` disappear outside Composition/Hosts. CmuxNextAppCore is
   dissolved: its narrow seams go to CmuxNextWorkbenchInterface, AppServicesProviding is deleted.

### C. Signals (NotificationService removal)

- `CmuxNextSignals` (core): `Signal<Event>` with subscriber slots in a CmuxNextCompat `Mutex`
  (unsubscribe from any thread; no isolated deinit, so macOS 14 works); `policy: .existingOnly |
  .all`; `reentrancy: .disallow` by default (Debug assert, Release counter); a Debug check that an
  owner's deinit leaves no live subscriptions (`check_empty`); `deliver(on:)` for off-main
  producers that coalesces to one main turn (ObserverListThreadSafe); `SignalSubscription` token
  that unregisters on release (ScopedObservation). PresentationChangeSubscribers is rebuilt on it
  or deleted.
- `CmuxNextEnvironment` (domain): the only place that registers **broadcast** observers
  (NotificationCenter with no object, NSWorkspace center, distributed center, CFNotificationCenter,
  FSEvents, file-system dispatch sources). `AppEvents` registers one observer per process-wide
  name; `WindowEvents` one per window name per window. Lifecycle events (willClose, screen,
  backing scale, occlusion, visibility) reach every subscriber; repaint/appearance events are
  coalesced and skipped for subscribers that are not mounted in the shown workspace of their
  window, and those implement `resync(revision:)` on show. `AppearanceEnvironment`
  (@Observable): reduceMotion, reduceTransparency, increaseContrast, differentiateWithoutColor,
  scrollerStyle, animationSpeed, inactiveDim, hoverCards. `FilePathWatcher`: one FSEventStream
  per root. `Clipboard`, `ApplicationEnvironment`, `WorkspaceServices`, `LaunchEnvironment`,
  `AppBundleInfo`, `Preferences` adapters.
- Object-scoped observation (an `object:` the owner holds; KVO on an owned object) stays legal in
  its owner through MainActorObservation, as Chrome keeps WebContentsObserver.
- All 13 app-defined Notification.Names (11 CmuxNext + 2 Shared) are deleted; point-to-point work
  is a direct call, a Signal on the owner, or a per-window dirty set.

### D. checkdeps (scripts/cmux-next/checkdeps.py; pre-push and `--all`; never a new CI job)

- **Location.** DEPS files live in a mirror tree `Packages/macOS/CmuxNext/deps/<Target>/[subdir/]DEPS`
  (and `Packages/Shared/<Pkg>/deps/...`), so SwiftPM sees no unhandled files and Package.swift
  needs no `exclude:` lines. Syntax: Python literal, `ast.literal_eval`, Chromium field names.
- **Sources of truth.** Allowed module edges and each target's layer come from
  architecture-layers.json plus Package.swift; DEPS hold only `-`, `!`, `specific_include_rules`,
  `noparent`, `visibility` (incl. testonly: TestSupport targets visible to test targets only),
  `assert_no_deps` (targets or frameworks, transitive), `symbol_rules` and
  `new_usages_require_review` (an `Owner-OK: <owner> <target>` trailer from OWNERS.md is required
  for a new edge into CmuxNextSignals, CmuxNextEnvironment, Composition, CEF targets, Terminal,
  Sidebar). No `Module.Symbol` include form; scoped `import struct M.S` is checked only after
  MemberImportVisibility is on.
- **Checks.** (a) every import form (public/package/internal/@testable/@preconcurrency/
  `import struct`) is legal for its file; (b) import-undeclared, built on the parser and alias map
  of check-package-dependency-lists.py, whose IMPORT_BASELINE becomes `!` rules and is deleted;
  (c) visibility; (d) transitive assert_no_deps through arch_counts.parse_manifest and the local
  package closure (Shared, iOS, CmuxUpdater manifests included); (e) symbol_rules on
  comment/string-blanked code, with type-based rules from `arch_counts.analyze` for
  stateful singletons, global mutable statics, broadcast observers and assumeIsolated (so a
  rename cannot dodge); (f) a cross-target move is re-checked under the destination's rules
  (same-target renames are not new).
- **Root symbol rules** (`deps/DEPS`): `\bAppServices\b|\bAppActionContext\b` outside
  CmuxNextApp/(Composition|Hosts); `Notification\.Name\(`; broadcast observer/post APIs outside
  CmuxNextEnvironment; stateful singletons and global mutable statics (arch_counts, by type);
  side-effecting static initializers (`static let x = ...FileManager|UserDefaults|ProcessInfo|
  Bundle.main|NSWorkspace|Data(contentsOf|DispatchQueue(`); `\?\? \.app\b|static func app\(`;
  `@_exported`; `lazy var` in first-party Sources; `\broutedDaemon\b|\bactiveDaemon\b`;
  `NSApp(lication\.shared)?\??\.(keyWindow|mainWindow)` outside the resolver;
  `\bNSApp\b|NSWorkspace\.shared|NSPasteboard\.general|ProcessInfo\.processInfo\.environment|
  Bundle\.main|UserDefaults\.standard` outside Environment and Launch/; `ProcessRoot\.` outside
  Launch/ and named trampolines; WorkbenchInterface hub concretes outside Workbench, WorkbenchUI
  and the App.
- **Ratchet.** Today's debt is bootstrapped as `!`. Pre-push refuses a NEW line that only `!`
  permits (Chrome warns; we ratchet; escape is the existing dated exception, no env skip).
  arch-ratchet.json row `deps_temporary_allowances` only goes down. Vendored MessagesLab code is
  third_party: checks off, its own counted row.
- **Compiler backstop** on the fleet: MemberImportVisibility on every swiftSettings array and
  `swift build --explicit-target-dependency-import-check=error`.

### E. Build speed (F13)

`scripts/cmux-next/bench-edit-loop.py` runs only as a fleet step. Warm Debug build of `cmux`,
then per probe a body-only edit (and a `package` signature edit for packages), rebuild, revert;
records wall time, recompiled-file count (`-driver-show-incremental`), emit-module and link time,
`-showBuildTimingSummary` phases, 3 repeats p50/max. Probes: Compat leaf, SidebarModel, Tabs view,
a Hosts file, AppFeatures, the hubs (Design, Daemon, Settings, Actions), a test-target edit
(`swift build --build-tests`) and the CmuxNextAppTests rebuild after an App edit. The hour-0
baseline decides the order: if App emit dominates, App moves first; if link, task 196; if the
@testable test module, test moves. A Rust twin measures cmux-tui. Hub splits (Daemon wire,
Actions catalog, Design presenters) and a per-target size cap stop new god targets. Release
cross-module optimization is confirmed and every perf-hot move names its Release bench.

### F. Throughput for hundreds of agents on one branch

- **Queue generator.** `app-graph.py` (index store from one fleet build) condenses App groups into
  SCCs, emits the topological move order, each group's destination, its exact Host surface, the
  cycle cuts, and each destination's final dependency list.
- **Two commits per group.** (1) seam-in-place inside the App, generated by `gen-host-seam.py`
  (`services:` -> `host: any XHost`, hub concretes -> interfaces, `registry.bind(` lines
  byte-identical); (2) a pure move by `move-app-files.py` (git mv of code and its tests, path-keyed
  baselines rewritten, xcstrings moved or split, OWNERS/architecture-layers updated). The move
  keeps MOVE_SHARE credit and code-quality.md R1/R4.
- **Manifest.** Package.swift is FREEZE (R10). Task 007 lands every destination with its final
  dependency list in one tokened push; later manifest edits (test targets, leftovers) are batched
  hourly by one manifest agent (task 019). Move tasks never touch Package.swift.
- **Merge train.** `move-train.py` stacks ready commits, runs one fleet compile-check that also
  builds test targets, bisects on red, lands the green prefix. Fleet compile slots, not agents,
  are the limit.
- **Generated files.** arch-ratchet.json only via `--update`; ci-target-graph.json regenerated on
  the fleet; never hand-merged.
- **Do-not-touch list** (COORDINATION.md): CEF/** and CmuxApplication.swift (cef-helper program),
  Focus/KeyRouter* and the key path (typing), TabContentCache*, PaneController*,
  Windows/WindowOverlayLayer and motion files (switch, motion), instrumentation types
  (NewTerminalTrace, ChatOpenTrace, TypingLatencyProbe, WakeupLedger, ExpectedActivity). Their
  tasks run in Phase W only on the owner's release line.
- **App closed to growth** for every program from hour 0 (Chrome "Do NOT add to :browser").

### G. Schedule (72 h)

| Window | Work |
|---|---|
| H0-H8 | Phase 0: 000a-000e, 000g, 000h, 000i, 001-003, 006-009, 010-012, 019, 243, 260, 262, 264, 265, 266 |
| H8-H48 | Waves in parallel: singletons (Q2), OS seams (Q15), broadcasts and buses (Q3, Q3b, Q4), layer splits (Q5), leaf App moves (Q1) in graph order, handlers (Q10), lazy (Q12), statics (Q2b), hub splits (Q17), Rust (Q18). Checkpoint at H48: App <= 60k, every unowned domain out |
| H48-H66 | Phase W (owner-gated): Workbench, Focus, Windows, Drag, NewTab, CEF moves; composition (180-182); test sweeps; MIV and strict import check |
| H66-H72 | 198: retire `!` rules, ratchet to zero, final benches |

## 4. Rules for implementers and reviewers

1. One task = one implementer unit, <= ~400 changed lines excluding renames; split by the task's
   machine queue if larger.
2. Moves are two commits (seam-in-place, then pure move by move-app-files.py). Never rewrite
   `registry.bind(` lines in a move. Tests move in the same commit as their subject.
3. Access: moved types stay `internal` unless another target uses them; never `public` without a
   cross-package consumer. Moved files keep their isolation (uiSwiftSettings or explicit @MainActor).
4. No new singleton, `lazy var`, broadcast name, broadcast observer, ambient lookup or
   `@_exported`, in any target (checkdeps).
5. Each fix with behavior change carries a regression test that fails without it, run by the
   agent on the fleet; no new CI gate, job, step or test (Lawrence 2026-10-23). Retargeting
   existing CI routing to the moved test targets keeps today's coverage and adds no test.
6. Owned areas (OWNERS.md: a590 Sidebar, PL-cef-tab, PL-motion-*, PL-switch, PL-typing,
   PL-ghostty, PL-telemetry, Performance Lead for Motion/Wakeups) get move-only diffs and an
   owner trailer; do-not-touch files wait for the owner's release.
7. Perf-hot moves name their bench and Release p50/p99 before and after.
8. Every move commit reports the localization audit and passes check-strings-bundle.py.
9. Never compile or test on the person's Mac: all builds go through cmux-ci and the train.
10. A take-back of #25042/#25048 states `Takes back #25042, #25048: <why>`.

## 5. Done checks

Run from the checkout root. "Today" values are at 772cdfc45ac.

1. App size: `find Packages/macOS/CmuxNext/Sources/CmuxNextApp -name '*.swift' -print0 | xargs -0 cat | wc -l` <= 10000 (today 143,911; H48 checkpoint <= 60,000).
2. App is wiring only: `find Packages/macOS/CmuxNext/Sources/CmuxNextApp -name '*.swift' | grep -vE '/CmuxNextApp/(Composition|Hosts|Launch|Menus)/'` prints nothing.
3. Layer edges: `python3 scripts/cmux-next/arch-ratchet.py --audit --json` has layer_hard=0 (33), layer_soft=0 (12), layer_upward=0 (3), layer_unplaced=0.
4. No mixed targets: `python3 -c "import json;d=json.load(open('plans/cmux-next/architecture-layers.json'));print(sum(1 for v in d['targets'].values() if isinstance(v,dict) and v.get('mixes')))"` prints 0 (29 today).
5. Stateful singletons (by type, first-party): `python3 scripts/cmux-next/arch_counts.py --sites stateful_singletons` lists only `ProcessRoot` (199 today); `rg -n 'static (let|var) (shared|current|instance)\b|static func shared\(' Packages/macOS/CmuxNext/Sources` prints only stateless-constant lines approved by arch_counts (134 `shared` today).
6. Global mutable statics (first-party): arch_counts `global_mutable_statics` lists only async-signal-safe crash-path entries, each with `// crash-allow:` (about 304 first-party today); Vendor reported in its own row.
7. Ambient: `rg -n '\?\? \.app\b|static func app\(|static let app\b|\broutedDaemon\b|\bactiveDaemon\b' Packages/macOS/CmuxNext/Sources` prints nothing (59 + 75 today).
8. OS seams: `rg -n '\bNSApp\b|NSWorkspace\.shared|NSPasteboard\.general|ProcessInfo\.processInfo\.environment|Bundle\.main|UserDefaults\.standard' Packages/macOS/CmuxNext/Sources | grep -vE '/CmuxNextEnvironment/|/CmuxNextApp/Launch/|/CmuxNextProcessEnvironment/'` prints nothing (about 840 today).
9. Broadcast names: `rg -n 'Notification\.Name\(' Packages/macOS/CmuxNext/Sources Packages/Shared --type swift | grep -v /Vendor/` prints at most 1 line, in CmuxNextEnvironment (14 today).
10. Posting: `rg -n 'NotificationCenter\.default\.post|\.post\(name:' Packages/macOS/CmuxNext/Sources` prints nothing outside CmuxNextEnvironment (27 today).
11. Broadcast observers: `python3 scripts/cmux-next/checkdeps.py --all --rule broadcast-observer --count` prints 0 (about 80 today); FSEventStreamCreate, makeFileSystemObjectSource and CFNotificationCenter appear only in CmuxNextEnvironment.
12. assumeIsolated: arch_counts `assume_isolated_outside_adapters` = 0 (151 today).
13. Hub gone: `rg -l '\b(AppServices|AppActionContext)\b' Packages/macOS/CmuxNext/Sources | grep -vE 'CmuxNextApp/(Composition|Hosts)/'` prints nothing (477 / 199 files today); `rg -l '\b(WindowController|PaneController|TabContentCache|WorkspaceContentController|WindowManager)\b' Packages/macOS/CmuxNext/Sources | grep -vE '/CmuxNext(Workbench|WorkbenchUI)/|CmuxNextApp/'` prints nothing.
14. No lazy composition: `rg -n 'lazy var' Packages/macOS/CmuxNext/Sources` prints nothing (155 in App today).
15. No re-exports: `rg -n '@_exported' Packages/macOS/CmuxNext/Sources` prints nothing (5 today).
16. DEPS coverage: `for d in Packages/macOS/CmuxNext/Sources/*/; do t=$(basename $d); test -f Packages/macOS/CmuxNext/deps/$t/DEPS || echo $t; done` prints nothing.
17. checkdeps clean: `python3 scripts/cmux-next/checkdeps.py --all` exits 0 in < 2 s and `--count-temporary` prints 0; IMPORT_BASELINE no longer exists in check-package-dependency-lists.py.
18. Swift strict deps on the fleet: `cmux-ci run --class isolated --ref SHA --script 'cd Packages/macOS/CmuxNext && swift build --explicit-target-dependency-import-check=error'` green; MemberImportVisibility on every swiftSettings array; `cmux-ci compile-check --ref SHA --app --package macOS/CmuxNext` green Debug and Release.
19. Tests follow code: `rg -l '@testable import CmuxNextApp\b' Packages/macOS/CmuxNext/Tests | wc -l` <= 40 (587 today), CmuxNextAppTests <= 10,000 lines (117,446), and `scripts/cmux-next/test-census.py --base <program start> --head HEAD` reports 0 lost test ids.
20. Incremental build: `bench-edit-loop.py` on an aws-m4pro host, 3 repeats: body-only edit p50 < 30 s and max < 40 s for every probe; `package` signature edit in a mid-layer model package p50 < 45 s; a Hosts-file edit recompiles <= 20 files; test-target edit loop p50 < 45 s.
21. Rust loop recorded: build-speed.md has dated `bench-edit-loop-rust.py` numbers and `check-rust-crate-deps.py` passes with its `!` count recorded.
22. Hub caps: `scripts/cmux-next/check-target-size.sh` passes; CmuxNextDesign < 20k lines; >= 20 targets depend on CmuxNextDaemonWire and not CmuxNextDaemon.
23. No perf regression: bench_launch.py cold/warm within noise of the hour-0 baseline; main-turn p99 in the 2 s after first frame <= 4 ms; every-action-sweep light+STRESS p95 unchanged; bench-typing key->frame p50/p99 unchanged on Release; bench-idle wakeups/s no worse.
24. Health regenerated: `python3 scripts/cmux-next/codebase-health.py --write` and `arch-ratchet.py --update` committed with the numbers above.

## 6. Machine queues

- **Q0-infra**: hand-made infrastructure; every task whose queue column says Q0-infra is one task.
- **Q1-app-moves**: `python3 scripts/cmux-next/app-graph.py --queue` (task 000a): each entry of
  `order` (one condensed SCC group, destination, host_members, cycle cuts) is one seam task plus
  one move task. Replaces the hub-count ordering. Tasks 100-182 are the named groups.
- **Q1b-app-toplevel**: `ls Packages/macOS/CmuxNext/Sources/CmuxNextApp/*.swift | sed -E 's#.*/##; s/(\+|\.swift).*//' | sort | uniq -c`, each prefix family mapped through app-graph.json.
- **Q2-singletons**: `python3 scripts/cmux-next/arch_counts.py --sites stateful_singletons` grouped by declaring type (>= 10 reads: own task) else per package.
- **Q2b-ambient**: `rg -n '\?\? \.app\b|static func app\(|static let app\b|\broutedDaemon\b|\bactiveDaemon\b|NSApp(lication\.shared)?\??\.(keyWindow|mainWindow)' Packages/macOS/CmuxNext/Sources`, one task per package.
- **Q2c-global-statics**: `arch_counts.py --sites global_mutable_statics`, per package, <= 40 sites per task.
- **Q3-broadcast-names**: `rg -n 'Notification\.Name\(' Packages/macOS/CmuxNext/Sources Packages/Shared --type swift | grep -v /Vendor/`, one task per name (or per pair sharing an owner).
- **Q3b-adhoc-buses**: `rg -n 'var \w+: \[[^]]*-> Void\)?\]' Packages/macOS/CmuxNext/Sources` plus the three named bus types.
- **Q4-broadcast-observers**: `python3 scripts/cmux-next/checkdeps.py --all --rule broadcast-observer --json`, chunks of <= 15 sites per task (until 001 lands: `rg -n 'addObserver\(|notifications\(named:|MainActorObservation\(' Packages/macOS/CmuxNext/Sources | rg -v 'object: [a-zA-Z_]'`).
- **Q5-layer-edges**: `python3 scripts/cmux-next/arch-layers.py --counts`; rows sharing a cause form one task.
- **Q6-undeclared-imports**: `python3 scripts/cmux-next/checkdeps.py --all --rule import-undeclared --json` (seeded from IMPORT_BASELINE).
- **Q7-typecheck-hotspots**: fleet `swift build` with `-warn-long-function-bodies=150 -warn-long-expression-type-checking=100`; each file with a hit is one task.
- **Q8-member-import-visibility**: per layer, enable the feature, compile on the fleet, group `missing import of defining module` errors by target.
- **Q10-handlers**: `ls Packages/macOS/CmuxNext/Sources/CmuxNextApp/Handlers | sed -E 's/(\+|\.swift).*//' | sort -u` mapped by domain prefix through app-graph.json.
- **Q11-tests**: per destination test target, <= 40 files per task: `rg -l '@testable import CmuxNextApp\b' Packages/macOS/CmuxNext/Tests/CmuxNextAppTests | xargs rg -l '\bMOVED_TYPE\b'`.
- **Q12-lazy**: `rg -n 'lazy var' Packages/macOS/CmuxNext/Sources` grouped by owning type; each removed in its consumer's seam task.
- **Q13-reexports**: `rg -n '@_exported' Packages/macOS/CmuxNext/Sources` (5).
- **Q14-impure-core**: `arch-layers.py --counts` impure-core list.
- **Q15-os-seams**: one rg per OS global (section 5 check 8), per package, <= 40 sites per task.
- **Q16-assume-isolated**: `arch_counts.py --sites assume_isolated_outside_adapters`, per package.
- **Q16b-subdir-deps**: subdirectories of `mixes` targets with no `import (AppKit|SwiftUI|WebKit|QuartzCore)` hit: one DEPS each.
- **Q17-hub-splits**: bench-edit-loop hub probes over 30 s, plus `check-target-size.sh --list`.
- **Q18-rust**: `cmux-tui/scripts/bench-edit-loop-rust.py` probes over 30 s and crate-split.md "Crate order".
- **Q19-hub-concretes**: `rg -l '\b(WindowController|PaneController|TabContentCache|WorkspaceContentController|WindowManager)\b'` per destination package after each move.

## 7. Decisions taken (reversible; listed for the coordinator)

Per the standing rule "decide yourself", p11 does not block on these. Each is reversible.

1. **PKG token**: tasks 006 and 007 need the FREEZE token from the coordinator before hour 2;
   later Package.swift edits go only through the hourly manifest agent (019).
2. **Vendor** (MessagesLab `**/Vendor/`) is third_party with its own counted row; the zero
   targets cover first-party code.
3. **ui -> service stays legal** (counted rules, Chrome ui -> components/core).
4. **Pre-push refuses** a new use of a `!` rule (stricter than Chrome's warning).
5. **CI routing**: existing workflow conditions and route lists that name CmuxNextAppTests are
   retargeted to the moved test targets (task 204). This keeps today's coverage and adds no job,
   step or test; it touches .github/workflows text, so the coordinator should confirm it.
6. **App size 10k** stays the end target; the 39k owned Workbench set is owner-gated (Phase W). If
   owners do not release by H60, the program ends at the H48 checkpoint (<= 60k) plus every
   unowned task, and Phase W continues after the push.

## 8. Risks

- **Owned code** (~39k App lines plus CEF, Terminal, Sidebar) gates the last 50k lines; Phase W
  depends on owner release. Fallback in decision 6.
- **Cycles**: the App is one big SCC; if app-graph.py's cuts are wrong, moves fail compile. The
  train bisects; cut tasks precede member moves.
- **Silent string loss** on move: covered by check-strings-bundle.py and a German-locale tagged
  build in 000c; residual risk for strings built at runtime from keys.
- **Lost tests**: test-census.py fails a move that drops a test id; CI routing retarget (204).
- **Launch**: eager construction; mitigated by no I/O in init, the side-effecting static-init
  rule, the afterFirstFrame scheduler and the 3 ms bench_launch rule.
- **Release perf**: cross-module moves lose inlining unless CMO is on (000i); hot moves name a
  Release bench.
- **Fleet capacity**: ~18 Macs for all programs; merge train batches compile-checks; Phase 0
  makes move tasks Package.swift-free so they batch.
- **Merge conflicts**: hotspots formatted and scaffolded once; generated files regenerated.
- **Undercounting**: task 004 first raises the hard-edge count (hidden Bridge -> Design becomes
  visible); not a regression.
- **Per-window presenters** change behavior with several windows: two-window tests in 025, 026, 219.
- **Debug dynamic linking** (196) with remaining singletons duplicates globals across images:
  196 waits for 047 and 042 and checks one image per target.
- **WindowEvents visibility**: events filtered for hidden subscribers must not include lifecycle
  events; covered by the close-with-50-hidden test.
- **AppCore take-back** reverses #25042/#25048 (one day old); the narrow seams survive in
  WorkbenchInterface.
- **MemberImportVisibility / strict import** may yield hundreds of errors; batched by layer through the train.
- **Rust scope**: crate split (247) is a stretch; bench and checker (245, 246) are required.

## 9. Review disposition

Review 1 (completeness):
- Path-keyed baselines (200), xcstrings (201): merged into 000b (move-app-files.py) and 000c (check).
- Namespace pre-pass (202): kept, limited to types that cross a module boundary (mover keeps the rest internal).
- TestSupport (203), test census + CI routing (204), guardrails root guard (205): kept.
- Missed singletons (210), Shared packages (211), global statics (212-215), lazy outside AppServices
  (216), test factory cost (217, merged with per-feature factory), OS seams (218-223; 219 merged with
  review 3's ambient-context task), buses (230, 231), file watchers (232), assumeIsolated (233, 234),
  hub splits (240-243), Rust (245-247), Pages mixes (250), checkdeps over Shared (251): kept.
- Existing import checker: 001 builds on check-package-dependency-lists.py; 002 converts and deletes IMPORT_BASELINE.
- New formatter: dropped; 006 extends the `// sorted:` marker.
- Minimal deps in scaffold: 007 now lands final dependency lists from 000a.
- Isolation: destinations keep uiSwiftSettings.
- lazy count 155, observer counts, mixes 29: corrected.
- Symbol rules dodgeable by rename; missing observer APIs: rules now type-based via arch_counts.
- compile-check does not build tests: train and test phases build test targets.
- 190-192 too big: regenerated per destination test target, <= 40 files.
- Probes: hub and test probes added to 008.
- CmuxNextInput duplicates Focus: dropped.
- check-app-size risk: corrected (passes in --base mode); 000d makes growth refusal universal.

Review 2 (feasibility):
- SCC graph (000a), mover (000b), strings check (000c), App closed (000d), seam generator (000e),
  merge train (000g), do-not-touch (000h), CMO check (000i): kept. Hour-0 baseline (000f): merged into 009.
- Seam and move in one diff: replaced by two commits.
- DEPS inside Sources: moved to a mirror `deps/` tree.
- PKG token bottleneck: final deps in 007, manifest agent 019.
- Smoke tests: dropped; test targets declared when tests move.
- Handler static enums: instance struct pattern.
- lazy vars that pass self: removed in their consumer's seam task; afterFirstFrame scheduler.
- Observer ban too broad: narrowed to broadcast registrations.
- Signal deinit threading: Mutex slots, off-main release test; PresentationChangeSubscribers reused.
- WindowEvents occlusion: lifecycle events always delivered; "visible" = mounted in shown workspace.
- Conflicts with other programs: do-not-touch list, Phase W.
- 10k in 72 h: kept as end target with an H48 checkpoint and owner gate (user asked for more ambition).
- AppCore: narrow seams kept in WorkbenchInterface, only the god-protocol deleted.
- Target name collisions: reconciled (section 3A).
- `Module.Symbol`: dropped.
- Test sweep at the end: tests move with code.
- Questions to Lawrence: decided in section 7.
- Hot-path Release perf: 000i plus per-move bench.

Review 3 (Chrome fidelity):
- WorkbenchInterface + FeatureSlots (260), retarget queue (261), scopes (262), ProcessRoot (264),
  subdir DEPS (265), owner review flag (266), static initializer audit (267), Chromium wire (268): kept
  (renumbered from 200-208).
- Ambient context (203): merged into 219.
- Hosts as relay hub: Hosts are upward-only; feature-to-feature via package edges or slots.
- Signal defaults: policy and disallow-reentrancy defaults, check_empty, weak capture rule, deliver(on:).
- Rename across targets not re-checked: fixed in 001.
- DEPS duplicating Package.swift: edges derived from architecture-layers.json; DEPS hold exceptions.
- 196 duplicated globals: depends on 047/042 and single-image check.
- Whole-object test factory only: per-feature closures.
- afterFirstFrame ordering: AfterStartupTaskUtils model.
- 093 scope: narrowed to WebKit engine and app-side ChromiumHost client, coordinated with PL-cef-helper.

## 10. Task table

Size: S <= 100 changed lines, M <= 400, L = split per its queue into <= 400-line pushes.
Default test phase "compile-check" means: `cmux-ci compile-check --ref SHA --app --package macOS/CmuxNext`
through the merge train, which also runs `swift build --build-tests` for affected test targets.

209 tasks. Prefix `p11-codebase-` omitted in this table and the details below.

| id | title | size | queue | depends on |
|---|---|---|---|---|
| 000a | app-graph.py: App type graph, SCC condensation, move order, Host surfaces, final deps | L | Q0-infra | - |
| 000b | move-app-files.py: one mover for code, tests, baselines, string tables | L | Q0-infra | 000a |
| 000c | check-strings-bundle.py: localized keys resolve in their target's bundle | S | Q0-infra | - |
| 000d | Close CmuxNextApp to growth for every program | S | Q0-infra | - |
| 000e | gen-host-seam.py: generated seam-in-place commit | L | Q0-infra | 000a, 260 |
| 000g | move-train.py: batched fleet compile with bisect | M | Q0-infra | - |
| 000h | Do-not-touch list shared with other programs | S | Q0-infra | - |
| 000i | Release cross-module optimization check | S | Q0-infra | - |
| 001 | checkdeps.py on the existing import checker | L | Q0-infra | - |
| 002 | Bootstrap mirror DEPS; retire IMPORT_BASELINE | M | Q0-infra | 001 |
| 003 | Wire checkdeps into pre-push and ratchet | M | Q0-infra | 002 |
| 004 | Fix hidden undeclared-import edges | M | Q6 | 002, 007 |
| 005 | Dissolve CmuxNextAppCore | S | Q5 | 003, 260 |
| 006 | Sorted marker on every dependency list; sorted layer map | M | Q0-infra | - |
| 007 | Scaffold destinations with final dependency lists | L | Q0-infra | 000a, 002, 006 |
| 008 | bench-edit-loop.py with hub and test probes | M | Q0-infra | - |
| 009 | Hour-0 baseline and Q7 queue | S | Q7 | 008 |
| 010 | CmuxNextSignals | M | Q0-infra | 007 |
| 011 | CmuxNextEnvironment adapters | L | Q0-infra | 010 |
| 012 | Composition skeleton and per-feature Factory | M | Q0-infra | 007 |
| 013 | AppServices lazy vars wave 1 | L | Q12 | 012 |
| 014 | AppServices lazy vars final sweep | L | Q12 | 013, 140 |
| 015 | Delete 5 @_exported | M | Q13 | 007 |
| 016 | MemberImportVisibility core/service | M | Q8 | 015, 019 |
| 017 | MemberImportVisibility domain, ui A-L | M | Q8 | 016 |
| 018 | MemberImportVisibility ui M-Z, App; strict import check | M | Q8 | 017 |
| 019 | Manifest agent: hourly Package.swift batches | S | Q0-infra | 007 |
| 020 | CmuxNextAppearance: DesignSettings and theme models | M | Q2 | 007 |
| 021 | Inject DesignSettings: App readers | M | Q2 | 020, 012 |
| 022 | Inject DesignSettings: Design, Sidebar, Tabs, Layout | M | Q2 | 021 |
| 023 | Inject DesignSettings: rest; delete shared | M | Q2 | 022 |
| 024 | ThemeScope.app / ThemeStore | M | Q2 | 020, 012 |
| 025 | Per-window ToastPresenter | M | Q2 | 012 |
| 026 | Per-window DialogPresenter | M | Q2 | 012 |
| 027 | LinkRouter and LinkMenuAppCache injected | M | Q2 | 012 |
| 028 | GhosttyRuntime injected | M | Q2 | 012, 264 |
| 029 | CEF runtime singletons injected (gated) | L | Q2 | 012, 000h |
| 030 | Wakeups probes to Instrumentation (gated) | L | Q2 | 012, 000h |
| 031 | Daemon singletons | M | Q2 | 262 |
| 032 | Control singletons | M | Q2 | 012 |
| 033 | Bridge mapping singletons | L | Q2 | 262 |
| 034 | AgentPane caches | M | Q2 | 012 |
| 035 | AgentPane state singletons | M | Q2 | 034, 262 |
| 036 | AgentLanes and AgentActivity singletons | M | Q2 | 262 |
| 037 | Sidebar singletons | M | Q2 | 012 |
| 038 | Tabs, Apps, Palette caches | M | Q2 | 012 |
| 039 | Design remaining singletons | L | Q2 | 011, 012 |
| 040 | Pages singletons | M | Q2 | 012 |
| 041 | Browser and BrowserCore singletons | M | Q2 | 029 |
| 042 | App-target singletons | L | Q2 | 012, 264 |
| 043 | Small-package singletons batch 1 | M | Q2 | 012 |
| 044 | Small-package singletons batch 2 | M | Q2 | 011 |
| 045 | Compat process detectors | M | Q2 | 012 |
| 046 | Stateless catalogs | S | Q2 | - |
| 047 | Remaining stateful singletons by type | L | Q2 | 023, 042, 210 |
| 048 | `?? .app` and `.app` factories | M | Q2b | 012 |
| 050 | browserChildWindowPagesNeedUpdate to dirty set | M | Q3 | 010, 000h |
| 051 | CEFHostView.geometryDidChange to delegate | S | Q3 | 000h |
| 052 | reduceMotion/speed to AppearanceEnvironment | M | Q3 | 011, 020 |
| 053 | hoverCards/inactiveDim to Appearance | S | Q3 | 052 |
| 054 | Ghostty configDidChange to Signal | M | Q3 | 010, 028 |
| 055 | SidebarDocStore names and favicons | M | Q3 | 010 |
| 056 | inspectUIElement and accessibility trust | S | Q3 | 011 |
| 060 | Broadcast observers Design 1 | M | Q4 | 011 |
| 061 | Broadcast observers Design 2 | M | Q4 | 060 |
| 062 | Broadcast observers App 1 | M | Q4 | 011 |
| 063 | Broadcast observers WindowOverlayLayer | M | Q4 | 050 |
| 064 | Broadcast observers App rest | M | Q4 | 062 |
| 065 | Broadcast observers Browser, RemoteBrowser, Pages | M | Q4 | 011 |
| 066 | Broadcast observers Sidebar, Terminal | M | Q4 | 011 |
| 067 | Broadcast observers remaining | M | Q4 | 011 |
| 070 | Settings -> Design hard edge | M | Q5 | 020 |
| 071 | SettingsSchema and SettingsStore split | L | Q5 | 070 |
| 072 | 10 service -> Settings soft edges | M | Q5 | 071 |
| 073 | DaemonService/KeepAwake -> Bridge soft edges | M | Q5 | 033 |
| 074 | CmuxNextPagesCore; 5 services | M | Q5 | 007 |
| 075 | AgentPaneModel part 1 | L | Q5 | 007 |
| 076 | AgentPaneModel part 2 | L | Q5 | 075 |
| 077 | Retarget 5 targets to AgentPaneModel | M | Q5 | 076 |
| 078 | CmuxNextLayoutModel | M | Q5 | 007 |
| 079 | CmuxNextTabsModel | M | Q5 | 007 |
| 080 | CmuxNextSidebarModel | L | Q5 | 007 |
| 081 | IconsCore and AgentBrands data | M | Q5 | 007 |
| 082 | BrowserAutomation/History/Host to BrowserCore | M | Q5 | 015 |
| 083 | ChromiumWarmup/RemoteLocalhost/NowPlaying to BrowserCore | M | Q5 | 082 |
| 084 | CmuxNextAgentActivityModel | M | Q5 | 007 |
| 085 | CmuxNextHomeModel | L | Q5 | 007 |
| 086 | CmuxNextHistoryModel | M | Q5 | 007 |
| 087 | WebUpdates and MobileHost hard edges | M | Q5 | 074, 077 |
| 088 | AgentCursor -> Design and 3 upward edges | M | Q5 | 007 |
| 089 | CmuxMobileRPC -> CmuxMobileSupport | M | Q5 | - |
| 090 | Impure core targets | M | Q14 | 030, 043, 045, 232 |
| 091 | Clear mixes batch 1 | L | Q5 | 007, 265 |
| 092 | Clear mixes batch 2 | L | Q5 | 091, 080 |
| 093 | Browser split: WebKit engine and ChromiumHost client | L | Q5 | 083, 029, 268 |
| 100 | Palette-family App dirs (reference move) | M | Q1 | 000b, 000e, 007, 012 |
| 101 | ErrorJournal, Crash, HangReports | M | Q1 | 100 |
| 102 | IconAssets, IconPicker, Favicons | M | Q1 | 100 |
| 103 | SleepyMode, QuickComposer | S | Q1 | 100 |
| 104 | Browser leaf dirs | M | Q1 | 100 |
| 105 | BrowserProfiles, Passwords | M | Q1 | 104 |
| 106 | BrowserHost, RemoteLocalhost glue | S | Q1 | 104 |
| 107 | Cloud part 1 | L | Q1 | 100 |
| 108 | Cloud part 2, Accounts, Billing, Usage | L | Q1 | 107 |
| 109 | Remote, Pairing, SessionTransfer, ChiefMove | L | Q1 | 100 |
| 110 | Server, ServerUpdates | M | Q1 | 100 |
| 111 | RemoteView, MacScreen glue | M | Q1 | 100 |
| 112 | Home part 1 | L | Q1 | 085, 100 |
| 113 | Home part 2, TopPages, Chief, Phone, ChatQuotes | L | Q1 | 112 |
| 114 | Feed | M | Q1 | 011, 100 |
| 115 | Notifications | M | Q1 | 100 |
| 116 | History, Vault, Stash glue | M | Q1 | 086, 100 |
| 117 | Bookmarks glue | M | Q1 | 100 |
| 118 | Onboarding, Permissions, ComputerUse setup | L | Q1 | 100 |
| 119 | Settings, Density, Themes | M | Q1 | 020, 100 |
| 120 | Quit | M | Q1 | 100 |
| 121 | FileExplorer, FilesPane, Screenshots, Viewers | M | Q1 | 100 |
| 122 | Agent glue to AgentTabs | M | Q1 | 100 |
| 123 | Apps, TaskManager, Tasks, Checklist | M | Q1 | 100 |
| 124 | SidebarSections, SidebarSnapshot, Pins, Groups | M | Q1 | 080, 100 |
| 125 | HostPressure, ClipboardReads, GlobalHotKeys, Share | M | Q1 | 100, 221 |
| 126 | Hibernation planner remainder | M | Q1 | 100 |
| 127 | Pages providers part 1 | L | Q1 | 074, 100 |
| 128 | Pages providers part 2, InternalPages | L | Q1 | 127 |
| 130 | Control part 1: Sidebar and Browser debug | L | Q1 | 124, 104 |
| 131 | Control part 2: window/pane/motion debug (Phase W) | L | Q1 | 170 |
| 132 | Control part 3: agent/home/terminal debug | L | Q1 | 122, 113 |
| 133 | Control part 4: CmuxNextAppControl | L | Q1 | 130, 131, 132 |
| 140 | Handler infra and invocation target | M | Q10 | 012, 260 |
| 141 | Cloud handlers | M | Q10 | 140, 108 |
| 142 | Agent and chat handlers | L | Q10 | 140, 160 |
| 143 | Browser handlers part 1 | M | Q10 | 140, 104 |
| 144 | Browser handlers part 2 | L | Q10 | 143 |
| 145 | Tab-family handlers (Phase W) | L | Q10 | 140, 170 |
| 146 | Pane/Column/Room/Screen/Window handlers (Phase W) | L | Q10 | 145 |
| 147 | Workspace handlers | L | Q10 | 145 |
| 148 | Settings/Appearance/Theme/Key handlers | M | Q10 | 140, 119 |
| 149 | Remote/Server/Machine handlers | M | Q10 | 140, 109 |
| 150 | History/Bookmark/Vault/Notification/Music handlers | M | Q10 | 116, 117, 115, 140 |
| 151 | Chief and Home handlers | M | Q10 | 113, 140 |
| 152 | Files/Viewer/Diff/VSCode handlers | M | Q10 | 121, 140 |
| 153 | Terminal/TextBox/Resume/RunningPrograms handlers | M | Q10 | 140 |
| 154 | Remaining handlers and strings | L | Q10 | 141-153 |
| 160 | AgentTabs* part 1 | L | Q1b | 122 |
| 161 | AgentTabs* part 2 | L | Q1b | 160 |
| 162 | Browser*/Chromium* top-level | L | Q1b | 104 |
| 163 | Sidebar* top-level | L | Q1b | 124 |
| 164 | Terminal* top-level | M | Q1b | 028, 100 |
| 165 | AppActions, ActionRouting, Config, WorkContext | M | Q1b | 140, 219 |
| 170 | Phase W: PaneController* | L | Q1b | 140, 261, 000h |
| 171 | Phase W: TabContentCache*, WorkspaceContent* | L | Q1b | 170, 262 |
| 172 | Phase W: PaneContentView*, WindowRootView* | L | Q1b | 171 |
| 173 | Phase W: Windows/ model | L | Q1 | 172 |
| 174 | Phase W: Windows/ views and overlay | L | Q1 | 173 |
| 175 | Phase W: Focus key path to FocusUI/Focus | L | Q1 | 140, 000h, 000i |
| 176 | Phase W: Focus rest, InputVerification | L | Q1 | 175 |
| 177 | Phase W: Drag/, PaneSwapDrag | L | Q1 | 172 |
| 178 | Phase W: NewTab | L | Q1 | 171 |
| 179 | Remaining small dirs and leftovers | L | Q1 | 173 |
| 180 | Fold AppServices into AppFeatures; delete AppActionContext | L | Q9 | 154, 179, 014, 216 |
| 181 | Menus from per-domain contributions | M | Q1b | 154 |
| 182 | Launch/ | M | Q1b | 180, 000h |
| 190 | Residual test sweep 1 | L | Q11 | 113, 115, 109, 203, 204 |
| 191 | Residual test sweep 2 | L | Q11 | 161, 162, 163, 203, 204 |
| 192 | Residual test sweep 3 | L | Q11 | 176, 177, 174, 203, 204 |
| 195 | Type-check hotspot fixes | M | Q7 | 009 |
| 196 | Debug mergeable/dynamic libraries | M | Q0-infra | 009, 047, 042 |
| 197 | Hub fan-out check | S | Q0-infra | 180 |
| 198 | Retire ! rules; ratchet to zero; close F13 | M | Q0-infra | 182, 192, 093, 092, 047, 067, 018, 197, 215, 234, 223, 250, 242 |
| 202 | Namespace-lint pre-pass for cross-module App types | L | Q1 | 000a |
| 203 | TestSupport targets with fake Hosts | L | Q11 | 007, 140, 019 |
| 204 | Test census and retargeted CI routing | M | Q11 | 007 |
| 205 | Composition-root guard in guardrails.py | S | Q0-infra | 012 |
| 210 | Singletons under other names | M | Q2 | 012 |
| 211 | First-party Shared packages | M | Q3 | 011 |
| 212 | global_mutable_statics: Design | L | Q2c | 020, 012 |
| 213 | global_mutable_statics: App | L | Q2c | 012 |
| 214 | global_mutable_statics: AgentPane, Terminal, Browser | L | Q2c | 028, 029 |
| 215 | global_mutable_statics: tail | L | Q2c | 212, 213, 214 |
| 216 | Lazy composition outside AppServices | M | Q12 | 012 |
| 217 | Default test Factory stubs | M | Q12 | 013 |
| 218 | ApplicationEnvironment (NSApp) | L | Q15 | 011 |
| 219 | Explicit action target; no ambient window/daemon | L | Q2b | 140, 218 |
| 220 | WorkspaceServices (NSWorkspace.shared) | L | Q15 | 011 |
| 221 | Clipboard seam | M | Q15 | 011 |
| 222 | LaunchEnvironment (ProcessInfo environment) | L | Q15 | 012 |
| 223 | AppBundleInfo and Preferences | M | Q15 | 012 |
| 230 | Ad-hoc buses to Signal | M | Q3b | 010 |
| 231 | Callback-array subscriber lists to Signal | M | Q3b | 010 |
| 232 | One FilePathWatcher | L | Q4 | 011 |
| 233 | assumeIsolated: Design, Terminal, Sidebar | M | Q16 | 060, 066 |
| 234 | assumeIsolated: App, Browser, tail | M | Q16 | 233, 064, 065 |
| 240 | CmuxNextDaemonWire split | L | Q17 | 007, 009 |
| 241 | CmuxNextActionsCatalog split | M | Q17 | 009 |
| 242 | CmuxNextPresenters split from Design | L | Q17 | 039, 026, 009 |
| 243 | Per-target size cap | S | Q0-infra | - |
| 245 | Rust edit-loop bench and statics row | M | Q18 | 008 |
| 246 | Rust crate layering checker | M | Q18 | - |
| 247 | Resume cmux-tui-core crate split | L | Q18 | 245, 246, 000b |
| 250 | Clear CmuxNextPages mixes | M | Q5 | 074 |
| 251 | checkdeps over Shared, iOS, CmuxUpdater | M | Q0-infra | 002 |
| 260 | CmuxNextWorkbenchInterface and FeatureSlots | M | Q0-infra | 007, 010 |
| 261 | Retarget hub concretes to interfaces | M | Q19 | 260 |
| 262 | MachineFeatures, WorkspaceFeatures, TabFeatures | L | Q0-infra | 012 |
| 264 | ProcessRoot | S | Q2 | 012, 002 |
| 265 | Subdirectory DEPS inside mixed targets | S | Q16b | 002 |
| 266 | new_usages_require_review | M | Q0-infra | 001 |
| 267 | Static initializer audit, type-based counting | M | Q2 | 012 |
| 268 | CmuxNextChromiumWire | M | Q5 | 007, 000h |

### Task details

The full per-task files, change, acceptance and test phase are below. "Pattern of 100" means:
commit 1 is the gen-host-seam.py seam in place (narrow Host from app-graph host_members, hub
concretes to WorkbenchInterface, `registry.bind(` lines unchanged); commit 2 is move-app-files.py
(code, tests, path-keyed baselines, string tables), with no Package.swift edit. Its acceptance:
the directories are gone from App; the move commit is renames plus <= 400 lines; checkdeps clean;
Hosts files are one-expression upward forwards; moved files name no hub concrete; no lazy var or
singleton moves; check-strings-bundle.py and follow-renames --check pass; perf-hot files carry a
Release bench before/after. "Pattern of 141" is the same for handlers, plus an unchanged sorted
action-ID list and a passing action-wait guardrail.

**000a app-graph.py.** Files: scripts/cmux-next/app-graph.py, tests/test_app_graph.py,
plans/cmux-next/app-graph.json, architecture-refactor-DESIGN.md section 4. Change: per-type
reference graph of CmuxNextApp from the index store of one fleet Debug build (regex fallback for
dry runs); group by directory or family; SCCs condensed to a DAG; per group write destination
(existing target first), host_members, cycle cuts, final deps per destination, scc_id, order.
DESIGN section 4 updated to the same map. Acceptance: the JSON has all fields; a 3-group cycle
fixture reports the cycle and its cut; each Q1 task maps to one order entry. Test: pytest; fleet
`app-graph.py --index-store <path> --write`.

**000b move-app-files.py.** Files: move-app-files.py, follow-renames.py, tests, prepush-gate.py.
Change: git mv code and tests; rewrite every path-keyed baseline (list in section 2) and the
cmux-next-motion-golden.yml paths filter, cmux_next_route.py, check-crash-safety.sh,
check-no-bench-hooks.sh, check-ime-input.py; move or split xcstrings tables; update
architecture-layers.json and OWNERS.md; follow-renames --check in prepush. Acceptance: fixture
moves change only paths; `git grep <old path>` empty; moved keys present with all locales; no
App table keeps an unreferenced key; --check exits 1 on a stale path. Test: pytest; scratch
dry run of App/TabSearch then prepush-gate.py.

**000c check-strings-bundle.py.** Each `bundle: .module` key must exist in the containing target's
table; pre-push via guardrails.py. Acceptance: wrong-target fixture fails; tip exits 0 or lists
existing debt. Test: pytest; `--all`; a German-locale fleet tagged build shows a moved Quit dialog translated.

**000d App closed to growth.** guardrails.py, prepush-gate.py, app-size-baseline.txt,
COORDINATION.md. prepush always runs check-app-size.sh with `--base <merge-base>`; app-type
guard refuses new App files outside the four dirs; the train lowers the cap after each batch.
Acceptance: adding an App file is refused; moving lines between App files passes.

**000e gen-host-seam.py.** Generates the Host protocol in the destination, the Hosts forwards
file (upward calls only; feature-to-feature becomes a FeatureSlots lookup or package edge) and the
in-App codemod (`services:` -> `host:`, hub concretes -> interfaces, handler enums -> instance
structs). Acceptance: fixture seam compiles; Hosts members one expression; bind lines identical;
no caseless static enum produced. Test: pytest; real run on App/TabSearch then compile-check.

**000g move-train.py.** Stacks ready commits, one fleet compile-check plus `swift build
--build-tests`, bisects on red, lands the green prefix, then lowers the app-size cap and runs
arch-ratchet --update. Never builds locally. Acceptance: 4-commit dry run with one bad commit
lands 3 and names the bad one.

**000h Do-not-touch list.** COORDINATION.md and OWNERS.md list CEF/**, CmuxApplication.swift,
Focus/KeyRouter*, TabContentCache*, PaneController*, WindowOverlayLayer, motion files and the
instrumentation types, with an owner and release line each, and the gated task ids (029, 030,
050, 051, 093, 170-178, 182, 268). Test: none (doc).

**000i Release CMO check.** Record the CMO state for hot targets in build-speed.md and enable it
through the manifest agent if it is off. Rule: each perf-hot move runs its Release bench before
and after. Test: bench-typing.py and every-action-sweep.py on Release.

**001 checkdeps.py.** Files: checkdeps.py, tests/test_checkdeps.py, check-package-dependency-lists.py
(it only gains an importable parser function). Change: spec section 3D. Acceptance: fixtures for
every rule kind; `!` counted; a new use of a `!`-only rule refused in --base mode;
specific_include_rules precedence; noparent; testonly visibility; transitive assert_no_deps; all
import forms; a rename of `shared` to `instance` still counted; a cross-target move of a Bridge
file that imports CmuxNextDesign into a domain target refused; --all < 2 s. Test: pytest;
`--all --json` lists the IMPORT_BASELINE pairs.

**002 Bootstrap DEPS.** Files: deps/DEPS, deps/<Target>/DEPS (112), check-package-dependency-lists.py.
Change: `--bootstrap` writes `-`, `!`, assert_no_deps and visibility only. Root symbol rules per
section 3D. IMPORT_BASELINE pairs become `!` rules and IMPORT_BASELINE is deleted. Vendor is
third_party. Acceptance: `--all` exits 0; `--count-temporary` equals the number of `!` entries and is
in the commit message; no Swift or Package.swift change; the existing CI step still passes.

**003 Wire checkdeps.** guardrails.py runs `--base/--head`, refuses new violations and new
`!`-only lines (dated exception only); arch_counts rows deps_temporary_allowances and
broadcast_observers (ratchet). Acceptance: adding `import CmuxNextDesign` to a Bridge file is
refused; a same-target git mv passes; no workflow change. Test: pytest guardrails and checkdeps.

**004 Hidden edges.** Declare the layer-legal pairs through the manifest batch. Remove Bridge ->
Design by moving the symbols to DesignTokens/Appearance or behind a Bridge-owned protocol.
Acceptance: import-undeclared lists only alias-mapped binaries; no `import CmuxNextDesign` in
Bridge; layer_hard does not rise once the edge is counted. Test: compile-check; Bridge tests.

**005 Dissolve AppCore.** git mv MachineWorkspaceProviding, PageActionProviding and WorkspaceClose
to WorkbenchInterface. Re-home WorkspaceSpawn behind the interfaces. Delete AppServicesProviding;
callers take their domain Host. PR body: `Takes back #25042, #25048: <why>`. Acceptance: the
target is gone; layer_unplaced=0; renames plus <= 120 lines.

**006 Sorted manifests.** Extend the `// sorted:` marker to every dependency array and sort
architecture-layers.json; FREEZE token. Acceptance: fleet dump-package sets equal at base and
head; the diff only reorders and formats.

**007 Scaffold.** Create the new targets of section 3A with a doc-only Module.swift, DEPS, a
layer entry and an App dependency. Each target gets its final dependency list from app-graph.json
and uiSwiftSettings where it receives App code. No test targets and no smoke tests.
ci-target-graph.json is regenerated on the fleet. FREEZE token. Acceptance: no hard, soft or
upward edge added; layer_unplaced=0; no existing source changes.

**008 bench-edit-loop.py.** Section 3E. Acceptance: refuses unless CMUX_CI_HOST is set; fixture
log parsing tests pass; build-speed.md documents the command. Test: fleet `--repeats 3`.

**009 Hour-0 baseline.** Run 008 on two hosts and run Q7. Record the emit, link and test-module
shares and one sentence on the order decision. Acceptance: a dated table plus the Q7 list; the
perf-lead F13 row links it.

**010 Signals.** Section 3C. Read PresentationChangeSubscribers first. Acceptance:
remove-during-dispatch and add-during-dispatch work under each policy; a nested dispatch asserts
under `.disallow`; a token released off main unregisters; reset twice is a no-op; check_empty
fires; deliver(on:) coalesces; dispatch is O(subscribers); non-test diff <= 300 lines. Test: fleet
`swift test --filter CmuxNextSignalsTests`.

**011 Environment.** AppEvents, WindowEvents (lifecycle events to all subscribers; repaint events
only to mounted-shown subscribers, which resync(revision:) on show), AppearanceEnvironment and
SystemNotificationSource. DESIGN section 6 updated. Acceptance: N x M fake test; closing a window
with 50 hidden subscribers delivers willClose to all 50 and releases them; occlude/unocclude
restarts rendering; registrations O(names); only the adapter has a `main-proof:` assumeIsolated.

**012 Composition skeleton.** AppFeatures phases, AfterStartupQueue (one start() per frame,
background priority), Factory of per-feature closures, AppServices facade, WindowFeatures per
WindowController (coordinate with PL-switch), Hosts/. Acceptance: no lazy var added; phases run in
order; a test overrides one feature and the rest stay production; launch signposts unchanged.
Test: compile-check; AppFeaturesTests; bench_launch.py x5.

**013 Lazy wave 1.** Lazies whose initializer does not pass self become `let` in AppFeatures;
their I/O moves to a start(). Acceptance: the drop count is in the commit; no new blocking sites
at launch; cold p50 regresses by <= 3 ms; main-turn p99 <= 4 ms in the 2 s after the first frame.

**014 Lazy final sweep.** After the seams, the rest become lets. Cycles are broken by narrow
protocols, never IUOs or self-capturing closures. Acceptance: no lazy var in AppServices*.swift;
launch as in 013.

**015 @_exported.** Delete the 5 export files and add explicit imports in sources and tests.
Acceptance: the rg is empty; only import lines change. Test: compile-check Debug+Release with tests.

**016-018 MemberImportVisibility** by layer through the train. Fix each error with an explicit
import. 018 also makes the fleet strict import check green. Acceptance: every swiftSettings array
has the flag; only import, dependency and settings lines change.

**019 Manifest agent.** One PKG token holder lands queued manifest requests every hour (test
targets, TestSupport, leftovers, deletions) and regenerates ci-target-graph.json. Acceptance:
each batch has a Freeze-Token trailer and a task-id list; no move-task diff contains Package.swift.

**020 Appearance.** git mv DesignSettings and the theme models. Observable properties replace the
posts, which stay as a shim until 052/053. Acceptance: renames plus <= 200 lines; no SwiftUI;
layer edges do not rise. Test: Design/Settings tests; perf gate theme scenario.

**021-023 Inject DesignSettings** (App; then Design/Sidebar/Tabs/Layout with a590 and
PL-motion-core diffs; then the rest, and delete `shared`). Acceptance: `DesignSettings.shared` count
is 0 per scope; hidden views read on show; stateful_singletons drops. Test: compile-check; perf
rows panes.split, sidebar, settings.

**024 ThemeScope.app.** AppFeatures builds ThemeStore; scopes passed by init. Acceptance: the rg
for `ThemeScope.app` and `ThemeStore.shared` is empty.

**025/026 Toast/Dialog presenters.** Per-window presenters in WindowFeatures. Window-less items
resolve through the composition-root resolver. Acceptance: 0 `.shared`; a two-window test places
the toast or dialog only on the requesting window. Test: capture tour (025), check-dialog-key-hints.py (026).

**027 LinkRouter.** Injected through the Hosts. Test: terminal-cmd-click-e2e.

**028 GhosttyRuntime.** Built by AppFeatures; trampolines use the context pointer or a named
ProcessRoot trampoline. Acceptance: 0 `.shared`; GhosttyRuntimeCallbacks is the only assumeIsolated
site there; the Release typing bench is unchanged.

**029 CEF runtime** (gated by 000h). One instance passed to CEFEngine, the WebAuth windows and
OffTheRecordProfiles. Acceptance: 0 `.shared` of the 5 types; owner trailer. Test: cef-tab-bench.py,
check-first-chromium.py.

**030 Instrumentation** (gated until the perf programs have their final numbers). Acceptance: 0 `.shared`
of the 5 probe types; Performance Lead OK; bench-idle unchanged.

**031-046 Singletons.** Each named type becomes an instance owned by its scope (MachineFeatures for
daemon, Bridge and AgentLanes feeds; TabFeatures for per-pane state; WindowFeatures for presenters
and tooltips; AppFeatures otherwise), passed by init. Acceptance: 0 stateful singletons for the
listed types or targets (arch_counts by type); owner trailers where owned; 046 proves
statelessness, and the reviewer rejects renames that dodge the count. Test: that package's tests
and the bench named in the JSON task list.

**047 Remaining singletons by type.** Acceptance: first-party stateful_singletons lists only ProcessRoot.

**048 Ambient `.app`.** Required init parameters. Acceptance: the Q2b rg for `.app` is empty.

**050-056 Broadcast names.** Each name becomes a direct call, a Signal on its owner, or a dirty
set. Acceptance per task: the name is deleted. 050: 10 hosts with 1 moved give 1 geometry call.
052: 20 hidden pages get 0 updates. 054: 50 hidden terminals are touched 0 times. 055: 1 of 400
rows invalidates 1 row. 056: at most 1 `Notification.Name(` left, in Environment.

**060-067 Broadcast observers.** Chunks of <= 15 sites. Broadcast registrations become AppEvents
or WindowEvents subscriptions; object-scoped observation stays. Acceptance: checkdeps
broadcast-observer count is 0 per scope; 066: Cmd-Tab with 100 terminals runs 0 hidden repaint
handlers. Test: bench-idle, every-action-sweep Cmd-Tab STRESS.

**070-093 Layer edges and mixes.** Each git-mvs UI-free files down (or retargets imports) and
keeps uiSwiftSettings. Acceptance: the named edges are gone or `mixes` is cleared; renames plus
<= 300 lines per push; Model/Core targets pass assert_no_deps. 089 brings layer_hard to 0.
093 scope: the WebKit engine and the app-side ChromiumHost client only.

**100-133, 160-179 App moves.** Pattern of 100 with the destination in the table. Phase W tasks
(131, 170-178) run only after the owner's release. 130-133 keep the registered debug.* name list
unchanged, and Release registers none.

**140 Handler infra.** Instance-struct bind pattern; ActionInvocation carries the resolved target;
ActionScopeResolving. Acceptance: Theme binds through it; the sorted action-ID list is unchanged;
action-wait passes.

**141-154 Handler moves.** Pattern of 141.

**180 Fold AppServices.** Acceptance: done checks 13 and 14 pass; Hosts have no if/for/switch
and no forward into another feature's controller.

**181 Menus.** Acceptance: check-menu-actions.py baseline unchanged; menu snapshot identical.

**182 Launch/.** Acceptance: done checks 1-2. Test: bench_launch.py.

**190-192 Residual test sweeps.** At most 40 files per push; fakes come from TestSupport.
Acceptance: the census reports 0 lost ids; 192 meets done check 19.

**195 Type-check hotspots.** Behavior-preserving. Acceptance: the Q7 re-run is empty for the touched files.

**196 Debug dynamic libraries.** Only if link is >= 5 s of the loop. Acceptance: link time goes
down; each target is in exactly one image; no duplicate-class log line; Release size and launch
unchanged; revert if the gain is < 3 s.

**197 Hub fan-out.** Acceptance: a Hosts body edit recompiles <= 20 files.

**198 Close-out.** Acceptance: all done checks pass, and the commit lists each command's output.

**202 Namespace pre-pass.** Acceptance: a dry run that makes cross-module App types `package` adds
0 lines to lint-namespace-types-ratchet.txt.

**203 TestSupport.** Fakes for each domain Host; DEPS visibility for test targets only.
Acceptance: checkdeps refuses a production dependency on a TestSupport target; one suite per
domain builds without AppServices.

**204 Census and CI routing.** test-census.py runs locally. Workflow conditions and route lists
that name CmuxNextAppTests also name the moved suites' targets; no new job, step or test.
Acceptance: 0 lost ids; the diff check shows no added job or step.

**205 Root guard.** ROOT_FILE/ROOT_BUDGET over the four dirs; Hosts forwards only; growth outside
the four dirs refused after 179.

**210 Other-name singletons**, **211 Shared packages**, **212-215 global statics**, **216 lazy outside
AppServices**, **217 test Factory stubs**, **218-223 OS seams**, **230-231 buses**, **232
FilePathWatcher**, **233-234 assumeIsolated**, **240-243 hub splits and caps**, **245-247 Rust**,
**250 Pages mixes**, **251 checkdeps over Shared**, **260 WorkbenchInterface**, **261 hub-concrete
retarget**, **262 scopes**, **264 ProcessRoot**, **265 subdir DEPS**, **266 owner review**, **267
static initializers**, **268 ChromiumWire**: the change, acceptance and test phase for each are
the ones in sections 3 and 5, written per task in the program's JSON task list. Each acceptance
is the matching done-check query scoped to the task's files or targets, plus the behavior test
named there. Key ones: 217, CmuxNextAppTests wall time within 5% of baseline; 219, a two-window
test where an action from B never resolves A; 222, env-write-allowlist unchanged; 232, bench-idle
no worse; 240, >= 20 targets on DaemonWire only; 242, Design < 20k lines; 262, a tab move keeps
TabFeatures and holds no window state, and closing a machine releases all its members; 268, the
wire target imports only Foundation.

> **Priority (2026-10-28):** lower. Lawrence moves the Mac to the Chromium fork later, so this AppKit-only program pays off after the move. No new p11 waves; finished branches still merge on spare train slots. See [PRIORITIES.md](PRIORITIES.md).
