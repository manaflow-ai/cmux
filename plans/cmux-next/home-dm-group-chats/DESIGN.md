# Home group chats at any size, by capability (2026-10-19)

Ask (Lawrence, u2548): group chats first; they scale without limit and are secure. One Durable
Object per chat, one per user for the inbox, no message copies fanned out to members, access by
revocable and attenuable capabilities checked in the chat's DO, hibernatable sockets, log-cursor
pagination, very large chats archive old log segments. One model for families, two founders,
startups and enterprises. Builds on `plans/cmux-next/home-messaging.md` (the conversation model)
and `plans/cmux-next/home-messaging-invites/DESIGN.md` (a111: message requests, same-domain
trust, email reach), and replaces neither.

## 0. What exists, and the two costs that stop it scaling

Today (feat-cmux-next f1566d56be9) a chat is a `ConversationDO` (home-core reducer, row mode),
each person has a `UserDO` inbox, and members are checked in the chat's DO (a leaked chat id
gives nothing). Sockets use the hibernation API. Messages are SQLite rows paged by `seq`.
Two things are O(members) on every message:

1. **The head.** Members (`participants[]`) and every read cursor live in the head, one JSON row
   rewritten on each commit and copied into each event's `effects` (2 MB cap, so roughly 10k
   members is a hard wall, and a 5k-member chat writes ~1.5 MB per message, twice).
2. **The fan-out.** Each commit puts one `inbox.bump` per human member in the outbox and updates
   one `unread` row per member: 10k members = 10k DO-to-DO calls and 10k writes per message.

Everything else (ids, ledger, idempotency, events, history, typing, invites, requests) is kept.

## 1. Model

### 1.1 Objects

| Object | Key | Holds | Per message |
|---|---|---|---|
| `ConversationDO` (the chat) | conversation id | head (bounded), member rows, grant rows, the ordered log, read cursors, typing (memory) | 1 message row, head, 1 event, 1 heads item (large tier), k mention bumps |
| `UserDO` (the person) | user id | inbox entries (pointers + own state: pin, mute, archive, read seq), push queue, blocks | 0 for large chats unless mentioned |
| `ChatHeadsDO` (new, 1024 shards) | `heads:<sha256(conv) mod 1024>` | per chat `{kind, title, last_seq, last_at, preview, rev}` | ≤ 1 coalesced write per chat per second |
| `TeamDO` (space) | team id | members, roles, policy (retention, external, default visibility), parent team | 0 |
| `AddressDO` | address hmac | email/phone owner link, invite ledger, suppression | 0 |
| R2 `home-archive` (later) | `conv/<id>/seg/<from>-<to>` | sealed log segments past the hot window | 0 |

### 1.2 Two tiers, one model

A chat starts **inline** (≤ 256 members): everything as today, exact unread and mention counts
pushed to each member's inbox. Adding the 257th member converts it, once and forever, to
**large**:

- Members move to rows (`mem` table). The head keeps `member_count` and a bounded **roster**
  (owners, admins and the 64 most recent authors) so clients still name speakers without a
  members read; `members.list` pages the rest by id cursor.
- Read cursors move to rows (`cur` table); the head keeps only the roster's.
- A message writes the same rows as in a 3-person chat. Instead of a bump per member, it puts
  one coalesced `heads.publish` in the outbox (the chat's row in its `ChatHeadsDO` shard) and
  bumps only the people it mentions (≤ 64; `@everyone` is an admin right and sets a head flag
  rather than bumping).
- A member's inbox entry is a pointer created when they join (one bump) with `large: true`.
  `inbox.list` reads the large entries' rows from their heads shards in one batch per shard and
  computes `unread = last_seq - read_seq` (`read_seq` comes back to the reader's own UserDO
  with each `read_cursor.set`, which already bumps only the actor).
- Push for a large chat goes only to mentions and to members who chose "every message"
  (a per-member flag in the chat's rows, capped at 1,000 per chat).

### 1.3 Message log

Rows keyed by dense `seq`; `conversation.history {before_seq, limit ≤ 200}` and
`conversation.snapshot {tail}` page by cursor (exists). Stage B: when a chat passes 1M messages
or 1 GB, sealed segments of 10k messages older than 30 days go to R2 as NDJSON with an index row
`{from, to, key, bytes}`; history below the hot window reads the segment. Retention (team policy)
deletes rows and segments together (the existing sweep alarm).

## 2. Capabilities and roles

Access is never "knows the chat id": every op names a principal (session, install or Chief
token, resolved by the Worker), and the chat's DO decides from **grants it holds**.

### 2.1 Grants

A grant is a row in the chat's DO:

```
grant { id, subject, role, rights, issuer, parent?, created_at, expires_at?, max_uses?, uses,
        revoked_at?, revoked_by? }
subject = user:<id>      a member (sealed: only that principal can use it)
        | team:<id>      an audience: any current member of that team (TeamDO decides)
        | link:<hash>    a bearer invite link: sha256(sha256(secret)); redeemed, never used directly
```

- **Membership is a user grant.** A member row's `role` is its grant; there is no other ACL.
- **Attenuation.** Whoever holds `invite` may mint a child grant (a link, or a direct add) whose
  rights are a subset of their own and whose expiry is no later than theirs. An admin cannot
  mint owner; a member mints at most member; anyone may mint read-only.
- **Revocation.** Revoking a grant revokes every grant minted under it (by `parent`), closes the
  sockets of every principal that loses read, and stops their pushes. Removing a member is
  revoking their user grant. `ban` adds a deny row that also refuses later link redemption and
  team audience for that user.
- **Bearer links** carry `<conv code>#<26-char secret>` in the URL fragment (never logged). The
  DO stores only the hash; a redeem needs a signed-in session, checks expiry, uses and ban, and
  turns the link into a user grant with the link's role (a use is consumed). Wrong secrets count
  toward the existing accept lock. Leaking a link gives at most its role until revoked or expired;
  leaking a member's chat id gives nothing.
- **Team audience** (`team:<id>`) is how a 1M-person org-wide channel works without 1M rows: the
  grant names the team, the Worker attaches the caller's team memberships to the principal, and a
  member row is written only when that person first reads or posts (for their cursor).

### 2.2 Roles

| Right | owner | admin | member | guest | read_only |
|---|---|---|---|---|---|
| read, react | ✓ | ✓ | ✓ | ✓ | ✓ |
| post, reply, edit/retract own | ✓ | ✓ | ✓ | ✓ | |
| invite (mint ≤ own role, add people they reach) | ✓ | ✓ | ✓ (policy) | | |
| rename, topic | ✓ | ✓ | ✓ (policy) | | |
| remove members, ban | ✓ | ✓ (not owners/admins) | | | |
| set roles (≤ admin), retract others' messages | ✓ | ✓ (members only) | | | |
| settings, retention, transfer ownership, archive | ✓ | | | | |

A chat always has an owner: the last owner leaving hands ownership to the earliest admin, else
the earliest member (exists for owner/member). `ownership.transfer` makes another member owner
and the old owner admin. A DM has no roles (two equal members, no add, no leave).

Group policy flags (owner sets): `members_can_invite` (default on), `members_can_rename`
(default on), `history_visible` (`all` | `since_join`).

## 3. Use cases on the one model

1. **Family and partners, no org.** Personal space. "New group" → add by email or phone: a
   person you already reach is added; anyone else gets an invite and sees it as a message
   request (a111). Or share a link (member role, 7 days, 20 uses). Inline tier.
2. **Two high-trust founders.** A team with policy `default_visibility: all`: every channel of
   the team is created with a `team:<id>` member grant, so both see everything, and a third
   hire sees everything on joining the team, with no per-channel adds.
3. **Small startup.** Team = workspace. Channels are chats with `team` set: public channels hold
   a `team:<id>` grant (anyone in the team may join and read), private ones only user grants.
   Guests are user grants with role `guest` on specific channels; they cannot see the team
   directory.
4. **Enterprise.** Org team → child teams (TeamDO `parent`) → channels. Admin roles at the org
   (TeamDO) and at the chat. Retention and `external` policy come from the org. Audit: every
   grant, role and membership change is a ledgered event in the chat's DO, and Stage B copies them
   to an org `AuditDO` (append-only, R2 export). SSO/SCIM later feeds TeamDO membership, and a
   deprovisioned user loses every `team:` grant at once. **Shared external chats**: a chat with
   two `team:` grants, one per org, each minted by that org's admin (consent on both sides); either
   org's admin revokes their side; the stricter retention applies.

Interactions: DMs, unnamed group DMs (inline), named groups and channels, @mentions (bump the
mentioned only), threads and replies, reactions, mute (inbox), leave, remove, ban, transfer
ownership, roles, block and report (a111's requests and block; report = block + suppress queue).

## 4. Load math

Assumptions: DO SQLite ~1 ms per small transaction, single-threaded per object; a message row
~1 KB; head ≤ 16 KB in the large tier (roster bounded).

| Case | Per message today | Per message, large tier |
|---|---|---|
| 3-person group | 3 bumps, 3 unread rows, ~2 KB head | unchanged (inline tier) |
| 5,000-member group | 5,000 bumps, 5,000 unread rows, ~750 KB head written twice | 1 message row, ≤16 KB head, 1 event, 1 heads item, k mention bumps |
| 1M-member org-wide channel | impossible (2 MB head) | same as above; 0 member rows until a member reads (team grant) |

- **1M-member org.** TeamDO member rows ≈ 1M × 200 B = 200 MB (DO limit 10 GB); reach checks
  read one row by index. Stage B shards the member index into 64 `TeamShardDO`s (~16k rows each)
  when one org passes 250k members, because one object serving every reach check is the hot spot.
  An org-wide announcement channel: posting is admin-only; each post is O(1) writes; delivery is
  one heads write plus broadcast to open sockets only (hibernated sockets cost nothing idle).
- **100k messages/s overall.** One chat sustains ~500 commits/s; a per-chat rate gate holds
  each chat at 50 msg/s and each member at 5 msg/s (humans never reach it; bots are refused with
  `rate_limited`). So 100k msg/s needs ≥ 2,000 busy chats, which any population producing that
  rate has. Inline-tier bumps: mean 5 members ⇒ ~400k UserDO writes/s spread over millions of
  UserDOs (< 1/s each). Heads: 1024 shards × ≤ 1 coalesced write per busy chat per second ⇒ with
  50k busy chats ~50 writes/s per shard. Push: per-conversation 1 per 10 s and 60/h per user
  (exists).
- **Read side.** `inbox.list` of a user in 200 chats, 50 of them large: 1 UserDO read + ≤ 50
  heads-shard reads (batched per shard; typically 1-10 distinct shards). Opening a chat: 1 snapshot
  read of ≤ 50 messages. Typing: memory only, gated (3 s refresh, 5 on per 10 s per member).

## 5. Threat model

| Threat | Control |
|---|---|
| Guessing or leaking a chat id | Ids are 130-bit; every read/op/socket checks a grant in the chat's DO; unknown and forbidden answer alike. |
| Leaked invite link | Hash at rest, secret in fragment, expiry, max uses, sign-in to redeem, accept lock on wrong secrets, revocable, ban blocks reuse. |
| Removed member | User grant revoked in the commit; their sockets close at once; history, attachments, typing and pushes refused after; grants they minted are revoked (cascade). Already-seen content is not recalled. |
| Privilege escalation | Attenuation (child ⊆ parent, expiry ≤ parent) enforced in the DO; admins cannot mint or remove owners; role changes are ledgered events. |
| Spam and harassment | Reach rule (shared team or connection), message requests with Accept/Decline/Block (a111), same-domain trust, per-actor rate limits (create 60/h, add 120/h, messages 5/s), ban. |
| Cross-org leakage | A shared chat needs one `team:` grant per org, each minted by that org's admin; revoking one side removes that org's members at once; external members are guests (no directory). |
| Enumeration of accounts | Every reach refusal is `not_reachable`; an email to a stranger gets the same answer as an unknown address. |
| Hot-spot / DoS on one chat | Per-chat and per-member rate gates; large tier makes a post O(1); socket broadcast only to subscribed sockets; heads coalesced. |

## 6. Stages

- **Stage A (this branch, shipped to staging then production):** roles (owner, admin, member,
  read_only; guest = member without invite on the chat), the rights matrix in home-core,
  `participants.set_role`, `ownership.transfer`, remove-with-ban, link grants
  (`grant.create` / `grant.revoke` / `grant.list` / `grant.redeem`) with attenuation and cascade
  revocation; the large tier (member and cursor rows, bounded roster head, mention-only bumps,
  `ChatHeadsDO`, `inbox.list` merge); tests: revoked member, roles, links, and a load test that
  shows per-message cost constant from 3 to thousands of members. Mac: the ops and group info.
- **Stage B:** heads-shard sockets for live large-chat rows; `team:` audience grants with team
  hierarchy and `default_visibility`; R2 log segments; TeamDO member sharding; org AuditDO;
  shared external chats; SCIM.
