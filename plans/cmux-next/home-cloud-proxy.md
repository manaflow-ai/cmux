# cmux-next Home: the daemon proxy for cloud conversations (`cloud-conversations-v1`)

Status: contract, part 1 of gap G2, 2026-10-03 (branch feat-cmux-next-home-cloud-proxy). Binding:
OWNERSHIP-PRINCIPLES.md, home-messaging.md (sections 3, 4, 5, 12, 13, 16, 20), home.md sections 2
and 5, home-scale.md section A7 (branch feat-cmux-next-home-scale). Lawrence's rule of 2026-10-03:
the Swift app talks only to the Rust daemon; the daemon talks to the Durable Objects.

## 1. Roles

| Entity | Owner | The daemon's role |
| --- | --- | --- |
| Cloud conversation (head, participants, messages, reactions, cursors, invites) | `ConversationDO` | transport only: forwards ops with the client's idempotency key and `origin`, returns the owner's result and relays its events |
| Inbox entries | `UserDO` stream `inbox:<user>` | transport only, same as above |
| Cloud session lease (API origin, bearer token, expiry) | the trusted local client that signed in (the Mac app's `CloudAuth`) | holds the lease in memory only; never writes it to disk, logs it or returns it |
| Upstream sockets (one per subscribed conversation, one for the inbox) | the daemon | shared by every local client; resumed with `after_seq` after a drop |
| Mirror and intent log | the client (home.md section 3) | none in part 1; home-scale.md DECISION D2 may move them into the daemon |

The daemon never acknowledges an op itself, never derives ids, never retries a mutation on its own
and never queues: when the cloud is unreachable a command fails at once (OWNERSHIP-PRINCIPLES,
"nothing queues"). The local owner (`local-conversations-v1`) is unchanged; cloud conversations use
their own commands and events, so a client mirror of the local owner never sees a cloud id.

## 2. Credential

cmux-tui holds no cloud credential today: `cmux-cloud-cli` only dispatches to other binaries, and
`cmux coderouter` asks the app, which holds the Stack session in its Keychain store
(`CmuxNextCloud/Auth/CloudAuth.swift`). The backend (`backend/apps/api/src/auth.ts`) accepts a
Stack access token (principal kind `session`) or an install token. So part 1 adds no credential
store: the app leases its current Stack access token to the daemon with `cloud-session-set`, and
refreshes the lease when the daemon asks (`cloud-session-needed`). The lease lives in daemon memory
(zeroized on replace and drop) and ends with the daemon process.

DECISION (open): a daemon install of its own (install key plus `/v1/auth/challenge` and
`/v1/auth/token`) would let the daemon keep cloud sockets while the app is closed, but it needs a key
store and home-scale.md D3 (app-signed envelopes for app-only ops). Part 1 does not build it.

## 3. Framing and trust

Commands use the daemon's `{"id":N,"cmd":"…",…}` framing; replies are `{"id":N,"ok":true,"data":…}`
or `{"id":N,"ok":false,"error":"…","error_code":"…","reason":"…","retryable":bool}`. All fields are
snake_case. Every command requires a trusted local (Unix) connection (authority `local-admin`, like
`local-conversations-v1`). The capability is advertised in `identify.capabilities` only when the
daemon was built with the cloud transport. Commands that call the cloud run off the connection's
request loop, so a slow cloud call never delays other commands on that connection; replies can
therefore arrive out of order and are matched by `id`.

Types (shapes are home-core's, identical to home.md section 2 where they overlap):

```
ConversationId = "conv_<26 Crockford base32>" | "conv_dm_<26>"
ParticipantId  = "user_<id>" | "agent_<id>" | "addr_<26>"
Summary        = home-core Summary with owner "cloud" (kind, team?, created_by?, state?, settings?,
                 invites? without token_hash, retention_days?)
Message        = home.md section 2 Message
Change         = {kind:"message",message} | {kind:"message-updated",message}
               | {kind:"read-cursor",participant,seq} | {kind:"conversation",conversation:Summary}
               | {kind:"invite",conversation,invite}
InboxEntry     = home-core InboxEntry (conversation, rev, kind, title, last_seq, last_at, preview,
                 dm_peer?, removed, unread, mentions, counts_rev, pinned, pin_position?, muted,
                 muted_until?, archived, archived_seq, marked_unread)
```

## 4. Commands

| cmd | params | data |
| --- | --- | --- |
| `cloud-session-set` | `{api_base_url, access_token, expires_at, client_version?}` | `{state:"active", api_base_url, expires_at}` |
| `cloud-session-clear` | `{}` | `{state:"signed_out"}` |
| `cloud-session-status` | `{}` | `{state:"signed_out"\|"active"\|"expired", api_base_url?, expires_at?}` |
| `cloud-inbox-list` | `{limit?, include_archived?}` (limit 1-200, default 200) | `{entries:[InboxEntry], revision}` |
| `cloud-conversation-snapshot` | `{conversation, tail}` (tail 1-50) | `{conversation:Summary, messages:[Message], rev, seq}` |
| `cloud-conversation-history` | `{conversation, before_seq, limit}` (limit 1-200) | `{messages:[Message], has_more}` ascending seq, all `< before_seq` |
| `cloud-conversation-op` | `{conversation?, idempotency_key, origin?, op}` | `{value, rev?, seq?, change?, replayed, transaction, stream, sequence}` |
| `cloud-inbox-subscribe` | `{}` | `{state}` |
| `cloud-inbox-unsubscribe` | `{}` | `{}` |
| `cloud-conversation-subscribe` | `{conversation}` | `{conversation, state}` |
| `cloud-conversation-unsubscribe` | `{conversation}` | `{}` |

`cloud-session-set`: `api_base_url` is an origin (`https://host[:port]`, or `http://` with a
loopback host for development); no path, query, fragment or user info. `access_token` is 1-8192
visible ASCII characters. `expires_at` is the token expiry in Unix milliseconds. `client_version` is
the app's version (1-64 visible ASCII characters), forwarded as `x-cmux-client-version` so a team's
minimum-version policy judges the app, not the daemon. A new lease
replaces the old one; open upstream sockets reconnect with it and resume with `after_seq`.

`cloud-conversation-snapshot`: `rev` is the head's `rev`; `seq` is the owner's stream sequence (the
`after_seq` a resume uses). The owner returns at most its snapshot tail (50 messages); older pages
come from `cloud-conversation-history`.

`cloud-conversation-op`: one op vocabulary (home-messaging.md section 20). `op` is tagged by `kind`;
its other fields are the op's params, sent unchanged. `conversation` names the target and is
required for every kind except `dm.open` and `conversation.create`, which must not carry it.
`idempotency_key` is 1-256 characters and goes to the owner unchanged; a retry with the same key
returns the stored result with `replayed: true`. `origin` is `user|cli|mcp|script|remote`
(absent = `cli`) and goes to the owner unchanged.

| kind | fields | owner rules (home-messaging.md section 4.1) |
| --- | --- | --- |
| `dm.open` | `peer: ParticipantId \| {email} \| {phone}` | opens the existing DM with that peer first; an address peer is invited in the same request |
| `conversation.create` | `title?, participants:[Participant], first_message?` | creates a group; the Worker derives the id from the actor and the key |
| `participants.add` | `participant: Participant` | human reach rule (sections 4.1, 16); max 64 |
| `participants.remove` | `participant: ParticipantId` | self, conversation owner, chief owner |
| `message.send` | `client_msg_id, parts, reply_to?, thread_root?` | `idempotency_key` must equal `client_msg_id` |
| `message.edit` | `message_id, parts` | author only |
| `message.retract` | `message_id` | author only |
| `reaction.add` / `reaction.remove` | `message_id, part_index, reaction` | one per (author, part, kind) |
| `read_cursor.set` | `seq` | monotonic, `<= last_seq` |
| `title.set` | `title` | groups only |
| `invite.create` | `address:{email}\|{phone}, display_name, locale?, copy_variant?` | the Worker derives the invite id and secret |

Any other kind is refused by the daemon (`reason: "unsupported_op"`) without a network call.

The reply carries the owner's value verbatim in `value` and lifts `rev`, `seq` and `change` from it
when present, so a conversation op reads like a local `conversation-op` reply. `transaction` is the
cloud transaction id; the same id tags the events the op caused. `stream` and `sequence` are the
owner's `request-settled` barrier (sequence 0 when nothing changed). For `dm.open` and
`conversation.create`, `value.conversation` is the Summary; `value.invite` reports the implicit
invite of an address peer.

Subscriptions: one upstream socket per target, shared by all local clients; a client's interests end
with `…-unsubscribe` or when its connection closes. A conversation socket closes 60 s after its last
local subscriber leaves (home-scale.md A7). At most 64 conversation subscriptions per daemon
(`reason: "too_many_subscriptions"`). `state` is the current `cloud-subscription-state` value.

## 5. Events (after the normal `subscribe`, trusted local connections only)

```
{"event":"cloud-conversation-changed","conversation":id,"rev":N,"seq":S,"transaction":tx,"change":Change}
{"event":"cloud-conversation-resynced","conversation":id,"rev":N,"seq":S,"summary":Summary,"messages":[Message]}
{"event":"cloud-inbox-changed","seq":S,"transaction":tx,"entries":[InboxEntry]}
{"event":"cloud-inbox-reset","seq":S}
{"event":"cloud-subscription-state","scope":"inbox"|"conversation","conversation"?:id,
 "state":"connecting"|"live"|"disconnected"|"closed","reason"?:Reason}
{"event":"cloud-session-needed","reason":"missing"|"expiring"|"expired"|"unauthenticated","expires_at"?:ms}
```

- `cloud-conversation-changed` maps one owner event frame to the local `Change` shapes: a written
  `msg` row is `message` for `message.send` and `message-updated` otherwise; `read_cursor.set` is
  `read-cursor`; an invite delivery report is `invite`; every other op is `conversation` with the
  new Summary. `rev` is the head's `rev` after the op; `seq` is the stream sequence.
- `cloud-conversation-resynced` replaces the client's confirmed mirror (pending intents stay). It
  follows the first subscription, any resume the owner answers with a snapshot, and any gap the
  daemon detects (it then sends `snapshot.request` upstream). Events never arrive out of `seq` order
  and never twice.
- `cloud-inbox-changed` carries the inbox entries an event wrote; `cloud-inbox-reset` means the
  inbox stream resynced and the client lists again with `cloud-inbox-list`.
- `cloud-subscription-state`: `live` once the stream is subscribed; `disconnected` while the daemon
  reconnects (reason `signed_out`, `unauthenticated` or `unavailable`); `closed` when the owner
  refused the socket (reason `forbidden`, for example after removal) and the daemon stopped. While
  a target is not `live`, the client shows the disconnected state and refuses edits to it.
- `cloud-session-needed`: the app answers with `cloud-session-set`. `expiring` is sent once per
  lease 120 s before `expires_at`; `expired` and `unauthenticated` (the cloud refused the token) are
  sent when a command or a socket needs the token.

## 6. Errors

| `error_code` | `reason` | `retryable` | meaning |
| --- | --- | --- | --- |
| `cloud_conversation_rejected` | the owner's or Worker's reject code (`not_reachable`, `forbidden`, `not_participant`, `invalid_parts`, `idempotency_conflict`, `invalid_client_msg_id`, `unknown_conversation`, `chief_main_pending`, `validation.invalid`, `auth.forbidden`, `policy.denied`, ...), or the daemon's `unsupported_op`, `too_many_subscriptions` | the owner's flag (false for daemon reasons) | the op was decided and refused; the key is spent only when the owner recorded it |
| `cloud_signed_out` | `missing` | false | no lease; nothing was sent |
| `cloud_session_expired` | `expired` | true | the lease expired; nothing was sent; `cloud-session-needed` was emitted |
| `cloud_unauthenticated` | `unauthenticated` | true | the cloud answered 401; `cloud-session-needed` was emitted |
| `cloud_unavailable` | `unavailable` | true | transport failure, timeout, 5xx or a malformed reply; for a mutation the outcome is unknown, so retry with the same `idempotency_key` |

Parameter shape errors are plain `bad request: …` errors without `error_code`, as on the local owner.
A connection that is not a trusted local connection gets `cloud conversations require a trusted local
connection`.

## 7. Upstream mapping

| Daemon | Cloud (backend/apps/api) |
| --- | --- |
| `cloud-inbox-list` | `POST /v1/read {op:"inbox.list", params:{limit?, include_archived?}}` |
| `cloud-conversation-snapshot` | `POST /v1/read {op:"conversation.snapshot", params:{conversation, tail}}` (the snapshot frame becomes Summary + messages) |
| `cloud-conversation-history` | `POST /v1/read {op:"conversation.history", params:{conversation, before_seq, limit}}` |
| `cloud-conversation-op` | `POST /v1/ops {op:kind, params:{conversation?, ...fields}, idempotency_key, origin}` |
| `cloud-inbox-subscribe` | `GET /v1/wire/user`, subprotocols `cmux.wire.v1, bearer.<token>`; after `welcome`: `{t:"subscribe", stream:"inbox:<user>", after_seq?}` |
| `cloud-conversation-subscribe` | `GET /v1/wire/conv/<id>`, same subprotocols; after `welcome`: `{t:"subscribe", after_seq?}` |

Every HTTP call and handshake sends `authorization: Bearer <token>` (sockets: the subprotocol) and,
when the lease has one, `x-cmux-client-version`. HTTP 401 maps to
`cloud_unauthenticated`; a reply with `ok:false` or a 4xx body `{code, message}` maps to
`cloud_conversation_rejected`; everything else that is not a decoded reply maps to
`cloud_unavailable`. A WebSocket handshake 401 or close code 4401 asks for a new lease; 403 closes
the subscription; other drops reconnect with backoff (1 s doubling to 30 s, cancelled by
unsubscribe, a new lease or shutdown).

## 8. Not in part 1

Typing (`ConversationDO` has no typing frame yet), inbox user ops (`inbox.pin`, `inbox.mute`,
`inbox.archive`, `inbox.mark_unread`), `invite.revoke`, `invite.accept`, search (`home.search`), the
on-disk cache and offline read-only view (home-scale.md A7), the daemon-held mirror and intent log
(D2), app-signed envelopes (D3) and the Swift `HomeSource` (part 2).
