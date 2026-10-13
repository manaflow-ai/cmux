# cnx-ios wire contract (v1)

Shared by `cnx-ios/backend` (Cloudflare Worker), `cnx-ios/rust` (link, hostd,
ffi) and the app. Change this file first, then the implementations.

## Identity and auth

- Every HTTP call and WebSocket carries `Authorization: Bearer <Stack access token>`
  (WebSocket may use subprotocol `cnx.v1, bearer.<token>` instead).
  The Worker verifies the JWT against Stack JWKS for the configured project
  (dev `454ecd03-1db2-4050-845e-4ce5b0cd9895`) and takes `sub` as `userId`.
- Team membership is checked through Stack (cached 60 s, refusals 15 s, in the
  TeamHub DO): the server API when the Worker has `STACK_SECRET_SERVER_KEY`,
  otherwise the client API (`GET /teams?user_id=me`) with the caller's own
  access token. (Changed: no Stack server key is provisioned for cnx-ios, so the
  caller-token path is the default.) v1 admission rule for a link: phone and Mac must belong to the
  same Stack user (the Mac's registering user). Team members cannot dial
  each other's Macs in v1.
- Personal space: teamId `personal-<userId>` (userId = the verified JWT `sub`)
  is a team of one. It is admitted for that user only, with no Stack membership
  call; any other user gets `403 not_member`. Every route works with it
  (devices, macs, prefs, signal WebSocket, relay) except
  `POST /v1/teams/:teamId/invites`, which answers `400 bad_request`
  "personal space has no members". Use it when the user has no Stack team.
- Devices: `deviceId` is a client-generated UUID persisted in Keychain;
  `kind` is `mac` or `phone`.

## HTTP (base `https://cnx-ios-api-<env>.debussy.workers.dev`; `debussy` is the account's workers.dev subdomain)

Errors are `{"error":{"code","message"}}` with codes `unauthorized` (401),
`bad_request` (400), `not_member` / `not_owner` / `wrong_team` (403),
`membership_unavailable` / `invite_failed` (502).

| Method + path | Body / result |
| --- | --- |
| `POST /v1/devices` | `{deviceId, kind, name, teamId, wgPublicKey?}` → `{device:{deviceId,ownerUserId,teamId,kind,name,wgPublicKey,createdAt,updatedAt,lastSeenAt}}` (upsert; caller must be a team member; a deviceId owned by another user is `403 not_owner`) |
| `GET /v1/teams/:teamId/macs` | → `{macs:[{deviceId,name,online,lastSeenAt,ownerUserId}]}` |
| `GET /v1/teams/:teamId/prefs` | → `{color, emoji}` for the caller (per user per team) |
| `PUT /v1/teams/:teamId/prefs` | `{color?: "#RRGGBB", emoji?: string\|null}` |
| `POST /v1/teams/:teamId/invites` | `{email}` → `{url, sent:true}`: Stack emails a team invitation whose link opens `url` (the configured callback) with the code. Changed from a bare link: without a Stack server key the API can only send the invitation email, not mint a shareable link. Needs the caller's `$invite_members` team permission. |
| `GET /v1/ice` | → `{iceServers:[{urls:[...],username?,credential?}], ttl}` from the Cloudflare TURN key (generate-ice-servers), STUN `stun:stun.cloudflare.com:3478` always included (STUN only if TURN is unavailable) |
| `GET /v1/health` | → `{ok:true, version}` |

## Signaling WebSocket `GET /v1/teams/:teamId/signal?deviceId=<id>`

One `TeamHub` Durable Object per team (hibernating WebSockets). JSON text
frames:

The socket is admitted only for a member of `teamId` whose `deviceId` is
registered to the caller in that team (else HTTP 403). The server selects
subprotocol `cnx.v1` when offered (never the bearer entry). One socket per
device: a newer connection closes the older with code 4000 `replaced` (no
offline presence in between); a Mac re-registered into another team is closed
with 4001 `moved`.

- server → client on connect: `{"type":"hello","you":deviceId,"macs":[{deviceId,name,online,lastSeenAt,ownerUserId}]}`
- server → all: `{"type":"presence","mac":{deviceId,name,online,lastSeenAt}}`
- client → server → peer: `{"type":"signal","to":deviceId,"from":deviceId,"sessionId":uuid,"payload":P}`.
  A `from` other than the socket's own deviceId is refused with `bad_request`.
  On every forwarded signal the DO sets `"fromUserId": <sender's Stack userId>`,
  overwriting any client value. `cnx-hostd` admits a dial only when `fromUserId` equals the Mac's
  own user; a missing `fromUserId` is refused with `bye {reason:"not_admitted"}`.
  where `P.kind` is one of
  - `webrtc-offer` `{sdp}`, `webrtc-answer` `{sdp}`, `webrtc-ice` `{candidate, sdpMid, sdpMLineIndex}`
  - `wg-init` `{publicKey, endpoints:[ "ip:port" ], overlayIP}`, `wg-resp` `{publicKey, endpoints, overlayIP}`
  - `bye` `{reason}`
- relay for WireGuard when no direct UDP path: binary frames
  `[16 bytes sessionId][16 bytes to deviceId][wireguard datagram]`; the DO
  rewrites the second field to the sender before forwarding. sessionId and
  deviceIds are UUIDs, written as their 16 raw bytes. Relay needs an
  admitted session between exactly those two devices (opened by a `signal`,
  ended by `bye` or after 24 h); datagrams up to 65535 bytes.
  A relay datagram of the single byte `0xff` is a reachability marker, "your
  UDP reaches me" (WireGuard messages are at least 32 bytes and start with
  type 1 to 4). A side sends it when authenticated UDP from its peer arrives
  (at most every 3 s). A side goes UDP-only only after receiving the marker;
  until then it sends every datagram through the relay as well, because UDP
  reachability can be one-way.
- WireGuard specifics: `publicKey` is base64 Curve25519; `endpoints` are
  `ip:port` strings (host and STUN-reflexive addresses of the tunnel's UDP
  socket); `overlayIP` is the sender's IPv4 address inside the tunnel (the
  dialer uses `10.77.0.2`, the answerer `10.77.0.1`).
- `{"type":"error","code","message","sessionId"?}` for refusals (`not_owner`,
  `offline`, `rate_limited`, `bad_request` for malformed frames or a `from`
  that is not the socket's device).
- Rate limits per socket: 20 text frames/s (burst 60), 4000 binary frames/s
  (burst 8000; excess binary frames are dropped silently).

Admission: the DO forwards `signal` only when `to` is a Mac owned by the
sender's userId, or the reply direction of an existing sessionId. A sessionId
is bound to the two devices of its first admitted signal.

## Link (inside either transport)

A link is one reliable ordered byte stream (WebRTC: data channel `cnx-link`,
ordered, reliable; WireGuard: one smoltcp TCP stream to `overlayIP:7420`).
Frames: `u32 BE length | u32 BE channel | u8 type | payload`, where `length`
counts the channel, type and payload bytes (5 + payload length). A payload is
at most 256 KiB; larger writes are split into several `data` frames.

| type | meaning |
| --- | --- |
| 0 `open` | payload JSON `{"service": S, "args": {...}}` |
| 1 `data` | raw bytes |
| 2 `close` | payload JSON `{"code","reason"}` |
| 3 `ping` / 4 `pong` | channel 0, 8-byte nonce |

Phone opens odd channel ids, Mac even. Services exposed by `cnx-hostd`
(default deny; anything else is refused with `close {code:"unknown_service"}`):

- `daemon`: splice to the cmux-tui session socket (protocol v12 JSON lines),
  filtered per line by a command allowlist (read/watch, terminal attach/input/
  resize, workspace/tab list/create/close/select, conversation and question
  commands). Command-bearing params such as spawn argv are denied.
- `acpmux`: splice to the acpmux loopback WebSocket: one link `data` frame
  carries exactly one WebSocket text message (a JSON value) in each direction.
- `file`: `{"path"}` read-only stream of a file inside a workspace root, for artifact preview.
- `echo`: test service.

A service that ends normally closes its channel with `{code:"eof"}`; a
refusal uses `unknown_service`, `forbidden`, `bad_request`, `not_found` or
`unavailable`. When the link itself drops, local channels see
`link_closed`.

## Transport switch

The app exposes Settings → Connection → Transport: `WebRTC` or `WireGuard`.
Both produce the same `Link`; switching tears the link down and redials.
