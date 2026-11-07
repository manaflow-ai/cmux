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
