# God-object dissolution plan (refactor/full-integration)

Handoff doc for the cmux god-object dissolution program. This branch is the deliverable: an isolated re-architecture reviewed off `main`. This doc is the source of truth for the *architecture* goal; the per-wave running state lives in the agent memory ledger `cmux-refactor-overnight-integration-branch`.

## Goal (owner ruling)

A large god TYPE, and its `God+*.swift` extension-file sprawl, is faulty in itself. Moving god *logic* into package coordinators while the god *type* stays (still owning every coordinator, conforming to every `*Hosting` protocol, reached globally) is NOT decomposition — it just relocates method bodies so per-file line counts drop.

End state: the god objects do not exist.
- `AppDelegate` < 1,000 lines total **including all extensions** (composition root only: `@main` / `NSApplicationDelegate` lifecycle + dependency wiring).
- `Workspace` / `TabManager` / `TerminalController` replaced by focused owned types.
- Genuinely app-coupled witnesses (`GhosttyNSView`/`GhosttySurfaceScrollView`, bonsplit, the responder swizzles) survive only as small single-purpose types/files, never as a god.

## Why they are still gods (not logic-trapped)

The focused types already exist; decomposition is ~25–50% done at the logic level. The gods persist for four structural reasons:

1. **Aggregate ownership** — one object holds everything (AppDelegate ~85 stored props; TabManager ~33 coordinators + 6 raw + subscriptions; Workspace ~25 coordinators + ~40 value props + 14 Combine bridges; TerminalController 39 mostly-delegated workers).
2. **Conformance-witness sprawl** — each god conforms to dozens of `*Hosting` protocols (AppDelegate 25, Workspace 39), each conformance body in a `God+*Hosting.swift` file.
3. **Singleton reach** — `AppDelegate.shared` = 608 call sites / 61 files / 175 distinct targets (the #1 blocker). `TerminalController.shared` still exists. `GhosttyApp` has process-wide statics. (TabManager already de-singletonized: per-window `WindowScopedStore<TabManager>`.)
4. **Irreducible app-coupled hot paths** — AppDelegate's 6 responder swizzles + `handleCustomShortcut` (~2,500 lines of `@objc`); `GhosttyNSView`/`GhosttySurfaceScrollView` (typing-critical, wrap `ghostty_surface_t`); Workspace's `bonsplitController` + `panels`.

## Target architecture (object graph)

Each god → a small composition root + domain models (each owns one domain's value-state + its coordinator + IS its hosting witness) + isolated app-coupled witness types. No global singletons; everything constructed at a root and injected.

- **`AppEnvironment`** (new, app-target) — process-lifetime services AppDelegate holds today; constructed in `applicationDidFinishLaunching`, injected via SwiftUI `@Environment` + init params.
- **`WindowContext`** (new, app-target) — per-window state currently in AppDelegate's `WindowScopedStore<…>` dicts (TabManager, focus controller, config store, sidebar/file-explorer state); one per `NSWindow`, held by `MainWindowController`.
- **`KeyEventRouter`** (new, app-target) — the ~2,500-line responder-swizzle + `handleCustomShortcut` cluster + first-responder guard cache, as its own type (stays app-side; do NOT touch `hitTest`/`forceRefresh`/`handleAction`).
- **`Workspace` → identity + ~8 domain-model holders** — `WorkspaceRemoteModel` (6 remote conformances), `WorkspaceSplitModel` (5 split), `WorkspaceSurfaceModel` (4 surface/creation/teardown), `WorkspaceLayoutModel`, `WorkspaceBrowserModel` (3 browser), `WorkspaceAgentModel` (2 agent), `WorkspaceSidebarMetadataModel`, `WorkspaceSessionModel`. Each owns value-state + coordinator + the hosting conformance, lives in its owning package. Workspace keeps only identity + the live bonsplit/panels/canvas witness + the holders.
- **`TabManager` → `WindowWorkspaceStore`** (CmuxWorkspaces) held by `WindowContext`; retire `typealias Tab = Workspace`.
- **`TerminalController`** — delete `.shared`, inject; `+Control*` bodies move into their package workers.
- **`GhosttyTerminalView.swift`** — split the 9.7k monofile: finish `GhosttyApp` extractable parts into CmuxTerminal; `GhosttyNSView`/`GhosttySurfaceScrollView` stay app-side as their own files.
- **`ContentView`** — keep as window-root view; move `VerticalTabsSidebar`/`TabItemView` into CmuxSidebarUI behind the snapshot boundary.

Exemplar templates: `NotificationNavigationCoordinator` (CmuxNotifications, constructor-injected seams), `AgentForkCoordinator` (CMUXAgentLaunch, init + `attach(host:)`), `TerminalSurfaceRuntimeTeardownCoordinator` (CmuxTerminal, actor).

## The dissolution mechanism (the step the last pass skipped)

For each cluster, do all four steps — the previous work stopped after step 1:

1. Create the focused owned TYPE (move the `God+XHosting.swift` body + matching stored props into it; it conforms to the hosting protocol).
2. The god holds it (`let x: XModel`).
3. **Migrate call sites off the god to the new type** (`workspace.remoteStatus` → `workspace.remote.status`; `AppDelegate.shared.notificationStore` → injected `environment.notifications`). This is what actually shrinks the god.
4. Delete the god's forwarders + the now-empty `God+XHosting.swift` file.

## Execution order (gated, measurable waves)

1. **De-singletonize `AppDelegate.shared` (keystone).** Introduce `AppEnvironment` + `WindowContext`; migrate the 608 sites in batches grouped by the 13 responsibility domains; delete `AppDelegate.shared`.
2. **Extract `KeyEventRouter`** (the ~2,500-line swizzle/shortcut cluster).
3. **Move AppDelegate witness clusters** into owned types; delete the 30 extension files. **Target: AppDelegate < 1,000 lines.**
4. **Dissolve `Workspace`** into the ~8 domain models (remote → split → surface → browser → agent → sidebar-metadata → session); migrate call sites; delete the 67 `Workspace+*` files; retire the 14 Combine bridges.
5. **`TabManager` → `WindowWorkspaceStore`**; finish **`TerminalController`** de-singletonization; split **`GhosttyTerminalView.swift`**; move **`ContentView`** sub-views to CmuxSidebarUI.

Agent prompts MUST require steps 3–4 (call-site migration + file deletion) and are forbidden from parking on "already a forwarder / witness floor."

## Verification

- Per wave: target package + app build green locally (Swift 6.3); zero dangling refs; periodic Swift-6.1 build via `ci.yml` `tests-build-and-lag`.
- Behavior: keep `tests` / `ui-regressions` / CoreAnimation-startup / lag CI green; per-window routing + shortcut-dispatch tests guard the de-singletonization.
- Progress metric (the goal): AppDelegate line count (< 1,000 incl. extensions), `AppDelegate.shared` call sites (→ 0), `God+*.swift` file counts (→ ~0), Workspace/TabManager/TerminalController line counts trending to small focused types.

## Branch state at handoff

Compiles under Swift 6.1; warning + file-length budgets green. One open, pre-existing, macOS-15-only CoreAnimation startup regression (`Run CoreAnimation main-thread startup regression` step; `main` passes it, branch fails; does not reproduce on macOS 26) — tracked separately, not blocking the architecture work. `release-build` is the known flaky LTO link (non-required).
