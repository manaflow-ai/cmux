# Git Diff Right-Sidebar Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add a new right-sidebar "Git" mode showing the current workspace's diff against the repo's default branch as a view-only file list with a native SwiftUI inline diff.

**Architecture:** A new `RightSidebarMode.git` case mounts a `GitDiffPanelView` backed by `WorkspaceChangesService` (list + per-file diff). Live updates come from an invalidation stream published by `SidebarGitMetadataService` (reusing its filesystem watchers) consumed by the panel, which calls a new `WorkspaceChangesService` forced-refresh/invalidation API. `WorkspaceChangesService` remains sole owner of diff loading/caching. A shared provenance-aware resolver picks the focused local panel's effective directory. Comparison base (resolved default ref vs `HEAD`) surfaces explicitly.

**Tech Stack:** Swift 6, SwiftUI, Swift Testing, CmuxGit (Layer-2 service package), CmuxSidebarGit, RightSidebarMode infrastructure, KeyboardShortcutSettings, Localizable.xcstrings.

**Design doc:** `docs/plans/2026-08-14-git-diff-sidebar-design.md` (read first). Referenced skills: @cmux-architecture, @cmux-testing, @cmux-localization, @cmux-dev-workflow, @cmux-debugging (typing-latency + list-boundary rules), @cmux-keyboard-shortcuts.

---

## Phase 1 — CmuxGit package: comparison semantics + cache invalidation

### Task 1: Add comparison-semantics field to `WorkspaceChangedFiles`

**Files:**
- Modify: `Packages/macOS/CmuxGit/Sources/CmuxGit/Changes/WorkspaceChangesModel.swift`
- Modify: `Packages/macOS/CmuxGit/Sources/CmuxGit/Changes/WorkspaceChangesSnapshotLoader.swift`
- Modify: `Packages/macOS/CmuxGit/Sources/CmuxGit/Changes/WorkspaceChangesService+Values.swift`
- Test: `Packages/macOS/CmuxGit/Tests/CmuxGitTests/WorkspaceChangesServiceTests.swift`

**Context:** The UI must distinguish "compared against the default branch's merge base" from "compared against `HEAD` (on the default branch or unresolvable base)". Today both collapse to `baseRef == nil` (`WorkspaceChangesSnapshotLoader.swift:47`). Add an explicit enum.

**Step 1: Add the model type**

In `WorkspaceChangesModel.swift`, add:

```swift
/// Why a changed-file snapshot's diff base was chosen.
public enum WorkspaceComparisonBase: String, Sendable, Equatable {
    /// Compared against the resolved default branch's merge base.
    case mergeBase
    /// Compared against `HEAD` (on the default branch, or no default ref resolved).
    case head
}
```

Add `public let comparisonBase: WorkspaceComparisonBase` to `WorkspaceChangedFiles` (default `nil`-safe: make init default `.head`) AND to `WorkspaceChangesScope` (internal struct in `WorkspaceChangesSnapshotLoader.swift`).

**Step 2: Populate it in the loader**

In `WorkspaceChangesSnapshotLoader.resolveScope` (`WorkspaceChangesSnapshotLoader.swift:44-72`): when `baseRef != nil` set `comparisonBase = .mergeBase`; otherwise `.head`. Add the field to the `WorkspaceChangesScope` init.

**Step 3: Propagate into `WorkspaceChangedFiles`**

In `changedFilesValue(from:)` (`WorkspaceChangesService+Values.swift:9`), pass `comparisonBase: snapshot.scope.comparisonBase`.

**Step 4: Write failing test, then implement**

Test in `WorkspaceChangesServiceTests.swift`: create a repo on a non-default branch with an upstream ref → expect `.mergeBase`; create a repo on the default branch → expect `.head`.

```swift
@Test func changedFilesComparisonBaseOnDefaultBranchIsHead() async throws {
    let fixture = try GitRepositoryFixture()
    try fixture.writeBranch("main")
    try fixture.writeWorkingTreeFile("a.txt", contents: "hello")
    let changes = WorkspaceChangesService(runner: ...)
    let files = try await changes.changedFiles(forDirectory: fixture.root.path)
    #expect(files.comparisonBase == .head)
}
```

**Step 5: Run the package tests**

Run: `xcodebuild test -project cmux.xcodeproj -scheme cmux -destination 'platform=macOS' -derivedDataPath /tmp/cmux-<tag> -only-testing:CmuxGitTests` (compile-check path; see @cmux-testing for the exact runner). Expected: the new tests pass, existing tests still pass.

**Step 6: Commit**

```bash
git add Packages/macOS/CmuxGit
git commit -m "feat(cgit): expose workspace diff comparison base"
```

### Task 2: Add forced-refresh / invalidation API to `WorkspaceChangesService`

**Files:**
- Modify: `Packages/macOS/CmuxGit/Sources/CmuxGit/Changes/WorkspaceChangesService.swift`
- Modify: `Packages/macOS/CmuxGit/Sources/CmuxGit/Changes/WorkspaceChangesLoadedSnapshotCache.swift`
- Modify: `Packages/macOS/CmuxGit/Sources/CmuxGit/Changes/WorkspaceChangesSummaryCache.swift`
- Test: `Packages/macOS/CmuxGit/Tests/CmuxGitTests/WorkspaceChangesServiceTests.swift`

**Context:** The 15-second loaded-snapshot cache (`WorkspaceChangesLoadedSnapshotCache.swift`) and summary cache make "live" diffs stale for up to 15s. Add invalidation so the panel can force a refresh after a filesystem event.

**Step 1: Add `invalidate(forDirectory:)` to both caches**

`WorkspaceChangesLoadedSnapshotCache` — add `func invalidate(forDirectory directory: String)` that removes the entry (keyed by directory). Mirror in `WorkspaceChangesSummaryCache` (keyed by repo root — invalidate by directory by also removing any key matching, or accept the directory as-is; document the keying).

**Step 2: Add public API on the service**

In `WorkspaceChangesService.swift`:

```swift
/// Drops cached snapshots and summaries so the next read is fresh.
public nonisolated func invalidateCache(forDirectory directory: String) async {
    await loadedSnapshotCache.invalidate(forDirectory: directory)
    await summaryCache.invalidate(forDirectory: directory)
}
```

**Step 3: Wire `force:` through `changedFiles`**

`changedFiles` currently calls `loadedScopeAndSnapshot(forDirectory:)` without `force`. Add `public nonisolated func changedFiles(forDirectory: String, force: Bool = false)` passing `force:` through. Keep the existing signature callable (default `false`).

**Step 4: Test**

Test: read `changedFiles`, then write a working-tree change, then `changedFiles(force: true)` returns the new file while a non-forced read within 15s returns stale. Assert invalidation makes the forced read fresh.

**Step 5: Run tests**

Run the CmuxGitTests target. Expected: new tests pass.

**Step 6: Commit**

```bash
git add Packages/macOS/CmuxGit
git commit -m "feat(cgit): support forced refresh of workspace changes"
```

---

## Phase 2 — Provenance-aware directory resolver

### Task 3: Shared focused-local-directory resolver

**Files:**
- Create: `Sources/WorkspaceGitDiffDirectoryResolver.swift`
- Modify: `Sources/AppDelegate.swift` (refactor `openDiffViewerForFocusedWorkspace`'s directory selection to use it)
- Test: `Sources/../cmuxTests/WorkspaceGitDiffDirectoryResolverTests.swift` (wire into pbxproj per @cmux-testing)

**Context:** A workspace has multiple panels with different directories; remote terminals must not feed local Git. `resolvedWorkingDirectory()` (`Workspace.swift:4400`) has the right fallback order but no provenance check.

**Step 1: Write the resolver**

```swift
import Foundation

/// Resolves the effective local working directory to diff for a workspace.
///
/// Order: focused local panel's effective directory → requested directory →
/// workspace resolved working directory. Remote workspaces / remote terminal
/// panels resolve to `nil` (shown as unavailable).
struct WorkspaceGitDiffDirectoryResolver {
    func resolvedDirectory(
        for workspace: Workspace,
        focusedPanelId: UUID?
    ) -> String? {
        guard !(workspace.isRemoteWorkspace || workspace.isRemoteTmuxMirror) else {
            return nil
        }
        if let focusedPanelId, let panel = workspace.panels[focusedPanelId] {
            if let dir = panel.effectiveWorkingDirectory(), !workspace.isRemoteTerminalSurface(focusedPanelId) {
                return dir
            }
        }
        return workspace.resolvedWorkingDirectory()
    }
}
```

Adjust accessor names to the real `Workspace`/panel API during implementation (verify against `Workspace.swift`; do not invent). Keep it a pure function of `(workspace, focusedPanelId)` so it's testable.

**Step 2: Test**

Test with a fake workspace: local focused panel → its dir; remote workspace → nil; focused remote terminal panel → nil; no panel → `resolvedWorkingDirectory()`.

**Step 3: Refactor `AppDelegate` to use it**

In `openDiffViewerForFocusedWorkspace` (`AppDelegate.swift:6442`), replace the inline `focusedAgentWorkingDirectoryContext` + `fallbackCwd` selection with the resolver for the non-agent context path. Keep the agent-turn path as-is.

**Step 4: Run tests**

Run the cmuxTests target (compile + the new tests). Expected: green.

**Step 5: Commit**

```bash
git add Sources/WorkspaceGitDiffDirectoryResolver.swift Sources/AppDelegate.swift cmuxTests
git commit -m "refactor: shared workspace git diff directory resolver"
```

---

## Phase 3 — SidebarGitMetadataService invalidation stream

### Task 4: Expose a directory-keyed invalidation stream + `.git` active demand

**Files:**
- Modify: `Packages/macOS/CmuxSidebarGit/Sources/CmuxSidebarGit/Service/SidebarGitMetadataService.swift`
- Modify: `Packages/macOS/CmuxSidebarGit/Sources/CmuxSidebarGit/Service/SidebarGitMetadataService+Watchers.swift`
- Modify: `Packages/macOS/CmuxSidebarGit/Sources/CmuxSidebarGit/Service/SidebarGitMetadataService+SurfaceEvents.swift`
- Test: `Packages/macOS/CmuxSidebarGit/Tests/CmuxSidebarGitTests/ProbeSchedulingTests.swift`

**Context:** `SidebarGitMetadataService` already owns coalesced filesystem watchers. The diff panel needs (a) a typed stream to learn "this directory's git state changed," and (b) to keep the watcher alive even when left-sidebar git polling is disabled. Keep diff loading/caching in `WorkspaceChangesService`; this service only publishes.

**Step 1: Add a public invalidation continuation source**

Add a `@MainActor` continuation-backed `AsyncStream<WorkspaceGitInvalidationEvent>` (or a notification-based `Notification.Name`) keyed by directory. Define:

```swift
public struct WorkspaceGitInvalidationEvent: Sendable, Equatable {
    public let directory: String
}
```

Expose `public func diffInvalidations() -> AsyncStream<WorkspaceGitInvalidationEvent>` that forwards a replayable/buffered stream of coalesced filesystem events (deduped per directory). Emit from the existing watcher event loop in `SidebarGitMetadataService+Watchers.swift` where `recordWorkspaceGitMetadataFilesystemEvent` is called.

**Step 2: Add `.git` active-demand tracking**

Add a set of directories with active `.git`-panel demand. Public:

```swift
public func registerGitDiffDemand(for directory: String)
public func unregisterGitDiffDemand(for directory: String)
```

When demand is non-empty for a directory, `updateWorkspaceGitMetadataWatcher` (`SidebarGitMetadataService+Watchers.swift:11`) must create/keep the watcher even when `sidebarGitMetadataActivePollingEnabled` is false (treat `.git` demand as an additional "active" signal). Document that this is additive to the left-sidebar polling setting, not a replacement.

**Step 3: Test**

Test: register demand with polling disabled → watcher exists and events flow into the stream; unregister → watcher torn down; two registers dedupe to one watcher; events coalesce per directory.

**Step 4: Run tests**

Run the CmuxSidebarGitTests target. Expected: green.

**Step 5: Commit**

```bash
git add Packages/macOS/CmuxSidebarGit
git commit -m "feat(sidebargit): publish diff invalidation stream with git-panel demand"
```

---

## Phase 4 — RightSidebarMode.git integration

### Task 5: Add the `git` mode enum + availability + shortcut

**Files:**
- Modify: `Sources/RightSidebarPanelView.swift` (enum `RightSidebarMode` at line 16; `contentForMode` at 380; `selectMode` at 436; `FileExplorerRootSyncPolicy` at 72; `paneModes` at 59)
- Modify: `Sources/RightSidebarMode+Availability.swift`
- Modify: `Sources/RightSidebarRemoteCommand.swift:134`
- Modify: `Sources/ContentView+RightSidebarCommandPalette.swift:142`
- Modify: `Sources/KeyboardShortcutSettings.swift:92`
- Modify: `Sources/KeyboardShortcutSettings+ActionVisibility.swift`
- Modify: `Sources/KeyboardShortcutActionContext.swift:206`
- Modify: `Sources/AppDelegate+DockShortcutRouting.swift:81`
- Modify: `Sources/MainWindowFocusController.swift:741`
- Modify: `Sources/RightSidebarToolPanel.swift` (all four switches)
- Modify: `Packages/macOS/CmuxSettings/Sources/CmuxSettings/Values/ShortcutAction.swift:37`
- Modify: `Packages/macOS/CmuxSettings/Sources/CmuxSettings/Values/ShortcutAction+Defaults.swift:61`
- Modify: `web/data/cmux.schema.json:1616`

**Step 1: Add the enum case**

In `RightSidebarPanelView.swift`, add `case git` to `RightSidebarMode`. Add to `label` ("Git"), `symbolName` (use `"arrow.left.arrow.right"`), and `shortcutAction` (`.switchRightSidebarToGit`). **Do NOT add to `paneModes`** (sidebar-only).

**Step 2: Availability + CLI verb**

In `RightSidebarMode+Availability.swift`: add `case "git": return .git` to `from(cliArgument:)` and always-on in `isAvailable(feedEnabled:dockEnabled:)` (group with `.files,.find,.sessions`).

**Step 3: Shortcut action (mirrored enums)**

Add `switchRightSidebarToGit` to the `KeyboardShortcutSettings.Action` enum (`KeyboardShortcutSettings.swift`) AND the mirrored `CmuxSettings.ShortcutAction` enum (`ShortcutAction.swift`). Add default stroke in `ShortcutAction+Defaults.swift` (e.g. `ShortcutStroke(key: "6", control: true)` — verify no collision). Add label, group, priority, and action-visibility entries in `KeyboardShortcutSettings.swift`, `KeyboardShortcutSettings+ActionVisibility.swift`, and the `ShortcutAction` group/priority mapping (match the `.switchRightSidebarToDock` pattern at `ShortcutAction.swift:278`).

**Step 4: Routing + focus + tool panel**

Update every `switch` over `RightSidebarMode` to include `.git`:
- `RightSidebarRemoteCommand.swift:134` (usage text + argument parsing).
- `ContentView+RightSidebarCommandPalette.swift` (command palette IDs + title + shortcut action, follow the dock pattern).
- `KeyboardShortcutActionContext.swift:206` (routing).
- `AppDelegate+DockShortcutRouting.swift:81` (Dock forwarding).
- `MainWindowFocusController.swift:741` (focus target/endpoint — treat `.git` like `.dock`/non-file modes).
- `RightSidebarToolPanel.swift` — all four switches (`syncWorkspaceRoot`, `focus`, `ownedFocusIntent`, `RightSidebarToolPanelView` at 265): add `.git` to the non-file groups (`break`/empty).

**Step 5: JSON schema**

Add `git` to the right-sidebar mode enum values in `web/data/cmux.schema.json:1616`.

**Step 6: Compile check**

Run the compile-only build (see AGENTS.md):

```bash
xcodebuild -project cmux.xcodeproj -scheme cmux -configuration Debug -destination 'platform=macOS' -derivedDataPath /tmp/cmux-<tag> build
```

Expected: compiles with the new `.git` case exhaustive everywhere. Fix any missed exhaustive switches (this is the value of the task).

**Step 7: Commit**

```bash
git add Sources Packages/macOS/CmuxSettings web/data/cmux.schema.json
git commit -m "feat: register Git right-sidebar mode, shortcut, CLI, and schema"
```

---

## Phase 5 — The panel

### Task 6: `GitDiffPanelView` + view model

**Files:**
- Create: `Sources/GitDiffPanelView.swift`
- Create: `Sources/GitDiffPanelViewModel.swift`
- Test: `cmuxTests/GitDiffPanelViewModelTests.swift` (wire into pbxproj per @cmux-testing)

**Context:** View-only file list + native inline diff. Follow the SwiftUI list-boundary rule (@cmux-debugging): no observable model reference below a `LazyVStack`/`ForEach`, no writes from `body`. Parse diff rows off-main into immutable rows. Keep all git work off the main actor.

**Step 1: View model (`@MainActor @Observable`)**

```swift
@MainActor
@Observable
final class GitDiffPanelViewModel {
    enum State: Equatable {
        case loading
        case unavailable(String)      // not a repo / remote
        case error(String, retry: Bool)
        case loaded(GitDiffPanelSnapshot)
    }
    private(set) var state: State = .loading
    private var refreshGeneration: UInt64 = 0
    private var refreshTask: Task<Void, Never>?

    func setDirectory(_ directory: String?, force: Bool = false)
    func selectFile(_ path: String)
    func refresh()
    func cancelInFlight()
}
```

Hold `directory: String?`, `selectedPath: String?`, `snapshot: WorkspaceChangedFiles?`, `selectedDiff: WorkspaceFileDiff?` (or derived rows). Use the injected `WorkspaceChangesService`.

**Step 2: Immutable diff rows (off-main parse)**

Define `struct GitDiffRow: Identifiable, Equatable { let id: Int; let line: String; let kind: Kind }` where `Kind = header|hunk|addition|deletion|context|noNewline`. A pure static `GitDiffParser.parse(_ unifiedDiff: String) -> [GitDiffRow]` that distinguishes `+++`/`---`, `@@`, `\ No newline`, and `+`/`-`/context. Unit-test the parser directly (pure function, no app deps).

**Step 3: Refresh pipeline (lifecycle-gated)**

`setDirectory(_:force:)`:
1. `refreshGeneration &+= 1`; capture `let generation = refreshGeneration`.
2. If `directory == nil` → `state = .unavailable(...)`; return.
3. `guard sidebar visible && mode == .git` else return (gate supplied by the view/parent calling `setDirectory` only when mounted-and-visible).
4. `refreshTask = Task { @MainActor in ... }` that: calls `await service.changedFiles(forDirectory: dir, force: force)` off-main; on success, `guard generation == refreshGeneration else { return }`; set `state = .loaded(...)`; if a file is selected, load its diff via `await service.fileDiff(forDirectory: path:)` with the same generation guard.

All service calls are `nonisolated async` and already run off the main actor (`WorkspaceChangesService.swift`); do not wrap in a manual thread hop. Coalesce: if a `refreshTask` is running, cancel it before starting a new one.

**Step 4: Wire the invalidation stream**

In `setDirectory`, subscribe once: `for await event in service.diffInvalidations()` filter `event.directory == self.directory`, then call `self.setDirectory(self.directory, force: true)`. Keep the subscription task tied to the panel's lifecycle (`cancelInFlight` cancels both refresh and subscription tasks). This is the "live, debounced" update — no polling.

**Step 5: View**

`GitDiffPanelView` renders:
- Header: `branch` + base label — `comparisonBase == .mergeBase ? "vs \(baseRef)" : "uncommitted on \(branch)"`.
- List of files: status badge (A/M/D/R/U → color), path, `+N −M`. Tap → `viewModel.selectFile(path)`.
- Inline diff: `LazyVStack` of `GitDiffRow`s, monospaced, green `+` / red `-` / gray context; binary → "Binary file"; truncated → "diff truncated"; list >500 → "showing first 500 files".
- Empty: "No changes vs <base>" or "No changes".
- Non-repo / remote: "Not a git repository" / "Git unavailable on this workspace".
- Error: message + Retry.

Pass the snapshot and rows as **value types** into row subviews; never pass `viewModel` below the `LazyVStack`/`ForEach` boundary.

**Step 6: Mount in `contentForMode`**

Add `case .git: GitDiffPanelView(...)` in `RightSidebarPanelView.contentForMode` (line 380). Pass the workspace directory (via the new resolver from Task 3) and the invalidation-demand hooks (`registerGitDiffDemand` on appear, `unregisterGitDiffDemand` on disappear) plus the visibility/mode gate.

**Step 7: View-model tests**

Test: `setDirectory(nil)` → unavailable; non-repo service → unavailable; load → `.loaded` with files; select → diff rows populated; generation guard drops a stale result (simulate by two rapid `setDirectory` calls); subscription fires refresh on matching directory event; force bypasses cache (injected fake service returns fresh).

**Step 8: Run tests + build**

Run cmuxTests (new view-model + parser tests) and the compile-only build. Expected: green.

**Step 9: Commit**

```bash
git add Sources/GitDiffPanelView.swift Sources/GitDiffPanelViewModel.swift cmuxTests
git commit -m "feat: Git diff right-sidebar panel with inline diff"
```

---

## Phase 6 — Localization + dogfood

### Task 7: Localize all user-facing strings

**Files:**
- Modify: `Resources/Localizable.xcstrings` (all new `String(localized:)` keys from Tasks 5-6)
- Modify: `web/messages/en.json`, `web/messages/ja.json` (any CLI/remote-command help text)

**Step 1:** Audit every user-facing string added (mode label, shortcut labels, header/base labels, empty states, error rows, truncation notes). Add EN + JA entries. Follow @cmux-localization. State in the handoff what was audited.

**Step 2: Commit**

```bash
git add Resources/Localizable.xcstrings web/messages
git commit -m "chore: localize Git sidebar strings (en, ja)"
```

### Task 8: Tagged build + dogfood + PR

**Files:** none (workflow).

**Step 1:** Build a tagged Debug app and open it:

```bash
./scripts/reload.sh --tag git-diff-sidebar --launch
```

**Step 2:** Report the build as a markdown link to `http://127.0.0.1:17320/git-diff-sidebar`. Do not use `file://` or raw `.app` paths.

**Step 3:** Dogfood: open the sidebar, switch to Git mode, confirm changed files match `git status`, confirm inline diff matches `git diff`, confirm live update on edit (via the invalidation stream, no typing lag), confirm remote workspace shows unavailable, confirm default-branch (`main`) shows "uncommitted on main".

**Step 4:** If runtime behavior changes mid-dogfood, rebuild the tag and re-notify (per AGENTS.md).

**Step 5:** Open the PR (first-pass handoff per AGENTS.md): `gh pr create`. Include the two-commit regression structure only if a regression test pair is involved (not here — skip).

---

## Verification checklist (run before claiming done)

- [ ] `CmuxGitTests` green (comparison base, forced refresh).
- [ ] `CmuxSidebarGitTests` green (invalidation stream, `.git` demand, dedupe).
- [ ] `cmuxTests` green (view model, parser, resolver).
- [ ] Compile-only build succeeds (exhaustive `.git` switches).
- [ ] No observable store reference below a `LazyVStack`/`ForEach` in the panel.
- [ ] No git work on the main actor; no manual `git` polling loop.
- [ ] All new strings localized EN + JA.
- [ ] `web/data/cmux.schema.json` updated.
