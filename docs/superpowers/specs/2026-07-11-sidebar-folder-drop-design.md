# Sidebar folder drag-and-drop - design

Date: 2026-07-11
Fork: `wasimjalali/cmux` (branch `feat/sidebar-folder-drop`)
Upstream: `manaflow-ai/cmux` (GPL-3.0-or-later)

## Goal

Let me drag a project folder from Finder onto the Cmux sidebar and have it open
as a new workspace tab whose working directory is that folder. Personal build,
run side-by-side with the released Cmux.

## Scope (decided)

- **Drop action:** each dropped folder opens one new workspace tab, cd'd into
  that folder.
- **Tab title:** the workspace's big sidebar title is the folder's name (last
  path component), not the full path. Passed as `title:` to `addWorkspace`,
  which pins it via `setCustomTitle`. (v2, 2026-07-11)
- **Auto-run Claude Code:** the new tab's terminal runs `claude` on open, via
  `initialTerminalInput: "claude\n"` (typed into the login shell, so the shell
  survives when claude exits). (v2, 2026-07-11)
- **Drop zone:** the sidebar / vertical-tab area only. Not the terminal or
  browser panes (those already have their own file-drop behavior).
- **Accepted items:** folders only. Dropped files are rejected (no accept
  highlight, drop does nothing). No "open at parent folder" behavior.
- **Multiple folders in one drop:** each valid folder opens its own tab, each
  titled with its folder name and each auto-running claude.

## Non-goals

- No files (folders only).
- No path-insertion into a terminal for sidebar drops (that stays terminal-pane
  behavior).
- No settings toggle for the feature. It is always on.
- No change to the sidebar's existing internal drag (workspace/tab reordering).
- No new workspace/tab data model. Reuse the existing one.

## Build / install reality (2026-07-11)

- **New `.swift` files must be hand-wired into `cmux.xcodeproj/project.pbxproj`**
  (4 entries each; validated by `scripts/lint-pbxproj-test-wiring.sh`), or Xcode
  silently ignores them.
- **The bundled `ghostty` CLI helper cannot be compiled on macOS 26:** the pinned
  Zig 0.15.2 fails to link the macOS 26.5 SDK (undefined libSystem symbols). The
  real helper is taken prebuilt from upstream release `v0.64.17` (universal,
  Ghostty 1.3.2) and installed via `scripts/install-prebuilt-ghostty-cli-helper.sh`.
  The terminal itself renders via the prebuilt `GhosttyKit.xcframework`, unaffected.
- **Production build:** Release config (`PRODUCT_NAME = cmux`, not "cmux DEV").
  Built ad-hoc with entitlements cleared (no dev cert / team locally), real helper
  installed, re-signed inside-out (no `--deep`), installed to `/Applications/cmux.app`.
  Full procedure in `docs/superpowers/plans/2026-07-11-sidebar-folder-drop-v2.md`.

## Approach (A: native drop into the internal workspace API)

Handle the folder drop inside the existing window-level Finder drop overlay,
`FileDropOverlayView`, gated by a sidebar-region check, and call Cmux's existing
new-workspace path with the dropped folder as the working directory.

**Why the window overlay and not a sidebar-embedded view (confirmed by code
exploration):** `FileDropOverlayView` is a transparent NSView installed on the
window theme frame above the whole content hierarchy. Its `hitTest` captures
every Finder file-URL drag across the entire window, sidebar strip included,
with no region filtering (`Sources/FileDropOverlayView.swift:115-146`). AppKit
only delivers dragging-destination messages to the view `hitTest` returns, so a
separate NSView embedded in the sidebar would never receive a file-URL drag. It
would be dead code. The feature therefore extends `FileDropOverlayView`.

Cmux already provides the two building blocks, so the work is wiring:

- **New-workspace-with-cwd (existing, verified):**
  `TabManager.addWorkspace(workingDirectory: url.path)` is `@MainActor`, returns
  `Workspace`, and is exactly what the command-palette "Open Folder" handler
  already calls (`Sources/ContentView.swift:7573`, after a directory-only
  `NSOpenPanel`). This is the canonical call for "open a folder as a new
  workspace." The drop handler calls it once per dropped directory.
- **File-URL reading (existing, verified):**
  `PasteboardFileURLReader.fileURLs(from: sender.draggingPasteboard) -> [URL]`
  (`Sources/TerminalImageTransfer.swift:35-78`).

### Why not Approach B (shell out to the control socket/CLI)

Rejected. Spawning a subprocess on every drop is clunky, depends on the `cmux`
CLI being on PATH, and is slower than an in-process call.

## Architecture

Three new units plus a surgical change to the existing overlay.

1. **`SidebarDropRegionRegistry` (new).** Mirrors the codebase's existing
   `MinimalModeTitlebarControlHitRegionRegistry` (`WindowDragHandleView.swift`).
   Holds weak references to registered sidebar-probe NSViews and answers
   `containsWindowPoint(_ windowPoint: NSPoint, in window: NSWindow) -> Bool` by
   converting a registered probe's bounds to window coordinates. Keeps
   everything in AppKit window space (same space as
   `NSDraggingInfo.draggingLocation`), so no SwiftUI-global coordinate flips.

2. **`SidebarDropRegionProbe` (new).** A tiny `NSViewRepresentable` whose backing
   NSView spans the sidebar and registers/unregisters itself with the registry
   on move-to-window. Mounted as a `.background` of the sidebar container in
   `ContentView`. Being inside the sidebar means its frame *is* the sidebar
   region. Handles width, visibility and resize automatically via layout.

3. **`DirectoryDropFilter` (new, pure).** `directories(among urls: [URL],
   isDirectory: (URL) -> Bool) -> [URL]` keeps existing directories, deduped by
   path, order preserved. The `isDirectory` predicate is injected (default:
   `FileManager.fileExists(atPath:isDirectory:)`) so the rule is unit-testable
   with no filesystem. This is the folders-only rule.

4. **`FileDropOverlayView` change (existing, surgical).** Add one private helper
   that classifies a drag: `.openFolders([URL])` when the drop point is over the
   sidebar and at least one URL is a directory; `.rejectOverSidebar` when over
   the sidebar with no directories; `nil` when not over the sidebar. Wire it into
   the three NSDraggingDestination lifecycle methods:
   - `draggingEntered`/`draggingUpdated` (via `updateDragTarget`): return `.copy`
     for `.openFolders`, `.none` for `.rejectOverSidebar`, else existing
     behavior. Returning `.copy` here is mandatory or AppKit never delivers the
     drop.
   - `prepareForDragOperation`: `true` for `.openFolders`, `false` for
     `.rejectOverSidebar`, else existing.
   - `performDragOperation`: for `.openFolders`, call a new
     `onFoldersDroppedOnSidebar: (([URL]) -> Bool)?` closure (set in
     `configureFileDropOverlay`, capturing `tabManager`, opening one workspace
     per folder) and return its result; `.rejectOverSidebar` returns `true`
     (consumed, no-op); else existing behavior.

   The `.rejectOverSidebar` branch is what stops a file dropped on the sidebar
   from falling through and pasting its path into the focused terminal.

## Data flow

Finder drag over sidebar → `FileDropOverlayView` lifecycle methods →
classify via `SidebarDropRegionRegistry.containsWindowPoint` +
`DirectoryDropFilter` → `.openFolders(dirs)` → `onFoldersDroppedOnSidebar`
closure → `tabManager.addWorkspace(workingDirectory:)` per dir → new tab(s)
appear, last dropped folder focused.

## Error handling (fail loud, no silent fallbacks)

- **No directories in the drop:** target rejects during drag-enter, so the drop
  never lands. Nothing happens, no error. This is expected, not a failure.
- **A folder no longer exists at drop time** (rare race): skip that URL, do not
  create an empty-cwd workspace. If every URL is gone, do nothing. This is a
  skip of invalid input, not a swallowed error.
- **New-workspace call itself fails:** let it surface the way Cmux already
  surfaces new-workspace failures. Do not wrap it in a catch that hides it.

## Testing

- **Unit (added to `cmuxTests` or the sidebar package tests):** the
  folder-filter helper. Cases: all folders, mix of files and folders, files
  only (empty result), a non-existent path (dropped), duplicates (deduped),
  order preserved.
- **Manual verification (the real check):** build the DEV app, drag a Finder
  folder onto the sidebar. Assert: accept highlight appears for a folder,
  does not appear for a lone file, a new tab opens after drop, the new tab's
  terminal is cd'd into the dropped folder. Drag two folders at once, assert
  two tabs open.

## Build and install

Per the fork's `CONTRIBUTING.md`:

- Prereqs: full Xcode (pinned 26.0 via `.xcode-version`), Zig
  (`brew install zig`). Xcode is being installed by Wasim; Zig and the rest are
  handled here.
- `./scripts/setup.sh` once (inits submodules incl. `ghostty`, builds
  `GhosttyKit.xcframework` via Zig, makes symlinks).
- `./scripts/reload.sh --tag dragdrop --launch` builds and opens the Debug
  `cmux DEV.app`, which runs alongside the released Cmux.

## Change management

Feature branch `feat/sidebar-folder-drop`. Adversarial review is not triggered
(no auth, DB, payments, secrets, or privileged data paths; this is local UI
wiring). Commit, push to the fork, open a PR against the fork's own `main` for
CodeRabbit review, then merge. No PR against upstream unless Wasim decides to
contribute it back.
