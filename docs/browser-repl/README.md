# cmux browser REPL

`cmux browser repl` is a persistent JavaScript REPL that drives cmux browser
panes for agents. It has one API. It covers every browser-operation capability
of two reference browser REPLs (reference A and reference B), and improves
on both where they differ. It does not copy either
surface: there are no dialects, no `agent` object, and no numbered AX text.

Parity is enforced by
[capabilities.json](../../tests/browser-parity/capabilities.json) and the
differential cases in
[tests/browser-parity/diff](../../tests/browser-parity/diff): every reference
member maps to a cmux equivalent and to cases that run the same task in cmux,
reference A and reference B, and no case may leave cmux worse than a
reference ([parity-report.md](parity-report.md)).

## Principles

1. **Playwright is the action model.** Models know Playwright; both references
   converge on it (reference A's `page` is Playwright-shaped, reference B exposes
   `tab.playwright`). `page`, `locator`, `keyboard`, `mouse`, events and waits
   follow Playwright semantics exactly where Playwright defines them.
2. **One observation format.** A compact accessibility snapshot with refs. Refs
   work anywhere a selector works. There is no second format to choose.
3. **Real input only.** Every click, hover, drag, wheel and key is a native
   event (`isTrusted === true`). There is no synthetic-event fallback.
4. **Nothing silent.** In a tab the session opened, dialogs and file choosers
   without a handler stay open and show in the snapshot until the agent
   answers them (a user's tab keeps its own UI, see
   [Sessions and tabs](#sessions-and-tabs)). The one exception, a dialog
   that opens during Meta+C, Meta+X or Meta+V, is dismissed so it cannot
   hold the clipboard shortcut, and the next snapshot says so. Ambiguous
   input failures are reported and never replayed.
5. **Less to remember.** Top-level `const`/`let` persist across calls, the last
   expression's value prints automatically, and printing a snapshot picks the
   diff or the full tree by size.

## Globals

| Global | Purpose |
| --- | --- |
| `page` | The current tab, a Playwright `Page`. |
| `tabs` | `list()`, `open(url, { background })`, `current()`, `use(tabOrId)`, `get(id)`. `list()` returns `{ id, title, url, active, current, state }` without attaching or waking a tab (`state`: see [Hibernated and crashed tabs](#hibernated-and-crashed-tabs)); `list({ all: true })` adds the session's own tabs that moved to another workspace (a user's tab of another workspace is not listed, and neither is its profile's data store); `use(id)` attaches a tab of the session's own workspace, except one another running session opened (listed with `ownedBy`; see [Sessions and tabs](#sessions-and-tabs)). A tab of another workspace is refused (`denied`): it needs an attach a person grants, which cmux does not offer yet. `tabs.close`/`page.close()` closes only tabs the session opened and user tabs it attached. `open`, `current`, `use` and `get` return a `Page` with a stable `page.id`. `content({ urls, format })` loads URLs in background tabs and extracts text, Markdown, HTML or a snapshot. `history({ query, from, to, limit })` searches cmux browser history. |
| `snapshot(target?, options?)` | Accessibility snapshot of `page`, a locator, or a ref string. See [Snapshot](#snapshot). |
| `screenshot(target?, options?)` | PNG of the viewport, full page, locator or ref. `{ annotate: true }` draws each ref's box and label. Returns an `Image` that displays when printed. |
| `fetch` | Standard `fetch` that sends the current tab's cookies (`credentials`: `"include"` by default, `"same-origin"`, `"omit"`). The domain policy is checked on every redirect hop; a request body over 64 MiB fails, a response body over 64 MiB fails (download it in a tab instead), as does one past the 128 MiB a session's fetches may hold at once; a fetch fails after 10 minutes; past 256 queued fetches a new one fails at once. |
| `fs`, `path`, `os`, `Buffer` | Node-compatible subsets. Files are limited to the session directory (the caller's cwd; `/`, the home directory and a directory that is, holds or is inside the sessions' private storage or the browser's downloads under the temporary directory are refused, and `repl mcp` started in `/`, the home or the temporary directory uses a temporary directory of its own) and the session's own temporary directory (`os.tmpdir()`, mode 0700, never shared with another session); a symbolic link is never followed out of them (also when another process changes the tree meanwhile), and `rm`, `rename` and `lstat` act on the link itself as in Node. A FIFO, socket or device fails with `EINVAL` instead of blocking, and `readFile` reads at most 64 MiB. While secrets are masked, `copyFile` writes its copy masked like `writeFile` and copies at most 64 MiB. One `writeFile`, `appendFile` or `copyFile` writes at most 256 MiB, and a session at most 2 GiB and 100,000 file changes (files created, directories made, entries renamed or removed, each entry of a recursive `rm` too, which stops at the limit and leaves the rest) in all, file chooser answers' files included (reset it to write more); a long write, copy, directory listing or recursive `rm` stops when its cell times out. `import("node:fs")` and friends return the same modules. |
| `sleep(ms)`, `display(value)` | Wait; show a value or image to the agent. |
| `sites` | Site tools that run through the signed-in browser session: Google Docs/Sheets/Slides/Drive, Gmail, Calendar, Search, YouTube, Slack, Notion, LinkedIn, X, GitHub, Linear, Jira, page assets, WebMCP and a secure sign-in sheet. Writes to other people are drafts until confirmed. See [site-tools.md](site-tools.md). |
| `session` | `name(label)` labels this session's tabs in the UI; `keep(page)` keeps a tab open after a one-shot run ends; `id`; `guide()` returns the agent guide (`Resources/browser-repl/guide.md`). `configure({ userAgent, extraHTTPHeaders, permissions, proxy })` sets Playwright browser-context options for the tabs the session created. The domain policy (`allowedDomains`, `prohibitedDomains`, `blockIPAddresses`, `blockedNavigations`, which also blocks subresources), `storageState` (the current tab's site by default, `{ all: true }` for the whole profile)/`setStorageState`, `downloads()` and `record()`: see [reference-c-parity.md](reference-c-parity.md). |
| `secret(name)`, `secrets` | Named secrets scoped to domains, typed with `locator.fill(secret(name))` and masked as `<secret:name>` in every output, read and file. Values stay in the native session, never in the REPL's JavaScript ([reference-c-parity.md](reference-c-parity.md#secrets)). |
| `search(query, options)` | `[{ title, url, snippet }]` from DuckDuckGo, Bing or Google. |
| `tools` | `register(name, fn, { description, params, domains })`, `list()`, `call(name, args)`: the session's own callable tools. |

### Page additions beyond Playwright

| Member | Purpose | Replaces |
| --- | --- | --- |
| `page.locator("e5")`, `page.ref("e5")` | Resolve a snapshot ref. Stale refs throw `ref e5 is stale: the element was removed; take a new snapshot`. | Reference A refs, reference B `ax.*(index)`, `dom_cua` node ids |
| `page.dialog()` | The open JavaScript dialog or `null`: `{ type, message, defaultValue, accept(text?), dismiss() }`. | Reference B `getJsDialog()` |
| `page.fileChooser()` | The open file chooser or `null`: `{ multiple, setFiles(files), cancel() }`. | Reference B chooser flow |
| `page.consoleMessages({ level, filter, limit })`, `page.errors()` | Console history and uncaught errors since the tab opened. | Reference B `dev.logs()` |
| `page.clipboard` | `readText()`, `writeText(text)`, `read()`, `write(items)` on a per-tab virtual clipboard that never touches a pasteboard. Meta+V fires a `paste` event whose `clipboardData` holds it and inserts its text unless the page cancels the event; Meta+C and Meta+X fill it from a `copy`/`cut` event with whatever the page's handler sets, or the selection. The events are dispatched in the focused frame (`isTrusted` is false, so an editor that accepts only a trusted paste ignores it). A JavaScript dialog the page opens meanwhile is dismissed and reported in the next snapshot. The system clipboard, which other code (the terminal) keeps, is never read or written. The clipboard is the creating session's alone, while it lives: `page.clipboard` and the shortcuts run only in tabs the session opened and throw `unsupported` in a user's tab (also one a finished run kept), so two sessions driving one tab never pass bytes through it; `cmux browser press` Meta+C, Meta+X and Meta+V do nothing in such a tab. A shortcut with the focus in a frame the domain policy blocks throws `blocked`, and a paste reaches only the frame document the policy check approved. In a tab a session created, the page's own scripts write here too, never to the system clipboard, even after an agent's click gave them a user gesture: `navigator.clipboard.write` and `writeText` (a `ClipboardItem` whose data settles later included) and `document.execCommand("copy")` or `"cut"`; their reads reject with `NotAllowedError` and `execCommand("paste")` returns false ([Guards](driver-protocol.md#guards) says how, and names the one case WebKit leaves open: a frame's initial empty document). In a user's tab the page keeps the browser's clipboard, also with the gesture an agent's input gives it. | Reference B `clipboard` |
| `page.elementAt(x, y)` | `{ ref, role, name, box }` for the topmost element at a viewport point. | Reference B `elementInfo()` |
| `page.keep()` | Keep this tab open after a one-shot run. | Reference B `markDeliverable()` |
| `page.exportContent(options)` | Write the page as Markdown, a Google Docs/Sheets/Slides tab in an export format (`{ format }`), or a YouTube watch page's captions (`{ transcript: true }`, fetched only from a track URL that is https on `www.youtube.com`, `m.youtube.com` or `youtube.com`) to a file; returns the path. | Reference B `content.export*` |
| `page.markdown(options)`, `page.extract(spec)`, `page.searchText(pattern)` | The page as Markdown (iframes and shadow roots included, each frame's text in its `<iframe>`'s place, which page text cannot move; `{ main: true }`, chunked with `{ start, maxChars }`); structured data by selectors; text matches with refs. | Reference C `extract`, `search_page`, `find_elements` |
| `page.scrollToText(text)`, `page.scroll({ pages, target })`, `page.scrollInfo(target?)`, `page.dropdownOptions(ref)`, `page.highlight(targets?)` | Scrolling by text or pages, scroll position in pages, `<select>` and ARIA options, a ref overlay on the page. | Reference C `find_text`, `scroll`, `dropdown_options`, `highlight_elements` |
| `locator.dispatchEvent("drop", { dataTransfer: { files, data } })` | Build a real `DataTransfer` in the page and dispatch a drag event with it, so drop zones receive files. | Playwright's `evaluateHandle` recipe |

Everything else uses standard Playwright: `page.mouse` replaces reference B `cua`
coordinates, `page.on("popup")`, `waitForEvent("download")`, `page.pdf()`,
`page.setViewportSize()`, `frameLocator`, `getByRole`, and so on.

One Playwright call is scoped on purpose: driven tabs use the user's browser
profile, so `page.context().clearCookies(options)` clears only the cookies
of that page's site (its registrable domain by the Public Suffix List, as
`storageState` scopes), and Playwright's `name`, `domain` and `path` filters
(strings or RegExps) narrow that. The driver decides the site from the tab,
not from what the runtime sends. On the user's profile, `{ all: true }` and
a tab with no site (`about:blank`) throw; a private or proxy store may be
cleared whole. The domain policy covers cookies too: `cookies()` leaves out
the cookies of blocked sites, and reading, setting or clearing cookies of a
blocked URL, site or tab throws.

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

- **Header** lines (title, URL, a pending dialog or file chooser) are the
  page's text, so terminal escape sequences and C0/C1 control characters
  are removed and a line longer than 500 characters is cut with its length.
- **Refs** go on interactive elements, iframes, scrollable regions and named
  landmarks, dialogs and lists (so a region can be scoped with
  `snapshot("e1")`). A ref is bound to its DOM node for the node's life and is
  never reused in that frame, even after the frame loads a new document. A
  removed node's ref fails at once (`ref e5 is stale`); a ref never issued
  fails with `ref e9 does not exist`. A ref is also bound to the document
  that issued it: each session remembers which document of a frame gave it
  each ref, and once the frame shows another document (it navigated, also
  when another session that drives the tab numbered the new document's
  refs first), using it fails `stale` (`ref e5 is stale: the element is from
  a previous document; take a new snapshot`) and never acts on the new
  document. An element handle (`locator.elementHandle()`) likewise fails
  `stale` (`Element handle is from a previous document; take a new
  snapshot`) once its frame shows another document. Both are bound to the
  frame's document too: when the page moves the element into another
  document (`adoptNode`, or appending it into a same-origin iframe or popup),
  the ref fails `stale` and the handle fails `stale` at once, and neither
  acts on it there. Reference A renumbers a ref when its name
  changes; reference B reuses indices after removals.
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
  (`"********"`). This is deliberate: reference B redacts any field
  that looks like a credential, including what the agent typed, and so hides
  the result of the agent's own action. The cost is that text a page
  pre-fills in such a field is visible to the agent.
- **States** print as `[checked]`, `[checked=mixed]`, `[disabled]`,
  `[expanded]`, `[expanded=false]`, `[pressed]`, `[selected]`, `[focused]`,
  `[required]`, `[invalid]`, `[readonly]`, `[level=N]`, `[scrollable]` (why a
  plain region has a ref) and, with `showHidden`, `[hidden]`. Reference A drops
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
- **Text** collapses whitespace to single spaces (reference A doubles spaces around
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
  The shape is judged from the table's first 50 rows (and 50 cells of each)
  and its first 1,000 descendant elements, so a huge table costs no more
  than a small one to classify.
  Reference A drops all table structure.
- **Structure with nothing in it** is not printed: an unnamed, ref-less
  container with no children (an empty `list`). An unnamed list item or cell
  around a single element prints as that element, and an unnamed landmark
  directly around one of its own kind prints once.
- **Open dialogs and file choosers** print first, under the header, so an
  agent sees why the page is blocked. A file chooser line carries its input's
  ref. A JavaScript dialog line has none, because no element owns the dialog
  and a ref must work as a selector; it names `page.dialog()` instead, and the
  tree is replaced by a note while the dialog blocks the page. A dialog cmux
  dismissed during Meta+C, Meta+X or Meta+V prints once, as
  `dialog dismissed: alert "…" (it opened during a copy)`.
- **Options**: `interactive` (interactive nodes, their named ancestors, and
  the page outline: headings and landmarks, which carry no new refs; its
  diff also carries text that an action added or changed, such as
  "Submitted me@x.com", with the lines that locate it),
  `viewport` (only elements that intersect the viewport, with their
  ancestors, and a closing note `# N interactive elements outside the
  viewport are not shown`; the count reads at most as many elements as the
  snapshot's node budget and then reads `# at least N …`; refs are the same
  as in a full snapshot),
  `showHidden`, `maxChars` (the print budget, see [Large output](#large-output)),
  `options`, `urls`.
- **Size**: on the real-site corpus (tests/browser-parity) the snapshot holds
  every interactive element of Chrome's Playwright AI snapshot that no
  overflow ancestor clips out, and no text Chrome does not render. It keeps
  visible text reference A drops (card descriptions, heading anchors, table cells),
  so on pages with much of that it can be slightly larger than reference A's; the
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
  prints once, as its new version. Only the `[ref=…]` cmux puts after an
  element's role and name counts as its ref: page text that reads
  `[ref=e1]` (a text line, a name, a value) never pairs with an element. Reference B omits ancestors; reference A prints
  bare `@@` hunks. The diff anchors on lines that occur once in both trees
  (refs make most element lines unique) and runs a bounded Myers diff
  between anchors, so it is near-linear: a 100,000-line tree with one change
  diffs in about 50 ms and a full rewrite of 50,000 lines in about 150 ms,
  where a plain Myers diff ran out of memory.

## Large output

What an agent reads costs context, and agent harnesses cut what a tool
prints: Claude Code keeps about 30,000 characters inline (then a
2,000-character preview and a file), Codex keeps 10,000 tokens (head and
tail, the middle dropped), reference B stops its DOM view at 20,000
characters and a node's children at 500 without saying where. Reference A prints
everything (a 5,000-item page is a 400 KB answer). cmux decides what is
kept, keeps what an agent needs to act, and says at each cut how to get the
rest. Measurements: [performance.md](performance.md).

- **The value is complete, the print is budgeted.** `.tree` and `.diff`
  always hold everything read, so code can search them for free. Reading
  is bounded too, because a hostile page can hold millions of nodes and the
  walk runs on the page's main thread: one snapshot reads at most 250,000
  nodes and 2,000,000 characters of text, names, values and URLs (one text
  node or field value can hold megabytes) over all its frames (frames
  inside a frame split what that frame left of its own share, reserved
  before any of them is read, so frames read at the same time never pass
  the budget; one past it prints
  `[not read: the snapshot's node budget is used up]`, or `size budget`),
  and a frame's walk stops after 8 s. The string that passes the size
  budget is cut with `…`. A name or value reads text the walk may not
  visit (an `aria-labelledby` target, a label, an editable element's
  text), and the name computation reads it whole and recursively, so
  that text is counted first (text outside the element against the node
  budget): past 2,000 nodes, 20,000 characters or 100 levels the name
  is read directly from the same sources, at most 20,000 characters.
  Labels come from an index of the read's `<label>` elements, each one
  counted; once a read's budget is spent, controls have no labels in it,
  never WebKit's getter, which scans the whole document per control. The
  walk descends at most 1,000 elements deep (script can nest elements
  deeper than the stack); a deeper element prints as `generic [ref=e9]
  [not read: nested deeper than 1000 elements; snapshot this ref to read
  it]`. A cut snapshot ends with `# the page is too large
  to read whole: the snapshot stopped after 250,000 nodes; …` (or `after
  2,000,000 characters`); snapshot a part of the page (`snapshot(ref)`, a
  locator) to read further. Printing a
  snapshot (the REPL's auto-print, `String(s)`, `console.log(s)`) shows at
  most `maxChars` characters, 20,000 by default (about 6,000 tokens; five
  of the nine frozen corpus pages, median 16,616 characters, print whole).
  `snapshot({ maxChars: Infinity })` prints everything.
- **Every other page read has the same budget.** What a helper reads
  from the page and returns crosses to the session before any output
  limit, so `page.markdown()`, `page.extract()`,
  `page.dropdownOptions()`, `page.searchText()`, `tabs.content()`,
  `page.content()`, the locator reads (`textContent`, `innerText`,
  `innerHTML`, `getAttribute`, `inputValue`, `allTextContents`,
  `allInnerTexts`) and the composer check before a site's Send or Post
  read at most 250,000 nodes and 2,000,000 characters, for 8 s, with one
  budget in the page agent (`A.budget()`), and say where they stopped.
  Every reply from the page agent's world, whatever read made it, also
  passes one reply budget (`reply` in `page-agent.js`, applied to every
  agent-world call by the runtime): past 10,000,000 characters the call
  fails with the same note, and `queryAll` makes at most 250,000 handles.
  A DOM getter (`textContent`, `innerText`, `outerHTML`) builds its whole
  string before anything can cut it, so the page agent first counts the
  nodes and the lengths it would join, within what the budget has left,
  and calls the getter only when its string fits (the getter's own
  text); past the budget it builds the string node by node and stops
  there (HTML serialized as the browser does, `innerText` approximated:
  no hidden, script or style content, a line break around blocks). A
  locator read past it returns the cut value (ending with `…`) and prints
  `# locator.textContent: the page is too large to read whole: it stopped
  after …`. `page.searchText` scans at most the budget's text (matches
  after it are not counted), returns at most 1,000 characters of context
  on each side and 1,000 of each match, and stops returning matches when
  they reach the budget's characters. Markdown ends with
  `<!-- the page is too large to read whole: Markdown stopped after
  2,000,000 characters; … -->` (or `nodes`, `8 s`, and `100 frames`:
  it reads at most 100 iframes, one after another, each with what the
  ones before it left). `extract` and `dropdownOptions` return what they
  read and print `# page.extract: the page is too large to read whole: it
  stopped after …`; `extract` keeps element handles only for the
  matches it returns. `tabs.content` reads 2,000,000 characters per call
  over all its URLs (each batch of four splits what is left); a cut row
  has `truncated` with the note, and a URL after the budget is used up is
  not read. Composer text is compared whole, so a composer past the
  budget fails the send (`The composer holds more than 2,000,000
  characters`) and nothing crosses.
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
  (`cmux browser repl --max-output <chars>`, `0` for no limit up to
  4,000,000 characters, past which the call spills as below), under both
  harness limits above so the REPL, not the harness, picks what is cut.
  Past the cap, the call's whole output goes to
  `output-N.txt` in the session's own `os.tmpdir()`
  (`<tmp>/cmux-browser-repl/<session>-<random>-tmp`, mode 0700, where its
  images, exports and recordings go too; kept after the session ends,
  removed only when empty; the session holds it open from when it made it,
  so a link another process puts at its path redirects nothing, and the
  printed path is where the directory is then): the first 80% prints,
  then `# output continues in <path>`, and at the end of the call its last
  lines and `# output truncated: X of Y characters shown; full output:
  <path>`. The file is written as output arrives, so a call that times out
  still has it. One print (a `console.log` call, a printed value) keeps
  at most 16,000,000 characters, in the output and the file alike: a
  longer one is cut before it is escaped or written, and ends with `#
  this print was cut after 16,000,000 characters (N were given)`.
- **Control characters** in printed text (page titles, text, option
  labels, URLs and error messages can hold terminal escape sequences)
  print visibly, whatever printed them (`console.log`, the auto-printed
  value, a snapshot, a page tool, an error): the session escapes them
  before output leaves it, so `--json`, `mcp` and the output file get the
  same text. Newline and tab stay, a CRLF is a newline, and every other C0
  control, DEL and C1 control prints as its JSON escape (`\r`, `\b`, `\f`,
  else `\u001b`). The terminal client also shows any control that reaches
  it another way as its control picture (ESC as `␛`, DEL as `␡`) or, for
  C1, as `\u{9B}`.

## Sessions and tabs

- Named sessions (`--session NAME`) keep variables and tabs until
  `cmux browser repl reset NAME` or 30 minutes idle. A run without `--session`
  is one-shot: its tabs close at the end unless `page.keep()` was called.
  A session's tabs close when it ends wherever they are, also one the user
  moved to another workspace or window; only `page.keep()` keeps one.
- `cmux browser repl mcp [--session NAME]` serves a session as an MCP
  server on stdio, with the tools `eval`, `snapshot`, `screenshot`, `tabs`
  and `reset`, for agents that load tools over MCP. Without `--session` each
  server process gets its own session (`mcp-<pid>-<random>`), reset when
  the server exits, so two MCP clients never share variables or tabs; give
  them the same `--session` to share one.
- A cell times out after 120 s by default; `--timeout <ms>` (the socket's
  `timeout_ms`) asks for at most 600000 (10 minutes), and a longer one is
  refused before the cell runs, since a running cell holds the session.
- At most 4 sessions drive one tab at once. Each session's page agent,
  refs and handles live in a content world of its own in every tab it
  drives, so code one session runs in its agent world (patched built-ins,
  DOM prototypes, the agent object) never changes another session's refs,
  hit tests or clicks; the driver's own checks run in worlds no session's
  code reaches ([Agent world](driver-protocol.md#agent-world)). Each world
  runs its own agent in every frame the tab loads, so a fifth session's call
  on the tab fails with `limit`, naming the limit, until one of the four
  ends.
- A session runs one cell at a time; cells sent meanwhile (callers that
  share a named session) wait in order. At most 64 wait, holding at most
  64 MiB of source together; one more fails at once with an error that
  says so.
- A session made without `--session` (a one-shot run, the interactive
  REPL's `cli-<pid>-<random>`, `mcp`'s) is its client's alone: the client
  sends a random owner token with every call, and without that token no
  other client sees it in `cmux browser repl list`, attaches to it or
  resets it, also when it knows the name or the client was killed before
  its session ended (it then idles out after 30 minutes). Named sessions
  are shared by name: an owner token is taken only with a client-made
  name (`cli-`, `mcp-`, `oneshot-`), and one sent with any other name is
  refused, so no client can hide a shared name from the others. An owner token is at most 128 bytes and a working
  directory at most 1024 bytes (`PATH_MAX`); a longer one is refused
  before a session is made.
- A session binds to the caller's cmux workspace (from `CMUX_WORKSPACE_ID`), or
  to the focused workspace when the caller is outside cmux or the id is unknown
  to this instance. A named session belongs to that workspace: the same
  `--session` name in another workspace is another session, with its own
  variables, secrets, directory and tabs. `cmux browser repl list` and
  `reset NAME` act on the caller's workspace's sessions; `--all-workspaces`
  lists or resets every workspace's. The interactive REPL and `mcp` keep
  the workspace their first call bound, so a change of focus outside cmux
  does not switch sessions; separate calls from outside cmux follow the
  focused workspace (pass `--workspace` to pin one).
- A session name is 1 to 64 characters of letters, digits, `.`, `_` and
  `-`. One cmux instance keeps at most 32 sessions open (named, one-shot and
  `mcp` ones together; each holds a JavaScript thread, timers and
  directories); one more is refused with an error that says so, and no
  open session is closed to make room.
- A session never moves the user's focus, so agents can work in the
  background: `tabs.open()`, navigation, input, dialogs, file choosers,
  downloads, popups, captures, the clipboard, `tabs.use()`, `page.keep()`,
  waking a hibernated tab and ending or resetting the session leave the
  user's key window, window order, Space, selected workspace, pane, tab in
  a pane, sidebar selection and first responder (terminal, omnibar) as they
  were, also when the session's workspace is the one the user works in.
  A new tab is added behind the pane's selected tab. Two things show
  something: `page.bringToFront()` selects the tab in its pane, and
  `sites.browserAuth.request` puts a sign-in sheet on the window the user
  works in (it needs the user to type), naming the site and the tab and
  workspace that ask; neither changes the selected workspace. Tab or
  Shift+Tab past a page's last or first control keeps the focus in the
  page (it wraps, as in a headless browser) instead of moving AppKit's
  first responder to the next view, which belongs to the user. A key no
  page handles stops at the page: WebKit hands such a key back to the
  app's key window, where it would type into the user's terminal or run a
  menu shortcut, so cmux drops that resend for automated keys.
- A session drives the tabs it created and the user's tabs, never a tab
  another running session created. `tabs.list({ all: true })` lists such a
  tab with `ownedBy` (the other session's name), and `tabs.use()`,
  `tabs.get()` and every call on it fail with an error that names that
  session; its page, cookies, storage, clipboard and network events stay
  the other session's. Sessions share tabs only by being one session: the
  same `--session NAME` in the same workspace. Once the creating session
  ends (a tab it kept with `page.keep()`), the tab is the user's and any
  session may drive it; its clipboard is emptied then, and no session
  has one there. Network events
  (`page.on("request")` and the like) in a tab the session did not create
  reach it only while it listens for them, or for a request its own action
  started, and never carry the page's credential headers (`Cookie`,
  `Authorization`, and any header whose name says it carries one:
  `auth`, `token`, `secret`, `session`, `password`, `signature`, `csrf`
  and the like, the rule `fetch` uses across origins), nor the credential
  values in their URLs and URL-valued headers (`location`, `referer`): a
  userinfo, and each query or fragment parameter named by that rule or by
  a short name URLs use for one (`code`, `sig`, `key`, `otp` and the like)
  reads `redacted`. The same values read `redacted` in the URLs
  `tabs.list()` gives for tabs the session did not create, in the frame
  URLs of such tabs and of frames its domain policy blocks, and in every
  `tabs.history()` entry (history does not say who visited it), and in
  the `url` of every page event (a cancelled navigation, a popup, a
  download) a session gets for a tab it did not create.
- Session behaviors apply only to tabs the session created: tabs from
  `tabs.open()` (and `tabs.content`), and popups of those tabs, while the
  session lasts. In them dialogs and file choosers wait for the agent,
  downloads stay in the temporary directory for `download.path()`, camera,
  microphone, geolocation and notification requests are answered from
  `session.configure({ permissions })` (granted only to an origin and
  frame the session's domain policy allows; one it blocks, or an opaque
  origin under a policy, is denied), the user agent and extra headers
  from `session.configure` apply, the page's scripts copy to the tab's
  clipboard instead of the system's (for the tab's whole life, also after
  the session ends and when cmux replaces the tab's web view to restore an
  unloaded page or recover from a crash), the domain policy's content rules block
  subresources, pages load local files (frames and subresources) only
  from the session's working and temporary directories, and plain-http
  pages load without cmux's prompt. Another
  session that drives such a tab does not change these; they follow the
  creating session. Any other tab is the user's, also one a session drives
  with `tabs.use()` or one a finished run kept with `page.keep()`: it keeps
  its own user agent, headers and content, and cmux's own dialogs, file
  panel, download location, permission prompts and insecure-HTTP prompt,
  except while the page handles one of the session's own clicks, keys or
  drags, the first second of one of its page scripts (`page.evaluate`), or
  one of its navigations until it commits:
  a dialog or file chooser the page opens then goes to that session, as in
  a tab it created, and a window it opens becomes a background tab that
  the session gets as a `popup` (under the session's domain policy) and
  that stays the user's (never closed with the session, nor for the
  session's domain policy, which only keeps the session's reads and input
  out of it). The agent caused
  them, so cmux's UI must not come up in front of the user (an Open panel
  or a key popup window over their work from a hidden workspace) or leave
  the agent waiting for an answer only the user could give. Windows the
  user's page opens otherwise stay the user's, with no `popup` event; while
  sessions drive a tab the user is not working in (not shown and focused in
  the key window of the active app), such a window opens as a background
  tab, never as a key window over the user's work (a page that opens one
  after an `await` in the agent's click lands here). A link that matches a
  configured external-browser rule leaves cmux for the system browser only
  when the user activated it in a user's tab they are working in: WebKit
  marks the navigation as a user gesture (`_isUserInitiated`), no
  session's input is in flight, and none ended in the last 11 s (a page can
  use an input's gesture that long). An agent's click, the page's own link
  activation (`a.click()`, also from agent-world code), or one in the 11 s
  after a session's input, in a tab sessions drive (and any link in a tab a
  session created) loads in the tab instead, under its guards.
  The domain policy there only refuses the session's reads and input while
  the tab, or a frame of it, shows a blocked page (the console messages and
  page errors of a main frame the policy blocks do not reach the session
  either, in any tab, and neither does a dialog or file chooser a frame it
  blocks opens) (see "Guards" in
  [driver-protocol.md](driver-protocol.md)); it never navigates or filters the user's tab. An event the agent registered a handler for on that
  page (`page.on("dialog")`, `page.on("filechooser")`,
  `page.waitForEvent("download")` and the like) goes to the session instead,
  only while the handler is registered; a download, though, only when the
  navigation it came from started while the page handled that session's
  own call (a click, key or navigation; its response may come later), no
  later navigation in that frame (also one to the same URL) replaced it,
  and the session's domain policy allows every address the download came
  through (redirects included, also one after the download started, and
  judged again under the policy then when it finishes; a local file only
  from the session's own directories). A download that went to a session
  ends with it: when the session leaves the tab (it ends, is reset, or the
  tab moves to a workspace where it may not drive it) a download of it
  still running is cancelled and its file removed, also in a tab it kept,
  and never goes on to the user's download location or save panel. A
  file the user downloads in their tab, or one the page starts by itself,
  keeps the user's download location and never reaches a session, and
  neither does one another session's call started. When several sessions drive one tab,
  each dialog, file chooser and download goes to one of them, and only that
  session can answer it: the creating session; else, for a dialog or file
  chooser the page opens while it handles one session's own call, that
  session, also when another session has a handler for it; else the session
  that registered its handler first. WebKit does not say which call a
  dialog, file chooser, popup or request came from, so while calls of two
  sessions are in flight on the tab at once none of these goes to either
  session: such a dialog is dismissed and a file chooser cancelled (as
  unhandled ones are, never shown to the user), a window opens as a
  background tab told to no session, and a request reaches only the
  sessions listening for network events. The runtime reports these handlers
  to the driver with `tab.handleEvents`.
- A driven tab keeps rendering like a foreground page. Shown in a pane of the
  key window, it stays live in the pane. Hidden, or shown in a window that is
  not key, it renders in a window outside every screen that reports itself as
  key (WebKit treats only a page in a key window as focused, for focus, blur,
  typing and hover); a shown tab's pane then holds a mirror of the page,
  refreshed after every driver call. The live view returns to the pane as
  soon as the pane is shown, its window becomes key, or the session ends,
  resets or expires.

## Limits

Every limit a session has, in one place. A session's holders reserve from
one ledger (`BrowserReplResourceLedger` in `Packages/macOS/CmuxBrowser`,
the values in `BrowserReplResourceLimits.standard`) before they hold
memory, work, a slot or disk, and release when they deliver or drop. A
reservation past a limit is refused whole with one message form,
`REPL session limit: <what> at most <limit> <at once | each | per cell |
over the session's life> (<held> held, this needs <n> more); <what to do>`,
after the call or method it refused (`fetch: …`, `Error: REPL session
'NAME': …`). A test runs a workload that reserves every resource and
checks nothing stays reserved after the session ends.

| Resource | Limit | Past it |
| --- | --- | --- |
| Memory the session holds in all (the rows marked M) | 512 MiB at once | the reservation is refused |
| The session's JavaScript heap (M) | 384 MiB, measured as each cell ends and after other runs (at most 5% of the thread's time) | after a full garbage collection, the session ends: the running cell fails with the limit, and the next session of its name prints it first |
| Cells waiting for the running one | 64 | the cell fails at once |
| Source of the waiting cells (M) | 64 MiB | the cell fails at once |
| Parsing the running cell (M) | 64 bytes for each byte of its source, reserved before it is parsed and held until it ends (Acorn's tree is about 50 bytes a byte of dense code); within the session's 512 MiB, so a cell holds at most about 8 MiB of source | the cell fails at once |
| A cell's timeout (`--timeout`, `timeout_ms`) | 10 minutes (default 120 s) | refused before the cell runs |
| Output a cell keeps in memory (M) | 16 MiB per cell | the rest goes to a spill file |
| Output a cell spills | 64 MiB per cell, within the fs budget | the rest is dropped |
| Browser calls running | 256 | later ones wait in order |
| Browser calls waiting | 10,000 | the call fails at once |
| One browser call's parameters | 64 MiB (`filechooser.respond`: its 256 MiB of files in Base64, plus 1 MiB) | the call fails before it is parsed |
| Parameters of calls and fetch requests waiting or running (M) | 512 MiB | the call fails at once |
| One browser call's result | 64 MiB, also with secrets masked | the call fails before its result is masked |
| Results the session's JavaScript has not taken yet (M) | 512 MiB | the call fails instead of waiting |
| One `fs`, `secrets` or `policy` call's arguments (M), reserved before they are parsed or decoded | 64 MiB (an fs call: one write in Base64, plus 1 MiB) | the call fails before it is parsed (`E2BIG` / `ENOMEM` for fs) |
| Fetches waiting for their response headers | 16 | later ones wait in order |
| Open fetches | 64 | later ones wait in order |
| Fetches waiting for a slot | 256 | the fetch fails at once |
| One fetch's request body / response body | 64 MiB / 64 MiB | the fetch fails |
| Response bodies the session's fetches hold (M), at the size of their Base64 results | 128 MiB | the fetch fails |
| A fetch's duration | 10 minutes | `timeout` |
| Page events waiting for the session's thread | 10,000 | a new one is dropped (the next cell says so) |
| Bytes of those events (M) | 64 MiB, masked | a new one is dropped, or arrives withheld |
| One page event | 1 MiB | arrives withheld (`{ targetId, withheld }`) |
| Page events held between cells | 10,000 | the oldest is dropped |
| Pending timers | 10,000 | `setTimeout` throws `RangeError` |
| Timer or event callback outside a cell | 10 s per run, 10% of the thread's time | stopped, or held until the next cell |
| One fs write or copy | 256 MiB | `EFBIG` |
| fs writes, spill files and file chooser answers over the session's life | 2 GiB | `EDQUOT` |
| fs file changes over the session's life | 100,000 | `EDQUOT` |
| One `readFile` / `readdir` | 64 MiB / 10,000 entries | `ERR_FS_FILE_TOO_LARGE` / `ERR_FS_DIR_TOO_LARGE` |
| One fs path (`path`, `from`, `to`) | 1,024 bytes (`PATH_MAX`) | `ENAMETOOLONG`, before any work |
| A page read (snapshot, Markdown and its `exportContent`, extract, locator reads, …) | 250,000 nodes, 2,000,000 characters, 8 s | cut, with a note; a string cut at the size budget (or a name past 2,000 characters) also loses the 53,248 characters before its cut, so it never ends inside a value masked as a secret |
| The localStorage one `storageState` reads, over all frames | 250,000 items, 2,000,000 characters of names and values | the call fails with the page-read note |
| One reply from the page agent's world | 10,000,000 characters (the page-read budget's characters plus 32 per node) | the call fails with the page-read note |
| Handles one `queryAll` makes | 250,000 | without a limit, the call fails with the page-read note |
| A screenshot / PDF | 16,384 CSS pixels an edge and 33,554,432 pixels / 14,400-point edges | `invalid` |
| An owner token / a working directory | 128 bytes / 1,024 bytes (`PATH_MAX`) | refused before a session is made |
| Sessions in one cmux instance | 32 | the next is refused |
| Sessions driving one tab | 4 at once | the next session's call on the tab fails with `limit` |
| Secrets per session | 256, each at most 4 KiB with 64 domains | refused, naming the limit |
| Domain policy | 1,024 patterns per list, 1,024 bytes a pattern | `invalid`, naming the limit |

JavaScriptCore has no heap limit a context can set, so the heap row is a
measure, not a refusal: a cell or callback can allocate past it while it
runs, and the session ends once the run returns. It counts toward the
session's memory, so other holders are refused beside a large heap.

Outside the session's ledger, bounded by their own tables: the driver's
per-tab holders (unfinished network requests, 1,000 or 8 MiB a tab; the
virtual clipboard, 32 items and 64 MiB of Base64), the values typed
secrets left in pages (4,096 in the whole app, shared by sessions on
purpose so each masks the others'), the session registry (32 sessions),
and the scripts the page agent runs in the page's world (`page.evaluate`,
bounded only by the 64 MiB result).

## Hibernated and crashed tabs

cmux unloads the pages of hidden browser tabs to save memory (Settings,
Browser, memory saver); the tab keeps its URL, history and title. A tab a
session drives is never unloaded while the session is attached, but a
user's tab, or a tab a finished run kept, can be unloaded before a session
reaches it. `tabs.list()` and `tab.info` report each tab's `state`:

| `state` | Meaning |
| --- | --- |
| `live` | The page is loaded. |
| `hibernated` | cmux unloaded the hidden page, or a relaunch restored the tab without loading it yet. Listing it does not load it. |
| `waking` | The page is loading again. |
| `crashed` | The tab's web content process ended (a WebKit crash, or macOS reclaimed its memory) while the tab was shown; the pane offers Reload. |

Any call that needs the page (`tabs.use()` reads `tab.info`, so it is one)
loads a hibernated tab again first, also when automatic restore of unloaded
pages is off in Settings, and waits until the restored document is parsed,
at most 30 s. The load runs off screen like any driven hidden tab; it never
shows or focuses the tab. Closing, keeping or navigating away from a
hibernated tab does not load its old page, and `page.reload()` loads it once. A hidden tab whose process died is restored the
same way on the next call. When the tab cannot be woken the call fails with
an error that names it ([driver-protocol.md](driver-protocol.md#hibernated-and-crashed-tabs)
has the exact texts): `hibernated` when the user stopped the tab from
loading or the restore ended without a page, `timeout` when it is still
loading after 30 s (retry), and `crashed` for a crashed tab, where only
navigation, `tab.info`, `page.bringToFront()` and `page.close()` work until
`page.reload()` or `page.goto(url)` loads it again.

## Excluded from the references

- **Site integrations** are `sites` ([site-tools.md](site-tools.md)); its
  "Decisions for the user" lists what is left out (password managers,
  CAPTCHA solving, `imessage`, image generation). Reference A's raw `exec`
  command is outside browser operation.
- **Raw CDP** (reference B `browser.capabilities`' `cdp`) and request interception:
  WebKit has no DevTools protocol. Reference B withholds both by
  default too (`browser.capabilities` in the parity cases records that). A
  Chromium engine would add them as `page.cdp`.

Everything else reference B documents has a cmux equivalent, including
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
  fetch, event, file write and output line passes through. Everything
  native hands the session's JavaScript or output passes one egress gate
  that masks secrets in a single scan of the original data, and page URLs
  travel as one typed value that only the tab's live creator reads with
  its credentials. The runtime
  deletes the `__cmuxNative` global, and the app the runtime's entry
  points, before any cell runs. Every script on the session's thread is
  bounded, also a timer or event callback outside a cell (10 s per run,
  and 10% of the thread's time over a stream of them, so they cannot
  starve the next cell, whose output says when they were stopped or
  waited), and `cmux browser repl reset` always ends a stuck one. This
  needs JavaScriptCore's execution time limit
  (`JSContextGroupSetExecutionTimeLimit`); where it is missing, a session
  runs no cell and says why.
- Runtime: `Resources/browser-repl/` (`runtime-core.js` Playwright model,
  `api.js` globals, `snapshot.js` host-side stitching and diff, `page-agent.js`
  per-frame script in an isolated content world, `repl-host.js`). Locators use
  Playwright's injected script (Apache-2.0).
- Driver contract: [driver-protocol.md](driver-protocol.md).
- Sites (registrable domains) for cookie scoping and `storageState` come from
  the Public Suffix List macOS keeps in CFNetwork (`_CFHostIsDomainTopLevel`,
  the list WebKit reads for its own site boundaries), asked by the native
  session and driver (`BrowserReplPublicSuffixList`), so it follows OS
  updates and nothing is vendored. Where CFNetwork does not export it, every
  host is its own site (a narrower scope). The dev backend uses a small
  stand-in (`tests/browser-parity/lib/public-suffix.mjs`).
- The format studies and the representation comparison live in the private repository `manaflow-ai/cmux-browser-parity-private`.

## Tests

[tests/browser-parity](../../tests/browser-parity/README.md): one scenario set in
this API, run against the cmux app, a Playwright WebKit development driver, and
a real-Playwright oracle (headless Chrome) for behavior values.
