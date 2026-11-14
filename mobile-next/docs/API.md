# Backend API (v1)

Base URL: `https://cmux-next-mobile-native.debussy.workers.dev` (Cloudflare account `0c1675e0def6de1ab3a50a4e17dc5656`).
Storage: PlanetScale MySQL database `cmux-next-mobile-native` (org `cmux`), accessed with `@planetscale/database`.
Only Cloudflare and PlanetScale are used. Apple is used only to verify Sign in with Apple identity tokens.

All bodies are JSON. Errors: `{ "error": { "code": "snake_case", "message": "..." } }` with a 4xx/5xx status.
Authenticated routes take `Authorization: Bearer <access_token>` (users) or `Bearer <host_token>` (Macs).
Opaque tokens carry a prefix: refresh tokens `cnr_`, host tokens `cnh_`, pairing poll secrets `cnp_`.
Common error codes: `invalid_json`, `invalid_request`, `unauthorized` (401), `not_found`, `method_not_allowed`,
`rate_limited` (429), `internal_error`.

## Auth

| Route | Body | Result |
| --- | --- | --- |
| `POST /v1/auth/email/start` | `{ email }` | `{ sent: true, expires_in }`. Sends a 6-digit code. Only the exact addresses in `TEST_LOGIN_EMAILS` (a comma list var, currently `aziz-native@test.cmux.dev` and the smoke-test account `smoke-native@test.cmux.dev`) send nothing; their code is the `TEST_LOGIN_CODE` secret. Any other `@test.cmux.dev` address, and any address while email delivery is not configured, gets `503 email_unavailable`. Rate limited per email (5 per 10 min) and IP (30 per hour): `429 rate_limited`. |
| `POST /v1/auth/email/verify` | `{ email, code }` | `Session`. Wrong, used or expired codes: `400 invalid_code`. Each code allows 5 attempts in total, counted atomically before the comparison. Rate limited to 30 verifications per IP per 10 min (`429 rate_limited`). After 30 failed test-code verifications in an hour across all test addresses, test-code sign-in returns `429 rate_limited` for an hour. |
| `POST /v1/auth/apple` | `{ identity_token, raw_nonce, given_name?, family_name? }` | `Session`. Verifies the JWT against Apple JWKS, `aud` = `APPLE_AUDIENCE` (comma list of bundle ids), nonce = hex sha256(raw_nonce). Failures: `401 invalid_identity_token`. A verified Apple email links to an existing account with that email. |
| `POST /v1/auth/refresh` | `{ refresh_token }` | `Session` (rotates the refresh token; the old one is revoked). `401 invalid_refresh_token`. Presenting a refresh token that was already rotated or revoked (including two concurrent refreshes with the same token) revokes every refresh token of that user; the client must sign in again. Access tokens already issued stay valid until they expire. |
| `POST /v1/auth/logout` | `{ refresh_token }` | `{ ok: true }` |
| `GET /v1/me` | | `User` |
| `PATCH /v1/me` | `{ display_name }` | `User` |
| `DELETE /v1/me` | | `{ ok: true }` deletes the account, its hosts and tokens. |

`Session = { access_token, access_expires_at, refresh_token, user: User, is_new_user }`
`User = { id, email, display_name, created_at }`
Access tokens are HS256 JWTs (`sub` = user id, `typ` = `user`, 1 hour). Refresh tokens are opaque, stored as sha256, 90 days.

## Pairing a Mac

The phone claims a code shown on the Mac; the Mac must then approve the claiming account before it receives a host token.

States: `pending` → `awaiting_approval` (phone claimed) → `approved` (Mac approved) → `completed` (token delivered once).
The Mac can reject from `pending` or `awaiting_approval` → `rejected`.

1. Mac: `POST /v1/pairing/start { host_name, platform, app_version }` (no auth) →
   `{ pairing_id, code, poll_secret, expires_at }`. `code` is 8 characters from `ABCDEFGHJKLMNPQRSTUVWXYZ23456789`;
   display it as `XXXX-XXXX`. Valid 10 minutes. Rate limited to 30 per IP per hour.
2. Phone (signed in): `POST /v1/pairing/claim { code }` →
   `{ host: Host, status: "awaiting_approval", expires_at }`. In this response `host.created_at` and `host.last_seen_at`
   are `null` and `online` is `false`; `host.id` is the id the host will have once approved. The code is case-insensitive;
   spaces and dashes are ignored. Unknown, expired or already claimed codes (by anyone, including the same user): `404 invalid_pairing_code`.
   Limits (`429 rate_limited`): 10 claims per user per 10 min, 30 per IP per 10 min, and after 20 failed claims within an
   hour the user is locked out of claiming for an hour.
3. Mac: `GET /v1/pairing/:pairing_id?poll_secret=...` returns one of:
   - `{ status: "pending" }`
   - `{ status: "awaiting_approval", user: { id, email, display_name } }`: show the account and ask to approve.
   - `{ status: "claimed", host_id, host_token, user: User }`: after approval, returned exactly once.
   - `{ status: "rejected" }` (repeatable).
   Errors: `410 pairing_consumed` (token already delivered), `410 pairing_expired` (past `expires_at` before completion),
   `404 pairing_not_found` (unknown id or wrong secret), `401 unauthorized` (no secret).
4. Mac: `POST /v1/pairing/:pairing_id/approve { poll_secret }` → `{ status: "approved" }`. Only from `awaiting_approval`;
   otherwise `409 invalid_pairing_state`. Approval extends `expires_at` by 10 minutes so the next poll can collect the token.
   `POST /v1/pairing/:pairing_id/reject { poll_secret }` → `{ status: "rejected" }`. From `pending` or `awaiting_approval`
   (idempotent once rejected); otherwise `409 invalid_pairing_state`. Both take no other auth; a wrong secret is
   `404 pairing_not_found`, a missing one `401 unauthorized`, and an expired pairing `410 pairing_expired` (approve).

The host appears in `GET /v1/hosts` only after approval and token delivery. A rejected pairing never creates a host.
The phone learns the outcome from `GET /v1/hosts` (or signaling presence) once the Mac connects.

A Mac already signed in can also call `POST /v1/hosts/register { host_name, platform, app_version }` with a user access token → `{ host_id, host_token }`.

| Route | Auth | Result |
| --- | --- | --- |
| `GET /v1/hosts` | user | `{ hosts: [Host] }` |
| `PATCH /v1/hosts/:id` | user | `{ name }` → `Host` |
| `DELETE /v1/hosts/:id` | user | `{ ok: true }` revokes the host token and closes its signaling sockets (close code 4001). |
| `GET /v1/host/me` | host | `{ host: Host, user: User }` |
| `DELETE /v1/host/me` | host | `{ ok: true }`: the Mac unpairs itself (host removed, token revoked). |

`Host = { id, name, platform, app_version, created_at, last_seen_at, online }` (`online` from the signaling room).

## ICE servers

`GET /v1/ice` (user or host) → `{ ice_servers: [{ urls: [..], username?, credential? }], ttl }`.
Rate limited to 60 per principal (user or host) per hour: `429 rate_limited`. Credentials last `ttl` seconds, so cache them.
Minted from the Cloudflare TURN key (`TURN_KEY_ID`, `TURN_KEY_API_TOKEN`) via
`POST https://rtc.live.cloudflare.com/v1/turn/keys/{id}/credentials/generate-ice-servers`.
Without TURN secrets it returns `stun:stun.cloudflare.com:3478` only.

## Signaling

`GET /v1/signal?peer=<peer id>` with `Authorization: Bearer <access_token|host_token>` upgrades to a WebSocket.
`?token=<token>` is still accepted for older clients but deprecated: tokens in URLs can end up in platform request logs.
The account must still exist (`401 unauthorized` otherwise).
Peer ids:
- Hosts: the server assigns `host-<host_id>` and ignores `peer`. Phones address a Mac as `host-<host_id>`.
- Phones: `peer` is client-generated, matches `[A-Za-z0-9_.:-]{1,64}`, and must not start with `host` (case-insensitive);
  otherwise `400 invalid_peer`.
A new socket with the same peer id replaces the old one (close code 4000). Non-upgrade requests get `426 upgrade_required`.
One Durable Object per user (`SignalRoom`, `idFromName(user_id)`) holds the sockets of that user's phones and Macs (hibernation API).

Server → client on connect: `{ "type": "welcome", "peer": PeerInfo, "peers": [PeerInfo] }`.
Presence changes: `{ "type": "presence", "peers": [PeerInfo] }`. `PeerInfo = { id, kind: "phone"|"host", host_id?, name?, connected_at }`.
`peers` always lists the other connected peers and never the recipient. Host peers carry `host_id` and the host `name`.
Relay: client sends `{ "type": "signal", "to": peerId, "session": "...", "payload": {...} }`; the target receives
`{ "type": "signal", "from": peerId, "session": "...", "payload": {...} }`. The payload is opaque to the server
(WebRTC uses `{ kind: "offer"|"answer", sdp }`, `{ kind: "candidate", candidate, sdpMid, sdpMLineIndex }`, `{ kind: "bye" }`).
`session` is echoed (or `null`). Messages over 64 KiB are dropped.
Unknown targets get `{ "type": "error", "code": "peer_offline", "to": peerId }`. Other errors: `{ "type": "error", "code":
"invalid_json" | "unknown_type" | "message_too_large" }`.
Keepalive: send exactly the text `{"type":"ping"}` → `{"type":"pong"}` (auto-response, does not wake the DO; other
spellings of ping are still answered, but wake it).
