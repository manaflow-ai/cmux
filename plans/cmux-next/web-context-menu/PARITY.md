# Web page context menu: Chrome parity

Written 2026-10-19 for the request "On web pages I right-click and I see options for 1Password but I want to see the icon as well. Think about how Chrome does it and what other stuff from Chrome we're missing."

Sources read (Chromium `main`, 2026-10-19): `chrome/browser/renderer_context_menu/render_view_context_menu.cc`, `chrome/browser/extensions/context_menu_matcher.cc`, `chrome/browser/extensions/context_menu_helpers.cc`, `chrome/browser/extensions/menu_manager.cc`, `chrome/app/chrome_command_ids.h`.

## How cmux builds the menu

- **Chromium tabs (CEF).** CEF hands the shim Chromium's own `RenderViewContextMenu` model (`shim_client.mm` `RunContextMenu`). The host shows it as an `NSMenu` (`BrowserContextMenuBuilder`). Choosing a Chromium row sends its command id back, and Chromium runs it. So Chromium's own rows (spelling, Emoji, Speech, Writing Direction, Translate, Cast, QR code, Save as, Print, Inspect, media controls, extension items) keep Chrome's behavior with no cmux code.
- cmux replaces Chromium's link, image and selection rows with its own rows (`BrowserHitMenu`, `BrowserHitActionCatalog`). Each cmux row is one registered action, so the palette, the CLI and MCP run the same code. cmux page actions (Tools, Page Info, Options) follow Chromium's rows.
- **WebKit tabs.** WebKit shows its own menu, and cmux inserts the same link, image and selection rows at the top. WebKit has no extensions.

## What was missing and what this change does

| Chrome behavior | Before | Now |
| --- | --- | --- |
| Extension rows show the extension's 16 px icon (`ContextMenuMatcher::SetExtensionIcon`) | No icon: CEF's `CefMenuModel` has no images | The icon is from the extension's manifest (smallest ≥16 px for 1x, ≥32 px for 2x, as `ExtensionIconManager` does). If no extension can be matched, Chrome's default puzzle-piece icon shows. `BrowserExtensionMenuIcons`, `BrowserContextMenuImages` |
| One top-level row per extension. An extension with more than one item (or one checkbox or radio item) gets a submenu titled with its name | Already Chromium's model: kept | Kept. A test checks that the icon is only on the top-level row |
| `visible: false` extension items and submenus with no visible child are not shown | Shown: the shim did not report visibility | The shim sends `visible`. `decodeList` removes hidden rows, empty submenus and doubled separators |
| Checkbox, radio and separator extension items, radio groups | Shown (checked state from the model) | Unchanged. Covered by a test |
| `contexts`, `documentUrlPatterns`, `targetUrlPatterns`, `enabled`, `onClicked` | Chromium's matcher: works | Unchanged |
| Translate and Cast… rows have icons on macOS (`AddItemWithIcon`, not behind `kMenuSimplification`) | No icon | SF Symbol stand-ins (`translate`, `airplayvideo`). `withChromeIcons` |
| Canvas: Save Image As…, Copy Image | **Lost**: cmux dropped the image command ids even with no image address, and no cmux row replaced them | Chromium's rows stay when there is no image address |
| Copy Link Text when cmux cannot read the link's text | **Lost**: Chromium's row was dropped and the cmux row was hidden | Chromium's row stays |
| Copy on a selection that is only white space | **Lost** | Chromium's Copy stays |
| A `mailto:` link: "Copy Email Address" | "Copy Link" | "Copy Email Address" (21 languages) |

## Chrome rows by context, with their owner in cmux

`C` = Chromium's own row (runs in Chromium). `cmux` = cmux row (registered action).

- **Page:** Back, Forward, Reload (C). Save As… (C). Print… (C, and cmux Print). Cast… (C, icon). Create QR Code for this page (C). Translate to … (C, icon). View Page Source (C). Inspect (C). Send to your devices and Reading mode: C, when Chromium enables them.
- **Frame:** Reload Frame, View Frame Source (C).
- **Link:** Open Link in New Tab, Open Link in New Window, Open Link in Incognito Window, Save Link As…, Copy Link Address / Copy Email Address, Copy Link Text (cmux). cmux also adds New Space, New Workspace, Split Right, and Open Link in Browser Profile ▸ (the counterpart of Chrome's "Open Link as" avatars, with the profile icons). Open Link in New Tab runs `browser.link.openInNewTab`, so where the tab opens follows the pane routing that a101 is changing.
- **Image:** Open Image in New Tab, Save Image As…, Copy Image, Copy Image Address (cmux). Search Image with Google, Create QR Code for this Image (C).
- **Video and audio:** Loop, Show Controls, Picture in Picture, Save Video/Audio As…, Copy Video/Audio Address, Open Video/Audio in New Tab, Cast… (C).
- **Selection:** Copy, Search Google for "…", Look Up "…" (cmux). Copy Link to Highlight, Translate selection, Print…, Speech ▸ (C).
- **Editable:** Spelling suggestions, Add to Dictionary, Spelling and Grammar ▸, Emoji & Symbols, Undo, Redo, Cut, Copy, Paste, Paste and Match Style, Delete, Select All, Look Up, Writing Direction ▸, Substitutions ▸, Transformations ▸, Speech ▸ (all C, so Chromium keeps them together).
- **Extensions:** all extension items (C), now with icons.

## Still different from Chrome (not fixable in the host)

- **Matching an icon to its row is inferred.** CEF does not say which extension added a row. cmux matches by the submenu title (Chromium's grouping title is the extension's name), the manifest's `short_name`, a name prefix or first word, and "the one left over". Only extensions with the `contextMenus` or `menus` permission are counted. Two extensions that each add one plain item with an unrelated title can get swapped icons. Exact fix: a fork API that returns the extension id for a context menu command id. That needs a Chromium build, so it is listed for the next fork bump (`plans/cmux-next/cef-cmux18-candidates.md`).
- **Icons set by the extension at run time** (`chrome.contextMenus` has no icon API, so none). Chrome also uses only the manifest icon.
- **Live updates while the menu is open.** Chrome builds the model once when the menu opens, and cmux shows that same model. Equal.
- **Chrome's own vector icons.** The Translate and Cast stand-ins are SF Symbols. a128 (Chromium BSD-3 icons) can change `BrowserContextMenuItem.chromeIcons` to its shared icon source.
- **Icons behind `kMenuSimplification`** (Search, Reading list, QR, Reading mode, PiP) are off by default on macOS Chrome, so cmux does not draw them.
