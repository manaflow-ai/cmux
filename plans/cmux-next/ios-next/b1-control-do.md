# B1 `control-do`: the control plane on Durable Objects

Status: landed (local) on `feat-cmux-next-ios-b1-control-do`, 2026-10-06. Plan: [PLAN.md](PLAN.md) B1.
Wire: [a0-rpc.md](a0-rpc.md) (`cmux.mobile/1`). Binding: OWNERSHIP-PRINCIPLES.md, transport.md section 6.

B1 adds no Durable Object class. It extends `HostDO` (control sockets next to the datagram relay),
`UserDO` (stream `ssh:<user>`), `TeamDO` (one admission RPC) and the `OwnerDO` gateway (`hello`,
`read`) that every owner shares. Notification fan-out stays where it is: `FeedDO` (feed items, APNs)
and `UserDO` (Home push); B1 only adds the streams the phone mirrors.

## 1. Who owns which stream

| Stream | Socket | Writer (single owner) | DO role | State |
| --- | --- | --- | --- | --- |
| `host:<host>` | `/v1/wire/host/<host>` | `HostDO` | owner | presence, viewers, attached devices, Mac caps |
| `workspace:<host>` | `/v1/wire/host/<host>` | the Mac workspace store | mirror + op forwarder | last Mac snapshot + event tail |
| `task:<host>` | `/v1/wire/host/<host>` | the Mac task runner | mirror + op forwarder | last Mac snapshot + event tail |
| `ssh:<user>` | `/v1/wire/user` | `UserDO` (secondary stream) | owner | synced SSH host records, known hosts; never a private key |
| `user:`, `inbox:`, `feed:` | existing | unchanged | | |

`host:` facts that only the Mac knows (`sleeping`, `paused`, caps) are written by the Mac through
`HostDO` ops; facts the socket layer knows (`online`/`offline`, attached devices) are written by
`HostDO` itself in the same stream. One writer per field, one sequence per stream.

The Mac is the owner of `workspace:` and `task:` (OWNERSHIP-PRINCIPLES "single writer"). `HostDO`
never runs a workspace reducer: it stores the Mac's latest snapshot and the events after it, keyed by
the Mac's own `seq`, and replays them. Clients see the Mac's sequence end to end.

## 2. Sockets and auth

`GET /v1/wire/host/<host>[?team=<team>]`, subprotocols `cmux.wire.v1, bearer.<token>` (as `/v1/wire/*`).

1. The Worker authenticates the bearer: an install access token, else a Stack session token
(fallback for a signed-in client without an install yet). VM installs are refused on every general
socket; the phase-2 cloud daemon is admitted only as the `host` of its own CloudDO-bound host id.
2. SSO and minimum-version policy (`ssoGate`, `versionRefusal`), then `withGrantClasses` (UserDO
   confirms the install is active).
3. `TeamDO.hostAccess(team, host, principal)` decides the role: `host` when the principal is the
   install that enrolled the host (session principals never), `device` when the user is a member of
   the host's team (a personal team has only its user, so this is "same account or same team").
   Anything else is 403. `team` defaults to the principal's team; another team named in `?team=`
   must also pass that team's SSO and minimum-version policy.
4. `HostDO` accepts the socket with the role and principal in the attachment, registers it with the
   user's `UserDO` socket registry (instant revocation closes it, code 4401) and closes it at token
   expiry (alarm), through the same `SocketGate` every owner uses.

The first frame must be `hello`. `HostDO` answers `hello.ok` (version 1, caps intersection, `max_frame`
131072) or `error proto.version_unsupported` and close 4002. Frames before `hello` get
`error proto.hello_required`. On the other owners `hello` is optional (cmux.wire/1 clients never send
it); when sent it is negotiated the same way. Server caps: owners `read`; `HostDO` `read`, `signal`,
`presence`, `resume`. `hello.resume[]` subscribes each listed stream with `after_seq`.

Admission is re-asked from TeamDO every 60 s on the socket's frames; a member who left the team or a
removed host loses the socket (close 4403). A listen-only socket is bounded by its token (access
tokens live 10 minutes). Close codes: 4000 replaced, 4002 version, 4401 revoked or `token expired`
(the client reconnects with a fresh token only for the latter), 4403 access lost.

One live socket per role and identity: a reconnect of the same install replaces the old socket (4000).
Limit: 32 device sockets per host (HTTP 429 on the upgrade when full).

## 3. Frames on the host socket

Device to `HostDO`:

| Frame | Handling |
| --- | --- |
| `subscribe {stream, after_seq?, pending?}` | `host:`/`workspace:`/`task:` of this host. Gap within the tail: replay events. Otherwise snapshot (+ mirror tail). With `pending[]` the mirror snapshot goes first and, when the Mac is online, the Mac follows with a snapshot carrying that device's decided keys. |
| `snapshot.request`, `unsubscribe` | as cmux.wire/1 |
| `op host.wake` | `HostDO`: `{presence}` when the Mac is online, else `reject host.not_wakeable` |
| `op workspace.*`, `op task.*` | forwarded to the Mac with `from` = device identity, `actor` and `origin: remote` (device ops never move the Mac's focus); Mac offline: `reject owner.unreachable` (retryable) + `request-settled ok:false`, nothing queues |
| `read task.list` | forwarded to the Mac under a fresh `HostDO` read id, mapped back to the device's id |
| `read signal.turn_credentials` | minted in the Worker isolate (section 6) |
| `presence.set {state {active, client}}` | the device's `active` flag in `host:` (viewers = active devices) |
| `signal` | relayed to the host (section 5) |

Mac (role `host`) to `HostDO`:

| Frame | Handling |
| --- | --- |
| `op host.presence.set` / `op host.caps.set` | committed to `host:` (Mac-known fields only) |
| `snapshot {stream: workspace:/task:, seq, state, decided, to?}` | `to` absent: replaces the stored snapshot, clears the tail, broadcasts when the seq is not the current head. `to` set: delivered to that device only (pending-key answer) and stored when newer. |
| `event {stream, seq, ...}` | accepted only when `seq == head + 1` and the op is in the stream's family; stored and broadcast. A gap drops it and sends the Mac `snapshot.request {stream}` |
| `result` / `reject` / `request-settled` with `to` | delivered to the pending device; `request-settled` ends the forward |
| `read.result` / `error` with `id` | mapped to the device's read id |
| `signal {to: <device install>}` | relayed to that device |

After the Mac connects, `HostDO` sends it `snapshot.request` for `workspace:` and `task:`. The Mac's
ledger keys idempotency by `(from, idempotency_key)`; a resend after reconnect (or over a `CmuxLink`
`rpc` channel) dedupes there. `HostDO` keeps forwards in SQLite (`host_fwd`, TTL 60 s, at most 64
per device), so a hibernated object still routes the Mac's answer. When the Mac socket closes, every
in-flight forward gets `error owner.unreachable` (retryable, outcome unknown: the client keeps the
intent and resends with the same key, OWNERSHIP-PRINCIPLES "Offline").

Epochs (B5): the Mac stamps workspace and task snapshots and events with `epoch`. `HostDO` stores it
with the snapshot and serves it; a Mac snapshot with another epoch replaces the mirror and drops the
tail even at a lower seq; an event of another epoch is a gap (`snapshot.request`); a `subscribe`
whose `epoch` differs from the stored one gets a snapshot, never a replay. The Swift client treats an
event of another epoch as a reset (cursor cleared, `snapshot.request`) and resubscribes with its
cursor's epoch. Schema ids accept both `h_…`/`in_…` and the backend's `host_<20>`/`inst_<20>`.

Mirror limits: snapshot at most 1 MiB; tail at most 512 events or 512 KiB, then `HostDO` asks the
Mac for a compacting snapshot; past 2048 events it drops new events (the next one is a gap and a
snapshot follows) instead of keeping a tail it cannot replay. `host:` keeps its last 256 events.

## 4. Presence

- Per host: `online` while the Mac's socket is open (`HostDO` writes it at accept and close), else
  `offline`; the Mac may set `sleeping` or `paused` while connected. `viewers` is the number of
  attached devices with `active: true`.
- Per device: `host.device.set {host, device {install, platform, app_version, active, since}}` at
  hello and on `presence.set`, `host.device.remove {host, install}` at socket close. Both are new
  `owner` messages in the catalog (`host` family), committed by `HostDO`.
- Every accept rebuilds presence from the sockets that are really open, so a close callback lost to
  a deploy or reset cannot leave `online` or a ghost device behind.
- Hibernation: presence lives in SQLite with the stream; sockets survive eviction (hibernation API,
  ping auto-response), and `webSocketClose` after eviction still writes `offline`/`device.remove`.

## 5. Signaling relay

`signal {kind: offer | answer | ice | ice.end | bye, session, to, body}` is relayed by `HostDO`, never
stored, never logged with its body.

- `from` is always overwritten with the sender's authenticated identity (install id; a session
  principal's identity); a client value is dropped (transport.md section 6 peer rewrite).
- Scope: a device may signal only the host (`to` = the host id or the host's install); the host may
  signal only a device attached to this `HostDO`. Device to device is refused (`auth.forbidden`).
  Admission is the socket's: same account or team (section 2).
- Validation: `session` matches `sess_…`, body per `families/signal.schema.json` (SDP at most 65536
  characters, candidate at most 1024), frame at most 131072 bytes.
- Peer not connected: `error signal.peer_offline` (retryable). Rate: 120 signal frames per 10 s per
  socket (token bucket, memory); over the limit `error signal.rate_limited`.

## 6. TURN credentials (for B2)

`POST /v1/realtime/turn {host?}` (bearer as `/v1/ops`) and `read signal.turn_credentials {host}` on
the host socket mint short-lived Cloudflare Realtime TURN credentials, one call per install:

- Calls `POST https://rtc.live.cloudflare.com/v1/turn/keys/<CLOUDFLARE_TURN_KEY_ID>/credentials/generate-ice-servers`
  with `Authorization: Bearer <CLOUDFLARE_TURN_KEY_API_TOKEN>` and `{ttl: 900}`; returns
  `{ice_servers [{urls, username?, credential?}], expires_at}` (schema `signal.turn_credentials:result`).
- Env (Worker secrets, never in wrangler.jsonc, never printed): `CLOUDFLARE_TURN_KEY_ID`,
  `CLOUDFLARE_TURN_KEY_API_TOKEN`. Absent: `503 {error {code: "signal.turn_unavailable"}}` (socket:
  `error signal.turn_unavailable`, retryable false). Upstream failure: `signal.turn_unavailable`
  retryable true. Set with `wrangler secret put <NAME> --env <env>` from stdin (backend-runbook.md).
- TURN mints are limited per authenticated identity by the `MOBILE_TURN_LIMIT` binding (six per
  60 seconds). The HTTP route answers `429` with `signal.rate_limited` and `retry-after: 60`; a
  socket read answers the same code in its `error`/`read` envelope. The HTTP and HostDO paths use
  the same key (`turn:<install>` for an install token, or `turn:<session identity>` for a session),
  so changing carriers cannot bypass the budget. A limiter failure fails closed before provider I/O.

## 7. Remote config (for C16)

`GET /v1/mobile/config` (bearer) returns `{version, flags {<name>: bool|number|string}, min_app_version?}`.
Source: the Worker var `MOBILE_REMOTE_CONFIG` (JSON, same shape) over built-in defaults; unknown
value types are dropped. Read once per app foreground; no polling.

## 8. `ssh:<user>` (C9)

`UserDO` secondary stream (as `inbox:`), ops `ssh.host.upsert {host}`, `ssh.host.remove {id}`,
`ssh.known_host.add {id, key_type, key, fingerprint}`. Only the user (session or an active install,
not a VM, not a chief) subscribes and writes. Records hold hostname, port, user, jump host and the
public key fingerprint; a field named like a secret (`private_key`, `password`, `passphrase`) is
refused. At most 500 hosts, 16 known keys per host.

## 9. Tests (backend/apps/api/test)

`host-control.test.ts` (hello negotiation and 4002, auth refusal, role admission, op forwarding with
idempotency and offline reject, read mapping, mirror gap/resync and resume, presence, hibernation
restore), `host-signal.test.ts` (relay, `from` rewrite, scoping, rate limit), `ssh-stream.test.ts`,
`realtime-turn.test.ts`, `mobile-config.test.ts`, `owner-hello.test.ts`.

## 10. Swift client (`Packages/Shared/CmuxControlPlane`)

`ControlPlaneClient` (actor) over `CmuxMobileWire` frames, one per socket (`/v1/wire/user`,
`/v1/wire/host/<host>`): `start()`/`stop()`, `states` (`connecting`, `connected(HelloOKFrame)`,
`disconnected`, `failed`), `subscribe(stream) -> AsyncStream<StreamUpdate>` (snapshot, then only
contiguous events; a gap sends `snapshot.request` and waits), `cursor(of:)`, `submit(OpFrame) ->
OpOutcome` (undecided ops are resent with the same key after a reconnect; resubscribe then carries
`pending` so the snapshot settles them), `read(op, params, stream)`, `sendSignal` (never sends
`from`), `signals` (`AsyncStream<SignalFrame>`), `setPresence(active:)`. Reconnect backoff runs
through an injected sleep (`ReconnectPolicy`); close codes 4002 and 4401 are terminal. Nothing
queues while disconnected. Transport seam `ControlPlaneTransport` (URLSession in production, an
in-memory server in the Swift Testing suite).

## 11. Open

- Session principals with a Stack `refresh_token_id` now receive a deterministic, server-scoped
  digest identity (`session:<user>:<digest>`); two signed-in clients therefore keep separate socket
  tags and idempotency ledgers without exposing the raw Stack session id to owners. Tokens without
  that claim retain the legacy per-user identity and still replace one another.
- `HostDO`'s own `host:` ops (Mac presence and caps, `host.wake`) have no idempotency ledger; they
  are last-writer state, so a replay reapplies the same value. A ledger lands if they gain effects.
- Pending-key snapshot forwards are limited per authenticated identity by the `MOBILE_PENDING_LIMIT`
  binding (120 per 60 seconds). When the budget is exhausted HostDO sends a retryable
  `signal.rate_limited` error to the device and still serves its local mirror snapshot; it does not
  forward that request to the Mac. Limiter failures fail closed for the owner forward.
- Socket `read` on owners calls the owner's `read` directly; HTTP `/v1/read` also checks catalog
  principal kinds. No read leaks today; the two paths should share admission.

- The datagram relay will pick its object name per host (`host:<id>:<n>`, transport.md section 6);
  control sockets use `idFromName(<host id>)` today. The persisted `host_ctl` row now treats the
  enrolled install as immutable, so a warm object cannot silently accept a different placement;
  when sharded placement lands, TeamDO must record the chosen name and both planes use it.
- `host.list` (TeamDO read) is not served over a socket yet; the phone lists hosts with
  `team.directory` or B6's `pairing.hosts`.
- B6 may narrow device admission from "team member" to "paired device" (trust store in `UserDO`);
  `hostAccess` is the one place to change.
