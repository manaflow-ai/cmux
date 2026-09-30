# cmux browser REPL

`cmux browser repl` is a persistent JavaScript REPL that drives cmux browser
panes for agents. It has one API. It covers every browser-operation capability
of Aside's `aside repl` and ChatGPT for Chrome (the Codex `browser`/`chrome`
plugins), and improves on both where they differ. It does not copy either
surface: there are no dialects, no `agent` object, and no numbered AX text.

Capability coverage is enforced by
[capabilities.json](../../tests/browser-parity/capabilities.json): every
reference member maps to a cmux equivalent and the scenario that proves it, or
to a written exclusion.

## Principles

1. **Playwright is the action model.** Models know Playwright; both references
   converge on it (Aside's `page` is Playwright-shaped, ChatGPT exposes
   `tab.playwright`). `page`, `locator`, `keyboard`, `mouse`, events and waits
   follow Playwright semantics exactly where Playwright defines them.
2. **One observation format.** A compact accessibility snapshot with refs. Refs
   work anywhere a selector works. There is no second format to choose.
3. **Real input only.** Every click, hover, drag, wheel and key is a native
   event (`isTrusted === true`). There is no synthetic-event fallback.
4. **Nothing silent.** Dialogs and file choosers without a handler stay open and
   show in the snapshot until the agent answers them. Ambiguous input failures
   are reported and never replayed.
5. **Less to remember.** Top-level `const`/`let` persist across calls, the last
   expression's value prints automatically, and printing a snapshot picks the
   diff or the full tree by size.

## Globals

| Global | Purpose |
| --- | --- |
| `page` | The current tab, a Playwright `Page`. |
| `tabs` | `list()`, `open(url, { background })`, `current()`, `use(tabOrId)`, `get(id)`. `list()` returns `{ id, title, url, active, current }` without attaching; `open`, `current`, `use` and `get` return a `Page` with a stable `page.id`. |
| `snapshot(target?, options?)` | Accessibility snapshot of `page`, a locator, or a ref string. See [Snapshot](#snapshot). |
| `screenshot(target?, options?)` | PNG of the viewport, full page, locator or ref. `{ annotate: true }` draws each ref's box and label. Returns an `Image` that displays when printed. |
| `fetch` | Standard `fetch` that sends the current tab's cookies. |
| `fs`, `path`, `os`, `Buffer` | Node-compatible subsets. Files are limited to the session directory (the caller's cwd) and the system temp directory. `import("node:fs")` and friends return the same modules. |
| `sleep(ms)`, `display(value)` | Wait; show a value or image to the agent. |
| `session` | `name(label)` labels this session's tabs in the UI; `keep(page)` keeps a tab open after a one-shot run ends; `id`; `guide()` returns the agent guide (`Resources/browser-repl/guide.md`). |

### Page additions beyond Playwright

| Member | Purpose | Replaces |
| --- | --- | --- |
| `page.locator("e5")`, `page.ref("e5")` | Resolve a snapshot ref. Stale refs throw `ref e5 is stale: the element was removed; take a new snapshot`. | Aside refs, ChatGPT `ax.*(index)`, `dom_cua` node ids |
| `page.dialog()` | The open JavaScript dialog or `null`: `{ type, message, defaultValue, accept(text?), dismiss() }`. | ChatGPT `getJsDialog()` |
| `page.fileChooser()` | The open file chooser or `null`: `{ multiple, setFiles(files), cancel() }`. | ChatGPT chooser flow |
| `page.consoleMessages({ level, filter, limit })`, `page.errors()` | Console history and uncaught errors since the tab opened. | ChatGPT `dev.logs()` |
| `page.clipboard` | `readText()`, `writeText(text)`, `read()`, `write(items)` on a per-tab clipboard used by paste. | ChatGPT `clipboard` |
| `page.elementAt(x, y)` | `{ ref, role, name, box }` for the topmost element at a viewport point. | ChatGPT `elementInfo()` |
| `page.keep()` | Keep this tab open after a one-shot run. | ChatGPT `markDeliverable()` |

Everything else uses standard Playwright: `page.mouse` replaces ChatGPT `cua`
coordinates, `page.on("popup")`, `waitForEvent("download")`, `page.pdf()`,
`page.setViewportSize()`, `frameLocator`, `getByRole`, and so on.

## Snapshot

```
title: Sign up
url: http://localhost:8765/
- navigation "Main" [ref=e1]:
  - link "Home" [ref=e2]
- main:
  - heading "Sign up" [level=1]
  - textbox "Email" [ref=e3] [placeholder="you@x.com"]: "me@x.com"
  - checkbox "Accept terms" [ref=e4] [checked]
  - combobox "Plan" [ref=e5] [options: Free, Pro, Team]: "Pro"
  - button "Create account" [ref=e6] [focused]
  - table "Scores":
    - row [header]: "Name | Score"
    - row: "Ada | 9"
    - row:
      - cell: "Linus"
      - link "Profile" [ref=e7]
  - list:
    - link "Pricing" [ref=e8]
    - listitem: "Plain item"
  - text: "Plain bold text."
  - iframe "Payment" [ref=e9]:
    - textbox "Card" [ref=f1e1]
```

Rules, and how they improve on the references:

- **Refs** go on interactive elements, iframes, scrollable regions and named
  landmarks, dialogs and lists (so a region can be scoped with
  `snapshot("e1")`). A ref is bound to its DOM node for the node's life and is
  never reused in that frame, even after the frame loads a new document. A
  removed node's ref fails at once (`ref e5 is stale`); a ref never issued
  fails with `ref e9 does not exist`. Aside renumbers a ref when its name
  changes; ChatGPT reuses indices after removals.
- **Roles** are Playwright's (`getByRole` finds them), except controls HTML
  has no ARIA role for: `summary` prints as `button`, an editable element as
  `textbox`, `canvas` as `canvas`. Their refs work; `getByRole` does not find
  them.
- **Frames**, including cross-origin and `srcdoc`, inline under their iframe
  with `fN` prefixes in DOM order, at any depth. Shadow roots are pierced,
  closed ones too: the page agent's content world is created with WebKit's
  `allowAccessToClosedShadowRoots` option (the one web extension worlds use),
  so in that world `element.shadowRoot` returns a closed root, and the
  snapshot, refs, `getByRole` and CSS locators reach inside the way an
  accessibility tree does. Page scripts still see `null`. Playwright does not
  enter closed roots; this is a deliberate difference.
- **Visibility** is what a user can see. An element and its subtree are left
  out when it or an ancestor is `display:none`, `content-visibility:hidden`
  (a closed `<details>`, `hidden="until-found"` such as Wikipedia's collapsed
  navbox rows), `inert`, `aria-hidden="true"`, or clipped away inside a
  zero-width or zero-height box with `overflow` other than `visible` (a
  collapsed accordion), or lying entirely outside the box of an ancestor
  with `overflow: hidden|clip` (per axis) or `contain: paint` (Amazon's
  overflowing nav belt, GitHub's ellipsized `#1234` links). Clipping follows
  CSS containing blocks: an absolutely positioned element escapes clippers
  below its positioned ancestor, a fixed one all but those at or above a
  transformed ancestor; the root, `body` and scroll containers do not clip.
  A `visibility:hidden` element is left out, but its
  `visibility:visible` children print. This is Playwright's
  `isElementVisible` (`checkVisibility`, which Playwright skips on WebKit)
  without its non-empty-box test, so an empty progress bar still counts.
  Screen-reader-only text (1px clipped boxes) and `opacity:0` controls
  (custom checkboxes, hover-revealed anchors) print; they are there to be
  read or used.
- **Names** come from content only for leaf roles that ARIA names from
  content: button, link, heading, option, tab, menu items, checkbox, radio,
  switch, tooltip and treeitem. Rows, cells, list items, paragraphs and other
  containers take only an author name (`aria-label`, `aria-labelledby`), so
  their content prints once, as children. A name that repeats the content it
  would print is printed instead of that content when it holds no refs and
  fits in 200 characters; otherwise the content prints and the name is
  dropped. A lone text a name already contains (an `aria-label` that extends
  the visible text) is not repeated. Other printed names are cut at 100
  characters with `…`; refs still resolve.
- **States** print as `[checked]`, `[checked=mixed]`, `[disabled]`,
  `[expanded]`, `[expanded=false]`, `[pressed]`, `[selected]`, `[focused]`,
  `[required]`, `[invalid]`, `[readonly]`, `[level=N]`, `[scrollable]` (why a
  plain region has a ref) and, with `showHidden`, `[hidden]`. Aside drops
  expanded and pressed. `[focused]` inside an iframe prints only when that
  iframe holds the page's focus.
- **Values** print after a colon. A closed drop-down shows its selected
  value and its options on the same line, `[options: Free, Pro, Team]`, the
  first 10 then `+N more` (a 60-option select stays one line); with
  `{ options: true }` or when expanded each option prints on its own line
  with `[selected]`.
- **Link URLs**: `[url=…]` prints for a link with no name or named only by
  an image's alt text, so such links can be told apart; with
  `{ urls: true }` every link shows it. URLs are relative when same-origin.
  Other links omit them by default because URLs are about a quarter of a
  page's snapshot and an agent acts on the ref.
- **Text** collapses whitespace to single spaces (Aside doubles spaces around
  inline elements). Paragraphs print as their text lines. Text of one to
  three punctuation characters (`|`, `(`, `·`) joins the texts on both sides
  (`"10 points by | ada"`) or, next to an element, is dropped, as are such
  tokens at the edge of a text next to an element (Hacker News' separators
  were 17% of its snapshot).
- **Tables**: a row whose cells all hold plain text prints as one line with
  cells joined by `|` (`- row: "Ada | 9"`), and as `- row [header]: "Name |
  Score"` when every cell is a column header; any other row prints its cells
  as children, unnamed, where header cells keep the role `columnheader`. A table used for layout flattens into its content: one
  that declares no header cell, caption, `thead`, `tfoot`, `colgroup`,
  `summary`, `border` or table role, and that holds or sits in another table,
  has one row or one column, or has rows of different lengths (Hacker News).
  Aside drops all table structure.
- **Structure with nothing in it** is not printed: an unnamed, ref-less
  container with no children (an empty `list`). An unnamed list item or cell
  around a single element prints as that element, and an unnamed landmark
  directly around one of its own kind prints once.
- **Open dialogs and file choosers** print first, under the header, so an
  agent sees why the page is blocked. A file chooser line carries its input's
  ref. A JavaScript dialog line has none, because no element owns the dialog
  and a ref must work as a selector; it names `page.dialog()` instead, and the
  tree is replaced by a note while the dialog blocks the page.
- **Options**: `interactive` (interactive nodes, their named ancestors, and
  the page outline: headings and landmarks, which carry no new refs),
  `viewport` (only elements that intersect the viewport, with their
  ancestors, and a closing note `# N interactive elements outside the
  viewport are not shown`; refs are the same as in a full snapshot),
  `showHidden`, `maxChars` (truncates with a note), `options`, `urls`.
- **Size**: on the real-site corpus (tests/browser-parity) the snapshot holds
  every interactive element of Chrome's Playwright AI snapshot that no
  overflow ancestor clips out, and no text Chrome does not render. It keeps
  visible text Aside drops (card descriptions, heading anchors, table cells),
  so on pages with much of that it can be slightly larger than Aside's; the
  corpus README lists the per-page sizes.
- **Printing** a snapshot prints its diff against the previous snapshot of the
  same tab when the diff is shorter than the tree; for a tree over 2,048
  characters the diff must be at least 30% shorter, because a diff that is
  most of a large page reads worse than the page. `.tree` and `.diff` are
  always available.
- **Diff** lines are `+ ` added, `- ` removed and `~ ` changed, each change
  preceded by its unchanged ancestor lines (two-space prefix) as context so
  it is locatable. A changed line (matched by ref, else role and name)
  prints once, as its new version. ChatGPT omits ancestors; Aside prints
  bare `@@` hunks.

## Sessions and tabs

- Named sessions (`--session NAME`) keep variables and tabs until
  `cmux browser repl reset NAME` or 30 minutes idle. A run without `--session`
  is one-shot: its tabs close at the end unless `page.keep()` was called.
- A session binds to the caller's cmux workspace (from `CMUX_WORKSPACE_ID`), or
  to the focused workspace when the caller is outside cmux or the id is unknown
  to this instance.
- `tabs.open()` never steals focus. `page.bringToFront()` shows a tab.
- A driven tab keeps rendering like a foreground page. Shown in a pane of the
  key window, it stays live in the pane. Hidden, or shown in a window that is
  not key, it renders in a window outside every screen that reports itself as
  key (WebKit treats only a page in a key window as focused, for focus, blur,
  typing and hover); a shown tab's pane then holds a mirror of the page,
  refreshed after every driver call. The live view returns to the pane as
  soon as the pane is shown, its window becomes key, or the session ends,
  resets or expires.

## Excluded from the references

- **Site integrations** (Aside `gmail`, `slack`, `notion`, `imessage`, …),
  password managers, CAPTCHA solving, `aside exec`: outside browser operation.
- **Raw CDP** (ChatGPT `tab.capabilities.cdp`) and request interception: WebKit
  has no CDP. ChatGPT disables both by default in its own backends. A Chromium
  engine would add them as `page.cdp`.
- **ChatGPT `tabs.content`, `content.exportGsuite`, `exportYouTubeTranscript`,
  `pageAssets`, `webmcp`, `browser.history`, `browser.user.claimTab`**: product
  features outside the REPL's browser-operation scope; listed per member in
  capabilities.json.

## Architecture

```
agent -> cmux browser repl -> control socket -> REPL session (JavaScriptCore)
                                                  runtime-core.js, api.js
                                                  | driver protocol
                                                  v
                                   WebKit driver (Swift, WKWebView)
```

- Runtime: `Resources/browser-repl/` (`runtime-core.js` Playwright model,
  `api.js` globals, `snapshot.js` host-side stitching and diff, `page-agent.js`
  per-frame script in an isolated content world, `repl-host.js`). Locators use
  Playwright's injected script (Apache-2.0).
- Driver contract: [driver-protocol.md](driver-protocol.md).
- Reference studies kept for the record: [aside-snapshot-spec.md](aside-snapshot-spec.md),
  [chatgpt-ax-spec.md](chatgpt-ax-spec.md).

## Tests

[tests/browser-parity](../../tests/browser-parity/README.md): one scenario set in
this API, run against the cmux app, a Playwright WebKit development driver, and
a real-Playwright oracle (headless Chrome) for behavior values.
