# Durable Object audit, revision 2: DO, Worker + PlanetScale, or R2

Status: proposal for the backend lead, 2026-10-03 (branch feat-cmux-next-do-audit). Documentation
only; no code, wrangler or schema changes. Revision 1 (964ea5b9e5a) kept every DO because
"PlanetScale is never a store of record". Lawrence rejected that framing: "do audit again, consider
that durable object sqlite can only be 10 GB and it's single threaded, think from first principles
if something should be workers + planetscale instead." This revision treats the store-of-record
rule as a question and answers it from size, throughput and query shape, per class. It also answers
his second question: how long a revoked install may keep making requests, and how to revoke without
a UserDO call on every request.

Read for this revision (at 6099e49ab80): every class in `backend/apps/api/wrangler.jsonc`,
`owner-do.ts`, `auth.ts`, `http.ts`, `index.ts`, `policy-gate.ts`, `user-do.ts`, `team-do.ts`,
`scheduler-do.ts`, `connection-do.ts`, `usage-meter-do.ts`, `team-vm-journal.ts`,
`team-ssh-ca.ts`, `domains/{feed-state,team,team-policy,team-sso,scheduler,connections}.ts`,
`packages/ownership/src/{engine,schema}.ts`, `packages/home-core/src/*` caps, and home-scale.md as
landed on `origin/feat-cmux-next` (its numbers are used here and cited by id: A3, A9, A14, B4, B11).
Revision 1 sections that still hold (AddressDO detail, migration rules) are kept in shorter form.

## 1. Platform facts this audit depends on

| Id | Fact | Status |
| --- | --- | --- |
| P1 | One SQLite-backed object stores at most 10 GB | given by Lawrence; matches Cloudflare docs as last known (UNVERIFIED for current plan terms) |
| P2 | One SQLite row, string or BLOB is at most 2 MB | the code already relies on it: `feed-state.ts` caps FeedDO state at 1.5 MB "Durable Object rows are at most 2 MB"; `team-policy.ts` says "All TeamDO state is one SQLite row (2 MB)". Cloudflare wording UNVERIFIED |
| P3 | One object runs one request at a time on one thread; 500 to 1,000 simple commits per second at 1 to 2 ms each | home-scale.md A14, not measured (C-4) |
| P4 | One object has about 128 MB of memory | home-scale.md B4 (UNVERIFIED) |
| P5 | At the 10 GB limit, writes fail with a storage-full error; reads continue | UNVERIFIED. Plan as: the object refuses every op that writes, including deletes that write a tombstone, so the entity is down for writes |
| P6 | Prices: DO storage 0.20 USD per GB-month; SQLite rows written 1.00 USD per million; DO requests 0.15 USD per million; R2 storage 0.015 USD per GB-month, no egress fee; KV reads 0.50 USD per million | A18 for DO; R2 and KV list prices UNVERIFIED |
| P7 | KV is eventually consistent: a write reaches all colos in up to about 60 s | UNVERIFIED |
| P8 | PlanetScale Postgres is one primary per database (no built-in write sharding as of last check), priced by cluster; HA = 1 primary + 2 replicas; storage about 0.50 USD per GB-month per node | A19, UNVERIFIED |
| P9 | DO SQLite has 30-day point-in-time recovery per object | UNVERIFIED |

P2 is the limit that bites first in three classes, before P1 (section 3, F-1).

## 2. First principles

What each store is for:

| Need | DO (SQLite) | Worker + PlanetScale | R2 |
| --- | --- | --- | --- |
| Single writer that assigns a dense seq, keeps an idempotency ledger and checks invariants in one local transaction | yes, by construction, 1 to 2 ms per commit | possible with `SELECT ... FOR UPDATE` on a parent row, but the lock is held across Worker-to-primary round trips (10 to 80 ms each, UNVERIFIED), so per-entity throughput is 10 to 100 ops/s and op latency is 2 to 4 round trips | no |
| Locks, leases, single flight | yes (one thread; one row) | yes (conditional `UPDATE ... RETURNING`, `ON CONFLICT`) | no |
| Timer per entity | yes (`setAlarm`) | cron sweep plus Queues delays | no |
| Realtime fan-out with hibernating sockets | yes | no (needs a DO or another socket service anyway) | no |
| Unbounded size per entity | no: 10 GB, 2 MB per row | yes (TB per cluster; partitions) | yes |
| Cross-entity queries (search, listing across users or teams, admin, analytics, joins) | no: an object answers only for itself, and a namespace cannot be listed | yes, with indexes and replicas | no (key prefix listing only) |
| Range scans over large history | yes inside one object, while it fits | yes | yes, by segment key |
| Failure domain | one object | the whole database: every request path that depends on it fails together | per request |
| Location | near the first caller | one region | global reads |
| Cost of cold bytes | 0.20 USD per GB-month | about 1.50 USD per GB-month (3 nodes, A19) plus index overhead | 0.015 USD per GB-month (P6) |

The decision rule this audit applies:

1. The writer of an entity's live state, where ops must be ordered, deduplicated and fanned out in
   real time, is a DO. Nothing else gives a local transaction plus sockets in one failure domain per
   entity, near the user.
2. Data that grows without bound in one entity does not stay in that entity's DO. The DO keeps a
   bounded hot window. Cold history goes to the cheapest store that serves its reads: R2 for bulk
   bytes read by key range (message bodies, journals), PlanetScale for records that need
   cross-entity queries (audit, runs, usage, directories).
3. PlanetScale may be the store of record for data that (a) needs cross-entity queries, (b) is not
   read on the interactive or auth path, or is read there only through a cache that tolerates an
   outage, and (c) is written from a DO outbox that never drops rows (the DO keeps a row until
   PlanetScale acknowledges it). It is never the sequencer of an interactive entity.
4. A Cloudflare binding replaces a DO only where approximate or stateless behavior is correct (per-IP
   burst limits, fan-in buffers, read caches).

## 3. Findings that cut across classes

- F-1. JSON-mode heads are one SQLite row (P2). Every commit of a JSON-mode owner rewrites the whole
  state as one row (`engine.ts` line 284, `INSERT INTO own_state ... json`). Owners in JSON mode:
  UserDO `user:` stream, TeamDO, SchedulerDO, ConnectionDO, FeedDO, AddressDO, PairingDO, TeamVmDO,
  UsageMeterDO. FeedDO caps itself at 1.5 MB; the others do not:
  - TeamDO: `members` and `hosts` have no cap; policy keeps 20 history copies of up to 64 KB, so
    policy alone can reach 1.34 MB. At about 150 B per member and 500 B per host, a team of about
    1,000 members with 1 host each plus a large policy passes 2 MB, and from then on every TeamDO
    commit fails. A 5,000-member enterprise team passes it with a small policy.
  - SchedulerDO: 100 automations with `instructions` up to 20,000 characters (up to 60 KB in UTF-8)
    plus 450 kept runs can reach about 6 MB.
  - Even under 2 MB, a 1 to 2 MB stringify per commit costs about 5 to 20 ms (UNVERIFIED), so the
    object's ceiling drops from 500 to 1,000 commits/s to 50 to 200, and a 5,000-member SCIM import
    blocks TeamDO (and with it every SSO gate miss of that team) for minutes.
- F-2. Outbox rows are never deleted (home-scale.md B6). Measured against size: a chief thread keeps
  about 3 KB per message (search text copy, conversation row, one bump). A 64-member group keeps one
  bump row per human per message and per last-message edit: about 64 x 0.4 KB = 25 KB per message,
  and about 110 MB per day at 2,000 messages and 4,300 edits per day. That group passes 10 GB in
  about 3 months from the outbox alone. This is the fastest-growing table in the system today.
- F-3. Event retention is time-based only (30 days or the newest 10,000, whichever keeps more), and
  row-mode events carry the full head (B4: 15 to 30 KB in a 64-member group). FeedDO events carry
  the item (up to 24 KB). Nothing bounds events by bytes:
  - an agent install at its FeedDO limit (240 posts per minute, `MAX_INSTALL_POSTS_PER_MINUTE`) with
    24 KB items writes about 8 GB of events per day, so one buggy agent fills a user's FeedDO in
    about 1 day;
  - a 64-member group at 6,300 events per day x 22 KB keeps about 4.2 GB of events.
- F-4. Listen-only sockets outlive their token and revocation. `owner-do.ts` checks `expires_at`
  only in `webSocketMessage` (line 353); `broadcast` sends to every subscribed socket without the
  check. UserDO closes a revoked install's own sockets (`afterOp`), but ConversationDO, MuxDO,
  FeedDO, TeamDO, SchedulerDO, ConnectionDO, UsageMeterDO and TeamVmDO sockets of a revoked install
  keep receiving events until the client sends a frame or the object restarts. A stolen device that
  only listens keeps reading every conversation it had open. Security bug, independent of the class
  choice (section 8).
- F-5. Every HTTP op from an install to any owner other than UserDO calls `UserDO.installGrant`
  first (`http.ts` `principalFor`, `auth.ts` `withGrantClasses`), with no cache. At 34M committed ops
  per day (A6) over HTTP that is up to 34M extra RPCs per day (2,000/s at peak), one cross-colo hop
  (50 to 150 ms, B6) added to each op, and one hot key per user with many agents.
- F-6. PlanetScale is already the only store of some history, through a lossy channel. TeamDO keeps
  only the audit chain head (`audit_head`, `audit_count`) and 20 policy versions; `team-policy.ts`
  says "the full history is the audit projection (audit_events)". The outbox dead-letters a row
  after 12 tries (about 24 minutes, B6), so a PlanetScale outage longer than that deletes audit
  history and breaks the tamper-evident chain. The "never a store of record" rule is already not
  true; the channel is just not built for it.
- F-7. Usage detail is deleted after 35 days and is projected nowhere. UsageMeterDO prunes
  `usage_ledger` rows (run, automation, step, quantity) after `USAGE_KEY_RETENTION_MS`; only monthly
  totals remain. A billing dispute or "which automation spent this" after 35 days has no answer.
- F-8. SchedulerDO keeps 200 finished runs per team (`MAX_FINISHED_RUNS`); older runs are gone. Run
  history beyond that needs a store that can list and filter (by automation, state, time).
- F-9. SchedulerDO `run_inputs` keeps each run's trigger payload (up to 256 KB) until 7 days after
  the run finishes. At 20,000 runs per day x 30 KB that is 4.2 GB in one object.

## 4. Sizing per class

Per-object bytes do not depend on MAU: the DO side scales by object count. MAU sets how many objects
sit in the tail. At 100k MAU expect about 1,000 users at p99 and tens of worst-case entities (agent
loops, large teams); at 1M MAU, ten times more, and enterprise teams of 5,000 to 20,000 seats.
"Today" = code at 6099e49ab80. "Target" = home-scale.md changes C-1 (delete outbox on send), C-6
(event window), C-7 (head diffs, `msg` table) applied. Row costs: a chief message row about 2.4 KB
stored (2 KB body, A9, plus metadata and two index entries), a human message row about 0.7 KB.

### 4.1 Size

| Class | Entity that grows without bound | p50, 1 y | p99, 1 y | p99, 3 y | Worst entity | Limit reached |
| --- | --- | --- | --- | --- | --- | --- |
| ConversationDO, chief thread | messages, events with head, outbox | 50 msg/day: 44 MB messages + 0.1 GB outbox | 2,740 msg/day (home-scale p99 of 1M messages, assumed per year): today 2.4 GB messages + 3 GB outbox + 1.3 GB events = 6.7 GB; target 2.6 GB | today 17.5 GB (passes 10 GB at about 1.5 years); target 7.4 GB | an agent loop at 20,000 msg/day: 17.5 GB per year of messages alone, passes 10 GB in about 7 months even at target; 1M messages of 16 KB logs pass it at once | yes, P1, for p99 within 3 y today and for the worst entity at any target |
| ConversationDO, group of up to 64 | messages, outbox bumps, events with a 15 to 30 KB head | 4 humans, 30 msg/day: under 50 MB | 2,000 msg/day (500 human, 1,500 chief): today 1.4 GB messages + 40 GB per year outbox (F-2) + 4.2 GB events; target 1.5 GB | today far over; target 4.4 GB | a 64-human team channel with streaming chiefs for 3 years: about 6 GB at target | yes, today in about 3 months (F-2) |
| UserDO | inbox entries (1 per conversation), inbox events, installs | 30 entries: under 1 MB | 2,000 entries (1.6 MB) + 30 d of 2,300 bumps/day (about 83 MB) | under 0.1 GB | a script at the 60 `conversation.create` per hour cap: 500k entries per year, 0.4 GB per year, 1.2 GB at 3 y | no |
| FeedDO | events carrying items (F-3); state capped at 1.5 MB | under 5 MB | 500 posts/day x 3 KB x 30 d = 45 MB | same (time window) | one install at 240 posts/min x 24 KB: about 8 GB per day of events | yes, in about 1 day for a runaway agent |
| MuxDO | wake rows, capped (`MAX_PENDING_PER_CONVERSATION` 200 x `MAX_TRACKED_CONVERSATIONS` 500) | under 1 MB | about 90 MB of events | same | 100k wake rows, about 50 MB, plus events | no |
| AddressDO | 50 deliveries max, side tables | KB | KB | KB | KB | no |
| TeamDO | JSON head: members, hosts, policy history (F-1); `ssh_certs`, SSO session rows | 5 members: 10 KB | 500 members, 1,000 hosts: 0.6 MB head + up to 1.34 MB policy | same | 5,000 members, 10,000 hosts: 5.8 MB head; 20,000 seats at 1M MAU: about 20 MB | yes, P2 (2 MB row), at about 1,000 to 3,000 members |
| SchedulerDO | JSON head (automations, 450 runs); `seen_deliveries` 30 d; `run_inputs` (F-9) | under 1 MB | 0.65 MB head; 50k deliveries/day x 0.2 KB x 30 d = 0.3 GB; inputs 0.3 GB | same | head up to 6 MB (P2 fails); inputs 4 GB or more | yes, P2 for large definitions; P1 possible from inputs |
| ConnectionDO | `external_calls` (7 d, keeps the provider reply) | under 10 MB | 100k calls/day x 1 KB x 7 d = 0.7 GB | same | 100k calls/day x 5 KB replies: 3.5 GB | no, but close for the worst |
| AccountIndexDO | links per provider account | KB | KB | KB | a few hundred teams on one account: under 1 MB | no |
| DomainDO, PairingDO, HostDO | one row each | bytes | bytes | bytes | bytes | no |
| UsageMeterDO | `usage_ledger` 35 d; monthly totals forever | under 10 MB | 50k records/day x 0.3 KB x 35 d = 0.5 GB | same | 500k records/day (per-call metering of a 5,000-seat team): 5.3 GB | no, but close for the worst |
| TeamVmDO | journal, capped at 8 GB (`MAX_JOURNAL_BYTES`) | unknown (no telemetry) | assume 1 GB per month for a busy team: cap in 8 months | at cap; writes refused with `journal.full` | at cap | yes, by design (cap); compaction S6b not built |

### 4.2 Throughput and hot keys

| Class | Peak ops per object | Ceiling (P3) | Hot key? |
| --- | --- | --- | --- |
| ConversationDO | 20 ops/s for a streaming chief in a group (B2, B4); capped at 50 by `conversation_busy` (target) | 500 to 1,000 | yes for a large group: many readers (96 sockets) and the B4 frame volume; bounded by the cap |
| UserDO | 20 bumps/s (heaviest user) plus one `installGrant` per HTTP op of every install of the user (F-5): a user with 20 agents at 5 ops/s adds 100 RPCs/s | 500 to 1,000 | yes, from F-5 |
| TeamDO | admin ops low; `signInRules`, `ssoSession` per isolate cache miss (30 s); token mint and every WebSocket connect call them; a 10,000-member team with 1.5 devices and a 10-minute reconnect cycle: about 25 calls/s | 50 to 200 once the head is 1 to 2 MB (F-1) | yes for large teams |
| SchedulerDO | webhook bursts of a large org: 100 deliveries/s or more during push storms; each matching delivery is a commit that rewrites the head | 200 to 300 with a 0.65 MB head | yes for large orgs |
| ConnectionDO | 2 commits per provider call (claim, record); provider rate limits (GitHub about 1.4 to 4 req/s per installation, UNVERIFIED) cap it near 10/s per connection | 500 to 1,000 | no |
| AccountIndexDO | one indexed read per provider webhook (100/s for a large org) | reads at about 0.1 ms, thousands per second | no |
| FeedDO | posts capped per poster and install; JSON head up to 1.5 MB | 100 to 200 | no, if F-3 is fixed |
| UsageMeterDO | one batched `record` per tail invocation and step (500 records per call max) | fine | no |
| MuxDO, AddressDO, DomainDO, PairingDO, HostDO, TeamVmDO | low commit rates; HostDO relays binary frames (throughput per object for relay UNVERIFIED) | fine | no |

### 4.3 Query shape

Cross-entity questions that a DO cannot answer, and where they must be served:

| Question | Today | Target |
| --- | --- | --- |
| Search across a user's conversations | PlanetScale replica (projection) | same |
| Team member list with paging, filter by role, SCIM reconciliation | TeamDO head (whole map) | TeamDO rows plus a PlanetScale projection for listing |
| Audit log by time, actor, op; compliance export | PlanetScale `audit_events` (already the record, F-6) | same, with a durable channel |
| Automation run history by automation, state, time | last 200 in SchedulerDO | PlanetScale `automation_runs` |
| Usage by run, automation, month; invoices; disputes | 35 days in UsageMeterDO | PlanetScale `usage_records` (or ClickHouse, Q4) |
| Which teams link a provider account | AccountIndexDO | same now; PlanetScale table later (5.10) |
| Operator abuse views over addresses (suppressed, invite counts) | none | PlanetScale non-PII projection (AddressDO F3) |
| Old messages in one conversation (range by seq) | ConversationDO rows | hot window in the DO, older segments in R2 |
| Membership of a user across conversations | UserDO inbox (one per user) | same |

## 5. Verdicts per class

Verdict vocabulary: keep / keep as sequencer and realtime, history out (with the bound) / merge /
replace with Worker + PlanetScale / replace with a binding.

### 5.1 ConversationDO: keep as sequencer and realtime; history older than the hot window moves to R2

Why not Worker + PlanetScale for the whole entity (the strongest alternative, written out):

- Ordering. A dense seq per conversation with an idempotency ledger and participant invariants needs
  per-conversation serialization. In Postgres that is a row lock on `home_conversations` held across
  the whole op; from a Worker each statement is a round trip to one region, so one op holds the lock
  for 2 to 4 round trips (20 to 300 ms) and a conversation caps at 10 to 50 ops/s with that latency
  on every send. A stored procedure removes the round trips but moves the domain reducer (TypeScript
  in `home-core`, shared with the Rust owner corpus) into PL/pgSQL.
- Volume. 34M committed ops per day at 100k MAU (2,000/s peak), 340M at 1M (20,000/s peak), each
  writing 10 to 40 rows (B11 target). One PlanetScale Postgres primary (P8) cannot take the 1M case,
  and sharding is not a product feature to plan on.
- Realtime. Sockets still need a DO (or another socket service). The DO would then hold no state and
  every resume (`after_seq`) would read PlanetScale.
- Failure domain. One primary down stops all messaging for all users. Today one object down stops
  one conversation.
- Location. Users far from the primary region pay 100 to 250 ms per op (UNVERIFIED).

So the sequencer stays. What changes is size: today the p99 chief thread passes 10 GB in about 1.5
years and the worst entity in months (section 4.1).

Hybrid design (bound and mechanism):

- The DO keeps: head, participants, cursors, invites, ledger (7 days), events (C-6 and F-3: the
  newest 7 days, at most 10,000 events and at most 256 MB, whichever is smallest, never fewer than
  the newest 1,000), the outbox until delivery (C-1), and message rows newer than 90 days. If hot
  message bytes pass 2 GB, the oldest are archived early; the newest 1,000 messages always stay.
  Bound per object: about 2 GB messages + 0.26 GB events + under 0.1 GB other, about 2.5 GB, 25% of
  P1, for any conversation forever.
- Cold store: R2, not PlanetScale. At 100k MAU the raw message bytes are about 16.4 GB per day
  (1.2M human x 300 B + 8M chief x 2 KB, A3, A9), about 6 TB per year:

  | Store for 6 TB/year of message history | After 1 year | After 3 years |
  | --- | --- | --- |
  | Keep in DO SQLite (rows + indexes, about 7 TB/year) | 1,400 USD/month | 4,200 USD/month |
  | PlanetScale table (heap + btree about 1.5x, 3 nodes, A19) | 13,500 USD/month | 40,500 USD/month, and past one primary at 1M MAU |
  | R2 segments, gzip about 3x on text (UNVERIFIED ratio) | 30 USD/month | 90 USD/month |

  At 1M MAU multiply by 10. PlanetScale keeps what it already has: the search projection (human rows
  under team retention, agent rows 90 days, B7).
- Segments: key `conv/v1/<conversation_id>/<first_seq:016>-<last_seq:016>.ndjson.gz`, about 16 MB
  or 10,000 messages each, written by the DO alarm. DO tables:

  ```sql
  CREATE TABLE archive_segments (
    first_seq INTEGER PRIMARY KEY, last_seq INTEGER NOT NULL,
    first_at INTEGER NOT NULL, last_at INTEGER NOT NULL,
    bytes INTEGER NOT NULL, sha256 TEXT NOT NULL, r2_key TEXT NOT NULL);
  CREATE TABLE archive_overlay (            -- changes to archived messages
    seq INTEGER PRIMARY KEY,
    kind TEXT NOT NULL CHECK (kind IN ('retract','delete','edit','reactions')),
    json TEXT NOT NULL, at INTEGER NOT NULL);
  ```

- Archive step (idempotent): select the oldest hot rows past the bound; build the segment; `put`
  with the deterministic key; on success commit `INSERT OR IGNORE INTO archive_segments` and delete
  those rows in one transaction. A crash after `put` and before the commit leaves a segment that the
  next run overwrites with identical content. A failed `put` deletes nothing.
- Reads of old history: `conversation.history` before the oldest hot seq returns, from the DO, the
  authorization decision (participant, `history_visible`), the segment list and the overlay rows for
  that range; the Worker reads R2 directly and applies the overlay. The DO does no bulk reads.
- Writes to archived messages: retraction, delete and reactions go to `archive_overlay` (small);
  a monthly compaction rewrites a segment when its overlay passes 100 rows. Edits of messages older
  than 90 days: refuse or overlay (Q1).
- Retention: delete whole segments past team retention; `home.message.delete_through` (B7) for the
  search projection.
- Import (A5): batches older than the hot window can be written straight into segments, so a
  1M-message import does not write 10M SQLite rows (about 10 USD each, A5).
- Failure modes: R2 down means history older than 90 days is unreadable (degraded read); sends,
  realtime and recent history are unaffected. A lost segment would lose history: verify the
  `sha256` on write and keep R2 object versioning or a second bucket for the first year (Q6).
- Migration: no class change, no `deleted_classes`. Add an R2 binding (for example
  `HOME_ARCHIVE`) to all four environment blocks of `wrangler.jsonc`. Objects archive lazily on
  their next alarm; a cron pokes large idle conversations selected from the
  `home_conversations` projection by `last_seq`. This replaces home-scale.md's quarterly chief-thread
  rotation (B2), which stays a fallback.

### 5.2 UserDO: keep; take it off the per-request path (section 8)

The inbox is bounded by conversation count (1.2 GB worst at 3 years); no history needs to move. The
real defect is F-5. The `user:` stream head is small (installs, grants, chiefs); keep JSON mode but
add the F-1 guard (5.15). `hosted_conversations` (home-scale A8) is a new table here, not a class.

### 5.3 TeamDO: keep as policy and membership authority; move members, hosts and policy history out of the head

TeamDO's `authorize` reads `state.members` on every op, `signInRules` and `ssoSession` serve the
auth path; those must stay in the object. What must change is F-1:

- `members` and `hosts` become DO tables (`team_members(user PRIMARY KEY, role, display_name)`,
  `team_hosts(id PRIMARY KEY, owner_user, kind, json)`), read by key in `authorize`, not one map in
  the head. Policy history keeps the current version in the head and older versions only in
  PlanetScale `audit_events` (already the documented record).
- Project members to PlanetScale (`team_members_v (team, user_id, role, display_name, source_seq,
  PRIMARY KEY (team, user_id))`) for paged listing, filter and SCIM reconciliation. This is a copy.
- Audit history: PlanetScale is the store of record (it already is, F-6). Make the channel durable:
  no dead letter for transient errors (C-27), and TeamDO keeps every `n`-th (every 1,000th) chain
  hash in a DO table as a checkpoint so a verifier can detect deleted projection rows.
- Bound: head under 100 KB; members and hosts in rows, about 650 B per member-with-host, so 20,000
  seats is about 13 MB of rows. Commit cost no longer grows with team size.
- Migration: an engine change (JSON domain to row writes for two maps); one-time copy from the head
  to the tables on wake, in the same transaction that removes the maps; no class change; mirrors
  need the new snapshot shape (client release for the team stream).

### 5.4 SchedulerDO: keep as sequencer; move runs out of the head and history to PlanetScale

Keep: cron fires, run deadlines, delivery dedupe (30 days), the exact token bucket, open runs. Change:

- Automations and runs become DO tables (head keeps counts and limits). This removes the P2 risk
  for large definitions and drops commit cost during webhook bursts.
- Finished-run history: PlanetScale store of record, from the outbox at the terminal transition.

  ```sql
  CREATE TABLE automation_runs (
    team text NOT NULL, run_id text NOT NULL, automation_id text NOT NULL,
    trigger_kind text NOT NULL, state text NOT NULL,
    started_at timestamptz, finished_at timestamptz NOT NULL,
    error_code text, usd_micros bigint, source_seq bigint NOT NULL,
    PRIMARY KEY (team, run_id, finished_at)
  ) PARTITION BY RANGE (finished_at);   -- monthly partitions, retention by DROP
  CREATE INDEX ON automation_runs (team, automation_id, finished_at DESC);
  ```

  Idempotency: `INSERT ... ON CONFLICT DO NOTHING` (a run finishes once). The DO keeps the newest
  200 finished runs for the live UI; the list endpoint pages older runs from the replica.
- `run_inputs` (F-9): pass the input to the Workflow at instance create and delete it once the
  instance exists, or store it in R2 (`run-inputs/<team>/<run>`) with a 7-day lifecycle rule.
- Bound: head under 100 KB, `seen_deliveries` 30 days (0.3 GB at p99), no inputs.

### 5.5 ConnectionDO: keep

Credentials stay sealed in one object; the external-call ledger with `mutation.indeterminate` and
the in-memory single-flight refresh (rotating refresh tokens are single use) are correct only with
one writer. Watch item: `external_calls` keeps the provider reply for 7 days; store a reply hash and
status instead of the body when the body is over 1 KB (worst 3.5 GB to under 0.2 GB).

### 5.6 FeedDO: keep; bound its events by bytes

State is already capped. Fix F-3: event window 7 days, at most 10,000 events and 64 MB; add a daily
post cap per install (for example 5,000 per day) so a runaway agent cannot churn the window. No
merge into UserDO now (revision 1 Q4 stands).

### 5.7 MuxDO: keep

Bounded by its caps; it is the wake queue and the future cloud brain loop (alarm-driven turns).

### 5.8 AddressDO: keep

Unchanged from revision 1 section 3: single writer for suppression, per-recipient windows, card
steps and the delivery ledger; attempt-once lock; five timers; the raw address lives only in this
object. Size is KB. PlanetScale would need application-level encryption of the raw address and
gains nothing at 0.1 invites/s. Fixes F1 to F4 of revision 1 stay (180-day purge, 3-day reminder, no
raw address in `own_events`, a non-PII projection for abuse reads, an operator suppress path).

### 5.9 DomainDO: keep

A one-row unique constraint on the SSO gate path (`policy-gate.ts`, cached 30 s per isolate; public
mail domains never wake an object). A PlanetScale `team_domains (domain PRIMARY KEY, team)` table is
the same constraint but would make sign-in depend on PlanetScale. Nothing grows; keep.

### 5.10 AccountIndexDO: keep now; replace with Worker + PlanetScale when webhook ingestion is queue-first

By shape it is a global secondary index, which is what a database is for. The reason to keep it now
is availability: a provider webhook resolved through PlanetScale fails during an outage, and GitHub
does not retry failed deliveries automatically (UNVERIFIED). Once webhook ingress writes each raw
delivery to a Queue first and acknowledges the provider, an outage only delays processing, and the
index can move:

```sql
CREATE TABLE account_links (
  provider_account text NOT NULL, team text NOT NULL, connection text NOT NULL,
  added_at timestamptz NOT NULL, failures int NOT NULL DEFAULT 0,
  PRIMARY KEY (provider_account, team, connection));
CREATE TABLE integration_stop_claims (provider_account text PRIMARY KEY, connection text NOT NULL,
  state text NOT NULL, at timestamptz NOT NULL);   -- claimed with the conditional upsert of revision 1 section 4.3
```

Now: write the links through E4 outbox items in the same commit as the connection change (revision 1
section 4.3); today's best-effort `add`/`remove` after commit loses entries. Migration later: dual
write from ConnectionDO outbox, backfill from the `connections` projection, compare, switch reads,
then `deleted_classes: ["AccountIndexDO"]` one release later (section 9).

### 5.11 PairingDO: keep

Hibernating wait socket, one-shot expiry, first approver claims. Bytes.

### 5.12 HostDO: keep

A socket relay; nothing else holds the sockets. Bytes of state.

### 5.13 UsageMeterDO: keep for the cap; usage history moves to PlanetScale (store of record)

Keep: dedupe by key (35 days), monthly counters in integer micro-dollars, and the cap answer in one
local transaction on every step boundary. A PlanetScale write per step would put the run path behind
the primary. Change (F-7): emit each recorded batch as an outbox projection:

```sql
CREATE TABLE usage_records (
  team text NOT NULL, key text NOT NULL, meter text NOT NULL,
  quantity numeric NOT NULL, usd_micros bigint NOT NULL, month text NOT NULL,
  run text, automation text, step text, attempt int, commit_sha text,
  observed_at timestamptz NOT NULL, recorded_at timestamptz NOT NULL,
  PRIMARY KEY (team, key, recorded_at)
) PARTITION BY RANGE (recorded_at);
```

Idempotency: the record key is already unique per team; `ON CONFLICT DO NOTHING`. Ordering does not
matter (sums). The DO stays the authority for the cap and the month total; PlanetScale is the record
for detail older than 35 days and for invoices. Write load: 5M to 50M records per day at 100k MAU (58
to 580 rows/s mean), sent as multi-row statements of up to 500. At 1M MAU consider ClickHouse, which
already holds the coderouter ledger (Q4).

### 5.14 TeamVmDO: keep as sequencer; journal history moves to R2 (S6b), hot tail 1 GB

The journal is the zero-loss tier: the DO acknowledges a write only when it is durable, assigns the
dense seq per stream and serializes provider calls. Bytes go to R2: compact closed ranges into
segments (`tvm/v1/<team>/<stream>/<first_seq>-<last_seq>`), record them in a `journal_segments`
table, delete rows after the `put` succeeds (the same idempotent step as 5.1). Bound: hot tail 1 GB
instead of 8 GB; `journal.full` becomes a backpressure signal when R2 is down, not a lifetime cap.

### 5.15 Engine guard for every JSON-mode owner

Refuse a commit whose state JSON passes 1.5 MB with a typed retryable reject (`owner.state_full`)
instead of an SQLite error, and log the owner and size. This turns F-1 from an outage into a
visible limit while 5.3 and 5.4 land.

### 5.16 MailerDO (planned): do not create; use a Queue consumer

`mail.security_notice` sends one mail per notice with retries. Idempotency key = notice id, kept in
the sending owner's outbox (at least once) and passed to the provider's idempotency header where it
exists. Per-recipient suppression for email addresses already lives in AddressDO; a mail that needs
suppression goes through AddressDO. No new class, so no future `deleted_classes`.

### 5.17 Summary

| Class | Verdict | Bound after the change |
| --- | --- | --- |
| ConversationDO | keep as sequencer + realtime; history older than 90 days or past 2 GB to R2 | about 2.5 GB per object |
| UserDO | keep; off the per-request auth path | under 1.3 GB worst |
| TeamDO | keep; members, hosts, policy history out of the head; audit record in PlanetScale | head under 100 KB |
| SchedulerDO | keep as sequencer; runs out of the head; finished runs to PlanetScale; inputs out | head under 100 KB, tables under 0.5 GB |
| ConnectionDO | keep; reply hashes in `external_calls` | under 0.2 GB |
| AccountIndexDO | keep now; replace with Worker + PlanetScale after queue-first ingestion | KB |
| FeedDO | keep; byte-bounded events, daily post cap | under 100 MB |
| MuxDO | keep | under 0.2 GB |
| AddressDO | keep | KB |
| DomainDO | keep | bytes |
| PairingDO | keep | bytes |
| HostDO | keep | bytes |
| UsageMeterDO | keep for the cap; detail to PlanetScale | 35 days of keys |
| TeamVmDO | keep as sequencer; journal to R2 | 1 GB hot |
| MailerDO | do not create; Queue consumer | none |

No class is replaced by Worker + PlanetScale now; one (AccountIndexDO) is replaced later. Four
classes move history out (ConversationDO and TeamVmDO to R2; SchedulerDO and UsageMeterDO to
PlanetScale), and TeamDO's audit history is formally PlanetScale's.

## 6. The hybrid, entity by entity

| Entity | Hot in the DO | Record for old data | Reads of old data | Bound in the DO |
| --- | --- | --- | --- | --- |
| Chief thread messages | head, last 90 days, at least 1,000 messages | R2 segments | Worker reads R2 after a DO authorization reply | 2 GB messages, 2.5 GB total |
| Group conversation messages | same | R2 segments | same | same |
| UserDO inbox | all entries (one per conversation) | none needed | n/a | 1.2 GB worst at 3 y; revisit only if conversation counts per user exceed 1M |
| FeedDO | 500 items, 7 days | none (items expire by design) | n/a | 1.5 MB state, 64 MB events |
| TeamDO audit journal | chain head, every 1,000th hash | PlanetScale `audit_events` | replica | KB |
| Team VM journal | open and recent ranges | R2 segments | Worker reads R2 | 1 GB |
| Scheduler history | open runs, newest 200 finished | PlanetScale `automation_runs` | replica | head under 100 KB |
| Usage records | 35 days of keys and monthly totals | PlanetScale `usage_records` (or ClickHouse) | replica | 35 days |

Rule for every handoff: the DO deletes a row only after the cold store acknowledges it (R2 `put`
success, or the outbox row's PlanetScale commit). The outbox must not dead-letter transient errors
(C-27); otherwise the hybrid loses data.

## 7. PlanetScale in the request path: plan, HA, cost

Under these verdicts PlanetScale enters no interactive write path and no auth path. New request-path
reads are admin listings (members, runs, usage, audit) on the replica, already present for search
(`HYPERDRIVE_RO`). New writes from outboxes at 100k MAU: runs about 25/s, usage 60 to 580/s mean,
members and audit under 10/s, all as multi-row statements, on top of the search projection (160/s
mean, 810/s peak at target, B7). This fits the HA cluster of 1 primary + 2 replicas that home-scale
already recommends (A19, about 2,500 USD/month); no plan change at 100k MAU. At 1M MAU usage detail
(up to 5,800 rows/s mean) should go to ClickHouse or its own cluster. Store-of-record data also needs
verified backups and point-in-time recovery on PlanetScale (UNVERIFIED for PlanetScale Postgres
terms) and a restore drill. No sensitive columns are added: audit details carry public ids only, run
rows carry no inputs, usage rows carry no PII.

Cost changes (monthly, 100k MAU, year 1 to year 3; 1M MAU is about 10x):

| Change | Effect |
| --- | --- |
| Messages to R2 (5.1) | DO storage -1,400 to -4,200 USD; R2 +30 to +90 USD |
| Outbox delete on send (C-1, F-2) | the largest storage item today; home-scale B11: 2.20 to 0.68 USD per 1M sends per month kept |
| Revocation redesign (section 8) | -34M UserDO RPCs per day (about -150 USD), +4M token mints per day; -50 to -150 ms on every HTTP op to non-UserDO owners |
| PlanetScale history tables | within the existing HA cluster; storage tens of GB per year |
| TeamVmDO journal to R2 | up to 8 GB per busy team: -1.60 USD to +0.12 USD per team |

## 8. Revocation without a UserDO call per request

### 8.1 What happens today

- Each install has a long-lived ES256 key (Secure Enclave on Apple devices; a file key for CLI and
  TUI installs, UNVERIFIED per platform). It mints an access token by signing a UserDO challenge
  (`auth/challenge`, `auth/token`); `redeem` refuses a revoked install at once.
- Access tokens live 10 minutes (`ACCESS_TOKEN_TTL_SECONDS = 600`) and are verified statelessly.
- HTTP ops to UserDO check `installActive` (0 s). HTTP ops to every other owner call
  `installGrant` first (0 s, at the F-5 cost).
- Sockets: UserDO closes a revoked install's sockets at once. Other owners close a socket only when
  it sends a frame after token expiry; a listen-only socket stays open (F-4). Ops sent over a socket
  are refused after expiry, so an open socket can still send for up to 10 minutes after revocation.

So the effective bound today is 0 s for HTTP, up to 10 minutes for socket sends, and unbounded for
socket reads on non-UserDO owners.

### 8.2 The threat and the blast radius

The threat is a lost or stolen device, or a copied file key, that holds a bearer credential. After
the user revokes the install, the attacker keeps what was already minted: an access token until it
expires and any open socket. The install key itself is dead the moment UserDO marks it revoked,
because every new token needs a fresh UserDO challenge.

| Scope | Examples | Damage per minute after revocation | Acceptable latency |
| --- | --- | --- | --- |
| Read | inbox, history, feed, search, socket subscriptions | new messages of that minute are disclosed; old ones were readable before revocation anyway | minutes |
| Act | send, edit, react, invite, feed post, chief posts | impersonation; up to 3 human sends/s (B9) = 180 messages per minute; invites limited per address | about 1 minute |
| Privileged and agent | `mux.confirm.decide`, `user.text_confirm.*`, install and grant create, team admin, policy, SSO, connection calls with write scopes, automation deploy and manual run, team VM start and SSH certificate mint, `conversation.import`, conversation delete, export, account delete | code execution on team VMs, repository writes, persistence (a new install outlives the revoked one), irreversible deletes | 0 s, and a fresh human presence for destructive ones |

The read loss is the slowest to matter and the cheapest to bound by TTL. The privileged class is the
one that must never ride on a cached decision; it is also low volume, so an online check costs
little.

### 8.3 Recommendation

1. Access tokens: TTL 5 minutes (from 10), refreshed at 4 minutes. The token carries what owners
   need, signed at mint: `inst`, `grant`, the grant's op classes, `install_kind`, email and
   `email_verified`, and a user revocation epoch `uep`. Owners authorize from claims; the Worker
   stops calling `installGrant` for read and act ops. Grant narrowing then takes effect at the next
   mint (5 minutes), except for privileged ops (item 3).
2. Deny list for act ops: on `install.revoke`, `install.revoke_by_team` and "revoke all" (bump
   `uep`), UserDO writes KV key `revoked:<env>` (one small value: installs revoked in the last
   15 minutes and per-user minimum epochs). Each isolate caches it for 15 s. Act ops (HTTP and
   socket frames) refuse a listed install. Bound: about 15 s plus KV propagation (up to 60 s, P7),
   so about 75 s. Cost: one KV read per isolate per 15 s, one KV write per revocation.
3. Privileged ops: an online check at UserDO (`installGrant`, 0 s), as today, only for the
   privileged op list. Destructive ones (team VM exec and SSH certificate mint, connection write
   calls, install and grant create, account and conversation delete, export, policy and SSO
   changes) also require step-up: a presence signature from the app install key (the D3 app-signed
   envelope, with the user-presence flag) or a Stack session authenticated within the last 10
   minutes. Install creation always requires a fresh human session, so a stolen device cannot mint a
   second install that survives revocation.
4. Sockets: check `expires_at` in `broadcast` and close expired sockets there (F-4 fix), and add an
   in-band `auth.refresh {token}` frame so a live socket extends its expiry without reconnecting. A
   revoked install cannot mint, so its sockets close within 5 minutes (plus 30 s grace) everywhere.
   UserDO keeps closing them at once. Optional later: UserDO sends `install.revoked` to the owners
   in the deny list's fan-out so ConversationDO closes at once; not needed for the bound.
5. Install keys: non-exportable hardware keys where the platform has them. File-key installs (CLI,
   TUI, Linux daemon) expire after 30 days without a mint and need a human session to renew;
   hardware-key installs after 180 days without a mint.

Resulting bounds after revocation: read 5 minutes (sockets 5.5 minutes), act about 75 s, privileged
0 s. Load: at 100k MAU about 15k installs online on average mint every 4 minutes, about 5M mints per
day (60/s mean), each one UserDO RPC plus the `signInRules`/`ssoGate` lookups that mint already does,
against up to 34M per-op RPCs today. Socket refresh frames: 23k sockets / 240 s, about 100 frames/s
at peak, billed as 1/20 request each.

Trade-offs:

| TTL | Read bound | Mints per day at 100k MAU | Comment |
| --- | --- | --- | --- |
| 1 min | 1 min | about 22M | close to today's per-op RPC count; little gained |
| 5 min (recommended) | 5 min | about 5M | standard short-lived access token range (OAuth access tokens are commonly 5 to 60 minutes) |
| 10 min (today) | 10 min | about 2M | acceptable for reads only if act ops use the deny list |
| 60 min | 60 min | about 0.4M | read exposure too long for a stolen phone |

The strongest objection: the deny list adds KV, a second source of truth, and its propagation is
not under our control (P7). The answer is that it is an accelerator only: correctness falls back to
the TTL, and privileged ops never use it.

## 9. Migration rules for any class change

Kept from revision 1 section 5, still binding:

1. A DO namespace cannot be listed. Every backfill needs an external key list (PlanetScale
   projections or owner state).
2. Order: new store and dual writes (DO stays the owner) -> backfill -> comparison until zero
   differences -> switch reads -> stop DO writes -> one release later, delete the class.
3. Deleting a class: remove its binding from all four `durable_objects.bindings` lists, remove the
   export from `index.ts`, and append a new tag such as `{ "tag": "v11", "deleted_classes":
   ["AccountIndexDO"] }` to all four `migrations` lists. Tags are append-only. `deleted_classes`
   deletes the storage of every object of that class at deploy; plan as if rollback to a version that
   binds the class is blocked (UNVERIFIED wording).
4. External-effect ledgers (ConnectionDO `external_calls`, AddressDO `address_attempts`) move only
   after they drain past their deadline, or the new path sends twice.
5. A class with subscribers changes the client protocol when it moves; the hybrids in section 6
   change only history reads, not stream names.
6. New for history handoff: a DO deletes rows only after the cold store acknowledges them, and the
   outbox never dead-letters transient errors (C-27) before any store-of-record projection ships.

## 10. Ranked refactor plan

1. Outbox delete on send (C-1). F-2 fills a 64-member group in about 3 months; nothing else is as
   urgent. Engine change, no class change.
2. Byte-bounded event windows for every owner (7 days, 10,000 events, 256 MB for ConversationDO,
   64 MB for FeedDO; never fewer than 1,000) and head diffs in events (C-6, C-7, F-3). Add the FeedDO
   daily post cap.
3. Revocation redesign (section 8): claims in the token, 5-minute TTL, KV deny list for act ops,
   online check plus step-up for privileged ops, `expires_at` in `broadcast` and `auth.refresh`.
   Fixes F-4 (security) and F-5 (hot key, latency). Supersedes home-scale C-29.
4. JSON head guard (5.15) now, then TeamDO members, hosts and policy history out of the head (5.3)
   and SchedulerDO automations and runs out of the head (5.4), before the first team of about 1,000
   members.
5. ConversationDO hot window + R2 archive (5.1) before the first chief thread passes 2 GB (about 9
   months after launch for a p99 user).
6. Durable outbox (C-27) with audit checkpoints (5.3); then the store-of-record projections:
   `automation_runs`, `usage_records`, `team_members_v`.
7. TeamVmDO journal compaction to R2 (5.14, S6b).
8. SchedulerDO `run_inputs` out of the object (5.4, F-9); ConnectionDO reply hashes (5.5).
9. AccountIndexDO maintenance through E4 outbox items now; replace with PlanetScale after queue-first
   webhook ingestion (5.10).
10. MailerDO as a Queue consumer (5.16); AddressDO F1 to F4.
11. Per-IP Rate Limiting bindings for `invite.create`, `dm.open` by address and `invite.preview`
    (revision 1 item 4).

Top five: items 1 to 5.

## 11. Never move

- Sequencing, the idempotency ledger, the head and the realtime hub of every interactive entity
  (ConversationDO, UserDO inbox, MuxDO, FeedDO).
- Auth state: installs, grants, revocation, challenges (UserDO); team membership checks and SSO
  rules (TeamDO); domain claims (DomainDO).
- Sealed credentials, the external-call ledger and refresh single flight (ConnectionDO).
- The money cap: dedupe, counter and the allowed answer in one transaction (UsageMeterDO).
- Raw addresses, suppression and the delivery ledger (AddressDO).
- The journal sequencer and provider single flight (TeamVmDO); the socket relays (HostDO,
  PairingDO).

## 12. Decision: may PlanetScale be a store of record?

Yes, for entities that meet rule 3 of section 2:

- team audit and policy history (`audit_events`), which it already is (F-6), once the channel is
  durable;
- finished automation runs (`automation_runs`);
- usage detail older than the 35-day dedupe window (`usage_records`), unless ClickHouse is chosen
  (Q4);
- later, the provider account index (`account_links`), after queue-first webhook ingestion.

No, for: message bodies (R2 is 100x cheaper per GB and the DO is the sequencer), anything on the
auth or revocation path, per-op sequencing and idempotency, the money cap, credentials, and raw
addresses. PlanetScale keeps serving copies for search, directory listings and operator views.

## 13. Open questions

- Q1. May messages older than 90 days be edited, or only retracted, deleted and reacted to (5.1)?
- Q2. Are the revocation bounds acceptable: read 5 minutes, act about 75 s, privileged 0 s (8.3)?
- Q3. Which ops are privileged and which of those need step-up (8.2 list is a proposal)?
- Q4. Usage detail store at scale: PlanetScale `usage_records` or ClickHouse (5.13)?
- Q5. What team size must work at launch? It sets the deadline for 5.3 (about 1,000 members today).
- Q6. Chief thread retention: forever in R2, or a user setting? Should R2 keep object versions for
  the first year (5.1)?
- Q7. Feed post cap per install per day (5.6): is 5,000 right?
- Q8. TeamVmDO journal growth per team (no telemetry): what rate should S6b plan for?
- Q9. PlanetScale backup and point-in-time recovery terms for store-of-record tables (section 7).

## 14. Assumptions

- AS1. Volumes are home-scale.md B1 (100k MAU, 40k DAU, 34M committed ops per day, peak 2,000 ops/s;
  1M MAU = 10x). Invites 3k to 10k per day. Feed, scheduler, usage and journal volumes are not
  measured; the p99 and worst values in section 4 are estimates stated with their inputs.
- AS2. home-scale's p99 chief thread of 1M messages is reached in about 1 year (2,740 messages per
  day). The worst entity is an agent loop at 20,000 messages per day.
- AS3. Stored row sizes: 2.4 KB per chief message and 0.7 KB per human message including metadata
  and two index entries; outbox bump rows 0.4 KB; events in a 64-member group 22 KB, in a chief
  thread 5 KB today and 2.5 KB with head diffs.
- AS4. Commit cost grows with JSON head size at about 5 to 20 ms per 1 to 2 MB (UNVERIFIED; C-4
  measures it).
- AS5. Prices are A18 for Cloudflare DO items and A19 for PlanetScale; R2, KV and gzip ratios are
  UNVERIFIED (P6).
- AS6. GitHub does not retry failed webhook deliveries automatically; GitHub API limits are about
  5,000 to 15,000 requests per hour per installation (both UNVERIFIED).
- AS7. Online installs average about 15k at 100k MAU (derived from A8's 23k peak sockets).
