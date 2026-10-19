# Browser REPL edge cases

Every row is one differential case in
[tests/browser-parity/diff/cases](../../tests/browser-parity/diff/cases)
(the `edge` field names the id). The case runs the same task in cmux, reference A
and reference B where the reference can run it inside the approved
test scope, and [parity-report.md](parity-report.md) lists its verdicts.
`tests/browser-parity/unit/diff.test.mjs` fails when a row has no case or a
case names an id that is not here.

Scope for the references: reference B runs on one approved origin
(`http://127.0.0.1:PORT`), so rows that need another origin, TLS or DNS are
out of scope for it; reference A runs on loopback fixture pages, so rows that need a
public name (`lvh.me`, `.invalid`) are out of scope for it. Rows that act on
processes or on a person's window run in the cmux app only.

## Network and navigation

| Id | Scenario | cmux behavior | Case |
| --- | --- | --- | --- |
| `auth-basic` | HTTP Basic challenge, with and without credentials in the URL | Without credentials `goto` resolves at once with the 401 response (no prompt blocks the tab); `user:pass@` in the URL answers the challenge | `edge.auth-basic` |
| `auth-digest` | HTTP Digest challenge | Same as Basic; `user:pass@` in the URL answers the digest challenge | `edge.auth-digest` |
| `tls-self-signed` | HTTPS with a self-signed certificate | `goto` rejects with a certificate error; the tab is not left on an interstitial | `edge.tls-self-signed` |
| `nav-dns` | Host that does not resolve | `goto` rejects with a DNS error and the tab stays on the previous page | `edge.nav-dns` |
| `nav-refused` | Port with nothing listening | `goto` rejects with a connection-refused error, quickly | `edge.nav-refused` |
| `nav-404` | 404 response | `goto` resolves with `status() === 404`; the page is loaded | `edge.nav-http-errors` |
| `nav-500` | 500 response | `goto` resolves with `status() === 500` | `edge.nav-http-errors` |
| `nav-aborted` | A second `goto` while the first is loading | The first rejects as interrupted; the second wins | `edge.nav-aborted` |
| `nav-redirect-loop` | A URL that redirects to itself | `goto` rejects with a too-many-redirects error | `edge.nav-redirect-loop` |
| `slow-load` | A document that takes 3 s | `goto` waits for load and resolves | `edge.slow-load` |
| `never-finishing-load` | A body that never ends (a streamed page) | `waitUntil: "commit"` resolves and the partial page is usable; `load` times out at the given timeout. WebKit keeps a nearly empty partial page blank and holds input until it has content, so the fixture streams paragraphs | `edge.never-finishing-load` |
| `spa-route-wait` | Client-side route change with delayed rendering | `waitForURL` matches the pushed URL; locator waits find the new view | `edge.spa-route-wait` |
| `service-worker` | A page controlled by a service worker | The worker registers, controls the page and answers its fetch | `edge.service-worker` |
| `websocket` | WebSocket echo | The page's socket opens and echoes | `edge.websocket` |

## Cookies, storage and permissions

| Id | Scenario | cmux behavior | Case |
| --- | --- | --- | --- |
| `cookies-flags` | HttpOnly, Secure, SameSite cookies | `document.cookie` omits HttpOnly; requests send all of them | `edge.cookies-flags` |
| `cookies-subdomain` | `Domain=` cookie across sibling subdomains | Sent to the sibling subdomain, not to another site | `edge.cookies-subdomain` |
| `storage-isolation` | localStorage and sessionStorage across two tabs of one origin | localStorage is shared, sessionStorage is per tab | `edge.storage-isolation` |
| `permission-geolocation` | `getCurrentPosition` | Settles without a prompt blocking the driven tab | `edge.permission-geolocation` |
| `permission-notifications` | `Notification.requestPermission()` | Settles without a prompt blocking the driven tab | `edge.permission-notifications` |
| `permission-camera` | `getUserMedia({ video: true })` | Settles (denied) without a prompt blocking the driven tab | `edge.permission-camera` |
| `permission-clipboard-read` | `navigator.clipboard.readText()` | Settles without a prompt blocking the driven tab | `edge.permission-clipboard-read` |
| `context-options` | `session.configure` with a user agent, an extra header, a granted permission, then a proxy | The user agent shows in requests and `navigator.userAgent`; the header is on navigations, not subresources; a granted permission is granted and the rest denied at once; clearing restores the tab; a tab opened after `proxy` connects through the proxy | `edge.context-options` |

## Downloads and files

| Id | Scenario | cmux behavior | Case |
| --- | --- | --- | --- |
| `download-blob` | `blob:` URL download | `download` event with the name; the file is readable | `edge.download-blob` |
| `download-data` | `data:` URL download | Same | `edge.download-data` |
| `download-content-disposition` | `Content-Disposition: attachment` | Same, with the server's filename | `edge.download-cd` |
| `download-post` | Form POST whose response is an attachment | Same; the page stays where it was | `edge.download-post` |
| `download-concurrent` | Two slow downloads in flight at once | Two `download` events, both files complete | `edge.download-concurrent` |
| `file-drop` | Dropping a file on a drop zone | `dispatchEvent("drop", { dataTransfer: { files } })` builds a real `DataTransfer` in the page and delivers the files | `edge.file-drop` |
| `input-file-accept` | File input with `accept` | `setInputFiles` sets files regardless of `accept`, like Playwright | `edge.input-types` |

## Input and forms

| Id | Scenario | cmux behavior | Case |
| --- | --- | --- | --- |
| `select-multiple` | `<select multiple>` | `selectOption([...])` selects all given values and returns them | `loc.select-option.forms` |
| `input-date` | `type=date` | `fill("2026-09-30")` sets the value; invalid text fails | `edge.input-types` |
| `input-time` | `type=time` | `fill("13:45")` | `edge.input-types` |
| `input-color` | `type=color` | `fill("#ff0000")` | `edge.input-types` |
| `input-range` | `type=range` | `fill("70")` | `edge.input-types` |
| `contenteditable-bold` | Rich editor, select all and bold with the keyboard | Native Meta+B toggles bold; typing continues after it | `edge.contenteditable-bold` |
| `typing-unicode` | Accents, emoji, CJK, ZWJ sequences | Typed text arrives exactly | `edge.typing-unicode` |
| `composition-events` | IME-style commit | `keyboard.insertText` commits the text with trusted `input` events | `edge.composition` |
| `ime-only-editor` | A Google Sheets style cell editor that drops text arriving without a keydown or a composition, and an editor that reverts text no trusted `beforeinput` announced | In a `contenteditable` editor, `keyboard.insertText` and `fill` commit through an IME composition, so the editor takes the text; a form field gets one plain `input` event | `edge.ime-only-editor` |
| `trusted-paste` | An editor that reads a paste from the event's `clipboardData` | Meta+V fires a `paste` event carrying the tab's clipboard and Meta+C fills the tab's clipboard from a `copy` event; both are dispatched (not trusted), since the tab's clipboard is virtual, so an editor that accepts only a trusted paste ignores it; the system clipboard is untouched | `edge.trusted-paste` |
| `keyboard-shortcuts` | Shortcuts with modifiers (`ControlOrMeta+a`, `Alt+Shift+K`) | Native key events with the modifiers held | `keyboard.shortcuts` |
| `hover-menu-delay` | Menu that opens 300 ms after hover | `hover()` then a locator wait finds the menu item | `loc.hover` |
| `hidden-disabled` | Hidden, disabled and read-only targets | Actions fail naming the failed check (not visible, disabled, not editable) | `loc.failure-kinds` |
| `overlay-intercepts` | A fixed overlay covers the target | The click fails naming the element that would receive it; nothing is clicked | `edge.overlay-intercepts` |
| `element-detached-mid-click` | Target re-rendered every 40 ms; target removed on mousedown | Locator clicks re-resolve and land; a removed target is reported | `edge.detached-mid-click` |
| `stale-ref-after-navigation` | A snapshot ref used after the page loads again | Fails at once as stale; never acts on a new element | `edge.stale-ref` |

## Layout, frames and windows

| Id | Scenario | cmux behavior | Case |
| --- | --- | --- | --- |
| `nested-scroll` | Target inside two nested scroll containers | Actions scroll every container that clips the target | `edge.nested-scroll` |
| `infinite-scroll` | Feed that loads more on scroll | Scrolling a sentinel into view loads more items | `edge.infinite-scroll` |
| `zoomed-page` | CSS `transform: scale` and `zoom` | Clicks land on scaled and zoomed targets | `edge.zoom-scale` |
| `device-scale` | Screenshot pixels versus CSS pixels | Clips are in CSS pixels, captured at the device scale | `edge.zoom-scale` |
| `iframe-sandboxed` | `sandbox` attribute and CSP `sandbox` frames | Frame locators act inside; script-less frames still show in the snapshot | `edge.iframe-sandboxed` |
| `iframe-srcdoc` | `srcdoc` frame | Frame locators and the snapshot reach inside | `edge.iframe-srcdoc` |
| `iframe-navigation` | A frame navigates to another document | Frame locators and the snapshot follow the new document | `edge.iframe-navigation` |
| `window-open-features` | `window.open(url, name, "width=...")` | A `popup` event with a page that has an opener | `edge.window-open` |
| `window-open-noopener` | `window.open(url, "_blank", "noopener")` | A `popup` event; the popup has no opener | `edge.window-open` |
| `window-close` | A popup calls `window.close()` | The page emits `close` and leaves `tabs.list()` | `edge.window-open` |
| `beforeunload` | Leaving a page with a beforeunload handler | A navigation the agent starts leaves without a prompt, as in both references (Chrome accepts the prompt itself); a prompt WebKit does raise is held in `page.dialog()` | `dialogs.beforeunload` |
| `alert-during-navigation` | `alert()` while the document loads | The dialog is held; answering it lets the navigation finish | `edge.alert-during-navigation` |
| `large-page` | 5,000 rows with 10,000 controls | The snapshot value holds everything; locators act on any row | `edge.large-page` |
| `main-thread-blocked` | A click handler that blocks the main thread for 2.5 s | Calls wait for the page and then succeed | `edge.main-thread-blocked` |

## Sessions and processes

| Id | Scenario | cmux behavior | Case |
| --- | --- | --- | --- |
| `sessions-two-tabs` | Two REPL sessions, each on its own tab, at once | Both finish with their own results; no cross-talk | `edge.sessions-two-tabs` |
| `sessions-same-tab` | Two sessions on one tab | A tab a running session opened is its own: another session lists it with `ownedBy` and `tabs.use()` fails naming the owner; concurrent calls of the one session both land (sessions share a tab by being one `--session`) | `edge.sessions-same-tab` |
| `legacy-socket-refused` | Another client calls the older `browser.*` socket methods (`cmux browser <surface> eval`, `click`, `snapshot`) on tabs sessions drive | A tab a session opened, and a user's tab it drives with `tabs.use()`, are refused with an error that names `cmux browser repl`; the tab list still shows them; a user's tab no session drives works, also once the session that drove it ended | `tabs.legacy-socket-refused` |
| `web-process-crash` | The tab's web content process is killed | The page emits `crash`; calls fail as crashed until `reload()` or `goto()`, which recover | `edge.web-process-crash` |
| `user-click-while-driving` | A person clicks in the pane while a session types | The person's click arrives as trusted input and the session's typing is intact | `edge.user-click-while-driving` |
