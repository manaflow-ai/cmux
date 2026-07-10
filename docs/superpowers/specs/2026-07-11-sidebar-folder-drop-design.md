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
- **Drop zone:** the sidebar / vertical-tab area only. Not the terminal or
  browser panes (those already have their own file-drop behavior).
- **Accepted items:** folders only. Dropped files are rejected (no accept
  highlight, drop does nothing). No "open at parent folder" behavior.
- **Multiple folders in one drop:** each valid folder opens its own tab.

## Non-goals

- No files (folders only).
- No launching an agent on drop, no path-insertion into a terminal.
- No settings toggle for the feature. It is always on.
- No change to the sidebar's existing internal drag (workspace/tab reordering).
- No new workspace/tab data model. Reuse the existing one.

## Approach (A: native drop into the internal workspace API)

Add a native macOS drag destination to the sidebar root view that accepts file
URLs, filters to directories, and calls Cmux's existing new-workspace path with
the dropped folder as the working directory.

Cmux already solves both halves of this, so the work is wiring, not invention:

- **File-drop precedent to mirror:** `Sources/FileDropOverlayView.swift`,
  `Sources/FileDropOverlayViewHitTesting.swift`,
  `Sources/TerminalPaneDropTargetView.swift`,
  `Sources/BrowserPaneDropTargetView.swift`. These show the codebase's
  established pattern for accepting external file URLs on a view. The sidebar
  drop target follows the same pattern.
- **New-workspace-with-cwd precedent:** `TabManager.openWorkspace(
  fromSavedLayout:cwdOverride:focus:)` (in
  `Sources/TabManager+SavedLayouts.swift`) and
  `TabManager.addWorkspace(...)` (in
  `Sources/TabManager+DetachedWorkspace.swift`) already create workspaces and
  already accept a working-directory override. The drop handler calls the same
  entry point the normal "new workspace" action uses, passing the dropped
  folder as the cwd. Exact signature to confirm during implementation via a
  code-exploration pass; the plan pins it down before code is written.

### Why not Approach B (shell out to the control socket/CLI)

Rejected. Spawning a subprocess on every drop is clunky, depends on the `cmux`
CLI being on PATH, and is slower than an in-process call. Kept only as a
fallback if the internal new-workspace entry point turns out to be
unreachable cleanly from the sidebar view (not expected).

## Architecture

New, self-contained unit inside the sidebar layer (main app `Sources/`,
alongside the existing sidebar drop files), with one clear job.

1. **Sidebar folder-drop target (new).** A view/overlay attached to the sidebar
   root that registers for file-URL drags.
   - On drag-enter/updated: inspect the dragged URLs. If at least one is a
     directory, show the accept highlight and report a "copy"/"link" operation.
     If none are directories, reject (no highlight, no drop).
   - On perform-drop: collect the dropped URLs, keep only directories, and for
     each call the new-workspace handler with that directory as cwd.
   - Does not interfere with the sidebar's internal reorder drag, which uses a
     different, app-internal drag type. Folder drops carry file URLs; reorder
     drags carry the internal workspace-id type. The target only claims the
     file-URL type.

2. **Folder-filter helper (new, pure).** A tiny pure function:
   input = list of dragged URLs, output = list of existing directory URLs
   (deduped, order preserved). This is the unit-testable core and holds the
   folders-only rule. No AppKit, no I/O beyond a directory-exists check that is
   injected so tests can stub it.

3. **New-workspace call (existing).** The drop target calls the existing
   `TabManager` new-workspace path with `cwdOverride` set. No new creation
   logic.

## Data flow

Finder drag → sidebar drop target receives `[URL]` → folder-filter helper keeps
directories only → for each directory, `TabManager` new-workspace(cwdOverride:
dir) → new tab appears in sidebar, focused on the last dropped folder.

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
