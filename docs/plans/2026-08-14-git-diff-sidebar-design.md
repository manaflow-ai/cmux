# Design: Git Diff right-sidebar mode (view-only, vs default branch)

Date: 2026-08-14 (rev 3 — addresses codex review of rev 2)

## Goal

Add a new right-sidebar mode ("Git") that shows the current workspace's git
diff against the repository's default branch (main/master), as a file list with
an inline diff. View-only: no staging, committing, or sync operations.

## Decisions (confirmed with user)

- **Location:** new `RightSidebarMode.git` tab in the existing right sidebar
  (⌘⌥B), alongside Files/Find/Vault/Feed/Dock.
- **Diff style:** file list + inline diff rendered natively in SwiftUI.
- **Operations:** view-only.
- **Base branch:** the repo's default branch (main/master), resolved
  automatically.
- **Refresh:** live, debounced, reusing the existing sidebar git metadata
  watcher/refresh machinery (no polling; must not regress #4705 typing
  latency).

## Architecture

- New `RightSidebarMode.git` case in `Sources/RightSidebarPanelView.swift`:
  label "Git", SF Symbol, a `KeyboardShortcutSettings.Action`
  (e.g. `.switchRightSidebarToGit`), availability always-on (like
  Files/Find/Vault). **Not** in `paneModes` (sidebar-only).
- New `GitDiffPanelView` (SwiftUI) mounted in `contentForMode`'s switch.
  New file `Sources/GitDiffPanelView.swift`, following the
  `FileExplorerPanelView` / `DockPanelView` pattern.
- **Data source:** `WorkspaceChangesService`. It resolves the default branch
  and compares from its merge base.
- **Live updates:** reuse `SidebarGitMetadataService`'s existing filesystem
  watchers + debounced refresh as the event seam (see "Live updates" below).
  The diff path uses its own concurrency budget, not the metadata
  `WorkspaceGitMetadataProbeLimiter` or snapshot cache.

## Live updates (corrected — the key change from rev 1)

Rev 1 claimed reuse of the "gitIndexSnapshot pipeline." That is wrong: the
`gitIndexSnapshot` parser (`GitMetadataService+Index.swift`) is a stateless
read, not an event stream. The actual live-update infrastructure is
`SidebarGitMetadataService` (`Packages/macOS/CmuxSidebarGit/.../Service/`),
which already owns:

- `RecursivePathWatcher` instances on each tracked directory's git paths
  (`SidebarGitMetadataService+Watchers.swift`), coalescing filesystem events.
- Debounced refresh scheduling with retry offsets and a 5-minute fallback
  (`SidebarGitMetadataService+Probe.swift`).
- A process-wide `WorkspaceGitMetadataProbeLimiter` capping concurrent git
  subprocesses.
- Per-directory snapshot dedupe and generation counters.

**Plan:** keep `WorkspaceChangesService` as the sole owner of diff loading and
caching. `SidebarGitMetadataService` only *publishes coalesced filesystem
invalidations* and tracks explicit `.git`-panel demand — it does not load or
cache diffs (that would fight its metadata-probing boundary,
`SidebarGitMetadataServing.swift:3`). Add a typed, directory-keyed
`AsyncStream`/notification on the watcher service. The panel consumes it and
calls into `WorkspaceChangesService`'s forced-refresh/invalidation API; only
`WorkspaceChangesService` owns the diff cache.

**Lifecycle gating (must be explicit, per #4705):** the diff refresh work must
be gated on ALL of:

- right sidebar visible;
- active mode is `.git`;
- the local repository directory is unchanged;
- the current refresh generation is still authoritative (stale-result
  rejection).

Because sidebar content stays mounted when hidden
(`RightSidebarPanelView.swift:66,377`), `.onDisappear` alone will not stop
refresh work. The panel must cancel/replace in-flight loads on directory or
focus change, and coalesce trailing-edge refreshes (the watcher can fire ~4×/s
during sustained writes — `RecursivePathWatcher.swift:17`). All parsing and
git work stays off the main actor; only compact immutable snapshots cross to
SwiftUI.

**Additional gating (codex rev 2):**
- Watchers only exist when the current settings enable active Git polling
  (`CmuxSettingsJSONPathSupport.swift:81`,
  `SidebarGitMetadataService+Watchers.swift:11`). Visible `.git` mode must
  independently register *active demand* so the watcher is created/kept even
  when left-sidebar polling is off, and must be released when the panel is
  hidden/closed or mode changes.
- `WorkspaceChangesService` keeps a 15-second loaded-snapshot cache
  (`WorkspaceChangesLoadedSnapshotCache.swift:3`) and `changedFiles` exposes no
  force/invalidate path (`WorkspaceChangesService.swift:160`). The panel needs
  a cache-invalidation/forced-refresh API so "live" results are not stale for
  up to 15s.
- The metadata snapshot cache and `WorkspaceGitMetadataProbeLimiter` explicitly
  cover metadata probes only (`SidebarGitMetadataService.swift:34`,
  `WorkspaceGitMetadataProbeLimiter.swift:3`). The diff path needs its own
  concurrency/coalescing controls (its own bounded git subprocess budget)
  rather than borrowing those.

## Comparison semantics (corrected)

`WorkspaceChangesSnapshotLoader.resolveScope` (`WorkspaceChangesSnapshotLoader.swift:44`)
only compares against the default branch's merge base when a default ref
resolves AND the checked-out branch differs from it; otherwise it falls back to
`HEAD`. On the default branch `baseRef` is `nil` (`WorkspaceChangesModel.swift:128`).

The panel must therefore surface the **actual comparison base** it used, not
assume "vs main." Header shows the resolved base ref when present (e.g.
`main`), and a distinct label when comparing against `HEAD` (e.g. "uncommitted
changes on <branch>"). The empty state must not claim "No changes vs main"
when the base could not be resolved. If the UI needs to distinguish
"on default branch, comparing to HEAD" from "default branch unresolved," the
model needs an explicit comparison-semantics field. This must propagate from
the internal `WorkspaceChangesScope` into **`WorkspaceChangedFiles`** (the type
the panel consumes — `WorkspaceChangesModel.swift:120`), not merely the summary
model (`WorkspaceChangesService+Values.swift:9`).

## Directory routing (corrected)

"workspaceCwd" is undefined — a workspace has multiple panels with different
directories. Adopt the existing diff action's rule
(`AppDelegate.swift:6452`): prefer the focused local panel's effective
directory, falling back to `resolvedWorkingDirectory()`. **Provenance note
(codex rev 2):** `resolvedWorkingDirectory()` has the right focused-panel →
requested-directory → workspace fallback order but performs no local/remote
provenance check (`Workspace.swift:4400`); the mobile path gates workspace-level
provenance (`TerminalController+MobileWorkspaceChanges.swift:268`). A shared
**provenance-aware resolver** is required so a focused remote terminal can never
supply a remote path to local Git. Remote workspaces / remote terminal panels
are shown as unavailable (empty state). Changing focus/CWD cancels and replaces
in-flight loads.

## UI layout

- Header: branch name + resolved base ref (or "uncommitted on <branch>"), and a
  refresh affordance.
- File list: status badge (A/M/D/R — **no `U`**, see below), path, `+N −M`
  counts. Click → inline diff below (or a split: list left, diff right).
- Inline diff: monospaced, green `+` / red `-` lines; binary files show a
  "Binary file" placeholder.

## Status badges (corrected)

`WorkspaceChangeStatus` has only added/modified/deleted/renamed/untracked
(`WorkspaceChangesModel.swift:61`); the parser maps Git's `U` to `.modified`
(`WorkspaceChangesParser.swift:133`). **Drop `U`** from the UI. If conflict
display is wanted later, extend the package model/parser + tests first.

## Diff rendering performance

Diffs can reach 6,000 lines / 400 KiB (`WorkspaceChangesService+FileDiff.swift:4`).
Parse the unified diff off-main into stable immutable rows (distinguishing
`+++`/`---` headers, hunk headers, context, and no-newline markers — not just
first-char coloring). Render lazily; do not pass an observable model below the
`LazyVStack`/`ForEach` boundary (per the #2586 list-boundary rule).

## Error handling

- Non-repo → empty state.
- Remote workspace / remote panel → unavailable empty state.
- Git failure → inline error row with retry.
- Truncated diffs (size cap) → "diff truncated" note.
- List truncation (500-file cap) → "showing first 500 files" note.
- All strings localized (EN + JA) per `cmux-localization`.

## Integration points (complete list)

Beyond the enum + `contentForMode`, update:

- `Sources/RightSidebarMode+Availability.swift` (availability + CLI verb).
- `Sources/RightSidebarRemoteCommand.swift:134` (remote-command usage text).
- `Sources/ContentView+RightSidebarCommandPalette.swift:142` (command-palette
  IDs + exhaustive switches).
- `Sources/KeyboardShortcutSettings.swift:92` (shortcut action, label, default
  binding).
- `Sources/KeyboardShortcutActionContext.swift:206` (shortcut routing/context).
- `Sources/AppDelegate+DockShortcutRouting.swift:81` (Dock shortcut
  forwarding).
- `web/data/cmux.schema.json:1616` (public JSON schema).
- Localization catalog + existing sidebar/shortcut/CLI tests.
- All `RightSidebarToolPanel` switches need an explicit non-pane `.git` case to
  compile.

**Additional integration points (codex rev 2):**
- Mirrored `CmuxSettings.ShortcutAction` enum / default / display / group /
  priority mappings (`Packages/macOS/CmuxSettings/.../Values/ShortcutAction.swift:37`,
  `ShortcutAction+Defaults.swift:61`).
- App shortcut visibility (`Sources/KeyboardShortcutSettings+ActionVisibility.swift:4`).
- Right-sidebar focus target/endpoint switches
  (`Sources/MainWindowFocusController.swift:741`).
- `WorkspaceChangesService` composition/injection: it is **not** currently
  injected through `TabManager`; the only production owner found is
  `MobileHostService.shared` (`TabManager.swift:479`, `Mobile/MobileHostService.swift:223`).
  A composition-root injection point must be added so the panel shares one
  instance and the injected service is testable.
- The new `WorkspaceChangesService` cache-invalidation/forced-refresh API and
  the shared provenance-aware directory resolver (both net-new).

## Relationship to the standalone `cmux diff` viewer

Keep the standalone `cmux diff` viewer (`AppDelegate.swift:6426`) as the richer
full-window viewer. Both features share only the focused-directory resolver so
the two Git-diff entry points never disagree on which repo/directory they show.

## Testing

- Unit tests in `CmuxGitTests` for the diff-vs-default-branch path (already
  covered by `WorkspaceChangesServiceTests`), plus new tests for the
  comparison-semantics field propagating into `WorkspaceChangedFiles` and for
  the new cache-invalidation/forced-refresh API.
- New `CmuxSidebarGitTests` for the invalidation seam: watcher event → typed
  invalidation emission, `.git` active-demand registration/release, and
  directory-keyed streams.
- New panel view-model tests: file list mapping, status badges, empty/non-repo/
  remote states, selection→diff, list truncation, and diff-refresh lifecycle
  gating (hidden sidebar, non-`.git` mode, directory change, stale generation,
  trailing-edge debounce, cancellation). Follow `cmux-testing` wiring
  (PBXFileReference + PBXSourcesBuildPhase).

## Out of scope

- No stage/commit/push/pull (view-only).
- No commit graph, ahead/behind counts, or multi-repo aggregation.
- No conflict (`U`) status display.
