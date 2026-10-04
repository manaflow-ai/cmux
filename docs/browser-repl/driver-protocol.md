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
`unsupported`, `invalid`, `closed`, `blocked`, `denied`, `hibernated` and `crashed`
(see [Hibernated and crashed tabs](#hibernated-and-crashed-tabs), and
[Tabs](#tabs) for `denied`).

Coordinates are CSS pixels relative to the top-left of the tab's viewport
(main frame), matching Playwright `page.mouse` and screenshots at scale 1.

## Tabs

| Method | Params | Result |
| --- | --- | --- |
| `tabs.list` | `{ all? }` | `[{ targetId, title, url, active, windowId, state, dataStore, openerTargetId?, ownerSession? }]` in window order (`state`: `live`, `hibernated`, `waking` or `crashed`; listing never wakes a tab); with `all`, then the browser tabs of every other workspace and window (`windowId` names the workspace). Any listed tab is a valid `targetId` for the other methods except one with `ownerSession`: another running session created it, and it lists without `dataStore`. Tabs with equal `dataStore` (an opaque id, never reused for another store) share cookies and storage; a hibernated tab not yet loaded since a relaunch has none |
| `tabs.dataStore` | `{ targetId? }` | `{ dataStore }`: the store `cookies.get` uses with the same params |
| `tabs.open` | `{ url?, background?, dataStore? }` | `{ targetId }`; resolves after commit of `url`. With `dataStore`, the tab opens in that store (and the profile of a tab that uses it); one no tab this session may drive uses fails with `invalid` |
| `tabs.close` | `{ targetId, runBeforeUnload? }` | |
| `tabs.activate` | `{ targetId }` | |
| `tab.navigate` | `{ targetId, url, waitUntil: "commit"\|"domcontentloaded"\|"load"\|"networkidle", timeoutMs }` | `{ url, status? }` |
| `tab.history` | `{ targetId, delta: -1\|1, waitUntil, timeoutMs }` | `{ url }`, or `null` when no entry (the blank page a tab opened on is not an entry) |
| `tab.reload` | `{ targetId, waitUntil, timeoutMs }` | `{ status? }` |
| `tab.info` | `{ targetId }` | `{ url, title, state, loadState, viewport: { width, height }, deviceScaleFactor, webProcessId? }` |
| `tab.setViewport` | `{ targetId, width, height }` or `{ targetId, reset: true }` | |
| `tab.bringToFront` | `{ targetId }` | |
| `tab.keep` | `{ targetId }` | |
| `tab.handleEvents` | `{ targetId, events: ["dialog"\|"filechooser"\|"download"\|"network"] }` | Replaces the events this session has a handler for in the tab (`network`: a listener for `request`, `response`, `requestfailed` or `requestfinished`). See below. |
| `session.name` | `{ name }` | |
| `session.configure` | `{ userAgent?, extraHTTPHeaders?, permissions?, proxy? }`, each key replacing its value (`null` clears) | `{ proxy }`: whether tabs opened from now on use the proxy. Applies to the tabs the session created while it is attached (a user's tab it drives keeps its own user agent, headers and content), whichever session drives them; it is undone when the creating session leaves the tab. Content rules are not accepted here: the driver builds them from the session's domain policy (see "Guards") |
| `history.search` | `{ queries?, from?, to?, limit }` (times in ms since the epoch) | `[{ url, title, dateVisited }]` newest first, from the history of the profiles the workspace's tabs use |

Tabs the session opened (`tabs.open`, popups of those tabs) close when the session ends;
`tab.keep` releases one so it stays open.

A session drives the tabs it created and the user's tabs (tabs no running
session created, including one a finished session kept), never a tab another
running session created: every call that names such a tab (`targetId`),
including `tabs.close`, `tab.keep`, `tabs.dataStore`, cookie and clipboard
calls, fails with `denied` and a message that names the owning session and
its workspace, before the tab is attached, woken or touched. Its data store
does not list and `tabs.open({ dataStore })` does not accept it, and a
cookie call without `targetId` never falls back to it. Ownership is by
session instance: a session reset and created again under the same name is
another session, and the same name in another workspace is another session
too. Ownership ends with the creating session; the tab is the user's from
then on.

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

A dialog or file chooser the page opens while it handles a session's
`input.*` call, the first second of its page-world `frame.evaluate` (the
runtime's own agent-world reads hold nothing), its `tab.navigate`,
`tab.reload` or `tab.history` until the navigation commits, or while a call
wakes the tab,
is sent to that session too, also in a user's tab (the call caused it, so
cmux's own dialog or Open panel must not come up in front of the user, and
the call must not wait for an answer only the user can give); downloads
keep the user's location.

Each such event goes to one session, never to every session driving the
tab: a session with a handler for it in its last `tab.handleEvents` (the
creating session's first, then the session that registered first), else the
creating session of a tab a session created, else, for a dialog or file
chooser, the session whose call the page is handling. Only that session gets
`dialog.opened`, `filechooser.opened` and the download's `download.*` events,
and `dialog.respond` and `filechooser.respond` from any other session fail
with `not_found`, leaving the dialog or chooser open. When that session
leaves the tab, its open dialogs are dismissed and its choosers cancelled.

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

No driver method moves the user's focus or selection except
`tabs.activate` and `tab.bringToFront`, which select the tab in its pane
(`tabs.open` adds the tab behind the pane's selected tab), and
`auth.request`, whose sheet names the tab and workspace that ask. While
`input.key` runs, WebKit's request to move AppKit focus out of the page
(`_webView:takeFocus:`, Tab past the last control) is refused, so the focus
stays in the web view and the window's first responder stays the user's.
A key-down no page handles is not passed on: WebKit resends such a key
through `NSApp.sendEvent` to the key window (the user's terminal, menus), so
keys the REPL and `cmux browser press` send carry a mark (`eventSourceUserData`; the mobile browser stream's keys, a person's, do not) and the app
drops a marked key that arrives outside the web view's own delivery.

## Hibernated and crashed tabs

A tab a relaunch restored but no pane has shown yet lists as `hibernated`
too; the first call on it creates its browser, which then wakes the same
way. Every call with a `targetId` except `tabs.close`, `tab.keep`,
`tab.navigate` and `tab.history` first wakes a hibernated tab
(the driver starts the restore of the page cmux unloaded, off screen) and
waits, at most 30 s on the injected clock, until the restore commits and
the document reaches `DOMContentLoaded`. Then the call runs. On a crashed
tab (web content process ended, Reload offered in the pane) every call but
`tabs.close`, `tab.keep`, `tab.navigate`, `tab.reload`, `tab.history`,
`tab.info`, `tabs.activate`, `tab.bringToFront` and `tab.handleEvents`
fails at once. `tab.reload` on a crashed tab loads the page in a new web
content process (as the pane's Reload does) and waits for it like a wake;
on a hibernated tab the wake is the reload. A hidden tab whose process
ended is restored like a hibernated one. Errors, where `<tab>` is `tab <id> ("<title>", <url>)`:

| Condition | Code | Message |
| --- | --- | --- |
| Crashed | `crashed` | `<method>: <tab> crashed: its web content process ended (a WebKit crash, or macOS reclaimed its memory). Call page.reload() or page.goto(url) to load it again; until then only navigation, tab.info and page.close() work on it` |
| The user stopped the tab from loading | `hibernated` | `<method>: <tab> is hibernated (cmux unloaded it to save memory while it was hidden) and the user stopped it from loading, so cmux does not load it again on its own. Call page.reload() to load it, then retry` |
| The restore ended without a page | `hibernated` | `<method>: <tab> is hibernated (cmux unloaded it to save memory while it was hidden) and loading it again did not finish with a page. Call page.reload() to load it, then retry` |
| Still loading after 30 s | `timeout` | `<method>: <tab> was hibernated (cmux unloaded it to save memory while it was hidden) and did not load again within 30 s, so the call did not run. It is still loading: retry the call, or call page.reload()` |

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
| `input.drag` | `{ targetId, path: [{ x, y }], button, modifiers }` (native drag session so HTML5 drag and drop fires). The drag's data goes to a private pasteboard of that drag, never the system's named drag pasteboard: around each move that may start the drag, WebKit's lookups of the drag pasteboard get the private one until WebKit starts the drag, the move is handled or 5 s pass. One drag holds that window at a time across all tabs (WebKit's lookups do not say which web view they serve); a move that cannot get it within 5 s fails with `timeout` and is not delivered. A drag WebKit starts after its window closed drops no data. A person's drag in another web view during the window gets the private pasteboard too |

`modifiers` is an array of `Alt`, `Control`, `Meta`, `Shift`. Key names follow
Playwright (`KeyboardEvent.key` values plus `Meta+a` style parsed by the runtime).

When sessions share a tab, a session's `input.mouse` `down` owns the pointer
until its `up` (or until the session leaves the tab), and an `input.drag`
owns it from its press to its release; another session's `input.mouse` or
`input.drag` waits meanwhile, at most 10 s, then fails with `timeout`
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
| `tab.replaced` | (cmux gave the tab a new web view: it restored a page it had unloaded to save memory, or recovered a crashed one; frame ids and element handles from before are gone) |
| `tab.navigated` | `{ frameId, url, sameDocument }` |
| `navigation.blocked` | `{ url, reason }`: the driver cancelled a main-frame navigation of a tab the session created because the domain policy blocks `url` |
| `tab.loadState` | `{ state: "domcontentloaded"\|"load"\|"networkidle" }` |
| `dialog.opened` | `{ dialogId, type: "alert"\|"confirm"\|"prompt"\|"beforeunload", message, defaultValue, dismissedDuring? }` (stays open until `dialog.respond`; with `dismissedDuring: "copy"\|"cut"\|"paste"` it opened during that clipboard command and is already dismissed) |
| `filechooser.opened` | `{ chooserId, frameId, element, multiple }` (the native panel is not shown; see `tab.handleEvents` for which tabs send it) |
| `download.started` | `{ downloadId, url, suggestedFilename }` |
| `download.finished` | `{ downloadId, path?, error? }` |
| `console` | `{ type, text, args?, location? }` |
| `pageerror` | `{ message, stack }` |
| `request` / `response` / `requestfailed` / `requestfinished` | `{ requestId, url, method, resourceType, status?, headers? }`. Sent only to the tab's creating session, to a session whose last `tab.handleEvents` for the tab names `network`, and to the session whose call the page was handling when the request started (the rest of that request's events follow it). Only the creating session gets the credential headers (`cookie`, `set-cookie`, `authorization`, `proxy-authorization`, `x-api-key`, `x-auth-token`, `x-csrf-token`, `x-xsrf-token`); the others get the headers without them |

## Browser state

| Method | Params |
| --- | --- |
| `cookies.get` / `cookies.set` | `{ urls?, targetId? }`, `{ cookies, targetId? }`. They use the store of the target tab (a private tab's, or the session's proxy store, is not the user's profile), which the runtime names on every call a page makes; without `targetId`, the session's `session.configure({ proxy })` store, else the active tab's. A URL the domain policy blocks fails with `blocked`; `cookies.get` leaves out the cookies of blocked sites and `cookies.set` refuses one, and also refuses a cookie with a Domain attribute (`.example.com`) unless an allowed pattern covers every subdomain it reaches (`*.example.com`) and no prohibited host is among them (see "Guards") |
| `cookies.clear` | `{ targetId?, all?, name?, domain?, path? }`. Deletes the cookies of the target tab's store (without `targetId`, the store `cookies.get` uses) on that tab's site, its registrable domain by the system's Public Suffix List (CFNetwork), and the site's subdomains, narrowed by exact `name`, `domain` and `path`. The driver takes the site from the tab; a `site` parameter is ignored. On a persistent profile (the user's cookies) a tab with no http(s) site and `all: true` fail with `invalid`; a store that is not persistent (a private tab's, the session's proxy store) is cleared whole for either. Cookies of sites the domain policy blocks are never cleared |
| `clipboard.read` / `clipboard.write` | per-tab virtual clipboard `{ items: [{ type, base64 }] }`, emptied when the session that created the tab ends, so a session that drives a kept tab later never reads what the creator put there. Meta+C, Meta+X and Meta+V run the engine's own Copy, Cut and Paste against it, so the page gets trusted `copy`, `cut` and `paste` events with `clipboardData` (every type), and the system clipboard is neither read nor written. They run only in tabs a session created: in a user's tab `input.key` refuses them with `unsupported` before any key reaches the page. Until the engine reports the command done, a JavaScript dialog in that tab is answered as an unhandled one is (`dialog.respond` with `accept: false`) and reported with `dismissedDuring`, never held. On WebKit, which has no per-view pasteboard, the general-pasteboard lookups WebKit itself makes (its pasteboard IPC answered through WebCore) get a private pasteboard from the start of one command until WebKit reports it done or 5 s pass; lookups by any other code, `NSPasteboard.general` included, get the system pasteboard. The tab's clipboard takes the private pasteboard only when the command finished in time. At 5 s the driver ends the tab's web content process (`tab.crashed`) in the same main-thread turn that ends the redirect, and the call fails with `timeout`: WebKit handles no message from that process afterwards, so a Copy or Cut the page would finish late never writes the system clipboard. It ends the process only when every other tab in it was created by the same session and no popup window of cmux's shares it (popups share their opener's process); otherwise the shortcut falls back to script (the selection's text, or inserting the clipboard's text, without clipboard events). A session that detaches, or a tab that closes, during the command does not change that. If another tab or a popup window joins the process during a command, the private pasteboard stays until WebKit finishes or 5 s more pass, when the driver ends the process anyway (its pages crash). A caller that stops waiting shortens none of these times. A Paste also runs through WebKit only while the private pasteboard's change count is below the system's, so WebKit's read grant, which compares change counts, can never cover the system clipboard; otherwise it falls back to inserting text. Commands run one at a time across all tabs, because WebKit's pasteboard requests do not say which web view they serve, so two tabs' commands at once would share one private pasteboard. For the same reason a copy in another web view during a command (a person's, or a page's in a user's tab) reaches the private pasteboard; WebKit's own Copy or Cut writes it at most once and a Paste never, so a command whose pasteboard was written more often fails with `stale` and leaves the tab's clipboard unchanged (the one copy it cannot tell apart is the only write of a Copy or Cut whose page cancelled the event and set no data). A person's paste in another web view during a command still reads the private pasteboard. Items that name a local file (a file URL, also a `file:` URL as `text/uri-list` or another URL type, a filename list, an alias, a Finder node or a file promise) are left out when the tab's clipboard is put on the private pasteboard for a Paste, so WebKit never hands the page a local file. A command waits up to 5 s for the one before it, which ends by then (10 s when its process could not be ended at once), then gets its own 5 s; one that cannot start fails with `timeout`, names the tab it waited for, and does not run. While a command runs, another web view's paste or copy uses the private pasteboard too. Writes a page's own scripts make (the asynchronous Clipboard API, `execCommand("copy")`) are outside this redirect; the page clipboard guard (see "Guards") sends them to this clipboard |

## Guards

Agent code runs in the REPL's JavaScriptCore context, so the guards are
native (`BrowserReplBoundary` in the session, and the driver):

- Secrets: values stay in the session. `input.insertText { secret }` reaches
  the driver as `{ text, secretName, secretDomains }`; the driver types it
  only when the document that holds the focused element has an origin
  matching one of `secretDomains`, else fails with `secret "x" may not be
  typed into <origin>; its domains are ...`. The origin is read in the
  driver's own content world by the same evaluation that finds the focus,
  in that document (its own origin, `null` when opaque), not from
  WebKit's frame tree, which keeps naming a frame's old document after it
  navigates. The check runs right before the
  text is committed, after the wait for the editor state (a page can move
  focus during that wait), and the marked text and insert follow on the
  same main-thread turn. A page can still move focus in its own web process
  between the check's last reply and the insert reaching that process:
  WebKit has no insert bound to an element or frame, so that cross-process
  window remains. Captures get `secretMasks
  [{ value, domains }]` (plain values, and the codes of a TOTP secret a
  server still accepts: the current window and one on each side); the
  driver masks only in frames whose document's origin is on those
  domains, and refuses the capture (`invalid`) when masking fails in one
  of them or a scan after the capture finds a value rendered unmasked.
  A frame keeps its id when it navigates, so the mask goes by documents:
  before the capture the driver marks every frame's document in its own
  content world and reads the origin there, masks only in a document
  that still holds the mark, and refuses the capture when, after it, any
  frame shows a document without the mark (it showed another page
  meanwhile).
  Results, events, fetch responses, output, errors, written files and
  files read back are redacted by the session. Another session that drives the same tab
  (`tabs.use`) does not hold the secret, so the driver remembers each value
  it typed, by tab, typing session and secret name, from when the domain
  check passes, before it types, until the tab closes (a value the check
  refuses is never remembered; sessions whose secrets share a name keep
  separate values), and masks it as typed, `<secret:name>`, in every result,
  event and error it returns to any other session, and in their captures;
  once the typing session ends, also for a later session of the same name.
  A TOTP secret's typed value is its code, masked as that literal.
  This masks the value as typed and in the encodings the session's
  redaction knows; page script that copies it elsewhere or transforms it
  is outside it, as it is within one session.
- Domain policy: the session refuses `tab.navigate`/`tabs.open` to a blocked
  URL (`blocked`) and `session.configure` content rules, and calls the
  driver's `setDomainPolicy(policy)` (Swift only). The driver applies the
  policy's content rules to the tabs the session created, refuses reads and input (`frame.evaluate`, `auth.request`,
  `frame.contentFrame(s)`, `input.*`, captures, clipboard, file chooser
  answers) on a tab that shows a blocked page, cancels main-frame
  navigations to blocked URLs in tabs the session created
  (`navigation.blocked`), and never navigates a user's tab away for the
  policy. It also judges every frame, not only the main frame, by WebKit's
  record of it (`WKFrameInfo.securityOrigin` and URL) and by its document
  (`location.origin` and `location.protocol + "//" + location.host`, read
  in the driver's own content world; `location` cannot be forged by page or
  agent script). Script the driver runs in a frame (`frame.evaluate` and
  the calls built on it, `frames.list` names, `frame.ownerBox`) first checks
  in the frame that the document is one the driver approved, and runs
  nothing in another: a frame keeps its id when it navigates, so a frame
  looked up from an earlier tree read is judged again. A frame that shows a
  blocked page fails with `blocked` (`snapshot()` marks its iframe
  `[not read: blocked by the domain policy]`). On a fresh tree read the
  driver refuses `input.mouse` and `input.drag` at a point inside the box
  of the main frame's child frame that is or holds a blocked frame (overlap
  is not subtracted, and a blocked frame whose box it cannot find refuses
  every point), `input.key` and `input.insertText` while a blocked frame
  holds the focus (its document has it or holds a focused element, or its
  parent's focused element is its frame; a frame that cannot answer counts
  as focused), PDFs while any frame shows a blocked page, and file
  chooser answers other than `cancel` when the chooser's own frame (as
  WebKit recorded it when the chooser opened, and the document it shows
  now) is blocked. A screenshot blanks, in gray, the box of each main-frame
  child frame that is or holds a blocked frame, as the tree is before and
  after the capture, and shows the rest of the page; it is refused when
  the main frame is blocked or a blocked frame's content cannot be hidden
  that way (its box is unknown, its frame element or an ancestor has
  `-webkit-box-reflect` or `filter`, or an element of the page has
  `backdrop-filter`). When a capture is prepared, the driver marks each
  frame's document in its own content world and judges the document it
  marked, the one the capture shows (a frame can navigate after the tree
  read): a PDF is refused while any marked document is blocked; a
  screenshot is refused while the main frame's is, and blanks every child
  frame whose marked document is blocked like the tree's blocked frames
  (it is refused when such a frame is missing from the tree read before
  the capture). The capture is refused when a frame shows another
  document after it. Child frames are matched to their elements through
  `window.frames`, which leaves out frames in shadow trees, so while the
  main frame has a frame in a shadow tree every box counts as unknown. In tabs the session created the content rules keep a
  blocked frame from loading at all; its empty frame belongs to the parent
  and refuses nothing. The page can still move a frame or the focus in its
  own web process between the check and the input reaching it. Each of
  these checks' own scripts (a frame's document, its focus, the frame
  boxes), each capture mask script (mark, mask, check, restore) and each
  focus probe of a secret's typing check must answer within 5 s, or the
  call fails with `stale`: WebKit
  drops a script's completion when a navigation replaces its document, and
  a busy page answers late.
- Page-opened windows: a window a page opens from a user's tab, also one
  a session drives, goes to the browser's own popup handling and never to
  a session, so no session adopts it or closes it when it ends, except one
  it opens while it handles a session's own call (as for dialogs above):
  the browser's path would put a key popup window over the user's work,
  out of the agent's reach, so that window becomes a background tab sent
  to that session alone (`tab.created` with `userOwned: true`), under the
  URL checks below with that session's policy, and stays the user's: it is
  neither labelled nor closed when the session ends. Any other window the
  page of a driven tab opens through the browser's path while the user is
  not working in that tab (it is not shown and focused in the key window
  of the active app) opens as a background tab, told to no session, never
  as a key popup window. A window
  a page opens from a tab a session created becomes a popup tab through
  cmux's own navigation, which trusts local files and cmux's internal
  schemes, and the page controls its URL. So it goes to the sessions
  (`tab.created`) only when it is an `http`, `https`, `about:blank` or
  `blob:` (of such an origin) page that the browser's URL allowlist and
  the creating session's domain policy allow; otherwise it opens nothing. When WebKit refuses to compile the policy's
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
  `AsyncClipboardAPIEnabled` feature off for that web view (`tabs.open`
  fails with `unsupported` on a WebKit without that switch, and a web view
  where it does not take gets an empty document with no script; no
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
  WebKit writes the system clipboard. No fix is known within WebKit's API:
  `WKUserScript` has no option to match such documents (its private
  initializers take URL patterns, an associated URL, a content world and
  deferral only), no WebKit preference refuses `execCommand("copy")` to a
  page in a gesture (`JavaScriptCanAccessClipboard` only widens it), no UI
  delegate method is called for a page's copy, and the UI process's
  pasteboard write runs in a handler whose only per-page argument (the IPC
  connection) no Objective-C hook can see, so the redirect cannot route it
  by page or process.
- Cookies: the domain policy applies by host, since a cookie belongs to a
  host and not an origin (a pattern's scheme and port do not narrow it).
  `cookies.clear` on a tab that shows a blocked page (its scope is that
  tab's site), and `cookies.get` or `cookies.set` with a blocked URL, fail
  with `blocked`. The runtime names the page's tab on every cookie call,
  and `cookies.get` and `cookies.set` use it only to pick the tab's data
  store, so a page showing a blocked site still sets and reads the
  cookies the policy allows. A cookie is in
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
| `print(level, text)` | append one output line; `level` is `log`, `info`, `warn`, `error` or `debug`; `text` is already formatted. An evaluation keeps at most 16 MiB of lines; the rest goes to `<tmpdir>/output-<evalId>.txt`, announced by a `# output continues in <path>` line and summed up by a last `# output truncated: …; full output: <path>` line |
| `setTimer(id, delayMs, repeat)` / `clearTimer(id)` | on fire the app calls `globalThis.__cmuxHostOnTimer(id)`; repeating timers keep firing until cleared, each fire `delayMs` after the previous callback ran, so a busy thread holds at most one queued callback per timer. `setTimer` returns `false`, scheduling nothing, when the session already has 10,000 timers scheduled or fired with their callback not yet run; the runtime's `setTimeout` then throws a `RangeError` |
| `driverCall(callId, method, paramsJSON)` | the app later calls `globalThis.__cmuxHostOnResult(callId, errorJSON, resultJSON)`; exactly one of the two is `null`; `errorJSON` is `{ code, message }` |
| `fetch(callId, requestJSON)` | request `{ url, method, headers: [[k, v]], bodyBase64?, targetId?, credentials?, origin? }`; result via `__cmuxHostOnResult`: `{ url, status, statusText, headers: [[k, v]], bodyBase64, redirected }`. Cookies come from, and `Set-Cookie` goes back to, the attached tab's cookie store (a cookie goes to a URL its domain matches and whose path its path matches by RFC 6265, so a `/account` cookie never goes to `/accounting`), for `credentials` `include` (default) always, `same-origin` only for URLs on `origin`, `omit` never. The domain policy is checked on the URL and every redirect hop (`blocked`); a body over 64 MiB fails; a session runs at most 16 fetches at once and queues the rest in order; when a cell times out, the fetches it started are cancelled and its queued ones fail with `cancelled`; the session redacts the URL, headers and the body (UTF-8 text as text; other bytes by each value's UTF-8 and escaped bytes, and its percent-encoded and Base64 forms) |
| `secrets(op, argsJSON)` | synchronous, `{"ok": value}` or `{"error": {code, message}}`: `set { name, value, domains, totp }`, `load { path }` (read natively) or `load { object }`, `list`, `has { name }`, `delete { name }`, `clear`. No result holds a value |
| `policy(op, argsJSON)` | synchronous, as `secrets`: `get` → `{ allowed, prohibited, blockIPs, locked }`, `check { url }` → reason or `null`, `site { host }` → the host's site (registrable domain by the Public Suffix List, or the host itself when it has none), the same site `cookies.clear` scopes to, `set { allowed?, prohibited?, blockIPs?, lock?, title }` (a locked policy refuses) |
| `fs(op, argsJSON)` | synchronous; returns `{"ok": value}` or `{"error": {"code": "ENOENT"\|"EACCES"\|"EEXIST"\|"ENOTDIR"\|"EISDIR"\|"ENOTEMPTY"\|"EINVAL", "message"}}` |
| `readResource(relativePath)` | text of a bundled `Resources/browser-repl/` file, or `null` |
| `tmpdir`, `homedir` | the session's private temporary directory (`<app temp>/cmux-browser-repl/<session>-<random>-tmp`, mode 0700, removed on close when empty; no other session's files are in it) and the canonical home directory, for `node:os` |

`fs` ops, paths relative to `cwd` (absolute paths must stay inside `cwd` or
the session's own `tmpdir`, never the system temporary directory that other
sessions and apps share, except files the driver reported through
`download.finished`, which are readable): `readFile {path}` → base64 (secrets redacted, text or bytes), `writeFile {path, base64, append?}`,
`mkdir {path, recursive?}`, `readdir {path}` → `[{ name, type }]`,
`stat {path}` → `{ size, type: "file"|"directory"|"symlink"|"other", mtimeMs, birthtimeMs }`,
`lstat {path}` (as `stat`, for the link itself), `rm {path, recursive?, force?}`,
`rename {from, to}`, `copyFile {from, to}`, `exists {path}` → boolean,
`resolve {path}` → absolute path. `rm` refuses `cwd` and `tmpdir`
themselves.

Symbolic links follow Node. `rm`, `rename` and `lstat` act on the link itself
and check only that its parent directory is inside a root, so a link pointing
outside can be removed, moved or described; `rm` of a link to a directory
never touches the directory. Every other op reads or writes through the link
and checks where it points, so such a link is never followed out of the
roots, and a dangling link is refused for writing. `readdir` reports a link as
`symlink`. `rename` uses `rename(2)` and `copyFile` copies to a temporary
file beside the destination before renaming it into place, so an existing
destination stays intact until the new file is complete.
Every `fs` operation of every session runs under one process-wide lock from
its path check to its last system call, so a session moving a link (agent
code cannot create one) never changes what another session's checked path
reaches.

Entry points the runtime defines, called by the app:

- `__cmuxReplEval(code)` returns a Promise; the app awaits it with the eval
  timeout (120 s by default). Rejection is an uncaught error; the
  app formats it with `__cmuxFormatError(error)` when defined, else
  `error.stack ?? String(error)`, and the CLI exits 1. At the timeout the
  app answers the caller at once; a script still running is terminated
  (`JSContextGroupSetExecutionTimeLimit`), then `__cmuxReplCancel(message)`
  settles the cell so the next one runs.
- The runtime (`repl-host.js`) keeps `__cmuxNative` in its closures and
  deletes the global, and its own `CmuxBrowserRepl` namespace, before any
  cell runs. Once the runtime has loaded, the app takes the entry points
  (above and below) and deletes their globals, so no cell can call them.
- Every call the app makes into the context (a cell, a driver result, a
  timer, an event, a cancel) is bounded, since agent code can start work
  outside a cell (timers, event handlers): one that starts while a cell
  runs ends at that cell's timeout; one that started outside a cell, or
  whose cell has ended, is terminated after 10 s. A cell runs from when
  the session's thread starts it, so a callback queued ahead of a
  submitted cell counts as outside a cell. After the session closes
  (`cmux browser repl reset`, idle expiry) every script is terminated and
  the app makes no further call into the context.
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
  it (`unsupported`) the runtime finds no frame for an iframe: matching the
  iframe's box against each child's `frame.ownerBox` would guess, and
  overlapping iframes share a box.
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
