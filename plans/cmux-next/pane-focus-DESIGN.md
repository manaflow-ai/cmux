# cmux-next: pane focus edge cases (PANE-FOCUS)

User (2026-10-20): "monoco editor on focus does not get focus. from first principles get all the
edge cases for focusing on panes fixed."

This note builds on focus.md (the `FocusCoordinator`, the Rust reducer `cmux-focus-core`, and
`FocusEffectApplier`) and close-focus.md (the successor after a close). It adds the last link
those documents leave out: **inside a web view, which DOM element has the keyboard**.

## 1. The focus chain, from first principles

A key typed by the user reaches a text input only when every link holds:

| Level | Owner | Holds |
| --- | --- | --- |
| L1 app | macOS | cmux is the active app |
| L2 window | AppKit | the cmux window is key (not a palette panel, a sheet, a Chromium page window) |
| L3 pane | `FocusState.pane` (reducer) | the focused pane of the shown workspace |
| L4 tab | `WindowState.selection` | the selected tab of that pane, presented (`contentPresented`) |
| L5 view | AppKit first responder (`FocusEffectApplier.moveResponder`) | the tab's focus target: Ghostty `TerminalSurfaceView`, a page's `PageWKWebView`, a browser tab's WebKit view or Chromium window, Home's message box, a Files list |
| L6 element | the DOM (web views only) | the page's primary input: Monaco's text area, Settings' search, Home Channels' composer |

L1 to L5 have one owner each (focus.md): the reducer, plus one memory above it in
`FocusCoordinator`, `OmnibarFocusMemory`, which brings a browser tab's address bar back (P20). L6 had none: `makeFirstResponder(webView)` makes
WebKit restore the element that had focus in that document before, and when there is none
(a page that just loaded, or a page whose focused element went away), nothing in the page
has focus. Keys then go to `<body>`, and typing goes nowhere.

## 2. Monaco root cause (row P1)

- The file page (`FilePageService.makeView`) is a `PageWebView`; its focus target is the
  `PageWKWebView` (`InternalPageView.focusTarget`). The applier makes it first responder
  (`FocusEffectApplier.moveResponder`, case `.page`). That part worked.
- The editor page (`webviews/src/pages/editor`) has `MonacoView.focus()`, but nothing called it.
  Monaco is created asynchronously (a lazy chunk, after `cmux.editor.open`), so even an
  autofocus at creation would miss the case where the web view got the keyboard first.
- Every editor test placed the caret with `editor.focus()` by hand (`caret()` in
  editor-page.test.ts), so no test saw the gap.

So after a pane click outside the text (the tab bar, the status bar), Cmd-Opt-Arrow, a tab
switch, a new file tab, a workspace switch or a relaunch, the web view had the keyboard and
Monaco did not.

## 3. Fix: one "focus content" hook for every page

One path, not one patch per entry point:

1. Host (`CmuxNextPages`): `PageWKWebView.becomeFirstResponder` reports to its `PageWebView`,
   which sends the page command `focusContent` (`PageNativeOp.focusContent`, one of the shared
   commands every page takes). Every way the web view gets the keyboard goes through
   `becomeFirstResponder`: the applier, `PageWebView.focusPage()`, a click, a restore.
2. Page (`webviews/src/pages/shared/pageFocus.ts`): `contentFocus(target)` focuses the page's
   primary input when the host sends `focusContent` or the window gets focus (WebKit's own
   signal for the same moment), and **only when nothing in the page has focus**
   (`document.activeElement` is the body). So a click on a field, an open find widget, or a
   restored element keeps the keyboard. A request that comes before the input exists
   (Monaco still loading) is kept and applied once, when the input mounts.
3. The editor page wires it to `MonacoView.focus()`. Other pages can wire their primary input
   the same way (one call), see open rows below.

## 4. The matrix

Expected first responder (L5) and element (L6) for each way focus moves. "Status" says what
this change did; "reducer" means the rule lives in `cmux-focus-core`/`FocusEffectApplier`
already (focus.md, close-focus.md) and was not changed here.

| Row | Event | Expected L3/L4 | Expected L5/L6 | Status |
| --- | --- | --- | --- | --- |
| P1 | Any path that gives a file (Monaco) page the keyboard | that pane/tab | `PageWKWebView`, Monaco text area | **fixed** (`focusContent` + `contentFocus`), tests: editor-page.test.ts (3), PageFocusContentTests |
| P2 | Monaco not mounted yet when the pane gets focus (cold tab, relaunch) | same | Monaco text area once mounted | **fixed** (pending request applied at mount), test "before Monaco mounts" |
| P3 | Web view gets the keyboard back while a page field (find widget) has focus | same | that field kept | **fixed** (only-when-nothing-focused rule), test "only when nothing in it has focus" |
| P4 | Mouse-down in a pane (a162 `8536e1bd16a`) | clicked pane, on mouse-down | content of that pane; a click inside text moves L6 itself | reducer; P1 covers a click outside Monaco's text |
| P5 | Cmd-Opt-Arrow (Ghostty default, a246) | neighbor pane, history first (focus.md 4a) | its content | reducer + P1 for pages |
| P6 | Cmd-1..9, tab switch, Ctrl-Tab | the pane's new tab | its content | reducer + P1 for pages |
| P7 | New tab / split (a215 "split steals focus") | the new pane only for a user intent; a CLI split without `focus` keeps focus | new content once presented | reducer (`expectation` + generation); a215 owns the steal |
| P8 | Close tab / pane | close-focus.md successor | successor's content | reducer; P1 for page successors |
| P9 | Zoom (Cmd-Shift-Enter, a252) | unchanged | unchanged; the zoomed content keeps L5 | not changed here (a252 owns the animation) |
| P10 | Workspace switch | remembered pane, else first | its content | reducer; P1 for pages |
| P11 | Window becomes key / app reactivates | unchanged | the resolved target re-applied; WebKit restores L6, P1 fills an empty L6 | reducer + P1 (window `focus` event) |
| P12 | Home right pane opens a tab (a150, a101) | per a150 (Home keeps the keyboard unless the user clicked) | — | not changed here (a150 owns it) |
| P13 | CLI/MCP `focus: true` | named pane/tab | its content | reducer; P1 for pages |
| P14 | Restore after relaunch | restored focused pane | its content once presented (`contentPresented`) | reducer; P2 for Monaco |
| P15 | Home Chief pane (a250) | never closes | Home message box | a250 owns it |
| P16 | Markdown page (editable, ProseMirror) | that pane/tab | web view; the editor only if focusing it keeps the scroll position (ProseMirror `focus()` scrolls its selection, at the top for a fresh document, into view) | **open**: takes `focusContent` today and ignores it; wire `contentFocus` with a scroll-keeping focus, coordinate with a223 (Markdown selection) and a217 (table scroll) |
| P16b | Diff page | that pane/tab | web view; no text input, so `<body>` is right (keys scroll) | correct as is |
| P17 | Settings page | that pane/tab | web view; the search field only on Cmd-F (`focusSearch`), not on every focus | correct as is: auto-focusing search would eat type-to-scroll |
| P18 | Agent chat pane (`AgentPaneView`, its own web view) | that pane/tab | composer, unless a field has focus, text outside the composer is selected, or a click activated the pane (the click places the keyboard, as in Claude desktop: a press outside the composer leaves it blurred; Escape in an idle composer blurs it; Leo 2026-10-20) | **fixed on the page host** (`agent.pageHost`, a `PageWebView`): the page takes `focusContent` into its idle composer claim (`useComposerKeyboard`, composerFocus.ts), test agent-pane-focus-content.test.ts. The old host (`AgentPaneWKWebView`, the default) sends no `focusContent`; the window's `focus` event and the composer's ready event make the same claim there |
| P19 | Browser tabs (third-party pages) | that pane/tab | WebKit view / Chromium page window; the page's own autofocus rules | correct as is: cmux must not focus elements in a third-party page |
| P20 | Return to a browser tab whose address bar had the keyboard when left (tab click, tab shortcut, pane or workspace switch) | that tab | its address bar (Chrome `OmniboxEditModel::RestoreState`); a click in its page or any other target there forgets it | in the model: `OmnibarFocusMemory` (a146, `FocusCoordinator`, above the reducer, which drops `addressBar` on a tab change); tests `OmnibarFocusMemoryTests`. L5 only; browser tabs are not `PageWKWebView`, so `focusContent` never reaches them |

## 5. Tests

- `webviews/test/editor-page.test.ts`, Chromium and WebKit: `focusContent` lands typing in
  Monaco without a click; a request before Monaco mounts focuses it at mount; a focused find
  field keeps the keyboard, an empty focus is filled.
- `PageFocusContentTests` (CmuxNextPagesTests): every page descriptor takes `focusContent`;
  `PageWKWebView` reports each `becomeFirstResponder`.
- `pageFocus.test.ts`: the request/mount rules of `contentFocus` on a fake document.
