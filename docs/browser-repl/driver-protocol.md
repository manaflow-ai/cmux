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
| `session.configure` | `{ userAgent?, extraHTTPHeaders?, permissions?, proxy? }`, each key replacing its value (`null` clears) | `{ proxy }`: whether tabs opened from now on use the proxy (a private data store whose connections go through it). The proxy ends with the session: a tab it kept, and any tab opened from one on that store, keep the store's cookies and storage but go back to the browser's own proxy settings. Applies to the tabs the session created while it is attached (a user's tab it drives keeps its own user agent, headers and content), whichever session drives them; it is undone when the creating session leaves the tab. Content rules are not accepted here: the driver builds them from the session's domain policy (see "Guards") |
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

HTTP authentication: a driven tab answers a Basic, Digest or other HTTP
challenge from the user name and password a session gave in a `tab.navigate`
URL (`http://user:password@host/`), by host and port, instead of a prompt
nobody can answer. Those credentials are the giving session's alone: they
answer a challenge only while the page handles that session's own
navigation or input (a call of exactly one session in flight), or any
request of a tab that session created, never another session's request on
a tab both drive, and they are forgotten when the session leaves the tab.
WebKit gets them without persistence, so it does not keep them for the data
store that the profile's other tabs share. Without an answer, a tab a session
created fails the navigation with the challenge named; a user's tab keeps its
sign-in prompt.

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
drops a marked key that arrives outside the web view's own delivery. That
resend is also how a Command shortcut's Edit menu command (select all, copy,
cut, paste, undo, redo; bold, italic and underline in the REPL) is run: only
once WebKit has sent the key back (no page handled it; a page that cancels
the keydown gets no command as well), on the web view itself. In a tab a
session created and is attached to, `cmux browser press` Meta+C, Meta+X
and Meta+V run on the tab's clipboard as the REPL's do, never the system
pasteboard, under the same guards: the creating session's domain policy
refuses them while a frame it blocks holds the focus, before and after the
command (`BrowserReplFrameGate.guardingFocus`), and what Copy or Cut took
lands only while that session still holds the tab; a refused one changes
nothing (the press has already returned). In any other tab they run the
web view's own Copy, Cut and Paste. A key whose outcome WebKit has not reported within 5 s runs nothing.

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

Input to an element in a child frame goes to the tab at the element's point
plus each owner `<iframe>`'s content box, found in the parent frame's agent
world through the `<iframe>` element that `frame.contentFrame` confirms shows
the frame: the one a locator entered the frame through, else the one the
frame's own place in the parent's `window.frames` names. A frame in a shadow
tree is not listed there; its `<iframe>` is looked for in at most 250000
elements of the parent (the snapshot's node budget), and an action there
fails past it, so a page cannot make each action walk its whole DOM. That sum is where the frame's content is only when the `<iframe>`
and its ancestors (in the flat tree, through slots and shadow hosts) move it
by translations at most: when one of them has a scale, rotation, skew,
`zoom`, `perspective`, `offset-path` or an SVG drawing around it, the action
fails naming that element and style instead of sending input that could
reach another element or frame. Before the input, and again after the
pointer moves there, each parent frame must have the `<iframe>` itself at
the point; an element over it fails the check (`<div> intercepts pointer
events`), as in the target's own frame. `locator.boundingBox()` and element
screenshots in such a frame fail the same way. The runtime no longer calls
`frame.ownerBox`.

## Input

All input is delivered as native, trusted events (`isTrusted === true`).

| Method | Params |
| --- | --- |
| `input.mouse` | `{ targetId, type: "move"\|"down"\|"up"\|"wheel", x, y, button: "left"\|"right"\|"middle", clickCount, modifiers, deltaX?, deltaY? }` |
| `input.key` | `{ targetId, type: "down"\|"up", key, code, text?, location?, modifiers, autoRepeat? }` |
| `input.insertText` | `{ targetId, text }` or, from the runtime, `{ targetId, secret: name }`, which the native session turns into `{ targetId, text, secretName, secretDomains }` (see "Guards") (IME commit into the focused element. On WebKit a `contenteditable` editor gets marked text then its confirmation, so `compositionstart`, `beforeinput`/`input` and `compositionend` fire, trusted, and editors that start an edit only on a keydown or a composition (Google Sheets) take it; a form field gets a plain insert with one `input` event, as Chrome's `Input.insertText`; text with a line break or tab, or focus in an unreadable frame, inserts without a composition) |
| `input.drag` | `{ targetId, path: [{ x, y }], button, modifiers }` (native drag session so HTML5 drag and drop fires). The drag's data goes to a private pasteboard of that drag, never the system's named drag pasteboard: around each move that may start the drag, WebKit's lookups of the drag pasteboard get the private one until WebKit starts the drag, the move is handled or 5 s pass. One drag holds that window at a time across all tabs (WebKit's lookups do not say which web view they serve); a move that cannot get it within 5 s fails with `timeout` and is not delivered. A drag WebKit starts after its window closed drops no data. A person's drag in another web view during the window writes the private pasteboard too, but a drop there never reads it: the drop's access grant comes from AppKit calling WebKit, which diverts the window to an extra private pasteboard emptied at each lookup until it closes (the automated drag then carries no data) |

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
| `filechooser.respond` | `{ targetId, chooserId, files }` or `{ ..., cancel: true }`. The files are written to a temporary directory of the session (removed when it ends) only after the driver knows the chooser is open and routed to the calling session; an answer for another session's chooser or a closed one fails with `not_found` and writes nothing. At most 256 files and 256 MiB together, with distinct names, else `invalid` and nothing is written |
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
| `request` / `response` / `requestfailed` / `requestfinished` | `{ requestId, url, method, resourceType, status?, headers? }`. Sent only to the tab's creating session, to a session whose last `tab.handleEvents` for the tab names `network`, and to the session whose call the page was handling when the request started (the rest of that request's events follow it). Only the creating session gets the credential headers (`cookie`, `set-cookie`, `authorization`, `proxy-authorization`, `x-api-key`, `x-auth-token`, `x-csrf-token`, `x-xsrf-token`, and any whose name says it carries one); the others get the headers without them, and the `url` and URL-valued headers (`location`, `content-location`, `referer`, `refresh`, `link`) with the userinfo and each credential-named query or fragment parameter (that name rule, or `code`, `sig`, `key`, `jwt`, `otp`, `pass`, `pwd`, `sid`, `ticket`, `assertion`, `SAMLResponse`, `SAMLRequest`) reading `redacted` |

## Browser state

| Method | Params |
| --- | --- |
| `cookies.get` / `cookies.set` | `{ urls?, targetId? }`, `{ cookies, targetId? }`. They use the store of the target tab (a private tab's, or the session's proxy store, is not the user's profile), which the runtime names on every call a page makes; without `targetId`, the session's `session.configure({ proxy })` store, else the active tab's. A URL the domain policy blocks fails with `blocked`; `cookies.get` leaves out the cookies of blocked sites and `cookies.set` refuses one, and also refuses a cookie with a Domain attribute (`.example.com`) unless an allowed pattern covers every subdomain it reaches (`*.example.com`) and no prohibited host is among them (see "Guards") |
| `cookies.clear` | `{ targetId?, all?, name?, domain?, path? }`. Deletes the cookies of the target tab's store (without `targetId`, the store `cookies.get` uses) on that tab's site, its registrable domain by the system's Public Suffix List (CFNetwork), and the site's subdomains, narrowed by exact `name`, `domain` and `path`. The driver takes the site from the tab; a `site` parameter is ignored. On a persistent profile (the user's cookies) a tab with no http(s) site and `all: true` fail with `invalid`; a store that is not persistent (a private tab's, the session's proxy store) is cleared whole for either. Cookies of sites the domain policy blocks are never cleared |
| `clipboard.read` / `clipboard.write` | per-tab virtual clipboard `{ items: [{ type, base64 }] }`, held by the session that created the tab while it is attached: any other session, and every session in a user's tab (also a kept one), gets `unsupported`. It empties when that session ends, and a Copy or Cut still running then, or a page script's write after it, never lands, so a session that drives a kept tab later never reads what the creator or the page put there. Meta+C, Meta+X and Meta+V run the engine's own Copy, Cut and Paste against it, so the page gets trusted `copy`, `cut` and `paste` events with `clipboardData` (every type), and the system clipboard is neither read nor written. They run only in tabs a session created: in a user's tab `input.key` refuses them with `unsupported` before any key reaches the page. Until the engine reports the command done, a JavaScript dialog in that tab is answered as an unhandled one is (`dialog.respond` with `accept: false`) and reported with `dismissedDuring`, never held. On WebKit, which has no per-view pasteboard, the general-pasteboard lookups WebKit itself makes (its pasteboard IPC answered through WebCore) get a private pasteboard from the start of one command until WebKit reports it done or 5 s pass; lookups by any other code, `NSPasteboard.general` included, get the system pasteboard. The tab's clipboard takes the private pasteboard only when the command finished in time. At 5 s the driver ends the tab's web content process (`tab.crashed`) in the same main-thread turn that ends the redirect, and the call fails with `timeout`: WebKit handles no message from that process afterwards, so a Copy or Cut the page would finish late never writes the system clipboard. It ends the process only when every other tab in it was created by the same session and no popup window of cmux's shares it (popups share their opener's process); otherwise the shortcut falls back to script (the selection's text, or inserting the clipboard's text, without clipboard events). A session that detaches, or a tab that closes, during the command does not change that. If another tab or a popup window joins the process during a command, the private pasteboard stays until WebKit finishes or 5 s more pass, when the driver ends the process anyway (its pages crash). A caller that stops waiting shortens none of these times. A Paste also runs through WebKit only while the private pasteboard's change count is below the system's, so WebKit's read grant, which compares change counts, can never cover the system clipboard; otherwise it falls back to inserting text. Commands run one at a time across all tabs, because WebKit's pasteboard requests do not say which web view they serve, so two tabs' commands at once would share one private pasteboard. For the same reason a copy in another web view during a command (a person's, or a page's in a user's tab) reaches the private pasteboard; WebKit's own Copy or Cut writes it at most once and a Paste never, so a command whose pasteboard was written more often fails with `stale` and leaves the tab's clipboard unchanged. A Copy or Cut can also write nothing itself (its page cancels the event and sets no data, a Cut of text the page cannot edit), so its one write must be shown to be the page's own: before the command a listener in every frame of the tab, in a content world of its own, sees the trusted `copy` or `cut` event, notes whether WebKit's default action writes the selection, and puts a random marker type on the event's `clipboardData`, which WebKit writes with the page's data when the page cancels the event. A write that neither the default action nor a cancelled event carrying the marker accounts for (no listener saw the event, the page cleared the marker) fails the command with `stale`. The page sees the marker type in its handler, and a cancelled event's marker (a random value used once) stays among WebKit's custom data on the tab's clipboard. Another web view never reads the private pasteboard: a web content process reads the general pasteboard only after the UI process grants it access at the change count it looks up then, and a paste another web view starts (a person's Command-V, Edit menu or context menu Paste, a paste callout, a drop) makes that lookup from a call by the app into WebKit, while the commanded tab's reads and writes come on WebKit's own run-loop turn and its grant while the driver starts the command. Such a lookup, or WebKit's read of `+generalPasteboard` before it lets a page read its own origin's clipboard data without asking, diverts the command: from then until it ends every WebKit lookup gets an extra private pasteboard emptied at each lookup, so that other paste reads nothing and the command fails with `stale` (a Paste may have pasted nothing). A page's script paste in another web view (`execCommand("paste")` in a gesture) asks the UI process for that grant too: with its own origin's data on the tab's clipboard WebKit reads `+generalPasteboard` first, which diverts the command, and otherwise WebKit shows its paste callout, which only the person can answer. Residual: WebKit keeps one grant per pasteboard name, for the processes it granted at one change count, and a grant at an equal count is extended instead of replaced; a web content process granted during an earlier command or quarantine at a private pasteboard whose change count equals this command's keeps its grant, and a page there that reads without asking again (WebKit asks once per user gesture) could read the tab's clipboard while the command runs. Another page of the commanded tab's own web content process can too, which runs only tabs that session created. Items that name a local file (a file URL, also a `file:` URL as `text/uri-list` or another URL type, a filename list, an alias, a Finder node or a file promise) are left out when the tab's clipboard is put on the private pasteboard for a Paste, so WebKit never hands the page a local file. A command waits up to 5 s for the one before it, which ends by then (10 s when its process could not be ended at once), then gets its own 5 s; one that cannot start fails with `timeout`, names the tab it waited for, and does not run. While a command runs, another web view's copy uses the private pasteboard too. Writes a page's own scripts make (the asynchronous Clipboard API, `execCommand("copy")`) are outside this redirect; the page clipboard guard (see "Guards") sends them to this clipboard |

## Guards

Agent code runs in the REPL's JavaScriptCore context, so the guards are
native (`BrowserReplBoundary` in the session, and the driver):

- Domain patterns (the policy's `allowed` and `prohibited`, a secret's
  domains, `tools.register` domains): `example.com`, `*.example.com`,
  `https://example.com:8443` or `*`. Several wildcards, a wildcard
  top-level domain (`example.*`), an embedded wildcard and a wildcard over
  a public suffix of the system's Public Suffix List (`*.com`, `*.co.uk`,
  `*.github.io`) fail with `invalid`; a wildcard over a site
  (`*.example.co.uk`) and a public suffix named alone (`com`, one host)
  are accepted.

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
  A capture takes those masks before it waits for the page, so one during
  which another session recorded a value to type (in any tab) fails with
  `stale` instead of returning pixels that may show it.
  The driver hands those sessions the same values as a store
  (`typedSecretRedaction()`, Swift only), and each session masks them
  wherever it masks its own secrets: fetch responses (read with the tab's
  cookies), files written and read back (a page's download), output lines
  and errors.
  A TOTP secret's typed value is its code, masked as that literal.
  This masks the value as typed and in the encodings the session's
  redaction knows; page script that copies it elsewhere or transforms it
  is outside it, as it is within one session. Accepted by the threat
  model: a page on the secret's own allowed domain already holds the
  value, so it can hand it back transformed (hex, compressed, split
  across strings or lines, Base64 or percent-encoding applied once more)
  and redaction does not find it.
  A session holds at most 256 secrets (`secrets.set`, `secrets.load`;
  replacing one is not another) of at most 4 KiB with at most 64 domains
  each, refused with an error naming the limit. `secrets.delete`,
  `secrets.clear` and replacing a secret's value stop the old value from
  being typed or listed, but it stays masked (in text, files and captures)
  for the session's life, since the agent never saw it and its source (a
  secrets file) may still hold it; a session holds at most 1,024 distinct
  values over its life, current and retired, and a new one past that is
  refused until a reset. Each masking pass tries,
  at each position, only the values whose first byte can start there (the
  byte, or the first byte of the character an escape there stands for),
  and stops after comparing 64 bytes per byte of its input past a 1 MiB
  allowance; text it stops on is withheld, as text masking would grow by
  more than 8 MiB is, so values that share a long prefix cannot make
  masking quadratic.
- Local files: whatever the domain policy, the session refuses
  `tab.navigate`/`tabs.open` (`blocked`) to any URL but `http`, `https`,
  `about:`, `data:`, `blob:` and a `file:` URL of a file strictly inside
  the session's working or temporary directory, judged by the path as
  written (`..` resolved without the file system) and refused when a part
  of it below that directory is a symbolic link. The browser loads a file
  with read access to its directory, so a page could otherwise read files
  the session's `fs` cannot; cmux's internal schemes and `javascript:` are
  refused too. A string without a scheme that looks like a path (`/`, `~`,
  `.`) is refused.
- Domain policy: the session refuses `tab.navigate`/`tabs.open` to a blocked
  URL (`blocked`; a `blob:` URL is judged by the origin in it, and one of
  an opaque origin, `blob:null/...`, is blocked) and `session.configure`
  content rules, and calls the
  driver's `setDomainPolicy(policy)` (Swift only). The driver applies the
  policy's content rules to the tabs the session created, refuses reads and input (`frame.evaluate`, `auth.request`,
  `frame.contentFrame(s)`, `input.*`, captures, clipboard, file chooser
  answers) on a tab that shows a blocked page, cancels main-frame
  navigations to blocked URLs in tabs the session created
  (`navigation.blocked`), and never navigates a user's tab away for the
  policy. A navigation to `about:` (`about:blank`) or `data:`, or to a
  `blob:` of an opaque origin, takes its document from the frame that
  started it, so it is judged by that frame's document as WebKit recorded
  it (its source frame) and cancelled when the policy blocks that one; one
  no page started (the agent's own) passes. The content rules judge a
  `blob:` subresource or child frame by the origin in its URL. It also judges every frame, not only the main frame, by WebKit's
  record of it (`WKFrameInfo.securityOrigin` and URL) and by its document
  (`location.origin` and `location.protocol + "//" + location.host`, read
  in the driver's own content world; `location` cannot be forged by page or
  agent script). Script the driver runs in a frame (`frame.evaluate` and
  the calls built on it, `frames.list` names, `frame.ownerBox`) first checks
  in the frame that the document is one the driver approved, and runs
  nothing in another: a frame keeps its id when it navigates, so a frame
  looked up from an earlier tree read is judged again. A frame that shows a
  blocked page fails with `blocked` (`snapshot()` marks its iframe
  `[not read: blocked by the domain policy]`). A tree read can lack frames
  (WebKit gives no tree, or cannot describe a child): while the policy is
  on, input and captures fail with `stale` when the main frame's document,
  or that of a frame with a child WebKit could not describe, holds more
  child frames (`window.frames`, read in the driver's world) than the tree
  has under it, and a PDF when any child could not be described. On a
  fresh tree read the driver refuses `input.mouse` and `input.drag` at a point inside the box
  of the main frame's child frame that is or holds a blocked frame (overlap
  is not subtracted, and a blocked frame whose box it cannot find refuses
  every point), `input.key` and `input.insertText` while a blocked frame
  holds the focus (its document has it or holds a focused element, or its
  parent's focused element, also inside a shadow tree, is its frame element,
  found by the frame's own position in `window.frames`; a frame that cannot
  answer, or whose element cannot be told, counts as focused). Meta+C,
  Meta+X and Meta+V check the focus again after the key, on a fresh tree
  right before WebKit's Copy, Cut or Paste runs (the page's key handlers
  can move the focus into a blocked frame meanwhile), and Copy and Cut
  once more after it, before the tab's clipboard takes what they copied;
  either fails with `blocked` and leaves the tab's clipboard unchanged.
  The input itself is a point or a key for the whole tab, so the page could
  move a blocked frame under the point, or the focus into it, between a
  check and the event. While `input.mouse`, `input.drag`, `input.key` or
  `input.insertText` is checked and in flight, the driver makes the element
  of each blocked frame (without a blocked ancestor) `inert` in its parent,
  from its own content world: an inert element is not hit tested and takes
  no focus, wherever the page moves it. A blocked frame in a shadow tree
  cannot be told from its siblings there, so every frame element in that
  parent's shadow trees is inert meanwhile; a blocked frame in a closed
  shadow root, out of the driver's reach, refuses the input (`blocked`).
  After a key or inserted text the focus is checked again, still under the
  guard. The driver watches each guarded element's `inert` attribute from
  its own content world and puts it back as soon as the page takes it off:
  a mutation observer runs before the page's script returns control, so
  before WebKit handles the next event. From before the tree read until the
  guard comes off, no child frame of the tab loads a new document: the
  navigation delegate decides a child frame's navigation, and its response,
  only after the input (`BrowserReplSubframeLoadHold`). A frame the page creates meanwhile
  shows its initial empty document, which takes its parent's origin, and an
  allowed frame cannot navigate to a blocked page; main-frame navigations
  and new windows are not held. Then the guard comes off (an element the
  page made inert itself stays inert), and the call fails with `blocked`
  when the page changed a guarded element's `inert` attribute meanwhile.
  Residual: `inert` is an attribute of the page's DOM, so the page sees it.
  Within one event handler (for example the `keydown` of an agent's key) the
  page can take it off and move the focus into the blocked frame before the
  observer runs; the rest of that event (the key's text) may then reach the
  frame, and the call fails with `blocked` afterwards. A child-frame
  navigation whose response the app had already accepted when the hold began
  can still commit during the input (WebKit reports no child-frame commit to
  the app, so the driver cannot wait for it). An allowed frame that holds the point or the focus keeps
  receiving input while blocked frames are inert.
  A page script's write to the tab's clipboard (`page-clipboard.js`) from
  a frame the creating session's policy blocks, judged by WebKit's record
  of the frame that sent it, is rejected, so `clipboard.read` never hands
  the agent what a blocked frame wrote.
  The driver refuses PDFs while any frame shows a blocked page, and file
  chooser answers other than `cancel` when the chooser's own frame (as
  WebKit recorded it when the chooser opened, and the document it shows
  now) is blocked. A screenshot blanks, in gray, the box of each main-frame
  child frame that is or holds a blocked frame, as the tree is before and
  after the capture, and shows the rest of the page. While it is taken,
  each of those frame elements is also hidden from the driver's own world
  (`visibility: hidden` and `transition-property: none`, both `!important`
  in its style attribute, which no style sheet, animation or transition
  outranks), so a frame the page moves over other content and back within
  the capture draws nothing; the driver puts that style back as soon as the
  page changes it (before the next rendering) and refuses the capture
  (`blocked`) when it did. From before the tree read until after the
  capture (a PDF's too) no child frame loads a new document, so a frame the
  page creates, or an allowed one it navigates, shows no blocked page in
  it. The screenshot is refused when
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
  the creating session's domain policy allow; otherwise it opens nothing.
  An `about:blank` window (or one with no URL) takes the origin of the frame
  that opened it, which can write into it, so it opens only when the policy
  allows that frame's document as WebKit recorded it (the same holds for a
  window of a user's tab sent to the session whose input it handles).
  Such a tab carries the session's content rules and page clipboard guard
  before it loads anything: the web view WebKit asks for loads the popup's
  request only after the session attached and put them on it, and a popup
  tab cmux loads itself is created blank, handed to the session, and only
  then navigated (`BrowserReplPopupOpening`). When WebKit refuses to compile the policy's
  content rules, every driver call of the session fails with `invalid`
  (`the domain policy could not be applied: ...`) until the session sets a
  policy that compiles (a locked one needs a reset); the tabs keep the last
  rule list that compiled, and every navigation (of any frame) in a tab the
  session created is cancelled (`navigation.blocked`). The policy setters
  (`session.allowedDomains` and the like) return once the native session
  holds the policy, before WebKit compiles it, so the error reaches the
  agent on the session's next call. WebKit compiles one policy at a time,
  and of the policies set meanwhile only the newest: a burst of updates
  costs the compilation in progress and the last. The navigation and popup checks use the
  new policy from the moment the setter returns (the driver publishes it
  synchronously to `BrowserReplPolicyBoard`), and until its content rules
  are on the session's tabs, the session's driver calls wait and every
  navigation in a tab the session created (its popups included) waits
  before WebKit's navigation policy decision, then is judged under the new
  policy: no page loads its subresources under the previous rules. A page
  already loaded keeps running meanwhile, so its own script can still
  start subresource loads under the previous rules until they are replaced.
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
  Script the agent runs in its own world (`frame.evaluate` with `world:
  "agent"`, and the runtime's reads and element actions there, such as
  `focus` and `dispatchEvent`) runs without a user gesture (WebKit's
  `_callAsyncJavaScript` with `withUserGesture: NO`; a WebKit without it
  fails such calls with `unsupported`): `execCommand` is the native one in
  that world, and a page handler such a script sets off would hold the
  gesture too. So does every script the driver runs for itself, in its own
  worlds or the agent's (the frame gate's checks and the scripts it gates,
  capture masks, secret and focus checks, `tab.info`, frame names and
  boxes, waits, selection reads, the sign-in fill, the page agent's
  install): agent code can have replaced a getter they read, and a page
  handler they set off would hold the gesture.
  The page clipboard guard covers the page's world only, and a user's tab
  has none, since its pages keep the browser's clipboard. An agent's
  trusted input (`input.mouse`, `input.drag`, `input.key`,
  `input.insertText`) and its page-world `frame.evaluate` give the tab a
  gesture, which page script and code in the agent's world (a listener the
  agent registered, which keeps WebKit's own `execCommand`) can use, and
  which WebKit honors for up to 10 s after (a timer set within 1 s, a fetch
  started in the gesture that settles within 10 s; measured on macOS 27.0,
  26A428). So in every tab, from the start of such a call until 11 s after
  it, the general-pasteboard lookups WebKit makes (by name and through
  `+generalPasteboard`, for any web view) get a private pasteboard that is
  emptied at every lookup: an `execCommand("copy")` or Clipboard API write
  reaches nobody, the session included, and a read finds nothing (the page
  clipboard guard's writes to the tab's clipboard are not pasteboard
  writes and still land). A write the page starts then stays there however
  late its data arrives (a `ClipboardItem` whose promise the page settles
  after the quarantine): WebKit writes only while the general pasteboard's
  change count is the one it read when the page called `write`, and the
  private pasteboard's count is kept below the system's, which only grows,
  so WebKit refuses the late write. While the system's count is below 2
  (nothing was copied yet in the login session) no such call runs; it fails
  with `unsupported`. WebKit does not say which web view wrote, so a
  copy or paste the person makes in another web view of cmux during that
  time does nothing (the terminal, text fields and other code keep the
  system clipboard). A command the session runs in its own tab (Meta+C)
  keeps its private pasteboard meanwhile.
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
| `print(level, text)` | append one output line; `level` is `log`, `info`, `warn`, `error` or `debug`; `text` is already formatted. An evaluation keeps at most 16 MiB of lines; the rest goes to `<tmpdir>/output-<evalId>.txt`, announced by a `# output continues in <path>` line and summed up by a last `# output truncated: …; full output: <path>` line. The file takes at most 64 MiB per evaluation, counted against the session's fs budget (2 GiB); past either, the rest is dropped with a `# output past N bytes … was dropped` line. The runtime's own error reports go through the call's output gate like `console` output |
| `setTimer(id, delayMs, repeat)` / `clearTimer(id)` | on fire the app calls `globalThis.__cmuxHostOnTimer(id)`; repeating timers keep firing until cleared, each fire `delayMs` after the previous callback ran, so a busy thread holds at most one queued callback per timer. `setTimer` returns `false`, scheduling nothing, when the session already has 10,000 timers scheduled or fired with their callback not yet run; the runtime's `setTimeout` then throws a `RangeError` |
| `driverCall(callId, method, paramsJSON)` | the app later calls `globalThis.__cmuxHostOnResult(callId, errorJSON, resultJSON)`; exactly one of the two is `null`; `errorJSON` is `{ code, message }`. A session runs at most 256 driver calls at once and queues up to 10,000 more in order; past that a call fails at once. When a cell times out, the driver calls it started are cancelled (the driver stops the work where it can) and its queued ones fail with `cancelled` |
| `fetch(callId, requestJSON)` | request `{ url, method, headers: [[k, v]], bodyBase64?, targetId?, credentials?, origin? }`; result via `__cmuxHostOnResult`: `{ url, status, statusText, headers: [[k, v]], bodyBase64, redirected }`. Cookies come from, and `Set-Cookie` goes back to, the attached tab's cookie store (a cookie goes to a URL its domain matches and whose path its path matches by RFC 6265, so a `/account` cookie never goes to `/accounting`), for `credentials` `include` (default) always, `same-origin` only for URLs on `origin`, `omit` never. The domain policy is checked on the URL and every redirect hop (`blocked`); once a redirect leaves the first URL's origin, the request drops `Authorization`, `Proxy-Authorization`, `Cookie` and every header whose name marks a credential (`auth`, `token`, `api-key`, `secret`, `session`, `password`, `csrf`, `xsrf`, `credential`, `signature`), also on later hops back to it, and gets only the tab cookies the credentials rules give the new URL; a request body over 64 MiB fails with `invalid` before it is decoded or queued; a response body over 64 MiB fails, and so does one that would take the bodies a session's fetches hold at once (received and not yet taken by the runtime) past 128 MiB; a fetch that has not finished after 10 minutes fails with `timeout`; a session has at most 16 fetches waiting for their response headers and 64 open in all, queues up to 256 more in order and fails one past that at once (`fetch: 256 fetches are already waiting ...`); a fetch whose headers arrived leaves its slot, so un-awaited fetches of bodies that never end (event streams) cannot hold every slot; when a cell times out, the fetches it started are cancelled and its queued ones fail with `cancelled`; the session redacts the URL, headers and the body (text and other bytes alike, in one linear pass over the bytes: each value's UTF-8 bytes and their encoded and Base64 forms); a response that masking would grow by more than 8 MiB (a mask is longer than a short value) fails with `invalid` instead |
| `secrets(op, argsJSON)` | synchronous, `{"ok": value}` or `{"error": {code, message}}`: `set { name, value, domains, totp }`, `load { path }` (read natively) or `load { object }`, `list`, `has { name }`, `delete { name }`, `clear`. No result holds a value |
| `policy(op, argsJSON)` | synchronous, as `secrets`: `get` → `{ allowed, prohibited, blockIPs, locked }`, `check { url }` → reason or `null`, `site { host }` → the host's site (registrable domain by the Public Suffix List, or the host itself when it has none), the same site `cookies.clear` scopes to, `publicSuffix { name }` → whether the name is itself a public suffix (the runtime's `tools.register` refuses a wildcard over one), `set { allowed?, prohibited?, blockIPs?, lock?, title }` (a locked policy refuses) |
| `fs(op, argsJSON)` | synchronous; returns `{"ok": value}` or `{"error": {"code": "ENOENT"\|"EACCES"\|"EEXIST"\|"ENOTDIR"\|"EISDIR"\|"ENOTEMPTY"\|"EINVAL"\|"ELOOP"\|"ERR_FS_FILE_TOO_LARGE"\|"EFBIG"\|"EDQUOT"\|"ECANCELED", "message"}}`. Each root (`cwd`, `tmpdir`) is opened once when the session starts, or when an operation first opens or creates it (`mkdir -p`), by a walk from `/` with `openat` and `O_NOFOLLOW` (and `mkdirat` for missing directories) over the path as it was resolved, so a parent swapped for a link meanwhile is never followed (`EACCES`), and held: every operation walks from that held directory with `openat` and `O_NOFOLLOW`, follows a link only by reading it and while it stays inside a root, and acts relative to the directory it holds open (`fstatat`, `mkdirat`, `unlinkat`, `renameat`), so another session or local process can neither swap a link in between the check and the use nor redirect a root by renaming it away and putting a link or another directory at its path. Files open with `O_NONBLOCK` and are checked with `fstat` first: a FIFO, socket or device fails with `EINVAL` at once, and `readFile` refuses a file over 64 MiB (`ERR_FS_FILE_TOO_LARGE`). One `writeFile` (also an append) or `copyFile` writes at most 256 MiB (`EFBIG`, before the file is opened) and a session at most 2 GiB over its life and 100,000 entry changes (each file a write or copy creates, also an empty one, directory made, entry renamed or removed; `EDQUOT`, a reset starts a new budget); they write 1 MiB at a time and stop with `ECANCELED` when the cell times out or the session ends (a stopped copy leaves no file), and so do `readdir` and a recursive `rm`, checked every 1,024 entries (a stopped `rm` leaves what it had not removed yet). No lock is shared between sessions, so a slow operation holds only its own session. Residual, outside the threat model: a same-user process that changes a path inside a root between two operations changes what the second one finds there (never a path outside the roots) |
| `readResource(relativePath)` | text of a bundled `Resources/browser-repl/` file, or `null` |
| `tmpdir`, `homedir` | the session's private temporary directory (`<app temp>/cmux-browser-repl/<session>-<random>-tmp`, mode 0700, removed on close when empty; no other session's files are in it) and the canonical home directory, for `node:os`. The directory and its parent are made with `mkdirat` and `openat` (`O_NOFOLLOW`) from the app's temporary directory: a link in place of `cmux-browser-repl`, or a parent another user owns, makes no directory (fs calls there then fail). The session holds the new directory open; output spills are created in it with `openat` |

`fs` ops, paths relative to `cwd` (absolute paths must stay inside `cwd` or
the session's own `tmpdir`, never the system temporary directory that other
sessions and apps share, except files the driver reported through
`download.finished`, which are readable): `readFile {path}` → base64 (secrets redacted, text or bytes), `writeFile {path, base64, append?}` (secrets redacted; either fails with `EINVAL` when masking would grow the contents by more than 8 MiB),
`mkdir {path, recursive?}`, `readdir {path}` → `[{ name, type }]`,
`stat {path}` → `{ size, type: "file"|"directory"|"symlink"|"other", mtimeMs, birthtimeMs }`,
`lstat {path}` (as `stat`, for the link itself), `rm {path, recursive?, force?}`,
`rename {from, to}`, `copyFile {from, to}`, `exists {path}` → boolean,
`resolve {path}` → absolute path. `rm` refuses `cwd` and `tmpdir`
themselves. `writeFile` and `copyFile` take from the write budget above.

Symbolic links follow Node. `rm`, `rename` and `lstat` act on the link itself
and check only that its parent directory is inside a root, so a link pointing
outside can be removed, moved or described; `rm` of a link to a directory
never touches the directory. Every other op reads or writes through the link
and checks where it points, so such a link is never followed out of the
roots, and a dangling link is refused for writing. `readdir` reports a link as
`symlink`. `rename` uses `rename(2)` and `copyFile` copies to a temporary
file beside the destination before renaming it into place, so an existing
destination stays intact until the new file is complete.
The descriptor walk, not a lock, keeps a session moving a link (agent code
cannot create one) from changing what another session's checked path
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
  submitted cell counts as outside a cell. Calls that start outside a
  cell also share a time credit, so a stream of callbacks each under 10 s
  cannot hold the thread ahead of the next cell: the credit holds 10 s,
  refills at 10% of wall time, and each such call may run at most the
  credit left when it starts. While the credit is in debt, timer and event
  callbacks wait in order (at most 10,000 events; past that the oldest
  event is dropped) until it recovers or a cell runs, when they run during
  that cell; driver results are never held. Page events queued for the
  session's thread or waiting are bounded where they arrive, before they
  are queued: past 10,000 events or 64 MiB of them, a new one is dropped
  (a finished download still becomes readable). When the limit ends a call,
  the timers it set (an interval re-arming itself) are cancelled. The next
  cell's output starts with `error` lines saying how many callbacks were
  stopped, waited or were dropped. After the session closes
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
  overlapping iframes share a box. The app's driver binds by each frame's
  own word (`BrowserReplFrameBinding`): the parent's script reads the
  handle's position in `window.frames`, and each child frame, in the
  driver's content world, reports its own position there (or none, in a
  shadow tree), between two tree reads that must name the same children;
  lengths must agree at every read. A page that adds or removes frames
  meanwhile gets two more tries, then `null`, never a sibling's frame; a
  child that does not answer within 2 s leaves the handles `null` unless
  the others fill `window.frames` (then it is in a shadow tree).
  `frame.ownerBox` finds the owner element the same way, and fails with
  `stale` when it cannot.
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
  Handle ids are opaque strings (`h12.<token>`), stable per element for the
  document's life. The token is random per document, made by the agent in
  its own world when it installs in the document, so a frame that navigates
  never resolves an earlier document's handle, even one whose number the new
  document reuses: `element`, `resolveHandle` (`null`) and every call that
  takes a handle fail `stale` with `Element handle is from a previous
  document; take a new snapshot`, and the runtime does not wait for such a
  handle to come back. The agent's `snapshot`, `refForHandle`, `elementAt`
  and `refState` results carry `doc`, that token; the runtime records the
  document each ref came from, passes it to `refState` (which answers
  `foreignDoc` for another document's ref) and pins a ref locator's query to
  it (`aria-ref=e5@<token>`), so a navigation between the check and the
  query fails `stale` too.
- Host: `importModule(specifier)` is optional (absent in the app).
  `fetchHandlesCookies` is implied by the native `fetch` contract, so the
  runtime does not add a `Cookie` header itself there.
