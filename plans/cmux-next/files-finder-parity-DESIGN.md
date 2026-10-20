# Files open in cmux, Open With everywhere, Finder parity at 100x speed

Status: design, 2026-10-20. Owner: "Chief attachments open right" agent.
Builds on: plans/finder-parity/PARITY.md (a123's CmuxNextFiles, ~45% parity),
plans/cmux-next/search-everything-DESIGN.md (a269's daemon index).

User ask (Lawrence, 2026-10-20): "for chief if i click on an image of html etc it should open to
the right instead of finder, but i should be able to right click, open with other app (finder,
vscode etc support all) make sure we have finder implementation that visually matches finder and
performance (including search) is 100 times better than finder".

## 1. Decisions (defaults picked, the user can override)

- A click on a file in a chat (a Home attachment, a `file://` link chip, an agent chat path)
  opens it in cmux on the right of the chat (`LinkOpener`, `layout.linkPlacement`), never in
  Finder or another app. Another app is one right-click away (Open With).
- One classifier decides how cmux shows a file: `FileOpenKind` in `CmuxNextFiles` (pure, tested):

  | kind | files | shown in |
  |---|---|---|
  | `.markdown` | `.md`, `.markdown`, `.mdx` … (`FilePageKind.isMarkdown`) | Markdown page |
  | `.web` | `.html`, `.htm`, `.xhtml`, `.svg` | cmux browser tab (`file://`, renders the page) |
  | `.preview` | images, PDF, audio, video | cmux browser tab preview (runs nothing) |
  | `.editor` | text, code, unknown small files | code editor page (read only when binary) |
  | `.folder` | a directory (not a package) | cmux Files pane tab |
  | `.app` | `.app` bundles and other packages | the system (launching an app is the only sensible open) |

  HTML used to open as source in the editor; the user asked for the page. "View Source" stays
  available as Open With > cmux Editor.
- Folders from a chat open in the Files pane. Folders from a terminal keep opening a terminal
  there (the terminal user's habit; unchanged).
- One right-click menu for a file, built by one type (`FileActionsMenu`, `CmuxNextFilesUI`) and
  used by Home attachments, Home file link chips and the Files pane:
  Open in Right Pane · Open With ▸ (default app first, marked "(default)", then every app
  `NSWorkspace.urlsForApplications(toOpen:)` reports, sorted by name, then Other…) · Quick Look ·
  Reveal in Finder · Reveal in cmux Files · Copy Path · Share…
  "Open With" lists come from the file's type (extension), so a Home attachment's menu shows at
  once without downloading the bytes; the bytes are fetched when an item runs.
- Agent chat (acpmux webview) file chips already route to `onOpenFile` (in cmux). The webview's
  own right-click menu is a later slice (section 6); its clicks follow the same classifier.

## 2. Shared paths (one mutation path per behavior)

```
Home attachment click ─┐                         ┌─ FilePageOpener (markdown/editor/web/preview)
Home file:// chip ─────┼─ LinkOpener.openFile ───┤
agent chat path ───────┘   (right of the chat)   └─ FilesPaneService.open(folder:) for .folder
Files pane double-click ── FilesPaneService.openFile ── same FileOpenKind
right-click anywhere ───── FileActionsMenu ── FileApps (NSWorkspace) / handlers from the host
```

- MessagesLab (vendored iMessage transcript) gets one seam, `HomeFileHost` (`open(url)`,
  `menuItems(name:resolve:)`), set by the cmux host. With no host it keeps the old system open,
  so the vendored package stays usable alone.
- `Copy Path`, `Reveal in Finder` and `Open With` never block the main thread on LaunchServices:
  `NSWorkspace` calls go through `CmuxNextCompat`'s background helpers.

## 3. Files pane: Finder parity plan

PARITY.md is the checklist (90 rows). This work moves these rows, in order:

| slice | rows | what |
|---|---|---|
| S1 (this change) | 9.1, 9.2, 9.3, 2.14 | Open With submenu (all apps, Other…), cmux-native open by kind, Share…, Reveal |
| S1 | 8.2 (name) | recursive "search this folder" by name on the fast index (section 4) |
| S2 | 1.4, 4.3 | gallery view; Finder toolbar (back/forward, view switcher, group, share, tags, action, search) |
| S2 | 8.5, 3.3 | tags: colored dots, Ctrl+Cmd+1..7, sidebar Tags section |
| S3 | 1.5, 1.7, 1.10 | list disclosure triangles, View Options (Cmd+J), Group By |
| S3 | 8.2 (content), 8.3 | content search through a269's daemon index; search tokens |
| S4 | 4.4, 5.3, 7.5, 7.6 | preview pane, inspector, file promises, marquee selection |

Visual parity is checked against Finder screenshots at the same window size in a gallery (Home
right pane, `design/files-finder-parity/`), one row per view, before/after.

## 4. Speed: 100x Finder, search included

### 4.1 What Finder does

- Folder open: Finder enumerates through its own file system layer; timed via Apple Events
  (PARITY.md baseline: `count items` 353-865 ms at 10k, 816-8 019 ms at 100k).
- Search: Finder's search field is a Spotlight query (`MDQuery`), the same engine as `mdfind`.
  `mdfind -onlyin DIR -name Q` is the engine-level timing of a Finder name search without its
  UI; content search is `mdfind -onlyin DIR Q`. Finder's UI adds its own result batching on top
  (hundreds of ms before first results), so the `mdfind` number is a lower bound for Finder.
  Folders Spotlight does not index (`/tmp`, excluded paths, external disks without an index)
  give Finder no results at all; ours works everywhere.

### 4.2 What we build

- `FolderNameIndex` (`CmuxNextFiles`, an `actor`): one walk of a folder tree with `fts(3)`
  (`FTS_PHYSICAL | FTS_NOSTAT` where possible), storing every relative path once in one
  contiguous byte buffer of folded names (ASCII lowercase; non-ASCII names folded with
  Foundation once, at index time) plus a `[UInt32]` offset table. No per-file objects.
- Query: a `memmem`-style scan over the folded name buffer for the folded query bytes (names
  only, so ~20 bytes per file: 100k files is ~2 MB, a scan is well under 1 ms warm), capped at
  N results, ranked: exact name, prefix, word-start, substring; shorter paths first.
- Live: the pane's `FolderWatchStream` (FSEvents) marks the index stale per subtree; a stale
  subtree is re-walked off-main. Memory bound: one index per open Files tab root, dropped with
  the tab; a tree over 2 M entries stops indexing and says so (falls back to Spotlight).
- Content search: a269 owns the global index (daemon, trigram blocks; `file` source = files in
  open workspaces' folders). The Files pane does not build a second content index: it asks the
  daemon's `search` op with scope `path:<folder>` once that op exists; until then content
  search falls back to `mdfind` (the same engine Finder uses, so never slower than Finder).

### 4.3 Bench (`scripts/measure/files-finder-bench.sh`, numbers in BENCH section of PARITY.md)

- Corpus: generated trees of 10k and 100k files (nested 3 deep, realistic names) in a folder
  Spotlight indexes (under `$HOME`), waited until `mdfind` returns the full count.
- Measured per corpus, 7 runs, median and p90:
  folder open (Finder Apple Events `count items` vs `DirectoryLister`),
  name search for 3 queries (rare, common, prefix) (`mdfind -onlyin -name` vs
  `FolderNameIndex.search`), index build time (ours; Spotlight's is hidden from the user but
  real).
- Target: 100x on folder open and name search. Runs on a fleet Mac mini (`--class exclusive`),
  never on this Mac.

## 5. Tests (failing first)

- `FileOpenKindTests`: HTML opens `.web`, images/PDF `.preview`, Markdown `.markdown`, code
  `.editor`, a folder `.folder`, `.app` `.app`.
- `OpenWithListTests`: default app first, de-duplicated by bundle id, sorted by name, cmux itself
  kept, empty list still gives Other….
- `FolderNameIndexTests`: finds nested files by substring, ranks exact > prefix > substring,
  caps results, folds case and diacritics, re-walk after a change.
- MessagesLab `HomeFileHostTests`: an attachment click goes to the host's `open`, not the system.

## 6. Gaps after S1 (named so nobody assumes them done)

- acpmux webview's own right-click menu on file chips (needs a native-menu bridge message).
- Gallery view, toolbar, tags, preview pane (S2-S4).
- Content search on a269's index (waits for its daemon `search` op).
- Visual parity is a gallery comparison, not a pixel diff.

## 7. Bench results (fleet, 2026-10-20)

`FolderNameIndexSpeedTests` on aws-m4pro (shard s3/6 of run ffp6-green-4a939a7143), 100 100
items (100 folders x 1 000 files plus folders), median of 25 searches:

| operation | cmux | Finder / Spotlight |
|---|---|---|
| index build (one walk, 100k) | 457 ms | Spotlight: background, minutes; none outside indexed volumes |
| name search, rare (`quasar`, 11 hits) | 0.96 ms | not measured yet (see below) |
| name search, common (`screenshot`, 200 shown) | 4.3 ms | not measured yet |
| name search, common (`report`, 200 shown) | 4.0 ms | not measured yet |
| folder open 10k / 100k (`DirectoryLister`, PARITY.md) | 25-44 / 324-461 ms | Finder `count items` 353-865 / 816-8 019 ms |

Not measured yet: the Finder/Spotlight side of search. `scripts/measure/files-finder-bench.sh`
(Finder Apple Events and `mdfind -onlyin -name` on the same corpus) is written, but the fleet
controller runs only reviewed `scripts/measure` scripts (cmuxterm-hq
build-fleet/cmd/controller/ci_step.go `measureScripts`); it must be added there after this lands.
Folder open is ~2-18x Finder today, not 100x: the listing is already one `getattrlistbulk` pass,
so 100x on open needs first rows painted before the full listing (streamed listing), the next slice.
