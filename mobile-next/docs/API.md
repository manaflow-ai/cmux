# Backend API (v1)

Base URL: `https://cmux-next-mobile-native.debussy.workers.dev` (Cloudflare account `0c1675e0def6de1ab3a50a4e17dc5656`).
Storage: PlanetScale MySQL database `cmux-next-mobile-native` (org `cmux`), accessed with `@planetscale/database`.
Only Cloudflare and PlanetScale are used. Apple is used only to verify Sign in with Apple identity tokens.

All bodies are JSON. Errors: `{ "error": { "code": "snake_case", "message": "..." } }` with a 4xx/5xx status.
Authenticated routes take `Authorization: Bearer <access_token>` (users) or `Bearer <host_token>` (Macs).

## Auth

| Route | Body | Result |
| --- | --- | --- |
| `POST /v1/auth/email/start` | `{ email }` | `{ sent: true, expires_in }`. Sends a 6-digit code. Addresses at `@test.cmux.dev` send nothing; their code is the `TEST_LOGIN_CODE` secret. Rate limited per email and IP. |
| `POST /v1/auth/email/verify` | `{ email, code }` | `Session` |
| `POST /v1/auth/apple` | `{ identity_token, raw_nonce, given_name?, family_name? }` | `Session`. Verifies the JWT against Apple JWKS, `aud` = `APPLE_AUDIENCE` (comma list of bundle ids), nonce = sha256(raw_nonce). |
| `POST /v1/auth/refresh` | `{ refresh_token }` | `Session` (rotates the refresh token). |
| `POST /v1/auth/logout` | `{ refresh_token }` | `{ ok: true }` |
| `GET /v1/me` | | `User` |
| `PATCH /v1/me` | `{ display_name }` | `User` |
| `DELETE /v1/me` | | `{ ok: true }` deletes the account, its hosts and tokens. |

`Session = { access_token, access_expires_at, refresh_token, user: User, is_new_user }`
`User = { id, email, display_name, created_at }`
Access tokens are HS256 JWTs (`sub` = user id, `typ` = `user`, 1 hour). Refresh tokens are opaque, stored as sha256, 90 days.

## Pairing a Mac

1. Mac: `POST /v1/pairing/start { host_name, platform, app_version }` (no auth) → `{ pairing_id, code, poll_secret, expires_at }`. `code` is 6 characters from `ABCDEFGHJKLMNPQRSTUVWXYZ23456789`, valid 10 minutes.
2. Phone (signed in): `POST /v1/pairing/claim { code }` → `{ host: Host }`.
3. Mac: `GET /v1/pairing/:pairing_id?poll_secret=...` → `{ status: "pending" }` or `{ status: "claimed", host_id, host_token, user: User }` (the token is returned once).

A Mac already signed in can also call `POST /v1/hosts/register { host_name, platform, app_version }` with a user access token → `{ host_id, host_token }`.

| Route | Auth | Result |
| --- | --- | --- |
| `GET /v1/hosts` | user | `{ hosts: [Host] }` |
| `PATCH /v1/hosts/:id` | user | `{ name }` → `Host` |
| `DELETE /v1/hosts/:id` | user | `{ ok: true }` revokes the host token. |
| `GET /v1/host/me` | host | `{ host: Host, user: User }` |

`Host = { id, name, platform, app_version, created_at, last_seen_at, online }` (`online` from the signaling room).

## ICE servers

`GET /v1/ice` (user or host) → `{ ice_servers: [{ urls: [..], username?, credential? }], ttl }`.
Minted from the Cloudflare TURN key (`TURN_KEY_ID`, `TURN_KEY_API_TOKEN`) via
`POST https://rtc.live.cloudflare.com/v1/turn/keys/{id}/credentials/generate-ice-servers`.
Without TURN secrets it returns `stun:stun.cloudflare.com:3478` only.

## Signaling

`GET /v1/signal?token=<access_token|host_token>&peer=<client-generated peer id>` upgrades to a WebSocket.
One Durable Object per user (`SignalRoom`, `idFromName(user_id)`) holds the sockets of that user's phones and Macs (hibernation API).

Server → client on connect: `{ "type": "welcome", "peer": { id, kind: "phone"|"host", host_id? }, "peers": [PeerInfo] }`.
Presence changes: `{ "type": "presence", "peers": [PeerInfo] }`. `PeerInfo = { id, kind, host_id?, name?, connected_at }`.
Relay: client sends `{ "type": "signal", "to": peerId, "session": "...", "payload": {...} }`; the target receives
`{ "type": "signal", "from": peerId, "session": "...", "payload": {...} }`. The payload is opaque to the server
(WebRTC uses `{ kind: "offer"|"answer", sdp }`, `{ kind: "candidate", candidate, sdpMid, sdpMLineIndex }`, `{ kind: "bye" }`).
Unknown targets get `{ "type": "error", "code": "peer_offline", "to": peerId }`.
Keepalive: `{ "type": "ping" }` → `{ "type": "pong" }` (auto-response, does not wake the DO).
