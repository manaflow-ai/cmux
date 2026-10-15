# cnx-ios wire contract (v1)

Shared by `cnx-ios/backend` (Cloudflare Worker), `cnx-ios/rust` (link, hostd,
ffi) and the app. Change this file first, then the implementations.

## Identity and auth

- Every HTTP call and WebSocket carries `Authorization: Bearer <Stack access token>`
  (WebSocket may use subprotocol `cnx.v1, bearer.<token>` instead).
  The Worker verifies the JWT against the Stack JWKS of one of its configured
  projects and takes `sub` as `userId`. The dev Worker accepts the dev project
  `454ecd03-1db2-4050-845e-4ce5b0cd9895` (primary) and the production project
  `9790718f-14cd-4f7e-824d-eaf527a82b82`, so dev and production app builds share
  it. The token's `iss` picks the project; signature, `iss`
  (`https://api.stack-auth.com/api/v1/projects/<id>`) and `aud` (`<id>`) are then
  checked against that project only. Other projects, anonymous users,
  restricted users (Stack's `is_restricted`, e.g. sign-up not finished; their
  tokens are signed by keys outside the default JWKS) and mismatched
  `iss`/`aud` pairs get 401. A token whose `kid` is missing from the cached
  JWKS, or a JWKS fetch that failed, refetches the project's keys once at
  once and verifies again (no 30 s cooldown on that path).
- A user is the pair (Stack project, `sub`): the same `sub` in two projects is
  two users. Membership is asked of the caller's own project with the caller's
  own token; a team, a personal space, device ownership and link admission
  never span projects. Stored rows record the project in the owner key
  (`<sub>` for the primary project, `<projectId>:<sub>` otherwise; Stack subs
  are UUIDs and never contain `:`), and the TeamHub of a non-primary project's
  team is named `<projectId>:<teamId>`. Every `userId`/`ownerUserId`/
  `fromUserId` on the wire stays the bare `sub`.
- Team membership is checked through Stack (cached 60 s, refusals 15 s, in the
  TeamHub DO): the server API when the Worker has `STACK_SECRET_SERVER_KEY`,
  otherwise the client API (`GET /teams?user_id=me`) with the caller's own
  access token. (Changed: no Stack server key is provisioned for cnx-ios, so the
  caller-token path is the default.) v1 admission rule for a link: phone and Mac must belong to the
  same Stack user (the Mac's registering user). Team members cannot dial
  each other's Macs in v1.
- Personal space: teamId `personal-<userId>` (userId = the verified JWT `sub`)
  is a team of one. The id carries no project: Stack subs are random v4 UUIDs, so
  a dev and a production user never share one in practice, and the space behind
  the id is still per project (above), so even a shared sub would give two
  separate spaces. It is admitted for that user only, with no Stack membership
  call; any other user gets `403 not_member`. Every route works with it
  (devices, macs, prefs, signal WebSocket, relay) except
  `POST /v1/teams/:teamId/invites`, which answers `400 bad_request`
  "personal space has no members". Use it when the user has no Stack team.
- Devices: `deviceId` is a client-generated UUID persisted in Keychain;
  `kind` is `mac` or `phone`.

## HTTP (base: production `https://cnx-ios-api.cmux.dev`, dev `https://cnx-ios-api-dev.debussy.workers.dev`)

The production Worker `cnx-ios-api-prod` accepts only the production Stack
project `9790718f-14cd-4f7e-824d-eaf527a82b82` and uses its own database
(PlanetScale `cmux/cnx-ios-prod`). The dev Worker accepts both projects for
testing. Production and Release app builds, the Mac app's Release build and
`run-host.sh` default to the production URL.

Errors are `{"error":{"code","message"}}` with codes `unauthorized` (401; the
message ends with the reason in parentheses, one of `malformed`,
`unknown_project`, `expired`, `not_yet_valid`, `bad_claims`, `unknown_key`,
`keys_unavailable`, `bad_signature`, `anonymous`, `restricted`, and never
echoes the token),
`bad_request` (400), `not_member` / `not_owner` / `wrong_team` (403), `not_found` (404),
`rate_limited` (429, with `retry-after` seconds; 0.7.0 per-user limits: 300 requests a minute overall, 30 `GET /v1/ice`, 10 invites, 60 notifications per Mac),
`membership_unavailable` / `invite_failed` (502).

| Method + path | Body / result |
| --- | --- |
| `POST /v1/devices` | `{deviceId, kind, name, teamId, wgPublicKey?}` → `{device:{deviceId,ownerUserId,teamId,kind,name,wgPublicKey,createdAt,updatedAt,lastSeenAt}}` (upsert; caller must be a team member; a deviceId owned by another user is `403 not_owner`) |
| `GET /v1/teams/:teamId/macs` | → `{macs:[{deviceId,name,online,lastSeenAt,ownerUserId}]}` |
| `GET /v1/me/macs` | → `{macs:[{deviceId,name,teamId,online,lastSeenAt,ownerUserId}]}`: the caller's own Macs (registered by the caller, the only Macs v1 lets it dial) in every team the caller still belongs to and in its personal space, with presence from each team's hub. Added in 0.5.0 so a phone finds its Mac whichever team either side has selected; the app polls it (every 4 s while its active team has no online Mac, else every 30 s) and moves to the team of an online Mac. `502 membership_unavailable` when Stack cannot list the caller's teams |
| `GET /v1/teams/:teamId/prefs` | → `{color, emoji}` for the caller (per user per team) |
| `PUT /v1/teams/:teamId/prefs` | `{color?: "#RRGGBB", emoji?: string\|null}`. `emoji` is the avatar glyph: `null` = automatic (team initial), `""` = none (color only), otherwise exactly one grapheme (letter, digit, symbol or emoji; not whitespace) |
| `POST /v1/teams/:teamId/invites` | `{email}` → `{url, sent:true}`: Stack emails a team invitation whose link opens `url` (the configured callback) with the code. Changed from a bare link: without a Stack server key the API can only send the invitation email, not mint a shareable link. Needs the caller's `$invite_members` team permission. |
| `GET /v1/ice` | → `{iceServers:[{urls:[...],username?,credential?}], ttl, turn}` from the Cloudflare TURN key (generate-ice-servers), STUN `stun:stun.cloudflare.com:3478` always included (STUN only if TURN is unavailable). `turn` (0.7.0) is `false` when no TURN server could be included: clients must say so (off-LAN WebRTC may then fail) instead of failing silently. `ttl` is 1 h (was 4 h) |
| `GET /v1/me/devices` | → `{devices:[{deviceId,kind,name,teamId,createdAt,updatedAt,lastSeenAt,online,push}]}` (0.7.0): every Mac and phone the caller registered, in any team or personal space. `online` is live presence for Macs and `null` for phones; `push` is whether the phone has an APNs token |
| `DELETE /v1/devices/:deviceId` | → `{deleted:true, deviceId}` (0.7.0). Owner only (`403 not_owner`, `404 not_found`). Deletes the row and its push token; the device's team hub drops the Mac from presence (broadcasting `presence` with `removed:true`), closes the device's signaling socket with code 4002 `removed`, and ends its relay sessions. A removed device that registers again is a new registration: removal tidies stale devices, it does not ban an id. Used by the phone (Settings → Connection → Macs / Phones) and by the Mac app ("Unpair this Mac") |
| `PUT /v1/devices/:deviceId/push` | `{token, environment, topic, kinds?}` → `{push:{environment,topic,kinds,updatedAt}}` (0.7.0). Phone only, owner only. `token` is the APNs device token in hex (64 to 200 hex digits), `environment` `sandbox` or `production` (the app's `aps-environment`), `topic` its bundle id, which must be one of the Worker's `APNS_TOPICS`. `kinds` is which events to push (default all): `question`, `permission`, `completed`, `failed`, `chief` |
| `DELETE /v1/devices/:deviceId/push` | → `{deleted:true}` (0.7.0): stop pushing to this phone (sign-out, notifications turned off) |
| `POST /v1/devices/:deviceId/notify` | `{eventId, kind, agent?, place?, workspaceId?, tabId?, sessionId?}` → `{configured, sent, failed, dropped}` (0.7.0). `:deviceId` is a Mac the caller owns. Pushes one event to every phone of the same owner that registered a token and wants that `kind`. Content minimization: the Mac sends only a kind, a short agent name (≤ 40 characters) and a short place such as the workspace title (≤ 60); the Worker writes the text itself ("Claude has a question", "Claude needs permission", "Claude finished", "Claude stopped with an error", "Chief replied") with the place as the body, and never forwards agent output, prompts, tool arguments or paths. The payload's `cnx` object carries `{mac, kind, eventId, workspaceId, tabId, sessionId}` so a tap opens that tab. `eventId` (≤ 64) is the APNs collapse id. `configured:false` when the Worker has no APNs key. Tokens APNs reports as gone are deleted (`dropped`). Rate limited per Mac (`429 rate_limited`) |
| `DELETE /v1/me` | → `{deleted:{devices:n}}` (0.7.0): purges everything the Worker stores for the caller (devices with their push tokens, team prefs) and evicts the caller's sockets. The app calls it first when the user deletes their account, then deletes the Stack account through cmux's account deletion (`DELETE <cmux API>/api/account`, as the main cmux app) |
| `POST /v1/me/bootstrap` | `{teamId, devices:[{deviceId,kind,name}]}` (at most 4) → `{devices:[{device}\|{error}], macs:{macs}\|{error}, myMacs:{macs}\|{error}, ice:{iceServers,ttl,turn}\|{error}}`: the phone's launch in one round trip (added in 0.8.0). Each part is the response of its own route (`POST /v1/devices` with `teamId`, `GET /v1/teams/:teamId/macs`, `GET /v1/me/macs`, `GET /v1/ice`), run at once; a part's error does not fail the others. A 404 means an older service: make the separate calls |
| `GET /v1/health` | → `{ok:true, version, stackProjects:[projectId], colo}` (accepted Stack projects, primary first; `colo` is the Cloudflare colo that received the request, added in 0.6.0) |
| `GET /v1/teams/:teamId/hub` | → `{ingressColo, hubColo, locationHint}`: diagnostics added in 0.6.0. Where this request entered Cloudflare, where the team's `TeamHub` runs, and the region a hub created by this request would get (`null` when unknown) |

Every response carries `Server-Timing` (0.8.0): the steps it waited on, for example
`auth;dur=1, member;dur=0, db_connect;dur=5, db;dur=82, hub;dur=12, total;dur=101`
(`auth` token check, `member` Stack membership, `db` the database, `hub` the team's Durable
Object, `turn` Cloudflare TURN, `stack` the Stack API). A request slower than 250 ms is
also logged with them.

## Signaling WebSocket `GET /v1/teams/:teamId/signal?deviceId=<id>`

One `TeamHub` Durable Object per team (hibernating WebSockets). A hub stays
where it is first created. Since 0.6.0 the Worker creates it with a
`locationHint` from the caller's own location (Cloudflare's geolocation of
the client: `wnam`, `enam`, `weur`, ...), not from the colo that received the
request. Free-plan traffic is sometimes received far from the client (on
2026-10-13 a California client was served from Paris), and a hub created then
would stay across an ocean. Existing hubs keep their place. JSON text
frames:

The socket is admitted only for a member of `teamId` whose `deviceId` is
registered to the caller in that team (else HTTP 403). The server selects
subprotocol `cnx.v1` when offered (never the bearer entry). One socket per
device: a newer connection closes the older with code 4000 `replaced` (no
offline presence in between); a Mac re-registered into another team is closed
with 4001 `moved`.

- server → client on connect: `{"type":"hello","you":deviceId,"macs":[{deviceId,name,online,lastSeenAt,ownerUserId}]}`
- server → all: `{"type":"presence","mac":{deviceId,name,online,lastSeenAt}}`; a deleted Mac's last presence adds `"removed":true` (0.7.0), and clients drop it from their lists
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
  datagrams reach me" (WireGuard messages are at least 32 bytes and start
  with type 1 to 4). A side sends it when an authenticated datagram from its
  peer arrives over UDP or TURN (at most every 3 s). A side leaves the relay
  only after receiving the marker; until then it sends every datagram
  through the relay as well, because reachability can be one-way. An address
  the OS refuses to send to (macOS Local Network privacy answers
  `EHOSTUNREACH` for LAN peers) is never chosen as the route again.
- WireGuard specifics: `publicKey` is base64 Curve25519; `endpoints` are
  `ip:port` strings (host and STUN-reflexive addresses of the tunnel's UDP
  socket); `overlayIP` is the sender's IPv4 address inside the tunnel (the
  dialer uses `10.77.0.2`, the answerer `10.77.0.1`).
- WireGuard over TURN (no wire change, so older Macs take part as they
  are): when `/v1/ice` lists a `turn:` UDP server, the dialer allocates a
  TURN relay and adds the relayed address to its `endpoints`. The Mac sends
  plain UDP to it like to any endpoint. The dialer sends through its
  allocation to the Mac's public endpoints and reports the path `turn` once
  that route is confirmed. TURN servers sit on well-routed anycast
  addresses, so this is usually far nearer than the Worker relay: on
  2026-10-13 it measured 16 ms RTT against 240 to 345 ms through the
  Worker. The relay frames stay as the fallback.
- `{"type":"error","code","message","sessionId"?}` for refusals (`not_owner`,
  `offline`, `rate_limited`, `bad_request` for malformed frames or a `from`
  that is not the socket's device). A refused relay frame is answered at most
  once per socket and session every 5 s (0.6.0; before, every frame of a
  tunnel whose peer had left drew an error). A client fails a dial only on
  an error for that dial's session or one without `sessionId`, never on an
  error naming another session. A WireGuard side that closes its tunnel
  sends `bye {reason:"closed"}` so the peer's tunnel stops too.
- Rate limits per socket: 20 text frames/s (burst 60), 12000 binary frames/s
  (burst 24000; excess binary frames are dropped silently). Raised from
  4000/8000 in 0.6.0: about 100 Mbit/s of 1280-byte datagrams plus ACKs.

Admission: the DO forwards `signal` only when `to` is a Mac owned by the
sender's user (same `sub` in the same Stack project), or the reply direction of an existing sessionId. A sessionId
is bound to the two devices of its first admitted signal.

## Link (inside either transport)

A link is one reliable ordered byte stream, the main stream (WebRTC: data
channel `cnx-link`, ordered, reliable; WireGuard: one smoltcp TCP stream to
`overlayIP:7420`), plus the input lane when both sides support it (below).
Frames: `u32 BE length | u32 BE channel | u8 type | payload`, where `length`
counts the channel, type and payload bytes (5 + payload length). A payload is
at most 256 KiB. Since the input lane, writers split data into frames of at
most 16 KiB (readers still accept 256 KiB from older peers).

| type | meaning |
| --- | --- |
| 0 `open` | payload JSON `{"service": S, "args": {...}}` |
| 1 `data` | raw bytes |
| 2 `close` | payload JSON `{"code","reason"}` |
| 3 `ping` / 4 `pong` | channel 0, 8-byte nonce |

A channel whose owner does not read it may hold the link reader for at
most 3 s; then that channel is closed `overflow` on both sides and the rest
of the link keeps flowing (before 2026-10-14 one unread channel, say a
terminal screen that never attached, stopped every channel and the pongs,
and the peer's keepalive closed the link). A side sends `ping` and `pong`
ahead of queued channel data. The keepalive
pings every 15 s and closes the link (`keepalive timed out`) only when
nothing at all, not a pong and no other frame, arrived for 20 s after a
ping. (Before, a ping queued behind megabytes of data on a slow relay and a
healthy link closed during a 10 MiB transfer.)

### Lanes (added with the input lane; backward compatible)

All channels used to share the main stream in FIFO order, so a keystroke,
a ^C or a resize could wait behind megabytes of terminal output
(head-of-line blocking). Borrowed from WebRTC, which gives each data
channel its own SCTP stream:

- **Negotiation.** The phone's first signal (`webrtc-offer`, `wg-init`)
  and the Mac's answer (`webrtc-answer`, `wg-resp`) carry
  `lanes: ["input"]` when that side supports the input lane. The lane is
  used only when both list it. Older peers send no `lanes` and ignore the
  field; the backend forwards payloads unchanged.
- **The input lane's stream.** WebRTC: a second ordered, reliable data
  channel `cnx-input` (its own SCTP stream, so a lost bulk packet does not
  hold input back at the receiver). The phone creates it with `cnx-link`;
  it carries frames only once both sides agreed. WireGuard: a second TCP
  stream to the same `overlayIP:7420`, opened by the phone right after the
  main one (the Mac takes the second accepted connection as the lane, for
  10 s). Its own smoltcp socket buffers keep input out of the main
  stream's 256 KiB send buffer and its 512 KiB stream queue; one TCP byte
  stream cannot reorder bytes already in its buffer, so priority inside the
  smoltcp write path would not help. The input lane carries the same frame
  format; a channel lives on one stream for its whole life.
- **Opening on the lane.** An `open` payload may add `"lane":"input"`.
  The opener sends it on the input lane when the link has one, else on the
  main stream. The peer replies on the stream the `open` arrived on, at
  input priority. Older Macs ignore the field (the channel works, without
  priority).
- **Scheduling on each stream.** A writer sends control frames (ping, pong,
  refusals) first, then input-lane frames, then bulk data round robin
  across channels, one 16 KiB frame per turn. A channel may queue 256 KiB
  before its sender waits, so a flood cannot build a long backlog in front
  of the link.
- **Use.** The app sends terminal keystrokes (`send`) on a `daemon` channel
  opened on the input lane. `resize-surface` stays on the attach channel,
  because the daemon gives geometry authority to the attaching client.
  Output, attach streams, `acpmux` and `file` stay bulk.

Phone opens odd channel ids, Mac even. Services exposed by `cnx-hostd`
(default deny; anything else is refused with `close {code:"unknown_service"}`):

- `daemon`: splice to the cmux-tui session socket (protocol v12 JSON lines),
  filtered per line by a command allowlist (read/watch, terminal attach/input/
  resize, workspace/tab list/create/close/select, conversation and question
  commands). Command-bearing params such as spawn argv are denied.
  `new-conversation-tab` is allowed only for an `agent_session` tab. The Mac
  sets its `host` to its own agent tab host, and refuses any other host,
  source or field.
- `acpmux`: splice to the acpmux loopback WebSocket. One WebSocket text
  message (a JSON value) is one write in each direction. A message above
  256 KiB arrives as several data frames, and the receiver joins frames until
  they parse as one JSON value (at most 32 MiB from the phone).
- `file`: `{"path"}` read-only stream of a file inside a workspace root, for artifact preview.
- `upload`: `{"name","size","cwd"?}` (`size` a number or a decimal string).
  The phone sends exactly `size` bytes as data frames. The Mac writes them to
  a new file and answers one data frame `{"path","size"}`, then `eof`. With
  `cwd`, which must be a folder of one of the Mac's tabs or inside a workspace
  root, the file goes to `<cwd>/.cmux/attachments/phone-<session>/`.
  Otherwise it goes to the host's uploads folder. A refusal (`too_large`,
  `forbidden`, `not_found`, `bad_request`, `io`) is answered
  `{"error","message"}` before the channel closes with that code. The name is
  made safe, and an existing file is never replaced (`name 2.ext`, ...).
- `browser`: `{"tab", "url"?}` a streamed Mac browser tab
  (verify/browser-stream.md). The channel carries the `cmux.rd/1` stream
  carrier (`u8 kind | u32 LE len | payload`, kind 1 control JSON, 2 datagram)
  of a `cmux.rb/1` session with the Mac's browser host, unchanged in the
  host-to-phone direction. hostd sends the rd `hello` itself, with the host's
  per-launch secret. The phone sends only datagrams (input, feedback, clock
  probes), `stop`, and rd `service` messages for `rb/1` whose body `t` is a
  viewer message (`rb.open`, `rb.close`, `rb.visibility`, `rb.screen`,
  `rb.vsync`, `rb.history`, `rb.navigate` to http, https or `about:blank`,
  `rb.menu.result`, `rb.dialog.result`, `rb.open_tab.result`, `rb.find`,
  `rb.find.stop`); hostd drops anything else. One host per `tab` outlives
  its channel; a new channel for the same tab closes the older with
  `replaced`. `url` must be http, https or `about:blank` (`forbidden`), and
  a Mac with no browser host refuses with `unavailable`. Under
  `CNX_CONTROL=stdio` the app starts the hosts: hostd writes
  `{"type":"need_browser","request","tab","url"}` and the app answers
  `{"type":"browser","request","addr":"127.0.0.1:PORT","secret"}` or
  `{"type":"browser_failed","request","reason"}`. It reports
  `{"type":"browser_gone","tab"}` when a host exits, and hostd asks
  `{"type":"browser_stop","tab"}` to stop one.
- `echo`: test service.
- `version` (link protocol 2, added 2026-10-14): one data frame
  `{"hostd": "<version>", "link": 2}`, then `eof`. A host that refuses it
  with `unknown_service` speaks link protocol 1 (keepalive pings queued
  behind data, a reader that stalls on one full channel); the phone keeps
  the link and says "Update cmux on this Mac".
  Added 2026-10-14: `"capabilities": [...]`, what the host does that a
  phone may rely on. `removal-v1` (the Mac host of manaflow-ai/cmux#20414):
  after its owner removes it (signaling 4002 `removed`) the host stays off
  until the person allows iPhone connections again on the Mac, so the
  phone's removal copy can say so. Absent (older hosts): the Mac may add
  itself back.
  `browser-stream-v1`: the host streams browser tabs (`browser`); the Mac
  build bundles a browser host (Release builds ship none yet). A host that
  says `removal-v1` without it refuses `browser` with `no_browser_host`, and
  the phone hides New Browser Tab for that Mac.

A service that ends normally closes its channel with `{code:"eof"}`; a
refusal uses `unknown_service`, `forbidden`, `bad_request`, `not_found` or
`unavailable`. When the link itself drops, local channels see
`link_closed`.

## Pairing (`auth` service and the Mac app's control lines)

The `auth` handshake is in `verify/phone-approvals.md` ("Pairing on every
link"). The limits and close codes the phone sees:

| close code | meaning |
| --- | --- |
| `busy` | an `auth` is already running on this link (one at a time), or 32 channels already wait behind it |
| `rate_limited` | the Mac asked about this iPhone recently: 10 minutes after the person refused one of its keys, or after 3 new identity keys from that device id (6 from all phones) in 10 minutes; the reason names the wait |
| `unavailable` | the Mac app has not sent its approved list within 10 s (hostd never asks before it has it) |
| `timeout` | nobody answered the Mac's prompt within 120 s; opening `auth` again on the same link asks again |
| `denied` / `unpaired` | the person refused this key / the signature or pairing failed |

hostd → app, one JSON line on stdout (supervised mode, `control.rs`):

```json
{"type":"pair_request","phone_device_id":"<uuid>","name":"<phone>",
 "identity_key":"04…","approval_key":"04…","registered_at_ms":1791961929681}
```

`registered_at_ms` (integer, epoch milliseconds; added 2026-10-14) is when
that phone device id first registered with the service (`createdAt` of `GET
/v1/me/devices`), so the Mac's dialog can show how new the device is. It is
absent when the lookup failed or took over 3 s; the dialog then says the
date is unknown.

### Mac identity (trust on first use)

`auth` args may carry `macNonce` (16 to 128 letters or digits, the phone's
own). The Mac app keeps a long-lived P-256 identity key in its Keychain and
sends it to hostd once, on stdin:

```json
{"type":"mac_identity","private_key":"<32-byte scalar hex>","public_key":"04…"}
```

With both, the challenge frame adds `macKey` (the X9.63 point, hex) and
`macSignature` (raw `r || s`, hex) over
`cnx-mac-identity-v1 \0 mac \0 phone \0 macNonce \0 challenge`. The phone
pins `macKey` per Mac device id when pairing first passes, and from then on
refuses (`mac_identity_changed`, before it signs) a Mac that proves another key
or none. Removing the Mac forgets the pin.

### Chief question answers

On the `chief` channel, a supervised hostd forwards `conversation-op` with
`op.kind` `question.answer` only with
`approval: {approver, nonce, expiresAt, signature}` (see
`verify/phone-approvals.md`, "Chief question answers"); hostd strips it before
the Chief owner. `approval` on any other op is refused.

## Connection setup (phone)

Nothing here changes the wire; it is how a phone keeps a dial short.

- The phone keeps its link device's signaling socket open between dials
  (and opens it at launch and on foreground, before any Mac is asked for);
  a dial reuses it. Signaling sockets send a WebSocket ping every 15 s and
  close after 40 s without any inbound frame, so a kept socket is never a
  dead TCP connection. A reused socket that does not answer a ping within
  2.5 s while a dial runs is replaced and the dial redone.
- `GET /v1/ice` is cached for half its `ttl` (60 s when it lists no TURN
  server) by the phone and by `cnx-hostd`, which refreshes it in the
  background so an answer never waits on it.
- WebRTC nominates the first working candidate pair (host, srflx and prflx
  at once; relay after 300 ms unless relay only).
- A signaling socket lost after the answer does not fail a WebRTC dial or
  answer: ICE and DTLS finish without it. Lost before the answer, the dial
  fails at once and the app redials without showing an error; it shows a
  failure only after the second consecutive failure.
- `cnx-hostd` reconnects a socket that was up for 20 s or more 150 ms after
  it drops (a Worker deploy resets every socket), instead of 1 s.

## Transport switch

The app exposes Settings → Connection → Transport: `WebRTC` or `WireGuard`.
Both produce the same `Link`; switching tears the link down and redials.

Debug builds add Settings → Developer → "Relay only (simulate distant
network)". It is a phone-side dial policy with no wire change: WebRTC gathers
only TURN relay candidates (path `turn`), and WireGuard never sends plain
UDP: it offers only its TURN relayed address and sends through TURN (path
`turn`), or, without a TURN server, sends empty `endpoints`, ignores the
Mac's and stays on the relay frames (path `relay`). Changing it redials.
