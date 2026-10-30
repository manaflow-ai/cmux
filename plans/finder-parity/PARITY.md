# cmux Files pane: macOS Finder parity

Goal (u2360): a cmux pane kind that does everything Finder does, faster.
The Screenshots pane (worktree `screenshots-pane`) is one preset of this pane
(a fixed set of folders, newest first, gallery view). Both use one shared core:
`FileListing` (off-main listing + FSEvents), `FileGrid` (virtualized rows and
tiles), thumbnails, drag in/out.

Status key: `[x]` done on feat-cmux-next, `[~]` partial, `[ ]` not started.
Priority: P0 = first slice, P1 = next, P2 = later, P3 = only if asked.

## 1. Views

| # | Feature | Finder shortcut | Pri | Status |
|---|---|---|---|---|
| 1.1 | Icon view (grid of icons/thumbnails, size slider) | Cmd+1 | P0 | [~] |
| 1.2 | List view (columns: Name, Date Modified, Size, Kind; sortable headers) | Cmd+2 | P0 | [x] |
| 1.3 | Column view (Miller columns, preview column) | Cmd+3 | P0 | [~] |
| 1.4 | Gallery view (big preview + filmstrip) | Cmd+4 | P1 | [ ] |
| 1.5 | List view disclosure triangles (expand folders inline) | Right / Left, Opt+Right recursive | P1 | [ ] |
| 1.6 | Extra list columns (Date Created, Last Opened, Date Added, Version, Comments, Tags) | View > Show View Options | P2 | [ ] |
| 1.7 | Show View Options panel (icon size, grid spacing, text size, label position, show item info, show icon preview, "Always open in", "Browse in", relative dates, calculate all sizes) | Cmd+J | P1 | [ ] |
| 1.8 | Per-folder view settings persisted (.DS_Store-like, ours in app storage) | | P1 | [~] view and sort per folder, newest 500 folders in defaults; not icon size |
| 1.9 | Clean Up / Clean Up By / Sort By (icon view) | | P2 | [ ] |
| 1.10 | Group By (None, Name, Kind, Application, Date Last Opened/Added/Modified/Created, Size, Tags) "Use Groups" | Ctrl+Cmd+0 | P1 | [ ] |
| 1.11 | Calculate folder sizes in list view | | P2 | [ ] |
| 1.12 | Zoom icons (Cmd+= / Cmd+-) | | P1 | [~] status-bar slider; Cmd+= / Cmd+- only when the app menu does not take them |

## 2. Navigation

| # | Feature | Shortcut | Pri | Status |
|---|---|---|---|---|
| 2.1 | Open folder / open file with default app | Cmd+Down, Return-free double click | P0 | [x] |
| 2.2 | Enclosing folder | Cmd+Up | P0 | [x] |
| 2.3 | Back / Forward history | Cmd+[ / Cmd+] | P0 | [x] |
| 2.4 | Go to Folder sheet with path completion (Tab), `~` expansion, recents | Cmd+Shift+G | P0 | [~] |
| 2.5 | Go menu: Home, Desktop, Documents, Downloads, Applications, Utilities, Computer, Network, iCloud Drive, Recents, AirDrop | Cmd+Shift+H/D/O/L/A/U/C/K/I/F/R | P1 | [~] Home, Desktop, Documents, Downloads, Applications, Utilities, Computer, iCloud Drive; no Recents, Network, AirDrop |
| 2.6 | Recent Folders | | P2 | [ ] |
| 2.7 | Path bar (clickable segments, drag targets, Cmd+click opens) | Opt+Cmd+P | P0 | [~] |
| 2.8 | Title-bar path popup (Cmd+click title) | | P2 | [ ] |
| 2.9 | Type-select (type the start of a name to select it) | | P0 | [x] |
| 2.10 | Arrow-key nav in all views, Shift extend, Cmd+A select all, Opt+Cmd+A deselect | | P0 | [x] |
| 2.11 | Tab / Shift+Tab select next/prev alphabetically | | P1 | [x] |
| 2.12 | Spring-loaded folders on drag hover | | P2 | [ ] |
| 2.13 | Open in new tab (Cmd+double-click), new window | Cmd+T / Cmd+N | P1 | [ ] (cmux tab model covers it) |
| 2.14 | Reveal ("Show in Enclosing Folder") from search results | Cmd+R | P1 | [ ] |
| 2.15 | Connect to Server (smb/afp/nfs/ftp/webdav) | Cmd+K | P2 | [ ] |

## 3. Sidebar

| # | Feature | Pri | Status |
|---|---|---|---|
| 3.1 | Favorites (Recents, Applications, Desktop, Documents, Downloads, Home, user-added) | P1 | [~] defaults + user-added, persisted; no Recents |
| 3.2 | Locations (volumes, iCloud Drive, network, external disks with eject) | P1 | [~] mounted volumes with eject; no iCloud/network rows |
| 3.3 | Tags section (click to list tagged files via Spotlight) | P2 | [ ] |
| 3.4 | Drag folder into sidebar to add; drag out to remove; reorder | P1 | [~] drop to add and reorder; remove by menu, not by drag out |
| 3.5 | Show/hide sidebar | Ctrl+Cmd+S | P1 | [x] |
| 3.6 | Shared favorites with real Finder sidebar (LSSharedFileList is deprecated; read-only import) | P3 | [ ] |

## 4. Window chrome

| # | Feature | Shortcut | Pri | Status |
|---|---|---|---|---|
| 4.1 | Tabs (cmux pane tabs already do this) | Cmd+T | P0 | [x] (host) |
| 4.2 | Status bar (N items, X available, selection count, icon-size slider) | Cmd+/ | P1 | [x] |
| 4.3 | Toolbar: back/forward, view switcher, group, share, tags, action menu, search | Opt+Cmd+T | P1 | [ ] |
| 4.4 | Preview pane (right side, metadata, Quick Actions) | Shift+Cmd+P | P1 | [ ] |
| 4.5 | Customize toolbar | | P3 | [ ] |

## 5. Inspect

| # | Feature | Shortcut | Pri | Status |
|---|---|---|---|---|
| 5.1 | Quick Look (space), full screen, arrow through selection, index sheet | Space, Opt+Space | P0 | [~] |
| 5.2 | Get Info (kind, size, where, dates, comments, open with, permissions, locked, stationery, name & extension, preview) | Cmd+I | P1 | [~] kind, size (folder total in background), where, dates, owner, permissions, Locked, Hide extension; no comments, Open with, preview |
| 5.3 | Inspector (live Get Info for selection) | Opt+Cmd+I | P2 | [ ] |
| 5.4 | Show Package Contents | | P1 | [x] |
| 5.5 | Thumbnails (QLThumbnailGenerator, cached, off-main) | | P0 | [~] |
| 5.6 | Change permissions/owner in Get Info | | P2 | [ ] |

## 6. File operations

| # | Feature | Shortcut | Pri | Status |
|---|---|---|---|---|
| 6.1 | Rename inline (Return), extension-hide aware, select stem only | Return | P0 | [x] |
| 6.2 | Batch rename (Replace Text / Add Text / Format with index/counter/date) | | P1 | [x] |
| 6.3 | New Folder / New Folder with Selection | Shift+Cmd+N / Ctrl+Cmd+N | P0 | [x] |
| 6.4 | Move to Trash, with Put Back and Undo | Cmd+Delete | P0 | [~] |
| 6.5 | Delete Immediately | Opt+Cmd+Delete | P1 | [x] (with confirmation) |
| 6.6 | Empty Trash (with confirm) | Shift+Cmd+Delete | P2 | [ ] |
| 6.7 | Duplicate ("name copy") | Cmd+D | P0 | [x] |
| 6.8 | Make Alias / Symlink | Ctrl+Cmd+A | P1 | [x] alias and symlink |
| 6.9 | Copy / Cut-paste (Cmd+C, Cmd+Opt+V moves), Paste | Cmd+C/V, Opt+Cmd+V | P0 | [x] |
| 6.10 | Copy as Pathname | Opt+Cmd+C | P0 | [x] |
| 6.11 | Copy/move with progress, cancel, ETA (off-main, cancellable) | | P0 | [~] |
| 6.12 | Conflict UI: Keep Both / Stop / Replace / Apply to all, merge folders (Opt) | | P0 | [x] |
| 6.13 | Undo / Redo for rename, move, copy, trash, new folder | Cmd+Z / Shift+Cmd+Z | P0 | [x] |
| 6.14 | Compress (zip) / expand archives | | P1 | [~] zip only (ditto) |
| 6.15 | Burn / create disk image | | P3 | [ ] |
| 6.16 | Lock / unlock (uchg) | | P2 | [ ] |
| 6.17 | Eject volume | Cmd+E | P1 | [~] sidebar Eject; no Cmd+E |
| 6.18 | Show in Finder (escape hatch) | | P0 | [x] |

## 7. Drag and drop

| # | Feature | Pri | Status |
|---|---|---|---|
| 7.1 | Drag files out to other apps, terminals, chat composer (file URLs) | P0 | [x] |
| 7.2 | Drop files in (copy across volumes, move on same volume) | P0 | [x] |
| 7.3 | Modifiers: Opt = copy, Cmd = move, Opt+Cmd = alias; cursor badge | P0 | [x] |
| 7.4 | Drop onto folder rows, path bar segments, sidebar | P1 | [~] |
| 7.5 | File promises (NSFilePromiseReceiver: from Photos, Mail, screenshot thumbnails) | P1 | [ ] |
| 7.6 | Rubber-band (marquee) selection in icon view | P1 | [ ] |
| 7.7 | Drag to dock/trash | P3 | n/a |

## 8. Search and metadata

| # | Feature | Shortcut | Pri | Status |
|---|---|---|---|---|
| 8.1 | Filter current folder by name (instant, in-memory) | Cmd+F | P0 | [x] |
| 8.2 | Spotlight search (NSMetadataQuery / mdfind), scope This Mac vs current folder | Cmd+F | P1 | [ ] |
| 8.3 | Search tokens: Kind, Name matches, Contents, Date, Tags; raw query (`kMDItem...`) | | P1 | [ ] |
| 8.4 | Smart Folders (saved searches, `.savedSearch` read + write) | Opt+Cmd+N | P2 | [ ] |
| 8.5 | Tags: show colored dots, add/remove tags (Ctrl+Cmd+1..7), tag editor | | P1 | [ ] |
| 8.6 | Finder Comments (kMDItemFinderComment) | | P3 | [ ] |
| 8.7 | Recents (kMDItemLastUsedDate query) | | P2 | [ ] |

## 9. Open and integrate

| # | Feature | Pri | Status |
|---|---|---|---|
| 9.1 | Open (default app) / Open With submenu / Other… / Always Open With | P0 open, P1 Open With | [~] Open With (every LaunchServices app, default first, Other…), shared with Home; no Always Open With |
| 9.2 | Open in cmux: text and Markdown in cmux viewer, folder in terminal (cmux-native extras) | P0 | [x] by FileOpenKind: Markdown, HTML (rendered), images/PDF/media, text/code open in cmux beside the pane; apps and Office/archives in their app |
| 9.3 | Share menu (NSSharingServicePicker), AirDrop | P2 | [x] Share… (system picker, AirDrop included) |
| 9.4 | Services menu, Quick Actions (Rotate, Markup, Create PDF, Convert Image, Trim) | P2 | [ ] |
| 9.5 | Finder Sync extensions (Dropbox badges) | P3 | n/a |
| 9.6 | iCloud: download/evict ("Remove Download"), status badges (NSMetadataUbiquitousItem…) | P2 | [ ] |
| 9.7 | Network volumes, slow-volume tolerance (no main-thread stat) | P1 | [ ] |

## 10. Display options

| # | Feature | Shortcut | Pri | Status |
|---|---|---|---|---|
| 10.1 | Show hidden files | Cmd+Shift+. | P0 | [x] |
| 10.2 | Show all filename extensions (setting) | | P1 | [ ] |
| 10.3 | Sort folders first (setting) | | P1 | [~] |
| 10.4 | Live updates when files change (FSEvents) | | P0 | [x] |
| 10.5 | Localized display names (Desktop → "Desktop" in Japanese) | | P1 | [ ] |
| 10.6 | Context menus matching Finder's order | | P0 | [~] |
| 10.7 | Light/dark, accessibility (VoiceOver labels, keyboard only) | | P0 | [~] |

## Count

Rows: 90 (2 n/a). P0: 32. Progress: see "Slice 1 notes".

## Performance baseline (2026-10-19, Lawrence's Mac, load avg 14-17)

Folders: `/private/tmp/finder-parity-bench/d10000` and `d100000`
(empty `file-N.txt` files on APFS).

Finder cannot be timed to "first paint" without opening a window (which
steals focus), so Finder is timed through Apple Events, which run Finder's
own enumeration:

| Operation | 10k | 100k |
|---|---|---|
| Finder `count items of folder` (cold, warm) | 353 ms, 865 ms | 816 ms, 8 019 ms |
| Finder `name of every item` (list the names) | 4 797 ms | 56 257 ms |
| Swift `FileManager.contentsOfDirectory` + 4 keys | 27-31 ms | 225-232 ms |
| Swift `getattrlistbulk` + `localizedStandardCompare` sort | 45 ms | 479 ms |

Notes:
- `localizedStandardCompare` sort is ~400 ms of the 479 ms at 100k. The pane
  sorts on precomputed collation keys instead (see below).
- Targets for the cmux pane at 100k: first rows painted < 100 ms after open,
  full sorted list < 300 ms, scroll at 120 Hz with no dropped frames (only
  visible rows exist), filter-as-you-type < 16 ms per key at 10k.
- Measured numbers for the pane are appended under "Pane results".

## Slice 1 notes (what `[x]` and `[~]` mean today)

- `[~]` partial: 1.1 no icon-size slider; 1.3 no preview column; 2.4 no Tab
  completion in the sheet (the resolver has `completions`, not wired); 2.7
  NSPathControl, segments click but are not drop targets; 4.2 status line
  without free space; 5.1 Space and arrows, no full screen or index sheet; 5.5
  thumbnails in icon view only; 6.4 Undo puts back, no Put Back menu item in
  the Trash; 6.11 progress shows in the status line, no Cancel button yet; 7.4
  folder rows and tiles take drops, path bar and sidebar do not; 9.1 Open uses
  the default app, no Open With submenu; 9.2 text and code open in cmux's
  viewer, folders not yet "open in terminal"; 10.3 folders-first exists in the
  model, no setting; 10.6 menus cover the slice's commands only; 10.7 VoiceOver
  comes from AppKit tables, not audited.
- Keys that keep their cmux meaning inside a Files pane: Cmd+D (split; use the
  menu's Duplicate), Cmd+1/2/3 (workspaces; Files uses Ctrl+Cmd+1/2/3 for
  icons/list/columns), Cmd+[ and Cmd+] (cmux page history, which the pane
  plugs into, so they do step through folders).
- Of 88 countable items (90 rows, 2 n/a): `[x]` 28, `[~]` 23. Parity by
  weight (`[~]` = half): (28 + 11.5) / 88 = 45%. P0 rows only (32): (21 + 5.5) / 32 = 83%.
  `[x]` means built and unit-tested in the model; none is verified in a running app yet.

## Shared core for the Screenshots pane

The Screenshots pane (worktree `screenshots-pane`) should not list, watch or
draw files on its own. Use:

- `CmuxNextFiles`: `DirectoryLister` (or `DirectoryListing` for a fake),
  `FolderWatcher` (`FolderChange.items([name])` per child), `FileSortOrder(field: .created, ascending: false)` for newest first,
  `FileOperator` for trash, rename and copy with Undo via `FileBrowserModel`.
- `CmuxNextFilesUI`: `FileIconProvider` (shared type icons and
  `QLThumbnailGenerator` thumbnails with an `NSCache`), `FilePasteboard`, and
  the icon grid (`FileIconGridView`, internal today; make it `public` when the
  Screenshots pane imports it, or ask in plans/finder-parity/PARITY.md).
- A Screenshots pane is a `FileBrowserModel` per folder (Desktop, the
  `com.apple.screencapture location`, `$TMPDIR/../TemporaryItems/NSIRD_screencaptureui_*`, CleanShot's folder) merged newest first.

## Pane results

Measured 2026-10-19 on Lawrence's Mac (load average 14-17, so all numbers are
noisy upper bounds), with the core compiled `-O` outside the app
(`/tmp/finder-parity-scripts/filesbench`):

| Operation | 10k | 100k | Finder (same folder) |
|---|---|---|---|
| List (`DirectoryLister.listSync`) | 25-44 ms | 324-461 ms | `count items`: 353-865 ms / 816-8 019 ms |
| Sort by name (flat key, index sort) | 2 ms | 29-32 ms | (inside its 56 s `name of every item`) |
| Sort by date | 1 ms | 18-25 ms | |
| Filter one keystroke (ASCII byte match, 2026-10-20, load 44-54) | 1 ms | 6-8 ms (was 52-64 ms with Foundation folding) | |
| Scroll | NSTableView reuses cells: rows on screen only | same | |

Not measured yet: first paint inside the app (needs a running build), scroll
frame times.
