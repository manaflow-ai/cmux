# cmux-next Cloud release rails

Agents push, migrate, bake and deploy cmux-next Cloud without a human step. These
rails make that safe. Code: `scripts/cmux-next/release/` (tests in its `test/`, CI in
`.github/workflows/release-rails.yml`). PlanetScale org `cmux`; the tooling takes a tree
and a target and reads database, branch and schema from `trees.ts`:

| tree | migrations | database | schema | Worker |
| --- | --- | --- | --- | --- |
| `cmux-vm` | `workers/cmux-vm/migrations` | `cmux-prod` (shared with cmux-old's web/, schema public) | `cmux_vm` | `cmux-vm-staging` |
| `backend` | `backend/db/migrations` | `cmux-next` | `public` | `cmux-api-staging`, `cmux-api` |

Targets: `development`, `staging`, `production` (PlanetScale branch `main`).

## What each gate refuses

**Migration lint** (`lint.ts` + `lint-rules.ts`; runs in `cmux-vm.yml` check, `backend.yml`
test and push guard, and before every rehearse and apply). Three layers on the parsed SQL:
1. *Never*, even with a header: DO, functions/procedures, TRUNCATE, roles and role
   membership, default privileges, OWNER TO, SET SCHEMA, schema RENAME, RLS
   enable/disable/force, triggers, rules, policies, a top-level SELECT (setval, set_config,
   pg_terminate_backend), SET, ALTER DATABASE/SYSTEM, COPY, LOCK, CLUSTER, REINDEX, VACUUM,
   REFRESH, LISTEN/NOTIFY, foreign data, publications, REVOKE, GRANT beyond
   `role-contract.json` (ALL, PUBLIC, GRANT OPTION, ON ALL IN SCHEMA, unlisted
   grantee/privilege/schema), BEGIN/COMMIT; for cmux-vm also CREATE EXTENSION. Anywhere in
   the tree (defaults, checks, backfills): a function outside `ALLOWED_FUNCTIONS` (lint-rules.ts;
   so no setval, nextval, set_config, query_to_xml, pg_terminate_backend, pg_sleep) and any cast
   to a reg* type.
2. *Expand allowlist*; anything else needs `-- contract: <reason>` (10+ characters) in the
   leading comment block: CREATE TABLE/SCHEMA/SEQUENCE/TYPE/DOMAIN, COMMENT, INSERT,
   UPDATE/DELETE with a WHERE that reads a column (`WHERE true` and `WHERE 1 = 1` do not), ALTER TYPE ADD
   VALUE, CREATE INDEX (CONCURRENTLY and non-unique on an existing table, alone in its
   file), and on an existing table only ADD COLUMN (nullable or NOT NULL with a stable
   DEFAULT: constants, casts, CURRENT_*, now(); no IDENTITY, GENERATED, UNIQUE or PRIMARY
   KEY), SET DEFAULT, DROP NOT NULL, ADD CONSTRAINT CHECK/FOREIGN KEY NOT VALID, VALIDATE.
   A table created in the same file may be shaped freely (except layer 1).
3. *cmux-vm confinement*, even with a header: every name (any node with a relname: tables,
   views, CTAS targets, sequences, policy tables, composite types; qualified types and
   functions; created types and domains, which must be qualified; COMMENT targets) is in schema `cmux_vm`
   (pg_catalog allowed for types and functions), because cmux-old shares the database.

Every tree: `NNNN_lower_snake.sql`, numbered from 0001 without gaps; every file in
`migrations.lock.json` with its sha256; a landed file never changes or disappears; lock
entries are append-only; `--base <previous head>` also compares that revision's files and
lock and requires new numbers above its highest. cmux-vm: `REQUIRED_SCHEMA` in
`workers/cmux-vm/src/db/schema-requirements.ts` must name the newest file's number (add the
table, column or index it creates). Files up to `grandfatheredThrough` (cmux-vm 0008,
backend 0006) predate the rules and are hash-checked only. backend files keep
`-- phase: contract` and `-- contract:` together.

**Runner guards** (`runner.ts`, independent of the lint). Each file runs in its own
transaction with `lock_timeout = 3s` and `statement_timeout = 10min` (env
`CMUX_RELEASE_LOCK_TIMEOUT`, `CMUX_RELEASE_STATEMENT_TIMEOUT`); cmux-vm files also with
`search_path = cmux_vm, pg_catalog`. Before COMMIT a cmux-vm file is rolled back when this
transaction wrote rows outside cmux_vm (`pg_stat_xact_user_tables`) or catalog rows outside
cmux_vm (pg_class, pg_attribute, pg_attrdef, pg_constraint, pg_index, pg_trigger, pg_policy,
pg_rewrite, pg_proc, pg_type, pg_namespace with this transaction's xid): DDL, TRUNCATE, GRANT,
a foreign key into public and a new schema all show up. A CONCURRENTLY file must name a
cmux_vm table and leave a valid index.

**Rehearse** (`db-release.ts rehearse`) refuses to start when the lint fails, the target
has a changed applied file, or (backend) rows the tree lacks. It fails when the throwaway
copy differs from the target (stale backup), a file fails to apply, anything stays
pending, the Worker schema check finds a missing table or column, or a table does not
answer a read. It always deletes its branch by exact name (`rh-<tree>-<target>-<time>-<hex>`;
nothing else is ever deleted) and writes a receipt.

**Apply** (`db-release.ts apply`) takes the target's advisory lock first (one run at a time;
backend shares migrate.ts's key) and a local lock, then refuses: credentials (`--url-env`)
whose user is not on the target's branch, that point at a pooler (port 6432: session locks and
SET would not hold), or that are not the owner (cmux-vm: the SQL role `cmux_vm_migrator`, named
in trees.ts; backend: the PlanetScale role `migrator`, fail closed when pscale cannot name it);
for cmux-vm an owner role with power outside cmux_vm (superuser, member of postgres, CREATEROLE,
CREATE on public, read or write on any table or sequence outside cmux_vm, owning anything there
through any membership) —
staging alone may pass `--allow-broad-owner-on-staging` until a cmux_vm-only owner exists
(logged, recorded in the receipt), production never; a contract file without
`--allow-contract <file>`; for production: no `--confirm-production`, `--root`, a checkout
with changes under the migrations, `scripts/cmux-next/release/` or the Worker requirements, an
origin that is not manaflow-ai/cmux, a HEAD that is not an ancestor of that remote's
feat-cmux-next (`git ls-remote`, after a fetch that must succeed; the lint then runs with that
commit as `--base`), a failing cmux-old compat gate (run in the step itself), or a pending file
staging lacks (same checksum, read from staging). A production rehearsal that cannot act as
the owner fails. Then it rehearses this exact set on a throwaway copy in the same run (a
rehearsal receipt from elsewhere is never trusted), and only after that applies. Nothing
pending is a no-op pass.

**Deploy ordering gate** (`db-release.ts gate`, cmux-vm `deploy-staging` step; backend
already runs `migrate.ts --verify` in `deploy-worker.sh`) reads the database with the
deploy's own credentials and refuses when a migration file of the commit is not applied
(or applied with another checksum) or when the Worker's schema check
(`workers/cmux-vm/src/db/schema-requirements.ts`, the same query the Worker runs) finds a
missing table, column or privilege. While the tracking table is absent or unreadable by
the deploy role it warns and the schema check alone decides.

**Post-deploy** (`worker-release.ts`): before the deploy it records the version serving
100% (refuses during a gradual deployment); after it smokes `release-smoke.json` (routes
without `sources` always, the others when a matching file changed). On red it runs
`wrangler rollback <recorded version>`, smokes again and fails the job.

**Image promotion** (`images/cmux-vm/promote.ts`) refuses a snapshot id that is not in
`images/cmux-vm/channels/dev.json` `history` with smoke PASSED, a Cloud snapshot without
the env's `cmuxnp-<env>-vmimg-` prefix, a fresh-clone smoke that fails, leaves a clone
running, or creates one outside `cmuxnp-dev-`. It changes only
`backend/apps/api/wrangler.jsonc` `vars.CLOUD_FREESTYLE_SNAPSHOT` or `vars.TEAM_VM_SNAPSHOT`
of one env plus the channel file (old value kept as `previous`): new machines only, never a
running VM.

## Ship a migration end to end

```bash
R=scripts/cmux-next/release
# 1. Write workers/cmux-vm/migrations/NNNN_x.sql (or backend/db/migrations); expand-only,
#    or a "-- contract: <reason>" header for a reviewed non-expand change.
bun $R/lint.ts && bun $R/lint.ts --update-lock          # adds the file to the lock
# 2. Plan and (optional dry run) rehearse against staging (throwaway branch, deleted after).
bun $R/db-release.ts plan     --tree cmux-vm --target staging
bun $R/db-release.ts rehearse --tree cmux-vm --target staging [--allow-contract NNNN_x.sql]
# 3. Apply to staging with the owner credentials (env var only; never print it). It rehearses again itself.
bun $R/db-release.ts apply --tree cmux-vm --target staging --url-env OWNER_URL [--allow-contract NNNN_x.sql]
# 4. Land the code that needs it; the staging deploy gate passes, deploys, smokes.
# 5. Production, from a clean checkout landed on feat-cmux-next, after the compat gate:
bun $R/db-release.ts apply --tree cmux-vm --target production --url-env PROD_OWNER_URL --staging-url-env STAGING_READ_URL --confirm-production
```

Credentials: plan and rehearse against development or staging may mint a 2 h read-only pscale
role on the target (deleted afterwards); against production they need `--url-env` with an
existing read credential, because the tool never creates a production role. The first
production read credential needs the chief's go (lane rules: no new production keys). apply
and adopt always need `--url-env` with the owner role (they refuse any other role). A
rehearsal branch is a point-in-time restore of the target 6 minutes ago (PlanetScale needs
5+; `--from` alone makes an empty cluster) and runs as the copy's own owner-role record,
whose password it resets on the copy only.

Each step prints a `bd-summary:` line for the bead. Receipts (append-only, one JSON file
per event plus `receipts.jsonl`) live in `~/.local/state/cmux-release/receipts` or
`$CMUX_RELEASE_RECEIPTS_DIR`. A receipt records what, target, run id, migration ids and
sha256, applied list before and after, and rollback steps. `db-release.ts receipts` lists
them; `db-release.ts cleanup` deletes rehearsal branches a crashed run left, by exact name.

cmux-vm staging was migrated by hand (0001-0008, no tracking table). Once:
`db-release.ts rehearse ... --adopt-through 0008`, then `db-release.ts adopt --tree cmux-vm
--target staging --url-env OWNER_URL --through 0008` (records rows only; refuses unless
the Worker schema check finds those migrations' tables and columns). The tracking table
`cmux_vm.schema_migrations` is owned by the migration role; the Worker role gets no grant.

## cmux_vm-only owner role

Staging, DONE 2026-10-09 (Lawrence's go via the chief; receipts
20261009T031820861Z and 20261009T032421690Z role-change-cmux-vm-staging):
1. Proven on an rh- copy: a SQL-created role logs in as `<role>.<branch id>`.
2. `cmux_vm_migrator` (SQL role: LOGIN, NOINHERIT, no CREATEROLE/CREATEDB, no membership),
   created by the old owner; login only in `~/.secrets/cmux-vm-db/staging-migrator.json` (0600).
3. Schema cmux_vm and its 15 relations moved with ALTER ... OWNER TO, object by object (indexes,
   TOAST and column-owned sequences follow); no default privileges, functions or types existed.
4. The 14 Worker grants (cmux-vm-worker) re-issued by the new owner; ACL diff empty.
5. Verified: no privilege in public (tables, sequences, CREATE), no membership; the 37 public
   functions stay executable through PUBLIC's default EXECUTE (cmux-old's schema; the function
   allowlist covers migrations); Worker schema check clean; vm-staging 200/401/401/401.
6. The old owner cmux-vm-owner (34v1zavjpy82) deleted. A plain delete was refused (the creator's
   implicit ADMIN grant); `--successor postgres` worked but re-granted cmux_vm_migrator to postgres.
   ACCEPTED RESIDUAL (chief): staging's postgres members (cmux-staging-web) inherit ownership of
   cmux_vm; the rails' linter and runtime guard still apply.

Production, before its first apply (not done): `pscale role create cmux-prod main <name>` with no
inherited roles; verify the old owner owns only cmux_vm objects (the read-only capture in this
change's notes); `pscale role reassign <old id> --successor <new pg role>` (pscale_admin moves the
objects); never `--successor postgres`; verify as above; set `ownerPgRole`/`ownerRole` in trees.ts.

## First live run of the deploy rails

The deploy steps (cmux-vm.yml deploy-staging: ordering gate, record version, smoke and rollback;
backend.yml: record version in deploy-worker.sh, then the always() smoke step) were tested only
with a fake wrangler and a fake Worker. The first feat-cmux-next push after they land that touches
`workers/cmux-vm/` or `backend/` is their live proof: its pusher watches that run, checks that the
steps "Deploy ordering gate", "Record the serving version", "Smoke health and changed routes" (or
"Smoke the API Worker") ran and logged `gate ok`, `previous version of ...` and `smoke green`, and
reports the run id in the landing report. A red step there is that pusher's P0.

## Backend label apply

backend-migrations.yml keeps its `backend:apply-migrations` label, but apply-staging and
apply-production run `scripts/cmux-next/release/ci-backend-apply.sh` from the trusted base
checkout (lint with the base lock, owner check, rehearsal on a throwaway cmux-next branch, apply,
receipt artifact). It needs `PLANETSCALE_SERVICE_TOKEN_ID`/`PLANETSCALE_SERVICE_TOKEN` in the
environments (a credential: the chief) and refuses without them. Production refuses a candidate
root by design, so a pre-merge production apply refuses until a landed-checkout path exists.

## Rollback

- Bad deploy: automatic (`wrangler rollback`). By hand: `wrangler rollback <version> --name <worker>`; the version is in the deploy log line "previous version of ...".
- Bad migration: roll the code back first, then the file's own `-- Rollback` section (the apply receipt lists it, newest first). Expand migrations normally stay in place.
- Bad image: `bun images/cmux-vm/promote.ts --channel <c> [--var TEAM_VM_SNAPSHOT] --rollback`, then deploy that env; after the deploy `wrangler rollback <version> --name cmux-api-<env>` undoes it at once.

## cmux-old compatibility (production steps)

cmux-old (latest stable v0.65.0, 2026-10-05) calls cmux.com/api/* (web/), presence.cmux.dev,
api.cmux.sh, cmux.dev (updates) and Freestyle hosts from its CLI. It does not call
vm.cmux.dev / vm-staging.cmux.dev (cmux-vm Worker) or cloud-api.cmux.dev (cmux-next API),
and no cmux-old path reads the cmux-next `CLOUD_FREESTYLE_SNAPSHOT` / `TEAM_VM_SNAPSHOT`
names (git grep at v0.65.0 over CLI/, Sources/, Packages/, cmux-tui/crates), so an image
promotion here does not affect cmux-old. Shared state: PlanetScale cmux-prod (hence the
schema confinement rule) and the Freestyle production account. Its CLI makes no REST call
itself: every Cloud call goes through the running app (CmuxCloud), which honours
`CMUX_VM_API_BASE_URL`/`CMUX_API_BASE_URL` and the env auto-login
(`CMUX_UITEST_STACK_EMAIL`/`_PASSWORD`, not DEBUG-gated in v0.65.0).

Production apply and production promote run the compat gate themselves (`compatNow`, no
receipt written elsewhere counts); `compat.ts check --change ...` runs the same gate by hand:

```bash
R=scripts/cmux-next/release
bun $R/compat.ts check --change migrations:cmux-vm --target production    # or image:<VAR>:<sh-id>
bun $R/cmux-old.ts replay --change dry-run                                 # the replay alone, any time
bun $R/cmux-old.ts generate --tag <new stable tag>                         # after every stable release; commit the spec
```

The client half replays the requests the latest stable release's shipped Swift builds
(`cmux-old/<tag>.json`: 70 for v0.65.0, tag commit 499779c6c2c0; GET status classes and JSON
keys recorded from cmux.com without credentials) against https://cmux-staging.vercel.app. A GET
must answer its recorded class (a JSON 2xx with at least its keys); any other method must not
answer 404, 405 or 5xx. `cmux-old/staging-gaps.json` lists reviewed staging-only differences
(today: POST /api/billing/recover answers 503 on staging). A production step refuses when the
latest stable release is newer than the newest spec. The app is never started for this.
Follow-up (bead filed by the lead): a real-binary smoke of the latest release on an isolated
cloud Mac VM, and authenticated replays with a signed-in agent profile.

Static: the inventory (`git grep` at the latest release tag for the hosts and names the
change reaches; a hit is reported as cmux-old-affecting), the migration lint, and the API
contract (cmux-vm `openapi.json` through the pinned oasdiff 1.32.1; backend
`catalog/cloud-operations.json`: removed operations, params, types, fields, enum values or
error codes, newly required params) against `--base` (origin/main for production). Change
keys: `migrations:<tree>:<hash of every file>`, `image:<VAR>:<history snapshot id>`,
`deploy:<tree>:<commit>`. Receipts count for 24 h.
