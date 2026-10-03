# Backend lead: stage B resume note (parked 2026-10-02, Claude capacity 2/28)

Resume after the Oct 4 reset. Branch for stage B code: `backend-home-routes` (off feat-cmux-next; no code yet).

## In flight when parked

- https://github.com/manaflow-ai/cmux/pull/16861 (Home catalog): base merged in, generated catalog and client regenerated (106 ops), protocol index exports `ops-home.ts` and `ops-home-schemas.ts`. Self-reviewed (owners, risks, principals). Next: merge when the CI `test` check passes.
- https://github.com/manaflow-ai/cmux/pull/16859 (0006_home schema + projections): base merged in (3c6821bb240), migration lint and projection tests pass, label `backend:apply-migrations` added (applies to staging and production before merge). Next: confirm `apply-staging`, `apply-production` and `backend migrations applied` pass, then merge. Tables hold no raw address, secret or token hash; `home_message_search` holds message text for home.search (by design).

## Stage B order (approved by the coordinator)

1. Home HTTP routes: `ownerRoute` cases for cloud:ConversationDO (keyed by `params.id`/conversation, stripped from params), cloud:MuxDO (agent, principal through withGrantClasses for install_kind), cloud:planetscale (home.search through a read-only Hyperdrive); inbox ops to UserDO `submitInbox`/`readInbox`. Worker derivations: conversation id, invite_id, address id (HMAC HOME_ADDRESS_KEY), token_hash, proof. Endpoints `GET /v1/invites/card/<code>` (open invite only, never user-to-user DM; the staging card waits on this), `POST /v1/invites/preview`, invite.accept with acceptLocked; `/v1/wire/conv/<id>` (E5); DM peer lookup (Q2); approval rules.
2. UserDO: delegate `user.text_confirm.*` and `user.presence_key.*` to home-core `reduceUserConfirm` (env user, installActive, installKind, chiefs, appIdHash, locale); presence-key route (macOS: install-key signature; iOS: App Attest attestation, then submitSystem `user.presence_key.register`); `install.revoke` and `install.revoke_by_team` also commit `user.presence_key.revoke`.
3. MuxDO route with install_kind; confirm streams `mux:<agent>` and `user:<user>` (system:mux:<agent>, system:user:<user>); conversation-search `{query, limit 1-100}` in POST /v1/read; one `mux.text_confirm.migrate` pass per chief after re-pushing team/MDM locks (minimum-only semantics).
4. Lane 15 security follow-ups: per-account phone link limits (5/day, 2 numbers/day) with one uniform answer; link page rules (home-messaging.md section 19); SendBlue fetch-by-handle before acting on a webhook; relink notice to the previous account.
5. Stage-A P3 leftovers: readInbox checks installActive; inbox prune slack; bind entity only after auth.

Stage C (after B): MailerDO (wrangler tag v8) and the mail path for `mail.security_notice`; FeedDO accepts feed.post notices from UserDO; AddressDO sends (vCard first, text after SENT/DELIVERED, allow list fail-closed, HOME_INVITES_SEND kill switch, every staging send logged and reported).

Other open items: shared teams after stage C (plan in enterprise.md); verify the OIDC callback's Stack server calls on staging the next time auth changes; Effect 4.0.0 bump after 2026-10-08; integrations gateway after stage C.

## home.search role (search-ro2), 2026-10-03

The first role (search-ro) inherited pg_read_all_data, granted by pscale_admin, which our roles
cannot revoke. It was replaced on development and staging by `search-ro2`, created with no
inherited roles, and granted by the table owner (migrator):

```sql
-- run as the migrator role (table owner) on the cmux-next branch; <ro> = the search-ro2 Postgres role name (username before the dot)
GRANT USAGE ON SCHEMA public TO "<ro>";
GRANT SELECT ON TABLE public.home_participants, public.home_message_search, public.home_conversations TO "<ro>";
```

Steps per branch (confirm the branch with `pscale branch show cmux-next <branch> --org cmux` first):
1. `pscale role create cmux-next <branch> search-ro2 --org cmux` (no `--inherited-roles`); store the URL in
   `~/.secrets/cmux-next-planetscale-ro-<env>.env` (mode 600).
2. The SQL above as migrator.
3. Check: `pg_has_role(<ro>, 'pg_read_all_data', 'MEMBER')` = false, SELECT on home_message_search = true,
   SELECT on audit_events = false, INSERT on home_message_search = false; a live `SELECT 1 FROM audit_events`
   as the role fails with permission denied.
4. `wrangler hyperdrive update <id> --connection-string=<new url>` (dev cb712d90..., staging 10bbf30d...,
   production 6badee5c...).
5. `pscale role delete cmux-next <branch> <old search-ro id> --org cmux --force --successor postgres`.

Done: development and staging (all checks passed, Hyperdrives use search-ro2, old role deleted).
Production (branch main, Hyperdrive 6badee5cbb964e9f9c09c6f175a14c85): done 2026-10-03 after the
coordinator's C-BATCH decision (same SQL and checks; all passed; Hyperdrive uses search-ro2; old
role deleted with --successor postgres).
New projection tables that search reads need the same GRANT.

## Queue after stage B (coordinator C-BATCH, 2026-10-03)

1. Drizzle for schema and queries: generated SQL migrations committed, reviewed and applied through
   the backend:apply-migrations gate; a test proves the Drizzle schema equals today's database
   (introspect the scratch Postgres after all migrations and diff); raw SQL only where Drizzle is
   poor (home.search). Starts after conversation.import and the chief records (both done).
2. Stage C: MailerDO (tag at landing), AddressDO sends (vCard first, allow list fail-closed, kill
   switch, logged staging sends), invite limits, lane 15 phone-link rules, and
   `install.enroll_local` (the daemon enrolls as its own install per ownership-v2, with a
   narrowed grant: read and mutate-own on its own host objects, no send-external, money or
   destructive).
3. Automations dogfood hard cap: $25 per team per UTC month (automations lead enforces; backend
   reviews the meter).

## Drizzle, step 1 (2026-10-03)

`backend/db/schema/index.ts` is the Drizzle schema, pulled from the database the committed
migrations build; `test-pg/drizzle-schema.test.ts` pulls again in CI and fails on any difference
(checked: an added column fails it). `drizzle/` holds the generate snapshots (baseline 0000, never
applied); schema changes follow `backend/db/drizzle/README.md` and still land as reviewed
`migrations/NNNN_*.sql` through the apply gate. Not modeled: the hash-partitioned
`home_message_search` (raw SQL in 0006 and home-search.ts). Next steps: move the projection
writes (apps/api/src/projection.ts) and the other queries to Drizzle query builders, one table group
per commit, each with the existing tests.

## Production high availability (2026-10-03)

Approved by Lawrence through the coordinator (+$10/month). Confirmed cmux-next/main is the
production branch, then `pscale branch resize cmux-next main --replicas 2 --org cmux --wait`.
Change request wo8mbi6eghr0 completed: PS_5_AWS_ARM, replicas 0 -> 2 ("highly available",
$15/month instead of $5). Size kept at PS-5 (no headroom resize). The production API answered 200
after the change.

## Worker Loader binding (automations lead, 2026-10-03)

`worker_loaders: [{ binding: "LOADER" }]` is in every env block of backend/apps/api/wrangler.jsonc. Only Tier 1 code automations use it (backend/apps/api/src/code-run.ts, plans/cmux-next/automations-plan.md slice 3). The coordinator assigned this line to the automations lead while the backend lead is parked. Tenant Dynamic Workers get no bindings and no network (`globalOutbound: null`) until the egress gateway and env.cmux land (slice 4). `AutomationTail` (a WorkerEntrypoint export of the API Worker) is attached as their tail.
