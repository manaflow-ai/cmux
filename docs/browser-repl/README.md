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
   hold the clipboard command, and the next snapshot says so. Ambiguous
   input failures are reported and never replayed.
5. **Less to remember.** Top-level `const`/`let` persist across calls, the last
   expression's value prints automatically, and printing a snapshot picks the
   diff or the full tree by size.

## Globals

| Global | Purpose |
| --- | --- |
| `page` | The current tab, a Playwright `Page`. |
| `tabs` | `list()`, `open(url, { background })`, `current()`, `use(tabOrId)`, `get(id)`. `list()` returns `{ id, title, url, active, current, state }` without attaching or waking a tab (`state`: see [Hibernated and crashed tabs](#hibernated-and-crashed-tabs)); `list({ all: true })` adds tabs in the user's other workspaces and windows, which `use(id)` attaches (reference B's `claimTab`), except one another running session opened (listed with `ownedBy`; see [Sessions and tabs](#sessions-and-tabs)). `open`, `current`, `use` and `get` return a `Page` with a stable `page.id`. `content({ urls, format })` loads URLs in background tabs and extracts text, Markdown, HTML or a snapshot. `history({ query, from, to, limit })` searches cmux browser history. |
| `snapshot(target?, options?)` | Accessibility snapshot of `page`, a locator, or a ref string. See [Snapshot](#snapshot). |
| `screenshot(target?, options?)` | PNG of the viewport, full page, locator or ref. `{ annotate: true }` draws each ref's box and label. Returns an `Image` that displays when printed. |
| `fetch` | Standard `fetch` that sends the current tab's cookies (`credentials`: `"include"` by default, `"same-origin"`, `"omit"`). The domain policy is checked on every redirect hop; a body over 64 MiB fails (download it in a tab instead), as does one past the 128 MiB a session's fetches may hold at once; a fetch fails after 10 minutes; past 256 queued fetches a new one fails at once. |
| `fs`, `path`, `os`, `Buffer` | Node-compatible subsets. Files are limited to the session directory (the caller's cwd; `/` and the home directory are refused, and `repl mcp` started there uses a temporary directory) and the session's own temporary directory (`os.tmpdir()`, mode 0700, never shared with another session); a symbolic link is never followed out of them (also when another process changes the tree meanwhile), and `rm`, `rename` and `lstat` act on the link itself as in Node. A FIFO, socket or device fails with `EINVAL` instead of blocking, and `readFile` reads at most 64 MiB. One `writeFile`, `appendFile` or `copyFile` writes at most 256 MiB, and a session at most 2 GiB in all (reset it to write more); a long write or copy stops when its cell times out. `import("node:fs")` and friends return the same modules. |
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
| `page.clipboard` | `readText()`, `writeText(text)`, `read()`, `write(items)` on a per-tab clipboard. Meta+V fires a trusted `paste` event whose `clipboardData` holds it; Meta+C and Meta+X fill it from a trusted `copy`/`cut` with whatever the page's handler sets. A JavaScript dialog the page opens meanwhile is dismissed and reported in the next snapshot. Neither touches the system clipboard, which other code (the terminal) keeps. The clipboard is the creating session's alone, while it lives: `page.clipboard` and the shortcuts run only in tabs the session opened and throw `unsupported` in a user's tab (also one a finished run kept), so two sessions driving one tab never pass bytes through it. One during which another web view copied, pasted or read the clipboard throws `stale` and leaves the tab's clipboard unchanged (that other web view never reads the tab's clipboard); a Paste gives the page only plain text, HTML, RTF, PNG, TIFF, WebKit's custom web data and `http(s)` URLs, never a file reference. One WebKit does not finish within 5 s throws a timeout, leaves the tab's clipboard unchanged and ends the tab's web content process (the page crashes; `page.reload()` loads it again), so nothing the page does later reaches the system clipboard. In a tab a session created, the page's own scripts write here too, never to the system clipboard, even after an agent's click gave them a user gesture: `navigator.clipboard.write` and `writeText` (a `ClipboardItem` whose data settles later included) and `document.execCommand("copy")` or `"cut"`; their reads reject with `NotAllowedError` ([Guards](driver-protocol.md#guards) says how, and names the one case WebKit leaves open). In a user's tab the page keeps the browser's clipboard. In any tab, what WebKit would write to the system clipboard with the gesture of the agent's input or page script (the page's scripts in a user's tab, script in the agent's world in any tab), from the call until 11 s after it, reaches neither the system clipboard nor the session; a copy or paste the person makes in another browser tab of cmux during that time does nothing. | Reference B `clipboard` |
| `page.elementAt(x, y)` | `{ ref, role, name, box }` for the topmost element at a viewport point. | Reference B `elementInfo()` |
| `page.keep()` | Keep this tab open after a one-shot run. | Reference B `markDeliverable()` |
| `page.exportContent(options)` | Write the page as Markdown, a Google Docs/Sheets/Slides tab in an export format (`{ format }`), or a YouTube watch page's captions (`{ transcript: true }`, fetched only from a track URL that is https on `www.youtube.com`, `m.youtube.com` or `youtube.com`) to a file; returns the path. | Reference B `content.export*` |
| `page.markdown(options)`, `page.extract(spec)`, `page.searchText(pattern)` | The page as Markdown (iframes and shadow roots included, `{ main: true }`, chunked with `{ start, maxChars }`); structured data by selectors; text matches with refs. | Reference C `extract`, `search_page`, `find_elements` |
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
  snapshot`) once its frame shows another document. Reference A renumbers a ref when its name
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
  viewport are not shown`; refs are the same as in a full snapshot),
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
  prints once, as its new version. Reference B omits ancestors; reference A prints
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
  nodes over all its frames (frames inside a frame split what it left, and
  one past the budget prints `[not read: the snapshot's node budget is used
  up]`), and a frame's walk stops after 8 s. A cut snapshot ends with
  `# the page is too large to read whole: the snapshot stopped after
  250,000 nodes; …`; snapshot a part of the page (`snapshot(ref)`, a
  locator) to read further. Printing a
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
  still has it.
- **Control characters** in printed text (page titles and text can hold
  terminal escape sequences) print visibly: newline and tab stay, other C0
  controls print as their control pictures (ESC as `␛`), DEL as `␡` and C1
  controls as `\u{9B}`. `--json` keeps the exact text.

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
- A session made without `--session` (a one-shot run, the interactive
  REPL's `cli-<pid>-<random>`, `mcp`'s) is its client's alone: the client
  sends a random owner token with every call, and without that token no
  other client sees it in `cmux browser repl list`, attaches to it or
  resets it, also when it knows the name or the client was killed before
  its session ended (it then idles out after 30 minutes). Named sessions
  are shared by name.
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
  and the like, the rule `fetch` uses across origins).
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
  the session ends), the domain policy's content rules block
  subresources, and plain-http pages load without cmux's prompt. Another
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
  that stays the user's (never closed with the session). The agent caused
  them, so cmux's UI must not come up in front of the user (an Open panel
  or a key popup window over their work from a hidden workspace) or leave
  the agent waiting for an answer only the user could give. Windows the
  user's page opens otherwise stay the user's, with no `popup` event; while
  sessions drive a tab the user is not working in (not shown and focused in
  the key window of the active app), such a window opens as a background
  tab, never as a key window over the user's work (a page that opens one
  after an `await` in the agent's click lands here).
  The domain policy there only refuses the session's reads and input while
  the tab, or a frame of it, shows a blocked page (see "Guards" in
  [driver-protocol.md](driver-protocol.md)); it never navigates or filters the user's tab. An event the agent registered a handler for on that
  page (`page.on("dialog")`, `page.on("filechooser")`,
  `page.waitForEvent("download")` and the like) goes to the session instead,
  only while the handler is registered; a download, though, only when the
  navigation it came from started while the page handled that session's
  own call (a click, key or navigation; its response may come later) and
  no later navigation in that frame (also one to the same URL) replaced it. A
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
  fetch, event, file write and output line passes through. The runtime
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
