# cmux browser REPL

`cmux browser repl` is a persistent JavaScript REPL that drives cmux browser
panes for agents. It has one API. It covers every browser-operation capability
of Aside's `aside repl` and ChatGPT for Chrome (the Codex `browser`/`chrome`
plugins), and improves on both where they differ. It does not copy either
surface: there are no dialects, no `agent` object, and no numbered AX text.

Parity is enforced by
[capabilities.json](../../tests/browser-parity/capabilities.json) and the
differential cases in
[tests/browser-parity/diff](../../tests/browser-parity/diff): every reference
member maps to a cmux equivalent and to cases that run the same task in cmux,
Aside and ChatGPT for Chrome, and no case may leave cmux worse than a
reference ([parity-report.md](parity-report.md)).

## Principles

1. **Playwright is the action model.** Models know Playwright; both references
   converge on it (Aside's `page` is Playwright-shaped, ChatGPT exposes
   `tab.playwright`). `page`, `locator`, `keyboard`, `mouse`, events and waits
   follow Playwright semantics exactly where Playwright defines them.
2. **One observation format.** A compact accessibility snapshot with refs. Refs
   work anywhere a selector works. There is no second format to choose.
3. **Real input only.** Every click, hover, drag, wheel and key is a native
   event (`isTrusted === true`). There is no synthetic-event fallback.
4. **Nothing silent.** In a tab the session opened, dialogs and file choosers
   without a handler stay open and show in the snapshot until the agent
   answers them (a user's tab keeps its own UI, see
   [Sessions and tabs](#sessions-and-tabs)). Ambiguous input failures are
   reported and never replayed.
5. **Less to remember.** Top-level `const`/`let` persist across calls, the last
   expression's value prints automatically, and printing a snapshot picks the
   diff or the full tree by size.

## Globals

| Global | Purpose |
| --- | --- |
| `page` | The current tab, a Playwright `Page`. |
| `tabs` | `list()`, `open(url, { background })`, `current()`, `use(tabOrId)`, `get(id)`. `list()` returns `{ id, title, url, active, current }` without attaching; `list({ all: true })` adds tabs in the user's other workspaces and windows, which `use(id)` attaches (ChatGPT's `claimTab`). `open`, `current`, `use` and `get` return a `Page` with a stable `page.id`. `content({ urls, format })` loads URLs in background tabs and extracts text, Markdown, HTML or a snapshot. `history({ query, from, to, limit })` searches cmux browser history. |
| `snapshot(target?, options?)` | Accessibility snapshot of `page`, a locator, or a ref string. See [Snapshot](#snapshot). |
| `screenshot(target?, options?)` | PNG of the viewport, full page, locator or ref. `{ annotate: true }` draws each ref's box and label. Returns an `Image` that displays when printed. |
| `fetch` | Standard `fetch` that sends the current tab's cookies (`credentials`: `"include"` by default, `"same-origin"`, `"omit"`). The domain policy is checked on every redirect hop; a body over 64 MiB fails (download it in a tab instead). |
| `fs`, `path`, `os`, `Buffer` | Node-compatible subsets. Files are limited to the session directory (the caller's cwd; `/` and the home directory are refused, and `repl mcp` started there uses a temporary directory) and the system temp directory; a symbolic link is never followed out of them, and `rm`, `rename` and `lstat` act on the link itself as in Node. `import("node:fs")` and friends return the same modules. |
| `sleep(ms)`, `display(value)` | Wait; show a value or image to the agent. |
| `sites` | Site tools that run through the signed-in browser session: Google Docs/Sheets/Slides/Drive, Gmail, Calendar, Search, YouTube, Slack, Notion, LinkedIn, X, GitHub, Linear, Jira, page assets, WebMCP and a secure sign-in sheet. Writes to other people are drafts until confirmed. See [site-tools.md](site-tools.md). |
| `session` | `name(label)` labels this session's tabs in the UI; `keep(page)` keeps a tab open after a one-shot run ends; `id`; `guide()` returns the agent guide (`Resources/browser-repl/guide.md`). `configure({ userAgent, extraHTTPHeaders, permissions, proxy })` sets Playwright browser-context options for the tabs the session drives. The domain policy (`allowedDomains`, `prohibitedDomains`, `blockIPAddresses`, `blockedNavigations`, which also blocks subresources), `storageState` (the current tab's site by default, `{ all: true }` for the whole profile)/`setStorageState`, `downloads()` and `record()`: see [browser-use-parity.md](browser-use-parity.md). |
| `secret(name)`, `secrets` | Named secrets scoped to domains, typed with `locator.fill(secret(name))` and masked as `<secret:name>` in every output, read and file. Values stay in the native session, never in the REPL's JavaScript ([browser-use-parity.md](browser-use-parity.md#secrets)). |
| `search(query, options)` | `[{ title, url, snippet }]` from DuckDuckGo, Bing or Google. |
| `tools` | `register(name, fn, { description, params, domains })`, `list()`, `call(name, args)`: the session's own callable tools. |

### Page additions beyond Playwright

| Member | Purpose | Replaces |
| --- | --- | --- |
| `page.locator("e5")`, `page.ref("e5")` | Resolve a snapshot ref. Stale refs throw `ref e5 is stale: the element was removed; take a new snapshot`. | Aside refs, ChatGPT `ax.*(index)`, `dom_cua` node ids |
| `page.dialog()` | The open JavaScript dialog or `null`: `{ type, message, defaultValue, accept(text?), dismiss() }`. | ChatGPT `getJsDialog()` |
| `page.fileChooser()` | The open file chooser or `null`: `{ multiple, setFiles(files), cancel() }`. | ChatGPT chooser flow |
| `page.consoleMessages({ level, filter, limit })`, `page.errors()` | Console history and uncaught errors since the tab opened. | ChatGPT `dev.logs()` |
| `page.clipboard` | `readText()`, `writeText(text)`, `read()`, `write(items)` on a per-tab clipboard. Meta+V fires a trusted `paste` event whose `clipboardData` holds it; Meta+C and Meta+X fill it from a trusted `copy`/`cut`. The system clipboard is not touched, and other code (the terminal) keeps the system clipboard while a shortcut runs; one that WebKit does not finish within 5 s throws a timeout and still never reaches the system clipboard. | ChatGPT `clipboard` |
| `page.elementAt(x, y)` | `{ ref, role, name, box }` for the topmost element at a viewport point. | ChatGPT `elementInfo()` |
| `page.keep()` | Keep this tab open after a one-shot run. | ChatGPT `markDeliverable()` |
| `page.exportContent(options)` | Write the page as Markdown, a Google Docs/Sheets/Slides tab in an export format (`{ format }`), or a YouTube watch page's captions (`{ transcript: true }`) to a file; returns the path. | ChatGPT `content.export*` |
| `page.markdown(options)`, `page.extract(spec)`, `page.searchText(pattern)` | The page as Markdown (iframes and shadow roots included, `{ main: true }`, chunked with `{ start, maxChars }`); structured data by selectors; text matches with refs. | browser-use `extract`, `search_page`, `find_elements` |
| `page.scrollToText(text)`, `page.scroll({ pages, target })`, `page.scrollInfo(target?)`, `page.dropdownOptions(ref)`, `page.highlight(targets?)` | Scrolling by text or pages, scroll position in pages, `<select>` and ARIA options, a ref overlay on the page. | browser-use `find_text`, `scroll`, `dropdown_options`, `highlight_elements` |
| `locator.dispatchEvent("drop", { dataTransfer: { files, data } })` | Build a real `DataTransfer` in the page and dispatch a drag event with it, so drop zones receive files. | Playwright's `evaluateHandle` recipe |

Everything else uses standard Playwright: `page.mouse` replaces ChatGPT `cua`
coordinates, `page.on("popup")`, `waitForEvent("download")`, `page.pdf()`,
`page.setViewportSize()`, `frameLocator`, `getByRole`, and so on.

One Playwright call is scoped on purpose: driven tabs use the user's browser
profile, so `page.context().clearCookies(options)` clears only the cookies
of that page's site (its registrable domain, as `storageState` scopes), and
Playwright's `name`, `domain` and `path` filters (strings or RegExps) narrow
that. `{ all: true }` clears every site. On a tab with no site (`about:blank`)
it throws unless `{ all: true }` is given or the tab uses a private or proxy
store, which may be cleared whole.

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
  A link or button whose box has zero width or height is left out unless
  some content inside it has a box that `clip`/`clip-path` does not hide
  (Wikipedia's zero-width citation backlinks, whose only content is a
  screen-reader label, are left out; an icon that overflows a zero-size link
  is kept). Where a clipped link is left out, the brackets around it close up
  (`message (#1234)` reads `message`).
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
  dropped; a control with its own ref keeps its name even then (a `<summary>`
  disclosure around a link prints `button "Guides" [ref=e3]:` with the link
  inside). A lone text a name already contains (an `aria-label` that extends
  the visible text) is not repeated. These comparisons ignore case,
  whitespace and zero-width characters. Other printed names are cut at 100
  characters with `…`; refs still resolve.
- **Typed values** print as they are, so an agent can check its own input
  (`textbox "Email": "me@x.com"`); only password fields are masked
  (`"********"`). This is deliberate: ChatGPT for Chrome redacts any field
  that looks like a credential, including what the agent typed, and so hides
  the result of the agent's own action. The cost is that text a page
  pre-fills in such a field is visible to the agent.
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
- **Link URLs**: a link to another site (its host differs after `www.` and
  subdomains of the same two-label base) prints where it goes, host and
  first path segment: `[url=github.com/ninjahawk]`, `[url=example.org/docs/…]`,
  at most 48 characters. A link with no name or named only by an image's alt
  text also prints an on-site `[url=…]` (relative, at most 100 characters),
  so such links can be told apart; with
  `{ urls: true }` every link shows its full URL, relative when same-origin.
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
  the page outline: headings and landmarks, which carry no new refs; its
  diff also carries text that an action added or changed, such as
  "Submitted me@x.com", with the lines that locate it),
  `viewport` (only elements that intersect the viewport, with their
  ancestors, and a closing note `# N interactive elements outside the
  viewport are not shown`; refs are the same as in a full snapshot),
  `showHidden`, `maxChars` (the print budget, see [Large output](#large-output)),
  `options`, `urls`.
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
  always available and always complete; what prints is at most `maxChars`
  (see [Large output](#large-output)).
- **Diff** lines are `+ ` added, `- ` removed and `~ ` changed, each change
  preceded by its unchanged ancestor lines (two-space prefix) as context so
  it is locatable. A changed line (matched by ref, else role and name)
  prints once, as its new version. ChatGPT omits ancestors; Aside prints
  bare `@@` hunks. The diff anchors on lines that occur once in both trees
  (refs make most element lines unique) and runs a bounded Myers diff
  between anchors, so it is near-linear: a 100,000-line tree with one change
  diffs in about 50 ms and a full rewrite of 50,000 lines in about 150 ms,
  where a plain Myers diff ran out of memory.

## Large output

What an agent reads costs context, and agent harnesses cut what a tool
prints: Claude Code keeps about 30,000 characters inline (then a
2,000-character preview and a file), Codex keeps 10,000 tokens (head and
tail, the middle dropped), ChatGPT for Chrome stops its DOM view at 20,000
characters and a node's children at 500 without saying where. Aside prints
everything (a 5,000-item page is a 400 KB answer). cmux decides what is
kept, keeps what an agent needs to act, and says at each cut how to get the
rest. Measurements: [performance.md](performance.md).

- **The value is complete, the print is budgeted.** `.tree` and `.diff`
  always hold everything, so code can search them for free. Printing a
  snapshot (the REPL's auto-print, `String(s)`, `console.log(s)`) shows at
  most `maxChars` characters, 20,000 by default (about 6,000 tokens; five
  of the nine frozen corpus pages, median 16,616 characters, print whole).
  `snapshot({ maxChars: Infinity })` prints everything.
- **Condensing keeps, in order:** controls on screen and the focused element
  with their ancestors; the outline (landmarks, frames, then headings level
  by level while the outline fits in half the budget); then the page in
  document order. A run of six or more similar siblings, also a repeating
  group such as a card flattened into heading, text, link and button, keeps
  its first three in that pass and the rest only if room is left. Prose
  (text between links) is never treated as a run. A small subtree (a list
  item, a card) prints whole or not at all; a line longer than a quarter of
  the budget prints its start and its length.
- **Every cut is a line** where the content was: `- … 4,997 more listitem
  (4,997 refs): snapshot("e1")`, `- … 12 more repeats of heading, link,
  button`, `- … 444 more lines (172 refs): snapshot("e384")`, naming the
  nearest ancestor with a ref to scope to. The last line says how much
  printed and how to get more:
  `# condensed to 19,657 of 62,822 characters (368 of 626 refs not shown): …`.
  Refs in the cut part are real and work in locators.
- **A diff too large for the budget** prints the condensed tree with a note
  that `.diff` has the changes.
- **Per call**, the REPL prints at most 25,000 characters
  (`cmux browser repl --max-output <chars>`, `0` for no limit), under both
  harness limits above so the REPL, not the harness, picks what is cut.
  Past the cap, the call's whole output goes to
  `<tmp>/cmux-browser-repl/<session>/output-N.txt`: the first 80% prints,
  then `# output continues in <path>`, and at the end of the call its last
  lines and `# output truncated: X of Y characters shown; full output:
  <path>`. The file is written as output arrives, so a call that times out
  still has it.

## Sessions and tabs

- Named sessions (`--session NAME`) keep variables and tabs until
  `cmux browser repl reset NAME` or 30 minutes idle. A run without `--session`
  is one-shot: its tabs close at the end unless `page.keep()` was called.
- `cmux browser repl mcp [--session NAME]` serves a session as an MCP
  server on stdio, with the tools `eval`, `snapshot`, `screenshot`, `tabs`
  and `reset`, for agents that load tools over MCP. Without `--session` each
  server process gets its own session (`mcp-<pid>-<random>`), reset when
  the server exits, so two MCP clients never share variables or tabs; give
  them the same `--session` to share one.
- A session binds to the caller's cmux workspace (from `CMUX_WORKSPACE_ID`), or
  to the focused workspace when the caller is outside cmux or the id is unknown
  to this instance.
- `tabs.open()` never steals focus. `page.bringToFront()` shows a tab.
- Session behaviors apply only to tabs the session created: tabs from
  `tabs.open()` (and `tabs.content`), and popups of those tabs, while the
  session lasts. In them dialogs and file choosers wait for the agent,
  downloads stay in the temporary directory for `download.path()`, camera,
  microphone, geolocation and notification requests are answered from
  `session.configure({ permissions })`, and plain-http pages load without
  cmux's prompt. Any other tab is the user's, also one a session drives with
  `tabs.use()` or one a finished run kept with `page.keep()`: it keeps cmux's
  own dialogs, file panel, download location, permission prompts and
  insecure-HTTP prompt. An event the agent registered a handler for on that
  page (`page.on("dialog")`, `page.on("filechooser")`,
  `page.waitForEvent("download")` and the like) goes to the session instead,
  only while the handler is registered. The runtime reports these handlers
  to the driver with `tab.handleEvents`.
- A driven tab keeps rendering like a foreground page. Shown in a pane of the
  key window, it stays live in the pane. Hidden, or shown in a window that is
  not key, it renders in a window outside every screen that reports itself as
  key (WebKit treats only a page in a key window as focused, for focus, blur,
  typing and hover); a shown tab's pane then holds a mirror of the page,
  refreshed after every driver call. The live view returns to the pane as
  soon as the pane is shown, its window becomes key, or the session ends,
  resets or expires.

## Excluded from the references

- **Site integrations** are `sites` ([site-tools.md](site-tools.md)); its
  "Decisions for the user" lists what is left out (password managers,
  CAPTCHA solving, `imessage`, image generation). `aside exec` is outside
  browser operation.
- **Raw CDP** (ChatGPT `browser.capabilities`' `cdp`) and request interception:
  WebKit has no DevTools protocol. ChatGPT for Chrome withholds both by
  default too (`browser.capabilities` in the parity cases records that). A
  Chromium engine would add them as `page.cdp`.

Everything else ChatGPT for Chrome documents has a cmux equivalent, including
`browser.history` (`tabs.history`), `user.claimTab` (`tabs.list({ all: true })`
and `tabs.use`), `tabs.content` and the content exports
(`page.exportContent`). [parity-report.md](parity-report.md) lists every
member's differential cases and verdicts; [edge-cases.md](edge-cases.md)
the edge cases.

## Architecture

```
agent -> cmux browser repl -> control socket -> REPL session (JavaScriptCore)
                                                  runtime-core.js, api.js
                                                  | driver protocol
                                                  v
                                   WebKit driver (Swift, WKWebView)
```

- Guards: agent code runs in the same JavaScriptCore context as the
  runtime and can replace any runtime object, so nothing in that context
  is a guard. The domain policy (and its lock), secret values, redaction
  and capture masking live in the native session (`BrowserReplBoundary`
  in `Packages/macOS/CmuxBrowser`) and the driver, which every driver call,
  fetch, event, file write and output line passes through. The runtime
  deletes the `__cmuxNative` global before any cell runs.
- Runtime: `Resources/browser-repl/` (`runtime-core.js` Playwright model,
  `api.js` globals, `snapshot.js` host-side stitching and diff, `page-agent.js`
  per-frame script in an isolated content world, `repl-host.js`). Locators use
  Playwright's injected script (Apache-2.0).
- Driver contract: [driver-protocol.md](driver-protocol.md).
- The format studies and the representation comparison live in the private repository `manaflow-ai/cmux-browser-parity-private`.

## Tests

[tests/browser-parity](../../tests/browser-parity/README.md): one scenario set in
this API, run against the cmux app, a Playwright WebKit development driver, and
a real-Playwright oracle (headless Chrome) for behavior values.
