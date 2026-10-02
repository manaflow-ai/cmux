# cmux-next Home messaging backend: conversations, inbox, chiefs, search, invites

Status: proposal, revision 2, 2026-10-02 (lane 15, Home messaging backend). Revision 2 applies decisions
D-H1..D-H8, the engine answers E1-E6 (PR 16827) and adds section 16 (relationships, membership,
roles) and section 15 (invite copy). Spec proposal:
home-messaging. Binding: OWNERSHIP-PRINCIPLES.md, spec `home-and-agents.md`, `backend.md`,
`identity-and-permissions.md`, decisions IOS2, IOS4, B10, N10-N13, SV1-SV3. Local-only
conversations stay as designed in `home.md` (crate `cmux-conversation`, capability
`local-conversations-v1`); this file adds the cloud owners, the self-hosted owner, search and
invites, and keeps one op vocabulary for all three. Items marked OPEN need a decision.

Shape agreed with the backend lead (2026-10-02): `backend/{apps/api, apps/dashboard,
packages/ownership, packages/protocol, packages/home-core}`; `home-core` holds pure reducers run by
a Cloudflare adapter (DO SQLite) and a self-hosted adapter; Postgres (PlanetScale `cmux-next`)
holds projections only; invites are typed ops and email/SMS goes out after commit; migrations go
through the label flow (staging, then production).

## 1. Words

- Chief: a user's orchestrator agent (agent class `mux`, D20). "Chief" is the product word (IOS4);
  wire and code keep `agent` with `agent_class: "mux"`. A subchief is a chief whose `parent` is
  another chief of the same owner; there is no other difference (IOS2).
- Conversation: one thread. Kinds: `chief` (owner + one chief, pinned at the top of Home), `dm`
  (exactly two humans), `group` (humans and chiefs, 2 to 64 participants).
- Address: an email address or phone number that is not (yet) linked to a cmux user. An address can
  be invited; it cannot act. (Product word "Contacts" means relationships, section 16.)

## 2. Entities and fields

Ids are owner-assigned and never reused. `<26>` = 26 Crockford base32 characters (ULID layout
from `cmux-conversation::encode_id` unless stated).

| Entity | Id | Fields |
| --- | --- | --- |
| Conversation head | `conv_<26>` (group, chief); `conv_dm_<26>` = base32(sha256("dm\0" + lo + "\0" + hi))[0..26] where lo/hi are the two sorted participant ids (a user id or an address id) | `kind`, `title`, `team?` (the team whose policy applies; null for personal), `created_by`, `created_at`, `updated_at`, `last_seq`, `rev`, `participants[]`, `invites[]`, `settings {wake_policy, agent_budget {turns, gap_ms}, history_visible: "all"|"since_join"}`, `retention_days?` (from team policy), `state: "active"|"archived"` |
| Participant | `user_<id>`, `agent_<id>`, `addr_<26>` | `kind: human|agent|address`, `display_name`, `agent_class?: mux|agent`, `owner_user?` (agents), `role: owner|member`, `joined_seq` (last_seq when added), `added_by`, `left_at?` |
| Message | `msg_<26>`, `seq` dense per conversation | `client_msg_id`, `author`, `parts[]` (text with runs/mentions, `work`, `approval`, `attachment {hash, mime, size, name}`, refs `task`/`vm`/`pr`), `reply_to? {message_id, part_index}`, `thread_root?`, `created_at`, `edited_at?`, `retracted_at?`, `reactions[] {author, part_index, kind, at}` |
| Read cursor | (conversation, participant) | `last_read_seq` (monotonic, written only by that participant) |
| Invite | `inv_<26>` inside its conversation | `address` (`addr_<26>`), `channel: email|sms`, `display_name`, `invited_by`, `created_at`, `expires_at` (14 days), `token_hash` (sha256 of sha256 of the 128-bit secret), `status: pending|accepted|revoked|expired`, `accepted_by?`, `accepted_at?`, `delivery {state: queued|sent|delivered|bounced|complained|failed|suppressed|refused_env, provider_id?, at}`, `copy_variant`, `locale` |
| Inbox entry | (user, conversation) | owner-projected (from ConversationDO, guarded by conversation `rev`): `kind`, `title`, `last_seq`, `last_at`, `preview` (240 chars, author + text), `unread` (count after the user's cursor, excluding own messages), `mentions` (unread mentions of the user), `dm_peer?`, `rev`; user-owned: `pinned`, `pin_position`, `muted_until?`, `archived`, `marked_unread` |
| Chief record | `agent_<26>` | `owner_user`, `team?`, `name`, `avatar?`, `parent?` (subchief), `brain: local|cloud`, `brain_host?` (host id for local), `thread` (its `chief` conversation), `reachability: owner|team|shared` (who may DM it), `grant` (grant id, identity spec 4), `archived_at?` |
| Address | `addr_<26>` = base32(HMAC-SHA256(`HOME_ADDRESS_KEY`, normalized address))[0..26] | `channel`, `address` (normalized: lowercase email with IDNA host; E.164 phone), `linked_user?`, `suppression? {reason: opted_out|bounced|complained|reported|admin, at}`, rate windows (section 9), delivery ledger |

Normalization: email = trim, lowercase, no plus-stripping (a different mailbox for some
providers). Phone = E.164 with the inviter's region as default; US and Canada only at launch (D-H5),
toll-free and premium area codes refused.

## 3. Owners

| Entity | Owner | Stream | Notes |
| --- | --- | --- | --- |
| Conversation head, participants, messages, reactions, edits, retractions, read cursors, invites | `ConversationDO`, one per conversation (`idFromName(conversation id)`) | `conv:<id>` | single writer; same reducer rules as `cmux-conversation`; message rows in DO SQLite tables, not in the JSON state blob (section 12, engine need E1) |
| Inbox entries, pins, mutes, archive, unread totals, push queue | `UserDO` of that user | `inbox:<user>` (a second stream in the same object, E2) | conversation-owned fields are a projection guarded by `rev`; user-owned fields are written only by the user |
| Chief records and their grants (personal) | `UserDO` | `user:<user>` | identity spec 2 and 4; team chiefs in `TeamDO` later |
| Chief wake queue and cloud brain loop | `MuxDO`, one per chief | `mux:<agent>` | every chief has one; a local brain host subscribes to it over the gateway instead of the cloud loop running |
| Team membership, who may message whom inside a team, team Home policy | `TeamDO` | `team:<team>` | existing directory; adds `home.*` policy keys (section 10) |
| Address state: address, suppression, per-recipient limits, delivery ledger | `AddressDO`, one per address | `address:<id>` (no client subscribers) | holds the only copy of the raw address; external sends happen here, after the invite commit |
| Search index, conversation index, invite index | PlanetScale `cmux-next` | projection | written only by outbox drains (backend lead's `projection.ts` pattern) |
| Typing indicators | `ConversationDO` memory | broadcast only | never stored |
| Open conversation, scroll, draft, Home selection | client | never synced | OWNERSHIP-PRINCIPLES |

## 4. Ops

Wire conventions are backend.md's: `{op, params, idempotency_key, origin}` in, `{value, revision,
transaction, replayed}` or `{code, message, retryable}` out, `request-settled` last. "Key" says how
the idempotency key is chosen. "Callers": `session` (signed-in human on any client), `install`
(an install token of that user), `chief` (an agent token whose class is `mux`), `system` (built
inside a DO only), `link` (an unauthenticated holder of an invite secret, read only).

### 4.1 ConversationDO

| Op | Params | Key | Callers | Rules |
| --- | --- | --- | --- | --- |
| `conversation.create` | `{kind: group|chief, title?, participants[], first_message?}` | client key; the Worker derives the id `conv_` + base32(sha256(user + key))[0..26], so a retry reaches the same object | session, install, chief (group only) | creator becomes `owner`; participants must pass the add rule below; `chief` kind is created only by `chief.create` (system) |
| `dm.open` | `{peer: user_id | {email}|{phone}}` | client key; id is deterministic (section 2) | session, install | idempotent by id; a typed address resolves to a related user's profile only (section 16); otherwise it becomes an address plus an implicit `invite.create`, the same answer whether or not the address has an account |
| `message.send` | `{client_msg_id, parts, reply_to?, thread_root?}` | must equal `client_msg_id` | participants (human, chief) | `cmux-conversation` rules; agent turn budget; addresses cannot send |
| `message.edit` / `message.retract` | `{message_id, parts}` / `{message_id}` | client key | author | not after retraction; retraction clears parts and reactions and removes the search row |
| `reaction.add` / `reaction.remove` | `{message_id, part_index, reaction}` | client key | participants | one per (author, part, kind) |
| `read_cursor.set` | `{seq}` | client key (`read:<seq>` recommended) | humans | monotonic, `<= last_seq` |
| `title.set` | `{title}` | client key | members (group) | not for `dm`, `chief` |
| `participants.add` | `{participant: user or chief}` | client key | members | a human may be added only when they share a team with the adder or already share a conversation with them; anyone else needs `invite.create`. A chief may be added by its owner, or by anyone when its `reachability` allows. Max 64 |
| `participants.remove` | `{participant}` | client key | self (leave), conversation owner, chief owner (for their chief) | removing the last human archives the conversation |
| `invite.create` | `{invite_id, address, channel, display_name, locale, copy_variant}` | `invite_id` (the Worker derives it from the client key) | members | Worker first runs `address.ensure` and `invite.quota.take`; commit emits outbox `address.deliver` (send happens after commit); max 20 pending invites per conversation |
| `invite.revoke` | `{invite_id}` | client key | inviter, conversation owner | pending only |
| `invite.accept` | `{secret}` | client key | session (any signed-in user) | finds the invite by `token_hash`; pending and not expired; replaces the address participant with the user in one commit, records `accepted_by`. D-H4: `dm` invites admit any holder of the link once; `group` email invites need the principal's verified email to equal the invited address, otherwise the join waits as `pending_approval` |
| `invite.approve_join` | `{invite_id, approve}` | client key | inviter, conversation owner | decides a `pending_approval` join |
| `invite.preview` (read) | `{secret}` | n/a | link | inviter name, conversation kind, first message preview (trusted inviters only, section 9); rate limited per conversation and IP |
| `invite.delivery.report` | `{invite_id, delivery}` | `delivery:<invite>:<state>` | system (AddressDO) | delivery state only moves forward |
| `conversation.settings.set` | `{wake_policy?, agent_budget?, history_visible?}` | client key | conversation owner | |
| `conversation.snapshot` / `conversation.history` (read) | `{tail}` / `{before_seq, limit}` | n/a | participants | `history_visible: since_join` hides seq < `joined_seq` |

### 4.2 UserDO (stream `inbox:<user>` and `user:<user>`)

| Op | Params | Key | Callers | Rules |
| --- | --- | --- | --- | --- |
| `inbox.bump` | `{conversation, rev, kind, title, last_seq, last_at, preview, unread, mentions, dm_peer?, removed?}` | `bump:<conversation>:<rev>` | system (ConversationDO outbox) | applies only when `rev` is newer (max merge, so duplicates and reordering are harmless) |
| `inbox.pin` | `{conversation, pinned, position?}` | client key | session, install | user-owned |
| `inbox.mute` | `{conversation, until?}` | client key | session, install | approvals still notify (spec) |
| `inbox.archive` | `{conversation, archived}` | client key | session, install | a new message un-archives (bump rule) |
| `inbox.mark_unread` | `{conversation, unread}` | client key | session, install | flag only; the read cursor stays |
| `inbox.list` (read) | `{after_rev?, limit}` | n/a | session, install | pinned first, then `last_at` desc |
| `chief.create` | `{name, parent?, avatar?, brain}` | client key | session | creates the agent principal, its grant (class `mux`), its `MuxDO` and its `chief` conversation (outbox, system ops with derived keys); the first chief is pinned |
| `chief.update` / `chief.archive` | `{agent, ...}` | client key | session (owner) | archive keeps history read-only |
| `invite.quota.take` | `{invite_id, channel}` | `quota:<invite_id>` | system (Worker on the inviter's behalf) | per-user windows (section 9); a refused take refuses the invite |
| `home.settings.set` | `{discoverable_by_email?, discoverable_by_phone?, allow_dm_from: anyone|teams|contacts}` | client key | session | |

### 4.3 MuxDO, TeamDO, AddressDO

| Op | Owner | Callers | Notes |
| --- | --- | --- | --- |
| `mux.wake` `{conversation, seq, reason: dm|mention|reply|owner}` | MuxDO | system (ConversationDO outbox, key `wake:<conv>:<seq>`) | queues an inbox item; the cloud brain consumes it, or a subscribed local brain host acks it |
| `mux.ack` `{conversation, seq}` | MuxDO | chief (its brain host) | moves the chief's catch-up cursor |
| `mux.configure` `{brain, brain_host?}` | MuxDO | session (owner) | |
| `team.policy` keys `home.external_invites`, `home.retention_days`, `home.max_group` | TeamDO | team admin | via the enterprise lead's TeamPolicy (#16774) |
| `address.ensure` `{address}` | AddressDO | system (Worker) | stores the normalized address; returns `{id, linked_user?, suppressed}` |
| `address.deliver` `{invite, conversation, channel, rendered}` | AddressDO | system (ConversationDO outbox) | external effect with its own ledger (ConnectionDO pattern: `mutation.indeterminate` when the provider call's outcome is unknown); checks suppression, per-recipient windows and the environment send policy before the provider call |
| `address.suppress` `{reason}` | AddressDO | system (provider webhooks, unsubscribe link) | |
| `address.unsuppress` | AddressDO | session whose Stack-verified email is this address; never an admin block | |

## 5. Flows

Send in a group (N humans, K chiefs):
1. Client sends `message.send` on the conversation socket (or `POST /v1/ops`); the mirror shows a
   pending intent keyed by `client_msg_id`.
2. ConversationDO commits message + ledger + event + outbox in one transaction, then publishes
   the event, the result and `request-settled`.
3. The outbox holds: one `inbox.bump` per human participant (coalesced: one per user per drain,
   latest `rev` wins), one `mux.wake` per chief that should wake (wake rules in home.md section 5),
   one `search.upsert` row, and nothing else. Push is decided by each UserDO from the bump (not
   muted, not the author, an install with a push token, no foreground socket).
4. Drains: DO-to-DO items go by RPC with the item key (at-least-once, idempotent at the target);
   Postgres items go through the existing `drainOutbox` (upserts guarded by `source_seq`).

Invite by email or phone (compose "just works", IOS2):
1. Client: `dm.open {peer: {email}}` or `invite.create` in a group, with a client key.
2. Worker: normalize, `address.ensure` on AddressDO (refuses suppressed addresses with the same
   answer as success to the inviter, so suppression does not leak), `invite.quota.take` on the
   inviter's UserDO, then the op on ConversationDO.
3. ConversationDO commits the invite (address participant + invite record), then its outbox sends
   `address.deliver` to AddressDO with the rendered copy.
4. AddressDO checks suppression, per-recipient windows and the environment policy (staging sends
   only to the private allow list, refused before the provider call), sends through the provider
   with the invite id as the provider idempotency key, records the result and reports
   `invite.delivery.report`.
5. Recipient opens `<accept origin>/i/<g|d><26-char conversation suffix>#<26-char secret>`. D-H1:
   the origin is `https://cmux.com` once that route ships (a main PR); until then the environment's
   dashboard (`https://console-staging.cmux.dev`, `https://console.cmux.dev`). `inviteOrigin` has no
   default and throws for an unknown environment. In every SMS the URL is alone on the last line. The secret is in the fragment, so it never reaches server logs or
   link scanners, and a prefetch cannot consume it. iOS opens the app through universal links;
   otherwise the web page shows the preview (`invite.preview`), then Stack sign-up with the
   address prefilled, then `invite.accept`, then the thread (web Home, or the app when installed).

Chief wake: ConversationDO decides who wakes (rules and budget enforced at the owner, as in
`cmux-conversation`), MuxDO queues, the brain posts with its chief token; the turn budget refuses
loops (`agent_budget`, `agent_rate`).

## 6. Volumes (design targets, to check against telemetry)

| Quantity | Target | Basis |
| --- | --- | --- |
| Monthly active users | 100k in year one, design headroom 1M | |
| Human messages per active user per day | 30 (p99 300) | DMs and groups |
| Chief messages per active user per day | 200 (p99 2,000), plus 3 work-card edits per chief turn | chief threads dominate volume |
| Messages per day at 100k MAU (40% daily active) | about 9M sends + 20M edits | |
| Peak ops per second, system | about 1,500 (5x the mean) | spread over objects |
| Peak ops per second, one conversation | 20 (a chief streaming work-card edits) | one DO handles about 1,000 simple ops/s |
| Fan-out per message | DM 2, chief thread 1 human + 1 chief, group p50 4, max 64 (cap) | inbox bumps coalesce per drain |
| Conversations per user | p50 30, p99 2,000 | inbox list pages by 200 |
| Message size | p50 300 B human, 2 KB chief; max 64 KiB text (reducer limit) | |
| Storage per conversation | p99 1M messages, about 2 GB (DO limit 10 GB) | chief threads; retention or a new thread per period if a chief thread passes 5M messages (OPEN) |
| Search rows | about 10M per day at 100k MAU, 1 KB average indexed text (truncated at 16 KiB) | about 3.5 TB per year before compression; retention policy needed before 1M MAU |
| Invites | 1 to 3 per active user per month; hard caps section 9 | |

## 7. PlanetScale `cmux-next` schema (projections only)

Proposed migration `0005_home.sql` (the backend lead applies it through `backend:apply-migrations`;
staging first). Every row carries `(source_stream, source_seq)`; upserts never move a row
backwards.

```sql
-- phase: expand
CREATE EXTENSION IF NOT EXISTS btree_gin;   -- OPEN: confirm availability on PlanetScale Postgres
CREATE EXTENSION IF NOT EXISTS pg_trgm;     -- CJK and substring search

CREATE TABLE home_conversations (
  id             text PRIMARY KEY,
  kind           text NOT NULL CHECK (kind IN ('chief', 'dm', 'group')),
  team_id        text,
  title          text,
  created_by     text NOT NULL,
  created_at     timestamptz NOT NULL,
  last_seq       bigint NOT NULL,
  last_at        timestamptz NOT NULL,
  participant_count int NOT NULL,
  state          text NOT NULL CHECK (state IN ('active', 'archived')),
  source_stream  text NOT NULL,
  source_seq     bigint NOT NULL
);
CREATE INDEX home_conversations_team ON home_conversations (team_id, last_at DESC) WHERE team_id IS NOT NULL;

-- Membership is the search permission: one row per (conversation, participant).
CREATE TABLE home_participants (
  conversation_id text NOT NULL,
  participant_id  text NOT NULL,
  kind            text NOT NULL CHECK (kind IN ('human', 'agent', 'address')),
  visible_from_seq bigint NOT NULL DEFAULT 0,
  joined_at       timestamptz NOT NULL,
  left_at         timestamptz,
  source_stream   text NOT NULL,
  source_seq      bigint NOT NULL,
  PRIMARY KEY (conversation_id, participant_id)
);
CREATE INDEX home_participants_member ON home_participants (participant_id, conversation_id) WHERE left_at IS NULL;

-- Search projection, hash-partitioned by conversation (64 partitions, fixed).
CREATE TABLE home_message_search (
  conversation_id text NOT NULL,
  seq            bigint NOT NULL,
  message_id     text NOT NULL,
  author_id      text NOT NULL,
  author_kind    text NOT NULL CHECK (author_kind IN ('human', 'agent')),
  created_at     timestamptz NOT NULL,
  edited_at      timestamptz,
  body           text NOT NULL,                 -- text parts only, truncated at 16 KiB
  tsv            tsvector GENERATED ALWAYS AS (to_tsvector('simple', body)) STORED,
  source_seq     bigint NOT NULL,               -- conversation rev of the last write
  PRIMARY KEY (conversation_id, seq)
) PARTITION BY HASH (conversation_id);
-- 64 partitions: home_message_search_p00 .. p63, each
--   CREATE TABLE home_message_search_pNN PARTITION OF home_message_search FOR VALUES WITH (MODULUS 64, REMAINDER NN);
CREATE INDEX home_message_search_fts ON home_message_search USING gin (conversation_id, tsv);
CREATE INDEX home_message_search_trgm ON home_message_search USING gin (conversation_id, body gin_trgm_ops);
CREATE INDEX home_message_search_recent ON home_message_search (conversation_id, created_at DESC);

CREATE TABLE home_invites (
  id             text PRIMARY KEY,
  conversation_id text NOT NULL,
  invited_by     text NOT NULL,
  address_id     text NOT NULL,                 -- HMAC id, never the address
  channel        text NOT NULL CHECK (channel IN ('email', 'sms')),
  status         text NOT NULL,
  delivery_state text NOT NULL,
  copy_variant   text NOT NULL,
  created_at     timestamptz NOT NULL,
  expires_at     timestamptz NOT NULL,
  accepted_by    text,
  accepted_at    timestamptz,
  source_stream  text NOT NULL,
  source_seq     bigint NOT NULL
);
CREATE INDEX home_invites_inviter ON home_invites (invited_by, created_at DESC);
CREATE INDEX home_invites_address ON home_invites (address_id, created_at DESC);
```

Outbox kinds (drain statements in `projection.ts`): `home.conversation.upsert`,
`home.participant.upsert`, `home.message.upsert`, `home.message.delete`, `home.invite.upsert`.
A retraction or retention delete sends `home.message.delete`; an edit sends an upsert with the
new body. No raw address, token or token hash is ever projected.

## 8. Search (Home messages only)

- Scope: messages of conversations where the caller is a current human participant, at or after
  `visible_from_seq`. Chiefs search through their owner's grant only when the op is in their
  grant (`read` class); addresses never search.
- Op: `home.search {q, conversation?, author?, kind?, before?, cursor?, limit<=50}`, owner
  `cloud:Worker` read (Hyperdrive, read-only role). Result: `{hits: [{conversation, seq,
  message_id, author, created_at, snippet, ranges}], cursor?}`; the client opens the hit with
  `conversation.history` around `seq`.
- Query: the Worker runs one statement that joins `home_participants` (index on `participant_id`)
  to `home_message_search` with `conversation_id = ANY(member conversations)` and either
  `tsv @@ websearch_to_tsquery('simple', q)` or, when `q` has CJK characters or is shorter than 3
  letters, `body ILIKE '%' || q || '%'` on the trigram index. The composite GIN indexes
  (btree_gin) let one bitmap scan apply the membership and the text condition together; hash
  pruning limits the scan to partitions of the caller's conversations.
- Ranking: default order is newest first among matches (what users expect from messages), with
  a "Top" section of at most 3 hits by `ts_rank_cd(tsv, q, 32) / (1 + age_days / 30)` with a 1.5x
  boost for human authors and exact phrase matches. Ties break by `created_at DESC`.
- Snippets: `ts_headline` on the hit rows only (bounded to 50); ranges are UTF-16 offsets for the
  native renderers.
- Freshness: the projection lags the commit by one outbox drain (target p95 under 2 s). The open
  conversation also searches its own loaded pages on the client, so "find in this conversation"
  is instant.
- Local-only conversations (home.md) search in the daemon's SQLite with FTS5 (trigram tokenizer);
  the client merges both result lists by `created_at`.
- Self-hosted servers use the same SQL on their own Postgres (SV2, D-H6), without partitions.

## 9. Invites: limits and abuse controls

- Per inviter (UserDO windows): 20 per day, 60 per week; accounts younger than 24 h or without a
  verified email: 5 per day and no custom text in the invite. Team admins may raise limits for
  their team (TeamDO policy).
- Per address (AddressDO): at most 1 invite per inviter per 7 days (a repeat attaches to the
  pending invite, no new send), at most 3 distinct inviters per 30 days, at most 1 reminder per
  invite (after 3 days, only if unopened). Opt-out, bounce, complaint or a spam report suppresses
  all future sends.
- Per conversation: 20 pending invites; 10 failed `invite.accept` attempts per hour lock invite
  acceptance for that conversation for an hour (secret guessing; secrets are 128-bit).
- Per network: Cloudflare rate limiting on `invite.create`, `dm.open` with an address, and
  `invite.preview`: 30 per minute per IP.
- Content: inviter text appears in the invite only for trusted inviters (verified email, account
  at least 24 h old, no prior reports); links in inviter text are not linkified in email and are
  removed from SMS.
- Environment send policy (in code, AddressDO, before any provider call): production sends to
  anyone not suppressed; staging, development and previews send only to addresses in the private
  allow list loaded at runtime from secret storage (never in the repository), and refuse every
  other recipient with `delivery.state = refused_env` and no provider call. A global kill switch
  (`HOME_INVITES_SEND=off`) refuses everything.
- Every email has a one-click unsubscribe (List-Unsubscribe and List-Unsubscribe-Post headers)
  and a "report spam" link (routes `/u/<token>` and `/r/<token>` on the accept origin); the first
  SMS to a number carries "Reply STOP to opt out." before the link (D-H5); inbound STOP suppresses.

## 10. Retention

- Messages: kept until the team policy `home.retention_days` (minimum 30) or user deletion;
  default keep. The ConversationDO alarm deletes expired message rows in batches and emits
  `home.message.delete` projection rows. Retraction removes the body at once (DO and search).
- Ledger: 7 days (engine default). Events (`own_events`): keep the last 30 days or 10,000 events,
  whichever is more; older resumes take a snapshot (engine need E3).
- Invites: pending ones expire after 14 days; records are kept 90 days, then reduced to counts.
- Addresses: suppression is kept forever (a suppressed address must stay suppressed); the raw
  address is deleted after 180 days without an invite unless suppressed.
- A conversation with no human participant for 30 days deletes its DO storage.

## 11. Self-hosted implementation (cmux server, team VM)

- D-H2: `home-core` is TypeScript, and the self-hosted owner may run the same TypeScript (the
  backend lead is trying Rust Workers on emscripten first; the language of the self-hosted
  owner follows that trial). The Mac's local-only owner stays the Rust crate `cmux-conversation`.
- Contract: the conformance corpus (`backend/packages/home-core/conformance/*.json`) is the
  protocol; every owner (cloud TS, self-hosted, Rust local) must pass the cases it supports.
- State: the owner's own SQLite; search and the conversation index in the server's Postgres with
  the same SQL as the cloud (SV2, D-H6), without hash partitions.
- Protocol: the server speaks `cmux.wire/1` (same frames, op names and params as the cloud) over
  its authenticated WireGuard listener; the Mac app and iOS use one client with two transports.
- What a server cannot do alone: push (APNs keys stay with cmux) and invites (provider keys and
  the suppression list stay central). A server calls the cloud relay ops `push.relay` and
  `invite.relay` with its host install token; the cloud applies the same limits and suppression.

## 12. Engine and infra (answered by the backend lead, PR 16827)

- E1 row mode: `Domain.reduce(head, op, params, ctx)` reads rows through `ctx.rows` (RowReader)
  and returns `{state, value, writes, outbox}`, committed in one SQLite transaction; events carry
  `effects {state, writes}`; snapshots carry the head plus the tail of `rowMode.snapshotTable`
  (`msg` for ConversationDO); older pages through `conversation.history`.
- E2: one engine per stream in UserDO (`own_` for `user:`, `inbox_` for `inbox:`), each with its
  own seq, ledger, outbox and subscription.
- E3: `pruneEvents` keeps 30 days or the last 10,000 events; older resumes get a snapshot.
- E4: outbox items with `target {class, name, coalesce?}` drain in seq order through
  `systemSubmit` with the item key as idempotency key, per-target backoff; `inbox.bump`
  coalesces per (target, conversation).
- E5: the UserDO gateway carries `user:<id>` and `inbox:<id>`; an open conversation uses
  `GET /v1/wire/conv/<id>`; ConversationDO checks participation and closes the stream on removal.
- E6: secrets per environment `HOME_ADDRESS_KEY`, `HOME_INVITE_ALLOWLIST_EMAILS`,
  `HOME_INVITE_ALLOWLIST_PHONES` (non-production), kill switch `HOME_INVITES_SEND`; Cloudflare
  rate-limit bindings for `invite.create`, `dm.open` by address and `invite.preview`.

File boundaries: lane 15 writes `backend/packages/home-core/**` (reducers for conversation,
inbox, mux and address; invite links, limits, policy and copy; the conformance corpus) and this
file. The backend lead writes the DO classes and bindings (ConversationDO, MuxDO, AddressDO, the
UserDO second stream), `/v1/wire/conv/<id>`, op routing, rate limits, the AddressDO provider
sends (it may import `deliverInvite` from `@cmux/home-core/invites`), the accept route, migration
`0005_home.sql` and every deploy.

## 13. Client API (iOS and Mac)

- HTTP: `POST /v1/ops` (every mutation above), `POST /v1/read` (`inbox.list`,
  `conversation.snapshot`, `conversation.history`, `home.search`, `invite.preview`),
  `POST /v1/invites/accept` (thin alias for the web landing page).
- WebSocket `cmux.wire/1`: the UserDO gateway carries `user:<user>` and `inbox:<user>` (inbox
  events: bump, pin, mute, archive); brain hosts subscribe to `mux:<agent>`; the open
  conversation uses `GET /v1/wire/conv/<id>` (snapshot with `tail`, resume with `after_seq`, events `message`, `message-updated`,
  `read-cursor`, `conversation`, `typing`, `invite`).
- Generated clients: the TS client in `clients/ts/cloud` and the Swift client from the same
  catalog; the Swift Home client keeps the mirror + intent log from home.md section 3.

## 14. Decisions

- D-H1 (coordinator): invite links on `cmux.com/i/<code>`; the environment's dashboard until that
  route ships.
- D-H2 (Lawrence): TypeScript `home-core`; the self-hosted owner may be TypeScript too.
- D-H3 (Lawrence): compose shows profiles only for people you share a team or a relationship
  with; otherwise only an invite. Redesign of relationships and membership: section 16.
- D-H4 (coordinator): group email invites bind to the verified email (else inviter approval);
  one-to-one invites admit any holder once.
- D-H5 (coordinator): STOP line in the first text; US and Canada first.
- D-H6 (Lawrence): Postgres on servers with the cloud's SQL.
- D-H7 (coordinator): per-group `history_visible`, default `all`.
- D-H8 (Lawrence): variant A (the inviter's words) with B as the fallback; each invite records
  its variant.

## 15. Invite copy (shipped strings: `home-core/src/invites/copy-strings.ts`)

The link is always alone on the last line (message apps detect it and show a preview card); the
first text to a number has "Reply STOP to opt out." on the line before it. Inviter name, title and
preview are cleaned (no links, no control characters, capped); A needs a trusted inviter (verified
email, account at least 24 h old, no reports) and falls back to B.

| Variant | SMS (dm) | Email subject (dm) |
| --- | --- | --- |
| A, their words (default) | Lawrence sent you a message on cmux: "want to try my agents?" | Lawrence: want to try my agents? |
| B, the product (fallback) | Lawrence invited you to chat on cmux, the app where their AI agents report in. | Lawrence invited you to chat on cmux |
| C, short | Lawrence wants to talk with you on cmux. | Lawrence wants you on cmux |

Group forms name the group ("added you to \"Launch\"") for trusted inviters only. Japanese
strings exist for every variant and need review. Email body: lead line, the quoted words (A), the
link on its own line and as a dark button (no blue), one line on what cmux is, then why the
recipient got it, one-click unsubscribe and report spam.


## 16. Relationships, membership and roles (proposal, from first principles)

Lawrence (D-H3): compose shows profiles only for people you share a team or a relationship with;
inviting someone into a team must be explicit and safe; more roles than admin and member (for
example "someone I can chat with"); teams may be the wrong abstraction.

### 16.1 The questions a permission answers

1. Reach: who may message me, add me to a group, or talk to my chief?
2. Discovery: who may see my profile (name, avatar) and find me by email or phone?
3. Access: who may use a resource (a host, a Cloud VM, the team VM, a chief, an automation, an
   integration, a document)?
4. Administration: who sets policy, manages members and pays?

Today a team answers all four at once. That is why "someone I can chat with" does not fit: it
needs reach and discovery but no access and no administration. The proposal splits them into
three primitives that never imply each other.

### 16.2 Three primitives

| Primitive | Answers | Created by | Revoked by | Owner |
| --- | --- | --- | --- | --- |
| Relationship (product word "Contacts"): a symmetric person-to-person link | reach and discovery between two people only | consent of both: one asks (a DM, an invite, a message request), the other accepts | either side: remove (back to none) or block | the pair's DM ConversationDO (`conv_dm_` id of the two users): one object per pair is the single writer of the pair's state |
| Grant (identity spec section 4): one principal may use one resource | access, per resource | the resource's owner (or a role, below) | the issuer, an admin of the issuing org, expiry | the resource owner's DO (UserDO for personal, TeamDO for org grants) |
| Organization (today's team): owns resources, policy, billing and an audit log | administration, and the default grants of its roles | explicit `org.invite` accepted by the invitee, or SSO/SCIM provisioning | admin removal, self leave, deprovisioning | TeamDO |

A role is a named bundle of default grants inside an organization, not a separate system:

| Role | Reach and discovery inside the org | Access | Administration |
| --- | --- | --- | --- |
| guest ("someone I can chat with") | profiles of people in conversations they share; may be added to org conversations; no directory | none (no hosts, VMs, chiefs, automations, integrations) | none |
| member | the org directory; DM any member; talk to org chiefs | org resources as the org's policy grants members (hosts per host policy, team VM account, automations they create, integrations within connection grants) | none |
| admin | member's | member's plus resource administration | members, roles, policy |
| owner | admin's | admin's | plus billing, transfer, delete |
| billing | none beyond guest | none | billing only |

Custom roles later are new bundles over the same grant classes (`read`, `mutate-own`,
`mutate-shared`, `execute`, `send-external`, `money`, `destructive`). A personal account is an org
of one, so "share this Mac with Austin" is a grant to Austin's user, not an org change.

### 16.3 What each grants in Home

- A relationship lets the two people see each other's profile, find each other in the compose
  dropdown, DM without a request, add each other to groups, @mention each other, and reach each
  other's chiefs when the chief's reachability is `contacts`.
- Org membership (any role) lets members see each other per their role (guests: only people in
  shared conversations) and appear in each other's compose dropdown; it creates no relationship,
  so leaving the org ends that visibility.
- Neither grants access to resources; only grants do.
- Being in the same group conversation shows names inside that conversation only; it creates no
  relationship and no dropdown entry.

### 16.4 Discovery and the compose dropdown

- `home.compose.resolve {query}` (read, Worker): matches names, handles and addresses only among
  the caller's relationships and org co-members visible to the caller's role.
- A typed full email or phone that belongs to an unrelated user returns the same answer as an
  unknown address: "invite will be sent". The inviter learns nothing about the address.
- That user receives a message request in Home and an email (on by default, R2), not a silent
  join. Accepting creates the relationship and moves the conversation into their inbox;
  declining or blocking ends it. Until acceptance the sender sees no delivery or read state.
- Unknown addresses get the invite flow (sections 5 and 9). Accepting a one-to-one invite also
  creates the relationship (consent by both).
- Profile fields (display name, avatar, handle) are owned by UserDO; they are published to the
  user's relationship pair objects and org TeamDOs only, never to a global directory.

### 16.5 Inviting into an organization (explicit and safe)

- A separate op, `org.invite {org, address|user, role}`, from a separate UI: the sheet names the
  org, the role and what it grants ("Austin will see Manaflow's machines, chiefs and automations,
  and Manaflow pays for a seat"), with a confirmation. The chat compose can never produce it.
- The invitee's accept screen states the same facts and the org's policy (retention, admin
  visibility) before they join. Guests see "you can chat with people at Manaflow; you get no
  access to its machines".
- Only admins and owners can invite members or admins; members may invite guests when the org's
  policy allows (default off).
- Email and SMS for org invites reuse the invite channel, limits and suppression, with their own
  copy (not the chat variants).

### 16.6 Block, remove and leave

- Remove a relationship: the pair state goes to `none`; the old DM stays readable for both; new
  messages from the other person arrive as a message request.
- Block: the pair state records the blocker; the blocked person cannot DM, request, invite (chat
  or org), add the blocker to groups or find the blocker; in shared groups the blocker's clients
  hide the blocked person's messages. Unblock is the blocker's op only.
- Leave or removal from an org: org grants end at once (the next token refresh fails and every
  owner rechecks grants); org conversations (`team` set) remove the member; personal DMs
  continue only where a relationship exists, otherwise they turn read-only.

### 16.7 Owners, ops and sync

| State | Owner | Ops | Projections |
| --- | --- | --- | --- |
| Pair relationship `{state: none|requested|connected, requested_by?, blocked_by[], since}` | DM ConversationDO of the pair | `relation.request` (implicit in `dm.open` and DM invites), `relation.accept`, `relation.decline`, `relation.remove`, `relation.block`, `relation.unblock` | each side's UserDO (`relations` rows, outbox with target), Postgres `home_relations (user_id, other_id, state)` for server-side checks |
| Org membership and roles | TeamDO | `org.invite`, `org.invite.accept`, `org.invite.revoke`, `org.member.role.set`, `org.member.remove`, `org.leave` | UserDO memberships, Postgres `memberships` (exists, `role` gains `guest` and `billing`) |
| Grants | UserDO or TeamDO (issuer) | identity spec section 4 | the resource owners check by grant id |
| Profile and discovery settings | UserDO | `profile.set`, `home.settings.set {allow_requests_from: anyone|teams|nobody, email_requests: on (default)|off}` | TeamDOs and pair objects of the user |

Checks: a group ConversationDO accepts `participants.add` of a human only when the adder and the
addee are connected or share an org where the adder's role may add people, read from the adder's
UserDO projection (eventually consistent; a block takes effect at the pair owner at once and in
projections within one drain).

### 16.8 Migration from today

`memberships.role` today is owner, admin or member; add `guest` and `billing` (expand
migration). Existing team members keep their roles. No relationships exist yet; the first DM
between two existing org members creates their relationship only when both send a message
(implicit consent), so org departures do not erase working DMs.

### 16.9 Decisions (Lawrence, 2026-10-02)

- R1: the three primitives are accepted: Contacts (relationships), Grants, and Team with the roles guest, member, admin, owner and billing. The product and code keep the name "Team" (`team_` ids); "org" in this section only separates it from relationships.
- R2: message requests from unrelated users show in Home AND send an email (on by default; the recipient can turn email off in `home.settings.set {email_requests}`).
- R3: the address owner is `AddressDO`, participants `addr_<26>`, secret `HOME_ADDRESS_KEY` (backend and home-core renamed).

## 17. Engine and flow questions (answered by the backend lead, 2026-10-02)

- Q1. The invite secret never enters a reducer, event or outbox (only its hash does), so
  AddressDO cannot build the link from `address.deliver`. Proposal: the Worker generates the
  secret, stores it in AddressDO (`address.stash_secret {invite, secret}`, system, deleted after
  the send) before `invite.create`, and AddressDO renders the copy when the `address.deliver`
  item arrives. Accepted: `address.stash_secret` keeps it in a side table outside op state,
  deleted after the provider accepts or after 24 h, never logged; AddressDO renders with
  home-core's builder.
- Q2. After a contact accepts a one-to-one invite, the conversation id is the contact-based
  `conv_dm_` id, not `dmConversationId(inviter, user)`. Proposal: `dm.open` first looks up the
  caller's inbox `dm_peer` index (UserDO) and uses the hash only when no DM exists. Built:
  inbox table `peer` and `dmPeer(rows, peer)`; the backend wires the lookup.
- Q3. `reduce` does not receive the idempotency key, so the Domain enforces `client_msg_id`
  uniqueness through the `msgkey` table instead of `client_msg_id == key`. Proposal: add
  `idempotency_key` to `ReduceContext`. Done: `ctx.idempotencyKey` (owner and own intent
  preview, absent in mirror replay); the Domain checks `client_msg_id === key` when present.
- Q4. Invite token hashes appear in `invite.create` event params and `inv` rows that participants
  can read. A hash cannot accept (accept hashes the presented secret), but the engine could keep
  them out of events with a per-op event redaction hook. Done: `EngineOptions.redact`;
  home-core exports `conversationRedact` (token hashes, accept proofs) and `PRIVATE_TABLES`
  (`invhash`, whose row keys are hashes: keep its writes out of subscriber effects). The accept
  op takes `proof = sha256(secret)` and invites store `token_hash = sha256(proof)`, so no event
  carries a value that can accept.

## 18. First contact over text (decisions, 2026-10-02)

- Contact card name: "cmux" now; "Chief · cmux" once texting Chief works (section 19).
- Sequence for the first text to a number (AddressDO `first_text`): 1. the cmux contact card
  (vCard 3.0, `FN:cmux`, the sending line, `URL:https://cmux.com`, embedded JPEG photo of the
  app icon; `renderVCard`), hosted as a `.vcf` and sent as media; 2. only after the card's
  provider status is SENT or DELIVERED (status callback), the invite text with the invite card
  image attached (`media_url = <accept origin>/og/invite/<code>.png`, `inviteImageUrl`) and the
  link alone on the last line. Later invites to the same number: the text with the image, no
  card. Builder: `textSendPlan` (home-core); the adapter (AddressDO, backend lead) runs the
  steps and waits on the callback between them.
- Why the image is attached: message apps may show "Tap to Load Preview" for links from a
  sender that is not a saved contact; an attached image always shows. Preview behavior is
  measured later with real users (the 13:41Z test showed the card with the icon; previews
  appeared at once for one link and needed a tap for another).
- Invite card image: `/og/invite/<code>.png`, 1200x630 PNG, public cache 1 day when
  personalized (first name and avatar or initial only), 5 min generic. Three designs
  (conversation default, terminal, minimal) in `invite-card-variants.tsx`; Lawrence picks.
  Privacy: personalization by the code alone is acceptable because invite codes are
  unguessable (group ids carry 80 random bits; address DMs are keyed HMACs); strongest
  objection: anyone who sees a forwarded link learns the inviter's first name and avatar,
  which is also what the link's recipient sees. `/v1/invites/card/<code>` must answer only for
  codes with an open invite and never for user-to-user DMs.

## 19. Text Chief over the phone (proposal)

Goal: a person texts the cmux line and talks to their Chief; Chief replies in the same thread.

- Inbound: `POST /v1/hooks/sendblue` in the Worker. The provider sends the shared secret in a
  header (no signature, no timestamp), so: constant-time secret check, accept only messages to
  our own lines, refuse `date_sent` older than 10 minutes, dedupe by `message_handle` in the
  AddressDO ledger (`inbound:<handle>`, 7 days), 2xx at once and process from the AddressDO
  outbox. Inbound media URLs expire after 30 days at the provider; copy to R2 only when kept.
- Phone linking (decision T1, built in `address/text-link.ts`): the user asks in the app; the
  Worker generates a 128-bit code and commits `address.text_link.request {user, code_hash}`;
  AddressDO texts a sign-in link on the fixed origin (`https://console.cmux.dev/link#<code>`, no
  shortener, the link alone on the last line, "expires in 10 minutes; ignore it if you did not
  ask"). Opening it signs in with Stack (or uses the signed-in session) and sends
  `address.text_link.confirm {proof}` (`proof = sha256(code)`; AddressDO stores
  `sha256(proof)`). It binds only when the signed-in account is the one that asked, within 10
  minutes, once; another account burns the link (forwarded links), five wrong proofs burn it, 3
  requests per number per hour. A number bound to one account cannot be requested by another
  until it is unlinked. STOP ends the binding. A binding lasts 180 days and needs a new link
  after 90 days without inbound texts.
- Limits (security review): 3 link requests per hour per (number, account), 6 per day per
  number, plus per-account limits in the Worker (5 per day, 2 numbers per day); one pending
  link per account, so a stranger's request never replaces the owner's link. The Worker answers
  every request the same way ("if this number can be linked, we sent a text"), so a refusal does
  not reveal whether a number is bound, suppressed or rate limited. A text never revives an
  idle or expired binding. The binding is separate from `linked_user` (invite routing), so a
  wrong binder never owns the address. STOP ends the binding; START or UNSTOP (or YES while
  suppressed) from the same number lifts only that opt-out (`address.resubscribe`); a late STOP
  still applies.
- Link page (backend lead): never confirm on load; show the masked number and the signed-in
  account, and require a button press; `Referrer-Policy: no-referrer`, no third-party scripts;
  keep the code out of sign-in redirect URLs (session storage) and remove the fragment with
  `history.replaceState`; a fresh idempotency key per click, and read `value.linked`. The text
  names the masked account that asked ("for the cmux account l***@example.com"), so a person
  who did not ask can tell. Link previews cannot use the code (the fragment never reaches a
  server, and a preview has no session).
- Residual risks (it is not foolproof; texts are a weak channel):
  - Forwarded link or login CSRF: an attacker asks for a link to the victim's number, then
    gets the victim to forward it or to open it in a browser signed in to the attacker's
    account. The victim's texts to cmux then reach the attacker's Chief. Mitigations: the text
    and the page name the requesting account; the button press; nothing else.
  - SIM swap, port-out or a recycled number BEFORE linking: an attacker who receives the
    user's texts can bind the number only to the account that asked (their own), so they cannot
    take the user's account, but they receive what the victim texts to cmux. Not built yet: a
    notice to the previous account when a number is relinked.
  - SIM swap, a stolen unlocked phone or a recycled number AFTER linking: whoever controls the
    number texts with the user's Chief authority (the strongest objection to the full default,
    below). After a SIM swap the attacker can also register the number for iMessage, so the
    iMessage rule does not help then. Carrier-change signals are not exposed by the provider
    (UNVERIFIED); the 90-day idle rule and the 180-day expiry limit the window only partly.
  - Forged sender numbers: some gateways can forge an SMS sender, so texts that arrive as plain
    SMS get read and reply only, and in group threads the authority is read and reply too.
  - The webhook secret: the provider sends a shared secret, not a signature. Anyone who learns
    it can forge an iMessage from any bound number with full authority. Mitigation to build:
    before acting with full authority, fetch the message from the provider API by its handle and
    compare it.
  - Phishing look-alikes: one fixed cmux domain and never a shortener, but users can still be
    fooled by a look-alike domain in a fake text.
  - The account itself: a stolen Stack session can link any number the attacker controls.
  - The unlinked-number auto-reply goes to any sender, including forged ones (once per day per
    number).
- Routing: an inbound text from a bound number becomes a `message.send` in the user's chief
  conversation, authored by the user with `origin: remote` and part metadata `via: sms`; MuxDO
  wakes the Chief; the Chief's reply in that conversation goes back out through AddressDO.
  Unbound numbers get one reply per day: "This number is not linked to cmux. Open cmux to link
  it: <link>".
- Group threads: a provider `group_id` maps to one group conversation (Chief plus the bound
  members; unbound members appear as `addr_` participants that cannot act). The Chief answers in
  a group only when named or replied to (existing wake rules and turn budget).
- Limits: inbound 30 per minute and 500 per day per number; Chief replies 200 per day per user;
  the conversation turn budget applies; the line's provider limits are global.
- STOP, HELP, START: STOP suppresses the address and pauses texting (the account stays); HELP
  returns a fixed text; START resumes. Keywords are answered before any routing.
- Privacy: texts are Home messages with the chief thread's retention; nothing else is stored
  beyond the dedupe key and delivery state.
- What the Chief may do from a text (decision T3): everything the Chief can do in the cloud, by
  default; a per-user setting `text_channel_scope: full | read_reply | off` restricts it
  (`textAuthority`). Never in a text: secrets, tokens, passwords, codes, other people's invite
  secrets; anything that would show one opens the app. Strongest objection: with the full
  default, a SIM swap, a stolen phone or a recycled number gives full Chief power by text.
  DECISION (not built): require an in-app confirmation for destructive or irreversible actions
  requested by text. RECOMMEND yes, because it closes the worst case of the full default at
  the cost of one tap.

Decisions (Lawrence, 2026-10-02): T1 a texted Stack sign-in link (above), not reverse
verification; T2 texts land in the main chief conversation marked `via: sms`; T3 full Chief
authority by default with a per-user restriction setting. Invite card: the minimal design is the
default (`?v=` keeps the others), `?s=square` renders 1200x1200.

## 20. One op vocabulary: reconciling home-core with `cmux-conversation`

Contract: `backend/packages/home-core/conformance/conversation-cases.json` (64 cases) is the
op-level contract both owners run; `conversation-cloud-cases.json` (84) covers cloud-only rules.
The Rust owner adds a cargo test that replays the local file (on a testbox). Framing stays per
transport (daemon line commands, `cmux.wire/1` frames); the op names, params, commits and reject
reasons are the same.

| # | Difference | Rust local owner today | home-core cloud | Recommendation |
| --- | --- | --- | --- | --- |
| 1 | Command names | `conversation-create/-op/-snapshot/-history/-list/-typing` | ops `conversation.create`, `message.*`, reads `conversation.snapshot/history`, `inbox.list` | Same op kinds inside `conversation-op`; map the five daemon commands 1:1 to the cloud ops and reads; no renames needed in Rust |
| 2 | rev and seq | `rev` +1 per committed op; message `seq` dense | head `rev` +1 per commit; engine stream seq per changed op | Keep both; document that a cloud head's `rev` equals the engine stream seq (both skip no-ops) |
| 3 | Ledger scope | `op_ledger (conversation, idempotency_key)`: two actors with one key collide | engine ledger per (identity, key) inside the conversation's object | Rust adds the actor to the ledger key (bug: one participant can block another's `client_msg_id`) |
| 4 | `client_msg_id == idempotency_key` | required | required when the engine passes the key (owner and own intent preview) | Same rule; corpus covers it |
| 5 | Reject transport | `error_code: conversation_rejected`, reason in the message text | `code` = the reason | Rust adds a structured `reason` field (same 20 local codes); cloud keeps `code` = reason; corpus asserts reasons |
| 6 | Agent budget | window of the newest 5 rows; text-less work cards fill the window, so two agents can loop forever with work cards | head counters `agent_text_streak`, `last_agent_text_at`, O(1) | Rust adopts the head counters (fixes the loop bypass); the local corpus notes describe the two edge differences until then |
| 7 | Typing | `conversation-typing` command, ephemeral event | ConversationDO memory broadcast | One non-op frame `typing {conversation, on}` and event `conversation-typing` on both; never stored, not in the corpus |
| 8 | Agent identity | `conversation-agent-token` + `conversation-bind` (local token) | principal from the Worker (agent token, grant) | Transport auth, not ops; stays local-only; not in the corpus |
| 9 | Participants | `user_local`, `user_<id>`, `agent_<name>` | plus `addr_<26>` (kind `address`), roles, `joined_seq`, `left_at` | Local stays a subset; `conversation.promote` maps `user_local` to the account's `user_<id>` |
| 10 | Message ids | ULID `msg_<26>` | engine `newId("msg")` | Both accept any `msg_` id; the corpus passes `new_message_id` |
| 11 | Events | `conversation-changed {rev, transaction, change}` | engine event `{seq, tx, op, params, effects}` | Clients map both to the corpus `Change`; ConversationDO also returns `change` in the op result |
| 12 | Summary owner | `"local"` | `"cloud"` | Keep; the client shows "this Mac only" for local |
