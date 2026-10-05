# v2 request origin (cmux.apps.* and page calls)

Status: approved by the coordinator 2026-10-04. Lands in the origin window, after the
two pure-move commits on fcn-origin-room. The window may land before peer verification (P8).

## Derivation

`RequestOrigin::derive(connection, request)`:
- `page` on every request of a connection whose hello role is `page_relay`.
- `user` only on a verified_app connection (none exist before P8; P8 turns it on).
- `app` on an app-supervisor connection.
- `agent` otherwise.

A client `origin` field may only narrow. On page_relay the only accepted claims are
`{claim: "page"}` and `{claim: "user", confirmation: <token>}`; any other claim is
`origin.forbidden`. A page_relay request with no `origin` is `page`, so a Swift relay bug
cannot escalate.

## Gate A2

`apps.install`, `apps.uninstall`, `apps.enable` need `user`. Refusal: `origin.forbidden`,
message "needs a verified cmux app connection", details `{required: "user", derived}`.
Before P8 every connection is refused.

## Confirmation token

- `origin.confirmation.issue {operation, params_sha256, relay_connection_id}` -> `{token, expires_at}`.
- Refused on page_relay connections (JS reaches the daemon through them). Issued only when the
  calling connection is verified_app and the relay connection belongs to the same verified peer.
- params_sha256: SHA-256 of the exact v2 envelope `params` after the relay rewrite, canonical
  JSON (sorted keys, no whitespace, UTF-8). The daemon hashes what it receives the same way.
- 32 random bytes, base64url, single-use, TTL 60 s, consumed only on `relay_connection_id`.
- Host-to-daemon value only: DaemonPageRelay attaches it; JS never sees it.

## Hello and capability

One handshake for origin and P8 (coordinator decision 2026-10-04):
- `{"cmd":"client-hello","role":"main"|"page_relay"}` must be the FIRST line of a local
  connection, or the second line right after one `identify` (coordinator decision (b)). `identify`
  must stay read-only and return only static daemon facts. `role` is required; a missing or unknown
  role fails closed (`client_hello.bad_request`). Any other line first (including a second
  `identify`) closes the hello window: a later client-hello is refused.
- Final fields (P8 accepted, 2026-10-04). Params: `{cmd: "client-hello", role: "main"|"page_relay",
  install_id?: 1-128 chars of [A-Za-z0-9_-]}`. Result: `{connection_id, nonce?: 64 lowercase hex}`.
- Step 1 errors (named by this lane); none changes state, and each closes the hello window:
  - `client_hello.local_only`: not a local Unix connection.
  - `client_hello.bad_request`, details `{field: "role"}`: role missing or unknown.
  - `client_hello.bad_request`, details `{field: "install_id"}`: install_id malformed.
  - `client_hello.window_closed`: client-hello after any other line, two identify lines, or a
    second client-hello.
- Nonce rule: a nonce is returned whenever role == main AND install_id is present, uniformly; the
  daemon never reveals whether it holds a launcher key for that id. A wrong or unknown id fails only
  at step 2 with `client_hello.refused`. Nonce + install_id are kept per connection until line 2
  in P8's HelloGate, zeroized after.
- Split: this lane's step 1 validates `install_id` (so the shape is fixed) but returns no nonce;
  P8's window adds HelloGate, the nonce and step 2 (install_id + proof, role not repeated; proof =
  HMAC-SHA256(key, "cmux-frontend-hello-v1" || 0x00 || install_id || 0x00 || nonce)). P8
  needs its own window after the origin window (hmac + sha2 edges in cmux-local-auth).
- peer_key = `token:<pid>.<pidversion>` (audit token), never pid alone. The `install:<id>` form
  is UNUSED (5c decision 2026-10-04, P8 landing): a page_relay connection sends no install_id and
  gets no nonce, so an `install:<id>` key on the main connection would never match its relay, and
  DEV builds (prover B) could never issue a confirmation. The install-key proof sets only
  verified_app; the audit token already binds the main and relay connections to one app process,
  and another process cannot forge it. Caveats (ad349 review):
  - The key names the PROCESS. If the page relay ever moves into a helper process (XPC, a WebKit
    helper), issue fails closed (relay_mismatch). Accepted.
  - On Linux the key is pid + process start time, which exec does not change (macOS exec bumps
    the pid version). Rule: the app opens its daemon sockets close-on-exec (the Swift
    `LineTransport` sets FD_CLOEXEC, P8), so a program it execs cannot inherit them. Linux has no
    verified app today; a future Linux app must keep the same rule.
- `set-client-info` stays a label only and never sets the role.
- A connection with no client-hello is the legacy client role: never user, never page_relay.
- verified_app (P8) = role main declared on that connection AND (install-key proof OR prover A).
- A page_relay connection sends client-hello, then page calls; no subscribe (valid without it;
  subscribe on page_relay is refused). Default deny (2026-10-04, mint guard): every line on a
  page_relay connection that is not a `cmux.protocol/2` request is refused with
  `origin.forbidden {required: "agent", derived: "page"}`, except `identify` and a late
  `client-hello` (window_closed). Pages speak only v2 through the relay.
- `terminal.renderer_grant.create` is refused for origin `page` and on every page_relay request,
  a confirmed-user claim included (the grant would reach page JS); see "Page access". The legacy
  `mint-terminal-renderer*` commands and the v2 operation also need a local Unix connection.
- Same-peer key for origin.confirmation.issue: peer_key above.
- Capability `origin-claim-v1` = client-hello step 1 + the `origin` envelope field + the issue
  operation. Clients use them only when it is advertised; otherwise the relay behaves as today
  and logs that page calls are not narrowed.

## Page access (coordinator decisions 2026-10-04 and 2026-10-05, page default deny)

Origin `page` is refused (`origin.forbidden`, details `{required: "agent", derived: "page"}`) for
EVERY `cmux.protocol/2` catalog operation that is not on the allow list, on every request of a
page_relay connection (a confirmed-user claim included: the result still reaches page JS) and on
any connection that narrows itself to `page`. The rule lives in
`cmux-tui-core/src/request_origin/page_access.rs`. Its match names every catalog operation with no
wildcard, so a new operation does not compile until it is classified, and an allow entry is a
deliberate edit with its own test. The legacy path is already closed: a page_relay connection
refuses every non-v2 line, and legacy lines carry no origin claim. The refusal message names the
class: the five classes below, and "a page may call only allow-listed operations" for every other
operation (reads such as `terminal.list`, `terminal.get`, `screen.layout.export`, `session.events`
and `session.journal.*` included).

- Terminal input: `terminal.input.write`, `terminal.input.keys`, `terminal.input.mouse`,
  `terminal.input.focus`, `pane.run`, `workspace.run`, `sidebar_view.input`, `browser.input.text`,
  `browser.input.key`, `browser.input.mouse`, `browser.input.wheel`.
- Screen, history and process reads: `terminal.screen.read`, `terminal.history.read`,
  `terminal.history.clear`, `terminal.output_read`, `terminal.state.read`, `terminal.copy`,
  `terminal.wait`, `terminal.wait_exit`, `terminal.process.get`.
- Attach and detach: `terminal.attach`, `terminal.viewer.resize`, `terminal.viewer.release`,
  `terminal.viewport.scroll`, `browser.attach`, `browser.viewer.resize`, `browser.viewer.release`,
  `sidebar_view.attach`, `client.detach`.
- Renderer: `terminal.renderer_grant.create`.
- File system: every `git.*` operation, `session.journal.hook.put` (its manifest runs a command),
  and `pane.create`, `pane.split`, `tab.create_terminal` when `cwd` is present (R5 parity).

Allow list: EMPTY. The page relay (`DaemonPageRelay`) carries only the History page's
`cmux.history.*` and the App Store page's `cmux.apps.*`; `PageDescriptor.admits` keeps every page
inside its own namespaces, and no page namespace maps to a denied operation. The diff, markdown,
agent, settings, coderouter, cloud, passwords, keybindings, changelog and icon picker pages use
Swift providers, not the daemon relay. None of them is a catalog operation.

Precondition for ANY allow entry: a per-page identity on the relay. Today one page_relay
connection carries every page of the app, so the daemon cannot tell which page sent a request,
and no rule exists for "the terminal this page was opened for". An entry also needs a shipped page
that calls it, a rule that scopes it to that page's own object (never "any terminal by id"), and
its own allowed and refused tests.

## Red tests (first commit)

- page_relay call claiming user with no token -> origin.forbidden.
- wrong-params token, reused token, expired token, token used on another connection -> forbidden.
- issue on a page_relay connection -> refused; issue on a non-verified connection -> refused.
- page_relay request with no origin derives page.
- apps.install/uninstall/enable refused with the A2 error before P8.
- request with no origin on a client connection behaves as today.
- origin-claim-v1 advertised.
- client-hello: role required (missing/unknown -> bad_request); accepted after one identify;
  refused (window_closed) after any other line or after two identify lines;
- client-hello errors: non-Unix connection -> local_only; malformed install_id -> bad_request
  {field: install_id}; no state change after any error;
- identify reveals no per-user or per-connection secret (no token, nonce, connection_id, path);
  returns connection_id; second client-hello refused.
- no client-hello: never page_relay, never user (legacy client role).
- page_relay with no subscribe is served; subscribe on page_relay refused.
- issue with a relay connection of a different peer (pid+pidversion differ) -> refused.

## Swift side (React UIs lead)

PageCallContext defaults to page; DaemonPageRelay opens the page_relay connection with client-hello as line 1 and adds the
token only for natively confirmed calls; Swift test that every relay request carries `origin`.
