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
- Result data: `connection_id` (the daemon client id, as a string); `nonce` when an install key
  exists (P8 step 2).
- Step 1 (origin window, this lane): role + connection_id. Errors `client_hello.local_only`,
  `client_hello.unavailable`, `client_hello.refused`, `client_hello.bad_request`.
- Step 2 (P8 lead, later, same command): install_id + proof =
  HMAC-SHA256(key, "cmux-frontend-hello-v1" || 0x00 || install_id || 0x00 || nonce).
- `set-client-info` stays a label only and never sets the role.
- A connection with no client-hello is the legacy client role: never user, never page_relay.
- verified_app (P8) = role main declared on that connection AND (install-key proof OR prover A).
- A page_relay connection sends client-hello, then page calls; no subscribe (valid without it;
  subscribe on page_relay is refused).
- Same-peer key for origin.confirmation.issue: the proven install_id when present, else the
  audit-token pid + pidversion. Never pid alone.
- Capability `origin-claim-v1` = client-hello step 1 + the `origin` envelope field + the issue
  operation. Clients use them only when it is advertised; otherwise the relay behaves as today
  and logs that page calls are not narrowed.

## Red tests (first commit)

- page_relay call claiming user with no token -> origin.forbidden.
- wrong-params token, reused token, expired token, token used on another connection -> forbidden.
- issue on a page_relay connection -> refused; issue on a non-verified connection -> refused.
- page_relay request with no origin derives page.
- apps.install/uninstall/enable refused with the A2 error before P8.
- request with no origin on a client connection behaves as today.
- origin-claim-v1 advertised.
- client-hello: role required (missing/unknown -> bad_request); accepted after one identify;
  refused after any other line or after two identify lines;
- identify reveals no per-user or per-connection secret (no token, nonce, connection_id, path);
  returns connection_id; second client-hello refused.
- no client-hello: never page_relay, never user (legacy client role).
- page_relay with no subscribe is served; subscribe on page_relay refused.
- issue with a relay connection of a different peer (pid+pidversion differ) -> refused.

## Swift side (React UIs lead)

PageCallContext defaults to page; DaemonPageRelay opens the page_relay connection with client-hello as line 1 and adds the
token only for natively confirmed calls; Swift test that every relay request carries `origin`.
