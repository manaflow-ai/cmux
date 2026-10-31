# cmux-next vs Chrome: extensions, audio, media, app menu

Source: Chromium `main` 2dca33025a6 (2026-10-19), desktop macOS, shipped flag defaults.
Every Chrome value below is cited in [CHROME-SPEC.md](CHROME-SPEC.md) by section number.
Status: **match** (same function and look), **close** (same function, small visual or text
difference, named), **gap** (missing; the plan says why and what it needs).

Chrome's desktop default is the **legacy** Extensions menu: `kExtensionsMenuAccessControl` is off
(§0). cmux started from the legacy menu and, since #22992 (Leo, 2026-10-20: "style the extensions
situation a bit better"), takes cmux's popover look and the best of Chrome's new menu and Edge's:
site-access sections, a second line with each extension's access, a side panel button, an accent
pin toggle, Get Extensions and an empty state. The rows below say where it now differs on purpose.

## A. Extensions bubble (§3.1, §3.2)

| Chrome | cmux status | Plan / reason |
|---|---|---|
| Bubble, not a menu: `BubbleDialogDelegateView`, arrow TOP_RIGHT under the puzzle | match: native popup panel, right-aligned below the puzzle (or below More when the puzzle is hidden) | |
| Width 320, corner radius 12, margins 0 | **different on purpose**: 340 wide, cmux popover radius and row insets (`PopupStyle`) | Matches cmux's other popovers. |
| Title "Extensions" 16 pt medium, close button 24×24 with a 16 glyph, tooltip "Close" | close: `Typography.bodyEmphasized`, the current site under it (Edge), close 24×24 with a 14 glyph | |
| Window accessibility title empty (no "Alert Extensions") | match: the panel's title is empty, the title row speaks | |
| List scrolls above 448, no horizontal scroll, content inset 20 | close: scrolls above 400 with edge fades (`ScrollEdgeFadeView`), content inset 12 | |
| Three sections "Full access", "Access requested", "No access needed", each with a header and a description, hidden when empty | close: "Can see and change this site", "Allowed only when clicked", "No access needed", hidden when empty, from each extension's manifest (`ExtensionSiteAccess`) | The fork reports no runtime `SiteInteraction`; a fork API `cmux_ext_site_interaction(browser, tab)` would replace the manifest reading and show withheld access. |
| Edge: "Allow extensions on {site}" toggle | **gap** | Chromium's user-restricted sites (`PermissionsManager`) have no fork API. |
| Rows sorted case-insensitive by name | match (the store's order is by name) | |
| Separator, then "Manage Extensions" with the 20 gear (`settings_chrome_refresh_old`), inset 24, image-label spacing 16 | close: 16 gear, then "Get Extensions" (Chrome Web Store, `storefront_old`) as Edge does | |
| Opens on mouse **press**; a press on the open puzzle closes it | match | |
| Puzzle held "pressed" while the bubble is open | match: pressed fill while open, normal again on every close path (u2426) | |
| Esc closes; arrow keys walk all buttons | match (Tab and Shift-Tab too; wrap at both ends) | |
| Hover on a row button takes focus, leaving clears it | match | |
| No empty state: puzzle hidden with 0 extensions | **different on purpose**: cmux always shows the puzzle and an empty state that points to the Web Store | cmux uses the bubble to reach Manage Extensions and Get Extensions with 0 extensions. |
| Colors: opaque `kColorBubbleBackground`, `kColorHoverButtonBackgroundHovered` | close: cmux theme overlay surface (glass, opaque under Reduce Transparency) and theme hover fill | Decision for the user (cmux glass or Chrome opaque). |

### Row (§3.2 `ExtensionMenuItemView`)

| Chrome | cmux status | Plan / reason |
|---|---|---|
| Primary button: icon 28 box (16 icon), name 12 pt, border V8, tooltip = action tooltip, disabled if the action is disabled | close: 20 icon in a 24 box, the name and (Edge) its access on a second line, the whole row highlights; the tooltip is the extension name, not the per-tab action title | Per-tab action title is in `CEFExtensionAction`; follow-up. |
| Pin button 44×44, 20 glyph `keep_old` (unpinned) / `keep_off_old` (pinned) | **different on purpose**: a 28×28 toggle, `keep_old` in both states | The state reads at a glance (below). |
| Pinned glyph in accent blue (`kColorExtensionMenuPinButtonIcon`) | match in spirit: the theme accent (`Palette.accentFill`) on an accent wash | Never Chrome's blue: the theme decides. |
| Edge: side panel button for a side panel extension | close: shown when the manifest has `side_panel` and the action opens no popup; it runs the action (which opens the panel) | The fork has no call that opens an extension's side panel directly. |
| Pin tooltips "Pin" / "Unpin"; a11y "Pin {name}" / "Unpin {name}"; announcement "Extension pinned" / "Extension unpinned" | match | |
| "Pinned by your Administrator" (force-pinned, disabled) | **gap** | Needs a force-pinned flag in `cmux_ext_list`. String is translated and ready. |
| "⋮" button 44×44, `browser_tools_chrome_refresh_old` 20, tooltip "More options", a11y name = extension name | close: 28×28 with a 16 glyph | |
| Row click on an extension whose action is disabled opens its context menu | match | |
| Built-in uBlock row | cmux only: the row's tooltip says the full uBlock Origin ships inside cmux | |

### What the old cmux menu had that Chrome's bubble does not

Removed from the bubble to match Chrome; still in the command palette and the CLI:
"Chrome Web Store", "Load Unpacked", the "Disabled" list, and Enable / Disable / Reload / Run in the
per-extension menu. Decision for the user (keep them in the bubble or drop them like Chrome).

## B. Per-extension context menu (§4.1, legacy order)

| # | Chrome (Mac text) | cmux status | Plan / reason |
|---|---|---|---|
| 1 | {Extension name}, enabled iff a home page URL; opens it in a new foreground tab | close: enabled for Web Store extensions, opens the Web Store item page | `homepage_url` is not in `cmux_ext_list`. Needs the fork to add it. |
| – | extension `chrome.contextMenus` items for the action context | **gap** | Needs a fork API to list and run them. |
| 2 | "This Can Read and Change Site Data" ▸ radio "When You Click the Extension" / "On {host}" / "On All Sites" + "Learn More About Site Access" | close: the item opens Chromium's own action menu, which has the radio items | A native submenu needs `cmux_ext_site_access(get/set)` in the fork. |
| 2' | "Can't Read or Change Site's Data" (disabled) | **gap** | Same fork API. |
| 3 | "Rate It..." | **gap** | Needs the review-prompt state. Low value. |
| 4 | "Options" | match | |
| 5 | "Remove from Chrome" | match as "Remove from cmux" | Decision for the user (brand name). |
| 5' | "Installed by Your Administrator" (disabled) | match | |
| 6 | "Pin" / "Unpin", only from the toolbar icon | **different on purpose**: also in the bubble's more menu, beside the row's pin toggle | |
| – | "Open Side Panel" / "Close Side Panel" | **gap** | cmux has no extension side panel host. |
| 7 | "Manage Extension" → chrome://extensions/?id= | match (new Chromium tab) | |
| 8 | "View Web Permissions" → site settings of the extension origin | match (new Chromium tab) | |
| – | "Inspect Popup" (developer mode) | **gap** | Needs the developer-mode pref from the fork. |
| look | Views menu: radius 12, items about 32 tall, 13 pt, separator 17 | close: AppKit `NSMenu` (radius about 6, items 22 tall, 13 pt) | Decision for the user (custom-drawn menu like Chrome, or keep NSMenu). |
| behavior | Pin from the menu keeps the bubble open; other items close it | match | |

## C. Toolbar (§2)

| Chrome | cmux status | Plan / reason |
|---|---|---|
| Puzzle 34×34, icon 20 `extension_chrome_refresh_old`, tooltip "Extensions", a11y "Extensions menu" | close: tooltip matches; a11y name is "Extensions" | Icon and size belong to the toolbar icon lane (a50). |
| Action button 34×34, icon 16, right click and Down arrow show the context menu `kTopLeft` | match (menu now from the shared model, Pin item included) | |
| Badge 14 tall, 9 pt bold, radius 4 with a 1 DIP cutout | match: Chromium draws the badge into the icon; VoiceOver reads it as the value | |
| Cmd+Shift+Left/Right reorders a pinned action | **gap** | Small follow-up: key handling on `ExtensionActionButton`, through `browser.extension.move`. |
| Drag reorder of pinned actions | match | |
| Pin / unpin animates (icon fades, neighbours slide) | match: 0.2 s ease-in-out; instant under Reduce Motion (u2426) | |
| Toolbar buttons with a menu (More, media, an action's context menu) pressed while the menu is open, normal after | match (u2426) | |
| Popped-out unpinned action while its popup is open | **gap**: the popup hangs off the puzzle (or More) | Needs a temporary button in `ExtensionActionToolbar`; follow-up. |

## D. Lag (u2229)

| Measure (40 extensions, debug build, aws-m4pro-7) | Before | After | Budget |
|---|---|---|---|
| First open | 54.7 ms | see the fleet run in the report | < 50 ms |
| Second open | 45.3 ms | see the fleet run | < 10 ms |
| Hover (slowest row) | 1.4 ms | see the fleet run | < 16 ms |
| Icons decoded on reopen | 40 (4.8 ms) | 0 | 0 |
| Chromium refresh on open | synchronous, before the menu shows | on the next main-actor turn | async |

Causes: every open rebuilt every row with Auto Layout (about 1.1 ms each) plus the `NSMenu` layout
pass; every open decoded every 128-pixel icon from disk; every open asked Chromium for the list
and commands (two JSON round trips) before it showed; "⋮" closed one `NSMenu` with its fade and
opened a second one.

## E. Audio, media controls, app menu (§D1–D3, §E)

Owners: tab audio is the tab-audio-toggles lane (a85); web views are a89. This lane did not change
them. Status from the code on origin/feat-cmux-next at the time of writing.

### Tab alert indicator (§D1)

| Chrome | cmux status | Plan / reason |
|---|---|---|
| Speaker `volume_up_chrome_refresh_old` / `volume_off_chrome_refresh_old`, 16, `kColorSysOnSurfaceSubtle` | close: own glyphs `.mediaAudio` / `.mediaMuted`, 12 pt, `Palette.textSecondary` | a85: Chrome glyphs at 16. |
| 8 DIP gap to the close button; title ends 4 DIP before it | close: title area end, left of the close button | a85. |
| Stays 2 s after audio stops (`kRecentlyAudibleTimeout`) | **gap** | a85. |
| Fade in 200 ms, fade out 1000 ms, playing↔muted instant | **gap**: no fade | a85. |
| Muted icon only if recently audible | **gap**: cmux shows muted whenever the tab is muted | a85. |
| Click on the icon does not mute (`kEnableTabMuting` off) | match | |
| Tab a11y "{TITLE} - Audio playing" / "- Audio muted" | close: "Playing audio" / "Muted" | a85. |
| Hover card / tooltip "{title}\n This tab is playing audio" | **gap** | a85. |
| Other alerts: camera, mic, screen share, tab capture, PiP, Bluetooth, USB, HID, serial, VR | **gap** | Needs capture and device state from Chromium; a85 or a new lane. |

### Tab context menu (§D2)

| Chrome | cmux status | Plan / reason |
|---|---|---|
| "Mute Site" / "Unmute Site" (plural "Mute Sites"), per-origin SOUND content setting | **different**: "Mute/Unmute Tab", per tab, in the Options folder | a85: title should switch Mute/Unmute; per-site mute needs the content setting through the fork. |
| Order: New Tab to the Right, split, group, move; Reload, Duplicate, Pin, Mute Site; reading list; Close, Close Other Tabs, Close Tabs to the Right | not audited here | Tab strip lane. |

### Global Media Controls (§D3)

| Chrome | cmux status | Plan / reason |
|---|---|---|
| Toolbar button `media_toolbar_button_chrome_refresh_old` 20, opens on press, tooltip "Control your music, videos, and more" | close: `BrowserToolbarButton.media` with Chrome's glyph (a128), shown while a tab has media; opens on release | |
| Button has no "on" look while media plays; pressed only while the dialog is open | match (u2426; it was drawn on while any tab played) | |
| Dialog: bubble, radius 8, items 400 wide, scroll above 488 | **different**: a menu (`BrowserMediaMenu`) with rows | Same bubble host as the Extensions bubble can carry it; follow-up. |
| Card: artwork 80 radius 8, title 14 bold, artist 14, source 11 with favicon 14 | close: artwork, title, artist, site | |
| Play/Pause 48 pill; Previous, Replay 10, Forward 10, Next 28 | close: Previous, Play/Pause, Next, Mute; **gap**: Replay 10 / Forward 10 | `BrowserMediaCommand.seek` exists; buttons are a small follow-up. |
| Scrubber (28 tall, 2→4 line, thumb 4×16, ±5 s keys) and LIVE pill | **gap** | Follow-up. |
| Picture-in-picture, Save video frame, Cast device picker | **gap** | PiP needs the fork; Cast is out of scope. |
| Live Caption / Live Translate rows, Caption settings | **gap** | Needs Chromium's on-device speech; out of scope. |
| cmux only | macOS Now Playing, sidebar card (off by default), New Tab player | |

### App menu "⋮" (§E)

| Chrome | cmux status | Plan / reason |
|---|---|---|
| New tab, New window, New Incognito window | match | |
| Profile, Passwords and autofill, History, Downloads, Bookmarks and lists, Tab groups | close: History, Downloads, Bookmark Manager, Passwords, Tab Groups | |
| Extensions ▸ "Manage extensions", "Visit Chrome Web Store" | **different**: flat "Manage Extensions" (and "Extensions…" while nothing is pinned) | Follow-up: an Extensions submenu with both items. |
| Delete browsing data... | close: "Clear History" | |
| Zoom row (−, %, +, full screen) | close: four separate rows | |
| Print... | **gap** | No engine prints yet. |
| Translate..., Find and edit, Cast/save/share, More tools | close: Find, Screenshot, Tools folder | |
| Help, Settings | match | |
| cmux only | Split Right, Focus Mode, Open in Default Browser, engine switch, Show in Toolbar | |

## Reference: Chrome's new menu (flag on, not the default)

Width 448, a site-settings toggle row, a reload section, a requests section with Allow / Dismiss,
per-extension site-access toggles, a site-permissions page with radio rows, no pin button (pin is
in the context menu), and the new context-menu order (§4.2). Not built: it is not what desktop
Chrome ships today, and it needs the same site-access fork API as the sections above.
