# Browser: Chrome parity (R113)

Lawrence (R113, 2026-10-04): "think from first principles what would make
browser useful, and get to chrome parity at the very least; think of
everything that needs to be perfect for someone to adopt cmux as their
primary browser."

Status from a code trace at feat-cmux-next 40deb713ef6 (browser power-user
lead, 2026-10-04), plus the R88 audit. W = WebKit tab, C = Chromium (CEF)
tab, the default engine. Owners: **app** = browser power-user lead
(app-level, both engines), **engine** = browser lead (CEF host, fork,
WebKit engine internals), **pw** = password lead, **hist** = React UIs lead
(History H3), **bm** = bookmarks owner, **keys** = keybindings lead,
**hq-48** = browser toolbar (R80). "UNSURE" means not proven on a build.

## Rank 1: blocks adoption as the primary browser

A user who makes cmux the default browser hits these in the first day.

| Item | W | C | Owner | Notes |
| --- | --- | --- | --- | --- |
| Omnibar opens in new tab (Cmd-Return, modified row click) | fixed (P1) | fixed (P1) | app | was loading in the current tab |
| Downloads UI (progress, list, reveal, open, cancel, retry) | missing | missing/UNSURE | app (UI), engine (C events) | S2: both engines feed one App list (`BrowserDownloadList`) with progress and end, a notice on finish/failure, one policy (`BrowserDownloadPolicy`: Downloads folder or chosen file, sanitized unique names, quarantine, never open). C through shim download events (`CEFDownloads`). The list UI is still missing |
| New tabs open next to the opener (Chrome order) | broken | broken | app + daemon (crate slot) | daemon appends to strip end |
| Session restore with back/forward history | URL only | works | engine (W interactionState), app | W history lost on relaunch and Cmd-Shift-T |
| Passwords: save prompt, fill, generator, manager page | missing | partial | pw | C fills from Chromium store; no save UI |
| Passkeys (WebAuthn platform) | missing | missing | pw | passkeys.md K13/K14 |
| Hard reload bypassing cache (Cmd-Shift-R) | works | refused | engine | shim needs ReloadIgnoreCache |
| Print (Cmd-P conflicts with Go to Workspace, keep cmux chord) | missing | UNSURE | app (W NSPrintOperation, File > Print action), engine (C) | Print via menu and palette; chord decision D4 kept |
| PDF viewer, save and print PDF | works (native) | works (fork) | engine | verify save/print buttons on a build |
| HTTP basic auth dialog | missing | UNSURE | app (W), engine (C) | W: a 401 renders the server page |
| Certificate error interstitial with proceed | missing (generic error) | UNSURE | app (W), engine (C) | W has no server-trust delegate |
| mailto: and other handlers from pages and other apps | missing | missing | app | Info.plist has http/https only |
| Address and card autofill | missing | UNSURE | pw | C may work with no cmux UI |
| Clear browsing data (history, cookies, cache, by time range) | partial | partial | app | per-site data only; no global sheet |
| Zoom remembered per site | per tab | per tab | app | Chrome keys zoom by host |
| Find in page with count | works | works | app | |
| Default browser registration, open links from other apps | works | works | app | |
| Import from Chrome/Safari/Arc/Firefox | partial | partial | bm, pw | passwords and cookies only into C |
| Trackpad swipe back/forward | works | UNSURE | engine (C) | history.md: not built for C |
| Keyboard focus, Esc, Cmd-L, Cmd-[ ], Cmd-R, Cmd-W, Ctrl-Tab | works | works | app | P3 makes page chords work from the omnibar |

## Rank 2: daily friction for a power user

| Item | W | C | Owner | Notes |
| --- | --- | --- | --- | --- |
| Shift-click / Shift-Return opens a new window | fixed (P5) | fixed (R123) | app | C: a page's NEW_WINDOW request goes through the link mapping |
| Modified link clicks match Chrome and are configurable (`browser.links.*`, Settings > Browser > Links) | fixed (R123) | fixed (R123), UNSURE on a build | app | one mapping (`BrowserLinkClickMapping`, `CEFLinkClicks.placement`). C: the last mouse-up on the requesting page (1 s; cmux UI never counts) separates Shift-Cmd-click from plain target=_blank (both NEW_FOREGROUND_TAB); middle-click follows Cmd-click; Option-click always downloads (Blink downloads it directly); Download on any other gesture downloads in the opener (shim StartDownload); a request without a user gesture never follows the mapping (S1) |
| Link menu: Open in New Tab (background), New Window, New Space, New Workspace, Split Right, Incognito Window, Save Link As, Copy Link, Copy Link Text | fixed (R123 B), UNSURE on a build | fixed (R123 B) | app | one cmux menu for both engines (`BrowserHitMenu`, `browserLink` actions with `url`); W hit from a `contextmenu` script; C Save Link As / Save Image As: cmux save panel, then the shim downloads into the chosen file (S2), from the menu, palette or action.run |
| Image menu: Open Image in New Tab, Save Image As, Copy Image, Copy Image Address | fixed (R123 B), UNSURE on a build | fixed (R123 B) | app, engine (C save) | Copy Image loads the address without page cookies; C save as above |
| Selection menu: Copy, Search <engine> for "…", Look Up "…" | fixed (R123 B), UNSURE on a build | fixed (R123 B) | app | outside editable fields; the omnibar's search engine |
| Drag a URL or link onto the tab strip | missing | missing | app | strip accepts only tab drags |
| Audio indicator and mute per tab | missing | missing | app (UI), engine (C audible event) | toggleTabAudioMute unported |
| Media controls / Now Playing | missing | missing | app (W), engine (C) | MPNowPlayingInfoCenter |
| Picture in picture | UNSURE | partial | engine | C has the window request |
| Cmd-. stop, Cmd-Shift-C copy URL, Shift-Cmd-G find previous | fixed (P4/P2) | fixed | app | |
| Omnibar suggestions: history index, open tabs, bookmarks, remote search, calculator | partial | partial | app (+hist for visits) | R110 design: omnibar-suggestions.md |
| Search engine settings (built-ins, custom, per profile) | missing setting | missing setting | app | engines exist, no setting key |
| Geolocation and notification permission prompts | missing | UNSURE | app (W), engine (C) | W has camera/mic only |
| Site settings and permissions | works | works | app | |
| Cookies and site data per site | works | works | app | |
| Spellcheck, dictionary lookup (Ctrl-Cmd-D) | UNSURE | UNSURE | engine | verify on a build |
| Translate | missing | UNSURE | engine | C bubble anchors to the hidden toolbar |
| Share sheet (File > Share) | missing | missing | app | NSSharingServicePicker |
| Reader mode | missing | missing | app | |
| Open in another browser (Safari, Chrome) | missing (bound unavailable) | missing | app | openLinkInDefaultBrowser unavailable |
| Tab search (Cmd-Shift-A), tab groups, pinned tabs | works | works | app | |
| Tab hibernation / memory saver | works | works | app | tab-lifecycle.md |
| Middle-click a tab, tear off to a window, hover card title | works | works | app | |
| Loading spinner, progress line, favicon | works | works | app | |
| Handoff / NSUserActivity | missing | missing | app | continue a page on iPhone |

## Rank 3: trust, privacy, accessibility

| Item | W | C | Owner | Notes |
| --- | --- | --- | --- | --- |
| Tracking protection / content blocking | missing | extensions only | app (W content rules), engine (C) | |
| Safe browsing (malware, phishing) | missing | missing/UNSURE | engine | fork build flag |
| HTTPS upgrade (HTTPS-first) | missing | UNSURE | engine | |
| Mixed content indicator | works | UNSURE | app | |
| Certificate viewer | works | works | app | |
| Incognito windows | works | works | app | |
| VoiceOver in pages | UNSURE | UNSURE | engine | C accessibility switch not set |
| Profiles | works | works | app | |
| Sync across devices | missing | missing | app + backend | product decision |
| User agent / device emulation | missing | missing | engine | DevTools on C covers emulation |
| DevTools / Web Inspector | works | works | engine | |
| Page screenshot (full, section) | partial | partial | app | section unavailable |

## Rank 4: cmux advantages to make obvious

Agents drive the browser (browser.page.* verbs; Rust browser host and REPL
in progress: browser-host.md), browser tabs in splits, columns and
workspaces, link hints (`f`, `F`), browser focus mode, per-workspace and
per-space browser profiles, cmux:// links, browser tabs restored with the
workspace, tab search across every machine.

## Decided (Lawrence through the coordinator, 2026-10-04)

- Keep the cmux chords that differ from Chrome: Cmd-1..9 workspaces, Cmd-T
  agent page, Cmd-D split right, Cmd-P go to workspace, Cmd-Shift-W close
  workspace, Cmd-Opt-U toggle unread (D1-D6). Print, bookmark and view
  source get menu and palette entries, not Chrome's chords.
- Shift-Return / Shift-click: a new window with a new workspace holding the
  tab (D7).
- Omnibar: remote suggestions on by default (never for URL-like or local
  input, never incognito), fully configurable search engines per profile,
  default Google, calculator row (local only); Ctrl-J/K and Ctrl-N/P move
  rows while the list is open.

## Order (app-level items)

P1 omnibar dispositions, R101 chrome spacing, P2 Shift-Cmd-G, P3 page chords
from the omnibar, P4 Cmd-. and Cmd-Shift-C, P5/P6 new window and link menu,
then: downloads UI, print (W), HTTP auth + certificate interstitial (W),
mailto handler, zoom per site, clear browsing data, drag URL to strip,
search engine settings + R110 suggestions, audio indicator and mute,
geolocation and notification prompts (W), share sheet, reader mode,
open in default browser, Handoff.
