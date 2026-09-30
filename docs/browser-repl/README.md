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
  - link "Home" [ref=e2] [url=/aria.html]
- main:
  - heading "Sign up" [level=1]
  - textbox "Email" [ref=e3] [placeholder="you@x.com"]: "me@x.com"
  - checkbox "Accept terms" [ref=e4] [checked]
  - combobox "Plan" [ref=e5]: "Pro"
  - button "Create account" [ref=e6] [focused]
  - table "Scores":
    - row: "Name | Score"
    - row: "Ada | 9"
  - paragraph: "Plain bold text."
  - iframe "Payment" [ref=e7]:
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
- **Frames**, including cross-origin, inline under their iframe with `fN`
  prefixes in DOM order. Shadow roots are pierced.
- **States** print as `[checked]`, `[checked=mixed]`, `[disabled]`,
  `[expanded]`, `[expanded=false]`, `[pressed]`, `[selected]`, `[focused]`,
  `[required]`, `[invalid]`, `[readonly]`, `[level=N]`, `[scrollable]` (why a
  plain region has a ref) and, with `showHidden`, `[hidden]`. Aside drops
  expanded and pressed. `[focused]` inside an iframe prints only when that
  iframe holds the page's focus.
- **Values** print after a colon; combobox shows its selected value and lists
  options only with `{ options: true }` or when expanded. Links show `[url=…]`,
  relative when same-origin, so agents do not guess URLs.
- **Text** collapses whitespace to single spaces (Aside doubles spaces around
  inline elements). Tables print one `row` per table row with cells joined by
  `|` (Aside drops table structure).
- **Open dialogs and file choosers** print first, under the header, so an
  agent sees why the page is blocked. A file chooser line carries its input's
  ref. A JavaScript dialog line has none, because no element owns the dialog
  and a ref must work as a selector; it names `page.dialog()` instead, and the
  tree is replaced by a note while the dialog blocks the page.
- **Options**: `interactive` (interactive nodes and their named ancestors),
  `showHidden`, `maxChars` (truncates with a note), `options`.
- **Printing** a snapshot prints its diff against the previous snapshot of the
  same tab when the diff is at least 30% smaller than the tree, else the tree.
  `.tree` and `.diff` are always available.
- **Diff** lines are `+ ` added and `- ` removed, each change preceded by its
  unchanged ancestor lines (two-space prefix) as context so the change is
  locatable. A changed line's old version prints right before its new one
  (matched by ref, else role and name). ChatGPT omits ancestors; Aside prints
  bare `@@` hunks.

## Sessions and tabs

- Named sessions (`--session NAME`) keep variables and tabs until
  `cmux browser repl reset NAME` or 30 minutes idle. A run without `--session`
  is one-shot: its tabs close at the end unless `page.keep()` was called.
- A session binds to the caller's cmux workspace (from `CMUX_WORKSPACE_ID`), or
  to the focused workspace when the caller is outside cmux or the id is unknown
  to this instance.
- `tabs.open()` never steals focus. `page.bringToFront()` shows a tab.

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
