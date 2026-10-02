# cmux-next Home messaging backend: conversations, inbox, chiefs, search, invites

Status: proposal, first cut 2026-10-02 (lane 15, Home messaging backend). Spec proposal:
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
- Contact: an email address or phone number that is not (yet) linked to a cmux user. A contact can
  be invited; it cannot act.

## 2. Entities and fields

Ids are owner-assigned and never reused. `<26>` = 26 Crockford base32 characters (ULID layout
from `cmux-conversation::encode_id` unless stated).

| Entity | Id | Fields |
| --- | --- | --- |
| Conversation head | `conv_<26>` (group, chief); `conv_dm_<26>` = base32(sha256("dm\0" + lo + "\0" + hi))[0..26] where lo/hi are the two sorted participant ids (a user id or a contact id) | `kind`, `title`, `team?` (the team whose policy applies; null for personal), `created_by`, `created_at`, `updated_at`, `last_seq`, `rev`, `participants[]`, `invites[]`, `settings {wake_policy, agent_budget {turns, gap_ms}, history_visible: "all"|"since_join"}`, `retention_days?` (from team policy), `state: "active"|"archived"` |
| Participant | `user_<id>`, `agent_<id>`, `contact_<26>` | `kind: human|agent|contact`, `display_name`, `agent_class?: mux|agent`, `owner_user?` (agents), `role: owner|member`, `joined_seq` (last_seq when added), `added_by`, `left_at?` |
| Message | `msg_<26>`, `seq` dense per conversation | `client_msg_id`, `author`, `parts[]` (text with runs/mentions, `work`, `approval`, `attachment {hash, mime, size, name}`, refs `task`/`vm`/`pr`), `reply_to? {message_id, part_index}`, `thread_root?`, `created_at`, `edited_at?`, `retracted_at?`, `reactions[] {author, part_index, kind, at}` |
| Read cursor | (conversation, participant) | `last_read_seq` (monotonic, written only by that participant) |
| Invite | `inv_<26>` inside its conversation | `contact` (`contact_<26>`), `channel: email|sms`, `display_name`, `invited_by`, `created_at`, `expires_at` (14 days), `token_hash` (sha256 of the 128-bit secret), `status: pending|accepted|revoked|expired`, `accepted_by?`, `accepted_at?`, `delivery {state: queued|sent|delivered|bounced|complained|failed|suppressed|refused_env, provider_id?, at}`, `copy_variant`, `locale` |
| Inbox entry | (user, conversation) | owner-projected (from ConversationDO, guarded by conversation `rev`): `kind`, `title`, `last_seq`, `last_at`, `preview` (240 chars, author + text), `unread` (count after the user's cursor, excluding own messages), `mentions` (unread mentions of the user), `dm_peer?`, `rev`; user-owned: `pinned`, `pin_position`, `muted_until?`, `archived`, `marked_unread` |
| Chief record | `agent_<26>` | `owner_user`, `team?`, `name`, `avatar?`, `parent?` (subchief), `brain: local|cloud`, `brain_host?` (host id for local), `thread` (its `chief` conversation), `reachability: owner|team|shared` (who may DM it), `grant` (grant id, identity spec 4), `archived_at?` |
| Contact | `contact_<26>` = base32(HMAC-SHA256(`HOME_CONTACT_KEY`, normalized address))[0..26] | `channel`, `address` (normalized: lowercase email with IDNA host; E.164 phone), `linked_user?`, `suppression? {reason: opted_out|bounced|complained|reported|admin, at}`, rate windows (section 9), delivery ledger |

Normalization: email = trim, lowercase, IDNA host, no plus-stripping (a different mailbox for some
providers). Phone = E.164 via libphonenumber rules with the inviter's region as default; only
mobile numbers in allowed countries (OPEN: start with US and Canada, the SMS/iMessage provider's
coverage).

## 3. Owners

| Entity | Owner | Stream | Notes |
| --- | --- | --- | --- |
| Conversation head, participants, messages, reactions, edits, retractions, read cursors, invites | `ConversationDO`, one per conversation (`idFromName(conversation id)`) | `conv:<id>` | single writer; same reducer rules as `cmux-conversation`; message rows in DO SQLite tables, not in the JSON state blob (section 12, engine need E1) |
| Inbox entries, pins, mutes, archive, unread totals, push queue | `UserDO` of that user | `inbox:<user>` (a second stream in the same object, E2) | conversation-owned fields are a projection guarded by `rev`; user-owned fields are written only by the user |
| Chief records and their grants (personal) | `UserDO` | `user:<user>` | identity spec 2 and 4; team chiefs in `TeamDO` later |
| Chief wake queue and cloud brain loop | `MuxDO`, one per chief | `mux:<agent>` | every chief has one; a local brain host subscribes to it over the gateway instead of the cloud loop running |
| Team membership, who may message whom inside a team, team Home policy | `TeamDO` | `team:<team>` | existing directory; adds `home.*` policy keys (section 10) |
| Contact state: address, suppression, per-recipient limits, delivery ledger | `ContactDO`, one per contact | `contact:<id>` (no client subscribers) | holds the only copy of the raw address; external sends happen here, after the invite commit |
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
| `dm.open` | `{peer: user_id | {email}|{phone}}` | client key; id is deterministic (section 2) | session, install | idempotent by id; a peer address resolves to a user (if discoverable, OPEN D-H3) or to a contact plus an implicit `invite.create` |
| `message.send` | `{client_msg_id, parts, reply_to?, thread_root?}` | must equal `client_msg_id` | participants (human, chief) | `cmux-conversation` rules; agent turn budget; contacts cannot send |
| `message.edit` / `message.retract` | `{message_id, parts}` / `{message_id}` | client key | author | not after retraction; retraction clears parts and reactions and removes the search row |
| `reaction.add` / `reaction.remove` | `{message_id, part_index, reaction}` | client key | participants | one per (author, part, kind) |
| `read_cursor.set` | `{seq}` | client key (`read:<seq>` recommended) | humans | monotonic, `<= last_seq` |
| `title.set` | `{title}` | client key | members (group) | not for `dm`, `chief` |
| `participants.add` | `{participant: user or chief}` | client key | members | a human may be added only when they share a team with the adder or already share a conversation with them; anyone else needs `invite.create`. A chief may be added by its owner, or by anyone when its `reachability` allows. Max 64 |
| `participants.remove` | `{participant}` | client key | self (leave), conversation owner, chief owner (for their chief) | removing the last human archives the conversation |
| `invite.create` | `{invite_id, contact, channel, display_name, locale, copy_variant}` | `invite_id` (the Worker derives it from the client key) | members | Worker first runs `contact.ensure` and `invite.quota.take`; commit emits outbox `contact.deliver` (send happens after commit); max 20 pending invites per conversation |
| `invite.revoke` | `{invite_id}` | client key | inviter, conversation owner | pending only |
| `invite.accept` | `{secret}` | client key | session (any signed-in user) | finds the invite by `token_hash`; pending and not expired; replaces the contact participant with the user in one commit (`participants.bind`), records `accepted_by`; email invites need the account's verified email to match or the inviter's approval (OPEN D-H4) |
| `invite.preview` (read) | `{secret}` | n/a | link | inviter name, conversation kind, first message preview (trusted inviters only, section 9); rate limited per conversation and IP |
| `invite.delivery.report` | `{invite_id, delivery}` | `delivery:<invite>:<state>` | system (ContactDO) | delivery state only moves forward |
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

### 4.3 MuxDO, TeamDO, ContactDO

| Op | Owner | Callers | Notes |
| --- | --- | --- | --- |
| `mux.wake` `{conversation, seq, reason: dm|mention|reply|owner}` | MuxDO | system (ConversationDO outbox, key `wake:<conv>:<seq>`) | queues an inbox item; the cloud brain consumes it, or a subscribed local brain host acks it |
| `mux.ack` `{conversation, seq}` | MuxDO | chief (its brain host) | moves the chief's catch-up cursor |
| `mux.configure` `{brain, brain_host?}` | MuxDO | session (owner) | |
| `team.policy` keys `home.external_invites`, `home.retention_days`, `home.max_group` | TeamDO | team admin | via the enterprise lead's TeamPolicy (#16774) |
| `contact.ensure` `{address}` | ContactDO | system (Worker) | stores the normalized address; returns `{contact, linked_user?, suppressed}` |
| `contact.deliver` `{invite, conversation, channel, rendered}` | ContactDO | system (ConversationDO outbox) | external effect with its own ledger (ConnectionDO pattern: `mutation.indeterminate` when the provider call's outcome is unknown); checks suppression, per-recipient windows and the environment send policy before the provider call |
| `contact.suppress` `{reason}` | ContactDO | system (provider webhooks, unsubscribe link) | |
| `contact.unsuppress` | ContactDO | session whose verified address is this contact | |

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
2. Worker: normalize, `contact.ensure` on ContactDO (refuses suppressed contacts with the same
   answer as success to the inviter, so suppression does not leak), `invite.quota.take` on the
   inviter's UserDO, then the op on ConversationDO.
3. ConversationDO commits the invite (contact participant + invite record), then its outbox sends
   `contact.deliver` to ContactDO with the rendered copy.
4. ContactDO checks suppression, per-recipient windows and the environment policy (staging sends
   only to the private allow list, refused before the provider call), sends through the provider
   with the invite id as the provider idempotency key, records the result and reports
   `invite.delivery.report`.
5. Recipient opens `https://cmux.com/i/<g|d><26-char conversation suffix>#<26-char secret>`
   (OPEN D-H1 for the domain). The secret is in the fragment, so it never reaches server logs or
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
  kind            text NOT NULL CHECK (kind IN ('human', 'agent', 'contact')),
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
  contact_id     text NOT NULL,                 -- HMAC id, never the address
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
CREATE INDEX home_invites_contact ON home_invites (contact_id, created_at DESC);
```

Outbox kinds (drain statements in `projection.ts`): `home.conversation.upsert`,
`home.participant.upsert`, `home.message.upsert`, `home.message.delete`, `home.invite.upsert`.
A retraction or retention delete sends `home.message.delete`; an edit sends an upsert with the
new body. No raw address, token or token hash is ever projected.

## 8. Search (Home messages only)

- Scope: messages of conversations where the caller is a current human participant, at or after
  `visible_from_seq`. Chiefs search through their owner's grant only when the op is in their
  grant (`read` class); contacts never search.
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
- Self-hosted servers use the same SQL on their own Postgres (SV2), without partitions.

## 9. Invites: limits and abuse controls

- Per inviter (UserDO windows): 20 per day, 60 per week; accounts younger than 24 h or without a
  verified email: 5 per day and no custom text in the invite. Team admins may raise limits for
  their team (TeamDO policy).
- Per contact (ContactDO): at most 1 invite per inviter per 7 days (a repeat attaches to the
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
- Environment send policy (in code, ContactDO, before any provider call): production sends to
  anyone not suppressed; staging, development and previews send only to addresses in the private
  allow list loaded at runtime from secret storage (never in the repository), and refuse every
  other recipient with `delivery.state = refused_env` and no provider call. A global kill switch
  (`HOME_INVITES_SEND=off`) refuses everything.
- Every email has a one-click unsubscribe (List-Unsubscribe and List-Unsubscribe-Post headers)
  and a "report spam" link; every first SMS to a number says how to stop (OPEN D-H5).

## 10. Retention

- Messages: kept until the team policy `home.retention_days` (minimum 30) or user deletion;
  default keep. The ConversationDO alarm deletes expired message rows in batches and emits
  `home.message.delete` projection rows. Retraction removes the body at once (DO and search).
- Ledger: 7 days (engine default). Events (`own_events`): keep the last 30 days or 10,000 events,
  whichever is more; older resumes take a snapshot (engine need E3).
- Invites: pending ones expire after 14 days; records are kept 90 days, then reduced to counts.
- Contacts: suppression is kept forever (a suppressed address must stay suppressed); the raw
  address is deleted after 180 days without an invite unless suppressed.
- A conversation with no human participant for 30 days deletes its DO storage.

## 11. Self-hosted implementation (cmux server, team VM)

- The `cmux` daemon on a server (SV1) hosts the conversation owner from `cmux-conversation`
  (Rust), the same crate the Mac uses for local-only conversations, extended with the cloud
  fields (kinds, contacts, invites, settings) behind the same reducer rules. State in the
  daemon's SQLite file; search with SQLite FTS5 (or the server's Postgres, SV2, OPEN D-H6).
- Protocol: the server speaks `cmux.wire/1` (the same op, result, reject, request-settled,
  event and snapshot frames and the same op names and params as the cloud) over its authenticated
  WireGuard listener; the Mac app and iOS use one client with two transports.
- Conformance: one JSON corpus of reducer cases (`backend/packages/home-core/conformance/`) that
  both `home-core` (vitest) and `cmux-conversation` (cargo test, on a testbox) must pass.
- What a server cannot do alone: push (APNs keys stay with cmux) and invites (provider keys and
  the suppression list stay central). A server calls the cloud relay ops `push.relay` and
  `invite.relay` with its host install token; the cloud applies the same limits and suppression.

## 12. Needs from the backend lead (engine and infra)

- E1. Row-backed domains: `OwnerEngine` stores the whole state as one JSON row. A conversation
  needs message rows in tables: let a domain return row writes (upserts and deletes on its own
  tables) committed in the same transaction as the ledger, events and outbox, and let `reduce`
  read rows through a read-only handle.
- E2. Two streams in UserDO (`user:` and `inbox:`) or a separate engine instance per stream in one
  object.
- E3. Event log retention (prune `own_events` by age and count; resume falls back to a snapshot).
- E4. DO-to-DO outbox items (kind with a target class and name) drained by RPC, at-least-once,
  next to the Postgres drain.
- E5. A `cmux.wire/1` path for the conversation socket and the inbox stream through the UserDO
  gateway, with ticketed subscription to a ConversationDO.
- E6. Secrets per environment: `HOME_CONTACT_KEY` (HMAC), `RESEND_API_KEY`, `SENDBLUE_*`,
  `HOME_INVITE_ALLOWLIST` (staging, development, previews only); Cloudflare rate limiting bindings.

## 13. Client API (iOS and Mac)

- HTTP: `POST /v1/ops` (every mutation above), `POST /v1/read` (`inbox.list`,
  `conversation.snapshot`, `conversation.history`, `home.search`, `invite.preview`),
  `POST /v1/invites/accept` (thin alias for the web landing page).
- WebSocket `cmux.wire/1`: the UserDO gateway carries `inbox:<user>` (inbox events: bump, pin,
  mute, archive) and the chief wake stream for brain hosts; the open conversation subscribes to
  `conv:<id>` (snapshot with `tail`, resume with `after_seq`, events `message`, `message-updated`,
  `read-cursor`, `conversation`, `typing`, `invite`).
- Generated clients: the TS client in `clients/ts/cloud` and the Swift client from the same
  catalog; the Swift Home client keeps the mirror + intent log from home.md section 3.

## 14. Open items (DECISION lines in the lane report)

- D-H1 invite link domain (`cmux.com/i/…` recommended).
- D-H2 reducer language for the cloud (TypeScript `home-core` plus the shared conformance corpus
  recommended; alternative: `cmux-conversation` compiled to WebAssembly inside the DO).
- D-H3 email and phone discovery (who can find you by address).
- D-H4 binding an email invite to the accepting account's verified email.
- D-H5 SMS opt-out wording and the allowed countries.
- D-H6 self-hosted search store (SQLite FTS5 or the server's Postgres).
- D-H7 history visibility for new group members (`all` recommended).
- D-H8 invite copy variant (section 15, next revision).
