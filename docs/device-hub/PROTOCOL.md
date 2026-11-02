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
- All of it deploys in Lawrence's Cloudflare account. The dev deployment is the
  `cmux-device-hub-dev` Worker on workers.dev (`workers/device-hub/DEPLOY.md`).

## Identity

- **Account**: the app's Stack Auth access token is exchanged once:
  `POST /v1/auth/stack {token}` → `{session, userId, stackUserId, projectId,
  expiresAt}`. The hub accepts tokens from the Stack projects in
  `STACK_PROJECT_IDS` (dev: cmux prod and the Stack development project used by
  DEBUG/tagged builds; production: prod only). The project is the token's
  `aud`; it must name exactly one accepted project, and the token is verified
  against that project's JWKS and issuer. `userId` is `"<projectId>:<sub>"`, so
  the same Stack user in two projects is two hub users. `session` is a
  JWT (ES256, `iss: device-hub`, `sub: userId`, 1 h). Send it as
  `Authorization: Bearer <session>` on every call.
- **Device key**: each device has two P-256 keys in its Secure Enclave
  (CryptoKit `SecureEnclave.P256.Signing` and `.KeyAgreement`). Public keys are
  sent as base64 of the X9.63 uncompressed point (65 bytes). A Windows or
  Linux machine running cmux-tui (Computer Use, `docs/computer-use-approvals.md`)
  registers the same way with the Rust client
  (`cmux-tui/crates/cmux-device-hub-client`) and says where its keys live in
  `assurance`: `hardware` (Secure Enclave, a TPM-backed CNG key), `keystore`
  (the Linux Secret Service, a Windows software CNG key) or `file` (a 0600 key
  file on a headless box: the lowest).
- **Device-signed requests**: every device-scoped call (all calls below except
  `/v1/auth/stack`) carries
  - `X-Device-Id: <uuid>` (lowercase),
  - `X-Device-Ts: <unix seconds>` (must be within 60 s of server time),
  - `X-Device-Sig: <base64 raw r||s, 64 bytes>` = ECDSA-P256-SHA256 over the
    UTF-8 string `"<METHOD>\n<path+query>\n<ts>\n<hex sha256 of body or empty>"`.
    The last line is the lowercase hex SHA-256 of the exact body bytes, or the
    empty string when there is no body (GET, WebSocket upgrades). `path+query`
    is the request target as sent, e.g. `/v1/sessions/<sid>/ws?ticket=<jws>`.
  The server verifies with the device's registered signing key and rejects a
  repeated `(device, ts, sig)` for 120 s, where `sig` is compared in its low-S
  form (`s` and `n - s` count as the same signature, so a flipped copy of a
  captured request is a replay). Devices may send high-S signatures. Registration itself is signed with the
  key being registered. A registered id keeps its signing key: registering it
  with another key is 409 `device_key_mismatch`, and a removed id cannot be
  registered again (403 `device_removed`; the app makes a new id). Calls from an
  unknown device are 401 `bad_signature`; from a removed one, 403 `device_removed`.
- **Times**: JSON timestamps (`expiresAt`, `createdAt`, `lastSeenAt`,
  `updatedAt`, audit `ts`) are Unix milliseconds. JWT/ticket claims and
  `X-Device-Ts` are Unix seconds.

## Records (User DO SQLite)

```
devices(id TEXT PK, name, platform 'macos'|'ios'|'windows'|'linux', signing_key,
        agreement_key, created_at, last_seen_at, removed_at NULL,
        mac_screen_shared INT 0/1, name_pinned INT 0/1, owner_kind, owner_id,
        assurance 'hardware'|'keystore'|'file', push_token NULL, push_topic NULL,
        push_env NULL 'production'|'development')
approvals(id TEXT PK, asker_id, nonce, digest, request JSON, allow_always INT,
        state 'pending'|'decided'|'expired'|'cancelled', decision NULL,
        decider_id NULL, sig NULL, created_at, answerable_until, decided_at NULL,
        owner_kind, owner_id, UNIQUE(asker_id, nonce))
permissions(host_id, viewer_id, scope 'none'|'ask'|'view'|'full', updated_at,
        owner_kind, owner_id,
        PRIMARY KEY(host_id, viewer_id))         -- default when absent: 'ask'
relays(id TEXT PK, owner_kind 'user'|'team', owner_id, name, urls JSON,
        auth_mode 'shared_secret'|'static', sealed JSON {deviceId: base64},
        enabled INT, priority INT, updated_at)   -- v1 writes owner_kind 'user'
sessions(id TEXT PK, viewer_id, host_id, scope 'view'|'full',
        state 'pending'|'approved'|'live'|'ended', created_at, started_at,
        ended_at, end_reason, path 'direct'|'relay'|NULL, owner_kind, owner_id)
audit(id TEXT PK, ts, event, viewer_id, host_id, device_id, scope,
        session_id, detail, duration_s, owner_kind, owner_id)
```
Every table carries `owner_kind 'user'|'team'` and `owner_id`; v1 writes
`'user'` and the hub user id. Columns added after the first deploy are added
in place when an existing User DO starts, and its rows are backfilled with the
user id. `audit.device_id` is the device a `device_added`/`device_removed`
entry is about.
Audit events: `shared`, `unshared`, `requested`, `approved`, `denied`,
`started`, `ended`, `permission_changed`, `device_added`, `device_removed`,
and for Computer Use approvals `cu_requested`, `cu_decided`, `cu_expired`,
`cu_cancelled` (`hostId` the asking machine, `viewerId` the deciding device,
`sessionId` the approval id, `detail` `<tool> <target name>` or the decision).
Audit holds metadata only: never screen content, keystrokes or clipboard.
Audit rows are never deleted or hidden: removing a device keeps every row that
names it, and the device row itself stays (with `removed_at`), so entries
carry its last known name in `viewerName`/`hostName`/`deviceName` even after
it leaves `GET /v1/devices`.
Relay changes are not audited. The User DO also keeps a `replay_msg(device_id,
digest, expires_at)` table (digest = ts and low-S signature) for the 120 s
replay cache.

JSON shapes: a device is `{id, name, platform, signingKey, agreementKey,
createdAt, lastSeenAt, macScreenShared, online, assurance}`; an ICE server is
`{urls:[…], username?, credential?}`; an audit entry is `{id, ts, event,
viewerId, hostId, deviceId, viewerName, hostName, deviceName, scope, sessionId,
detail, durationS}` (`detail` carries the
end reason, the decision, or `old->new` for a permission change).

## HTTP API (all JSON)

| Method, path | Body | Result | Notes |
|---|---|---|---|
| `GET /v1/health` | | `{ok, service, protocol, time}` | No auth. |
| `POST /v1/auth/stack` | `{token}` | `{session, userId, expiresAt}` | Verifies the Stack Auth token (JWKS). The session carries the Stack token sealed (AES-GCM, key derived from the session key) for the cmux relay check, and ends no later than that token (at most 1 h). A session from before this (no sealed token) still works but never gets the cmux relay; one whose token does not open is refused with 401 `unauthorized`. |
| `GET /v1/me` | | `{userId, plan: 'free'\|'paid', device}` | `plan` is `paid` when cmux billing says the cmux relay is included (see Plans); `free` otherwise, including when the lookup fails. Needs a registered device. |
| `POST /v1/devices` | `{id, name, platform, signingKey, agreementKey, assurance?}` | `{device}` | Registers or updates this device. Signed by `signingKey`. The first registration sets `name`; once `PATCH` renamed the device, registration keeps that name. `platform` is `macos`, `ios`, `windows` or `linux`; `assurance` defaults to `hardware` for `macos`/`ios` and `file` for `windows`/`linux`. A registered id keeps its platform, and its assurance only goes down (`hardware` > `keystore` > `file`): otherwise 409 `device_platform_mismatch`, since the platform decides who answers Computer Use questions. |
| `PUT /v1/devices/:id/push` | `{token, topic, environment}` | `{push:{registered, configured}}` | Only device `:id` itself (403 `not_self`), only an `ios` device (400). `token` the APNs device token in hex (64-200 digits), `topic` its app's bundle id (one of `APNS_TOPICS`), `environment` `production` or `development`. `{token: null}` forgets it. `configured` is false when this hub has no APNs key: Computer Use questions then reach the phone only over its socket. |
| `GET /v1/devices` | | `{devices:[…]}` | Not removed devices, with `online` from open sockets. |
| `PATCH /v1/devices/:id` | `{name}` | `{device}` | Any of the user's devices. |
| `DELETE /v1/devices/:id` | | `{}` | Removes the device; ends its sessions; pushes revocations. Deletes every permission that names it, as host or as viewer, and pushes `permissions.changed` for each host that listed it. |
| `PUT /v1/devices/:id/mac-screen` | `{shared}` | `{device}` | Only device `:id` itself may change its own sharing. |
| `POST /v1/devices/:id/sign-out` | | `{}` | Only device `:id` itself (403 `not_host` otherwise). Ends its sessions at once with reason `signed_out`, closes its User DO socket (code 4003), lists it offline at once and pushes `devices.changed` to the other devices. The device stays registered. Call it before dropping the account session. |
| `GET /v1/permissions?host=:id` | | `{permissions:[{viewerId, scope}]}` | One entry per other device; absent rows read `ask`. |
| `PUT /v1/permissions/:hostId/:viewerId` | `{scope}` | `{permission:{hostId, viewerId, scope, previous, updatedAt}}` | Only device `:hostId` itself (403 `not_host` otherwise). A viewer raises its access only by requesting a session; the host's `always` decision stores the permission. Lowering a scope revokes sessions that exceed it: `none` ends every open session of the pair, `view` ends `full` ones; `ask` and `full` end none. |
| `POST /v1/sessions` | `{hostId, scope}` | `{session:{id, state, scope}}` | From the viewer. See flow. |
| `POST /v1/sessions/:id/decision` | `{decision:'deny'\|'once'\|'always', scope}` | `{session}` | From the host device only. `scope` defaults to the requested one and may lower `full` to `view`, never raise it (400). `always` stores the permission. Requests expire after 5 min: the server ends them (`session.revoked`, reason `expired`) without waiting for a decision. If setting up the approved session fails, it ends with `approve_failed` and the call returns 500. |
| `POST /v1/sessions/:id/end` | `{reason}` | `{}` | Either side; idempotent. Pushes `session.revoked`. Without `reason`: `host_stopped` from the host, `viewer_disconnected` from the viewer. |
| `POST /v1/sessions/:id/ice` | | `{ice:[…]}` | Fresh cmux relay credentials while `approved`/`live` (checked against cmux billing on every call; else `[]`); otherwise 409 `session_not_active`. |
| `GET /v1/relays` | | `{relays:[…]}` | Each relay carries `sealed: {<this device id>: blob}` or `{}`. |
| `PUT /v1/relays/:id` | `{name, urls, authMode, sealed, enabled, priority}` | `{relay}` | `sealed`: `{deviceId: base64}` for every device. |
| `DELETE /v1/relays/:id` | | `{}` | |
| `GET /v1/audit?limit=&before=&device=` | | `{entries:[…]}` | The whole account's log, newest first. `limit` 1-200 (default 50); `before` = `ts` (ms), exclusive; `device` keeps entries whose `viewerId` or `hostId` is that device (sessions, permissions, sharing) plus every `device_added`/`device_removed` entry, so each device's History shows the account's devices coming and going (`deviceId` says which). |

Errors: `{error:{code, message}}` with HTTP 400/401/403/404/409/429.
Codes: `bad_request`, `unauthorized` (missing/expired hub session),
`not_found`, `bad_signature`, `stale_timestamp`, `replay`, `device_removed`,
`device_key_mismatch`, `not_shared`, `permission_none`,
`scope_exceeds_permission` (no longer sent: hubs before 2026-10-20 refused a
scope above `view` with it; apps still read it as View Only), `host_offline`, `not_host`, `session_not_pending`,
`session_not_active`, `ticket_invalid`, `role_taken`, `rate_limited` (reserved;
v1 does not rate-limit yet), `host_scope`, `not_anchored`, `not_self`, `device_platform_mismatch`, and for
approvals `digest_mismatch`, `approval_exists`, `self_approval`,
`not_approver`, `not_asker`, `approval_not_pending`, `approval_expired`,
`always_not_allowed`, `bad_decision_signature`; `internal` (500).

## WebSocket: User DO

`GET /v1/user/ws` (upgrade), with the account and device headers. One socket per
device (a new one replaces the old, which is closed with code 4000; a removed
device's socket is closed with 4001, a signed-out one's with 4003). `online`
counts only open sockets: one the server has closed counts as offline at once,
before the client answers the close frame.
Connecting pushes `devices.changed` to every device, the connecting one
included (its own entry is now `online`); disconnecting pushes it to the
others. Server → device messages:

```
{type:'devices.changed'}                       // refetch GET /v1/devices
{type:'permissions.changed', hostId}
{type:'relays.changed'}
{type:'session.request', session:{id, viewerId, viewerName, viewerKeyFingerprint, scope}}   // to the host
{type:'session.ticket', sessionId, ticket, signalURL, ice:[…], peer:{id, name, signingKey}, role, scope}
{type:'session.denied', sessionId}             // to the viewer
{type:'session.revoked', sessionId, reason}    // to both; end at once
{type:'session.ended', sessionId, reason}
{type:'approval.request', approval:{id, deviceId, deviceName, request, allowAlways, answerableUntil}}  // to approvers
{type:'approval.decided', id, decision, digest, deciderId, sig}   // to the asking device
{type:'approval.closed', id, state, decision}                     // to every other device: drop the question
```
Device → server: `{type:'ping'}` (auto-response `{type:'pong'}`). The
auto-response matches bytes exactly: send the text frame `{"type":"ping"}`, no
spaces; the reply is `{"type":"pong"}`. Other device frames are ignored.
`viewerKeyFingerprint` is the lowercase hex SHA-256 of the viewer's 65-byte
signing key. Pushes reach only connected devices; there is no backlog, so a
device refetches state after it reconnects: its devices, relays, its own
permission list, and every other device's permission list it shows (its access
to each host), so a change made while it was away never leaves an old value.

## Session flow

1. Viewer `POST /v1/sessions {hostId, scope}`. Server checks: host not removed,
   host `mac_screen_shared`, permission(host, viewer):
   - `none` → 403 `permission_none`, with no prompt;
   - `view`/`full` (covering the scope) → approved at once;
   - `ask` or absent, or a scope above the permission (`view` asking for
     `full`: the app's Ask for Access) → `pending`; push `session.request` to
     the host device, whose prompt names the requested scope. Its decision
     works as under `ask`: `once` grants the session only, `always` stores the
     chosen scope, `deny` leaves the permission as it was.
   Host not connected → 409 `host_offline`. Audit `requested`.
2. Host answers with `/decision`. `deny` → audit `denied`, push
   `session.denied` to the viewer. `once`/`always` → audit `approved`
   (`always` upserts the permission with the chosen scope).
3. On approval the server creates the Session DO and pushes `session.ticket`
   to both devices. Ticket = compact JWS (ES256, server key) with payload
   `{sid, role:'viewer'|'host', dev, peer, peerKey, scope, iat, exp: iat+60, jti}`.
   `signalURL` = `wss://<host>/v1/sessions/<sid>/ws` (`<host>` is the Worker's
   public origin: env `PUBLIC_BASE_URL`, else the request's). `ice` = cmux relay
   credentials if cmux billing includes the relay for the user right now
   (Cloudflare TURN, minted per session, TTL 1 h), else `[]`; the app adds the
   user's own relays.
4. Each device opens `signalURL?ticket=<jws>` with its device headers (no
   `Authorization`; the ticket admits it). The User DO passes both devices'
   signing keys to the Session DO when it creates it, so the Session DO
   verifies the JWS, `exp`, `sid`, `dev` = `X-Device-Id` = the role's device,
   the device signature, and burns `jti` (SQLite). At most one socket per role.
   Failures, before the upgrade: 401 `ticket_invalid` (bad, expired or other
   session), 403 `ticket_invalid` (other device), 401 `bad_signature` /
   `stale_timestamp`, 401 `replay` (used `jti`), 409 `role_taken`, 404
   `session_not_active` (ended or unknown session).
5. Signaling messages are relayed verbatim between the two roles:
   `{type:'offer'|'answer', sdp, fpSig}`, `{type:'candidate', …}`, `{type:'bye'}`.
   Text frames up to 64 KiB; other types are dropped. Frames sent before the
   peer connects are queued (up to 256) and delivered when it does. Either
   device may send `{type:'path', path:'direct'|'relay'}` once the media path
   is known; it is not relayed and is stored as `sessions.path` (NULL until
   reported).
   `fpSig` = base64 raw ECDSA over `"<sid>|<role>|<fingerprint>"`, where
   `fingerprint` is the value of the SDP's `a=fingerprint:` line (all of them,
   joined with `,`, in order) and `role` is the sender's. The receiver
   verifies it with `peerKey` from its own ticket (and the peer's role) and
   aborts on mismatch. Candidates are `{type:'candidate', candidate, sdpMid,
   sdpMLineIndex}`.
6. When both are connected the Session DO marks the session `live` (audit
   `started`). A signaling socket that closes or fails ends signaling for that
   side only, never the session: the peer connection may still be up, and the
   other side's socket stays open. A session ends on `bye`, `/end`,
   revocation (7) or the offline grace (8); then the Session DO closes both
   sockets and deletes its storage. A `bye` is provisional for 3 s: if an
   authoritative end follows (a client often sends `bye` and then `/end`), its
   reason wins; otherwise the session ends with reason `bye` (audit `ended`
   with duration, push `session.ended` to both).
7. Revocation: removing a device, lowering a permission, turning sharing off,
   signing out, or ending from either side pushes `session.revoked` to both
   devices, closes the signaling sockets with code 4002 and audits `ended`
   with the same reason; the
   host closes the peer connection at once; `/ice` stops renewing. Pending
   requests are ended the same way.
8. Offline devices: when a device's last User DO socket closes or errors while
   it has open sessions, the server waits 30 s. If it has not reconnected by
   then, every session where it is viewer or host ends: audit `ended` with
   reason `peer_offline`, push `session.ended` (reason `peer_offline`) to both
   devices, and the Session DO closes its sockets. A socket replaced by a new
   one from the same device does not count as offline.

**End reasons.** The first authoritative reason wins. A signaling socket
close never ends a session, and a `bye` that arrives just before an
authoritative end does not replace its reason. The same string is pushed in `session.revoked` /
`session.ended` and stored as the audit `ended` entry's `detail`:

| Reason | Cause | Push |
|---|---|---|
| `permission_revoked` | the host lowered the viewer's permission | `session.revoked` |
| `device_removed:viewer` | the viewer device was removed | `session.revoked` |
| `device_removed:host` | the host device was removed | `session.revoked` |
| `sharing_off` | the host turned Mac Screen sharing off | `session.revoked` |
| `signed_out` | a device called `/v1/devices/:id/sign-out` | `session.revoked` |
| `host_stopped` | the host called `/end` without a reason | `session.revoked` |
| `viewer_disconnected` | the viewer called `/end` without a reason | `session.revoked` |
| any other string | the `reason` given to `/end` (≤100 chars) | `session.revoked` |
| `expired` | a pending request was not decided within 5 min | `session.revoked` |
| `peer_offline` | a device stayed disconnected for 30 s | `session.ended` |
| `bye` | a device sent `bye` and no authoritative reason followed within 3 s | `session.ended` |
| `approve_failed` | the server could not set up the approved session | `session.revoked` |

A denied request ends with `session.denied`, not a reason.

The host enforces the scope: in a `view` session it ignores all input.

## Relays

User-owned relay list (team-owned later). Secrets never reach the server in
readable form: the configuring device seals the relay secret (shared secret,
or username + password) for every registered device with HPKE
(P-256, HKDF-SHA256, AES-GCM) to that device's `agreementKey`. Each device
opens its own blob and keeps it in the Keychain. A blob is base64 of HPKE
base mode (`P256_SHA256_AES_GCM_256`): the 65-byte encapsulated key, then the
ciphertext; the HPKE info is `cmux-device-hub relay v1 <relay id>`; the
plaintext is `{"mode":"shared_secret","secret":…}` or
`{"mode":"static","username":…,"password":…}`. Relays are used lowest
`priority` first. Shared-secret mode mints
`username = "<expiry>:<device-name>"`, `credential = base64(HMAC-SHA1(secret,
username))`, expiry 6 h, renewed before it ends. Both sides use the relays.
Free plan: direct, the user's own relays, and the host's tailnet/WireGuard
addresses as candidates; the cmux relay only on paid plans.

Plans: the hub keeps no plan list. For each ticket and each `/ice` call it
asks the cmux web backend of the user's Stack project (env `BILLING_ORIGINS`,
`<stackProjectId>=<origin>` pairs) for `GET /api/billing/plan` with the user's
own Stack access token (`x-stack-auth`). The answer must be authenticated and
about the same user. The cmux relay is included for `subscriptionPlanId` `pro`
or `max`, or `teamPlanId` `team` (the user's billing team, as cmux billing
resolves it). Go, Free, a non-200, a timeout (5 s) or any other answer gives
`ice: []`. There is no cache, so a lapsed subscription loses the relay on its
next ticket or refresh; ICE already handed out lasts its 1 h TTL.

## Computer Use approvals

A machine whose Computer Use worker needs a person's answer (a call on an app
outside the agent session's manifest; `docs/computer-use-approvals.md`, "The
approval question") asks the user's other devices through the hub. The hub
stores and forwards; it never decides, and the asking machine never takes its
word: it checks the deciding device's signature itself.

**Approvers** are the user's `macos` and `ios` devices other than the asking
one: the only ones with a protected collector (the cmux app's card, Face ID on
the phone). A Windows or Linux machine asks; it never answers (403
`not_approver`), and no device answers its own question (403 `self_approval`).

**The request** is the worker's object from the contract, unchanged:
`{v, nonce, client, machine, session, agent, workspace, target:{bundle_id,
executable, name}, tool, risk, created_ms, wait_until_ms, answerable_until_ms,
digest}`, where `digest` is the lowercase hex SHA-256 of the canonical JSON of
the object without `digest`. Canonical JSON: object keys (ASCII) sorted
by code point, no whitespace, integers only (no fractions or exponents),
strings escaped only for `"`, `\\`, `\b \f \n \r \t` and other U+0000-U+001F
as `\u00xx` (lowercase hex); everything else, `/` and non-ASCII included, is
written as its UTF-8 bytes. A string holding a lone surrogate (`\ud800` in
the body) is refused (400): Swift and Rust strings cannot hold one. `schemas/device-hub/test-vectors.json` holds the
shared vectors every client (hub, Swift `CmuxDeviceHub`, Rust client) tests
against: request signing, low-S, canonical JSON and decision signatures.

**The decision signature** (`sig`): the deciding device's ECDSA-P256-SHA256,
base64 raw r||s (64 bytes, high-S accepted), over the UTF-8 string
`"cmux-cu-approval-v1\n<digest>\n<decision>"` with `decision` one of `once`,
`session`, `always`, `deny`.

An approval is `{id, deviceId, deviceName, request, allowAlways, state,
decision, deciderId, sig, createdAt, answerableUntil, decidedAt}`; `state` is
`pending`, `decided`, `expired` or `cancelled`.

| Method, path | Body | Result | Notes |
|---|---|---|---|
| `POST /v1/approvals` | `{request, allowAlways?}` | `{approval}` | From the asking machine. The hub checks the shape (`v` 1, `nonce` 32 lowercase hex, the strings 1-200 characters, `bundle_id`/`executable` a string or null with at least one set, `target.name` 1-200, the times integers with `created_ms` <= `wait_until_ms` <= `answerable_until_ms`, `answerable_until_ms` in the future and at most 15 min away, the canonical request at most 4 KiB) and recomputes `digest` (400 `digest_mismatch`). `allowAlways` (default false) is the asking machine's `computerUse.phoneAlwaysAllow`: approvers offer Always Allow only when it is true, and the hub refuses an `always` otherwise. The same `nonce` again from the same device with the same digest returns the stored approval (a retry); with another digest, 409 `approval_exists`, as for a copy of another device's open question (same digest). At most 32 open questions per machine (429 `rate_limited`). Pushes `approval.request` to every approver's socket and an APNs alert to every `ios` approver with a push token. Audit `cu_requested`. |
| `GET /v1/approvals` | | `{approvals:[…]}` | The pending approvals this device may answer (not its own), oldest first: what a phone or Mac shows after it reconnects. |
| `GET /v1/approvals/:id` | | `{approval}` | Any device of the user. The asking machine reads the outcome after a reconnect. |
| `POST /v1/approvals/:id/decision` | `{decision, digest, sig}` | `{approval}` | From an approver. Checks, in order: 403 `self_approval` (the asking device), 403 `not_approver` (not `macos`/`ios`), 409 `approval_not_pending` (already decided or cancelled: a second answer or a replay), 409 `approval_expired` (past `answerable_until_ms`), 400 `digest_mismatch` (`digest` is not the stored one), 403 `always_not_allowed` (`always` without `allowAlways`), 400 `bad_decision_signature` (`sig` does not verify with the decider's registered key). Then the approval is `decided`; the hub pushes `approval.decided` to the asking device and `approval.closed` to the others. Audit `cu_decided`. |
| `DELETE /v1/approvals/:id` | | `{approval}` | Only the asking device (403 `not_asker`): its agent session ended (`app_approval_cancel`). A pending approval becomes `cancelled` (audit `cu_cancelled`, push `approval.closed`); any other state is returned as it is. |

- At `answerable_until_ms` a pending approval becomes `expired` (audit
  `cu_expired`, `approval.closed` to every device, the asking one included).
  Rows are deleted an hour after `answerable_until_ms`; the audit stays.
- The asking machine applies `approval.decided` (or a `decided` approval it
  read) only when `deciderId` is not itself, the decider is a `macos` or `ios`
  device in `GET /v1/devices`, `digest` is its own request's, and `sig`
  verifies with that device's `signingKey`. `always` also needs its own
  `computerUse.phoneAlwaysAllow`, whichever device answered. Anything else
  is ignored and the question stays open until its deadline.
- A host-scoped session (Device renewal) may ask, read and cancel its own
  approvals; it never lists, reads or answers another machine's (403
  `host_scope`).

**Phone push** (APNs, when the hub has `APNS_KEY_P8`, `APNS_KEY_ID`,
`APNS_TEAM_ID` and the token's topic is in `APNS_TOPICS`): to
`api.push.apple.com` (`production`) or `api.sandbox.push.apple.com`
(`development`), `apns-push-type: alert`, priority 10, `apns-collapse-id:
cu-<id>`, `apns-expiration` = `answerable_until_ms` in seconds:

```json
{"aps": {"alert": {"title": "Claude wants to use Safari", "subtitle": "build-box-7", "body": "api-server · click"},
         "sound": "default", "category": "CMUX_COMPUTER_USE_APPROVAL", "interruption-level": "time-sensitive",
         "thread-id": "cu:<asking device id>", "mutable-content": 1},
 "cmuxComputerUse": {"v": 1, "approvalId": "…", "deviceId": "<asking device id>", "hub": "<public origin>",
                     "allowAlways": false, "answerableUntil": 1793400600000}}
```

Texts are cleaned like the mobile Worker's (control and format characters
become spaces, cut to 60 characters with "…"); the machine name is the asking
device's hub name. The phone never acts on the push's text: it fetches the
approval from `hub` (only a hub address it has built in), recomputes the
digest from `request` and shows that. A token APNs answers 410 or
`BadDeviceToken` for is forgotten.
