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

## Parse once (2026-10-06)

A `cmux.protocol/2` line is parsed ONCE into the typed envelope (`RequestEnvelope`: typed
`operation`, `origin` claim, `params`), by `resource_router::parse_resource_line`. The origin
rules check that value; envelope and catalog validation then move the same value into the
dispatched request. No check reads the raw line again, so no spelling (a JSON escape in a key or
in the operation, a duplicate member, case) can be read one way by the gate and another way by
the handler. Rules:
- A line that does not parse (bad JSON, unknown or duplicate member, unknown operation, a
  non-string id) is refused with `validation.invalid` and never dispatched. There is no raw-text
  fast path and no admit-on-unreadable.
- The origin rules run before envelope and catalog validation, so a refused origin learns nothing
  from validation.
- A line whose connection has no registry record (detached while its reader held the line) is
  refused (`origin.forbidden`, reason `connection_not_registered`), never run as `agent`.
- `apps.*` is not a catalog operation: a v2 `apps.*` line gets the envelope validation error
  (coordinator decision). `origin.confirmation.issue` refuses an `operation` that is not a
  catalog operation.

## Gate A2

`apps.install`, `apps.uninstall`, `apps.enable` need `user`. Refusal: `origin.forbidden`,
message "needs a verified cmux app connection", details `{required: "user", derived}`.
Before P8 every connection is refused. The rule applies on the legacy `apps-*` door and to app
supervisor calls; on v2 it applies to the typed operation's wire name, so it binds as soon as
those operations join the catalog.

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
  install_id?: 1-128 chars of [A-Za-z0-9_-]}`. Result: `{connection_id, user_origin_allowed: bool,
  nonce?: 64 lowercase hex}`; step 2 result `{verified, install_id, connection_id,
  user_origin_allowed}`.
- `user_origin_allowed` (Cloud v6 decision, 2026-10-05): whether origin `user` passes the apps door
  on this connection now (verified app, not bound to an agent); the last hello reply counts. The app
  claims `user` only when it is true, else sends `script`, and NEVER resends a refused `user` as
  `script` (it shows the refusal). A missing field is false.
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

Precondition for ANY allow entry: a per-page identity on the relay. `page-router-v1` gives it per
connection (`client-hello {page}`) and `page-streams-v1` per stream (below), but still no rule
exists for "the terminal this page was opened for". An entry also needs a shipped page that calls
it, a rule that scopes it to that page's own object (never "any terminal by id"), and its own
allowed and refused tests.

## Page streams (`page-streams-v1`, p05-ipc-103, risk:high)

Why: the app opens one page relay connection per page today (PageRelayChannel, plus one for Home
channels). The p05-ipc spec (D3) wants one control connection and at most one page relay
connection per daemon. Chrome's model is Mojo's associated interfaces: many endpoints share one
message pipe, each message names its endpoint, and ordering per endpoint is kept
(`mojo/public/cpp/bindings/README.md`, "Associated Interfaces"; `mojo/core/ports/node.h`). A
page is an endpoint (a stream) on the one page relay connection. Page streams never live on the
main connection: the main connection derives `user` or `agent`, and putting pages there would
make the fail-safe default (`page` for every request of the connection) depend on a per-request
tag instead of on the connection's role.

Wire (daemon side; the app side is p05-ipc-104 and p05-ipc-108):
- `{"cmd":"client-hello","role":"page_relay","streams":true}`: a streamed page relay. `streams`
  is a boolean, true only with role `page_relay` and no `page`; anything else is
  `client_hello.bad_request {field: "streams"}`. The reply adds `page_streams: true`.
  Capability `page-streams-v1` in `identify`.
- Stream 0 is the connection itself. Its only lines are `open-stream {stream, page}` and
  `close-stream {stream}` (stream 1-65535; page as in `client-hello`), plus `cmux.protocol/2`
  requests. Every other line (`identify`, `subscribe`, any legacy command) is
  `origin.forbidden {reason: "stream_zero", derived: "page"}`. A member other than
  `cmd`, `id`, `stream` (and `page` for open) is `page_stream.bad_request {field}`.
- `open-stream` replies `{stream, page, relay_id, page_operations}`. The page is the stream's for
  its whole life: opening an open id is `page_stream.in_use`; only `close-stream` frees the id.
  At most `MAX_SERVER_CONNECTIONS` (64) streams are open per relay (`page_stream.limit`): each
  stream stands for what was one relay connection, so the bound is the old one.
- `close-stream` is idempotent (`closed: false` for a stream that was not open) and drops every
  token issued for the stream.
- Every `cmux.protocol/2` request on a streamed relay names its stream in the origin claim:
  `"origin": {"claim": "page", "stream": N}` or `{"claim": "user", "confirmation": T,
  "stream": N}`. No claim, or a claim without `stream`, is `origin.forbidden {reason:
  "stream_required"}`; a stream that is not open is `{reason: "stream_not_open"}`; `stream: 0`
  fails the envelope parse (`validation.invalid`). The request is judged with that stream's page
  exactly as a one-page relay's request is judged with the connection page (catalog
  `page_refusal`, routed `routed_origin`).
- Any other connection (main, legacy, a one-page relay, a WebSocket) refuses `open-stream` and
  `close-stream` with `origin.forbidden {reason: "page_stream_not_here", derived}`, also after its
  hello window closed, and refuses a `stream` member in a v2 origin claim the same way.
- Confirmation tokens: `origin.confirmation.issue {relay_connection_id}` takes either a one-page
  relay's connection id or a stream's `relay_id`. A `relay_id` comes from the daemon's connection
  id counter, so it never equals a connection id or an earlier stream's id; a reopened stream gets
  a new one. The token is bound to (operation, params hash, endpoint) and is consumed only on that
  stream. The streamed connection's own id names no page, so issue for it is `relay_mismatch`.
  The same-peer rule (`peer_key`) is unchanged. Each endpoint holds at most 16 live tokens, so one
  page's gestures never evict another page's.

Analysis (remote-relay rules applied to a local trust boundary):
- Local command and content execution: a page stream request is origin `page` before any claim,
  whatever its tag says. The hard classes (terminal input, screen and history reads,
  attach/detach, renderer grants, file system, terminal cwd) stay refused for every page on every
  stream, a confirmed-user claim included (`every_page_stream_is_denied_the_hard_classes`). Stream
  0 reaches no legacy command, so no `send`, `subscribe {surface}` or `new-tab` is reachable from
  the relay connection.
- Access to unowned objects: a stream can act only as its own page. The page is fixed at open and
  cannot be rebound while the stream lives; another stream's token fails; a token of a closed
  stream fails on the reopened one. A page cannot open a stream itself: page JS has no line on
  the relay, the host opens streams.
- Local-state exposure: `open-stream` returns only the page's allow list (already public in
  page-router.json) and an opaque relay id. Nothing on stream 0 reads daemon state.
- Escalation: `origin.confirmation.issue` stays refused on every page relay, streamed included;
  only the verified app of the same peer mints, as before.
- Fail-safe defaults: an untagged request is refused, not run as some page; an unknown page id
  gets no operation (page-router.json has no entry); the main connection can never hold a page
  stream, so a bug in the app's stream tagging cannot run a page request as `user`.

Not in this task (follow-ups):
- Events per stream: a streamed relay has no `subscribe`; the History page's `history-changed`
  needs `subscribe {stream}` (p05-ipc-148). Until then the app keeps History on a one-page relay.
- The Chief registry's ledger label (`user_local via page:<page>`) reads the connection page; on
  a streamed relay it records `user_local`. The page is known per request
  (`request.envelope.origin.stream`); chief_registry_resource.rs must read it before
  home-channels moves to a stream (p05-ipc-108).
- No app uses `streams: true` yet (p05-ipc-104), so no user-visible behavior changes; the app
  gates its use behind its own setting.

Tests: `cargo test -p cmux-tui-core --lib -- page_stream page_access origin_gate request_origin
client_hello` (server/page_stream_tests.rs, page_access_tests.rs
`every_page_stream_is_denied_the_hard_classes`, request_origin_tests.rs page stream unit tests).

## Red tests (first commit)

- page_relay call claiming user with no token -> origin.forbidden.
- wrong-params token, reused token, expired token, token used on another connection -> forbidden.
- issue on a page_relay connection -> refused; issue on a non-verified connection -> refused.
- page_relay request with no origin derives page.
- apps.install/uninstall/enable refused with the A2 error before P8 (legacy door; v2 gets the
  envelope validation error, parse once).
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
