# Browser driver protocol

The contract between the REPL runtime (JavaScript, engine-neutral) and an engine
driver. The runtime builds the Aside and ChatGPT APIs on these primitives the
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
| `tabs.list` | | `[{ targetId, title, url, active, windowId, openerTargetId? }]` in window order |
| `tabs.open` | `{ url?, background? }` | `{ targetId }`; resolves after commit of `url` |
| `tabs.close` | `{ targetId, runBeforeUnload? }` | |
| `tabs.activate` | `{ targetId }` | |
| `tab.navigate` | `{ targetId, url, waitUntil: "commit"\|"domcontentloaded"\|"load"\|"networkidle", timeoutMs }` | `{ url, status? }` |
| `tab.history` | `{ targetId, delta: -1\|1, waitUntil, timeoutMs }` | `{ url }`, or `null` when no entry |
| `tab.reload` | `{ targetId, waitUntil, timeoutMs }` | |
| `tab.info` | `{ targetId }` | `{ url, title, loadState, viewport: { width, height }, deviceScaleFactor }` |
| `tab.setViewport` | `{ targetId, width, height }` or `{ targetId, reset: true }` | |
| `tab.bringToFront` | `{ targetId }` | |
| `tab.keep` | `{ targetId }` | |
| `session.name` | `{ name }` | |

Tabs the session opened (`tabs.open`, popups) close when the session ends;
`tab.keep` releases one so it stays open. `session.name` labels the tabs the
session opened, now and later, with an automatic tab title; a title the user
set is kept. An empty name stops labeling new tabs.

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
| `input.insertText` | `{ targetId, text }` (IME-style commit into the focused element) |
| `input.drag` | `{ targetId, path: [{ x, y }], button, modifiers }` (native drag session so HTML5 drag and drop fires) |

`modifiers` is an array of `Alt`, `Control`, `Meta`, `Shift`. Key names follow
Playwright (`KeyboardEvent.key` values plus `Meta+a` style parsed by the runtime).

## Capture

| Method | Params | Result |
| --- | --- | --- |
| `tab.screenshot` | `{ targetId, clip?, fullPage?, format: "png"\|"jpeg"\|"webp", quality? }` | `{ base64, width, height }` |
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
| `tab.navigated` | `{ frameId, url, sameDocument }` |
| `tab.loadState` | `{ state: "domcontentloaded"\|"load"\|"networkidle" }` |
| `dialog.opened` | `{ dialogId, type: "alert"\|"confirm"\|"prompt"\|"beforeunload", message, defaultValue }` (stays open until `dialog.respond`) |
| `filechooser.opened` | `{ chooserId, frameId, element, multiple }` (native panel suppressed while a REPL session is attached) |
| `download.started` | `{ downloadId, url, suggestedFilename }` |
| `download.finished` | `{ downloadId, path?, error? }` |
| `console` | `{ type, text, args?, location? }` |
| `pageerror` | `{ message, stack }` |
| `request` / `response` / `requestfailed` / `requestfinished` | `{ requestId, url, method, resourceType, status?, headers? }` |

## Browser state

| Method | Params |
| --- | --- |
| `cookies.get` / `cookies.set` / `cookies.clear` | `{ urls? }`, `{ cookies }`, `{}` |
| `clipboard.read` / `clipboard.write` | per-tab virtual clipboard `{ items: [{ type, base64 }] }` |

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
| `sessionId`, `cwd` | session name; absolute fs root (the CLI caller's cwd) |
| `capabilities` | array of driver capability names (`[]` on WebKit) |
| `print(level, text)` | append one output line; `level` is `log`, `info`, `warn`, `error` or `debug`; `text` is already formatted |
| `setTimer(id, delayMs, repeat)` / `clearTimer(id)` | on fire the app calls `globalThis.__cmuxHostOnTimer(id)`; repeating timers keep firing until cleared |
| `driverCall(callId, method, paramsJSON)` | the app later calls `globalThis.__cmuxHostOnResult(callId, errorJSON, resultJSON)`; exactly one of the two is `null`; `errorJSON` is `{ code, message }` |
| `fetch(callId, requestJSON)` | request `{ url, method, headers: [[k, v]], bodyBase64? }`; result via `__cmuxHostOnResult`: `{ url, status, statusText, headers: [[k, v]], bodyBase64, redirected }`. Cookies come from, and `Set-Cookie` goes back to, the attached tab's cookie store (`params.targetId` optional in the request) |
| `fs(op, argsJSON)` | synchronous; returns `{"ok": value}` or `{"error": {"code": "ENOENT"\|"EACCES"\|"EEXIST"\|"ENOTDIR"\|"EISDIR"\|"ENOTEMPTY"\|"EINVAL", "message"}}` |
| `readResource(relativePath)` | text of a bundled `Resources/browser-repl/` file, or `null` |
| `tmpdir`, `homedir` | canonical temporary and home directories, for `node:os` |

`fs` ops, paths relative to `cwd` (absolute paths must stay inside `cwd` or
the user's temporary directory, except files the driver reported through
`download.finished`, which are readable): `readFile {path}` → base64, `writeFile {path, base64, append?}`,
`mkdir {path, recursive?}`, `readdir {path}` → `[{ name, type }]`,
`stat {path}` → `{ size, type: "file"|"directory"|"symlink"|"other", mtimeMs, birthtimeMs }`,
`rm {path, recursive?, force?}`, `rename {from, to}`, `copyFile {from, to}`,
`exists {path}` → boolean, `resolve {path}` → absolute path. `rm` refuses
`cwd` and the temporary directory themselves.

Entry points the runtime defines, called by the app:

- `__cmuxReplEval(code)` returns a Promise; the app awaits it with the eval
  timeout (120 s by default). Rejection is an uncaught error; the
  app formats it with `__cmuxFormatError(error)` when defined, else
  `error.stack ?? String(error)`, and the CLI exits 1.
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
