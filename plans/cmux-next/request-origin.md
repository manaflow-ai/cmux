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

- Hello params add `role` (`client` default, `page_relay`); fixed for the connection life.
  Hello result adds `connection_id`. P8's client.hello must carry both (coordinator told P8).
- Capability `origin-claim-v1` = the `origin` envelope field + the page_relay role + the issue
  operation. Clients send `origin` / open page_relay only when it is advertised; otherwise the
  relay behaves as today and logs that page calls are not narrowed.

## Red tests (first commit)

- page_relay call claiming user with no token -> origin.forbidden.
- wrong-params token, reused token, expired token, token used on another connection -> forbidden.
- issue on a page_relay connection -> refused; issue on a non-verified connection -> refused.
- page_relay request with no origin derives page.
- apps.install/uninstall/enable refused with the A2 error before P8.
- request with no origin on a client connection behaves as today.
- origin-claim-v1 advertised.

## Swift side (React UIs lead)

PageCallContext defaults to page; DaemonPageRelay opens the page_relay connection and adds the
token only for natively confirmed calls; Swift test that every relay request carries `origin`.
