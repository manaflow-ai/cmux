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
   A table created in the same file may be shaped freely (except layer 1); `CREATE TABLE IF NOT EXISTS`
   never counts as created (it may meet a live table).
3. *cmux-vm confinement*, even with a header: every name (any node with a relname: tables,
   views, CTAS targets, sequences, policy tables, composite types; qualified types and
   functions; created types and domains, which must be qualified; COMMENT targets) is in schema `cmux_vm`
   (pg_catalog allowed for types and functions), because cmux-old shares the database.

Every tree: `NNNN_lower_snake.sql`, numbered from 0001 without gaps; every file in
`migrations.lock.json` with its sha256; a landed file never changes or disappears; lock
entries are append-only; `--base <previous head>` also compares that revision's files and
lock and requires new numbers above its highest. cmux-vm: `REQUIRED_SCHEMA` in
`workers/cmux-vm/src/db/schema-requirements.ts` must name the newest file's number (add the
table, column or index it creates). Only the files in lint.ts `GRANDFATHERED` (exact name and hash: cmux-vm 0001-0008, backend
0001-0006) skip the statement rules; no lock edit or intermediate push can move that boundary. backend files keep
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
# 5. Production, from a clean checkout landed on feat-cmux-next, after the compat gate
#    (its first apply runs 0001-0009; 0009 is a contract migration: add --allow-contract 0009_cmux_vm_mesh_device_address.sql):
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

## Hardening 1 (after the fourth review)

No migration may name the tracking table; CREATE/DROP INDEX CONCURRENTLY is alone in its file and
runs outside a transaction (CREATE names its index); serial columns and an inline CHECK on an
existing table are refused (the CHECK needs a header); CREATE SCHEMA has no AUTHORIZATION;
sequences are permanent with no OWNED BY; COMMENT names an exact table, column, index, sequence,
type or the schema. The owner check also refuses CREATEDB, CREATE on another schema and column
grants outside cmux_vm. A production step exports the files from git at the verified commit,
re-checks HEAD right before it writes, and refuses NODE_OPTIONS, BUN_OPTIONS, BUN_CONFIG_*,
NODE_PATH, LD_PRELOAD, DYLD_INSERT_LIBRARIES and a bunfig.toml preload. migrations.lock.json
also pins libpg-query's package.json, and one digest over every file of the runtime packages
(the pg and libpg-query closures); `lint.ts` prints `pins ok: ...` when both match. Library-path
variables (LD_LIBRARY_PATH, LD_AUDIT, DYLD_LIBRARY_PATH, DYLD_FRAMEWORK_PATH), a preload in
~/.bunfig.toml or $XDG_CONFIG_HOME/.bunfig.toml, and a --preload/--require flag are refused too;
the clean-tree check runs again right before every production write, and production adopt
checks the same. A production step that ever runs in CI runs under `env -i` with an explicit
PATH and only the variables it needs.

## First live run of the deploy rails

The deploy steps (cmux-vm.yml deploy-staging: ordering gate, record version, smoke and rollback;
backend.yml: record version in deploy-worker.sh, then the always() smoke step) were tested only
with a fake wrangler and a fake Worker. The first feat-cmux-next push after they land that touches
`workers/cmux-vm/` or `backend/` is their live proof: its pusher watches that run, checks that the
steps "Deploy ordering gate", "Record the serving version", "Smoke health and changed routes" (or
"Smoke the API Worker") ran and logged `gate ok`, `previous version of ...` and `smoke green`, and
reports the run id in the landing report. A red step there is that pusher's P0.

Done 2026-10-09 on the rails' own trunk push d21f7844e1ba: cmux VM run 37882089972 (deploy-staging
logged `gate ok: cmux-vm/staging has every migration this commit needs (9 files)`, `previous
version of cmux-vm-staging: 64b76a0d-...`, 7 routes PASS, `smoke green`) and backend run 37882089907
(deploy-staging logged `all 6 migrations applied`, `previous version of cmux-api-staging:
5167083a-...`, `smoke green: cmux-api-staging`).

## Backend label apply (parked)

backend-migrations.yml still applies on its `backend:apply-migrations` label through
backend/db/migrate.ts, without a rehearsal. Routing it through the rails is parked on branch
feat-cmux-next-hq39-backend-label-rails: it needs `PLANETSCALE_SERVICE_TOKEN_ID`/
`PLANETSCALE_SERVICE_TOKEN` in cmux-next-staging and cmux-next-production (the chief) and a
landed-checkout production apply (workflow_dispatch after landing); without both, the required
gate "backend migrations applied" could not pass.

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
bun $R/cmux-old.ts replay --change dry-run                                 # the signed-in replay alone, any time
bun $R/cmux-old.ts revisions                                               # staging vs production web commit
bun $R/cmux-old.ts generate --tag <new stable tag>                         # after every stable release; commit the spec
```

The client half replays the requests the latest stable release's shipped Swift builds
(`cmux-old/<tag>.json`, generated from the tag alone, no network, byte-for-byte reproducible:
81 requests for v0.65.0, tag commit dda24fbd2250, build 108; origin moved the tag from 499779c6c2c0
on 2026-10-05, and the gate refuses a spec whose commit is not what origin's tag names now). For each "/api/" literal the generator finds
the method (call argument, the helper or function that sets `httpMethod`, a ternary, a URL helper's
callers), the path template, the header names the client sets, the JSON body keys and, for reads,
the shape the client's decoder needs: parsed from the `Decodable` struct (CodingKeys, optionals,
nested types, raw enums, custom `init(from:)`), or for a hand-written dictionary decoder from a
reviewed entry in `cmux-old/<tag>.review.json` with its source line. A literal that resolves to
nothing must be skipped there with a reason (cache tables, telemetry labels); a stale entry fails.

The replay signs in as the AGENT test profile only (`CMUX_UITEST_STACK_EMAIL`/`_PASSWORD`, from
the environment or `~/.secrets/cmuxterm-dev.env`, `--credentials -` reads stdin; values never
printed; it refuses an email equal to `CMUX_DOGFOOD_STACK_EMAIL`), exactly as the tag does:
Stack password sign-in with the development project id and publishable key read from the tag's
`AuthConfig.swift` (the project cmux-staging serves; the replay checks that first). Reads (21 for
v0.65.0: every GET plus POST /api/client-config) go out with the client's headers (bearer, refresh
token, the selected team) and must answer 2xx with their shape; a path parameter the agent account
has no value for (no machine, no publication) is sent as `cmuxnp-dev-absent` and must answer a JSON
4xx. Public reads (whats-new, mobile-mac-compat, client-config) go out without credentials, as the
client sends them. Every other request (60, all state-changing) is shape-only: probed without
credentials, it must not answer 404, 405 or 5xx; nothing on the agent account changes. The session
is signed out afterwards. `cmux-old/staging-gaps.json` lists reviewed staging-only differences
(today: POST /api/billing/recover answers 503 on staging). The app is never started for this.

Web revisions: the gate reads the commit serving cmux-staging.vercel.app and cmux.com
(`vercel api /v13/deployments/<host>`, read-only, the operator's Vercel login) and records both in
the receipt with the relation (same, newer, older, diverged, unknown). A production step refuses
when the replay was not signed in, when it failed, when the latest stable release is newer than
the newest spec, or when staging is not production's commit or a descendant of it. A change that
cmux-old reaches (inventory hit) passes only with all of that green. Follow-up: a real-binary
smoke of the latest release on an isolated cloud Mac VM.

Static: the inventory (`git grep` at the latest release tag for the hosts and names the
change reaches; a hit is reported as cmux-old-affecting), the migration lint, and the API
contract (cmux-vm `openapi.json` through the pinned oasdiff 1.32.1; backend
`catalog/cloud-operations.json`: removed operations, params, types, fields, enum values or
error codes, newly required params) against `--base` (origin/main for production). Change
keys: `migrations:<tree>:<hash of every file>`, `image:<VAR>:<history snapshot id>`,
`deploy:<tree>:<commit>`. Receipts count for 24 h.
