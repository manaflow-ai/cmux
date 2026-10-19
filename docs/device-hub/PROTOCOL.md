# Device hub protocol, v1

The contract between cmux apps (cmux-next on macOS today, the cmux iOS app later)
and the device hub backend (`workers/device-hub`). It replaces pairing links for
Mac Screen. v1 shares only between devices of the same user; every record that
could later be team-scoped carries an `owner` so team sharing is an addition,
not a migration. Recovery, approval of new devices by existing ones, and
host-signed allow lists are later work.

## Pieces

- **Worker** (`workers/device-hub`): HTTP API, routes WebSockets to Durable Objects.
- **User DO** (one per user, id = user id): SQLite storage is the source of truth
  for the user's devices, permissions, relays, sessions and audit log. Every
  signed-in device keeps a WebSocket to it with the hibernation API
  (`state.acceptWebSocket`, tag = device id; pings answered with
  `setWebSocketAutoResponse` so they never wake it).
- **Session DO** (one per session): signaling for exactly two devices, admitted
  by single-use tickets. Hibernates while idle; deleted when the session ends.
- All of it deploys in Lawrence's Cloudflare account. Until credentials are
  available it runs under `wrangler dev` on a cmux Mac mini (tailnet URL).

## Identity

- **Account**: the app's Stack Auth access token is exchanged once:
  `POST /v1/auth/stack {token}` → `{session, userId, expiresAt}`. `session` is a
  JWT (ES256, `iss: device-hub`, `sub: userId`, 1 h). Send it as
  `Authorization: Bearer <session>` on every call.
- **Device key**: each device has two P-256 keys in its Secure Enclave
  (CryptoKit `SecureEnclave.P256.Signing` and `.KeyAgreement`). Public keys are
  sent as base64 of the X9.63 uncompressed point (65 bytes).
- **Device-signed requests**: every device-scoped call (all calls below except
  `/v1/auth/stack`) carries
  - `X-Device-Id: <uuid>` (lowercase),
  - `X-Device-Ts: <unix seconds>` (must be within 60 s of server time),
  - `X-Device-Sig: <base64 raw r||s, 64 bytes>` = ECDSA-P256-SHA256 over the
    UTF-8 string `"<METHOD>\n<path+query>\n<ts>\n<hex sha256 of body or empty>"`.
  The server verifies with the device's registered signing key and rejects a
  repeated `(device, ts, sig)` for 120 s. Registration itself is signed with the
  key being registered.

## Records (User DO SQLite)

```
devices(id TEXT PK, name, platform 'macos'|'ios', signing_key, agreement_key,
        created_at, last_seen_at, removed_at NULL, mac_screen_shared INT 0/1)
permissions(host_id, viewer_id, scope 'none'|'ask'|'view'|'full', updated_at,
        PRIMARY KEY(host_id, viewer_id))         -- default when absent: 'ask'
relays(id TEXT PK, owner_kind 'user'|'team', owner_id, name, urls JSON,
        auth_mode 'shared_secret'|'static', sealed JSON {deviceId: base64},
        enabled INT, priority INT, updated_at)   -- v1 writes owner_kind 'user'
sessions(id TEXT PK, viewer_id, host_id, scope 'view'|'full',
        state 'pending'|'approved'|'live'|'ended', created_at, started_at,
        ended_at, end_reason, path 'direct'|'relay'|NULL)
audit(id TEXT PK, ts, event, viewer_id, host_id, scope, session_id, detail,
        duration_s)
```
Audit events: `shared`, `unshared`, `requested`, `approved`, `denied`,
`started`, `ended`, `permission_changed`, `device_added`, `device_removed`.
Audit holds metadata only: never screen content, keystrokes or clipboard.

## HTTP API (all JSON)

| Method, path | Body | Result | Notes |
|---|---|---|---|
| `POST /v1/auth/stack` | `{token}` | `{session, userId, expiresAt}` | Verifies the Stack Auth token (JWKS). |
| `GET /v1/me` | | `{userId, plan: 'free'\|'paid', device}` | `plan` from env `PAID_USER_IDS` in v1. |
| `POST /v1/devices` | `{id, name, platform, signingKey, agreementKey}` | `{device}` | Registers or updates this device. Signed by `signingKey`. |
| `GET /v1/devices` | | `{devices:[…]}` | Not removed devices, with `online` from open sockets. |
| `PATCH /v1/devices/:id` | `{name}` | `{device}` | |
| `DELETE /v1/devices/:id` | | `{}` | Removes the device; ends its sessions; pushes revocations. |
| `PUT /v1/devices/:id/mac-screen` | `{shared}` | `{device}` | Only device `:id` itself may change its own sharing. |
| `GET /v1/permissions?host=:id` | | `{permissions:[{viewerId, scope}]}` | |
| `PUT /v1/permissions/:hostId/:viewerId` | `{scope}` | `{permission}` | Any of the user's devices may set it in v1. Lowering a scope revokes live sessions that exceed it. |
| `POST /v1/sessions` | `{hostId, scope}` | `{session:{id, state, scope}}` | From the viewer. See flow. |
| `POST /v1/sessions/:id/decision` | `{decision:'deny'\|'once'\|'always', scope}` | `{session}` | From the host device only. `always` stores the permission. |
| `POST /v1/sessions/:id/end` | `{reason}` | `{}` | Either side. |
| `POST /v1/sessions/:id/ice` | | `{ice:[…]}` | Fresh cmux relay credentials while authorized (paid only; else `[]`). |
| `GET /v1/relays` | | `{relays:[…]}` | Each relay carries only this device's sealed blob. |
| `PUT /v1/relays/:id` | `{name, urls, authMode, sealed, enabled, priority}` | `{relay}` | `sealed`: `{deviceId: base64}` for every device. |
| `DELETE /v1/relays/:id` | | `{}` | |
| `GET /v1/audit?limit=&before=` | | `{entries:[…]}` | Newest first. |

Errors: `{error:{code, message}}` with HTTP 400/401/403/404/409/429.
Codes: `bad_signature`, `stale_timestamp`, `replay`, `not_shared`,
`permission_none`, `scope_exceeds_permission`, `host_offline`, `not_host`,
`session_not_pending`, `rate_limited`.

## WebSocket: User DO

`GET /v1/user/ws` (upgrade), with the account and device headers. One socket per
device (a new one replaces the old). Server → device messages:

```
{type:'devices.changed'}                       // refetch GET /v1/devices
{type:'permissions.changed', hostId}
{type:'relays.changed'}
{type:'session.request', session:{id, viewerId, viewerName, viewerKeyFingerprint, scope}}   // to the host
{type:'session.ticket', sessionId, ticket, signalURL, ice:[…], peer:{id, name, signingKey}, role, scope}
{type:'session.denied', sessionId}             // to the viewer
{type:'session.revoked', sessionId, reason}    // to both; end at once
{type:'session.ended', sessionId, reason}
```
Device → server: `{type:'ping'}` (auto-response `{type:'pong'}`).

## Session flow

1. Viewer `POST /v1/sessions {hostId, scope}`. Server checks: host not removed,
   host `mac_screen_shared`, permission(host, viewer):
   - `none` → 403 `permission_none`;
   - `view` and scope `full` → 403 `scope_exceeds_permission`;
   - `view`/`full` (covering the scope) → approved at once;
   - `ask` or absent → `pending`; push `session.request` to the host device.
   Host not connected → 409 `host_offline`. Audit `requested`.
2. Host answers with `/decision`. `deny` → audit `denied`, push
   `session.denied` to the viewer. `once`/`always` → audit `approved`
   (`always` upserts the permission with the chosen scope).
3. On approval the server creates the Session DO and pushes `session.ticket`
   to both devices. Ticket = compact JWS (ES256, server key) with payload
   `{sid, role:'viewer'|'host', dev, peer, peerKey, scope, iat, exp: iat+60, jti}`.
   `signalURL` = `wss://<host>/v1/sessions/<sid>/ws`. `ice` = cmux relay
   credentials if the user is on a paid plan (Cloudflare TURN, minted per
   session, TTL 1 h), else `[]`; the app adds the user's own relays.
4. Each device opens `signalURL?ticket=<jws>` with its device headers. The
   Session DO verifies the JWS, `exp`, `dev` = `X-Device-Id`, the device
   signature, and burns `jti` (SQLite). At most one socket per role.
5. Signaling messages are relayed verbatim between the two roles:
   `{type:'offer'|'answer', sdp, fpSig}`, `{type:'candidate', …}`, `{type:'bye'}`.
   `fpSig` = base64 raw ECDSA over `"<sid>|<role>|<fingerprint>"`, where
   `fingerprint` is the value of the SDP's `a=fingerprint:` line (all of them,
   joined with `,`, in order). The receiver verifies it with `peerKey` from its
   own ticket and aborts on mismatch.
6. When both are connected the Session DO marks the session `live` (audit
   `started`). When either sends `bye`, closes, or the server revokes, it
   marks `ended` (audit `ended` with duration and reason), closes both sockets
   and deletes its storage.
7. Revocation: removing a device, lowering a permission, turning sharing off,
   or ending from either side pushes `session.revoked` to both devices; the
   host closes the peer connection at once; `/ice` stops renewing.

The host enforces the scope: in a `view` session it ignores all input.

## Relays

User-owned relay list (team-owned later). Secrets never reach the server in
readable form: the configuring device seals the relay secret (shared secret,
or username + password) for every registered device with HPKE
(P-256, HKDF-SHA256, AES-GCM) to that device's `agreementKey`. Each device
opens its own blob and keeps it in the Keychain. Shared-secret mode mints
`username = "<expiry>:<device-name>"`, `credential = base64(HMAC-SHA1(secret,
username))`, expiry 6 h, renewed before it ends. Both sides use the relays.
Free plan: direct, the user's own relays, and the host's tailnet/WireGuard
addresses as candidates; the cmux relay only on paid plans.
