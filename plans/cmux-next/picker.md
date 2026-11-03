# The cmux picker (R89)

Owner: R89 (this branch, feat-cmux-next-r89-picker). Lawrence's decision: cmux uses its own picker everywhere, no NSOpenPanel or NSSavePanel. The dialogs lead (R96) replaces every system panel with it.

API (CmuxNextApp/Viewers/CmuxPicker.swift, models in CmuxNextPalette/FolderPicker):
- `services.viewers.picker.open(CmuxPicker.OpenOptions) async -> [URL]?`: `choose` (.files, .folders, .filesOrFolders), `allowsMultiple`, `types: [UTType]` (empty: any file), `allowsAllFiles` (the user may switch the filter off), `startDirectory`, `title`, `prompt`, `recents` (ViewerRecents kinds sorted first), `filter` (a cmux-named filter such as `.markdown`).
- `services.viewers.picker.save(CmuxPicker.SaveOptions) async -> URL?`: `name` (prefilled, its name part selected), `types` (the default first; Save As rows for the others), `startDirectory`, `title`, `prompt`.
- Both return nil when the user leaves. `openPage(_:onFinish:)` and `savePage(_:onFinish:)` give the palette page for an action the palette pushes in place (`PaletteSources.actionPages`).
- Overwrite: `PickerOverwriteConfirming`. CmuxDialog does not exist yet, so `PalettePageOverwriteConfirmation` (a palette page, Cancel selected) is the temporary implementation. A CmuxDialog conformer goes in `PickerEnvironment.overwrite`; nothing else changes.

Interaction (PICKER-PATHS, approved 2026-10-04): typing filters the folder shown, always (fuzzy, prefix matches first in Finder order, `c2` before `c10`; a leading `.` lists hidden entries). There are no single-key jumps: `~` alone is text. A query that starts with `/` or `~/` is PATH mode: it completes the typed path one segment at a time (Tab or Right completes the selected segment, Return goes there; `~/` means home only here). At the start folder an empty query shows Locations: Recent (a page of the recent folders and files), the focused workspace's folders, Home, Desktop, Documents, Downloads, iCloud Drive (when present), then `picker.pinned`. Tab or Right enters a folder; Left at the start of the query, Backspace on an empty query, or Cmd-Up goes to the parent; the footer's path segments are clickable; Return chooses (a file picker enters folders); Cmd-Return marks items when several may be chosen; Up/Down, Ctrl-N/Ctrl-P, Home/End and Page Up/Down move; Escape clears the query (and leaves path mode), then closes. A hint under the field says "Type to filter, or start with / to type a path". Save: the query is the name, folders stay listed, `folder/name` goes to the folder, New Folder… makes and enters one.

Settings (PAGE-PREFS: picker preferences are `picker.*` keys in the settings store, read through the host): `picker.pinned` (array of absolute or `~/` folder paths; parsed in CmuxNextSettings `PickerPinnedSetting`, `CmuxConfigSnapshot.pickerPinned`; no Settings UI row or schema row yet, for the Settings lead). Show hidden and sort are not preferences yet (hidden: a leading `.`; sort: Finder order). Two user defaults hold state, not preferences: `picker.privacyExplainerShown` and `viewer.recents.v1`.

Privacy: a level is read only when the user opens it, off the main actor, at most 2,000 entries per page (Show More) and 200,000 names scanned. Listing never probes inside Desktop, Documents, Downloads, Library, Movies, Music, Pictures, iCloud Drive or a volume. The first visit to a protected folder shows one explainer (remembered in the user default `picker.privacyExplainerShown`); a refused folder shows an inline row and Open Privacy Settings.

Recents: `ViewerRecents` (user default `viewer.recents.v1`), kinds diff, markdown and file. `hostOpValue(.diff)` and `hostOpValue(.markdown)` answer `cmux.diff.recents` and `cmux.markdown.recents` in the diff-host.md "Empty state" shape. The diff host (S4) keeps its own recents (`DiffRecents`, which answers `cmux.diff.recents` and records every open); the picker reads them for its diff Locations, and `cmux.diff.chooseFolder` asks with the picker (`PickerDiffFolderChooser`). `ViewerService.chooseMarkdownFile(start:)` is ready for `cmux.markdown.chooseFile` (S6); every open through `openFile` records.

Diff: `DiffPageService` conforms to `DiffViewerOpening` and is `ViewerService.diffViewer`; the open actions have one path (ViewerHandlers). Open items: cmux-next has no file viewer surface: a chosen file opens through `ViewerService.fileOpener` (`FileOpening`), `BrowserTabFileOpener` (the browser tab's file view, as `file.open`) until the code editor page (cmux.editor) conforms. S6 takes Markdown files. R85 (`list.next`/`list.previous` with Ctrl-J/Ctrl-K) is not on feat-cmux-next; the picker adds no key handling for it and inherits it when it lands.

## The system open panel on the click path (PL-fleet-gui, 2026-10-23)

Home's "+", an agent composer's Add Files / Attach and every WebKit view's `<input type="file">` (cmux pages on WebKit and
WebKit browser tabs, one path: `WebFileInputAnswering`) still use `NSOpenPanel` (the made-ahead `MadeAheadOpenPanel`, one
instance made at the composition root).

Chromium is not on that path. Chromium is the default engine for browser tabs and for cmux pages (`PageWebView` follows
`browser.defaultEngine`), and the CEF shim (`shim_client.mm`) has no `CefDialogHandler`: a Chromium file input runs
Chromium's own `SelectFileDialog`, which makes a new `NSOpenPanel` on the main thread for each click, not made ahead and
with no dead-panel guard (a cold 160 to 830 ms per click; with a hung or absent panel service about 40 s, and the page may
wait forever). Open, routed to the CEF owners (session cmux-b6): `CefDialogHandler::OnFileDialog` sends a file-dialog event
to Swift, which answers through `WebFileInputAnswering` (`Continue` with the paths, `Cancel` on nil), for Chromium browser
tabs and Chromium-hosted cmux pages.

Browser tabs do not start the warm-up (`warmWhenIdle`); an agent pane and Home do. Decision (2026-10-23): almost every
session has a browser tab and few of them use a file input, so warming from a tab would put the panel's 160 to 830 ms (and,
with a hung panel service, the 40 s freeze) on nearly every session to save it on a rare click. A session with only
browser tabs pays the cold panel on its first file-input click. cmux's own picker (below) removes the cost for both.

What of the panel can block the main thread, measured with
`debug.open_panel_bench` (`scripts/cmux-next/open-panel-bench.py`; `split-spring.sh --suite=open-panel` on the fleet):

| Where | Panel | Getting it (`init_ms`) | `beginSheetModal` call | Sheet on screen |
| --- | --- | --- | --- | --- |
| mac26, macOS 26.5, 60 Hz, build 71cdd837537, light | made ahead | 0.18 ms p50, 0.35 max | 284 ms p50, 355 p95 | 312 ms p50, 401 max |
| same | new `NSOpenPanel()` per click | 298 to 376 ms | 317 to 325 ms | 650 to 738 ms |
| cmux17/cmux21 macOS 27.0, cmux-app-review-mac 26.5.1, a fresh process (JXA) | first panel | 316 to 386 ms | | |
| mac26 (loaded), a fresh process | first panel | 1 510 ms | | |
| aws-m4pro-3, macOS 27.0.1, no console session | any | about 40 s (10 + 10 + 20 s of `HostCallsAuxiliary` waits), then prompt nil | | |

What blocks: `NSOpenPanel()` itself. Its init waits synchronously on the panel's view service (about 300 ms for a
process's first panel, 40 s and a dead panel when the service never answers). `beginSheetModal` returns after the sheet's
open animation, but the display link kept ticking through it (longest frame 24 to 26 ms at 60 Hz in the run above): it
runs a nested run loop, not a frozen main thread. No caller uses `runModal`; every one uses `beginSheetModal` or
`begin(completionHandler:)` already.

The options:

- `begin` / `beginSheetModal` instead of `runModal`: already so.
- A panel kept warm once the service answered: already so. `MadeAheadPanelStore` keeps one panel and resets its choices and
  texts after each use, off the click; the click then pays 0.2 ms to get it. The warm-up runs only while this account is
  the console user and the person is idle, and stops after a dead panel. A newly made panel that reads no prompt is
  dropped, never shown. A kept panel whose view service ended later is not detected (every caller sets its prompt,
  so it always reads one; open, perf-lead.md row 25). The warm-up is not bounded: it is the same
  `NSOpenPanel()` on the main thread, so for a console user whose panel service hangs or respawns slowly it freezes
  the main thread once, up to about 40 s, before the dead panel stops it. No deadline is possible around it (below).
- A light in-app placeholder while the panel comes up: it cannot help the one case left, a click with no panel made ahead
  (before the first warm-up, in a session that never warms, after a dead panel). That wait is the `NSOpenPanel()` init on the main thread, and a placeholder
  needs the same main thread to draw. AppKit has no public way to make an `NSOpenPanel` off the main thread or to ask its
  view service ahead without making one.

So AppKit leaves no non-blocking path for a click or a warm-up that has to make its panel: about 300 ms on a working
host, 40 s with no view service or a hung one. The made-ahead panel removes it for every click after the warm-up. The way to remove it for every click is
the decision at the top of this file: cmux's own picker (`CmuxPicker`, no XPC service) for these entry points too.
The dead-panel guard does not shorten that block: a click whose new panel comes back dead still waits it out, then ends
the input as a cancel instead of a sheet that never ends.

Open: the STRESS rows and a rerun with the display link running into the click (frames from 120 ms before it) are fleet
steps 783852f9bdbf32290748032c (open-panel) and f26d6dae44358f76a3454389 (bench-smoke) at 3577c3e9407.
