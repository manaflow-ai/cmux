# Browser chrome: toolbar, omnibar, suggestions and Page Info

The browser pane's chrome in React, over the native page engine: the toolbar strip, the omnibar
with its page-info chip and bookmark star, the suggestion card under the bar, and the Page Info
bubble the chip opens. The components draw props and report commands; the host (the native
BrowserChromeView today) owns the tab state, the omnibox state machine, focus and the popups'
windows.

- `webviews/src/browser-chrome/ui/BrowserToolbar.tsx` (toolbar strip, omnibar, chip, star,
  extension and trailing buttons, progress line), `toolbarModel.ts` (metrics, commands, layout and
  chip rules), `SuggestionDropdown.tsx` (suggestion card), `browserChrome.css`.
- `webviews/src/browser-chrome/page-info/PageInfoBubble.tsx` (the bubble), `model.ts` (model,
  commands, permission rules), `pageInfo.css`; the windows the bubble opens:
  `SiteSettingsWindow.tsx`, `SiteDataWindow.tsx`, `CertificateViewer.tsx` (with `certificate.ts`,
  the viewer's words), `windows.ts` (their wire), `pageInfoWindows.css`.
- Strings: `Localizable.xcstrings` next to each, copied with every locale from the native
  `CmuxNextBrowser/Resources/Localizable.xcstrings` (toolbar) and `PageInfo.xcstrings` (Page Info,
  chip); `scripts/pages/gen-strings.mjs` writes `generated/strings.json`.
- Gallery: `browser-chrome.toolbar`, `browser-chrome.suggestions`, `browser-chrome.page-info`,
  `browser-chrome.page-info.site-settings`, `.site-data`, `.certificate` (area Browser chrome,
  Experimental until the React chrome ships). Each has a Look option.
- The Import Cookies card (its own section below): gallery `browser-chrome.cookie-import`, same area, with a Look option.

The native sources these match: `UI/OmnibarStyle.swift`, `OmnibarMetrics.swift`,
`BrowserToolbarLayout.swift`, `BrowserToolbarButton.swift`, `BrowserToolbarPolicy.swift`,
`ChromeButtons.swift`, `BookmarkStarButton.swift`, `ExtensionActionToolbar.swift`,
`ProgressLineView.swift`, `OmniboxSuggestionPanel.swift`, `SuggestionRowView.swift`, and
`PageInfo/UI/*`, `PageInfo/Model/*`, `PageInfoStrings*.swift`.

## Parts

Left to right in the toolbar row:

1. **Back, Forward, Reload.** Reload is Stop while the page loads. Right-click on Back or
   Forward asks for the history menu (`navigationMenu`). No tooltips: the icon says it.
2. **Omnibar.** The page-info chip, the address text, the bookmark star.
   - The chip: the page's security icon (secure pages show the tune icon, not a lock), plus a
     label for Not secure, Dangerous, File and cmux pages, or an extension or search engine
     keyword. Danger tone (certificate error, dangerous site) draws icon and label in the theme's
     red. It opens Page Info; it does nothing while the user types or the bar is empty.
   - The address: the compact URL with the host at full strength and the rest dimmed; while
     editing, the full address in one color.
   - The star: hollow (not bookmarked), filled (bookmarked), absent on pages that cannot be
     bookmarked.
3. **Pinned extension actions** (each the extension's icon and badge), then the Extensions
   button. Shown on Chromium tabs only.
4. **Trailing buttons**, only the pinned ones with something to show, in catalog order: Media,
   Zoom, Bookmarks, Downloads, Design Mode, Profile, Theme, DevTools, then More (always).
5. **Progress line**, 2 pt, at the row's bottom edge, the focus ring gray at 80%.

The suggestion card hangs from the bar. Page Info is a popup anchored at the chip.

## Metrics (Standard density, pt)

| part | value | native source |
| --- | --- | --- |
| bar height, suggestion row height | 28 | `OmnibarMetrics.barHeight` |
| toolbar button | 28 square, icon 20, hover radius 8 | `buttonSize`, `toolbarIconSize`, `buttonCornerRadius` |
| between buttons | 3 | `basePadding` |
| Reload to bar, bar to extensions | 6 | `barMargin` |
| toolbar side inset | 2 | `paneChromeInset` (pill top) |
| gap under the row | 2 | `chromeGap` |
| bar radius | 8 | `Metrics.cornerRadius` |
| chip | 24 square (bar less 2 each side), 2 from the bar's start, radius 6, glyph 16 | `chipSize`, `chipLeading`, `chipCornerRadius` |
| chip label | 2 after the glyph, 6 before the chip end, 14 text | `PageInfoChipButton.layout` |
| address text | 14, 5 after the chip, 8 before the end | `textLeading`, `trailingPadding` |
| star | 20 box, 18 glyph | `trailingIconSize` + 2 |
| suggestion card | the bar's width, rows inset 4, 2 above each row, 4 at the end, row radius 4 | `rowSideInset`, `rowGap`, `cardBottomPadding` |
| suggestion row | glyph 16 on the chip's center, text on the address text's column | `SuggestionRowView` |
| Page Info card | 320 wide, padding 6, radius 8 | `bubbleWidth`, `inset / 2` |
| Page Info row | 28 (42 with subtitle), inset 6, icon column 26, glyph 16, 2 between rows | `PageInfoStyle` (former) |
| Page Info text | title 12 emphasized, body 12, captions 10.5 (web: the 11 caption step) | `Typography` |
| Page Info switch | 28 x 16, the text color when on | `PageInfoToggle` (former) |
| header buttons | 24 square, glyph 14 | `PageInfoIconButton` (former) |
| Page Info windows | fixed width (site settings 460, site data 440, certificate 520), inset 18, height fits the page up to 640 | `PageInfoWebWindow` |

Comfortable density (34 pt bar and buttons, 15 pt text) is not drawn yet; the numbers live in
`TOOLBAR_METRICS` and the `--pi-*` block, so it is one change in each.

## States

- **Idle.** The bar is a tonal fill over the toolbar (fg at 7%), a lift on hover (10%).
- **Focused / editing.** No fill, a 2 pt neutral ring, the full URL, the chip's label hidden and
  its icon describing the input (search, or the highlighted suggestion's kind). Focus changes the
  look in the press's own frame; only hover eases.
- **Suggestions open.** The bar takes the card's opaque fill and squares its bottom corners; the
  card continues it with square top corners, so bar and rows are one shape. With the toolbar at
  the bottom of the pane the card opens upward and the corners swap.
- **Loading.** Stop replaces Reload in place (same box); the progress line glides with progress
  and fades out on finish. A line that just appeared starts in place.
- **Insecure.** Not secure chip label in the text color; certificate errors and dangerous sites in
  the danger red.
- **Popup open.** The chip keeps its pressed fill while Page Info is open (as a toolbar button
  does while its menu is open).
- **Narrow pane: collapse order** (`BrowserToolbarLayout`, `widthLeftByToolbarButtons`):
  1. trailing buttons hide into More while the omnibar would be under 100 pt with Forward shown:
     Design Mode and DevTools first (level 1), then the rest (level 2);
  2. pinned extensions move into the Extensions menu, last pinned first, while the omnibar would
     be under 200 pt;
  3. Forward hides; the omnibar takes what is left.
  Back, Reload, the omnibar, Extensions and More always stay. Only the buttons that fit are
  rendered, so the strip's cost does not grow with what is pinned.

Every change is one layout to the end state: a collapse step, Stop for Reload, the editing ring,
the card joining the bar. Nothing pops in after an animation; popups open in one frame and only
fade as they close.

## Page Info

Pages, each one card, swapped in place:

- **Main.** The site (host and port, or the file path), then the connection row (chevron), the
  permissions this site has (switch each, the row opens that permission's page), Reset
  permission(s), the reload notice, Cookies and site data (chevron), Site settings (external
  mark), About this page (public web pages). Non-web pages show a single identity line.
- **Security.** Back, title and site; the long summary; the details paragraph (plus the identity
  line and the engine's reason on a certificate error); Turn on warnings when the user proceeded
  past a warning ("For all sites in this profile" on Chromium); the certificate row.
- **Cookies.** The description, the third-party line when the engine blocks them, Manage
  on-device site data with "Cookies from this site: N · Sites with data: N"; Loading while the
  numbers come.
- **One permission.** Its switch, its choices as a radio group (Ask, Allow, Block with the
  default marked), Manage.

Commands are `PageInfoCommand`'s cases (`show`, `showCertificate`, `setPermission`,
`resetPermissions`, `siteSettings`, `manageSiteData`, `deleteSiteData`, `aboutThisPage`,
`reenableCertificateWarnings`, `reload`, `close`).

### Windows

Site settings, On-device site data and the certificate viewer are native windows
(`PageInfoWindows`: one per kind and pane, placed by `WindowPlacement`, in the shell window's theme
scope) whose content is a React page each (`cmux.site-settings`, `cmux.site-data`,
`cmux.certificate`, through `BrowserChromeWebHost`). A window opens once its page reported its
height, at a fixed width; it follows the height up to 640 pt, then the page scrolls. The certificate
viewer stacks its two tabs in one cell, so switching never resizes it.

- **Site settings.** Usage ("Cookies from this site: N · Sites with data: N") and Delete data; every
  permission the engine enforces with a menu of its choices (default marked); Reset permissions
  (off while nothing differs from its default); the engine note.
- **On-device site data.** Every site that stored data, this site first, with its details and a
  delete button; Loading, No site data; Done (Return).
- **Certificate viewer.** General (Issued To, Issued By, Validity Period, SHA-256 Fingerprints;
  dates in the page's language) and Details (hierarchy, fields, Export); the engine's verification
  failure under both. Export is the native save panel (PEM of the chosen certificate to the root).

The wire (`PageInfoWindowWire`, `windows.ts`): site settings `{site, origin, usage, permissions:
[{kind, setting, isDefault, choices}], canReset}`; site data `{entries: [{domain, cookieCount,
hasOtherData, isThirdParty}] | null}`; certificate `{chain: [{version, serialNumber,
signatureAlgorithm, issuer, subject, notBefore, notAfter, publicKeyAlgorithm,
subjectAlternativeNames, sha256Fingerprint, sha1Fingerprint, publicKeySHA256, pem}], failure?}`
with names `{commonName?, organization?, organizationalUnit?, summary}` and dates in ms. Commands
(`PageInfoWindowCommand`): `setPermission`, `resetPermissions`, `deleteSiteData` (a domain, or the
window's site), `exportCertificate {index}`, `close`. Escape closes every window.

## Import Cookies card

The card at the bottom of a browser page that offers to bring cookies over from the most used
browser on this Mac (`webviews/src/browser-chrome/cookie-import/CookieImportCard.tsx`, page
`pages/cookie-import`, host `CmuxNextBrowser/UI/BrowserCookieImportCard.swift`, gallery
`browser-chrome.cookie-import`). Leo, 2026-11-07: "this looks kind of ugly, to be honest. Like
this isn't styled well." The native card drew two labels and buttons of two different kinds,
with Don't Show Again as loose gray text at another height.
Leo, 2026-11-08: "i dont like this. 1. looks bad. 2. not glass. 3. talks about too much
irrelevant shit". It is a toast now, with one line, drawn on the glass the window's toasts use
(cmux-design-references `claude/live/sidebar-mobile-promo-banner`: an icon, one line, a link and
a close button; `cursor/live/import-nudge-dismiss-on-hover`: a quiet nudge with a close button,
not a banner).

- **Surface.** The native card is the toast surface's glass (`SurfaceRole.toast`: the neutral
  glass, the theme-tinted veil and rim, radius 9, opaque under Reduce Transparency). This is the
  material the window's toasts draw on the same overlay host, with the popups' elevation-2
  shadow. The page draws only the line and the answers on it. Width: the pane's, at most 7/8 of
  the palette width (560 at Standard), so the English line and its answers fit on one row.
- **Layout (Standard density).** One row, padding 8, 12 at the leading edge. The browser's app
  icon is 20 and sits 8 before the line. The line is in the body step (13), and wraps to a second
  line before it cuts a word. The answers follow at the trailing edge as one group. In a narrow
  pane, or with longer labels, the group wraps under the line, still at the trailing edge.
- **Answers.** These use the toast's grammar (toasts.css): clear text with the hover fill only
  under the pointer. Don't Show Again is in the secondary ink, Import… is bold in the ink, and the
  close button (×, labelled and titled Not Now) is last. No key hints: the card never takes focus,
  so Return and Escape stay the page's.
- **Copy.** The title is the only line. The detail ("Stay signed in to your sites. Nothing leaves
  this Mac.") and the Keep in sync checkbox are gone. Keep in sync is
  Settings > Browser > Import (`browser.import.cookieSync`, on by default), and Import uses
  that setting.
- **States.** It shows once, and only after its page has reported the height of its line. It
  fades in at that height, so there is no empty frame and no growth after it appears. Until
  then every click goes to the page. After that it stays put (Leo, 2026-11-08: "the import
  cookies from google chrome card flickers sometimes"):
  - Its page measuring itself turns its clicks on where it is.
  - The keyboard leaving its tab hides it where it is, and the keyboard coming back shows it
    again.
  - The same offer shown again keeps the card.
  - None of these presents it again or makes a new card.

  Any answer fades it out and the chrome answers the host. After cookies came over by any path
  (this card, File > Import from Browser, Import Cookies from Browser) it never shows again.

## Bookmarks bar

The strip under the toolbar that shows the Bookmarks Bar folder's items. It is native AppKit
(`CmuxNextBookmarks/UI/BookmarksBarView.swift`, `BookmarkBarItemView.swift`, `BookmarkFolderMenu.swift`,
`BookmarksBarView+Drag.swift`), filled by the app through `BookmarksBarSource`
(`BookmarksBarHostSource` over the app's `BookmarksBarHost`, the same model path as the star and the manager page).

- **Hosting.** Each browser tab's chrome holds one bar view as its accessory bar (height
  `controlHeight + space2`). The bar paints no fill: the chrome gives the accessory band the toolbar's
  fill, so the toolbar and the bar read as one band. No glass (the toolbar has none). A bar off its
  window rebuilds when it is shown again.
- **Layout (Standard density, pt).** Items `controlHeight` tall, `space1` apart, from the pane chrome
  inset; a small icon and the title in the body step; widest item `tabMaxWidth * 0.8`. What does not fit
  goes behind the chevron; Other Bookmarks keeps the trailing end when it has anything.
- **States.** No fill at rest, the gray hover fill fading at the quick motion step, the pressed fill
  at once. Empty bar with Other Bookmarks: the caption hint in the faint ink. A drop shows a 2 pt
  line between items.
- **Menus.** Folders, the chevron and Other Bookmarks open a native `NSMenu` (a submenu fills when it
  opens) with Open All past one link and "(empty)" for none. Right-click is the registry's Bookmark or
  Bookmarks Bar menu.
- **Clicks.** Click opens in the tab, Cmd-click or the middle button in a background tab, Shift or
  Cmd-Shift in a new tab. Drag an item to reorder it (pasteboard type `com.cmuxterm.bookmark-id`);
  drop a link to bookmark it there.

## Keyboard

- Toolbar: every control is a button in tab order; Space or Return presses it. Shortcuts
  (Cmd-L, Cmd-R, Cmd-[, Cmd-], Cmd-.) stay with the action registry, not the strip.
- Suggestions: the omnibox owns the keys (Up, Down, Ctrl-N/P, Return, Shift-Delete); rows only
  report hover and click (with Cmd, Shift, Option). A press on a row never takes focus from the
  field. Rows are `option`s of a `listbox`; the field points at the highlighted one with
  `aria-activedescendant` (`idPrefix`).
- Page Info: Up and Down move between rows, Left (Right in RTL) goes back from a subpage, Escape
  closes, Space or Return activates a row or flips a switch.

## Variants and recommendation

| surface | variants | recommended |
| --- | --- | --- |
| omnibar | flat (today), outlined (hairline, no fill), capsule (fully round) | **flat** |
| suggestions | joined (today), floating (separate glass popup), two-line (title over URL) | **joined** |
| Page Info | parity (today), grouped (inset cards per group), dense (one-line rows) | **parity** |
| Site settings | parity (today), grouped (inset cards), segmented (choices on the row) | **parity** |
| On-device site data | parity (today), grouped (this site / third parties headed), compact (one line) | **parity** |
| Certificate viewer | list (Details shows every field's value), tabs (today: pick a field), sheet (no tabs) | **list** |
| Import Cookies card | toast (one row: the line, Don't Show Again and Import as text, the close button as Not Now), buttons (one row of ghost, subtle and accent buttons), stacked (the line, then a row of buttons) | **toast** |

- **Flat** keeps the bar a field you can find at a glance on any wallpaper or theme, and its fill
  is what the joined card continues. Outlined reads lighter but loses the bar on busy pages and
  makes the open card look like a different object; capsule fights the 8 pt radius every pane and
  tab pill shares.
- **Joined** keeps the typed text and the rows on one column, with no gap for the pointer to fall
  through, and opaque, so page text never shows under the rows. Floating is what other popups do,
  but here it breaks the column and puts glass over a page the user is reading. Two-line fits long
  titles at the cost of half as many rows in view.
- **Parity** matches the native bubble row for row, so the move to React changes nothing a user
  sees. Grouped reads well but grows the card by a third; dense hides the "Can ask to …" sentences
  that explain what a switch does.
- **Site settings and site data stay at parity** for the same reason. Segmented choices save a
  click but make every row three buttons wide and crowd the window's fixed width; the grouped site
  data list only helps once many third parties stored data, and compact rows cut the domain short.
- **List** for the certificate viewer: the native Details tab hid each value behind picking its
  field in a short table; listing every field with its value (selectable to copy) reads the whole
  certificate at once in the same window, and keeps General as today. The sheet loses the quick
  General summary under a long scroll.
- **Split** reads in order: what this is, then the quiet way out on the left and the two real
  answers together on the right, so the eye lands on Import last. Trailing puts three
  same-height targets side by side, which makes Don't Show Again look like a third button of
  equal weight. Inline saves a row in wide panes but squeezes the text in the narrow ones the
  browser pane often is.
