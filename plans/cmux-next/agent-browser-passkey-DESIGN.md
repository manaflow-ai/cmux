# Agents never take over the user's browser; passkeys come to the user

Status: design plus first slice, 2026-10-20. Owner: the "Agent browser passkey focus" agent.
Coordinates with a352 (Chief auth escalation skill: owns `escalate_auth` and the Chief
skill text) and a337 (browser focus mode). Inputs: [passkeys.md](passkeys.md) (K16, 3.5),
[chief-browser-use-DESIGN.md](chief-browser-use-DESIGN.md) (`cmux browser right`),
[automation-lease.md](automation-lease.md), OWNERSHIP-PRINCIPLES.md.

Ask (Lawrence, 2026-10-20): "the passkey sometimes gets 'document is not focused' … If an
agent wants to use a backgrounded web page, how can we handle that better? … I was using a
browser but then an agent kind of took over the browser, which is very bad."

## 1. What happens today (causes)

### 1.1 Takeover

`browser.page.right` (`cmux browser right <verb>`, every Chief's browser target) picks a tab in
the column right of the Home chat in this order: the agent's own tab, a tab it already holds,
**else the tab the column shows**, else a new tab. Two of those steps take the user's browser:

1. **No URL, no own tab: the agent leases the user's shown tab.** `cmux browser right click e3`
   (or `fill`, `press`, `eval`, `navigate` without a fresh tab) runs on the page the person is
   reading or typing in. The lease even locks the user's own tab against other agents. Tests
   codified it (`theShownBrowserTabOfTheHomeRightColumnIsTheTarget`).
2. **A new agent tab is opened selected.** `openBrowser` with `focus: false` keeps keyboard focus
   but still makes the new tab the pane's shown tab (`PaneController.newBrowserTab`,
   `background: false`). When the person is working in that pane, their page vanishes behind the
   agent's. The same holds for `cmux browser open URL --pane`, MCP `tab_create_browser` and
   `cmux tab new-browser`: every agent-origin open selects its tab.

Keyboard focus itself is not stolen (OWNERSHIP-PRINCIPLES: only `origin == user` or `focus: true`
changes the view), but "what the pane shows" and "which page agent input lands in" were not
covered by that rule.

### 1.2 "The document is not focused"

WebAuthn starts only in a focused, visible document:

- **WebKit:** `navigator.credentials.get/create` rejects with `NotAllowedError: The document is
  not focused.` unless the frame's document has focus (`Document::hasFocus()`, the page's window
  is key and the web view is first responder-capable) at the call. a352 confirmed on the NIGHTLY
  WebKit right pane: in a hidden tab the call fails with exactly that; after the tab was shown the
  same call waited with no error (the Touch ID sheet up).
- **CEF/Chromium:** `ChromeWebAuthenticationDelegate::IsFocused` is
  `web_contents->GetVisibility() == VISIBLE`, checked at the start and at completion
  (passkeys.md K16).

So an agent working in a background tab (the right way, per 1.1) reaches a passkey step that the
engine refuses by design. The fix is not to make the page think it is focused; it is to bring the
page to the person at the right moment.

## 2. Principles

1. **The person's tab is theirs.** An agent reads the shown tab freely (snapshot, screenshot,
   state); it never clicks, types, evaluates or navigates in it unless the person handed it over
   (an explicit `take`). Agents drive their own tabs.
2. **The pane the person is in keeps showing what they chose.** An agent's new tab opens
   unselected there; elsewhere (the person is in the chat) it opens shown, so they watch the
   agent work, which is the point of the right column.
3. **A ceremony runs only in front of the person.** Passkeys, Touch ID and security keys always
   start in a visible, focused tab in the key window, after the person asked for it with one
   click. No engine flag makes a hidden page count as focused.
4. **The agent never sees credential bytes** (passkeys.md 3.5.4); it learns a status only.

## 3. Design

### 3.1 Agent tabs (takeover)

`browser.page.right` gets the verb the CLI will run (`verb`, for example `browser.page.click`):

| Case | Before | After |
| --- | --- | --- |
| Agent's own tab in the column | it | it (unchanged) |
| Read verb (`snapshot`, `screenshot`, `state`, `wait`, `tabs`, `text`, `value`) or `passkey` (it only asks the person), no own tab | lease the shown tab | the shown tab, **no lease** (`shared: true`) |
| Any other verb, no own tab, no URL | lease the shown tab | `user_tab` error naming the tab and its URL: "open your own tab: `cmux browser right navigate <url>`" |
| `take: true` (`--take`, only when the person asked) | n/a | lease the shown tab as before |
| URL given, no own tab | new tab, selected | new tab; **unselected when the person's focus is in that pane** (`background: true`) |

An old CLI sends no `verb`; the app treats it as a write verb (safe default: no takeover).

`action.run` gets a run option `background: true` (like `focus`, not an action argument), carried
as `ControlActionRequest.background` → `ActionInvocation.opensInBackground`. `openBrowser`
honours it. And an agent-origin `openBrowser` (`cli`, `mcp`, `script`) without `focus: true`
opens in the background whenever its pane is the window's focused pane, so `cmux browser open`,
MCP `tab_create_browser` and `cmux tab new-browser` follow principle 2 too.

Rejected: a hidden off-screen window for agent tabs. WebKit throttles and does not draw hidden
windows (screenshots fail, `snapshotUnavailable`), CEF reports them hidden (K16), and the person
loses sight of the agent. A **visible "Agent" window** (one per Chief, behind the main window,
never key) stays an option for a later slice if column tabs are not enough; it would use the same
`background` plumbing.

### 3.2 Passkey hand-off (focus and trigger)

New page verb `browser.page.passkey` (`cmux browser <tab|right> passkey [REF] [--agent NAME]
[--reason TEXT]`):

1. The agent drives its own tab to the sign-in step and names the element that starts the
   ceremony (`REF` from a snapshot, for example the "Sign in with a passkey" button), or none when
   the page already called WebAuthn and waits.
2. If the tab is already shown in the key window with the app active, the app focuses the page and
   clicks `REF` at once: status `triggered`.
3. Otherwise the app records a pending request and posts a banner: title "<agent> needs your
   passkey", body "<site>: click to show the page and use Touch ID". Status `pending` with the
   request id. (The Home card is a352's `escalate_auth` message in the chat; it carries the same
   request id. A daemon notification row is a later slice.)
4. The person clicks the banner (or the Home card's action, later). The app reveals the tab:
   selects it in its pane, shows its workspace, brings its window to the front and makes the page
   first responder; then clicks `REF`. The engine sees a focused, visible document and shows the
   Touch ID sheet. The person only touches the sensor.
5. A request runs once; it expires after 5 minutes; a later raise for the same tab replaces the
   earlier one (its banner is withdrawn).

Why agent-raised, not a page hook: the agent knows it is at a passkey step, the page cannot spoof
the request (a page-world wrapper around `navigator.credentials` could be called by any site to
post "needs your passkey" banners, a phishing aid), and no private WebKit API is needed (K9).

The click is the person's intent, so the reveal may change focus and the shown workspace
(`origin: user` semantics), as a notification click already does.

### 3.3 Engine-level options (not taken)

| Option | Effect | Security tradeoff | Verdict |
| --- | --- | --- | --- |
| WebKit: make a hidden view count as focused (`_setFocused`-style SPI, swizzling `hasFocus`) | ceremony starts in a hidden tab | private API (K9 crash class); a page or agent could put a Touch ID sheet in front of a person who cannot see which site asks | no |
| CEF: report `VISIBLE` for a hidden tab (`WasHidden(false)`) | Chromium starts it | same unseen-origin problem; breaks occlusion savings | no; only keep `VISIBLE` for partial cover (K16) |
| User-gesture hand-off: the banner click grants transient activation to the page | sites that demand activation (`create`) succeed | the gesture is the person's, scoped to one tab and one request | yes, implicitly: the reveal click is the gesture; WebKit's `evaluateJavaScript` click is enough for `get` today (a352's run) |
| Defer: hold the page's rejected call and retry after reveal | no agent step needed | needs the page-world hook above | later, only from an isolated content world with no page-callable trigger |
| Virtual authenticator (CEF DevTools) for agent test sites | agents test their own WebAuthn | never reaches real credentials | already planned (passkeys.md 3.5.3) |

## 4. Slices

1. **This slice (lands now):** 3.1 in full (verb-aware right target, `take`, `background` run
   option, agent opens unselected in the person's pane) and 3.2 with a banner (raise, reveal on
   click, trigger once, expiry). Failing-first tests: `BrowserPageRightTests` (no takeover),
   `BrowserPasskeyRequestsTests` (hidden tab posts and waits; click reveals then triggers once;
   shown tab triggers at once; replace and expire).
2. a352: `escalate_auth` calls `cmux browser right passkey REF`, waits for the page state, and the
   Chief skill text says so (a352 owns the wording).
3. Home card with a "Use passkey" button bound to the same request id; daemon notification row so
   the Notifications panel lists it.
4. CEF: pending-ceremony visibility guard (passkeys.md K16 step 3).
5. Optional "Agent window" for Chiefs that need many tabs (3.1).
