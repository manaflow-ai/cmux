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
`unsupported`, `invalid`, `closed`, `blocked`, `denied`, `limit`, `hibernated` and `crashed`
(see [Hibernated and crashed tabs](#hibernated-and-crashed-tabs),
[Tabs](#tabs) for `denied`, and [Agent world](#agent-world) for `limit`).

Coordinates are CSS pixels relative to the top-left of the tab's viewport
(main frame), matching Playwright `page.mouse` and screenshots at scale 1.

## Tabs

| Method | Params | Result |
| --- | --- | --- |
| `tabs.list` | `{ all? }` | `[{ targetId, title, url, active, windowId, state, dataStore, openerTargetId?, ownerSession? }]` in window order (`state`: `live`, `hibernated`, `waking` or `crashed`; listing never wakes a tab); with `all`, then the tabs of other workspaces the session may use: only tabs it created that moved there (`windowId` names the workspace). A user's tab of another workspace is not listed, and neither is its `dataStore`: reaching it needs an attach a person grants, which cmux does not offer yet (see Guards, Authority), and naming it by id fails with `denied`. A tab of the session's own workspace is a valid `targetId` for the other methods except one with `ownerSession`: another running session created it, and it lists without `dataStore`. The `url` of a tab the session did not create (another session's or the user's) has its userinfo and credential-named query and fragment parameters reading `redacted`, as in network events. Tabs with equal `dataStore` (an opaque id, never reused for another store) share cookies and storage; a hibernated tab not yet loaded since a relaunch has none |
| `tabs.dataStore` | `{ targetId? }` | `{ dataStore }`: the store `cookies.get` uses with the same params |
| `tabs.open` | `{ url?, background?, dataStore? }` | `{ targetId }`; resolves after commit of `url`. With `dataStore`, the tab opens in that store (and the profile of a tab that uses it); a store no tab this session may use has (another running session's tab, a tab of another workspace) fails with `invalid` |
| `tabs.close` | `{ targetId, runBeforeUnload? }` | Only a tab the session created, or a user's tab of its workspace it is attached to (it drove it, for example after `tabs.use`); another fails with `denied` |
| `tabs.activate` | `{ targetId }` | |
| `tab.navigate` | `{ targetId, url, waitUntil: "commit"\|"domcontentloaded"\|"load"\|"networkidle", timeoutMs }` | `{ url, status? }`; `url` as for `tab.info` |
| `tab.history` | `{ targetId, delta: -1\|1, waitUntil, timeoutMs }` | `{ url }` (as for `tab.info`), or `null` when no entry (the blank page a tab opened on is not an entry); an error that names the entry gives it with its credential values `redacted` unless the session created the tab |
| `tab.reload` | `{ targetId, waitUntil, timeoutMs }` | `{ status? }` |
| `tab.info` | `{ targetId }` | `{ url, title, state, loadState, viewport: { width, height }, deviceScaleFactor, webProcessId? }`. The live values come from a read of the main document through the frame checks (see "Guards"); while the domain policy blocks that document they come from the browser's own state (the URL and title `tabs.list` shows), and the page is not read. `url` is written as the session could read it itself: in a tab it created, as written; in another tab, the main document's `location.href` its frame gate read, and when the gate refuses that document, a dialog holds its script or the read does not answer, the address with its userinfo and credential-named query and fragment parameters reading `redacted` (the rule `tabs.list` uses). A refusal that names a page the session cannot read (a user's tab on a blocked page) names it that way too |
| `tab.setViewport` | `{ targetId, width, height }` or `{ targetId, reset: true }` | |
| `tab.bringToFront` | `{ targetId }` | |
| `tab.keep` | `{ targetId }` | |
| `tab.handleEvents` | `{ targetId, events: ["dialog"\|"filechooser"\|"download"\|"network"] }` | Replaces the events this session has a handler for in the tab (`network`: a listener for `request`, `response`, `requestfailed` or `requestfinished`). See below. |
| `session.name` | `{ name }` | |
| `session.configure` | `{ userAgent?, extraHTTPHeaders?, permissions?, proxy? }`, each key replacing its value (`null` clears) | `{ proxy }`: whether tabs opened from now on use the proxy (a private data store whose connections go through it). The proxy ends with the session: a tab it kept, and any tab opened from one on that store, keep the store's cookies and storage but go back to the browser's own proxy settings. Applies to the tabs the session created while it is attached (a user's tab it drives keeps its own user agent, headers and content), whichever session drives them; it is undone when the creating session leaves the tab. Content rules are not accepted here: the driver builds them from the session's domain policy (see "Guards") |
| `history.search` | `{ queries?, from?, to?, limit }` (times in ms since the epoch) | `[{ url, title, dateVisited }]` newest first, from the history of the profiles the workspace's tabs use. History does not say who visited an entry, so each `url` has its userinfo and credential-named query and fragment parameters reading `redacted` (the rule network events use) |

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
the tab waits for it. A download keeps the route it started with. A
download reaches a session only when the session's domain policy allows
every address its request went through (the navigation's URL and its
redirects, the download's own redirects, the response's URL; a `data:` or
opaque `blob:` one is judged by the document that started the navigation,
or for a scripted download (`<a download>`) by the frame that asked for it,
and under a domain policy is refused when cmux has no record of either)
and each local file among them lies inside the session's working or
temporary directory. Otherwise, in a tab the session created, the download
is cancelled and `navigation.blocked` reports why; in a user's tab it keeps
the user's download location. In a tab the session created, a redirect of
the download to an address that would refuse it is cancelled before the
request goes there, also one WebKit reports before it picked the
download's destination. The driver routes a download, and the session
records it, in the same main-thread turn as WebKit's destination is
picked, so a session that leaves the tab either cancels a download it
recorded or is gone before the route is made. A download a session's
input started whose session left the tab before then (also every
session, or a tab no session drives any more) is cancelled with no event,
never saved to the user's download location. That holds also when the
session left before WebKit turned the navigation into a download: the tab
keeps the navigation's record naming the session (past its 60-second
claim window too) until the download claims it or a later navigation in
the same frame replaces it.

A dialog or file chooser the page opens while it handles a session's
`input.*` call, the first second of its page-world `frame.evaluate` (the
runtime's own agent-world reads hold nothing), its `tab.navigate`,
`tab.reload` or `tab.history` until the navigation commits, or while a call
wakes the tab,
is sent to that session too, also in a user's tab (the call caused it, so
cmux's own dialog or Open panel must not come up in front of the user, and
the call must not wait for an answer only the user can give). A download
the call starts keeps the user's location unless the session has a
`download` handler in its last `tab.handleEvents` for the tab and its
domain policy and directories allow where the download came from (above):
the session's own input asked for that file, and it could read the same
URL with `fetch` and the tab's cookies.

Each such event goes to one session, never to every session driving the
tab: a session with a handler for it in its last `tab.handleEvents` (the
creating session's first, then the session that registered first), else the
creating session of a tab a session created, else, for a dialog or file
chooser, the session whose call the page is handling. Only that session gets
`dialog.opened`, `filechooser.opened` and the download's `download.*` events,
and `dialog.respond` and `filechooser.respond` from any other session fail
with `not_found`, leaving the dialog or chooser open. When that session
leaves the tab, its open dialogs are dismissed and its choosers cancelled.

A dialog or file chooser opened by a frame whose document (as WebKit
recorded it) that session's domain policy blocks never reaches it: in a
tab the session created, or while the page handles the session's call, it
is answered as an unhandled one (dismissed or cancelled, never shown to
the user); otherwise (the session's handler on a user's tab) it keeps the
browser's own UI. A `dialog.respond` for a dialog whose frame the policy
blocks by then fails with `blocked`, and the dialog is dismissed.

When a session ends, the driver releases what it left pressed in each tab
it drives, and only that: each key it holds gets its key-up (last pressed
first) and its press in progress its button-up at the last mouse position,
or the drag it started ends. The page sees them as trusted events, so they
go through the session's input guards: under a domain policy, the frame
gate, which keeps blocked frames inert while they land. When the guards
refuse them (the tab shows a page the policy blocks, or a local file
outside the session's directories), nothing is sent and the keys and press
are forgotten: later input no longer carries those modifiers, and a drag
ends with `dragend` and no drop. Another session that stays on the tab
keeps its own keys and press and inherits none of these. Keys and a
press are held in the web view that got them: when cmux replaces the
tab's web view (a restore, a crash recovery), they are forgotten the same
way, and a release never reaches the replacement's page. When the last
session leaves or the tab closes, nothing more is sent; what is left is
forgotten the same way. `session.name` shows the tabs the
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
`auth.request`, whose sheet names only the frame's WebKit-recorded origin. While
`input.key` runs, WebKit's request to move AppKit focus out of the page
(`_webView:takeFocus:`, Tab past the last control) is refused, so the focus
stays in the web view and the window's first responder stays the user's.
A key-down no page handles is not passed on: WebKit resends such a key
through `NSApp.sendEvent` to the key window (the user's terminal, menus), so
keys the REPL and `cmux browser press` send carry a mark (`eventSourceUserData`; the mobile browser stream's keys, a person's, do not) and the app
drops a marked key that arrives outside that same event's own delivery (another web view delivering its own key at that moment does not exempt it). That
resend is also how a Command shortcut's Edit menu command (select all, copy,
cut, paste, undo, redo; bold, italic and underline in the REPL) is run: only
once WebKit has sent the key back (no page handled it; a page that cancels
the keydown gets no command as well), on the web view itself. In the REPL
bold, italic and underline run `execCommand` in the main frame through the
frame gate, which checks the tab again and judges the document the command
runs in, in the same script turn: a main frame that navigated meanwhile to
a page the session's authority refuses is not formatted (`blocked`). In a tab a
session created (one with the page clipboard guard), `cmux browser press`
Meta+C, Meta+X and Meta+V run nothing: that tab's clipboard is its
session's virtual one, `cmux browser press` carries no session, and as
agent input it never reaches the system pasteboard (the press has already
returned). In any other tab they run the
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
| `frames.list` | `{ targetId }` | `[{ frameId, parentFrameId, url, name, crossOrigin }]`, parents before children, document order. In a tab the session did not create, and for a frame its domain policy blocks, `url` has its userinfo and credential-named query and fragment parameters reading `redacted`, as in `tabs.list`; a blocked frame's `name` is the tree's, not read from the page |
| `frame.evaluate` | `{ targetId, frameId, world: "agent"\|"page", source, args, awaitPromise, timeoutMs }` | JSON-serializable return value |
| `frame.ownerBox` | `{ targetId, frameId }` | owner `<iframe>` content box in parent-frame coordinates |

`world: "agent"` runs in the session's own isolated content world (see
[Agent world](#agent-world)) where the driver has
already installed the page agent (`Resources/browser-repl/page-agent.js`) and
Playwright's injected script. Cross-origin frames are reachable. `source` is a
function expression called with `args`; text that is not one expression on
its own fails with `invalid` before anything runs (see "Guards"). An omitted
`world` is `"page"`; any other value than `"page"` or `"agent"` fails with
`invalid` before anything runs. The driver decides the world once, and the
same decision picks where `source` runs (page script runs with a user
gesture) and opens the page-world input window below. The agent world survives until the
frame navigates; after navigation the driver reinstalls it before the next call.

Input to an element in a child frame goes to the tab at the element's point
plus each owner `<iframe>`'s content box, found in the parent frame's agent
world (the session's) through the `<iframe>` element that `frame.contentFrame` confirms shows
the frame: the one a locator entered the frame through, else the one the
frame's own place in the parent's `window.frames` names, among at most
250000 `<iframe>` and `<frame>` elements of the parent's light DOM (the
snapshot's node budget). A frame in a shadow tree is not listed there; its
`<iframe>` is looked for in the rest of that budget, counted in elements
walked. An action fails past it, so a page cannot make each action walk its
whole DOM or check each of its `<iframe>`s. That sum is where the frame's content is only when the `<iframe>`
and its ancestors (in the flat tree, through slots and shadow hosts) move it
by translations at most: when one of them has a scale, rotation, skew,
`zoom`, `perspective`, `offset-path` or an SVG drawing around it, the action
fails naming that element and style instead of sending input that could
reach another element or frame. Before the input, and again after the
pointer moves there, each parent frame must have the `<iframe>` itself at
the point; an element over it fails the check (`<div> intercepts pointer
events`), as in the target's own frame. Each press of a click checks both
once more (the move before it, or the press before a second one, runs page
handlers that can put another element or frame at the point): the
runtime's `input.mouse` `down` names the target and each parent frame's
`<iframe>` (`expect`), and the driver checks them in each frame's agent
world (the session's own, where its handles live and no other session's
code runs) in the web content process right before it sends the press, then
sends it as soon as the last check answers, without another suspension.
When any changed it sends no press and fails with `stale` (`no press was
sent: …`), and so does the click. Residual: WebKit runs no script between
its hit test of a native event and the event's dispatch, and a check
cannot hold back an event already sent, so the time from the checks to
the press reaching the web content process stays open (the checks'
replies to the app and the press back, one message each way, not
measured). Page code that runs then (a timer, an
animation frame, a message or network callback) or a CSS animation or
transition that moves a frame at that moment can still put another
element or frame under the press; doing so on purpose needs that timing
to fall inside the gap. `locator.boundingBox()` and element screenshots
in such a frame fail as above. The runtime no longer calls
`frame.ownerBox`.

## Input

All input is delivered as native, trusted events (`isTrusted === true`).

| Method | Params |
| --- | --- |
| `input.mouse` | `{ targetId, type: "move"\|"down"\|"up"\|"wheel", x, y, button: "left"\|"right"\|"middle", clickCount, modifiers, deltaX?, deltaY?, expect? }`. `expect`, on a `down` only: `{ frameId, handle, x, y, owners: [{ frameId, handle, x, y }] }`, the element the press must reach at `x`, `y` of its frame, then each parent frame's `<iframe>` and where the press lands in that frame, innermost first, the last at the press point; the press is sent only while each is still what is at its point (see "Frames and scripts"), else it fails with `stale` and no press. A `frameId` of `null` is the main frame |
| `input.key` | `{ targetId, type: "down"\|"up", key, code, text?, location?, modifiers, autoRepeat? }` |
| `input.insertText` | `{ targetId, text }` or, from the runtime, `{ targetId, secret: name }`, which the native session turns into `{ targetId, text, secretName, secretDomains, secretRevision }` (see "Guards") (IME commit into the focused element. On WebKit a `contenteditable` editor gets marked text then its confirmation, so `compositionstart`, `beforeinput`/`input` and `compositionend` fire, trusted, and editors that start an edit only on a keydown or a composition (Google Sheets) take it; a form field gets a plain insert with one `input` event, as Chrome's `Input.insertText`; text with a line break or tab, or focus in an unreadable frame, inserts without a composition) |
| `input.drag` | `{ targetId, path: [{ x, y }], button, modifiers, expect?, dropExpect? }` (native drag session so HTML5 drag and drop fires). `expect` binds the press at the first point and `dropExpect` the release at the last, each shaped and checked as `input.mouse`'s `expect`, right before the press and right before the release (a locator's `dragTo` sends both unless `force`): a changed source fails with `stale` (`no press was sent: …`) and no press; a changed target fails with `stale` (`no drop was made: …`), the HTML5 drag ends with no drop and a plain mouse drag is released at the press point. The drag's data goes to a private pasteboard of that drag, never the system's named drag pasteboard: around each move that may start the drag, WebKit's lookups of the drag pasteboard get the private one until WebKit starts the drag, the move is handled or 5 s pass. Past 5 s, or once the tab's drag state is reset, the window stays held but diverted until WebKit has handled the move: its lookups get a private discard emptied at each lookup, so a page whose `dragstart` runs late never writes the system's drag pasteboard, and the drag WebKit then starts ends with no drop and the move fails with `timeout`. One drag holds that window at a time across all tabs (WebKit's lookups do not say which web view they serve); a move that cannot get it within 5 s fails with `timeout` and is not delivered. A drag WebKit starts after its window closed drops no data. A person's drag in another web view during the window writes the private pasteboard too, but a drop there never reads it: the drop's access grant comes from AppKit calling WebKit, which diverts the window to an extra private pasteboard emptied at each lookup until it closes (the automated drag then carries no data) |

`modifiers` is an array of `Alt`, `Control`, `Meta`, `Shift`. Key names follow
Playwright (`KeyboardEvent.key` values plus `Meta+a` style parsed by the runtime).

A mouse `down` that opens a context menu (the right button, or the left with
`Control`) fires the page's `contextmenu` event but never shows cmux's
native menu. When the page cancels that event no menu comes; the person's
next right click or Control-click in the tab still gets its menu, as does
any after the sessions leave the tab.

When sessions share a tab, a session's `input.mouse` `down` owns the pointer
until its `up` (or until the session leaves the tab), and an `input.drag`
owns it from its press to its release; another session's `input.mouse` or
`input.drag` waits meanwhile, at most 10 s, then fails with `timeout`
naming the session that holds the mouse. An `input.drag` that fails
partway (a refused drop, a stale press, a closed window) ends its press and
drag with `dragend` and no drop before another session gets the pointer,
and a drag is its own session's: no other session's mouse event moves or
drops it. A modifier key a session holds
down (`input.key` `down` of `Shift`, `Meta`, `Alt` or `Control`) applies only
to that session's later `input.key`, `input.mouse` and `input.drag` events
until its `up`; another session's input on the tab never carries it.

## Capture

| Method | Params | Result |
| --- | --- | --- |
| `tab.screenshot` | `{ targetId, clip?, fullPage?, format: "png"\|"jpeg"\|"webp", quality? }` (the session adds `secretMasks`) | `{ base64, width, height }` |
| `tab.pdf` | `{ targetId, format?, width?, height?, landscape?, printBackground?, margin? }` | `{ base64 }` |

Each screenshot edge is at most 16,384 CSS pixels, and a screenshot has at
most 2^25 pixels (a full page 2,048 wide and 16,384 tall), counted also
after the page's zoom, since WebKit snapshots the zoomed view; a larger
one, or a clip that is not finite, fails with `invalid`. A PDF's paper
edges must be above 0 and at most 14,400 points (200 inches, the largest
page a PDF describes without a user unit), its margins 0 or more and
leaving room on the paper, else `invalid` before anything is printed.

## Files, dialogs, popups, downloads

| Method | Params |
| --- | --- |
| `input.setFiles` | `{ targetId, frameId, element: <agent element handle id>, files: [{ name, mimeType, base64 }] }` |
| `filechooser.respond` | `{ targetId, chooserId, files }` or `{ ..., cancel: true }`. The files are written to a temporary directory of the session (removed when it ends) only after the driver knows the chooser is open and routed to the calling session; an answer for another session's chooser or a closed one fails with `not_found` and writes nothing. Files are given only into the document that opened the chooser, checked right before the answer with child-frame loads held: a chooser whose frame shows another document since (or a tab that replaced its web view) fails with `stale`, and one whose document the authority refuses with `blocked`; nothing is written then and the chooser stays open to be cancelled (`cancel` always goes through); the runtime keeps it pending (`page.fileChooser()`, the `FileChooser` the event gave) until the driver confirms an answer, and settles it only then or on `not_found`. At most 256 files and 256 MiB together, with distinct names, else `invalid` and nothing is written. The session counts the files against its `fs` write budget before the call reaches the driver (one call's 256 MiB, the 2 GiB and 100,000 file changes over its life); an answer past it fails with `invalid` (`EDQUOT` or `EFBIG` in the message) and nothing is written |
| `dialog.respond` | `{ targetId, dialogId, accept, promptText? }`; `blocked` (and the dialog dismissed) when the domain policy blocks the frame that opened it |
| `download.path` | `{ downloadId }` → `{ path }` after completion |

## Events

Every event carries `targetId`.

Every URL in an event, and in a `tabs.list`, `frames.list` or
`history.search` row, came from a page or a tab, not from the session that
reads it. The driver carries it as one typed value (`BrowserReplPageURL`,
Swift only) that names the tab's live creator, and turns it into text for
each reader where results and events leave the driver: only that creator
reads it as written; every other session gets its userinfo and
credential-named query and fragment parameters reading `redacted` (the
rule network events use), also where another field of the same payload (a
refusal's reason) repeats it. A URL that holds its document rather than
naming where it is reaches every other session as its scheme alone: a
`data:`, `blob:` or `javascript:` URL as `data:…` (and so on), an `about:`
URL as its name without a query or fragment (`about:srcdoc`). An event
`url` the driver did not type that way reaches every session in that form.
A frame the session's domain policy blocks lists in that form even for the
tab's creator, and an error that names a frame (a `blocked` refusal, a
`stale` frame that did not answer) names it in that form for every
session.

| Event | Payload |
| --- | --- |
| `tab.created` | `{ targetId, openerTargetId?, url }` (popups and `target=_blank`; `url` as written only for the opener's live creator) |
| `tab.closed` | |
| `tab.crashed` | (the web content process ended; calls other than navigation fail until a reload or navigation starts a new one) |
| `tab.replaced` | `{ reason? }` (cmux gave the tab a new web view: it restored a page it had unloaded to save memory, or recovered a crashed one; or, with `reason`, the creating session narrowed its domain policy or left a directory with a `cwd` change and cmux loaded the page again or made it `about:blank` (see Guards); frame ids and element handles from before are gone) |
| `tab.navigated` | `{ frameId, url, sameDocument }` |
| `navigation.blocked` | `{ url, reason }`: the driver cancelled a navigation of a tab a session created because that session's domain policy blocks `url`, its file roots do, or its content rules failed; every attached session hears of it, and only the tab's live creator gets `url` as written |
| `tab.loadState` | `{ state: "domcontentloaded"\|"load"\|"networkidle" }` |
| `dialog.opened` | `{ dialogId, type: "alert"\|"confirm"\|"prompt"\|"beforeunload", message, defaultValue, dismissedDuring? }` (stays open until `dialog.respond`; with `dismissedDuring: "copy"\|"cut"\|"paste"` it opened during that clipboard command and is already dismissed) |
| `filechooser.opened` | `{ chooserId, frameId, element, multiple }` (the native panel is not shown; see `tab.handleEvents` for which tabs send it) |
| `download.started` | `{ downloadId, url, suggestedFilename }`. Only the tab's creating session gets `url` as written; a session that gets a download in a user's tab (its own input started it) gets it with the userinfo and credential-named query and fragment parameters reading `redacted`, as in network events |
| `download.finished` | `{ downloadId, path?, error? }`. The driver judges where the download came from again at each redirect WebKit reports after it picked the destination and, under the session's domain policy and directories then, before it names the path: a place they refuse gives `error` (`refused: ...`, which names that place; a session that did not create the tab gets it with its credential values replaced, as `download.started` gives the URL, and without the rule's explanation) and no path, and in a tab the session created the download is cancelled and its file removed (in a user's tab it goes to the user's download location) |
| `console` | `{ type, text, args?, location? }`. Only the tab's live creator gets `text` as written; every other session gets each URL in it (from its scheme to whitespace, a quote, `<`, `>` or a backquote) with its userinfo and credential-named query and fragment parameters reading `redacted`, as in network events |
| `pageerror` | `{ message, stack }`, its URLs (a stack names the document's URL and its scripts') given as `console` gives `text`'s |
| `request` / `response` / `requestfailed` / `requestfinished` | `{ requestId, url, method, resourceType, status?, headers?, note? }`, and for `requestfailed` a `failure` (WebKit's error text). The driver holds each unfinished request's details for its later events, at most 1,000 requests or 8 MiB of them per tab: past that the oldest are dropped, and their `requestfailed` or `requestfinished` comes without their headers and with a `note` saying so. Sent only to the tab's creating session, to a session whose last `tab.handleEvents` for the tab names `network`, and to the session whose call the page was handling when the request started (the rest of that request's events follow it). Only the creating session gets the credential headers (`cookie`, `set-cookie`, `authorization`, `proxy-authorization`, `x-api-key`, `x-auth-token`, `x-csrf-token`, `x-xsrf-token`, and any whose name says it carries one); the others get the headers without them, and the `url` and URL-valued headers (`location`, `content-location`, `referer`, `refresh`, `link`) with the userinfo and each credential-named query or fragment parameter (that name rule, or `code`, `sig`, `key`, `jwt`, `otp`, `pass`, `pwd`, `sid`, `ticket`, `assertion`, `SAMLResponse`, `SAMLRequest`) reading `redacted`, as in every URL the `failure` text names |

## Browser state

| Method | Params |
| --- | --- |
| `cookies.get` / `cookies.set` | `{ urls?, targetId? }`, `{ cookies, targetId? }`. They use the store of the target tab (a private tab's, or the session's proxy store, is not the user's profile), which the runtime names on every call a page makes; without `targetId`, the session's `session.configure({ proxy })` store, else the active tab's. A URL the domain policy blocks fails with `blocked`; `cookies.get` leaves out the cookies of blocked sites and `cookies.set` refuses one, and also refuses a cookie with a Domain attribute (`.example.com`) unless an allowed pattern covers every subdomain it reaches (`*.example.com`) and no prohibited host is among them (see "Guards") |
| `cookies.clear` | `{ targetId?, all?, name?, domain?, path? }`. Deletes the cookies of the target tab's store (without `targetId`, the store `cookies.get` uses) on that tab's site, its registrable domain by the system's Public Suffix List (CFNetwork), and the site's subdomains, narrowed by exact `name`, `domain` and `path`. The driver takes the site from the tab; a `site` parameter is ignored. On a persistent profile (the user's cookies) a tab with no http(s) site and `all: true` fail with `invalid`; a store that is not persistent (a private tab's, the session's proxy store) is cleared whole for either. Cookies of sites the domain policy blocks are never cleared |
| `clipboard.read` / `clipboard.write` | per-tab virtual clipboard `{ items: [{ type, base64 }] }`, held by the session that created the tab while it is attached: any other session, and every session in a user's tab (also a kept one), gets `unsupported`. It empties when that session ends, and a Copy or Cut still running then, or a page script's write after it, never lands, so a session that drives a kept tab later never reads what the creator or the page put there. No pasteboard is ever involved: Meta+C, Meta+X and Meta+V (`input.key`) run on this clipboard only, never WebKit's Copy, Cut or Paste. The driver finds the frame that holds the focus (each document's focused frame element, from the main frame), and a script in its own content world runs in that frame's document, through the frame gate, which under a domain policy authorizes the document and checks in the same script turn that the script still runs in it. In that turn the script dispatches a `copy`, `cut` or `paste` `ClipboardEvent` with a `DataTransfer` at the focused element (Paste: every type of the clipboard; images as files) and, unless a handler cancelled it, does the default action: Copy and Cut take the selection after the handlers (text, and HTML outside form fields), Cut deletes it from an editable target, Paste inserts the text through the engine's `insertText`. A cancelled Copy or Cut takes what the handler set. Copy or Cut with nothing selected empties the clipboard without an event. The events are dispatched, so `isTrusted` is false and an editor that accepts only a trusted paste ignores it. So the clipboard takes only what that document's event produced, and a paste reaches only the document the gate checked, wherever the page moves the focus meanwhile; a focus in a blocked frame fails with `blocked`, a focus the driver cannot place (a frame in a shadow tree) or one that moved into a child frame meanwhile with `stale`. They run only in tabs a session created: in a user's tab `input.key` refuses them with `unsupported` before any key reaches the page. Until the shortcut returns, a JavaScript dialog in that tab is answered as an unhandled one is (`dialog.respond` with `accept: false`) and reported with `dismissedDuring`, never held; a handler that runs long only delays the call. Writes a page's own scripts make (the asynchronous Clipboard API, `execCommand("copy")`) reach this clipboard through the page clipboard guard (see "Guards") |

## Guards

Agent code runs in the REPL's JavaScriptCore context, so the guards are
native (`BrowserReplBoundary` in the session, and the driver):

- Authority: one function, `BrowserReplDocumentAuthority.verdict(_:)`,
  decides whether a session may read from or act on a document, frame, URL
  or tab now. Its one input, `BrowserReplAccess`, names the subject (a URL
  to load, a tab's recorded page, or a frame's document as WebKit recorded
  it or as read in the frame, with its makers when it is opaque), the tab
  (its creator, main-frame URL, attached sessions and workspace) and the
  tab capability (`use` or `close`). The verdict joins the domain policy,
  the session's file roots (local files and documents of a local file's
  origin), the makers of opaque documents and the tab's ownership, and the
  rules below are its parts. The frame gate, the driver's page, frame and
  tab checks, held-input release, landed pages, cookie URLs, dialog and file
  chooser routes and answers, console and page-error recipients,
  permission grants, the page clipboard's refusal and capture masks all ask
  it. Tab capability: a session uses only tabs of its own workspace that no
  other running session created (`denied` otherwise); a tab of another
  workspace needs an attach a person grants, and cmux has no such grant
  yet, so it is refused, as is a restored placeholder tab there before it
  is created. A user's tab moved to another workspace is left at once by
  the sessions attached to it that may not use it there: no event, dialog,
  file chooser, download or network event of the tab reaches them after
  the move, and their next call on it fails with `denied` (a tab a session
  created stays its own wherever it moves). A call already in flight when
  the tab moves stops too: the frame gate asks the tab capability, with
  the tab's workspace as it is then, before every script it runs and every
  input it guards and again when that script returns, the driver before
  each native mouse, drag, key and text step (also when the move left no
  session attached to the tab), and again before it hands back a result
  (a tab it can no longer reach fails the call), so the moved tab is
  neither read nor sent input and the call fails with `denied`. A
  navigation the session started there (`tab.navigate`, `tab.history`,
  `tab.reload`) that has not committed when the session leaves the tab
  (the move, or the session ending) is stopped before it commits, and the
  call fails with `denied`. It closes only tabs it created and user tabs it is attached
  to. Navigation-time decisions in tabs a session created (the navigation
  delegate, popups and downloads) still apply the creating session's
  policy and file roots through their own checks (`BrowserReplNavigationGuard`,
  `BrowserReplPopupRoute`, `BrowserReplDownloadSource`).
- Method and event table: the driver runs only the methods
  `BrowserReplDriverMethod` names; any other name fails with `unsupported`
  before anything runs (default deny). Each method's `BrowserReplMethodSpec`
  says which authority checks apply: its tab capability (or none, with the
  reason), its page check (the tab's page, the URL it loads, or none with
  the reason) and its frame check (the frame under the pointer, along a
  drag, the focused frame, the chooser's frame, every frame for a PDF,
  during the capture for a screenshot, the dialog's document, where its
  script runs, or none with the reason), whether it is trusted input
  that holds blocked frames inert, and whether it leaves the page:
  `tab.navigate`, `tab.history` and `tab.reload` (and a hibernated tab's
  reload on wake) fail with `blocked` when the page they land on is one the
  authority refuses as the tab's page (the domain policy, a local file
  outside the session's directories, or a main-frame document of a local
  file's origin); a user's tab stays where it landed. `tab.history` also
  refuses an entry the authority refuses before going to it. `tab.info`, `frames.list` and
  `frame.ownerBox` are judged where their script runs (the frame gate) and
  answer the URL and title `tabs.list` shows; `download.path` reads the
  session's own downloads, each judged when it started; `dialog.respond`
  is judged by the dialog's document. Events go out only as
  `BrowserReplDriverEvent` cases through the delivery the table names
  (`BrowserReplEventSpec`: every attached session for a tab's lifecycle,
  the network recipients whose authority allows the document that sent the
  request (WebKit's document id on the request, matched to a frame tree
  read; an event whose document cannot be told, or that WebKit names no
  document for, reaches no session whose authority is active in the tab,
  and a document load is also judged by the URL it loads, by the domain
  policy and the session's file roots, so a load of a file outside the
  session's directories reaches no session even while the frame tree still
  names the frame's earlier document), the sessions whose authority allows the sending
  document for console messages and page errors, the one routed session
  for dialogs and file choosers judged by the opening frame's document,
  the download's session judged by its source); the driver drops any other
  name, and a path that does not match an event's delivery drops it.
  `BrowserReplDocumentAuthorityTests` enumerates every method and event.

- Domain patterns (the policy's `allowed` and `prohibited`, a secret's
  domains, `tools.register` domains): `example.com`, `*.example.com`,
  `https://example.com:8443` or `*`. A two-label host (`example.com`)
  also covers its www host (`www.example.com`); a leading `=`
  (`=https://example.com`) names the exact host alone, in the native
  matcher, the content rules and the frame checks (the policy and secret
  domains; `tools.register` does not take it), and `=` with a wildcard
  fails with `invalid`. The sign-in sheet's credentials for a two-label
  host take that form (see site-tools.md, "Secure sign-in"). Several wildcards, a wildcard
  top-level domain (`example.*`), an embedded wildcard and a wildcard over
  a public suffix of the system's Public Suffix List (`*.com`, `*.co.uk`,
  `*.github.io`) fail with `invalid`; a wildcard over a site
  (`*.example.co.uk`) and a public suffix named alone (`com`, one host)
  are accepted. Where the system's list cannot be read (CFNetwork does
  not export it), every wildcard pattern (`*.example.com` too) fails with
  `invalid`, since none can be told from one over a public suffix; exact
  hosts and `*` are still accepted. Agent code chooses them, and each costs every navigation
  check and the content rules WebKit compiles, so they are bounded before
  they are parsed: at most 1,024 patterns in `allowed` and in
  `prohibited`, a pattern of at most 1,024 bytes, a host of at most 253
  characters in its ASCII form with labels of at most 63, and a scheme
  of at most 32 characters with at most one wildcard (`http*://`); past
  any of them the pattern or list fails with `invalid`, naming the limit.

- Secrets: values stay in the session. The page that receives a typed
  value can send it on, and only the domain policy's content rules stop
  that, in the tabs the session created. So the session refuses
  `input.insertText { secret }` (`invalid`, naming the call to make)
  unless its policy's `allowed` list is set and each pattern in it is
  covered by one of the secret's domains, and from then on refuses a
  policy change (`invalid`) whose `allowed` list would reach past the
  domains of any secret it sent to be typed; the driver refuses it
  (`invalid`) in a tab whose live creator is not the typing session (a
  user's tab, also one `tabs.use` attached, or another session's).
  `input.insertText { secret }` reaches
  the driver as `{ text, secretName, secretDomains, secretRevision }`; the driver types it
  only when the document that holds the focused element has an origin
  matching one of `secretDomains`, else fails with `secret "x" may not be
  typed into <origin>; its domains are ...`. The origin is read in the
  driver's own content world by the same evaluation that finds the focus,
  in that document (its own origin, `null` when opaque), not from
  WebKit's frame tree, which keeps naming a frame's old document after it
  navigates. A document whose active element is a frame element
  (`<iframe>`, `<frame>`, `<object>`, `<embed>`) never answers for the
  focus: the frame inside does. The check runs right before the
  text is committed, after the wait for the editor state (a page can move
  focus during that wait), and the marked text and insert follow on the
  same main-thread turn. The check judges the web view the text goes to,
  and the text goes to it only while the tab still shows it: a tab that
  replaced its web view meanwhile (a web content recovery) gets nothing
  (`stale`). A page can still move focus in its own web process
  between the check's last reply and the insert reaching that process:
  WebKit has no insert bound to an element or frame, so that cross-process
  window remains. The call also carries `secretRevision`, the secret's
  revision when the session filled in the value; on that same turn the
  driver asks the session whether the name still holds that revision, and a
  secret deleted, cleared or set again since the call was made fails with
  `invalid` and nothing is typed. Captures get `secretMasks
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
  meanwhile), and (`stale`) when a child frame it marked is gone after
  it: that frame could have shown any page during the capture.
  Everything the session hands its JavaScript or its output passes one
  egress gate (`BrowserReplBoundary.egress`, Swift only): driver results,
  refusals and errors, events (and withheld events), fetch responses (URL,
  headers, body bytes), every `fs`, `secrets` and `policy` answer (file
  contents as bytes; names from `readdir`, paths and error messages as
  text, since a page's download keeps the name the page gave it), printed
  lines and evaluation errors. The gate builds one scanner per call and
  scans the original data once; the session can hand JavaScript only the
  gate's output type. Files the session writes or copies are masked by the
  same scanner. The driver masks no text itself: masking part of the
  values first would let one value's mask cut into another before the
  gate looks for it. Another session that drives the same tab
  (`tabs.use`) does not hold the secret, so the driver remembers each value
  it typed, by tab and value, from when the domain
  check passes, before it types, until the tab closes (a value the check
  refuses is never remembered; sessions whose secrets share a name keep
  separate values, and a name typed again with a new value keeps the
  earlier one, which the page may still hold), and every other session masks it as typed,
  `<secret:name>`, at its egress gate (every result, event and error), and
  the driver in their captures; once the typing session ends, also for a
  later session of the same name.
  The open tabs hold at most 4,096 such values (one per tab and distinct
  value; the same value typed into the tab again, also after the session
  that typed it ended, is the record it already has, and its captures
  mask it on every domain it was typed for, since an older frame may still
  show it; a record whose domains together would pass 1,024 stays beside
  the new one): past that the driver refuses to type
  another (`invalid`) until tabs close, since a value it typed is never
  dropped while its tab is open.
  A capture takes those masks before it waits for the page, so one during
  which another session recorded a value to type (in any tab) fails with
  `stale` instead of returning pixels that may show it. The session's own
  masks are the values it holds when it makes the call, and its calls run
  concurrently, so it can set a secret (or a domain of one) and type it
  while the capture is taken: when the capture returns, every value the
  session holds, and every TOTP code of a window since the masks were
  taken, must be among the masks with each of its domains, or the capture
  fails with `stale` as well.
  The driver hands those sessions the values as a store
  (`typedSecretRedaction()`, Swift only), and each session's gate masks
  them in the same pass as its own secrets.
  A TOTP secret's typed value is its code, masked as that literal.
  A value that reads as a number (`0042`, `0012345678`, `3.140`) is also
  masked where a result holds it as a JSON number (`Number(value)` drops
  leading zeros), whatever its length, except a value masked by its shape.
  Masking by shape: masking runs over data the agent chooses (what it
  prints, writes, or has a page echo), so a mask that appears only where
  that data equals a held value answers a guess. A value from a set one
  call can list whole is therefore never compared: while a session holds a
  TOTP secret, every whole six-digit number (no letter or digit on either
  side) is masked as `<secret:name>`, and while it holds (or another
  session typed) a digit-only value of at most 8 digits (a PIN, a typed
  TOTP code), every whole number with as many digits is masked with that
  value's mask, in text and as a JSON number with those digits. Their
  encoded forms (Base64, escapes) and their numbers without leading zeros
  are not looked for. Every other value is matched by value, so a value an
  agent can guess (a short or dictionary password) can still be confirmed
  by printing guesses: value masking keeps a value out of what pages and
  files hand back, not away from an agent that guesses it. Capture masks
  still mask the exact values and codes.
  Masking matches whole values, so where the page agent cuts a page
  string (the page-read budget, a long name) it drops the 53,248
  characters before the cut (4,096 bytes in their longest escaped form)
  before the reply leaves the page: a cut never hands on a value's prefix.
  A snapshot's link URLs leave the page whole; the snapshot renderer
  makes every summary of one after masking: an off-site link's
  `host/first-segment` form, an on-site link's path without its origin,
  and the caps (300 characters for a cross-origin URL, 48 for an off-site
  summary, 100 for an unnamed link's URL).
  Text the agent's own page scripts cut or search (a `searchText` context
  window, a regex group, `page.evaluate`) is outside this, as other
  transforms are.
  This masks the value as typed and in the encodings the session's
  redaction knows; page script that copies it elsewhere or transforms it
  is outside it, as it is within one session. Redaction is best-effort
  value matching. Accepted by the threat model (the transformed-echo
  limit): a page on the secret's own allowed domain already holds the
  value, so it can hand it back transformed (hex, compressed, encrypted,
  split across strings or lines, Base64 or percent-encoding applied once
  more) and no value matching finds it. A file `secrets.load` read holds
  values only the loading session knows to mask, so from the load on no
  session's `fs` reads it, the loading session's neither: `readFile`
  and `copyFile` from it (also a file chooser answer, which reads its
  files through `fs`) fail with `denied`, a message that says the file
  holds secrets loaded by `secrets.load`, under any name (judged by its
  device and inode). Only `secrets.load` reads it, through its own native
  read. `stat`, `lstat`, `exists` and `readdir` still see it, and
  `writeFile`, `rename` and `rm` still change it (an agent edits its
  keys by writing the file whole). A read checks once it opened the file
  and again once it read it (a copy before it publishes), so a
  `secrets.load` of the file meanwhile fails the read too. A tab would
  render its text as pixels no mask covers, and its page scripts could
  read it: from the load on, no session's tab loads that file (a
  navigation of any frame, by the agent or a page, fails with
  `blocked`), judged by the same identity, so a rename or another hard
  link to it is refused too. The load
  opens the file and protects it in one hold of the lock a file navigation
  checks and starts under, so no navigation passes its check in between.
  The protection lasts while the file exists under any name (not only
  while the session lasts: a value it typed stays masked in text, but a
  capture masks it only on the secret's domains). One session protects
  at most 512 distinct files over its life (loading one it already
  protects takes nothing); past that its `secrets.load` fails with
  `limit`, naming the quota, and reads nothing. Neither the session's end
  nor a reset frees its files, so a new session after a reset has a new
  quota but the app-wide set keeps them: cmux protects at most 4,096 such
  files at once for all sessions, and past that, once files that are gone
  are dropped (a file is gone when its volume, asked by the `statfs`
  volume id taken when it was protected, names no object with its inode;
  one whose volume id could not be taken is never dropped), `secrets.load` fails closed with `invalid` and reads
  nothing until protected files are removed. A file
  chooser answer reads its files through `fs`, masked. It must be
  UTF-8 and may not spell a digit with a JSON escape (`\u0030` to
  `\u0039`), else `secrets.load` fails with `invalid`: file reads mask a
  value by its UTF-8 bytes and escaped forms (a short digit value only by
  its shape), so a UTF-16 or UTF-32 source, or an escaped digit value,
  would read back unmasked.
  A session holds at most 256 secrets (`secrets.set`, `secrets.load`;
  replacing one is not another) of at most 4 KiB with at most 64 domains
  each, refused with an error naming the limit. `secrets.load` stops
  between entries when its cell times out or the session ends, and
  builds the masks once when it returns or stops, so what it loaded is
  masked either way. `secrets.delete`,
  `secrets.clear` and replacing a secret's value stop the old value from
  being typed or listed, but it stays masked (in text, files and captures)
  for the session's life, since the agent never saw it and its source (a
  secrets file) may still hold it, in captures on every domain any of its
  registrations named; a session holds at most 1,024 distinct
  values over its life, current and retired, and a new one past that is
  refused until a reset, and one value is registered for at most 1,024
  domains over its life. One masking pass matches the session's own values
  (current and retired), the values other sessions typed and the numbers
  masked by shape together against the original input, so no value's mask can
  replace part of another value before that value is looked for. It tries
  every position, also one inside an earlier match, and masks
  intersecting matches as their union (each distinct mask once), so a
  value registered to overlap another never leaves the other's suffix
  unmasked. At each position it tries
  only the values whose first byte can start there (the
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
  with read access to a directory, so a page could otherwise read files
  the session's `fs` cannot; cmux's internal schemes and `javascript:` are
  refused too. The driver checks the path again and starts the load while
  no REPL `fs.rename` can run (in any session; `rename` is the only `fs`
  call that can put a link at a path), and gives the page read access to
  the session directory that holds the file, which must still be the
  directory the session began with (same identity, no link on its path).
  WebKit resolves that directory when it grants it and refuses a file
  outside it, so a link another session or process swaps in below it
  after the check leads nowhere outside (measured on macOS 27.0). A load
  of such a file that the tab starts without the driver (a crashed web
  process's recovery, a discarded tab's restore, a reload, the page's own
  navigation) gets the same grant under the same lock: in a tab a session
  created for any file (the creating session's directories), in a user's
  tab for a file inside an attached session's directories; a refused one
  loads nothing, and such a file is never restored from WebKit's saved
  session state, whose replay would grant the directory it recorded. A file
  navigation in a workspace whose browser waits for a remote proxy is
  refused rather than started later outside that check. In a tab the
  session created, and its popups, the same rule holds for what the page
  loads, whoever starts it: the navigation delegate cancels a navigation of
  any frame to a file it refuses (`navigation.blocked`; a page, a redirect,
  history), and content rules block `file:` subresources and child frames
  outside the directories (matched on the URL as WebKit spells it, so a
  file inside them spelled another way is blocked too; an encoded `/` is
  blocked). WebKit itself refuses a file outside the directory a load
  granted (measured on macOS 27.0); these hold also when the web process
  holds a wider grant. A window a page opens from any tab a session drives
  never loads a local file through cmux's own navigation. A string without a scheme that looks like a path (`/`, `~`,
  `.`) is refused. The same rule refuses the session's reads and input
  (the calls a blocked page refuses, `blocked`) on any tab that shows a
  local file outside those directories, such as a user's tab opened on
  one before the session reached it, and on a tab the session did not
  create whose page is a document of a local file's origin under another
  URL (an `about:blank` page a file page wrote). A page cmux serves through
  its own URL scheme (`cmux-diff-viewer:`, which streams the local files a
  diff registered), or a document of such a page's origin, counts as a
  local file outside those directories, whatever they are: the session's
  reads and input on a user's tab that shows one are refused, a tab the
  session created never loads one in any frame, and a load or a landed
  page on one is refused. A document of an opaque
  origin whose URL names no host (a `data:` page or frame, a `blob:` of an
  opaque origin, a sandboxed `about:srcdoc`) is judged there by the
  documents that made it, as under the domain policy below: it is refused
  when a local file outside those directories, or a document of a local
  file's origin, made it, or when cmux has no record of who made it (a file
  can replace itself with a `data:` document that shows its content). In a tab the
  session did not create, a child frame that shows such a document (a
  local page inside the directories can frame files outside them, and
  that tab has no content rules) is judged like a frame the domain policy
  blocks, whatever the policy (see the frame rules below): script there
  fails with `blocked`, also through a frame record from before it
  navigated (a local document is bound by its URL, not only its origin),
  input that would reach it and PDFs are refused, and a screenshot blanks
  it. As under a policy, a capture there judges the documents it marks (a
  frame can show such a file after the tree read) and holds child-frame
  loads until it is taken, also with no policy. A tab whose main frame shows a web page (`http`, `https`) cannot
  frame a local file, so it is left to the policy alone.
- Domain policy: the session refuses `tab.navigate`/`tabs.open` to a blocked
  URL (`blocked`; a `blob:` URL is judged by the origin in it, and one of
  an opaque origin, `blob:null/...`, is blocked) and `session.configure`
  content rules, and calls the
  driver's `setDomainPolicy(policy)` (Swift only). The driver applies the
  policy's content rules to the tabs the session created. WebKit compiles
  them asynchronously while those tabs' pages keep running, so from the
  main actor's next turn after a policy or directory change until the new
  list is on a tab (and after WebKit refused it, until a policy compiles),
  the tab carries a fail-closed list that blocks every load: no live page
  loads, under the previous rules, what the new ones forbid. The driver refuses reads and input (`frame.evaluate`, `auth.request`,
  `frame.contentFrame(s)`, `input.*`, captures, clipboard, file chooser
  answers) on a tab that shows a blocked page, cancels main-frame
  navigations to blocked URLs in tabs the session created
  (`navigation.blocked`), and never navigates a user's tab away for the
  policy. The cancel is in the navigation-action decision, which WebKit
  asks again for each HTTP redirect hop, with the hop's URL and before it
  requests it, so a redirect to a blocked host is cancelled before that
  host is asked for anything (`BrowserReplRedirectPolicyTests`). A navigation to `about:` (`about:blank`) or `data:`, or to a
  `blob:` of an opaque origin, takes its document from the frame that
  started it, so it is judged by that frame's document as WebKit recorded
  it (its source frame) and cancelled when the policy blocks that one; one
  no page started (the agent's own) passes. A page-started navigation to
  any other URL is judged by that URL and by the frame that started it: a
  blocked frame cannot move the tab even to an allowed page (whose URL it
  chose and can put its page's data in). The content rules judge a
  `blob:` subresource or child frame by the origin in its URL. A document
  of an opaque origin whose URL names no host (a `data:` frame, a sandboxed
  `about:srcdoc`, a `blob:` of an opaque origin) is judged by the pages that
  made it: the navigation delegate records, for every navigation to such a
  URL in any tab, the document that started it (WebKit's source frame; one
  that is itself opaque passes on its own makers, and a new tab's first
  load is the app's), and the driver refuses reads and input on the
  document (and blanks or makes inert its frame) when the policy blocks one
  of them. A frame keeps every maker recorded for it for its life (WebKit
  does not say which child-frame navigation committed). Under a locked
  policy such a document is refused also when cmux has no record of who
  made it (a document loaded before cmux saw the navigation, or a frame
  with more than 16 makers). It also judges every frame, not only the main frame, by WebKit's
  record of it (`WKFrameInfo.securityOrigin` and URL) and by its document
  (`location.origin` and `location.protocol + "//" + location.host`, read
  in the driver's own content world; `location` cannot be forged by page or
  agent script). The origin and the URL's host must each be allowed, so a
  page that relaxed `document.domain` onto an allowed parent domain stays
  blocked. Script the driver runs in a frame (`frame.evaluate` and
  the calls built on it, `frames.list` names, `frame.ownerBox`) first checks
  in the frame that the document is one the driver approved, and runs
  nothing in another: a frame keeps its id when it navigates, so a frame
  looked up from an earlier tree read is judged again. Two opaque documents
  have the same origin and place, so an opaque document is judged by its
  frame's makers as recorded at each call, never by an earlier verdict, and
  the script runs only in the opaque document whose URL (without its
  fragment) the driver approved: one the frame shows when the script
  arrives, whose maker WebKit reported after the check, runs nothing and is
  judged again. A `data:` URL holds its document's content and a `blob:` URL
  is unique, but an `about:srcdoc` or sandboxed `about:blank` URL tells
  nothing: for those the makers are judged again after the script, whose
  result is refused when a maker recorded meanwhile is blocked, and the
  script may already have run there (residual). The driver's own text in
  that script runs in a scope of its own after the check, and the agent's
  `source` must be one expression on its own (else `invalid`, before
  anything runs), so nothing in it can replace the `location` the check
  reads or run before the check. Script in the page world or a session's
  agent world can also reach other frames of the tab, and two frames of
  one site that both set `document.domain` to it are one origin: such
  script (the agent's `frame.evaluate`, and the driver's own reads in the
  agent's world, which agent code can patch) fails with `blocked` while
  any frame of the tab that the authority refuses has a host sharing a
  domain with the target frame's host that both could relax to (any
  scheme or port), judged on a fresh tree read before the script and
  again after it, whose result is then withheld. Residual: a timer or
  observer agent code left in its world can read such a frame that loads
  between calls, and hand it on in a later call once the frame is gone. A frame that shows a
  blocked page fails with `blocked` (`snapshot()` marks its iframe
  `[not read: blocked by the domain policy]`). A tree read can lack frames
  (WebKit gives no tree, or cannot describe a child): while the policy is
  on, input, captures and script that can reach other frames (the
  `document.domain` check above) fail with `stale` when the main frame's document,
  or that of a frame with a child WebKit could not describe, holds more
  child frames (`window.frames`, read in the driver's world) than the tree
  has under it, and a PDF when any child could not be described. A
  capture that masks a secret, or runs while the policy or the local-file
  rule judges the tab, is refused (`stale`) whatever the policy when the
  documents of the frames it marked hold more child frames (`window.frames`
  and the frames in their shadow trees, closed ones too) than the tree
  names besides the main frame: a frame missing from the tree would be
  neither masked nor judged. On a
  fresh tree read the driver refuses `input.mouse` and `input.drag` at a point inside the box
  of the main frame's child frame that is or holds a blocked frame (overlap
  is not subtracted, and a blocked frame whose box it cannot find refuses
  every point), `input.key` and `input.insertText` while a blocked frame
  holds the focus (its document has it or holds a focused element, or its
  parent's focused element, also inside a shadow tree, is its frame element,
  found by the frame's own position in `window.frames`; a frame that cannot
  answer, or whose element cannot be told, counts as focused). Meta+C,
  Meta+X and Meta+V check the focus again after the key, on a fresh tree,
  and then run only in the document the frame gate authorizes, in the same
  script turn as its document check (see `clipboard.read`), so the page
  moving the focus into a blocked frame meanwhile never hands that frame
  the clipboard or its selection to the clipboard.
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
  A blocked frame reports its place in its parent's `window.frames` (from
  its own window, WebKit's handle of that frame), and the page can reorder
  its frames before the parent guards that place: so after the guards are
  on, each guarded frame reports its place again and each parent confirms
  `window.frames` stayed the list it guarded at every change in between
  (a mutation observer compares it), else the input fails with `stale`
  and nothing is sent. The inert element then holds the blocked frame and
  keeps it wherever the page moves it.
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
  and new windows are not held. So every native step of the input (each
  event of an `input.drag`, also its drop) judges the main frame's live
  page first, which WebKit names from the start of a navigation, before it
  commits: a page the authority refuses fails the input with `blocked`, and
  a main frame of another origin than when the input started (which the
  input's checks and guards never judged) with `stale`; an `input.drag`
  then ends with `dragend` and no drop. Then the guard comes off (an element the
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
  now) is blocked, or `stale` when the frame tree no longer has that frame
  (its document cannot be judged). A screenshot blanks, in gray, the box of each main-frame
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
  the creating session's domain policy allow, and only when that policy
  allows the document of the frame that opened it (a blocked frame chose
  the URL); otherwise it opens nothing.
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
  Content rules judge a connection only when it opens, so when the new
  policy may block something the previous one allowed (it blocks IP
  addresses, prohibits a new pattern, or allows a list that lacks a
  pattern allowed before, or there was no allow list), each live page of a
  tab the session created is loaded again once the rules are on it: an
  allowed page reloads, a blocked one becomes `about:blank`, and the
  tab's sessions get `tab.replaced` with the reason. Every connection the
  old document held (a WebSocket to a now-blocked host) ends with it. The
  session's calls wait until this is done; a tab whose page cannot be
  replaced within 10 s is closed. A policy that only widens reloads
  nothing. A `cwd` change that leaves a directory does the same to each
  live page of a tab the session created that is not a web page (a local
  file, or a document such as `about:blank` that may hold a local file's
  origin), since such a tab's documents are not judged on each read: a
  file inside the new directories reloads, anything else becomes
  `about:blank`, and the tab's sessions get `tab.replaced` with the reason.
  `BrowserReplDocumentAuthority.pageReplacement(after:in:)` makes both
  decisions.
- Page clipboard: in a tab a session created, page scripts read and write
  only the tab's virtual clipboard, never the system clipboard, also while
  an agent's click, key or evaluated script gives them a user gesture.
  WebKit has no per-web-view pasteboard (its Copy, Cut and Paste name the
  general pasteboard, which the UI process looks up process-wide), no
  setting that refuses `execCommand("copy")` to a page in a gesture
  (`JavaScriptCanAccessClipboard` only widens it; there is no clipboard
  access policy among `WKPreferences`' features or selectors), and no UI
  delegate method that sees a pasteboard write (checked on macOS 27.0,
  26A428). So once a session creates the tab (or a popup of one), the
  driver turns WebKit's `AsyncClipboardAPIEnabled` and
  `DOMPasteAccessRequestsEnabled` features off for that web view
  (`tabs.open` fails with `unsupported` on a WebKit without both switches,
  and a web view where they do not take gets an empty document with no
  script): no document of the tab, already-loaded ones and initial empty
  ones included, has a native `navigator.clipboard`, `Clipboard` or
  `ClipboardItem`, and no page script can paste (WebKit never asks the app
  for paste access; a person's Command-V is not a script paste). It also
  adds `Resources/browser-repl/page-clipboard.js` at document start in the
  page world of every frame. That script supplies a `navigator.clipboard`
  and `ClipboardItem` whose writes (a promised item once it settles) reach
  the tab's clipboard through a script message handler; they need no
  transient activation, since they reach only that tab and WebKit resets
  the page's activation after each script the driver evaluates, also
  between an agent click's press and release. It rejects their reads with
  `NotAllowedError`, and replaces `execCommand` so `copy` and `cut` fire
  the page's handlers with a `DataTransfer` and put what they set, or the
  selection, on the tab's clipboard, and `paste` returns false; it reads
  the command name with built-ins it captured before the page's scripts
  ran and hands WebKit only that string, so a page that replaces `String`
  or `String.prototype.toLowerCase` cannot turn a name it does not see as
  `copy` into WebKit's Copy. The guard stays on the web view for its life,
  also after the session leaves (later writes then fail). In a session's
  agent world the page agent's install starts with the same `execCommand`
  replacement (`BrowserReplPageClipboard.agentWorldGuardSource`, in every
  tab), whose `copy`, `cut` and `paste` return false, so a listener the
  agent registered cannot run WebKit's Copy with the gesture of its click.
  Residual, measured on macOS 27.0 (26A428): WebKit gives user scripts to
  a document when it commits, not to a frame's initial empty document (an
  iframe whose `src` is still loading or is a `javascript:` URL, a window
  the page opened before its first load commits). Same-origin script, the
  page's or the agent's, that reaches such a document while it holds a
  gesture (a person's, or one an agent's input gave) can call that
  document's own `execCommand("copy")`, and WebKit writes the system
  clipboard. Only a process-wide pasteboard hook could stop that, and cmux
  keeps none for the clipboard (the drag pasteboard's, see `input.drag`,
  covers only the drag pasteboard's name). `WKUserScript` has no option to
  match such documents (its private initializers take URL patterns, an
  associated URL, a content world and deferral only).
  Script the agent runs in its own world (`frame.evaluate` with `world:
  "agent"`, and the runtime's reads and element actions there, such as
  `focus` and `dispatchEvent`) runs without a user gesture (WebKit's
  `_callAsyncJavaScript` with `withUserGesture: NO`; a WebKit without it
  fails such calls with `unsupported`), and so does every script the
  driver runs for itself, in its own worlds or the agent's (the frame
  gate's checks and the scripts it gates, the clipboard shortcuts, capture
  masks, secret and focus checks, `tab.info`, frame names and boxes, waits,
  the sign-in fill, the page agent's install): agent code can have
  replaced a getter they read, and a page handler they set off would hold
  the gesture.
  A user's tab has no page clipboard guard: its pages keep the browser's
  clipboard. An agent's trusted input (`input.mouse`, `input.drag`,
  `input.key`, `input.insertText`) and its page-world `frame.evaluate` give
  that tab a user gesture, with which the page's own scripts (and the
  agent's page-world script) can write the system clipboard, as with a
  person's click (accepted). They never read it: with that gesture WebKit
  lets a script paste (`execCommand("paste")`) or read `navigator.clipboard`,
  asking the person with its Paste menu, or not at all when the clipboard
  holds data the same site copied (measured on macOS 27.0). So while an
  agent's input or page-world script runs in any tab, and for
  `BrowserReplTabOwnership.agentGestureLingering` (11 s) after the last one
  ends (a fetch callback the script set up keeps its gesture up to 10 s),
  the driver turns WebKit's `DOMPasteAccessRequestsEnabled` off for that web
  view (`BrowserReplPageClipboard.holdScriptPasteOff`): the page's script
  paste and clipboard reads fail (`NotAllowedError`, `false`) and no Paste
  menu opens. Then it is on again, unless it was off before (a tab a
  session created). Meanwhile a person's Command-V and Edit menu Paste
  still work (they are not script paste); a page's own Paste button that
  reads the clipboard by script is refused. A WebKit that cannot turn it
  off refuses such input and page-world scripts (`unsupported`). Residual:
  the switch is on the web view's `WKPreferences`, which a window a page
  opens can share with its opener. The hold remembers whether script paste
  was on before its first hold and puts that back when it ends; if a
  session creates a tab on those shared preferences while a hold lasts
  (its page clipboard guard turns script paste off for good), the hold's
  end turns it back on for that tab too. Popups of a user's tab are the
  user's, so this needs a session-created tab and a user's tab on one
  preferences object. The
  agent's clipboard shortcuts and `page.clipboard` are refused there
  (`unsupported`).
- Cookies: the domain policy applies by host, since a cookie belongs to a
  host and not an origin (a pattern's scheme and port do not narrow it).
  `cookies.clear` on a tab that shows a blocked page (its scope is that
  tab's site), and `cookies.get` or `cookies.set` with a blocked URL, fail
  with `blocked`. The runtime names the page's tab on every cookie call,
  and `cookies.get` and `cookies.set` use it only to pick the tab's data
  store, so a page showing a blocked site still sets and reads the
  cookies the policy allows. A cookie with a Domain attribute (leading dot)
  is in reach when a host an allowed pattern names receives it (its own
  domain or a parent domain); a host-only cookie (no leading dot) goes to
  its own host alone (RFC 6265), so it is in reach only when an allowed
  pattern names that host. Either needs a domain that is not one a prohibited pattern
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
| (all host functions) | Every holder below reserves from the session's resource ledger, which also bounds what they hold in memory together at 512 MiB; a call past any limit fails with one message form, `REPL session limit: <what> at most <limit> …`. The full list of limits is in [README.md, Limits](README.md#limits) |
| `print(level, text)` | append one output line; `level` is `log`, `info`, `warn`, `error` or `debug`; `text` is already formatted. An evaluation keeps at most 16 MiB of lines; the rest goes to `<tmpdir>/output-<evalId>.txt`, announced by a `# output continues in <path>` line and summed up by a last `# output truncated: …; full output: <path>` line. The file takes at most 64 MiB per evaluation, counted against the session's fs budget (2 GiB); past either, the rest is dropped with a `# output past N bytes … was dropped` line. The runtime's own error reports go through the call's output gate like `console` output |
| `setTimer(id, delayMs, repeat)` / `clearTimer(id)` | on fire the app calls `globalThis.__cmuxHostOnTimer(id)`; repeating timers keep firing until cleared, each fire `delayMs` after the previous callback ran, so a busy thread holds at most one queued callback per timer. `setTimer` returns `false`, scheduling nothing, when the session already has 10,000 timers scheduled or fired with their callback not yet run; the runtime's `setTimeout` then throws a `RangeError`. A timer belongs to the cell running when it was set, or to the cell of the timer whose callback set it (an interval re-arming itself); when that cell times out, its timers are cancelled with its fetches and driver calls, and `__cmuxReplCancel(message, evalId, timerIds)` drops their callbacks, so none runs in a later cell. The runtime also carries the cell's own token through its leftover work: code of a cancelled cell that resumes later (an await a page event or another cell settles, also inside an async function the cell awaited, which the engine's async stack names) is refused every host and driver call (`setTimer`, `fs`, `fetch`, `driverCall`, `secrets`, `policy`; an error with code `cancelled`), and a page listener the cell registered is dropped unrun. The host and driver objects agent code can reach (`page._session.host`, `page._session.driver`) are frozen copies whose prototype is `Object.prototype`; the unchecked ones stay in the runtime's closure, so no prototype walk reaches a call that skips the check. That check reads the JavaScript stack in the context agent code shares, so it keeps a cell's own late work from acting; it is not a guard |
| `driverCall(callId, method, paramsJSON)` | the app later calls `globalThis.__cmuxHostOnResult(callId, errorJSON, resultJSON)`; exactly one of the two is `null`; `errorJSON` is `{ code, message }`. A session runs at most 256 driver calls at once and queues up to 10,000 more in order; past that a call fails at once. A call whose `paramsJSON` is over 64 MiB (a `filechooser.respond` answer: its 256 MiB of files in Base64, plus 1 MiB) fails with `invalid` before it is parsed or queued, and so does one whose JSON holds more than 2,000,000 structural elements (each `[`, `{` and `,` outside a string) or nests deeper than 512 levels, since no timeout interrupts a parse on the session's thread (the same limits refuse the arguments of `fs` with `E2BIG`, and of `secrets` and `policy` with `invalid`, before they are parsed); one that would take the request data the session's waiting and running driver calls and fetches hold at once (their `paramsJSON` and `requestJSON`) past 512 MiB fails at once too. When a cell times out (or its session is reset or closed), the driver calls it started are cancelled (the driver stops the work where it can: a cancelled input call sends no further native mouse, drag, key or text event, since each step's tab check refuses it, also when a hidden tab borrows the render host) and its queued ones fail with `cancelled`. A call keeps its slot until the runtime has its result. A result (or error) over 64 MiB fails with `invalid` before it is masked or queued, and so does one that would take the results the runtime has not taken yet (a busy cell) past 512 MiB together, measured with secrets masked |
| `fetch(callId, requestJSON)` | request `{ url, method, headers: [[k, v]], bodyBase64?, targetId?, credentials?, origin? }`; result via `__cmuxHostOnResult`: `{ url, status, statusText, headers: [[k, v]], bodyBase64, redirected }`. Cookies come from, and `Set-Cookie` goes back to, the attached tab's cookie store (a cookie goes to a URL its domain matches and whose path its path matches by RFC 6265: a host-only cookie, one with no leading dot, only to its exact host, and a Domain cookie to its domain and subdomains but never to an IP address by suffix, so a `/account` cookie never goes to `/accounting`, and a Secure cookie only over `https` or to a loopback host: `localhost` and its subdomains, `[::1]` and an address in 127.0.0.0/8 written as four decimal parts, never a name that only starts with `127.`), for `credentials` `include` (default) always, `same-origin` only for URLs on `origin`, `omit` never; a `Cookie` or `Cookie2` header the caller sets is sent only where those rules send cookies (it replaces the tab's cookies there), so `omit` sends none on any request. A response's `Set-Cookie` is stored only as a browser would take it (RFC 6265 section 5.3): its Domain attribute must be the response's host or a parent domain of it, and not a public suffix (the system's Public Suffix List), and a Secure cookie only from an `https` response, so a fetched page never plants a cookie on another site. The domain policy is checked on the URL, every redirect hop and the URL the response came from, when its headers arrive and before its cookies are stored or its body returned (an HSTS upgrade to `https` moves a request without a redirect hop) (`blocked`); once a redirect leaves the first URL's origin, the request drops `Authorization`, `Proxy-Authorization`, `Cookie` and every header whose name marks a credential (`auth`, `token`, `api-key`, `secret`, `session`, `password`, `csrf`, `xsrf`, `credential`, `signature`) and every other header the caller set except the CORS-safelisted `Accept`, `Accept-Language`, `Content-Language`, `Content-Type` and `Range` (a header's name need not say it carries a credential), also on later hops back to it, and gets only the tab cookies the credentials rules give the new URL; a request body over 64 MiB fails with `invalid` before it is decoded or queued, and so does a request whose JSON could not hold at most 64 MiB of body plus 1 MiB; once parsed (off the session's thread, before anything is sent), a request whose URL, method, headers and decoded body together pass 64 MiB (one call's request limit of the session's resource ledger) fails with `invalid` too, so headers cannot take the body's room; a request counts against the 512 MiB of request data a session's waiting and running calls hold (`driverCall`); a response body over 64 MiB fails, and so does one that would take the bodies a session's fetches hold at once (received and not yet taken by the runtime, each counted once received at the size of the Base64 result that carries it) past 128 MiB; a fetch that has not finished after 10 minutes fails with `timeout`; a session has at most 16 fetches waiting for their response headers and 64 open in all, queues up to 256 more in order and fails one past that at once (`fetch: REPL session limit: fetches waiting for a slot at most 256 at once ...`); a fetch whose headers arrived leaves its slot, so un-awaited fetches of bodies that never end (event streams) cannot hold every slot; when a cell times out, the fetches it started are cancelled and its queued ones fail with `cancelled`; the session redacts the URL, headers and the body (text and other bytes alike, in one linear pass over the bytes: each value's UTF-8 bytes and their encoded and Base64 forms); a response that masking would grow by more than 8 MiB (a mask is longer than a short value) fails with `invalid` instead |
| `secrets(op, argsJSON)` | synchronous, `{"ok": value}` or `{"error": {code, message}}`: `set { name, value, domains, totp }`, `load { path, allowWeak? }` (read natively; a file over 8 MiB fails with `invalid` before it is parsed, and so does one not in UTF-8 or with a digit spelled `\u0030` to `\u0039`) or `load { object, allowWeak? }` (more than 16,384 domain patterns, or more than 16,384 name and pattern pairs in all, the most 256 secrets of 64 domains hold, fail with `invalid` before any value is looked at; without `allowWeak: true`, a value shorter than 8 characters or a common password fails the whole load with `invalid` before anything is registered, naming the secrets and never their values), `list`, `has { name }`, `delete { name }`, `clear`. No result holds a value. `load` stops with `cancelled` when the cell times out or the session ends: the file's Base64 decode every 256 KiB, and before and after its parse and between patterns (also in the weak-value check) |
| `policy(op, argsJSON)` | synchronous, as `secrets`: `get` → `{ allowed, prohibited, blockIPs, locked }`, `check { url }` → reason or `null`, `site { host }` → the host's site (registrable domain by the Public Suffix List, or the host itself when it has none), the same site `cookies.clear` scopes to, `publicSuffix { name }` → whether the name is itself a public suffix (the runtime's `tools.register` refuses a wildcard over one); a host or name over 1,024 bytes is no host name: `site` returns it lower-cased as given and `publicSuffix` false, without Punycode or a suffix walk, `set { allowed?, prohibited?, blockIPs?, lock?, title }` (a locked policy refuses) |
| `fs(op, argsJSON)` | synchronous; returns `{"ok": value}` or `{"error": {"code": "ENOENT"\|"EACCES"\|"EEXIST"\|"ENOTDIR"\|"EISDIR"\|"ENOTEMPTY"\|"EINVAL"\|"ELOOP"\|"ERR_FS_FILE_TOO_LARGE"\|"ERR_FS_DIR_TOO_LARGE"\|"EFBIG"\|"EDQUOT"\|"ECANCELED"\|"ENAMETOOLONG"\|"EBUSY"\|"denied", "message"}}`. A path (`path`, `from`, `to`) over 1,024 bytes (`PATH_MAX`) fails with `ENAMETOOLONG` before it is normalized or walked, and the message does not repeat it. Each root (`cwd`, `tmpdir`) is opened once when the session starts (a cell that moves the session to another `cwd` has it checked and opened when the cell is submitted, while no REPL `fs.rename` can run, refused when a link is on its path, and runs in the directory held then, refused when its path names another directory by the time the cell begins), or when an operation first opens or creates it (`mkdir -p`), by a walk from `/` with `openat` and `O_NOFOLLOW` (and `mkdirat` for missing directories) over the path as it was resolved, so a parent swapped for a link meanwhile is never followed (`EACCES`), and held: every operation walks from that held directory with `openat` and `O_NOFOLLOW`, follows a link only by reading it and while it stays inside a root, and acts relative to the directory it holds open (`fstatat`, `mkdirat`, `unlinkat`, `renameat`), so another session or local process can neither swap a link in between the check and the use nor redirect a root by renaming it away and putting a link or another directory at its path. Files open with `O_NONBLOCK` and are checked with `fstat` first: a FIFO, socket or device fails with `EINVAL` at once, `readFile` refuses a file over 64 MiB (`ERR_FS_FILE_TOO_LARGE`), and `readdir` a directory of more than 10,000 entries (`ERR_FS_DIR_TOO_LARGE`, once its read passes that many). `readFile` and `copyFile` of a file `secrets.load` read, in any session, fail with `denied` (see Secrets). While the session masks any secret value (its own or one another session typed), `copyFile` reads its source whole and writes it masked, as `writeFile` writes, so it copies at most 64 MiB then (`ERR_FS_FILE_TOO_LARGE`) and a source the masking limit refuses fails with `EINVAL`. One `writeFile` (also an append) or `copyFile` writes at most 256 MiB (`EFBIG`, before the file is opened) and a session at most 2 GiB over its life and 100,000 entry changes (each file a write or copy creates, also an empty one, directory made, entry renamed or removed, and each entry a recursive `rm` removes, taken before it is removed: past the limit the `rm` stops with `EDQUOT`, says how many entries it removed and leaves the rest; `EDQUOT`, a reset starts a new budget); they write 1 MiB at a time and stop with `ECANCELED` when the cell times out, a callback that outlived its cell passes the callback time limit, or the session ends (a stopped copy leaves no file); `readFile` (also the whole read of a masked copy and `secrets.load`) checks every 64 KiB it reads, the secret masking of file contents (`readFile`, `writeFile`, a masked `copyFile`), of a `fetch` body, of output text and of every driver result, page event and host answer (between strings and every 64 KiB of a string, before and after a JSON parse) every 64 KiB it scans, and the Base64 that carries file contents and `fetch` bodies every chunk (192 KiB encoded, 256 KiB decoded), so a synchronous call or a result delivery ends at the timeout instead of holding the session's thread (a cancelled driver result or host answer fails with `cancelled`, a page event arrives withheld, output text is replaced by a note), so a synchronous call ends at the timeout instead of holding the session's thread (a cancelled fetch body fails with `cancelled`); and so do `readdir` and a recursive `rm`, checked every 1,024 entries (for `rm`, entries handled and directories opened together, so a deep chain of empty directories stops too; a stopped `rm` leaves what it had not removed yet); `copyFile` copies the source's extended attributes after its data, each taken from the same write budget as part of the call, checking for cancellation between them; it leaves out one the destination refuses, and one past 1 MiB, unread (the copy succeeds and its result is `{ warnings: [...] }`, a line per attribute left out that names it and its size, which `fs.copyFile` prints as a `warn` line); a recursive `rm` reads a directory 1,024 entries at a time and removes them before it reads on, so it never holds a large directory's whole list nor lists it again for each subdirectory. A directory held open stays usable after it is moved, so each system call relative to a directory below a root (`openat` of what it acts on, `fstatat`, `mkdirat`, `unlinkat`, `renameat`) runs under the lock every REPL `fs.rename` holds, right after a walk up the directory's `..` entries reaches the root by identity: a directory another session (one whose root holds this one's) moved out of the root since the walk opened it fails the call with `EACCES`, and nothing is made, written or removed there (a recursive `rm` stops; a file already open stays the file opened inside the root). The lock is held for that one call only, so a slow operation holds only its own session. Residual, outside the threat model: a same-user process that changes a path inside a root between two operations changes what the second one finds there (never a path outside the roots) |
| `readResource(relativePath)` | text of a bundled `Resources/browser-repl/` file, or `null` |
| `tmpdir`, `homedir` | the session's private temporary directory (`<app temp>/cmux-browser-repl/<session>-<random>-tmp`, mode 0700, removed on close when empty; no other session's files are in it) and the canonical home directory, for `node:os`. The directory and its parent are made with `mkdirat` and `openat` (`O_NOFOLLOW`) from the app's temporary directory: a link in place of `cmux-browser-repl`, or a parent another user owns, makes no directory (fs calls there then fail). The session holds the new directory open; output spills are created in it with `openat` |

`fs` ops, paths relative to `cwd` (absolute paths must stay inside `cwd` or
the session's own `tmpdir`, never the system temporary directory that other
sessions and apps share, except files the driver reported through
`download.finished`, which are readable): `readFile {path}` → base64 (secrets redacted, text or bytes), `writeFile {path, base64, append?}` (secrets redacted; either fails with `EINVAL` when masking would grow the contents by more than 8 MiB; every other answer, names and paths and error messages too, is masked as text),
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
destination stays intact until the new file is complete. That rename runs
while no REPL `fs.rename` and no browser file grant runs, and only while
the temporary entry is still the regular file the copy wrote (same device
and inode, not followed); a link moved in for it makes the copy fail with
`EBUSY`, never publishes the link. The temporary file (named
`.<name>.cmux-copy-<UUID>`) is made write-only (mode 0200) and gets the
source's mode only after the copy checked that no `secrets.load` protected
the source meanwhile; no session's `fs` reaches a path through such a name
(`EACCES` for every op), `readdir` leaves it out and a tab does not load it,
so a source another session protected during the copy is never readable
under the temporary name.
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
  (a finished download still becomes readable). The bytes count as the
  event will reach the runtime: masking can make an event longer, and one
  that masked would take the waiting events past 64 MiB arrives withheld
  (`{ targetId, withheld }`). When the limit ends a call,
  the timers it set (an interval re-arming itself) are cancelled. The next
  cell's output starts with `error` lines saying how many callbacks were
  stopped, waited or were dropped. After the session closes
  (`cmux browser repl reset`, idle expiry) every script is terminated and
  the app makes no further call into the context.
- `__cmuxHostOnEvent(name, payloadJSON)` delivers every driver event.
  The session masks secrets in each on a queue of its own, off the
  session's thread, in the order events arrived, and a driver call's
  result goes through that queue too, so an event sent before a call
  returned is delivered before its result. A payload past 1 MiB, or one
  masking would grow past the redaction limit, arrives as
  `{ targetId, withheld }`: the tab and why its content was left out.
- `__cmuxHostOnTimer(id)`, `__cmuxHostOnResult(callId, errorJSON, resultJSON)`.

Script load order: `manifest.json` in `Resources/browser-repl/`,
`{ "repl": [...], "agent": [...] }`, paths relative to that directory. `repl`
scripts run in order in the REPL context; `agent` scripts install in order in
the agent world. A missing or malformed manifest, or a listed file that does
not exist, fails the evaluation with an error naming the path; nothing is
skipped. `cmux browser repl guide` prints `guide.md` from the same directory
when present.

### Agent world

- Each session has a content world of its own, `cmux-agent-<random>`
  (`BrowserReplSessionWorld`), in every tab it drives. Its page agent, refs
  and handles live there, and `frame.evaluate` with `world: "agent"` runs
  there; any other `world` value runs in the page's world. Two sessions that
  drive one tab share nothing in the agent world: one session's code that
  patches built-ins (`WeakRef.prototype.deref`, `Map.prototype.get`,
  `Array.prototype.filter`), DOM prototypes (`getBoundingClientRect`,
  `elementFromPoint`), `window.frames` or the agent object changes only its
  own world, never another session's refs, handles, hit tests, press checks
  or frame positions. The world sees closed shadow roots (see README,
  Snapshot).
- The driver's own scripts run in private worlds that no session's
  `source` reaches: the frame gate's document, focus and frame-box probes,
  frame binding's child reports, `tab.info`, frame names, load waits, the
  screenshot's viewport read and the clipboard shortcuts (`cmux-driver`)
  and capture masks (`cmux-capture-mask`). What reads the session's own
  handles runs in the session's world: element actions, the press check,
  `frame.contentFrame(s)`, `frame.ownerBox`, `input.setFiles`, the file
  chooser's element and the rich-text check of `input.insertText` (that
  world sees closed shadow roots); code there is the session's own.
- A world's name is used once. WebKit hands a named world back by name while
  anything holds it and has no call that clears what a world holds in a
  loaded document, so a name is never pooled: a session never gets a world
  an ended session used, nor what it left in a page.
- Scripts are added to a tab's `WKUserContentController` (document start,
  all frames), one per session world, when a session first touches the tab;
  frames that loaded earlier get the scripts on the first `frame.evaluate`.
  Each script runs only while its world has the `cmuxReplAgent` message
  handler, added and removed with it; both leave the controller when the
  session detaches from the tab. What a session's agent left in documents
  already loaded stays in its world, which no later session gets, until
  they navigate.
- Each session runs its own agent (about 400 KB of script) in every frame
  of every document the tab loads, so at most 4 sessions drive one tab at
  once (`BrowserReplTabSessionLimit`, measured in
  [performance.md](performance.md#agent-worlds)). A fifth session's call on
  the tab fails with `limit` (`REPL session limit: sessions driving one tab
  at most 4 at once (4 held, this needs 1 more); …`) and the tab is not
  attached; it attaches once one of the four ends.
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
  targets, then runs `source`. Detached elements fail with `stale`. The
  page's world belongs to the page: its script can patch the built-ins and
  DOM prototypes the bridge and `source` use, so it can hand `source` other
  elements, as it can change what `source` reads or does with the right
  ones. Nothing the session holds crosses into that world but `source`,
  `args` and the elements, and the result passes the egress gate, so this
  gives the page no access it lacks (accepted). Code that must act on the
  elements the agent world found, unchanged by the page, runs with
  `world: "agent"`.
- Evaluation errors carry `{ code, message, errorName }`; page exceptions use
  code `evaluation` unless the thrown value has its own `code`. The page
  chooses all three, so the session's egress gate masks each of them as it
  masks a result.
- `tab.info` answers from native state (URL, title, `isLoading`) while a
  JavaScript dialog is open, since page script is blocked then.
- `frameId` is WebKit's frame handle id (`-[WKFrameInfo _handle].frameID`);
  frames come from `-[WKWebView _frames:]`.
- Network events come from `-[WKWebView _setResourceLoadDelegate:]`; without
  that SPI no `request`/`response` events are sent. Each request is bound to
  its document by `_WKResourceLoadInfo.documentID`, matched against
  `-[WKFrameInfo _documentIdentifier]` from a frame tree read; WebKit gives
  no initiating frame beyond that. A document the tree no longer shows by
  the read (a frame that navigated away first, a short-lived `about:blank`
  or `srcdoc` child) cannot be judged, so under an active policy or file
  root its requests are dropped for that session rather than sent
  unjudged. A document the gate read once is remembered (up to 1,024 per
  tab), so a request's later events stay deliverable after the frame
  navigates.

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
