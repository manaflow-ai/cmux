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
| Message | `msg_<26>`, `seq` dense per conversation | `client_msg_id`, `author`, `parts[]` (text with runs/mentions, `work`, `approval`, `attachment {hash, name, mime_type, byte_count, width?, height?, duration_ms?, poster? {hash, mime_type, byte_count}, preview? {hash, mime_type, byte_count}}` (cloud heads only; see section 10.1), refs `task`/`vm`/`pr`), `reply_to? {message_id, part_index}`, `thread_root?`, `created_at`, `edited_at?`, `retracted_at?`, `reactions[] {author, part_index, kind, at}` |
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
| `participants.add` | `{participant: user or chief}` | client key | members | 120 per hour per actor and `conversation.create` 60 per hour, checked before any reach lookup (section 9); a human may be added only when they share a team with the adder or are connected to them (a shared group is no connection), and their `allow_requests_from` allows it (section 16.10); anyone else needs `invite.create` (later a message request). A chief adds the humans its owner could add, under its owner's reach. A chief may be added by its owner, or by anyone when its `reachability` allows. Max 64 |
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
| `inbox.reindex` | `{conversations[], done}` | `inbox-reindex:<sha256 of the batch>` | system (the UserDO itself) | one-time migration: writes the order rows of entries stored before `entry_order` existed and releases a peer row that points at a left DM to a live DM with that peer; an id that is not valid is skipped, so `done` always sets the head flag `ordered` |
| `inbox.pin` | `{conversation, pinned, position?}` | client key | session, install | user-owned; a position (given or automatic) past 2^53 - 2 is `invalid_params` |
| `inbox.mute` | `{conversation, until?}` | client key | session, install | approvals still notify (spec) |
| `inbox.archive` | `{conversation, archived}` | client key | session, install | a new message un-archives (bump rule) |
| `inbox.mark_unread` | `{conversation, unread}` | client key | session, install | flag only; the read cursor stays |
| `inbox.list` (read) | `{cursor?, limit, include_archived?}` | n/a | session, install | pinned first by position, then `last_at` desc, ties by conversation id; pages of at most 200 by a keyset `cursor` (the `next_cursor` of the previous page, null on the last); an index table `entry_order` keeps the order, so a page reads about one page of rows. Changes after a snapshot come from the `inbox:` stream (`after_seq`), not from this read, so the earlier `after_rev` param is dropped |
| `chief.create` | `{name, parent?, avatar?, brain}` | client key | session | creates the agent principal, its grant (class `mux`), its `MuxDO` and its `chief` conversation (outbox, system ops with derived keys); the first chief is pinned |
| `chief.update` / `chief.archive` | `{agent, ...}` | client key | session (owner) | archive keeps history read-only |
| `invite.quota.take` | `{invite_id, channel}` | `quota:<invite_id>` | system (Worker on the inviter's behalf) | per-user windows (section 9); a refused take refuses the invite |
| `home.settings.set` | `{discoverable_by_email?, discoverable_by_phone?, allow_requests_from?: anyone|teams|nobody, email_requests?}` | client key | session | at least one field. Defaults: `allow_requests_from: anyone`, `discoverable_by_email: false`, `discoverable_by_phone: false`, `email_requests: true`. `allow_requests_from` limits `dm.open`, group creation and `participants.add` of this user (section 16.10): `anyone` = a shared team or a connection (interim, until message requests exist), `teams` = a shared team or a connection (a connected contact never needs a request), `nobody` = no new reach, also from contacts (an existing DM keeps working). `email_requests` is stored but not read yet (16.10 item 9) |

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
   muted, not the author, an install with a push token, no foreground socket, Mac not active;
   limits and follow-ups in section 9).
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
`home.participant.upsert`, `home.message.upsert`, `home.message.delete`,
`home.message.delete_through`, `home.invite.upsert`. A retraction sends `home.message.delete`; a
retention sweep sends one `home.message.delete_through {conversation_id, seq}` per batch; an edit
sends an upsert with the new body. No raw address, token or token hash is ever projected.

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
- Reach (built 2026-10-04, `home-rate.ts`): `conversation.create` 60 per hour and
  `participants.add` 120 per hour per acting principal (a user, or each of the user's chiefs),
  counted in the user's UserDO (private table `home_rate`). The Worker takes the attempt before
  the member check and before any reach RPC, so a flood never fans out to TeamDOs, other users'
  UserDOs or ConversationDOs; every attempt counts, also a refused one. A spent budget is
  `home.rate_limited`, retryable, `details.retry_after_ms` (until the oldest counted attempt
  leaves the hour). Reach lookups are capped at 64 targets per op after the gate (TeamDO checks
  the cap too). `dm.open` with a user peer spends the `conversation.create` budget.
  All of an owner's chiefs together also share a total of 3x the per-actor limit per hour (180
  and 360): every `agent_` actor counted in the owner's UserDO counts toward it, and the owner's
  own budget is separate, so archiving and creating chiefs mints no fresh budget.
  After a refusal, a retry of a key already decided in the target conversation goes straight to
  the owner with the plain principal (no reach RPC): its stored result, or `idempotency.conflict`
  for other params. A refused `dm.open` with a user peer still reopens the caller's existing DM
  (inbox peer index, no charge; not for a chief). A caller whose UserDO never served them (no `user.ensure`) gets
  `home.user_not_ready`, not retryable. A create the owner refuses (reach, policy) opens an empty
  ConversationDO: the refusal is decided on the initial state and writes no storage or ledger.
  Open follow-up: `conversation.import` with a new `local_id` and `dm.open` with an address peer
  have no Worker budget yet (only the per-network limits below).
  Open follow-up (accepted for now): with the budget spent, the DM reopen still lets a client
  write one idempotency entry per new key into its own DM (the same size as an entry on the
  budget path, and only in the caller's own DM). A chief never reopens through its owner's inbox.
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
- Home push (UserDO, decided from each `inbox.bump`, section 5 step 3). Accepted in review: a
  plain push is also held while the user's Mac is active (FeedDO presence), in addition to "no
  foreground socket"; this is the same rule as the feed's `feed.prefs.push_skip_when_mac_active`
  (`user-do.ts` `homePushQuiet`). A held push is dropped after 30 minutes
  (`FOREGROUND_MAX_WAIT_MS`), so a stale message never notifies later. Approvals bypass the hold
  and the cap. Per-user cap: 60 plain pushes per hour (B10); an over-cap push waits for the
  window. Known follow-ups: the cap counts a send before the APNs call, so an APNs
  `retry_later` that is sent again counts twice (`recordSend` in `home-push-drain.ts`); collapsed or
  capped pushes do not update the app badge (B10).

## 10. Retention

- Messages: kept until the team policy `home.retention_days` (minimum 30) or user deletion;
  default keep. The ConversationDO alarm runs the system op `conversation.sweep`: it deletes
  expired message rows oldest first, 500 per commit, and emits one `home.message.delete_through`
  projection row per batch; when the newest message expires, inbox previews are cleared, and expired
  messages a human had not read leave that human's unread and mention counts (read, retracted and
  own messages never counted). A stored count can be a lower bound (a recount reads at most 1000
  messages), so a lowered count is never below what one scan of at most 1000 remaining messages
  holds. The stored counts of a human who left are dropped; a rejoin recounts from the remaining
  messages. The same op expires pending invites past `expires_at`. Retraction removes the body at once (DO and search).
- DM consent markers (2026-10-04, home-core `consent.ts`): retention deletes `msg` and `msgkey`
  rows, but connection proof (16.7) must outlive the messages. Each human author of a DM has one
  private `consent` row (key = author, `{at}`), written in the commit of their first message
  there. No sweep, retention pass or purge deletes `consent` rows; they go only with the DO
  storage when the conversation itself is deleted. Any commit in a DM that writes or deletes a
  human author's `msgkey` row adds that author's missing marker in the same commit, so a
  retention batch over a DM from before the markers leaves the markers behind (the sweep must
  stay inside the wrapped domain reduce). The table is in `PRIVATE_TABLES` (never in
  subscriber effects).
- Ledger: 7 days (engine default). Events (`own_events`): keep the last 30 days or 10,000 events,
  whichever is more; older resumes take a snapshot (engine need E3).
- Invites: pending ones expire after 14 days; records are kept 90 days, then reduced to counts.
- Addresses: suppression is kept forever (a suppressed address must stay suppressed); the raw
  address is deleted after 180 days without an invite unless suppressed.
- A conversation with no human participant for 30 days deletes its DO storage.

### 10.1 Attachments (feat-cmux-next-home-attachments, revised after the backend lead's review, 2026-10-03)

- Intent: `POST /v1/home/attachments/intent` (current participant; allow list jpeg, png, gif,
  webp, heic, pdf, text/plain, markdown, csv, json, zip, mp4, mov, m4a, mp3, aac, wav; never svg,
  html or xml; 100 MB per file; per user 300 intents and 2 GB declared per rolling day, 10 GB
  stored; 60 intents per minute). It answers `exists` only for a hash the caller can already use
  here, otherwise a single-use slot recorded in the ConversationDO.
- Up to 32 MB the bytes stream through the Worker (`PUT /v1/home/attachments/upload/<conv>/<slot>.<kid>.<mac>`),
  which hashes them. From 32 to 100 MB the client PUTs to a presigned R2 URL (15 min, signs
  `content-length` and `x-amz-checksum-sha256`), then `POST /v1/home/attachments/commit`, which HEADs
  size and checksum. Either way the object is usable only after verification; the recorded etag
  pins downloads to that version.
- Presigned overwrite (answered 2026-10-04): no. The presigned PUT signs `content-length`,
  `x-amz-checksum-sha256` and `if-none-match: *`. R2 refuses bytes that do not match the signed
  checksum, and refuses any PUT to a key that already holds an object (412), so once the bytes are
  there (and so after commit) the URL cannot write again; a client that retries a PUT whose first
  attempt landed gets 412 and calls commit. The header is signed, so the client cannot drop it.
  Downloads also read only the etag recorded at commit. Stream slots are single use through the
  Worker. The conditional PUT against real R2 is still to be checked on staging.
- Video posters: one poster per video, part of the same attachment (never a separate part or
  record). The intent of a video may declare `poster {sha256, byte_count, mime_type}` (image/jpeg
  or image/webp, 2 MB; `attachment.poster_refused` for any other class, 415 for other types, 413
  over the cap). The answer adds `poster_upload {method: PUT, upload_url, headers}`, always through
  the Worker (`PUT /v1/home/attachments/poster/<conv>/<slot>.<kid>.<mac>`), which hashes the bytes
  and stores them at `<object key>.poster`, a key derived from the slot. The poster PUT works once
  while the slot is open; the video's own PUT or commit answers 409 `attachment.poster_missing`
  until it is stored (the slot stays usable). Commit writes `poster {hash, mime_type, byte_count,
  etag}` on the video's record and answers it; the slot's quota charge includes the poster bytes.
  With an `exists` commit the first record wins, also for its poster. Expiry, refusals, the sweep
  and conversation deletion delete the poster key with its object.
- Image previews (Lawrence's decision, 2026-10-04): readers get small image previews through a
  server preview variant, built on the poster machinery (one "derived image" per attachment, its
  variant chosen by class: `poster` for a video, `preview` for an image). The intent of an image
  may declare `preview {sha256, byte_count, mime_type}` (image/jpeg or image/webp, 512 KB,
  `ATTACHMENT_LIMITS.previewMaxBytes`; `attachment.preview_refused` for any other class, so a
  video uses `poster`, never `preview`). The answer adds `preview_upload`
  (`PUT /v1/home/attachments/preview/<conv>/<slot>.<kid>.<mac>`, a token purpose of its own),
  stored at `<object key>.preview`, hash-checked, once while the slot is open; the image's PUT or
  commit answers 409 `attachment.preview_missing` until then. Commit writes `preview {hash,
  mime_type, byte_count, etag}` on the image's record; quota, expiry, refusals, the sweep and
  conversation deletion treat it exactly like a poster. The client makes the preview; the server
  never decodes images. The derived PUT also checks that the slot's own type names the URL's
  variant, behind the per-variant token purpose; a mismatch is 403 and stores nothing.
- First upload wins, including its derived image; a client adopts the stored ref. An intent for a
  hash already recorded here answers `exists` with the stored record as it is: when that record
  has no preview (or poster), the answer has none and no `preview_upload` (`poster_upload`), and
  the preview the new intent declared is dropped. No path attaches a derived image to an existing
  record. The client uses the returned attachment (with or without a preview) as its part's ref.
- Use in messages: `message.send`/`message.edit` accept a hash only when the author uploaded it
  here or a message above the author's history floor references it; every other case is the same
  `unknown_attachment`. A part's `poster` is valid only on a video part and its `preview` only on
  an image part (`invalid_parts` otherwise); each must equal its record's (`attachment_mismatch`).
- Downloads: `POST /v1/home/attachments/url {conversation, hash, message_id?, part_index?, variant?}`
  mints a 10-minute bearer-less URL bound to key id, method, conversation, object id, part,
  variant, actor and expiry; each GET rechecks membership and floor; the file name comes from the
  message part; text is served as `text/plain` attachments, only images inline; out-of-range
  `Range` is 416. `variant: "poster"` signs the poster recorded on the video's record, for a video
  record and, with `message_id`, a video part; `variant: "preview"` signs the preview recorded on
  an image's record, for an image record and part (anything else is 400). Without one it is 404
  `attachment.no_poster` or `attachment.no_preview`, never the original. The GET reads only the
  record's derived key, type, size and etag (nothing from the request) and serves it inline; the
  variant is part of the signature, with the same membership and floor checks.
- No URL carries user content: object and slot ids are random; names stay in message parts.
- Inbox: bumps carry `preview_attachments {kind: photo|video|audio|file, count}` (preview text
  empty for attachment-only messages); clients localize.
- Slots: every slot is charged its declared bytes at intent; its row lives until the alarm deletes
  its object key at expiry (refunding a slot that never committed). An `exists` commit deletes the
  slot's object at once and refunds; a presigned slot that did not keep its object stays a
  tombstone until its URL expires, so a later PUT to the key is deleted too. A presigned URL ends
  exactly at the slot's stored `expires_at`; presigned slots (open or tombstone) and `uploading`
  slots are reaped only one hour (`UPLOADING_GRACE_MS`) after it, because S3 checks expiry only when
  a PUT starts: one hour covers a 100 MB PUT down to about 230 kbit/s.
- Retention: `attref` rows are written in each message's commit; the ConversationDO alarm sweeps
  uploads unreferenced for 24 h in batches with a persistent (created_at, hash) cursor (a long run
  of referenced records costs one pass, never a hot loop) and releases the uploader's stored bytes.
  A batch holds a `running` mark until `markSwept`, so a retract or edit that lands while the batch
  awaits its R2 delete queues another pass (due at once) instead of being cleared. Hooks for paths that do
  not exist yet: `messageDeleteWrites` (message retention) and `ConversationDO.deleteAttachmentStorage`
  (conversation storage deletion; it drops open slots, so it schedules a second prefix delete at
  the latest dropped slot's expiry plus `UPLOADING_GRACE_MS`, which removes a late presigned PUT). Attachments in `conversation.import` remain C-13.

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
  `read-cursor`, `conversation`, `typing`, `invite`). Typing is the non-op frame
  `{t: "typing", on, conversation?}` in and `{t: "conversation-typing", conversation, participant,
  on}` out (home-core `typingGate` limits it per participant; never stored).
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

Built so far (2026-10-03, branch feat-cmux-next-home-reach): until pair state exists, "connected"
means a DM where both are current participants and both gave consent (both sent a message there,
or one accepted the other's one-to-one invite). "Both sent a message" is read from the DM's
private consent markers (section 10), not from message rows, so a connection survives
retention; a DM from before the markers falls back to its `msgkey` rows while they exist. The setting is `allow_requests_from:
anyone|teams|nobody` plus `email_requests` (R2, default on, stored only); `allow_dm_from` is
gone (section 16.10).

### 16.8 Migration from today

`memberships.role` today is owner, admin or member; add `guest` and `billing` (expand
migration). Existing team members keep their roles. No relationships exist yet; the first DM
between two existing org members creates their relationship only when both send a message
(implicit consent), so org departures do not erase working DMs.

### 16.9 Decisions (Lawrence, 2026-10-02)

- R1: the three primitives are accepted: Contacts (relationships), Grants, and Team with the roles guest, member, admin, owner and billing. The product and code keep the name "Team" (`team_` ids); "org" in this section only separates it from relationships.
- R2: message requests from unrelated users show in Home AND send an email (on by default; the recipient can turn email off in `home.settings.set {email_requests}`).
- R3: the address owner is `AddressDO`, participants `addr_<26>`, secret `HOME_ADDRESS_KEY` (backend and home-core renamed).

### 16.10 Reach decisions (coordinator, 2026-10-03)

1. Names are the 16.7 ones: `home.settings.set {allow_requests_from: anyone|teams|nobody,
   email_requests}`. `allow_dm_from` is removed everywhere; `nobody` refuses all new reach.
2. A shared group is no connection (16.3 stands).
3. Interim rule, until message requests (16.4) exist: `anyone` reaches only people who share a
   team with the caller or are connected to them; a stranger gets `not_reachable`, the same
   answer as an unknown account. Target: a stranger's DM or add becomes a message request.
4. The setting limits group adds too (`conversation.create` and `participants.add`): only people
   the caller can reach are added; the client offers an invite (later a request) for the others.
5. Defaults: `allow_requests_from: anyone`, `discoverable_by_email: false`,
   `discoverable_by_phone: false`.
6. A chief adds the humans its owner could add, acting under its owner's reach: the Worker
   resolves the reach facts for the chief's `owner_user` (the owner's teams, the owner's
   connections, the target's setting checked against the owner) after the owner's UserDO
   confirms the agent is one of the owner's active chiefs. Any other agent caller gets no facts,
   so a cloud owner never re-adds a departed human through the stored record for an agent.
   The owner's UserDO checks the agent class explicitly: only class `mux` (a chief) qualifies;
   an automation run principal that carries a chief's id gets no facts. A chief never opens a
   DM (DMs are between humans).
7. Backend owner, 2026-10-04: a connected pair needs no request under `anyone` and `teams`, also
   without a shared team (16.3). Under `nobody` the pair's existing DM keeps working (`dm.open`
   reuses it), but a new group add by the contact or the contact's chief is refused.
8. Rate limits before reach (section 9): `conversation.create` 60 per hour, `participants.add`
   120 per hour, `home.rate_limited` with `retry_after_ms`.
9. Follow-up, NOT built: the message-request path. There is no pending-request store, no
   `relation.request` / accept / decline ops, and `email_requests` is stored by
   `home.settings.set` but never read (no email is sent). Until it exists a stranger under
   `anyone` is refused `not_reachable`, the same as under `teams`; so today `anyone` and `teams`
   behave the same. Needed: the pair owner (16.7) holds `requested` state, the recipient's UserDO
   lists requests in Home, accept makes the pair connected, decline and block are silent to the
   sender, and the request email honors `email_requests` and the section 9 windows.

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
  Decided (Lawrence, 2026-10-02) and built (`mux/text-confirm.ts`): an in-app confirmation for
  destructive or irreversible actions requested by text.
  Rule `needsConfirmation(level)` (levels decided 2026-10-02, `mux/confirm-level.ts`), one level
  per user (UserDO, section 21), read by every chief as `chiefLevelOf`:
  - `strict` (default): text requests that are `destructive`, `money`, `send-external` or
    `access` (grants, installs, addresses, tokens, team invites, the text channel), or flagged
    irreversible;
  - `destructive-only`: `destructive` or flagged irreversible only;
  - `off`: no confirmation.
  A safer level applies at once; a riskier level needs Face ID or the device passcode and a
  device proof the server checks; a team or MDM lock is a minimum (one slot per source, shown as
  "Locked by <name>"; it can raise the level, never lower it); every change is audited and every lowering is announced to all of
  the owner's devices and by email. Details and the client contract: section 21. The former
  per-chief ops `mux.text_confirm.level.set|confirm|lock` are removed; per-chief values migrate
  to the safest.
  Settings copy (en; all 21 locales in `home-core/copy/text-confirm-levels.json`, ja written by
  the agent, other locales `needs_review`):
  - title: "Confirm risky actions asked by text"
  - strict: "Strict (recommended): when a text asks Chief to delete something, spend money, send
    something outside cmux, change who has access or do anything that cannot be undone, you
    confirm it in the app first."
  - destructiveOnly: "Destructive only: you confirm deletions and actions that cannot be undone.
    Chief may spend money, send messages and change access from a text without asking you."
  - off: "Off: Chief does everything a text asks without asking you."
  - simSwapRisk (shown under every level): "Anyone who takes control of your phone number (a
    stolen phone, a SIM swap or a recycled number) can text Chief as you. The less you confirm,
    the more that person can do."
  - raiseTitle, raiseBody, raiseConfirm (the second dialog): "Lower your protection?" / "With
    this level, a person who takes over your phone number can do more as you. Continue only if
    you accept that risk." / "Lower protection"
  - lockedBy: "Locked by {name}"
  - notices (feed and email): level.strict / level.destructiveOnly / level.off; lowered.title
    "Text protection lowered", lowered.body "Confirmation for texts to Chief changed from {from}
    to {to}. If you did not do this, open cmux on a trusted device and set it back to Strict.";
    keyAdded.title and keyAdded.body for a new presence key.
  Confirmation requests, MuxDO ops (idempotency keys from the caller): `mux.confirm.request {op, params_hash, risk, summary, source}` by the chief
  (row in table `confirm`, at most 64 rows and 20 live pending); `mux.confirm.decide {confirm,
  approve}` only by the owner's session or Mac, iPhone or web app install acting for no agent,
  with origin `user` (never a text, a daemon or CLI install, the chief or another user);
  `mux.confirm.consume {confirm, op, params_hash}` by the chief, once, for exactly the approved
  op and params, all within 15 minutes of the request. Executor contract: the action's
  idempotency key derives from the confirm id. Gap: the chief writes both the summary and the
  params hash; the approval card must render the action from the op and params, not only the
  summary. The adapter posts the request as an `approval` part in the chief
  conversation and pushes it to the owner's devices.

Decisions (Lawrence, 2026-10-02): T1 a texted Stack sign-in link (above), not reverse
verification; T2 texts land in the main chief conversation marked `via: sms`; T3 full Chief
authority by default with a per-user restriction setting. Invite card: the minimal design is the
default (`?v=` keeps the others), `?s=square` renders 1200x1200.

## 20. One op vocabulary: reconciling home-core with `cmux-conversation`

Contract: `backend/packages/home-core/conformance/conversation-cases.json` (73 cases) is the
op-level contract both owners run, and a REQUIRED check for the Rust owner (decision
2026-10-02). Every head now carries `agent_text_streak` and `last_agent_text_at` (local heads
too); the cases named "loop guard:" are the work-card bypass that a row window misses.
`conversation-search-cases.json` (12 cases) is the contract for `conversation-search {query,
limit 1-100} -> {hits: [{conversation, title, seq, message_id, author, created_at, snippet}]}`
(read model `searchConversations`: current participants only, `since_join` honored, retracted
messages never match, case-insensitive substring per code point, newest first, snippets of 120
characters centered on the match); the cloud `home.search` returns the same hit shape. `conversation-cloud-cases.json` (84) covers cloud-only rules.
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
| 6 | Agent budget | window of the newest 5 rows; text-less work cards fill the window, so two agents can loop forever with work cards | head counters `agent_text_streak`, `last_agent_text_at`, O(1), in every head | Decided: Rust adopts the head counters; the local corpus now requires them |
| 7 | Typing | `conversation-typing` command, ephemeral event | ConversationDO memory broadcast | One non-op frame `typing {conversation, on}` and event `conversation-typing` on both; never stored, not in the corpus |
| 8 | Agent identity | `conversation-agent-token` + `conversation-bind` (local token) | principal from the Worker (agent token, grant) | Transport auth, not ops; stays local-only; not in the corpus |
| 9 | Participants | `user_local`, `user_<id>`, `agent_<name>` | plus `addr_<26>` (kind `address`), roles, `joined_seq`, `left_at` | Local stays a subset; `conversation.promote` maps `user_local` to the account's `user_<id>` |
| 10 | Message ids | ULID `msg_<26>` | engine `newId("msg")` | Both accept any `msg_` id; the corpus passes `new_message_id` |
| 11 | Events | `conversation-changed {rev, transaction, change}` | engine event `{seq, tx, op, params, effects}` | Clients map both to the corpus `Change`; ConversationDO also returns `change` in the op result |
| 12 | Summary owner | `"local"` | `"cloud"` | Keep; the client shows "this Mac only" for local |

## 21. Lowering the text confirmation level: per user, with a server-checked device proof

Decisions (Lawrence, 2026-10-02): the level is stored once per user in UserDO and every chief
reads it; lowering it needs Face ID or the device passcode AND a device proof the server checks;
every owner device and the owner's email are told. Code: `home-core/src/user/` (owner logic,
proofs, notices) and `home-core/src/mux/level-projection.ts` (each chief's copy).

Owner and ops (UserDO delegates to `reduceUserConfirm`; UserDO passes the user, `installActive`,
the user's chiefs and the locale):

| Op | Caller | Effect |
| --- | --- | --- |
| `user.text_confirm.level.set {level}` | owner's app (session or mac/ios/web install, no agent), origin `user` | safer: applies; riskier: `text_confirm.proof_required`; locked: no-op on the locked level, else `text_confirm.locked` |
| `user.text_confirm.lower.challenge {level}` | owner's mac or ios install with an active presence key past its 24 h cooldown, origin `user` | returns `{sign: {op: "user.text_confirm.lower", user, install, new_level, nonce, expires_at}, message}` (`message` = the exact bytes to sign, base64url); 2 minutes; one live nonce per install |
| `user.text_confirm.lower {level, nonce, presence_sig, app_attest?}` | the same install, origin `user` | spends the nonce on any attempt; checks install, level, expiry, active key, lock, still riskier, the presence signature and (iOS) the App Attest assertion with a growing counter; applies, audits, syncs every chief, notifies |
| `user.text_confirm.lock {level or null, by: team_policy or mdm, name}` | system (Worker, from TeamPolicy or MDM) | one slot per source; a lock is a minimum: it raises the user's own level to at least its level (ratchet) and caps how far the owner can lower; it never makes the level riskier; unlock never lowers |
| `user.text_confirm.migrate {level}` | system, only `system:mux:<agent>` of one of this user's chiefs | an unset level reads as strict, so migration never lowers; a user who had chiefs at off lowers again with a proof |
| `user.presence_key.register {install, jwk, platform, app_attest?}` | system (Worker, after its checks below) | the platform must equal the install's registered kind; stores the key; usable after 24 h; notifies every device and email |
| `user.presence_key.revoke {install}` | owner's app, or system (`install.revoke`, device loss) | key unusable at once; its nonces dropped |
| `mux.text_confirm.level.sync {level, rev}` | only the owner's UserDO (`system:user:<user>`) | each chief keeps the newest rev; `chiefLevelOf` feeds `needsConfirmation` |
| `mux.text_confirm.migrate {}` | system (one maintenance pass per chief) | sends the chief's former level to UserDO once |

Device keys (presence keys):
- One per device install, separate from the install's token key: a Secure Enclave P-256 key
  created with an access control that requires user presence (Face ID, Touch ID or the device
  passcode), so it cannot sign without the person.
- Registration: the app calls a Worker route with its install token. macOS: the Worker checks
  that the install is active and that the install key signed the registration. iOS: the app also
  creates an App Attest key and sends the attestation (client data = the presence key's
  thumbprint); the Worker verifies Apple's certificate chain, the app id and the counter, then
  commits `user.presence_key.register` with the attested key. Owner: UserDO; principal: the
  install.
- Revocation: `install.revoke` (device lost, remote sign-out) also commits
  `user.presence_key.revoke`; the domain also refuses when UserDO says the install is no longer
  active. A new key is unusable for 24 hours and every device and the email are told, so a key
  added by an intruder (a stolen install token) can be removed before it works.
- iOS sends both proofs: App Attest proves the genuine app on a genuine device but not Face ID;
  the presence signature proves a person unlocked the key.

Presence-key registration route (built, backend lead, 2026-10-03):
- `POST /v1/presence-key` with the install's own `Authorization: Bearer <install token>`.
  Body: `{platform: "mac" | "ios", jwk, signature, attestation?, key_id?}`.
- `jwk`: the presence key's P-256 public JWK (`kty`, `crv`, `x`, `y`).
- `signature`: the install key (the token key, not the presence key) signs the UTF-8 string
  `cmux-presence-key-v1\n<environment>\n<user>\n<install>\n<thumbprint>` with ES256; raw
  r||s or DER; base64url. `environment` is the Worker ENVIRONMENT (`production`, `staging`,
  `development`); `thumbprint` is the RFC 7638 thumbprint of `jwk`. Required on both platforms,
  so a stolen bearer token alone cannot replace the key.
- iOS also: `attestation` (base64url CBOR attestation object from App Attest) and `key_id` (the
  App Attest key id, base64). The attestation's client data is the thumbprint string
  (clientDataHash = sha256(thumbprint)). The Worker checks the chain to Apple's App Attestation
  root, the nonce, the key id, the app id `IOS_APP_ID` (production `7WLXT3NR37.com.cmux.app`,
  staging/development `7WLXT3NR37.dev.cmux.ios` with development keys allowed), counter 0 and
  the AAGUID.
- Answer: `{ok: true, value: {install, usable_from}}` (usable 24 h later) or
  `{ok: false, error: {code, message}}` (403 for a refused signature or attestation).
- Owner devices only: the install's registered kind must equal `platform`; sessions and agents
  are refused.

Client contract (iOS lane and the Mac Home lead):
1. Settings shows the three levels with the section 19 copy, and the lock line when locked.
2. A safer level: `user.text_confirm.level.set {level}`.
3. A riskier level: show the raise dialog (raiseTitle, raiseBody, raiseConfirm), then call
   `user.text_confirm.lower.challenge {level}`; sign the returned `message` bytes as they are
   (never re-encode the JSON) with the presence key (the system Face ID or passcode prompt;
   ES256; raw r||s, exactly 64 bytes; base64url); on iOS also generate an App Attest assertion
   with clientDataHash = sha256 of the same bytes; send `user.text_confirm.lower
   {level, nonce, presence_sig, app_attest?}` with a fresh idempotency key; read
   `value.lowered` (a refused proof commits with `lowered: false` and a code).
4. First run on a device: create and register the presence key (backend route); say that
   lowering works after 24 hours.

Backend lead (through the coordinator): the UserDO domain delegates the `user.text_confirm.*` and
`user.presence_key.*` ops and keeps `UserConfirmState`; the MuxDO wire route resolves
`install_kind`; the registration route verifies App Attest attestations; `install.revoke`
revokes the presence key; one `mux.text_confirm.migrate` pass per existing chief; a mail path for
outbox items `mail.security_notice` (target class `MailerDO`, which does not exist yet); the feed
accepts `feed.post` notices from UserDO.

Residual risks: a person with the phone and its passcode can still lower the level (the proof
cannot tell the owner from someone who knows the passcode); the notices make it visible. On
macOS there is no key attestation: the server cannot prove the presence key lives in the Secure
Enclave with a presence requirement, so a stolen install key plus a modified client could
register a software key, which works after the 24 h cooldown unless the owner acts on the
notice. `origin: user` is claimed by the client and is not a control; the device proof is. The
per-chief MDM or team locks of the old design are not carried by `mux.text_confirm.migrate`
(only their level); the Worker must push the locks to UserDO again before the migrate pass.
DECISION: may a team or MDM lock make the level riskier (force `off`), or only set a minimum?
RECOMMEND only a minimum (built), because otherwise a team admin can turn protection off without
the owner's device.
node:crypto `createPublicKey` and `verify` inside workerd, and the App Attest attestation check,
are UNVERIFIED until the backend lead runs them in the Worker.

## 22. Promoting a Mac conversation: `conversation.import` (2026-10-03)

For chief-mac.md P1 (`conversation.promote`); shape proposed by the backend lead, built in
`home-core/src/conversation/import.ts`, corpus `conformance/conversation-import-cases.json`.
- Owner: ConversationDO; caller: the promoting user (session or app install, never an agent).
- Id: `importConversationId(user, source.host, source.local_id)` (`conv_` + sha256 base32), so an
  import only creates its own object; the Worker computes it from the signed-in user and routes
  the first call there (never from a client field) and adds `conversation.import` to the ops the
  conversation socket refuses.
- First call `{id, source {kind mac, host, local_id}, kind group|chief, title?, participants,
  messages, read_cursors?}` creates state `importing`; `{id, after_seq, messages}` continues the
  dense seq; `conversation.import.commit {id, last_seq}` opens normal ops. Before commit every
  other op is refused (`importing`). Same source repeated: no-op returning `last_seq`; anything
  else on an existing id: `conversation_exists`.
- Participants: the importer as the only human, and agents the DO's reach policy says the
  importer owns (owner and names stamped by the policy; the default policy refuses agents, so
  ConversationDO must inject an owner-record policy before chief imports work). `chief` = the
  owner and one owned `mux` agent. A local `user_local` must be mapped to the account's
  `user_<id>` by the Mac before the call.
- Messages: at most 500 and 1 MiB per batch; validated like `message.send`; ids, authors,
  times, edits, retractions and reactions kept; times never go backwards or into the future;
  replies point to earlier messages. Rows `msg` and `msgkey` (per author, so a later send with
  the same author and client id is a conflict, as in the Rust owner's actor-keyed ledger).
- The loop guard counters follow the imported history (retracted agent texts count); read
  cursors are clamped to `last_seq` at commit. The engine ledger has no entries for imported
  messages (the Mac's op ledger stays on the Mac).
- Outbox: search rows per batch; one inbox bump per human at commit; no chief wakes for history.
- The Rust owner is the source side only (the local conversation becomes read-only with a
  pointer, home.md section 5); it never runs these cases.
