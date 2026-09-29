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
