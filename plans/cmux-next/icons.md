# Icons (R94)

Status: in progress, 2026-10-04. Owner: the emoji and icon lead. Request (Lawrence): "set workspace
icon should let user search through emojis, virtualized so performance is insanely good. think
about all other places where we should support emojis + images/svgs".

## 1. One icon value

Every object's icon is one value: `{emoji}` | `{symbol}` | `{image: asset}` | `{svg: asset}`.
Assets are content addressed (`sha256-<64 hex>`) and stored once by the object's owner (the
daemon's blob store for daemon-owned objects, so iOS and the CLI see them).

Wire form: the existing `icon` string fields, so stored rows and old readers stay valid.

| Wire string | Value |
| --- | --- |
| one RGI emoji, at most 32 bytes | emoji |
| `[a-z0-9]+(.[a-z0-9]+)*`, at most 128 bytes | SF Symbol |
| `image:sha256-<hex>` | raster asset (png, jpeg, webp; at most 256 KiB; the picker scales to 256 px PNG) |
| `svg:sha256-<hex>` | sanitized SVG asset (at most 64 KiB) |

Decoders: `IconValue` (Swift, CmuxNextDesign; the only rule in the app), `iconValue.ts` (page),
`validate_presentation_icon` (daemon, the authority). SVG: an allowlist sanitizer with a real XML
parser that re-serializes; the page copy is only for preview, the owner sanitizes again.

## 2. One picker

A React page (`webviews/src/pages/icon-picker`, `cmux-page://cmux.icon-picker/`), shown in a native
popover; it moves onto the one shared prewarmed page host (the shell) when that lands. Tabs Emoji,
Symbols, Image, SVG. Data: Unicode emoji-test 17.0, CLDR 48.2.0 annotations (en, ja), emojibase
17.0.0 GitHub shortcodes (MIT), pinned by SHA-256 (`webviews/scripts/icon-picker`). Search by
names, keywords, shortcodes, kana-folded Japanese, flag ISO codes. Recents by frecency in the
personal projection `icon-picker.prefs`, remembered skin tone, docked section headers, a detail bar
(glyph, name, `:shortcode:`), keyboard first (arrows, Ctrl-N/J/P/K, Return, Escape, Ctrl-Tab, Cmd-C
copies through the copy command).

Measured (real WKWebView, cmux-lawrence-2, `webviews/bench/icon-picker`): keystroke p95 2-3 ms,
scroll step p95 1 ms, session open 4-6 ms, cold web view to first frame 94-100 ms, blank host
navigated to the page 52-57 ms, loaded page shown again 27-38 ms.

Entry points share one action per object: `workspace.setIcon`, `screen.setIcon`, `space.setIcon`,
`browserProfile.setIcon`. An `icon` argument (CLI, MCP, scripts) sets it; no argument (palette,
context menu) opens the picker, and its pick, Remove Icon or cancel takes the same path.

## 3. Inventory

D = daemon-owned, A = app-owned.

| Object | Owner | Icon today | Plan |
| --- | --- | --- | --- |
| Workspace (and Home) | D | yes | picker done; icon and color show together |
| Screen | D | yes | picker done |
| Space | D | yes | picker done; Settings draws emoji |
| Browser profile | D | yes | picker done; Settings draws symbols |
| Workspace status entry | D | yes (CLI) | renderer missing |
| Screen, workspace and tab groups | D | no | candidate |
| Sidebar sections and items | A (layout doc) | no | per sidebar-sections.md 10 |
| Tabs | derived | no | candidate (per-tab override) |
| Bookmark folders | D | no | candidate |
| cmux.json actions and buttons | A (config) | symbol or image path | accept the wire string |
| Home conversation reactions | D | emoji | same picker |
| Cloud machines, servers | per record | no | candidate |
| App manifests | package author | own field | out of scope |
| Agent personas, layouts, snippets | none yet | no record | blocked on an owner |

## 4. Decisions (coordinator, 2026-10-04)

D1 SVG icons yes, with the sanitizer conditions above and a security review. D2 images scaled to
256 px PNG in the page. D3 recents and skin tone in the daemon personal projection. D4 Left/Right
move in the grid while typing. D5 shortcodes added now. The shared page host uses one-shot hosts.
