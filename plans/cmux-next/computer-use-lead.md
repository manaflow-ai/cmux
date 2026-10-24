# Computer and browser use lead

This file holds the lead's plan. The section below was written by the
codemode parity helper (branch `cu-codemode`); the lead's own sections merge
in around it.

## Codemode parity

Ask (Lawrence, 2026-10-23): "all browser use stuff to work through cmux
codemode. we need to have parity with aside repl cli." Code mode is the cmux
MCP server's `cmux_exec` with the `browser_repl_open|eval|close|reset|list|guide`
tools (`cmux mcp`, cmux-tui `src/cli/mcp/`), served by the browser host
(`cmux-browser-host`, its runtime JS in `js/`). Aside is `aside repl`.

### What the lead measured (NIGHTLY 1.0.0-nightly.3997257646201, an acpmux agent)

1. Every `browser_repl_*` call failed `browser_host.unavailable`: `cmux mcp`
   only connected, while `cmux-browser-host eval` starts a host when none
   answers.
2. After a manual `cmux-browser-host list`, `browser_repl_open` answered
   `engine: "headless"`: a private headless Chromium, not the app's in-app
   tabs. acpmux agents have no `CMUX_TUI_SOCKET`, and acpmux names a private
   `CMUX_BROWSER_HOST_SOCKET` (`session_tmp.rs` `env_for`), so they never reach
   the daemon's host that holds the app's provider.
3. Aside globals missing: `annotatedScreenshot`, `pwd`, `listBrowserTabs`,
   `attachBrowserTab`, `attachActiveBrowserTab`, `getTabByTargetId`,
   `openTab`, `closeTab`.

### What landed (tests `codemode_parity_*`)

- A. One start-on-demand connect, `cmux_unix_socket::on_demand::connect_or_start`,
  used by `cmux-browser-host eval|list|close` and by `cmux mcp`. When no host
  answers and no daemon owns the socket, `cmux mcp` starts the bundled
  `cmux-browser-host serve --socket <socket>` (own process group, 10 s
  connect window). A daemon terminal (`CMUX_TUI_SOCKET` plus the named
  socket) waits for its daemon's host and never starts one.
- B, routing: `cmux mcp` tries, in order, the daemon terminal's named host;
  the host of the daemon `cmux mcp` already talks to (the CLI's own socket
  resolution: the app's daemon for the bundled `cmux`, so per-build isolation
  holds), when its socket exists and answers; then the default socket, where
  it starts a headless host. No acpmux change is needed: the server finds the
  app daemon's host itself.
- B, engine: `engine: "auto"` is `cef` for a named session while the app's
  provider is connected and offered `cef` in its `hello` (browser-host.md
  decision 7), else `headless` (Linux VM, no app). The implicit `default`
  session stays headless, because the host keeps the person's tabs off the
  shared `default`.
- B, naming: a `browser_repl_*` call without `session` from an agent chat
  (`CMUX_AGENT_SESSION`) uses `agent-<chat session>`, so code mode gets a
  named session (the in-app engine) without the agent naming one, and two
  chats never share one page. An explicit `session` wins.
- C. `js/aside-compat.js`: `listBrowserTabs`, `attachBrowserTab`,
  `attachActiveBrowserTab`, `getTabByTargetId`, `openTab`, `closeTab`,
  `annotatedScreenshot` (= `screenshot(target, { annotate: true })`, the
  existing ref-box overlay) and `pwd`; `snapshot(page, { ref | selector })`
  scopes like `snapshot(ref)`. Documented in the REPL guide
  (`browser_repl_guide`, `skills/cmux-browser/references/repl-guide.md`) and
  `skills/cmux-browser/SKILL.md`.

### Open: decisions and gaps for the in-app browser (B)

1. Profile. The host gives agents the per-workspace agent profile (D12): only
   origin `user` opens a session on another profile (`host.rs` `open`). Aside
   drives the person's own signed-in browser. cmux agents reach the person's
   sign-ins today only by attaching an open tab (`tabs.list({ all: true })`
   then `tabs.use(id)` or `attachBrowserTab(id)`, with the lease and the
   extension-access gate) or through `cmux browser import-cookies` (consent
   panel). Decision for Lawrence: keep D12 (agents open new tabs signed out)
   or let an agent chat open new tabs in the person's profile.
2. Placement. A `cef` session's new tab opens in the background of the
   active window's focused pane (`AppBrowserHostTabs.sessionTabPane`), not in
   the column right of the agent's chat (`beside_caller`, as `cmux browser
   right` does). Proposal: `tabs.open` from a session with a caller (the
   lease `terminal`, or the acpmux agent session that `cmux mcp` would send as
   `browser.repl.open {agentSession}`) opens in that chat's right column, with
   the same rule as `browser.page.right`. Needs a field on `browser.repl.open`
   and the app's `openProviderTab` to take a placement hint.
3. Provider reconnect (measured 2026-10-23 23:00 on NIGHTLY). The NIGHTLY
   daemon's host (`bh-8f2549be3082`) had the app's provider at 22:50 (a `cef`
   session opened). After that host stopped, an agent connect started a new
   one (pid 32473), and minutes later every `cef` open still failed
   `engine_unavailable: cef: the cmux app is not connected to the browser
   host`. The app re-asks for credentials on a daemon connection change or
   after a dial failure with backoff, and stays idle when the credentials
   request answers nothing (`BrowserHostProvider.run`). Until that is fixed,
   `auto` falls back to headless there (by design, no failure). Owner: the
   browser host lead (app side, `CmuxNextBrowserHost`).
4. `cmux-browser-host eval` (the bundled CLI) still uses only its own socket
   rule; it cannot reach the app daemon's host from an acpmux agent. It needs
   the app identity code that lives in the `cmux` binary; when
   `cmux browser repl` (#16174) moves into `cmux`, it gets the MCP route.

### Parity table (Aside 1.26.1019.1018 against the cmux REPL, read-only comparison)

REPL API (`aside guide repl`), 29 entries: 15 present, 10 alias (landed
above), 4 differ, 0 missing.

| Aside API | cmux | Status |
| --- | --- | --- |
| `page` | `page` (opens a tab on first use; Aside starts with none) | differs |
| `tabs` | `tabs.list/open/current/use/get/content/history` (an object, not a list of pages) | differs |
| `listBrowserTabs()` | `tabs.list({ all: true })` mapped to `{ targetId, title, url, active }` | alias |
| `attachBrowserTab(targetId)` | `tabs.use(id)` | alias |
| `attachActiveBrowserTab()` | active tab, `tabs.use` | alias |
| `getTabByTargetId(targetId)` | `tabs.get(id)` | alias |
| `openTab(url)` | `tabs.open(url)` | alias |
| `closeTab(tab)` | `page.close()` | alias |
| `snapshot(page, options)` returning `{ tree, diff }` | `snapshot(target, options)`, `.tree`, `.diff` | present |
| snapshot `interactive`, `showHidden` | same options | present |
| snapshot `ref`, `selector` | `snapshot(ref)`, `snapshot(locator)`; options accepted | alias |
| `annotatedScreenshot(page)` | `screenshot(page, { annotate: true })` | alias |
| `page.screenshot()`, `page.pdf()` | same | present |
| `fetch(url)` | `fetch(url, init)` with the tab's cookies | present |
| `fs`, `path`, `Buffer`, `sleep`, `display`, `console.log` | same | present |
| `pwd` | session directory | alias |
| `download.path()`, `download.saveAs()` | same | present |
| `const`/`let` persist | only in a named session (code mode now names one per chat) | differs |
| 120 s timeout | 120 s host default; code mode 60 s default, at most 300 s | present |
| no `import`/`require` | `require`/`import("node:fs")` of fs, path, os, buffer | differs |

One runtime rule differs from Aside and fails Aside-style scripts: a
selector that tests the `value` attribute (`input[value=medium]`) is refused
on page reads (`frame.observe: splitFrames selectors cannot test attribute
values`), a deliberate guard against reading field values through selectors
(browser-host.md "frame.observe"). `getByRole`/`getByLabel` work instead.

Built-in skills (`aside skills list`), 11: 3 present (google-accounts,
google-search, youtube), 6 partial (google-docs, google-gmail, google-sheets,
linkedin, notion, slack), 2 missing (`aside` daemon settings and sessions,
`Messages`/iMessage). Of 80 documented functions: 28 present, 11 partial, 41
missing. Largest gaps: iMessage (`waitForCode` for SMS codes), LinkedIn
messaging and invitations, Notion databases and block creation, Slack file
upload, Docs/Sheets live-editor edits (cursor, selection, comments, notes,
suggestions). cmux has site tools Aside lacks: googleCalendar, googleDrive,
googleSlides, github, jira, linear, x, webmcp, pageAssets, browserAuth. The
cmux site tools (`sites.*`) are not in the REPL guide; agents find them only
through `sites.list()` and `sites.help(name)`.

### Dogfood through code mode

`tests/automation-bench/dogfood/repl_parity.mjs` runs 10 tasks of
`tasks.json` (example-title, hn-story-links, hn-click-new, wikipedia-search,
httpbin-form, internet-checkboxes, internet-dropdown, internet-dynamic-loading,
internet-iframe-snapshot, todomvc-add) through `cmux mcp serve` (stdio),
one `cmux_exec` per task that calls `browser_repl_eval`, once written with the
cmux names and once as an `aside repl` script would be written.

| Run (2026-10-23, NIGHTLY 3997257646201, acpmux agent) | cmux style | Aside style |
| --- | --- | --- |
| Before (headless host started by hand) | 9/10 | 0/10 (`openTab is not defined`) |
| Aside names defined in the script as the same thin wrappers (`--polyfill`, what the landed `aside-compat.js` gives) | 9/10 | 8/10 |
| `--engine cef` on the app daemon's host | provider not connected (gap 3); fell back to headless: 9/10 | 8/10 |

The cmux-style failure is httpbin-form (the `value` selector rule above). The
extra Aside-style failure is todomvc-add, most likely because the shared
headless agent profile kept the todos an earlier run added (localStorage), so
the count check did not see exactly 2 (not verified).
Measure the landed code with the first nightly that contains it:
`node tests/automation-bench/dogfood/repl_parity.mjs --style both`.
