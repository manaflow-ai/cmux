# Direct messages and group chats: hosted (Durable Objects) and self-hosted (Tailscale)

Status: design, 2026-10-20. Owner: the "DMs and group chats" lane. Extends
[home-messaging.md](home-messaging.md) (the hosted backend) and
[remote-hosts.md](remote-hosts.md) (tailnet admission). Section 11 of home-messaging.md
("self-hosted over WireGuard, Postgres") is replaced by section 4 of this file.

Request (Lawrence, 2026-10-20): DMs and group chats must work on iOS and macOS. They run on
Durable Objects. People can also self-host the server on their own Mac mini or Linux server.
The self-hosted transport is Tailscale only.

## 1. Audit (feat-cmux-next at 1db7859295a)

### 1.1 Hosted backend (backend/apps/api, backend/packages/home-core)

| Requirement | State | Where |
| --- | --- | --- |
| One DO per conversation | yes: `ConversationDO`, `idFromName(conv id)`; DM id is deterministic from the two members | `conversation-do.ts:75`, `home-core/src/conversation/ids.ts` |
| Ordered durable log | yes: message rows in DO SQLite (row mode), dense `seq` per conversation, one transaction for state + ledger + events + outbox, commit before publish | `owner-do.ts`, `ownership/src/engine.ts`, `home-core/.../apply.ts` |
| Idempotent sends | yes: ledger keyed by (identity, idempotency key) with a params hash; `message.send` needs `client_msg_id == idempotency_key`; 7 day window | `engine.ts:227`, `apply.ts:79` |
| WebSocket fan-out | yes: `/v1/wire/conv/<id>` per conversation, `/v1/wire/user` for the inbox stream; resume with `after_seq` (gap <= 1000 replays, else snapshot) | `owner-do.ts:410-483` |
| Hibernation | yes: `ctx.acceptWebSocket` + `serializeAttachment`; typing memo in memory only (by design) | `owner-do.ts:420` |
| Inbox, unread, mentions | yes: outbox `inbox.bump` to each member's `UserDO` (coalesced, `rev`-guarded) | `home-core/.../fanout.ts`, `user-inbox.ts` |
| Chief in a conversation | yes: outbox `mux.wake` to `MuxDO`; brains post with an agent token | `mux-do.ts` |
| Replies, threads, tapbacks, edits, retracts, read cursors, typing | yes | `ops-home-conversation.ts` |
| Media | yes: R2 slots, verified upload, derived poster/preview | `home-attachments*.ts` |
| Push | yes: APNs from `UserDO` | `home-push*.ts` |
| Tests | 400 home-core + 22 DM/group Workers-pool tests green locally (one red test fixed: missing `cleanAttachmentPart` export) | `backend/apps/api/test/home-*.test.ts` |

Defects found:
- H-1 `conversation.history` sets `has_more = rows.length === limit`: a page that is exactly full
  says "more" when there is none, so a client asks for one more empty page. Fix: read
  `limit + 1` rows.
- H-2 (`home-core` test) `cleanAttachmentPart` was not exported from the conversation index (red test).

### 1.2 macOS (cmux NEXT)

The app talks to the hosted Worker only through the session daemon (`cmux-tui`,
`cmux-tui-cloud-conversations`), which holds the Stack token (`cloud-session-set`).

| Feature | State |
| --- | --- |
| DM human-human, group create/add/remove/rename, invites | works (`CloudHomeSource+Ops.swift`) |
| Human-Chief | works through the local daemon owner (`DaemonHomeSource`) |
| Send idempotency, optimistic intents, offline queue, resend with the same key | works (`IntentLog`, `HomeStore+OfflineSends`) |
| Receive, reconnect (1-30 s backoff), catch-up by `after_seq`, gap repair | works (daemon `stream.rs`) |
| Replies, threads, tapbacks, edit, retract, read cursor, typing, unread, mentions | works |
| Media on cloud conversations | broken: `CloudHomeSource` has no upload/fetch, so the "attachments unsupported" refusal applies although the daemon advertises `cloud-attachments-v1` |
| Pin, mute on cloud conversations | refused as `unsupported_op` in Swift; the daemon supports them |
| Search on cloud conversations | always empty |
| Server choice | none: the origin is fixed per build (`CloudConfiguration.ownerAPIBaseURL`); the daemon allowlists origins (`CMUX_CLOUD_API_ORIGINS`) |

### 1.3 iOS

| App | State |
| --- | --- |
| `ios/` (CmuxiOS, cmux-next iOS) | the Home UI is complete (tapbacks, new group, invite, search), but `AppContainer.swift:129` uses `MockHomeSource()`: no DM or group reaches a server |
| `cmux-next-ios` (CmuxMobileKit) | human-Chief conversation only (`ChiefCloudBackend.swift`); no `dm.open` or `conversation.create` |

So on iOS today, DMs and group chats do not work at all.

## 2. Principles

1. One protocol. Hosted and self-hosted speak the same `cmux.wire/1`: `POST /v1/ops`,
   `POST /v1/read`, `GET /v1/wire/conv/<id>`, `GET /v1/wire/user`, the same frames and op names.
   A client has one implementation with a base URL and an auth mode.
2. One owner implementation. The self-hosted server runs the same TypeScript classes as the
   cloud (`ConversationDO`, `UserDO`, `MuxDO`, `AddressDO`, `OwnerDO`, `OwnerEngine`, home-core).
   No second reducer, no second ledger. The conformance corpus stays the contract.
3. Identity from the network for self-host. Tailscale identity (WhoIs on the peer address) is
   the credential. No bearer token, no password, no pairing secret.
4. No public port. The self-hosted server listens only on the host's tailnet addresses (and
   loopback for the local client). There is no flag for a public listener.

## 3. Hosted: what changes

The hosted design already meets the request (section 1.1). Work:
- Fix H-1 and H-2 with tests (red first).
- Small refactor with no behavior change: `OwnerDO.fetch` moves its socket accept into a
  protected `acceptSubscriber(server, entity, principal)` so the self-host runtime can admit a
  socket into the same code path (section 4.3). The Workers path calls the same method.
- Deploy: a push to feat-cmux-next deploys development and staging (backend.yml). Then the
  staging e2e (`bun run e2e:staging`) and the DM/group smoke; then production with
  `backend/scripts/deploy-worker.sh production` (`CMUX_NEXT_DEPLOY_PRODUCTION=1`).

## 4. Self-hosted server

### 4.1 Shape

`cmux-chat-server`: one executable (`bun build --compile`, macOS arm64/x64, Linux x64/arm64),
source in `backend/apps/home-server`. It contains:
- a small Durable Object runtime (`do-runtime/`): `DurableObjectState` (`storage.sql`,
  `transactionSync`, `getAlarm/setAlarm`, `blockConcurrencyWhile`, `waitUntil`,
  `acceptWebSocket`, `getWebSockets`), namespaces (`idFromName`, `get`), and RPC stubs that copy
  arguments and results (structured clone, as Workers RPC does). The module
  `cloudflare:workers` resolves to this runtime at build time.
- the real owner classes imported from `backend/apps/api/src`.
- a router that implements the chat subset of the Worker: `/v1/ops`, `/v1/read`,
  `/v1/wire/conv/<id>`, `/v1/wire/user`, `/v1/home/attachments/*`, `/healthz`,
  `/v1/selfhost/info`. Other routes answer `404 not_on_selfhost`.

Why not workerd: workerd is one binary too and runs the classes natively, but it cannot do
WhoIs itself (no Tailscale LocalAPI access, no subprocess), so it would need a second front
process, and R2 and rate-limit bindings would need a Miniflare layer. Bun gives one process
with SQLite (`bun:sqlite`), WhoIs and a socket listener. Risk: the shim must match DO
semantics; the conformance tests and the same DM/group e2e scenarios as the Workers tests run
against it (section 6).

### 4.2 Storage

- One SQLite file per object: `<data>/do/<class>/<sha256(name)[0..32]>.sqlite` (WAL,
  `synchronous=FULL`). An object is single-threaded: calls into one object are serialized by
  a per-object queue (the DO input gate).
- Alarms: the time is stored in the object's file (`_do_alarm`), armed with one timer per
  object, and re-armed at start for every object that has one (so a restart does not lose a
  sweep or an outbox drain).
- Attachments: files under `<data>/blobs/` behind the same R2 subset the code uses
  (`put`, `get`, `head`, `delete`, `list` by prefix).
- Projections (PlanetScale) do not exist on a server: `PROJECTION_PRIMARY=none` marks
  projection rows sent. Search on a self-hosted server: not in v1 (the client shows local
  search only).
- Data dir: macOS `~/Library/Application Support/cmux/chat-server`, Linux
  `$XDG_STATE_HOME/cmux/chat-server`; `--data DIR` overrides.

### 4.3 Transport and identity (Tailscale)

- Listen: every tailnet address of the host (from `tailscale ip`) on port 7320 (`--port`),
  plus `127.0.0.1`. HTTP/1.1 and WebSocket, plain HTTP: WireGuard already encrypts and
  authenticates the tailnet path, and the server never binds a non-tailnet address.
- Clients reach it by MagicDNS name: `http://<host>.<tailnet>.ts.net:7320` (or the 100.x
  address).
- Admission per connection (same rule as remote-hosts.md section 6): WhoIs on the peer
  address (`tailscale whois --json <ip:port>`, cached per node for 60 s). Refuse tagged nodes
  and peers whose address is one of the host's own addresses unless the request is on
  loopback from the same user. Admit the owner login and logins in the allow list
  (`cmux-chat-server allow <login>`). Loopback is admitted as the owner.
- Principal: `{kind: "session", user: "user_ts_<base32(sha256(lower(login)))[0..20]>",
  identity: "session:<user>", email: <login>, email_verified: true, display_name: <WhoIs name>}`.
  The user id is stable for a login on every server, so a DM between two logins has the same
  id everywhere. Members on one server share it as their "team" for reach rules
  (`team_ts_<server id>`), so admitted people can DM and group each other.
- Not on a server in v1: push (needs cmux's APNs key; later `push.relay` from home-messaging.md
  section 11), email/SMS invites (the address flow refuses with `invites_not_on_selfhost`),
  cloud Chief brains (a local Chief joins through the daemon's local brain path).

### 4.4 Lifecycle CLI

```
cmux-chat-server serve [--data DIR] [--port 7320]       # foreground (what the service runs)
cmux-chat-server enable [--owner LOGIN]                 # write config, install launchd/systemd user unit
cmux-chat-server disable
cmux-chat-server status [--json]                        # addresses, URL, owner, allow list, objects
cmux-chat-server allow LOGIN | deny LOGIN
```

`enable` refuses when `tailscale status` is not running or the node is tagged and no
`--owner` is given.

### 4.5 Client setting

One setting, `home.server` in `~/.config/cmux/cmux.json` and Settings > Home:
- `"hosted"` (default): the cmux cloud for the build (`cloud-api.cmux.dev`, staging for
  non-release builds), Stack sign-in.
- `{"selfHosted": "http://mini.tail1234.ts.net:7320"}`: the self-hosted server. The client sends
  no bearer; the server identifies it by Tailscale.

macOS: the app passes the base URL to the daemon (`cloud-session-set` with
`auth: "tailscale"` and no token). The daemon allowlists a self-hosted origin only when it is
a MagicDNS `*.ts.net` name or a `100.64.0.0/10` / `fd7a:115c:a1e0::/48` address, over http
or https.

iOS: a direct `cmux.wire/1` source in `CmuxHomeCore` (`WireHomeSource`: URLSession HTTP +
WebSocket, the same intent log and mirror) replaces `MockHomeSource` for both hosted (Stack
bearer) and self-hosted (no bearer; the Tailscale iOS app must be on). The Settings screen
has the same choice.

## 5. Plan (each step: failing test first, then the fix)

1. Hosted fixes H-1, H-2 and the `acceptSubscriber` seam.
2. `backend/apps/home-server`: DO runtime + router + Tailscale admission, with tests: DM and
   group e2e (create, send, receive on a second socket, reply, tapback, read cursor, unread in
   the inbox, typing, attachment upload/download, idempotent resend, reconnect with
   `after_seq`, restart with data kept, refusal of an unknown login and of a tagged node).
3. macOS: `home.server` setting, daemon origin rule, lease without a token for self-hosted.
4. iOS: `WireHomeSource` in CmuxHomeCore + Settings choice; replace the mock.
5. macOS cloud attachments (`upload`/`fetch` through the daemon's `cloud-attachments-v1`).
6. Deploy hosted to staging, run the staging DM/group e2e, then production.
7. Self-hosted on the real tailnet Mac mini (`cmux-lawrences-mac-mini`): install the binary,
   `enable`, then two logins (Mac + iPhone) DM and group through it.

## 6. Verification

- Unit/e2e: `backend/apps/api` Workers-pool tests (hosted), `backend/apps/home-server` bun
  tests (self-hosted, same scenarios), home-core conformance on both.
- Builds on the Mac mini fleet (`cmux-ci build cmux --ref SHA`), never heavy local builds.
- Staging then production for the hosted Worker.
- Real tailnet run on the Mac mini, with the result recorded in section 7.

## 7. Verification record

- 2026-10-20, hosted: H-1 red test `home-history-page.test.ts` (0da3acea717), fix 9c1e9d32091.
  Hosted Workers-pool tests after the `acceptSubscriber` seam and `PROJECTION_PRIMARY=none`:
  26 files, 165 tests green (`test/home-*`, `test/socket*`, `test/wire-ticket*`, `test/projection*`).
- 2026-10-21, staging: backend run 39553887817 green (test, deploy-staging, promote-gates) at
  a4f9d6162af. Smoke against `cmux-api-staging` (Stack dev account): group create, conversation
  socket welcome and live events, resend replayed, `has_more` false on an exactly full page and true
  with older messages, tapback, read cursor, leave. Production: promote-gates stopped at G6, the
  hold switch `CMUX_NEXT_PRODUCTION_HOLD` ("Lawrence's go on the first deploy clears it"); not bypassed.
- 2026-10-21, self-hosted attachments (4d1c3227c53): upload in a DM, the other member downloads the
  same bytes, a non-member cannot mint a URL.
- 2026-10-20, self-hosted server landed in a3d5d15c81b (`backend/apps/home-server`):
  `bun test` 9/9 (DM, group, resend replay, reply, tapback, read cursor, unread, typing, resume
  with `after_seq`, restart keeps data, alarm survives restart, admission refusals).
- 2026-10-20, real tailnet (tail137216): binary built on macOS arm64 (64 MB), run on `cmux21`
  (untagged node, owner `leoli.4u@gmail.com` via loopback) with `lawrence@manaflow.ai` allowed
  and reaching it from a MacBook over MagicDNS `cmux21.tail137216.ts.net:7320`:
  - both logins admitted by WhoIs/loopback; both `dm.open` give the same `conv_dm_…`;
  - a message from cmux21 reached the MacBook's conversation socket as an event (171 ms
    including an SSH hop); a resend with the same key replayed;
  - reply, tapback, group create and send; the other person's inbox showed both rows with
    `unread: 1` and previews;
  - `deny` gave 403 at once; restart kept history; the LAN address (172.20.21.252:7320) does
    not answer (only 127.0.0.1 and the tailnet addresses listen).
  - Not possible: the controller Mac mini (`cmux-lawrences-mac-mini`) is a tagged node and the
    tailnet ACL does not let other nodes reach it on 7320, so the two-person test ran on `cmux21`.
    The ACL was not changed. On the mini, the binary served the owner (lawrence) over the tailnet.
