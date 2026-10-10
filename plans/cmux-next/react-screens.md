# React screens: which Swift screens move to React pages

Lawrence (2026-10-10): every complicated Swift screen in cmux-next becomes a React page, built like
History; the iMessage-style Home pane stays native (the channels Home page is its React
alternative). Epic bead: cx-0rpl.

## The pattern (History)

- The page is `webviews/src/pages/<page>/` (main.tsx, store.ts, the page component, mockProvider.ts
  for `/<page>/?mock` and the gallery, `<page>.gallery.ts(x)`, generated/strings.json).
- The app hosts it in a `PageWebView` (CmuxNextPages) with a `PageDescriptor`: id
  `cmux.<page>` (also the origin, listed in `PageID.firstParty`), its op namespaces, the native
  ops it may call, and the registry actions it may run.
- Data comes through the page bridge: a `PageProvider` per namespace. The daemon owns the data
  where it is shared state (`DaemonPageRelay`, page access checked by the daemon); app-local
  state (tunables, the key table) has an app provider. Swift keeps only the host, windows and
  platform APIs (pasteboard, panels, sheets).
- Strings come from xcstrings through `webviews/scripts/pages/gen-strings.mjs` (21 locales).
- Build: `scripts/cmux-next/build-pages-web.sh` PAGES; dev HMR: `webviews/dev-server/plugins.ts`
  DEV_PAGES and `PageDevServer.pageIDs`.
- While both exist, a `PageTunables` choice (`native` / `web`) picks the page; the Swift view and
  the tunable are deleted after the React page is proven.

## Inventory (CmuxNext, 2026-10-10, tip a1b9443b7f31)

Size = lines of SwiftUI/AppKit view code (view, window and controller files; models not counted).

| Screen | Size | State | Verdict |
|---|---:|---|---|
| Sidebar (workspaces, chats, cards, profile bar) | 6012 | high | KEEP: core window chrome |
| Browser chrome (address bar, omnibox, find, prompt bar) | 4431 | high | KEEP: browser surface |
| Onboarding window (steps, import, projects, accounts) | 3502 + 364 | high | MOVE (permission prompts and the helper drag panel stay native) |
| Layout, panes, dividers, drop overlay | 2425 | high | KEEP: surfaces |
| Command palette | 2182 | high | KEEP: latency-bound chrome |
| Home, iMessage-style | 2097 | high | KEEP (Lawrence); the channels Home is React |
| Tab strip and hover card | 900 | high | KEEP: chrome |
| Main window chrome | 1714 | high | KEEP |
| Terminal surface, find bar, copy mode | 1612 | high | KEEP: surface |
| Feed inbox (tab and menubar panel) | 1550 | high | MOVE |
| Page Info popover; Certificate, Site Settings, Site Data windows | 1509 | medium | KEEP the popover; MOVE the three windows |
| Remote desktop pane, machine browser tab | 1418 | high | KEEP: surface |
| Server menubar popover (dashboard, pairing, approver) | 1306 | medium | MOVE the content; the popover shell stays native |
| App Permissions UI (consent sheet, installed apps) | 1112 | medium | not hosted anywhere: delete (React apps page covers grants) |
| Agent Activity page | 906 | medium-high | MOVE |
| App Store, native | 889 | medium | ALREADY React (`apps.store.surface`, default native): flip, delete Swift |
| Tasks page | 862 | medium | MOVE |
| Agent pane, New Tab | 834 | — | ALREADY React (`cmux.agent`) |
| Notifications panel | 711 | medium | MOVE |
| App scene renderer (app manifests) | 695 | medium | KEEP: renders third-party manifests natively |
| Remote browser pane | 601 | high | KEEP: surface |
| Sidebar group editor popover | 503 | low | KEEP: anchored popover |
| Bookmark Manager page and editor sheet | 495 | medium | MOVE |
| History, native | 494 | medium | ALREADY React (`history.surface`, default native): flip, delete Swift (cx-gzh.16) |
| Onboarding gallery window | 481 | low | KEEP: dev tool |
| Debug Settings window and tab | 458 | medium | MOVE: first (cx-0rpl.2) |
| Popups, question card, tab group editor, update sheet, share sheet, quit alerts, which-key, indicators | 120-402 each | low | KEEP: thin chrome, sheets, NSAlert |
| What's New, native page | 321 | low | ALREADY React (changelog page): delete the native duplicate |
| Settings, Keyboard Shortcuts, Passwords, Changelog, Diff, Editor, Markdown, Icon picker, CodeRouter, Cloud, Chief inspector | host only | — | ALREADY React |

## MOVE list, ranked by value

1. Debug Settings: Lawrence's first ask; every tunable from the registry's data (new tunables
   appear with no page code). In progress, cx-0rpl.2.
2. Feed inbox (1550): the agent decision surface (answer, approve); high state and forms; two
   hosts (tab, menubar panel) share one page.
3. Tasks page (862): board, inbox, detail, new task; data already comes from a store.
4. Notifications panel (711): list and actions; same row model as Feed.
5. Agent Activity page (906): lanes, grid, detail; frames show as images.
6. Server popover content (1306): dashboard, pairing, approver; the NSPopover shell stays.
7. Bookmark Manager (495): tree and edit sheet.
8. Page Info windows (Certificate, Site Settings, Site Data, about 360).
9. Onboarding (3502): largest, but hq-a3 changes it now (onboarding landing B deletes the
   wizard); start after that lane lands.

Clean-ups beside the moves (small, no new page): flip `history.surface` and
`apps.store.surface` to web and delete the Swift pages; delete the native What's New page and the
unhosted App Permissions UI.
