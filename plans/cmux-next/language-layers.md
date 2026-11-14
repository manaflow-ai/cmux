# Which layer: Swift, React or Rust

Lawrence (2026-11-09): Home is Swift. Toasts, dialogs, toolbars, the sidebar and everything in
Cmd+Shift+P are Swift. Only the agent chat UI is React. Core logic is Rust.

This file is the rule for new work and for review. It replaces the MOVE verdicts of
`react-screens.md` for native chrome; that file's KEEP rows already said the same.

## The rule

| Layer | Owns |
|---|---|
| Swift (AppKit) | Home (transcript, conversation list, Chief panel, its sheets). Native chrome: windows, the sidebar, toolbars and bars, the tab strip, menus, popovers and bubbles, sheets, dialogs and alerts, toasts, tooltips, the Command Palette and its pages, drag to and from other apps. |
| React | The agent chat pane (transcript, composer, tool cards). Full tab pages that read like a document and scroll (Settings, History, the diff and Markdown viewers), listed in `scripts/cmux-next/react-pages.tsv`. |
| Rust | State and logic with no view: the daemon, acpmux, cmux-tui, Cloud core, the action catalog. Swift and React only show it. |

## The decision test

Answer in order. The first "yes" decides.

1. Is it part of Home? **Swift.**
2. Is it attached to a native view or to the window frame: a bar, a toolbar item, a sidebar section
   or row, a popover or bubble on a native control, a sheet, a dialog, a toast, a menu? **Swift.**
3. Can the person reach it from Cmd+Shift+P (a palette row, a palette page, a palette preview)?
   **Swift.**
4. Does it need the same first responder, focus ring, text input or drag pasteboard as the AppKit
   views beside it? **Swift.**
5. Is it the agent chat pane? **React.**
6. Is it a whole tab page with scrolling content and no native neighbor inside its bounds?
   **React is allowed.** A new one needs a row in `react-pages.tsv` and these answers in the pull
   request.
7. Is it logic or state with no view? **Rust**, with Swift only as host glue.

When two answers disagree, the earlier one wins. Line count is not an argument: a move that removes
more Swift than it adds React can still be on the wrong side of this test.

## Signs that a change went too far

A reviewer stops the change when it does one of these.

- It deletes AppKit view files and adds a directory under `webviews/src/pages/` for the same surface.
- It hosts a `PageWebView` inside a popover, sheet, bar, sidebar section, card or overlay window.
- It makes one web view per bar, row or card.
- It draws on a transparent web overlay above native views (toasts, dialogs).
- It moves a surface that the Command Palette opens, or a palette page, into a web page.
- It moves a Home surface into a web page.
- It adds a `debt` or `review` row to `react-pages.tsv`.

What these moves cost in November 2026 (the audit of 80 commits, 10 of them on the wrong side):
the toast close button could not be hovered; dialogs lost native focus and key handling; the
bookmarks bar needed one web page per bar; Home lost drag to Finder until it was built again.

## The mechanical check

`scripts/cmux-next/check-react-pages.py` reads `scripts/cmux-next/react-pages.tsv`. Every directory
under `webviews/src/pages/` needs a row:

- `page`: a full tab page that passes question 6.
- `debt`: native chrome or Home drawn in React today. It goes back to Swift; then delete the row.
- `review`: hosted inside native chrome and not judged yet. Judge it, then make it `page` or `debt`.

A directory with no row fails. With `--base`, a row that is new since the base must be `page`: no
change may add debt.

The same check keeps the Command Palette in Swift (question 3): a file of `CmuxNextPalette` that
imports WebKit or the pages module, or names `WKWebView` or `PageWebView`, fails. On 2026-11-11 the
target has none, and it does not depend on the pages module.

The check cannot see a web view hosted inside other native chrome; that part is the review bots'
(`.github/review-bot-rules/native-chrome-layer.md`).
