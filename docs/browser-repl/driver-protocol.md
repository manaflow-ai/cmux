# Browser driver protocol

The contract between the REPL runtime (JavaScript, engine-neutral) and an engine
driver. The runtime builds the reference A and reference B APIs on these primitives the
same way Playwright builds its API on a browser protocol. Drivers:

- `webkit`: cmux app, `WKWebView` panes (Swift).
- `chromium`: CDP passthrough, when a Chromium engine lands.
- `dev`: Playwright WebKit (tests/browser-parity/lib/dev-driver.mjs), used to
  develop the runtime without an app build.

## Transport

`driver.call(method, params) -> Promise<result>` and `driver.on(event, handler)`.
In the app, calls are synchronous-looking JSON messages between the REPL's
JavaScriptCore context and Swift; results are JSON. Errors are
`{ code, message }`, with codes `not_found`, `stale`, `timeout`,
`unsupported`, `invalid`, `closed`.

Coordinates are CSS pixels relative to the top-left of the tab's viewport
(main frame), matching Playwright `page.mouse` and screenshots at scale 1.

## Tabs

| Method | Params | Result |
| --- | --- | --- |
| `tabs.list` | `{ all? }` | `[{ targetId, title, url, active, windowId, openerTargetId? }]` in window order; with `all`, then the browser tabs of every other workspace and window (`windowId` names the workspace). Any listed tab is a valid `targetId` for the other methods. |
| `tabs.open` | `{ url?, background? }` | `{ targetId }`; resolves after commit of `url` |
| `tabs.close` | `{ targetId, runBeforeUnload? }` | |
| `tabs.activate` | `{ targetId }` | |
| `tab.navigate` | `{ targetId, url, waitUntil: "commit"\|"domcontentloaded"\|"load"\|"networkidle", timeoutMs }` | `{ url, status? }` |
| `tab.history` | `{ targetId, delta: -1\|1, waitUntil, timeoutMs }` | `{ url }`, or `null` when no entry (the blank page a tab opened on is not an entry) |
| `tab.reload` | `{ targetId, waitUntil, timeoutMs }` | `{ status? }` |
| `tab.info` | `{ targetId }` | `{ url, title, loadState, viewport: { width, height }, deviceScaleFactor, webProcessId? }` |
| `tab.setViewport` | `{ targetId, width, height }` or `{ targetId, reset: true }` | |
| `tab.bringToFront` | `{ targetId }` | |
| `tab.keep` | `{ targetId }` | |
| `tab.handleEvents` | `{ targetId, events: ["dialog"\|"filechooser"\|"download"] }` | Replaces the events this session has a handler for in the tab. See below. |
| `session.name` | `{ name }` | |
| `session.configure` | `{ userAgent?, extraHTTPHeaders?, permissions?, proxy? }`, each key replacing its value (`null` clears) | `{ proxy }`: whether tabs opened from now on use the proxy. Applies to the tabs the session created while it is attached (a user's tab it drives keeps its own user agent, headers and content), whichever session drives them; it is undone when the creating session leaves the tab. Content rules are not accepted here: the driver builds them from the session's domain policy (see "Guards") |
| `history.search` | `{ queries?, from?, to?, limit }` (times in ms since the epoch) | `[{ url, title, dateVisited }]` newest first, from the history of the profiles the workspace's tabs use |

Tabs the session opened (`tabs.open`, popups) close when the session ends;
`tab.keep` releases one so it stays open.

A tab the session created (`tabs.open`, and popups of such a tab) gets the
session's behaviors while the session is attached: `dialog.opened`,
`filechooser.opened` and `download.*` for every dialog, file chooser and
download, permission requests answered from `session.configure`, and no
insecure-HTTP prompt. Any other tab the session drives is the user's: those
events keep the browser's own UI and are not sent, except an event named in
the session's last `tab.handleEvents` for that tab, which is sent to the
sessions instead. The runtime sends `tab.handleEvents` whenever a page's
`dialog`, `filechooser` or `download` listeners change, and its next call on
the tab waits for it. A download keeps the route it started with.

When the last session leaves a tab, the driver releases what the sessions
left pressed: each held key gets its key-up (last pressed first) and each
held mouse button its button-up at the last mouse position, or the drag it
started ends. The page sees them as trusted events. `session.name` shows the tabs the
session opened, now and later, as `<name> · <page title>`, following title
changes; a title the user set wins, and the plain title returns when the
session ends. An empty name removes the label.

Hidden tabs a session drives render at 1280x800 (Playwright's default); a tab
shown in a visible pane keeps its pane size; `tab.setViewport` overrides both.
While driven, a hidden tab's window reports key and its web view is first
responder there, so the page is focused (`document.hasFocus()`, focus and blur
events) without changing the user's key window or first responder.

`tab.info.url` is the live document URL, including `history.pushState` changes.

## Frames and scripts

| Method | Params | Result |
| --- | --- | --- |
| `frames.list` | `{ targetId }` | `[{ frameId, parentFrameId, url, name, crossOrigin }]`, parents before children, document order |
| `frame.evaluate` | `{ targetId, frameId, world: "agent"\|"page", source, args, awaitPromise, timeoutMs }` | JSON-serializable return value |
| `frame.ownerBox` | `{ targetId, frameId }` | owner `<iframe>` content box in parent-frame coordinates |

`world: "agent"` runs in an isolated content world where the driver has
already installed the page agent (`Resources/browser-repl/page-agent.js`) and
Playwright's injected script. Cross-origin frames are reachable. `source` is a
function expression called with `args`. The agent world survives until the
frame navigates; after navigation the driver reinstalls it before the next call.

## Input

All input is delivered as native, trusted events (`isTrusted === true`).

| Method | Params |
| --- | --- |
| `input.mouse` | `{ targetId, type: "move"\|"down"\|"up"\|"wheel", x, y, button: "left"\|"right"\|"middle", clickCount, modifiers, deltaX?, deltaY? }` |
| `input.key` | `{ targetId, type: "down"\|"up", key, code, text?, location?, modifiers, autoRepeat? }` |
| `input.insertText` | `{ targetId, text }` or, from the runtime, `{ targetId, secret: name }`, which the native session turns into `{ targetId, text, secretName, secretDomains }` (see "Guards") (IME commit into the focused element. On WebKit a `contenteditable` editor gets marked text then its confirmation, so `compositionstart`, `beforeinput`/`input` and `compositionend` fire, trusted, and editors that start an edit only on a keydown or a composition (Google Sheets) take it; a form field gets a plain insert with one `input` event, as Chrome's `Input.insertText`; text with a line break or tab, or focus in an unreadable frame, inserts without a composition) |
| `input.drag` | `{ targetId, path: [{ x, y }], button, modifiers }` (native drag session so HTML5 drag and drop fires) |

`modifiers` is an array of `Alt`, `Control`, `Meta`, `Shift`. Key names follow
Playwright (`KeyboardEvent.key` values plus `Meta+a` style parsed by the runtime).

When sessions share a tab, a session's `input.mouse` `down` owns the pointer
until its `up` (or until the session leaves the tab); another session's
`input.mouse` waits meanwhile, at most 10 s, then fails with `timeout`
naming the session that holds the mouse.

## Capture

| Method | Params | Result |
| --- | --- | --- |
| `tab.screenshot` | `{ targetId, clip?, fullPage?, format: "png"\|"jpeg"\|"webp", quality? }` (the session adds `secretMasks`) | `{ base64, width, height }` |
| `tab.pdf` | `{ targetId, format?, width?, height?, landscape?, printBackground?, margin? }` | `{ base64 }` |

## Files, dialogs, popups, downloads

| Method | Params |
| --- | --- |
| `input.setFiles` | `{ targetId, frameId, element: <agent element handle id>, files: [{ name, mimeType, base64 }] }` |
| `filechooser.respond` | `{ targetId, chooserId, files }` or `{ ..., cancel: true }` |
| `dialog.respond` | `{ targetId, dialogId, accept, promptText? }` |
| `download.path` | `{ downloadId }` → `{ path }` after completion |

## Events

Every event carries `targetId`.

| Event | Payload |
| --- | --- |
| `tab.created` | `{ targetId, openerTargetId?, url }` (popups and `target=_blank`) |
| `tab.closed` | |
| `tab.crashed` | (the web content process ended; calls other than navigation fail until a reload or navigation starts a new one) |
| `tab.navigated` | `{ frameId, url, sameDocument }` |
| `navigation.blocked` | `{ url, reason }`: the driver cancelled a main-frame navigation of a tab the session created because the domain policy blocks `url` |
| `tab.loadState` | `{ state: "domcontentloaded"\|"load"\|"networkidle" }` |
| `dialog.opened` | `{ dialogId, type: "alert"\|"confirm"\|"prompt"\|"beforeunload", message, defaultValue, dismissedDuring? }` (stays open until `dialog.respond`; with `dismissedDuring: "copy"\|"cut"\|"paste"` it opened during that clipboard command and is already dismissed) |
| `filechooser.opened` | `{ chooserId, frameId, element, multiple }` (the native panel is not shown; see `tab.handleEvents` for which tabs send it) |
| `download.started` | `{ downloadId, url, suggestedFilename }` |
| `download.finished` | `{ downloadId, path?, error? }` |
| `console` | `{ type, text, args?, location? }` |
| `pageerror` | `{ message, stack }` |
| `request` / `response` / `requestfailed` / `requestfinished` | `{ requestId, url, method, resourceType, status?, headers? }` |

## Browser state

| Method | Params |
| --- | --- |
| `cookies.get` / `cookies.set` | `{ urls?, targetId? }`, `{ cookies, targetId? }`. A URL the domain policy blocks fails with `blocked`; `cookies.get` leaves out the cookies of blocked sites and `cookies.set` refuses one, and also refuses a cookie with a Domain attribute (`.example.com`) unless an allowed pattern covers every subdomain it reaches (`*.example.com`) and no prohibited host is among them (see "Guards") |
| `cookies.clear` | `{ targetId?, all?, name?, domain?, path? }`. Deletes the cookies of the target tab's store (the active tab's without `targetId`) on that tab's site, its registrable domain by the system's Public Suffix List (CFNetwork), and the site's subdomains, narrowed by exact `name`, `domain` and `path`. The driver takes the site from the tab; a `site` parameter is ignored. On a persistent profile (the user's cookies) a tab with no http(s) site and `all: true` fail with `invalid`; a store that is not persistent (a private tab's, the session's proxy store) is cleared whole for either. Cookies of sites the domain policy blocks are never cleared |
| `clipboard.read` / `clipboard.write` | per-tab virtual clipboard `{ items: [{ type, base64 }] }`. Meta+C, Meta+X and Meta+V run the engine's own Copy, Cut and Paste against it, so the page gets trusted `copy`, `cut` and `paste` events with `clipboardData` (every type), and the system clipboard is neither read nor written. They run only in tabs a session created: in a user's tab `input.key` refuses them with `unsupported` before any key reaches the page. Until the engine reports the command done, a JavaScript dialog in that tab is answered as an unhandled one is (`dialog.respond` with `accept: false`) and reported with `dismissedDuring`, never held. On WebKit, which has no per-view pasteboard, the general-pasteboard lookups WebKit itself makes (its pasteboard IPC answered through WebCore) get a private pasteboard from the start of one command until WebKit reports it done or 5 s pass; lookups by any other code, `NSPasteboard.general` included, get the system pasteboard. The tab's clipboard takes the private pasteboard only when the command finished in time. At 5 s the driver ends the tab's web content process (`tab.crashed`) in the same main-thread turn that ends the redirect, and the call fails with `timeout`: WebKit handles no message from that process afterwards, so a Copy or Cut the page would finish late never writes the system clipboard. It ends the process only when every other tab in it was created by the same session and no popup window of cmux's shares it (popups share their opener's process); otherwise the shortcut falls back to script (the selection's text, or inserting the clipboard's text, without clipboard events). A session that detaches, or a tab that closes, during the command does not change that. If another tab or a popup window joins the process during a command, the private pasteboard stays until WebKit finishes or 5 s more pass, when the driver ends the process anyway (its pages crash). A caller that stops waiting shortens none of these times. A Paste also runs through WebKit only while the private pasteboard's change count is below the system's, so WebKit's read grant, which compares change counts, can never cover the system clipboard; otherwise it falls back to inserting text. Commands run one at a time across all tabs, because WebKit's pasteboard requests do not say which web view they serve, so two tabs' commands at once would share one private pasteboard. A command waits up to 5 s for the one before it, which ends by then (10 s when its process could not be ended at once), then gets its own 5 s; one that cannot start fails with `timeout`, names the tab it waited for, and does not run. While a command runs, another web view's paste or copy uses the private pasteboard too. Writes a page's own scripts make (the asynchronous Clipboard API, `execCommand("copy")`) are outside this redirect; the page clipboard guard (see "Guards") sends them to this clipboard |

## Guards

Agent code runs in the REPL's JavaScriptCore context, so the guards are
native (`BrowserReplBoundary` in the session, and the driver):

- Secrets: values stay in the session. `input.insertText { secret }` reaches
  the driver as `{ text, secretName, secretDomains }`; the driver types it
  only when the frame that holds the focused element has an origin
  (`WKFrameInfo.securityOrigin`, checked in the driver's own content world)
  matching one of `secretDomains`, else fails with `secret "x" may not be
  typed into <origin>; its domains are ...`. The check runs right before the
  text is committed, after the wait for the editor state (a page can move
  focus during that wait), and the marked text and insert follow on the
  same main-thread turn. A page can still move focus in its own web process
  between the check's last reply and the insert reaching that process:
  WebKit has no insert bound to an element or frame, so that cross-process
  window remains. Captures get `secretMasks
  [{ value, domains }]` (plain values, and the codes of a TOTP secret a
  server still accepts: the current window and one on each side); the
  driver masks only in frames on those domains.
  Results, events, fetch responses, output, errors and written text are
  redacted by the session.
- Domain policy: the session refuses `tab.navigate`/`tabs.open` to a blocked
  URL (`blocked`) and `session.configure` content rules, and calls the
  driver's `setDomainPolicy(policy)` (Swift only). The driver applies the
  policy's content rules to the tabs the session created, refuses reads and input (`frame.evaluate`,
  `input.*`, captures, clipboard, file chooser answers) on a tab that shows
  a blocked page, cancels main-frame navigations to blocked URLs in tabs
  the session created (`navigation.blocked`), and never navigates a user's
  tab away for the policy. When WebKit refuses to compile the policy's
  content rules, every driver call of the session fails with `invalid`
  (`the domain policy could not be applied: ...`) until the session sets a
  policy that compiles (a locked one needs a reset); the tabs keep the last
  rule list that compiled. The policy setters (`session.allowedDomains`
  and the like) return once the native session holds the policy, before
  WebKit compiles it, so the error reaches the agent on the session's next
  call.
- Page clipboard: in a tab a session created, no page script writes the
  system clipboard. An agent's click, key or evaluated script gives the
  page a user gesture, and WebKit lets a page holding one write the system
  clipboard through the asynchronous Clipboard API (WebKit's UI process
  writes it through `+[NSPasteboard generalPasteboard]`, also off the main
  thread) and through `execCommand("copy")` or `"cut"` (written by name,
  `+pasteboardWithName:`, while WebKit handles the web process's message).
  Neither message says which page sent it, so the pasteboard redirect
  cannot route them by tab, and WebKit has no setting that refuses
  `execCommand("copy")` to a page in a gesture. So once a session creates
  the tab (or a popup of one), the driver turns WebKit's
  `AsyncClipboardAPIEnabled` feature off for that web view (no
  `navigator.clipboard`, `Clipboard` or `ClipboardItem` in any of its
  documents, already-loaded ones included) and adds
  `Resources/browser-repl/page-clipboard.js` at document start in the page
  world of every frame. That script supplies a `navigator.clipboard` and
  `ClipboardItem` whose writes (a promised item once it settles) reach the
  tab's clipboard through a script message handler; they need no transient
  activation, since they reach only that tab and WebKit resets the page's
  activation after each script the driver evaluates, also between an agent
  click's press and release. It rejects their reads with `NotAllowedError`,
  and replaces `execCommand` so `copy` and `cut` fire the page's handlers with a
  `DataTransfer` and put what they set, or the selection, on the tab's
  clipboard; WebKit's own command never runs from page script there. The
  guard stays on the web view for its life, also after the session leaves
  (later writes then fail). Residual, measured on macOS 27.0 (26A428): WebKit
  gives user scripts to a document when it commits, not to a frame's
  initial empty document (an iframe whose `src` is still loading or is a
  `javascript:` URL, a window the page opened before its first load
  commits). Same-origin page script that reaches such a document while it
  holds a gesture can call that document's own `execCommand("copy")`, and
  WebKit writes the system clipboard.
- Cookies: the domain policy applies by host, since a cookie belongs to a
  host and not an origin (a pattern's scheme and port do not narrow it).
  `cookies.*` on a tab that shows a blocked page, and `cookies.get` or
  `cookies.set` with a blocked URL, fail with `blocked`. A cookie is in
  reach when a host an allowed pattern names receives it (its own domain
  or a parent domain) and its domain is not one a prohibited pattern
  names or, under `blockIPs`, an IP address; other cookies are left out of
  `cookies.get`, refused by `cookies.set` and never cleared.

## Capabilities

`driver.capabilities()` returns names the driver supports beyond this core:
`cdp`, `route` (request interception), `history` (browser history search),
`tabGroups`. The runtime exposes capability-gated APIs only when present and
otherwise throws the reference's own unsupported error text.

## Proposed changes (Swift driver)

### Native host contract (JavaScriptCore)

The app runs each REPL session in its own `JSContext` on a dedicated thread.
Before loading the runtime it installs one global, `__cmuxNative`. The runtime
(`repl-host.js`) builds `host`, timers, `fs`, `fetch` and `driver` on it. All
structured values cross the boundary as JSON strings.

| Member | Contract |
| --- | --- |
| `version` | `1` |
| `sessionId`, `cwd` | session name; absolute fs root: the CLI caller's cwd, or, when the request has none, a new directory of the session's own under the temporary directory (removed on close when empty). The app refuses `/`, the home directory and any directory containing it with an error telling the agent to `cd` to a project or scratch directory; `cmux browser repl mcp` sends no cwd when started in one of those |
| `capabilities` | array of driver capability names (`[]` on WebKit) |
| `print(level, text)` | append one output line; `level` is `log`, `info`, `warn`, `error` or `debug`; `text` is already formatted |
| `setTimer(id, delayMs, repeat)` / `clearTimer(id)` | on fire the app calls `globalThis.__cmuxHostOnTimer(id)`; repeating timers keep firing until cleared |
| `driverCall(callId, method, paramsJSON)` | the app later calls `globalThis.__cmuxHostOnResult(callId, errorJSON, resultJSON)`; exactly one of the two is `null`; `errorJSON` is `{ code, message }` |
| `fetch(callId, requestJSON)` | request `{ url, method, headers: [[k, v]], bodyBase64?, targetId?, credentials?, origin? }`; result via `__cmuxHostOnResult`: `{ url, status, statusText, headers: [[k, v]], bodyBase64, redirected }`. Cookies come from, and `Set-Cookie` goes back to, the attached tab's cookie store, for `credentials` `include` (default) always, `same-origin` only for URLs on `origin`, `omit` never. The domain policy is checked on the URL and every redirect hop (`blocked`); a body over 64 MiB fails; the session redacts the URL, headers and a text body |
| `secrets(op, argsJSON)` | synchronous, `{"ok": value}` or `{"error": {code, message}}`: `set { name, value, domains, totp }`, `load { path }` (read natively) or `load { object }`, `list`, `has { name }`, `delete { name }`, `clear`. No result holds a value |
| `policy(op, argsJSON)` | synchronous, as `secrets`: `get` → `{ allowed, prohibited, blockIPs, locked }`, `check { url }` → reason or `null`, `site { host }` → the host's site (registrable domain by the Public Suffix List, or the host itself when it has none), the same site `cookies.clear` scopes to, `set { allowed?, prohibited?, blockIPs?, lock?, title }` (a locked policy refuses) |
| `fs(op, argsJSON)` | synchronous; returns `{"ok": value}` or `{"error": {"code": "ENOENT"\|"EACCES"\|"EEXIST"\|"ENOTDIR"\|"EISDIR"\|"ENOTEMPTY"\|"EINVAL", "message"}}` |
| `readResource(relativePath)` | text of a bundled `Resources/browser-repl/` file, or `null` |
| `tmpdir`, `homedir` | canonical temporary and home directories, for `node:os` |

`fs` ops, paths relative to `cwd` (absolute paths must stay inside `cwd` or
the user's temporary directory, except files the driver reported through
`download.finished`, which are readable): `readFile {path}` → base64, `writeFile {path, base64, append?}`,
`mkdir {path, recursive?}`, `readdir {path}` → `[{ name, type }]`,
`stat {path}` → `{ size, type: "file"|"directory"|"symlink"|"other", mtimeMs, birthtimeMs }`,
`lstat {path}` (as `stat`, for the link itself), `rm {path, recursive?, force?}`,
`rename {from, to}`, `copyFile {from, to}`, `exists {path}` → boolean,
`resolve {path}` → absolute path. `rm` refuses `cwd` and the temporary
directory themselves.

Symbolic links follow Node. `rm`, `rename` and `lstat` act on the link itself
and check only that its parent directory is inside a root, so a link pointing
outside can be removed, moved or described; `rm` of a link to a directory
never touches the directory. Every other op reads or writes through the link
and checks where it points, so such a link is never followed out of the
roots, and a dangling link is refused for writing. `readdir` reports a link as
`symlink`. `rename` uses `rename(2)` and `copyFile` copies to a temporary
file beside the destination before renaming it into place, so an existing
destination stays intact until the new file is complete.

Entry points the runtime defines, called by the app:

- `__cmuxReplEval(code)` returns a Promise; the app awaits it with the eval
  timeout (120 s by default). Rejection is an uncaught error; the
  app formats it with `__cmuxFormatError(error)` when defined, else
  `error.stack ?? String(error)`, and the CLI exits 1. At the timeout the
  app answers the caller at once; a script still running is terminated
  (`JSContextGroupSetExecutionTimeLimit`), then `__cmuxReplCancel(message)`
  settles the cell so the next one runs.
- The runtime (`repl-host.js`) keeps `__cmuxNative` in its closures and
  deletes the global before any cell runs; the entry points above are
  non-writable.
- `__cmuxHostOnEvent(name, payloadJSON)` delivers every driver event.
- `__cmuxHostOnTimer(id)`, `__cmuxHostOnResult(callId, errorJSON, resultJSON)`.

Script load order: `manifest.json` in `Resources/browser-repl/`,
`{ "repl": [...], "agent": [...] }`, paths relative to that directory. `repl`
scripts run in order in the REPL context; `agent` scripts install in order in
the agent world. A missing or malformed manifest, or a listed file that does
not exist, fails the evaluation with an error naming the path; nothing is
skipped. `cmux browser repl guide` prints `guide.md` from the same directory
when present.

### Agent world

- The world is `WKContentWorld.world(name: "cmux-agent")`. Scripts are added to
  a tab's `WKUserContentController` (document start, all frames) when a
  session first touches the tab; frames that loaded earlier get the scripts on
  the first `frame.evaluate`.
- `frame.evaluate` sends `source` as `(<source>)(...args)` through
  `callAsyncJavaScript`, so `awaitPromise` is always true on WebKit.
- `frameId` values are opaque strings. `null`/omitted means the main frame.
- The agent is installed with the recipe in `page-agent.js` and found at
  `globalThis[Symbol.for("cmux.browserRepl.agent")]`; `input.setFiles`
  resolves the handle there, assigns files with `DataTransfer` and dispatches
  `input` and `change`.
- `frame.evaluate` with `world: "page"` and `handles`: handles live in the
  agent world, so the driver moves them through the DOM. The page world
  registers a one-off capturing listener for a random event type, the agent
  world dispatches that event on each element, and the page world reads the
  targets, then runs `source`. Detached elements fail with `stale`.
- Evaluation errors carry `{ code, message, errorName }`; page exceptions use
  code `evaluation`.
- `tab.info` answers from native state (URL, title, `isLoading`) while a
  JavaScript dialog is open, since page script is blocked then.
- `frameId` is WebKit's frame handle id (`-[WKFrameInfo _handle].frameID`);
  frames come from `-[WKWebView _frames:]`.
- Network events come from `-[WKWebView _setResourceLoadDelegate:]`; without
  that SPI no `request`/`response` events are sent.

## Proposed changes (runtime)

Needs found while building `Resources/browser-repl` against the `dev` driver.
The dev driver implements all of them.

- `frame.contentFrame { targetId, frameId, element }` returns `{ frameId }` of
  the frame an `<iframe>` agent handle hosts, or `null`. The runtime uses it
  for frame locators, DOM-order frame prefixes and snapshot stitching. Without
  it the runtime falls back to matching the iframe's content box against each
  child's `frame.ownerBox`, which fails for overlapping or hidden frames.
- `frame.contentFrames { targetId, frameId, elements: [handle] }` returns one
  `{ frameId }` or `null` per handle, in order: every iframe of a frame in one
  call. Snapshots use it; without it (`unsupported`) they call
  `frame.contentFrame` per iframe.
- Frame calls must not cost a frame-tree walk each. The app's driver keeps
  one tree read per tab (`BrowserReplFrameRegistry`), finds a frame by id
  without a read, and gives callers that need the current tree
  (`frames.list`, `frame.contentFrame(s)`, `frame.ownerBox`) a read that starts
  after their request, shared with concurrent callers.
- `frame.evaluate` takes `handles: [agentHandleId]`. The driver resolves them
  to elements in the target world and passes them before `args`, so
  `locator.evaluate` and `evaluateAll` run user functions in the page world on
  elements the agent world found. On WebKit this needs a cross-world lookup,
  for example through `__cmuxPageAgent.resolveHandle`.
- `tab.info` must answer while a JavaScript dialog is open (page script is
  blocked then): return the last known `title` and `loadState`. `loadState`
  is `commit`, `domcontentloaded` or `load`; the runtime polls it for
  `waitForLoadState` and `waitForURL`.
- An `input.mouse` `up` that opens a dialog may stay pending until
  `dialog.respond`; events such as `dialog.opened` must still arrive while
  the call is pending, because the runtime answers dialogs from them.
- `input.key` carries the resolved `key` (`C` for Shift+KeyC), `code`,
  `location`, and `text` only when the key inserts text (none while Meta,
  Control or Alt is held).
- The page agent exposes `globalThis[Symbol.for("cmux.browserRepl.agent")]`
  and `globalThis.__cmuxPageAgent.resolveHandle(id)`, both non-enumerable.
  Handle ids are strings (`h12`), stable per element for the document's life.
- Host: `importModule(specifier)` is optional (absent in the app).
  `fetchHandlesCookies` is implied by the native `fetch` contract, so the
  runtime does not add a `Cookie` header itself there.
