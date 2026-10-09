# cmux-next mobile: wire contract

This file is the single contract between the iOS app (`App/`, `Packages/`),
the Mac host (`host/`) and the backend (`backend/`). Change it first, then the
code on every side.

## 1. Layers

```
 UI (SwiftUI/UIKit)                         Mac providers (pty, acp, cdp, chief)
        |                                              |
 HostClient (RPC + events + streams)        HostServer (RPC + events + streams)
        |                                              |
 Link: lanes of ordered reliable byte messages  <---->  Link
        |                                              |
 LinkTransport impl: WebRTC | Loopback | (future: WireGuard, irx, WS relay)
```

Everything above `Link` is transport agnostic. A transport only has to
provide three ordered, reliable lanes that carry whole byte messages:

| Lane | Id | Use |
| --- | --- | --- |
| control | `ctl` | JSON RPC requests, responses and events (UTF-8 text) |
| interactive | `int` | small latency-sensitive binary stream frames (terminal I/O) |
| bulk | `blk` | large binary frames (browser images, file blobs) |

WebRTC maps each lane to one negotiated data channel (`ordered: true`,
reliable), ids 0, 1, 2, labels as above.

### Fragmentation

Messages may be any size. The shared `LaneCodec` (Swift `CNTransport`, TS
`host/src/transport/laneCodec.ts`) splits every message into chunks of at most
16 KiB of payload. Each chunk is `[u8 flags][payload]`; flag bit 0 (`0x01`)
marks the final chunk of a message. Lanes are ordered, so the receiver
concatenates chunks until a final one. A transport implementation sends and
receives chunks; the codec sits between the transport and the link.

## 2. Control lane messages (JSON)

```jsonc
{"t":"req","id":7,"m":"term.attach","p":{...}}       // client -> host (or host -> client)
{"t":"res","id":7,"ok":true,"r":{...}}
{"t":"res","id":7,"ok":false,"e":{"code":"not_found","message":"..."}}
{"t":"evt","topic":"agent.update","p":{...}}          // host -> client push
```

Ids are per sender, positive integers. Error codes: `bad_request`,
`not_found`, `unauthorized`, `unavailable`, `internal`, `unsupported`.

The first request on a new link is `host.hello`. The host refuses everything
else until the hello is accepted.

## 3. Binary stream frames (int and blk lanes)

```
[u8 kind][u32 BE streamId][payload...]
```

| kind | lane | direction | payload |
| --- | --- | --- | --- |
| 1 `termOutput` | int | host -> phone | raw PTY bytes |
| 2 `termInput` | int | phone -> host | raw input bytes (already encoded by Ghostty) |
| 3 `browserFrame` | blk | host -> phone | `[u32 seq][u16 cssW][u16 cssH][u16 pxW][u16 pxH][u8 format 0=jpeg 1=png]` + image bytes |

Stream ids are allocated by the host and returned by the `*.attach` call.

## 4. RPC methods

All params and results use camelCase JSON. Timestamps are ms since epoch.

### host
- `host.hello {client:{name,version,platform}, protocol:1}` -> `{hostId, hostName, os, version, protocol:1, capabilities:[string]}`
  Capabilities: `term.v1`, `agent.v1`, `browser.v1`, `conv.v1`.
- `host.ping {}` -> `{at}`

### conversations (Chief, iMessage-style)
Conversation `{id, kind:"chief"|"agent"|"group", title, subtitle?, avatar:{initials, tint}, pinned, muted, unread, lastMessage?:Message, updatedAt, participants:[{id,name}]}`
Message `{id, conversationId, clientId?, sender:{id,name,isMe}, text, sentAt, status:"sending"|"sent"|"delivered"|"read"|"failed", replyTo?}`

- `conv.list {}` -> `{conversations:[Conversation]}`
- `conv.history {conversationId, before?, limit?}` -> `{messages:[Message], hasMore}`
- `conv.send {conversationId, text, clientId}` -> `{message}` (echo replaces the pending bubble by `clientId`)
- `conv.read {conversationId}` -> `{}`
- `conv.setPinned {conversationId, pinned}` / `conv.setMuted {conversationId, muted}` / `conv.delete {conversationId}` -> `{}`
- events: `conv.message {message}`, `conv.updated {conversation}`, `conv.typing {conversationId, senderId, typing}`, `conv.removed {conversationId}`

### agents (ACP sessions, AI-chat style)
Session `{id, title, harness, model?, mode?, cwd, status:"idle"|"running"|"waiting"|"error"|"closed", createdAt, updatedAt, unread, preview?}`
Harness `{id, name, available, models:[{id,name}], modes:[{id,name}]}`
TranscriptItem (upserted by `id`):
```jsonc
{"id","kind":"user","text","attachments":[]}
{"id","kind":"assistant","text","streaming":bool}          // markdown
{"id","kind":"thought","text","streaming":bool,"durationMs"?}
{"id","kind":"tool","toolKind":"read|edit|execute|search|fetch|delete|think|other","title","status":"pending|running|completed|failed","input"?,"output"?,"locations":[{path,line?}],"diff"?:[{path,oldText?,newText}]}
{"id","kind":"plan","entries":[{content,status:"pending|in_progress|completed",priority}]}
{"id","kind":"permission","toolCallId","title","options":[{id,name,kind:"allow_once|allow_always|reject_once|reject_always"}],"resolved"?:optionId|"cancelled"}
// "resolved":"cancelled": the request ended unanswered (agent.cancel, turn end, agent exit, host restart)
{"id","kind":"notice","level":"info|warning|error","text"}
{"id","kind":"turnEnd","stopReason","durationMs"}
```
- `agent.harnesses {}` -> `{harnesses:[Harness]}`
- `agent.list {}` -> `{sessions:[Session]}`
- `agent.create {harness, cwd?, model?, prompt?}` -> `{session}`
- `agent.history {sessionId}` -> `{session, items:[TranscriptItem], commands:[{name,description}]}`
- `agent.prompt {sessionId, text, attachments?:[{name,mimeType,dataBase64}]}` -> `{}`
- `agent.cancel {sessionId}` / `agent.close {sessionId}` -> `{}`
- `agent.permission {sessionId, itemId, optionId}` -> `{}`
- `agent.setModel {sessionId, modelId}` / `agent.setMode {sessionId, modeId}` -> `{}`
- `agent.rename {sessionId, title}` -> `{}`
- events: `agent.session {session}`, `agent.item {sessionId, item}`, `agent.removed {sessionId}`

### terminals
Terminal `{id, title, cwd, cols, rows, running, createdAt}`
- `term.list {}` -> `{terminals:[Terminal]}`
- `term.create {cols, rows, cwd?}` -> `{terminal}`
- `term.attach {terminalId, cols, rows}` -> `{streamId, terminal}`; the host first
  sends the scrollback replay as `termOutput` frames, then live output.
- `term.detach {streamId}` / `term.resize {terminalId, cols, rows}` / `term.close {terminalId}` -> `{}`
- `term.rename {terminalId, title}` -> `{}`
- events: `term.updated {terminal}`, `term.exited {terminalId, code}`

### browser (tabs visible on the Mac)
Tab `{id, url, title, loading, progress, canGoBack, canGoForward, faviconUrl?, active}`
- `browser.list {}` -> `{tabs:[Tab]}`
- `browser.create {url?}` -> `{tab}`
- `browser.attach {tabId, width, height, scale, mobile:true}` -> `{streamId, tab}` (width/height in CSS px)
- `browser.detach {streamId}` / `browser.close {tabId}` / `browser.activate {tabId}` -> `{}`
- `browser.viewport {tabId, width, height, scale}` -> `{}`
- `browser.ack {streamId, seq}` -> `{}` (host keeps at most 2 unacked frames)
- `browser.navigate {tabId, url}` / `browser.back {tabId}` / `browser.forward {tabId}` / `browser.reload {tabId}` / `browser.stop {tabId}` -> `{}`
- `browser.pointer {tabId, type:"down"|"up"|"move", x, y, button:"left"|"none", clickCount}` -> `{}` (CSS px)
- `browser.touch {tabId, type:"start"|"move"|"end"|"cancel", points:[{x,y,id}]}` -> `{}`
- `browser.scroll {tabId, x, y, dx, dy}` -> `{}`
- `browser.key {tabId, type:"down"|"up", key, code, text?, modifiers:int}` -> `{}` (CDP modifier bits)
- `browser.text {tabId, text}` -> `{}`
- `browser.screenshot {tabId}` -> `{dataBase64}` (tab overview thumbnail, jpeg)
- events: `browser.tab {tab}`, `browser.closed {tabId}`, `browser.detached {streamId, tabId, reason:"displaced"}`
  (another client attached the same tab; this client's stream ended)

## 5. Backend HTTP API (Cloudflare Worker, base `https://<worker>/v1`)

JSON bodies. Phone auth: `Authorization: Bearer <accessToken>` (HS256 JWT,
15 min, `sub`=userId, `typ`="user"). Host auth: `Bearer <hostToken>` (opaque,
stored hashed). Errors: `{error:{code,message}}` with HTTP status: 400
`bad_request`, 401 `unauthorized`, 403 `forbidden`, 404 `not_found` (410 for an
expired or claimed pairing), 429 `rate_limited`, 501 `unsupported`, 503
`unavailable`, 500 `internal`.

| Method | Path | Auth | Body -> Result |
| --- | --- | --- | --- |
| POST | `/auth/stack` | - | `{accessToken, projectId}` -> `Tokens`. Primary sign-in: the Stack Auth access token cmux iOS uses. Verified against the project JWKS (ES256 or RS256), `iss`=`https://api.stack-auth.com/api/v1/projects/<projectId>`, `aud`=projectId, unexpired, not anonymous. Prod `9790718f-14cd-4f7e-824d-eaf527a82b82` always; dev `454ecd03-1db2-4050-845e-4ce5b0cd9895` only while the backend enables it (Debug builds). Identity is `stack:<projectId>` + Stack user id; only prod links to an existing account by verified email |
| POST | `/auth/test` | - | `{email, secret}` -> `Tokens`. Only when the `TEST_LOGIN_SECRET` secret is set (else 404) and only for `@test.cmux.dev` emails; automated simulator runs |
| POST | `/auth/email/start` | - | `{email}` -> `{nonce}` (6-char code mailed) |
| POST | `/auth/email/verify` | - | `{email, code, nonce}` -> `Tokens` |
| POST | `/auth/apple` | - | `{identityToken, fullName?, nonce?}` -> `Tokens`; when `nonce` (raw) is sent, the token's `nonce` claim must be its SHA-256 hex (or the raw value) |
| GET | `/auth/oauth/:provider/start?redirect=<app scheme url>&code_challenge=<S256>&code_challenge_method=S256` | - | 302 to GitHub/Google. PKCE S256 is required |
| GET | `/auth/oauth/:provider/callback` | - | 302 to `redirect?code=<one-time>` (or `?error=`) |
| POST | `/auth/oauth/exchange` | - | `{code, codeVerifier}` -> `Tokens` (verifier required) |
| POST | `/auth/refresh` | - | `{refreshToken}` -> `Tokens`. Rotates. Retrying the immediately previous token within 30 s returns the same new pair; other reuse revokes the token family (401) |
| POST | `/auth/logout` | user | `{refreshToken}` -> `{}` |
| GET | `/me` | user | -> `{user}` |
| DELETE | `/me` | user | -> `{}` |
| POST | `/hosts/pair/start` | - | `{name, os}` -> `{deviceCode, userCode, expiresAt, interval}` |
| POST | `/hosts/pair/poll` | - | `{deviceCode}` -> `{status:"pending"}` or `{status:"approved", hostId, hostToken, userId, approverEmail}` (token returned once; the host should confirm `approverEmail` with its user before using it) |
| POST | `/hosts/pair/approve` | user | `{userCode}` -> `{host}`; 10 attempts per user per 10 min (429) |
| GET | `/hosts` | user | -> `{hosts:[{id,name,os,online,lastSeenAt,createdAt}]}` |
| DELETE | `/hosts/:id` | user | -> `{}` |
| GET | `/ice` | user or host | -> `{iceServers:[{urls:[...],username?,credential?}], ttl:3600}`. A user must have at least one paired host (else 403); 60 per hour per user, and per host (429) |
| GET | `/signal` (WebSocket) | user or host (`Authorization: Bearer`) | signaling, below. `?token=` is still accepted but deprecated |

`Tokens = {accessToken, refreshToken, expiresIn, user:{id,email,name}}`.

### Signaling (Durable Object per user, `SignalRoom`)

Each socket is a peer: `{peerId, role:"phone"|"host", hostId?}`. JSON frames:

```jsonc
// server -> peer on connect
{"type":"welcome","peerId":"p_..","hosts":[{"hostId","online"}]}
{"type":"presence","hostId":"h_..","online":true}
// peer -> server -> peer (server stamps "from")
{"type":"offer","to":"h_..","sessionId":"s_..","sdp":"...","policy"?:"relay"} // phone -> host (to = hostId)
{"type":"answer","to":"p_..","sessionId":"s_..","sdp":"..."}      // host -> phone (to = peerId)
{"type":"candidate","to":"..","sessionId":"s_..","candidate":"..","sdpMid":"0","sdpMLineIndex":0}
{"type":"bye","to":"..","sessionId":"s_.."}
{"type":"error","code":"host_offline","message":"..","sessionId"?:"s_.."}
```

`presence` for a host deleted with `DELETE /hosts/:id` carries `"removed":true`.
Error codes: `host_offline` (no socket for that hostId), `peer_offline` (no
phone with that peerId), `forbidden` (phones send offers, hosts send answers),
`bad_request` (malformed frame). `{"type":"ping"}` gets `{"type":"pong"}`.
Close codes: 4001 replaced by a newer connection of the same host, 4002 phone
access token expired (refresh, then reconnect), 4003 host deleted, 4004 account
deleted. On 4003 and 4004 a host drops its live WebRTC peers.

The phone is always the offerer. The host answers. ICE is trickled.

`policy:"relay"` on an offer (optional, default `"all"`) asks the host to use
`iceTransportPolicy: relay` for that session too, so a phone-side "relay only"
toggle forces TURN on both ends. A relay-only side also drops non-`relay`
remote candidates and refuses to open the link unless its selected local
candidate is `relay` (libjuice can otherwise form a direct path from
peer-reflexive candidates).

## 6. Database (PlanetScale MySQL, via `@planetscale/database`)

Tables: `users`, `identities(provider, subject, user_id)`, `email_codes`,
`refresh_tokens(hash)`, `hosts(token_hash)`, `host_pairings`, `oauth_codes`.
Migrations live in `backend/migrations/` and are applied with
`backend/scripts/migrate.ts`.
