# WebKit tab duplication prototype (feed.md section 10)

This prototype runs the WebKit column of feed.md section 10.2 (N12, FD3 to FD5) live. It is not product code. It proves the mechanism that a future `WebKitTab.duplicate` uses.

## What it does

`server.py` is a test site on 127.0.0.1 with a random port. It sets an HttpOnly session cookie and a plain cookie, serves a page with a text input, a login form and a tall body, a POST-result page, a service worker, a cookie echo (`/whoami`) and per-path request counts (`/stats`). An inline head script on every page records what the page sees before its other scripts run: sessionStorage, the agent shim and service-worker control.

`main.swift` is one AppKit accessory app. It never activates. Each WKWebView is in a borderless window at -20000,-20000 that is never ordered front. The app starts `server.py`, runs the steps below, prints a JSON report, stops the server and exits.

1. Agent tab A: a `WKWebsiteDataStore(forIdentifier:)` store (like the agent profile), a document-start shim `window.__agentShim = 1` in the page world, cookies from the server, localStorage, sessionStorage, a typed input value and a scroll offset.
2. Duplicate D: the same store, a new `WKUserContentController` (the `WebKitEngine.prepare` path), `D.interactionState = A.interactionState`, and A's top-origin sessionStorage written by a document-start script in the app-private world `cmux.duplicate`. The seed script removes itself at D's first commit.
3. Sign-in in D: a page script sets a sessionStorage key and a JS cookie, then posts the login form. The server sets a new HttpOnly session and redirects (303) to `/home`.
4. Copy-back: the app reads D's top-origin sessionStorage from the app world, closes D, seeds A with a one-shot app-world script, and loads D's final URL in A with GET.
5. Extra scenarios: a POST history entry, form state of back entries, and service workers.

## Run

```sh
plans/cmux-next/feed/prototypes/webkit-duplicate/run.sh
```

One `swiftc` compile and one run take about 25 s together. The binary is in `$TMPDIR/cmux-webkit-duplicate-proto/`. Exit 0 means every check passed. Progress lines go to stderr. `PROTO_SERVER_LOG=1` shows server requests. `PROTO_ORDER_FRONT=1` orders the offscreen windows front; the recorded run did not need it.

Each run clears its own store and removes the empty stores of earlier runs (`~/Library/WebKit/webkit-duplicate/`). The network process keeps the current run's store busy until exit, so one empty store directory stays until the next run.

## Recorded results

macOS 27.0 (26A428), WebKit 22625.1.29.11.27, 2026-10-02. 26 of 26 checks passed. `results.json` is the full report. "Observe" rows record behavior without a pass/fail claim.

| Id | Check | Result | Value |
| --- | --- | --- | --- |
| A1 | Agent shim runs in A | pass | `1` |
| A3 | A sends HttpOnly `sid` and `pref` | pass | `pref=dark; sid=agent-session` |
| C1 | Control: interactionState alone carries sessionStorage | observe | no: head saw `{}` |
| C2 | Control: `configuration.copy()` of A | observe | same controller, shim `1` in the copy |
| D0 | Read A's top-origin sessionStorage from the app world | pass | `ssKey=agent-ss` |
| D1 | D restores A's current entry | pass | finish, URL equal to A's |
| D1n | Restore goes to the network | observe | no: 0 GET requests (HTTP cache) |
| D2 | D's back list equals A's | pass | 0 = 0 |
| D3 | D sends A's cookies incl. HttpOnly | pass | `pref=dark; sid=agent-session` |
| D3h | `sid` is HttpOnly in D | pass | `document.cookie` = `pref=dark` |
| D4 | D sees A's localStorage | pass | `agent-ls` |
| D5 | Inline head script in D sees the seeded sessionStorage | pass | `ssKey=agent-ss` before page scripts |
| D6 | D sessionStorage after load | pass | `agent-ss` |
| D7 | Form value of the current entry in D | observe | not restored (empty) |
| D8 | Scroll offset in D | pass | `1234` |
| D9 | Agent shim absent in D | pass | head `null`, later `undefined` |
| D10 | Seed script gone after first commit | pass | 0 user scripts |
| D11 | Site change in D survives a reload | pass | `changed-in-D` |
| S1 | Sign-in in D ends on `/home` | pass | finish `/home` |
| S2 | D has the new session | pass | `js_login=1; sid=user-session` |
| S3 | D's history after POST + 303 | observe | `/page > /home`, no `/login` entry |
| S4 | Cookie diff over D's lifetime (FD3 hide list) | pass | `js_login`, `sid (HttpOnly)` |
| B1 | A loads D's final URL by GET | pass | finish `/home` |
| B2 | A sends the new session | pass | `js_login=1; sid=user-session` |
| B3 | A's inline head script sees D's sessionStorage | pass | `authToken=tok-123`, `ssKey=changed-in-D` |
| B4 | A keeps its agent shim; only the seed is removed | pass | shim `1`, 1 user script |
| B5 | A's history has no `/login` entry | pass | `/page > /home` |
| P1/P2 | Restore of a POST entry, no guard | observe | **re-POSTs**: policy `POST backForward` → `-999` → policy `POST formResubmitted` → server got POST #2 |
| P3 | Restore with a policy that cancels main-frame POST | pass | 0 POSTs; D has no current URL, back list `/form` |
| F1 | Back entry form state in D (A's page in back/forward cache) | observe | values empty, scroll `777` |
| F2 | Control: goBack in A3 itself | observe | values kept (`persisted: true`, live page) |
| F3 | Back entry form state in D (A4 without back/forward cache) | observe | values restored, scroll `777` |
| F4 | Control: goBack in A4 itself, no back/forward cache | observe | values restored |
| W1 | Agent's service worker controls a new tab in the same store | pass | `true` |
| W3 | After removing the origin's registrations a new tab is not controlled | pass | `false` |

## Findings

1. The mechanism works with public API. Cookies (incl. HttpOnly), localStorage and service workers are shared through the store. History and scroll come through `interactionState`. sessionStorage does not (C1); the app-world document-start seed fills it before the page's first inline script (D5).
2. WebKit saves form state into a history item only when the document is destroyed. The current entry's values (D7) and back entries that live in the back/forward cache (F1) are not in `interactionState`. Feed.md 10.1 says `interactionState` carries form state; correct it to "scroll and history; form values only for entries that left memory".
3. Restoring a POST entry sends the POST again with no prompt (P1). The duplicate needs a `decidePolicyFor navigationAction` guard that cancels a main-frame POST with type `backForward` or `formResubmitted` during restore (P3). After a cancel, D has no current page; the app then loads A's last GET URL.
4. `WKWebViewConfiguration.copy()` shares the agent's `WKUserContentController` (C2). The duplicate must use the engine's fresh-controller path, never a copy of A's configuration. `WebKitEngine.prepare` already does this.
5. `WKUserContentController` has no public per-script or per-world removal. Removing the one-shot seed is "remove all, re-add the others" (B4). On A this also re-adds the agent's scripts, which is correct but must not race an agent that edits scripts at the same time; the browser host pauses A's lease during the request, so no agent writes happen then.
6. The restore in D served `/page` from the HTTP cache (D1n). Inline scripts still ran, so the seed ordering holds.
7. A service worker the agent registered controls D (W1). Removing the origin's registrations before D opens stops that (W3). The removal unit is the whole data record (registrable domain), not "registrations created during the lease".
8. The cookie diff across D's lifetime (S4) gives the FD3 hide list: name, domain and path of every cookie that is new or changed while D is open.

## UNVERIFIED

- The passkey ceremony in D. It needs a signed build with the browser passkey entitlement (passkeys.md K18).
- A real user typing in D. The prototype sets values from scripts; it does not synthesize input.
- Cross-origin sign-in flows (an identity provider on another origin). FD5 covers the top origin only; this prototype uses one origin.
- Iframes, partitioned cookies and IndexedDB. Not tested; IndexedDB is shared by the store like localStorage, by design, but no check covers it.
- Visibility and occlusion effects. The windows were never ordered front.
- The CEF column of section 10.2. Another lane owns the fork export `cmux_tab_duplicate`.
