# Durable Object audit: which entities deserve a DO

Status: proposal for the backend lead, 2026-10-03 (branch feat-cmux-next-do-audit). Documentation only;
no code, wrangler or schema changes. Question from Lawrence: which entities really need a Durable
Object, and is AddressDO one of them?

Read for this audit (at 6099e49ab80): every class bound in `backend/apps/api/wrangler.jsonc`
(UserDO, TeamDO, SchedulerDO, ConnectionDO, AccountIndexDO, FeedDO, ConversationDO, MuxDO,
AddressDO, DomainDO, PairingDO, HostDO, UsageMeterDO, TeamVmDO), `owner-do.ts`, `do-outbox.ts`,
`secondary-stream.ts`, `backend/packages/ownership/src/{engine,schema}.ts`, the home-core domains
(`address/*`, `invites/limits.ts`, `mux/domain.ts`), the callers (`home-routes.ts`,
`home-text.ts`, `home-send.ts`, `auth.ts`, `policy-gate.ts`, `sso-discover.ts`, `ingress/*`),
`db/migrations/*.sql`, backend.md, home-messaging.md (sections 2, 3, 6, 9, 10, 12, 17),
OWNERSHIP-PRINCIPLES.md and home-scale.md on feat-cmux-next-home-scale. MailerDO is planned
(backend.md, stage C) but does not exist yet; it is covered as a forward-looking row.

## 1. The test

A DO earns its place when the entity needs at least one of these, and the alternative costs more:

| Id | Reason | What only a DO gives cheaply |
| --- | --- | --- |
| R1 | Single writer: dense sequences, an idempotency ledger, invariants across fields, a transactional outbox | one thread, local SQLite, state + ledger + events + outbox in one synchronous transaction (`OwnerEngine`) |
| R2 | Lock: single flight, claim once, lease | the object is single-threaded; an in-memory map or one row is the lock |
| R3 | Alarm: a timer per entity | `setAlarm`, durable, per object, no sweep over all entities |
| R4 | Realtime: WebSocket fan-out | hibernating sockets with attachments, no cost while idle |

Alternatives: a Worker with PlanetScale Postgres (transactions, `SELECT ... FOR UPDATE`, unique
constraints, `INSERT ... ON CONFLICT`, conditional `UPDATE ... RETURNING`), or a Cloudflare binding
(Rate Limiting, KV, Queues, Workflows, cron).

One constraint changes the arithmetic for every "replace with PlanetScale" verdict. Today
PlanetScale is never a system of record: every table is written only by outbox drains
(home-messaging.md section 3, home-scale.md A3, backend.md "Tables hold no raw address, secret or
token hash"), and no request path reads it except `home.search` through a read-only replica role.
Making PlanetScale the owner of an entity means: (a) that request path now fails when the
PlanetScale primary is down or slow; (b) every write pays a Worker to Hyperdrive to primary round
trip in one region, per statement, instead of local SQLite; (c) the production cluster is PS-5 with
two replicas (backend.md, 15 USD per month), sized for projections, not for request-path writes;
(d) the schema goes through the `backend:apply-migrations` gate. A replacement must win against
these costs, not only against "a DO is heavier".

## 2. Verdicts

| Class | Key | State it owns | R1 | R2 | R3 | R4 | Volume at 100k MAU | Verdict |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| ConversationDO | conversation id | head, participants, messages (rows), reactions, cursors, invites, accept-failure lock | yes: dense `seq`, `client_msg_id` ledger, participant and invite invariants | yes: accept lock (`home_accept_failures`) | planned: retention deletes (section 10) | yes: `conv:<id>` subscribers, typing in memory | 34M committed ops/day, peak 20 ops/s per conversation | keep |
| UserDO | user id | installs, grants, revocation, push targets, chiefs, auth challenges; second stream `inbox:<user>` | yes: grants, revocation, inbox `rev` max-merge | yes: single-use challenge nonces | yes: `ssh_revoke_pending` retries, inbox prune | yes: gateway (`user:` + `inbox:`) | heaviest user about 2,300 bumps/day; plus one `installGrant` RPC per install-token request to another owner | keep; take `installGrant` off the per-request path (section 4.2) |
| TeamDO | team id | members, policy versions, hosts directory, SSO, SSH CA, domain claims (via DomainDO), server enrollment | yes: policy versions, member invariants | no | yes: domain recheck, server revocation flush, integration lock sync | yes: `team:<team>` | low (admin ops), never on the message path | keep |
| SchedulerDO | team id | automations, schedules, runs, webhook delivery dedupe (30 days), run token bucket | yes: run state machine, delivery dedupe, exact token bucket | no | yes: cron fires, run deadlines, deferred deliveries | yes: `scheduler:<team>` | automation fires and deliveries per team | keep |
| ConnectionDO | team id | connection records; sealed credentials; external-call ledger; Gmail watches; revocations; reseal queue | yes: external-effect ledger with `mutation.indeterminate` | yes: one token refresh per connection (`refreshing` map; rotating refresh tokens are single use) | yes: pending expiry, watch renewals, provider revocations, reseal | yes: `connections:<team>` | per provider call and webhook | keep |
| AccountIndexDO | provider account key | `links (team, connection, failures)`, Gmail `stop_claim` lease | no invariant across rows | yes, small: `claimStop` lease | no | no | one `list()` per provider webhook | keep the class; fix its lossy maintenance through the E4 outbox (section 4.3) |
| FeedDO | user id | feed items, triage, push rules; presence in socket attachments | yes | no | yes: expiry, snooze wake, push due, prune | yes, and presence needs the sockets in the same object | agent-posted items per user (UNMEASURED) | keep; merge into UserDO only if socket counts require it (open question Q4) |
| MuxDO | chief (agent) id | wake queue rows, ack cursors, confirm-level state | yes: per-conversation ack cursor, bounded queue | no | planned: cloud brain loop | yes: brain host subscribes to `mux:<agent>` | about 1 wake per human message in a chief thread plus mentions | keep |
| AddressDO | `addr_<26>` (HMAC) | raw address, suppression, per-recipient windows, delivery ledger, invite secret stash, send attempts, contact-card steps, text-link state | yes (section 3) | yes: one provider attempt per delivery | yes: stale attempt 10 min, card wait 24 h, secret expiry 24 h; needed: 180-day raw-address purge, 3-day reminder | no | 3k to 10k invites/day (0.04 to 0.12/s mean), plus SendBlue statuses and later inbound texts | keep (section 3); small fixes listed |
| DomainDO | email domain | one row: owning team | yes: first verifier wins (a unique constraint) | no | no | no | one read per SSO gate cache miss (30 s per isolate) | keep (section 4.4) |
| PairingDO | pairing code | one pending pairing, claim, result | yes: single use | yes: first approver claims | yes: one-shot expiry | yes: waiting server holds a hibernating socket | a few per server enrollment | keep |
| HostDO | host id | relay reachability; sockets of host and clients | no | no | no | yes: the whole purpose is a socket relay | one host socket per host, binary relay frames | keep |
| UsageMeterDO | team id | usage ledger (35-day dedupe), monthly counters in integer micro-dollars, cap | yes: dedupe by key + counter + cap answer in one transaction | no | yes: dedupe-key prune | yes: `usage:<team>` | one `record` per tail invocation and step boundary | keep |
| TeamVmDO | team id | VM record, epoch, leases, provider single flight, team journal (up to 8 GB) | yes: journal is a dense seq per stream, the zero-loss tier | yes: one provider call at a time (`inflight`) | yes: lease expiry, repair of an interrupted provider call | yes: `team_vm:<team>` | low op rate, large journal bytes | keep |
| MailerDO (planned, stage C) | not yet decided | mail sends for `mail.security_notice` | depends | depends | depends | no | low | decide with the test in section 6 before it lands (Q1) |

No class fails the test badly enough to justify a migration now. Two classes (AccountIndexDO and
DomainDO) would fit PlanetScale by shape, but both sit on paths that today do not depend on
PlanetScale (provider webhooks, the SSO gate on every request), so moving them adds an availability
dependency in exchange for very little. The real problems found are inside classes, not in the
choice of class: section 4.

## 3. AddressDO in detail

### 3.1 What it holds and does today

- State (`AddressHead`, one JSON value): `id`, `channel`, `value` (the raw normalized address),
  `linked_user`, `suppression {reason, at}`, `window.lastByInviter` (inviter to last send time),
  `deliveries[]` (last 50, each with a forward-only `state` rank and `provider_id`), `texted`,
  `link` (pending phone-link codes, attempts, binding).
- Side tables outside op state: `address_secrets` (invite secret, 24 h), `address_attempts` (one row
  per delivery, written before the provider call), `address_card_steps` and `address_card_sent`
  (the vCard-first rule for a new number).
- Ops (`address/domain.ts`): `address.ensure`, `address.deliver` (from ConversationDO's outbox),
  `address.delivery.record`, `address.suppress`, `address.unsuppress` (only a Stack-verified owner
  of the email), `address.resubscribe`, `address.link`, `address.text_link.request|confirm|unlink`,
  `address.inbound.note`. Reports go back to ConversationDO as `invite.delivery.report` outbox
  items with key `delivery:<invite>:<state>`.
- External effects (`address-do.ts`): the alarm sends each `sending` delivery once; SendBlue
  webhooks arrive through `textEvent`, which releases texts waiting on a card and suppresses on
  STOP.
- No subscribers (`maySubscribe` returns false), no client reads.

### 3.2 Does it need a single writer?

Yes, for four facts that change together and are read together in one decision:

1. The 3-distinct-inviters-per-30-days cap (`takeAddressQuota`). Two inviters who invite the same
   address at the same moment must not both pass when one slot is left. That is a read-decide-write
   across rows, so it needs serialization per address.
2. Suppression beats every send, including a send that is already queued: the alarm reads the state
   again before each text (`onWake` comment: "a STOP that came in during an earlier send of this
   wake stops this text").
3. One card per new number: later invites to the same number wait for the first card's status, and
   all of them close together if the card never reports (`address_card_steps`).
4. Forward-only delivery states with terminal ranks, plus a report outbox in the same transaction.

Per-address serialization is the requirement. A DO gives it by construction. Postgres gives it with
`SELECT ... FROM home_addresses WHERE id = $1 FOR UPDATE` at the start of every transaction that
touches the address. Both are correct; neither has contention at this volume.

### 3.3 The other reasons

- Lock (R2): "one provider attempt per delivery, ever". Today: `INSERT INTO address_attempts ...
  ON CONFLICT DO NOTHING` before the call, and the DO output gate holds the outgoing fetch until the
  insert is durable. Postgres equivalent: `UPDATE home_address_deliveries SET attempt_at = now()
  WHERE invite_id = $1 AND attempt_at IS NULL AND state = 'sending' RETURNING ...`, committed before
  the call; only the caller that gets a row back calls the provider.
- Alarm (R3): three timers exist (stale attempt 10 min, card wait 24 h, secret expiry 24 h) and two
  are required by the spec but not built yet: the 180-day raw-address purge (section 10) and the
  3-day reminder (section 9). Without a DO: a cron sweep (today production cron runs every 6 h; a
  1-minute cron would be needed) or Queues delayed messages (maximum delay 12 h, UNVERIFIED; the 24 h
  card wait would need a re-enqueue).
- Realtime (R4): none.
- Rate windows: a Cloudflare Rate Limiting binding cannot hold them. Bindings count per colo,
  approximately, over 10 s or 60 s periods; the address windows are exact and last 7 and 30 days.
  They need storage in either design.

### 3.4 Raw address and privacy

Today the raw address exists in exactly one place: the SQLite of the object named by its HMAC id
(`addr_` = HMAC-SHA256(HOME_ADDRESS_KEY, normalized address)). It also appears in that same object's
`own_events` params for `address.ensure` (30-day retention) and inside the ledger `params_hash`
(SHA-256 of a low-entropy phone number is reversible by enumeration, but it sits next to the raw
value anyway). PlanetScale holds only `address_id` (`home_invites`). Deletion is `deleteAll()` on one
object. No replica, no shared role, no backup we operate.

In PlanetScale the raw address would sit on the primary, on both replicas and in PlanetScale's
backups, readable by any role with SELECT on the table (migrator, postgres, pscale admins). That
needs application-level encryption (AES-256-GCM with a new secret, for example
HOME_ADDRESS_ENC_KEY, nonce per row) on top of the HMAC id, and the 180-day purge would not reach
backups until they expire. This is a real cost of the replacement, not a reason invented to keep
the DO.

### 3.5 Delivery ledger and indeterminate outcomes

The rule is: an attempt with no recorded outcome after its deadline closes as `indeterminate` and is
never resent (a provider may have delivered it). Both designs implement it the same way: claim
before the call, record after, sweep the claimed-but-unrecorded rows at the deadline. The DO does the
sweep per object in its alarm; Postgres does it with one statement per sweep over all addresses
(`UPDATE ... SET state = 'indeterminate' WHERE state = 'sending' AND attempt_at < now() - interval
'10 minutes' AND card_handle IS NULL RETURNING invite_id, conversation_id`). The Postgres sweep is
simpler to reason about in bulk; the DO alarm needs no global scan. Neither needs a single writer
beyond the claim.

### 3.6 Replacement design (written out so the choice is explicit)

Tables (new migration, `backend:apply-migrations` gate):

```sql
CREATE TABLE home_addresses (
  id                 text PRIMARY KEY,          -- addr_<26>, HMAC(HOME_ADDRESS_KEY, normalized)
  channel            text NOT NULL CHECK (channel IN ('email', 'sms')),
  value_enc          bytea,                     -- AES-256-GCM(HOME_ADDRESS_ENC_KEY); NULL after the 180-day purge
  linked_user        text,
  suppression_reason text CHECK (suppression_reason IN ('opted_out','bounced','complained','reported','admin')),
  suppressed_at      timestamptz,
  texted             boolean NOT NULL DEFAULT false,
  card_sent_at       timestamptz,               -- this number got the cmux contact card
  link               jsonb,                     -- text-link pending codes, attempts, binding (text-link.ts shape)
  last_invite_at     timestamptz NOT NULL
);
CREATE TABLE home_address_inviters (
  address_id   text NOT NULL REFERENCES home_addresses(id) ON DELETE CASCADE,
  inviter      text NOT NULL,
  last_sent_at timestamptz NOT NULL,
  PRIMARY KEY (address_id, inviter)
);
CREATE TABLE home_address_deliveries (
  invite_id         text PRIMARY KEY,
  address_id        text NOT NULL REFERENCES home_addresses(id) ON DELETE CASCADE,
  conversation_id   text NOT NULL,
  inviter           text NOT NULL,
  state             text NOT NULL,
  state_rank        smallint NOT NULL,          -- RANK from address/domain.ts; 9 = terminal
  provider_id       text,
  attempt_at        timestamptz,                -- the claim; set once, before the provider call
  card_handle       text,
  card_at           timestamptz,
  secret_enc        bytea,                      -- invite secret, encrypted, cleared after the attempt or 24 h
  updated_at        timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX ON home_address_deliveries (state, attempt_at) WHERE state = 'sending';
```

Flow:

1. `invite.create` (Worker): `INSERT INTO home_addresses ... ON CONFLICT (id) DO NOTHING`, then store
   `secret_enc` in a deliveries row with state `pending_deliver` (replaces `stashSecret`).
2. ConversationDO outbox `address.deliver`: the drain needs a new channel kind (a Queue producer or
   a Worker RPC) because today it only drains to PlanetScale projections or to DO targets. The
   consumer runs one transaction: lock the address row `FOR UPDATE`; `INSERT ... ON CONFLICT
   (invite_id) DO UPDATE ... WHERE state = 'pending_deliver' RETURNING` (a replay returns the prior
   state); if suppressed, state `suppressed`; else read `home_address_inviters` for 30 days, run the
   same pure `takeAddressQuota`, upsert the inviter row; commit; enqueue a send message when the
   state is `sending`.
3. Send consumer (Queues, at least once): claim with the conditional `UPDATE ... attempt_at`
   above; lock the address row `FOR UPDATE` for the card rule; re-check suppression; call the
   provider; record with `UPDATE ... SET state = $s, state_rank = $r WHERE invite_id = $1 AND
   state_rank < $r AND state_rank < 9`; report to ConversationDO by RPC `systemDeliver` with key
   `delivery:<invite>:<state>` (its ledger makes the retry safe).
4. SendBlue webhook: `UPDATE home_addresses SET suppression_reason = 'opted_out', suppressed_at =
   now() WHERE id = $1 AND suppression_reason IS NULL`; card status releases waiting deliveries by
   enqueuing their send messages.
5. Cron, every minute: the indeterminate sweep (10 min and 24 h deadlines), secret expiry, reminder
   selection, and `UPDATE home_addresses SET value_enc = NULL, link = NULL WHERE last_invite_at <
   now() - interval '180 days' AND suppression_reason IS NULL`.

Cost and latency of the replacement: about 3 PlanetScale transactions, 1 to 2 Queue messages and
one RPC per invite, at 3k to 10k invites per day: negligible in money for both designs (the DO side
is well under 1 USD per month at these counts with A18 prices). The invite path changes from one DO
RPC (`stashSecret`, often cross-colo, 50 to 150 ms) to one to two PlanetScale round trips from the
Worker colo to the primary region (10 to 80 ms each, UNVERIFIED). The send path gains Queues and a
1-minute cron as new moving parts.

### 3.7 Verdict for AddressDO: keep

Three of the four reasons apply (single writer across suppression, windows, card steps and
deliveries; the attempt-once lock; five per-entity timers). The replacement is correct but rebuilds
each of them from three services (Postgres row locks, Queues, cron), adds a new outbox channel kind
to the engine, moves raw PII into the shared database with application-level encryption, and gains
nothing measurable at about 0.1 invites per second. Lawrence's doubt is fair in one sense: no single
reason is unique to a DO here. But the combination is exactly what a DO is for, and the code that
handles the hard part (claim before call, indeterminate close, STOP during a send) already exists
and is tested.

What would flip the verdict: (a) a need to query across addresses in real time (operator admin
blocks by list, bulk import of provider suppression lists, compliance reports), which a non-PII
projection can also serve; (b) a decision to keep a raw-address copy in PlanetScale anyway; (c)
invite volume large enough that per-object cold starts dominate (not expected).

Small fixes that the audit recommends inside AddressDO (no class change):

- F1. Build the two missing timers as alarm work: the 180-day raw-address purge (clear `value`,
  `link`, side tables; keep `suppression` forever, section 10) and the 3-day reminder (section 9).
- F2. Stop storing events in an owner with no subscribers: an engine option (for example
  `noEvents`) or `redact.params` for `address.ensure` so the raw address is not copied into
  `own_events`. Today it is the same object, so this is hygiene, not a leak.
- F3. Project a non-PII row per address (`address_id`, `suppression_reason`, `suppressed_at`,
  counts) through the existing PlanetScale channel, for admin and abuse reports, if the backend lead
  wants cross-address reads (Q3).
- F4. An operator path for `address.suppress {reason: "admin"}` by raw address (the Worker derives
  the HMAC id), so abuse handling does not need a DO console.

## 4. Other classes: short notes

### 4.1 ConversationDO, PairingDO, HostDO, TeamVmDO, ConnectionDO, UsageMeterDO: never touch the class choice

Each of these depends on something a Worker plus Postgres cannot do without rebuilding it:
ConversationDO (dense seq, realtime, accept lock), PairingDO (hibernating wait socket plus one-shot
expiry plus first-claim), HostDO (a socket relay; nothing else can hold the sockets), TeamVmDO
(single-flight provider calls plus an acknowledged-durable journal, the zero-loss tier),
ConnectionDO (sealed credentials kept out of every projection, the external-effect ledger, the
in-memory single-flight refresh that is correct only because there is one instance), UsageMeterDO
(the money cap: dedupe, counter and the allowed answer in one local transaction, called on every
step boundary, where a PlanetScale write per step would add latency and load to the run path).

Watch item, not a class change: TeamVmDO's journal is capped at 8 GB (`MAX_JOURNAL_BYTES`) of the
10 GB object limit until compaction to R2 (S6b). Q6.

### 4.2 UserDO: keep, but remove the per-request grant check

`withGrantClasses` (`auth.ts`) calls `UserDO.installGrant` for every install-token request to any
other owner, with no cache. That puts one user's object on the path of every HTTP op the user's
installs make, including ops for ConversationDO, MuxDO and team objects. Options, in order of
preference: (a) a per-isolate cache with the same 30 s TTL that `policy-gate.ts` already uses for
sign-in rules and domain owners, accepting that an HTTP request may pass up to 30 s after a revoke
(sockets are closed at once by `closeSockets` either way); (b) grant classes in the install JWT,
with a revocation list pushed to KV. The revocation bound is a product decision (Q2). This is the
largest DO-load item found, and it needs no class change.

### 4.3 AccountIndexDO: keep the class, fix how it is written

By shape it is a lookup index (provider account to linked team connections) with a failure counter
and one lease; PlanetScale would serve it with `PRIMARY KEY (account, team, connection)`,
`INSERT ... ON CONFLICT DO NOTHING`, a conditional `UPDATE` for failures, and for the lease:

```sql
INSERT INTO integration_stop_claims (account, connection, state, at) VALUES ($1, $2, 'running', now())
ON CONFLICT (account) DO UPDATE SET connection = excluded.connection, state = 'running', at = now()
WHERE (integration_stop_claims.state = 'running' AND integration_stop_claims.at < now() - $lease)
   OR (integration_stop_claims.state = 'done' AND integration_stop_claims.at < now() - $done_ttl)
RETURNING connection;
```

But the read is on the provider-webhook path, and GitHub does not retry failed webhook deliveries
automatically (manual redelivery only, UNVERIFIED for the current GitHub App settings), so a
PlanetScale outage would drop GitHub events that today do not depend on PlanetScale. The real defect
is different: ConnectionDO calls `add`/`remove` after its own commit as best effort ("a lost entry
only drops webhooks for that connection until it re-links"). Fix: emit `account_index.add` and
`account_index.remove` as E4 outbox target items (`target {class: "AccountIndexDO", name: account}`)
in the same commit as the connection change, so delivery is at least once and idempotent
(`INSERT OR IGNORE`, `DELETE`). Optional: also project the links to PlanetScale for admin reads.

### 4.4 DomainDO: keep

DomainDO is a 43-line unique constraint ("first team to verify owns the domain"). A PlanetScale
table `team_domains (domain text PRIMARY KEY, team text NOT NULL, verified_at timestamptz NOT NULL)`
with `INSERT ... ON CONFLICT (domain) DO NOTHING RETURNING team` would hold it exactly. It stays a DO
because its read is on the SSO gate (`policy-gate.ts` `domainOwner`, every request, cached 30 s per
isolate) and on sign-in discovery: moving it makes authentication depend on PlanetScale. Enumeration
for admin can come from TeamDO projections (each TeamDO knows its verified domains) without moving
the owner.

If the backend lead still wants to replace it, the steps are those of section 5 with the backfill
taken from every TeamDO's verified domains (a DO namespace cannot be listed), dual writes from
`TeamDO.recheckDomains` and `domainOp` (DO first, then PlanetScale; reads still from the DO), a
comparison job, a read switch with fail-closed behavior for SSO enforcement when PlanetScale is
unreachable, and only then `deleted_classes`.

### 4.5 FeedDO and MuxDO: keep, no merge now

FeedDO and UserDO are both per user. Merging FeedDO into UserDO as a third `SecondaryStream` would
save one socket per device (home-scale.md counts sockets and incoming messages as cost), but it
would put agent-posted feed writes and APNs sends into the object that serves auth and inbox bumps.
Decide with socket telemetry (Q4). MuxDO stays separate from UserDO because a chief's wake queue
aggregates many conversations and will host the cloud brain loop (alarm-driven turns).

### 4.6 SchedulerDO, UsageMeterDO, TeamVmDO, ConnectionDO, TeamDO: five per-team objects, no merge

All five are keyed by team id. Merging would save RPC hops between them but would put webhook
ingestion, usage recording on every step, VM provider calls and admin policy writes on one thread,
and one failure (a stuck alarm, a full journal) would stop all of them. The split follows write rate
and failure domain; keep it.

## 5. Migration rules for any class change (for reference)

Not needed by this audit's verdicts, recorded so a later change does not lose data:

1. A DO namespace cannot be listed from the Worker. Every backfill needs an external list of keys:
   PlanetScale projections (`home_invites.address_id` for AddressDO, `connections` for
   AccountIndexDO) or owner state (TeamDO for DomainDO).
2. Order: new store and dual writes (DO stays the owner) -> backfill -> comparison job until zero
   differences -> switch reads -> stop DO writes -> one release later, delete the class.
3. Deleting a class: remove its binding from all four `durable_objects.bindings` lists
   (top level, development, staging, production), remove the export from `index.ts`, and append a
   new tag such as `{ "tag": "v11", "deleted_classes": ["DomainDO"] }` to all four `migrations`
   lists. Tags are append-only and applied in order; never edit an applied tag. `deleted_classes`
   deletes every object's storage of that class at deploy; after it, a rollback to a version that
   still binds the class is not possible (UNVERIFIED wording of the Cloudflare refusal; plan as if
   rollback is blocked). Use `renamed_classes` or `transferred_classes` only to keep the data.
4. External-effect ledgers (ConnectionDO `external_calls`, AddressDO `address_attempts`) must move
   with their in-flight rows: a claimed attempt with no outcome must arrive in the new store as
   claimed, or the new path will send twice. Drain them first (stop new claims, wait past the
   deadline, let the sweep close them as indeterminate), then migrate.
5. Client protocol: a class that has subscribers (`maySubscribe`) carries a stream name in
   `cmux.wire/1`. AddressDO, DomainDO and AccountIndexDO have none, so their replacement would not
   change the client protocol. Merging FeedDO into UserDO would change the stream's socket and
   needs a client release.

## 6. Ranked plan

1. UserDO grant check off the per-request path (section 4.2). Highest load effect, no class change,
   needs Q2.
2. AccountIndexDO maintenance through E4 outbox items (section 4.3). Fixes silent webhook loss.
3. AddressDO F1 (180-day purge, 3-day reminder) before stage C sends reach production; F2 with it.
4. The missing per-network rate limits for `invite.create`, `dm.open` by address and
   `invite.preview` (home-messaging.md section 9 and E6) as Cloudflare Rate Limiting bindings
   (30 per minute per IP). wrangler.jsonc has only `SSO_DISCOVER_LIMIT`, `PAIR_BEGIN_LIMIT` and
   `GOOGLE_HOOK_FAIL_LIMIT` today. These are per-IP burst limits: a binding, never a DO.
5. MailerDO: apply the test before it lands (Q1). If its only job is to send one mail per notice
   with retries, a Queue consumer with a PlanetScale or DO-side idempotency key is enough; it needs a
   DO only if it owns per-recipient suppression or windows, in which case those belong in AddressDO
   (email addresses are already AddressDO entities).
6. AddressDO F3 and F4 when abuse handling needs them.

Never touch (class choice): ConversationDO, PairingDO, HostDO, ConnectionDO (credentials and the
external-call ledger), TeamVmDO (journal), UsageMeterDO (money cap). Do not move any owner to
PlanetScale while the production cluster is sized for projections only.

## 7. Open questions for the backend lead

- Q1. MailerDO: what state does it own beyond what AddressDO already owns for email addresses? If
  none, should mail sends live in AddressDO (one sender per address, same suppression) or in a Queue
  consumer?
- Q2. What revocation bound is acceptable for HTTP ops after `install.revoke`: 0 s (today), 30 s
  (cache), or another value?
- Q3. Do abuse and operator workflows need cross-address queries now (F3), or later?
- Q4. Is one socket per device for FeedDO a measured cost? If yes, merge FeedDO into UserDO as a
  third stream; if no, keep.
- Q5. Is "PlanetScale is never a system of record" a rule the backend lead wants to keep? This
  audit assumes yes; if it changes, AccountIndexDO and DomainDO become cheap replacements.
- Q6. TeamVmDO journal compaction to R2 (S6b): when does a team reach the 8 GB cap at expected use?

## 8. Assumptions

- AS1. Volumes are home-messaging.md section 6 and home-scale.md B1 (100k MAU, 40k DAU, 34M
  committed ops per day, peak 2,000 ops/s). Invites: 1 to 3 per active user per month, so 3k to 10k
  per day. Feed, scheduler and usage volumes are not measured.
- AS2. Prices are home-scale.md A18 (UNVERIFIED list prices). No verdict here depends on price; all
  affected classes cost well under 10 USD per month at the stated volumes.
- AS3. PlanetScale latency from a Worker colo through Hyperdrive to the primary is 10 to 80 ms per
  round trip (UNVERIFIED; depends on colo and region). DO RPC across colos is 50 to 150 ms
  (home-scale.md B6).
- AS4. The DO output gate holds outgoing fetches until pending SQLite writes are durable, which
  `address-do.ts` relies on for claim-before-call (Cloudflare documents output gates for outgoing
  messages; not re-checked for subrequests in this audit).
- AS5. Cloudflare Rate Limiting bindings support only 10 s and 60 s periods and count per colo
  approximately; Queues delayed delivery is at most 12 h (both UNVERIFIED against current docs).
- AS6. GitHub does not retry failed webhook deliveries automatically (UNVERIFIED).
- AS7. The production cluster is PS-5 with two replicas (backend.md, 2026-10-03).
