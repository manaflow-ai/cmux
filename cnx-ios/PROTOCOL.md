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
  (devices, macs, prefs, signal WebSocket) except
  `POST /v1/teams/:teamId/invites`, which answers `400 bad_request`
  "personal space has no members". Use it when the user has no Stack team.
- Devices: `deviceId` is a client-generated UUID persisted in Keychain;
  `kind` is `mac` or `phone`. A phone keeps one pair of ids (link, presence)
  per account and keeps them across sign-out (`verify/persistence.md`).

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
| `POST /v1/teams` | `{name}` (1 to 64 characters, trimmed) → `{team:{id,name}}`: creates a Stack team with the caller as creator and first member, using the project's server key (Stack refuses client-side team creation). `503 team_creation_unavailable` when the Worker has no server key for the caller's project; `403`/`502 team_create_failed` when Stack refuses. |
| `POST /v1/teams/:teamId/invites` | `{email}` → `{url, sent:true}`: Stack emails a team invitation whose link opens `url` (the configured callback) with the code. Changed from a bare link: without a Stack server key the API can only send the invitation email, not mint a shareable link. Needs the caller's `$invite_members` team permission. |
| `GET /v1/ice` | → `{iceServers:[{urls:[...],username?,credential?}], ttl, turn}` from the Cloudflare TURN key (generate-ice-servers), STUN `stun:stun.cloudflare.com:3478` always included (STUN only if TURN is unavailable). `turn` (0.7.0) is `false` when no TURN server could be included: clients must say so (off-LAN WebRTC may then fail) instead of failing silently. `ttl` is 1 h (was 4 h) |
| `GET /v1/me/devices` | → `{devices:[{deviceId,kind,name,teamId,createdAt,updatedAt,lastSeenAt,online,push}]}` (0.7.0): every Mac and phone the caller registered, in any team or personal space. `online` is live presence for Macs and `null` for phones; `push` is whether the phone has an APNs token |
| `DELETE /v1/devices/:deviceId` | → `{deleted:true, deviceId}` (0.7.0). Owner only (`403 not_owner`, `404 not_found`). Deletes the row and its push token; the device's team hub drops the Mac from presence (broadcasting `presence` with `removed:true`), closes the device's signaling socket with code 4002 `removed`, and ends its signaling sessions. A removed device that registers again is a new registration: removal tidies stale devices, it does not ban an id. Used by the phone (Settings → Connection → Macs / Phones) and by the Mac app ("Unpair this Mac") |
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
  - `wg-init` `{publicKey, endpoints:[ "ip:port" ], overlayIP, lanes?, relayed?, relayedTls?, version?}`,
    `wg-resp` `{publicKey, endpoints, overlayIP, lanes?, relayed?, relayedTls?, version?}`.
    `relayed` (optional) lists which of the sender's endpoints are its TURN
    relayed addresses (the phone's; a Mac's only when its network blocks
    UDP). The peer sends plain UDP to them like any endpoint, and labels
    such a route `turn`, not `direct`; `relayedTls` lists which of them
    reach their TURN server over TCP or TLS (label `turn-tls`). `version`
    is the WireGuard protocol version: absent (0) from older peers, `2`
    from peers that never send relay frames and confirm routes with an
    in-tunnel `reach` message (below). A roam's endpoint announcement
    (`{"t":"endpoints", generation, endpoints, relayed?, relayedTls?}`)
    carries a new allocation's address the same way. Older peers omit all
    of these, and the label stays `direct`.
  - `wg-endpoints` `{generation, endpoints, relayed?, relayedTls?}` (API
    0.9.0): the same endpoint announcement a roaming side sends inside the
    tunnel (below), also sent through signaling, because the peer may not
    receive anything from the new address yet (a NAT that filters by
    address). The receiver applies the newer generation of either copy.
    Older peers ignore it (an unknown kind).
  - `bye` `{reason}`
- Relay frames (retired in API 0.9.0). Binary frames
  `[16 bytes sessionId][16 bytes to deviceId][wireguard datagram]` used to
  carry WireGuard when no UDP path worked. The DO no longer forwards them:
  every binary frame is dropped, and its sender gets
  `{"type":"error","code":"relay_retired","sessionId":...}` at most once
  per socket and session every 5 s. The error always names the frame's
  session, so an older client fails no other dial in progress (it fails a
  dial only on an error for that dial's session or one without
  `sessionId`). A frame shorter than 16 bytes is dropped silently. The
  TeamHub keeps presence and signaling (introductions); it carries no
  data. A WireGuard path without UDP is TURN over TLS (below).
- WireGuard specifics: `publicKey` is base64 Curve25519; `endpoints` are
  `ip:port` strings (host and STUN-reflexive addresses of the tunnel's UDP
  socket); `overlayIP` is the sender's IPv4 address inside the tunnel (the
  dialer uses `10.77.0.2`, the answerer `10.77.0.1`).
- WireGuard paths, in order: plain UDP (direct, hole-punched), then TURN
  over UDP, then TURN over TLS on 443. When `/v1/ice` lists a TURN server
  the dialer allocates a TURN relay and adds the relayed address to its
  `endpoints`. It tries `turn:...?transport=udp` first; when that gets no
  allocation it uses `turns:...:443?transport=tcp` (any other `turns:` URL,
  else `turn:...?transport=tcp`, when the service lists no TLS on 443).
  The TLS attempt starts 500 ms after the UDP one (at once when UDP
  fails), so a network that answers UDP never opens a TLS connection; when
  TLS finishes first, UDP gets 250 ms more. Only the leg to the TURN
  server changes (RFC 5766 over TCP or TLS): the allocation still relays
  UDP, so the Mac sends plain UDP to the relayed address like to any
  endpoint. On the stream every STUN message and ChannelData message is
  framed by its own length, ChannelData padded to 4 bytes (RFC 5766
  §11.5). The TLS server name is the URL's host, checked against the
  public web PKI. The dialer sends through its allocation to the Mac's
  public endpoints and reports the path `turn`, or `turn-tls` when the
  allocation rides TCP or TLS. TURN servers sit on well-routed anycast
  addresses: on 2026-10-13 TURN over UDP measured 16 ms RTT against 240 to
  345 ms through the retired Worker relay. A Mac whose STUN servers never
  answer (its network drops UDP) takes its own TURN allocation the same
  way, lists it in `wg-resp` (`relayed`, `relayedTls`), and sends through
  it; so does a side with relay only or UDP blocked (debug). A TURN
  allocation whose TCP or TLS stream dies is replaced at once (then after
  1, 3, 10 and 30 s) and announced like a roam's.
  Datagrams queue toward a TURN allocation by class (no wire change):
  control (handshake messages, keepalives), then input (what the tunnel's
  pacer sends as interactive: keystrokes, ACKs, terminal output at a
  terminal's pace), then bulk (large transfers) and media (the media
  lane's video), which share the rest by bytes. A datagram the pacer did
  not class (packets held through a handshake, the watchdog's resends) is
  input up to 400 bytes, else bulk. Each class is bounded by bytes (16, 64,
  256 and 256 KiB) and drops its oldest datagram past it, and media older
  than 250 ms is dropped, so on a backed-up TLS stream media never delays
  control or input and memory stays bounded.
- WireGuard route confirmation. Reachability can be one-way, so a side that
  receives its peer's datagrams on a route does not yet know its own reach
  the peer. Until it does, it sends every datagram on that route and through
  its TURN allocation too (and to every candidate when it has no route; and
  every 100 ms to each of the peer's other endpoints, its relayed addresses
  among them). The confirmation is an overlay UDP datagram to port 7421 of
  the peer, JSON `{"t":"reach","from":"ip:port","via":"udp"|"turn"}` ("your
  datagrams reach me": they arrived from `from`, your address as seen here,
  on my plain UDP socket or my TURN allocation), sent by a version-2 side
  when an authenticated datagram from its peer arrives: at once on a new
  route, then 100, 300 and 1000 ms later while datagrams keep arriving, then
  at most every 3 s. `from` names the carrier that works (the receiver's
  TURN when it is its relayed address, else plain UDP) and `via` whether it
  reached the peer's relayed address. The current route is confirmed only
  when it is that pair. Otherwise the side switches to that pair when it is
  an upgrade (direct UDP instead of a relayed route), or when no `reach`
  confirmed the current route in the 4 s since it became the route (for
  example plain UDP to the peer's relayed address when its own UDP to the
  peer's LAN address is lost), and keeps it while `reach` keeps naming it,
  even though the peer's datagrams arrive on another route, and for 25 s
  after the last one (an idle link's keepalives every 10 s each draw one),
  or until the peer announces endpoints without that address. A relayed copy
  of a datagram never displaces a direct route that still delivers. A side
  that receives its peer's direct UDP while most of the peer's datagrams
  arrive relayed sends `reach` for that direct arrival at once (at most
  every 100 ms), so the peer upgrades; while the route is relayed (its own
  TURN, or the peer's relayed address) the direct candidates are tried every
  5 s. A confirmed route that is silent for 14 s, or that no `reach`
  confirmed for 25 s, is no longer trusted (every route again until a new
  `reach`). A bare `{"t":"reach"}` confirms the current route. An older peer
  (version 0) sends its confirmation through the retired relay, where it is
  lost, and never sends `reach`: with such a peer a side takes the peer's
  authenticated datagrams as the confirmation. An address the OS refuses to
  send to (macOS Local Network privacy answers `EHOSTUNREACH` for LAN peers)
  is never chosen as the route again.
- WireGuard roaming (no wire change for older peers, which simply never
  announce): a side whose network changed (the phone's `NWPathMonitor`, the
  Mac's routing socket) moves its tunnel onto a new UDP socket and at once
  sends an authenticated datagram from it (a keepalive on a session younger
  than 120 s, else a handshake initiation); the peer follows the new
  address (WireGuard endpoint roaming) and answers `reach` at once. Until
  the new route is confirmed every datagram also goes through TURN and to
  all of the peer's candidates, and for 3 s after a roam both sides also
  spray candidates every 100 ms. The roaming side learns its new reflexive
  address with STUN on the new socket and takes a fresh TURN allocation on
  the transport the new network allows (UDP, else TLS). New endpoints
  travel inside the tunnel: an overlay UDP datagram to port 7421 of the
  peer's overlay address, JSON
  `{"t":"endpoints","generation":N,"endpoints":["ip:port"]}` (at most 16,
  `generation` grows per announcement), answered with
  `{"t":"ack","generation":N}` and resent after 0.15, 0.4, 1, 2 and 4 s
  until acknowledged; and once through signaling (`wg-endpoints`, again
  after the side's signaling socket is replaced). An empty list means
  "same endpoints, my network changed". A side that receives an
  announcement replaces its candidates (unless empty) and resends the data
  messages it sent in the last 20 s (at most 128); so does a side whose
  route changes or that roams, as soon as it has a route to send them on.
  WireGuard's replay window drops the copies that already arrived, and TCP
  inside the tunnel never waits out its 1 s minimum retransmission
  timeout. The tunnel's UDP socket asks for 2 MB buffers, so such a burst
  is not dropped by the OS. While the confirmed route is TURN, plain UDP
  candidates are tried every 5 s, so a direct path wins again. A side
  whose signaling socket was replaced moves its sessions to the new socket
  (for `bye` and `wg-endpoints`).
- `{"type":"error","code","message","sessionId"?}` for refusals (`not_owner`,
  `offline`, `rate_limited`, `bad_request` for malformed frames or a `from`
  that is not the socket's device, `relay_retired` for a binary frame). A
  refused signal names its session once the frame has a valid `sessionId`
  (0.9.0). A client fails a dial only on an error for that dial's session
  or one without `sessionId`, never on an error naming another session. A
  WireGuard side that closes its tunnel sends `bye {reason:"closed"}` so
  the peer's tunnel stops too.
- Rate limits per socket: 20 text frames/s (burst 60). Binary frames
  (retired) are counted in their own bucket (12000/s, burst 24000), so a
  flood of an older client's frames costs at most a bounded number of
  `relay_retired` checks; excess ones are dropped silently.

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

### Media lane (`video`; added 2026-10-14, backward compatible)

Browser video as RTP beside the link's reliable streams
(verify/browser-video-track.md). One lane per link carries one H.264 stream
from the Mac to the phone; a `browser` channel claims it (below).

- **Negotiation.** The phone lists `"video"` in its first signal's `lanes`
  (`webrtc-offer` or `wg-init`); the Mac lists it back in its answer only
  when it attached a sender. Either side without it (an older phone, an older
  Mac, `CNX_VIDEO_LANE=0`) leaves the lane out and browser video stays on the
  `browser` channel. No other negotiation happens, and a WireGuard roam
  changes nothing.
- **The stream.** H.264 (RFC 6184: STAP-A for the parameter sets, FU-A),
  payload type 102, 90 kHz clock, the host's capture time as the RTP
  timestamp. The transport-wide sequence number extension
  (`draft-holmer-rmcat-transport-wide-cc-extensions-01`) on every packet.
  RTCP back: generic NACK (resent at most 3 times, 40 ms apart), PLI and FIR
  (the Mac makes a keyframe at most every 250 ms), TWCC feedback every 25 ms,
  sender and receiver reports.
- **WebRTC carrier.** A video track on the link's own peer connection: the
  phone's offer has one `recvonly` H.264 m-line with `nack`, `nack pli`,
  `ccm fir` and `transport-cc`; the Mac adds a `sendonly` track before it
  applies the offer. SRTP as usual.
- **WireGuard carrier.** RTP and RTCP as plain UDP datagrams inside the
  tunnel, between overlay port 7422 on both sides (next to the link's TCP
  7420 and the roaming messages' UDP 7421), with no SRTP, ICE or DTLS
  (WireGuard authenticates and encrypts every datagram). RTCP is told from
  RTP by the second byte (192 to 223, RFC 5761). The SDP-less parameters are
  fixed: payload type 102, TWCC extension id 1, the Mac's SSRC `0x636e7876`.
  A datagram from another overlay address, or RTP from another SSRC, is
  dropped. The Mac binds its port before it answers, the phone before it
  opens the link stream. RTP payloads are at most 1196 bytes, so a packet
  with its header and room for three extensions stays within the 1232-byte
  datagram limit of the 1280-byte tunnel; nothing is fragmented. In cmux-wg's
  scheduler RTP is `Media` (dropped after 50 ms in the send queue) and RTCP
  `Interactive`.
- **Roaming.** After a network change on either side (its own roam, or an
  endpoint announcement on 7421 from the peer) the phone sends a PLI and the
  Mac's sender resets its congestion baseline; the lane's port, keys and
  parameters stay.

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
  `"video":"track"` (with the media lane): the page's main video stream
  rides the link's media lane instead of the channel, on either carrier;
  rd control, input, clock probes and secondary surfaces stay on the
  channel. A newer `browser` channel that asks for the lane takes it, and the
  older tab's video returns to its channel with a keyframe. A hostd without
  the lane, or an older one, ignores the field and streams on the channel.
  `"video_tag": N` (u32, random per channel): hostd appends it to each of
  this tab's lane access units as an H.264 SEI NAL unit after the slices
  (user data unregistered, UUID `cnx-video-tag-v1` in ASCII, then N as 8
  lowercase hex digits, then the stop bit `0x80`; no byte is zero, so no
  emulation prevention). The phone keeps a lane frame only when it carries
  its own channel's tag, strips the SEI before decoding, and starts at its
  first keyframe; it never learns when the lane switched tabs otherwise.
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
  `browser-video-track-v1`: the host honors `browser {"video":"track"}`
  (the media lane above), on WebRTC and, since 2026-10-14, on WireGuard.

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
  at once; relay after 300 ms unless relay only). WireGuard tries direct
  UDP, TURN over UDP and (only when UDP gets no TURN allocation) TURN over
  TLS on 443.
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
network)" and "Block UDP". Both are phone-side dial policies with no wire
change, and changing either redials.

- Relay only: WebRTC gathers only TURN relay candidates (path `turn`), and
  WireGuard never sends plain UDP: it offers only its TURN relayed address
  and sends through TURN (path `turn`, or `turn-tls` when UDP to the TURN
  server fails). Without a TURN server the dial fails at once.
- Block UDP (WireGuard; WebRTC ignores it): no plain UDP in or out and no
  TURN over UDP, as on a network that passes only TCP. The link rides TURN
  over TLS on 443 (path `turn-tls`); without a `turns:` or TCP `turn:`
  server the dial fails at once. The rig sets it without the app's
  settings: simulator `SIMCTL_CHILD_CNX_DEV_BLOCK_UDP=1`.

The phone's link line names the path: "WireGuard direct", "WireGuard relay
(TURN)", "WireGuard relay (TURN over TLS)" (and the same for WebRTC's
TURN). There is no WebSocket relay any more. cnx-hostd reports the path as
`direct`, `turn`, `turn-tls` or `none` (`phone_up`, `phone_path`).
