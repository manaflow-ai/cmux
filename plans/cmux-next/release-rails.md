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

**Migration lint** (`lint.ts`; runs in `cmux-vm.yml` check, `backend.yml` test and push
guard, and before every rehearse and apply). Without `-- contract: <reason>` (10+
characters) in the leading comment block, refused on the parsed SQL: any DROP; DROP
COLUMN / DROP CONSTRAINT / ALTER TYPE / SET NOT NULL / DROP DEFAULT; ADD COLUMN NOT
NULL without DEFAULT; a validated ADD CONSTRAINT (or UNIQUE/PK) on an existing table;
RENAME; RENAME VALUE; CREATE INDEX on an existing table without CONCURRENTLY, and any
unique index on one; UPDATE/DELETE without WHERE; TRUNCATE; DO and functions; REVOKE;
GRANT beyond `role-contract.json` (ALL, PUBLIC, GRANT OPTION, role membership, default
privileges, roles, unlisted grantee/privilege/schema); BEGIN/COMMIT. A CONCURRENTLY
index must be alone in its file. **cmux-vm only, even with a header:** every object in
schema `cmux_vm` (unqualified names, public, other schemas, `SET` are refused), because
cmux-old shares the database. Every tree: `NNNN_lower_snake.sql`, numbered from 0001
without gaps; every file in `migrations.lock.json` with its sha256; a landed file never
changes or disappears; lock entries are append-only; `--base <previous head>` also
compares that revision's files and lock and requires new numbers above its highest.
Files up to `grandfatheredThrough` (cmux-vm 0008, backend 0006) predate the rules and are
hash-checked only. backend files keep `-- phase: contract` and `-- contract:` together.

**Rehearse** (`db-release.ts rehearse`) refuses to start when the lint fails, the target
has a changed applied file, or (backend) rows the tree lacks. It fails when the throwaway
copy differs from the target (stale backup), a file fails to apply, anything stays
pending, the Worker schema check finds a missing table or column, or a table does not
answer a read. It always deletes its branch by exact name (`rh-<tree>-<target>-<time>-<hex>`;
nothing else is ever deleted) and writes a receipt.

**Apply** (`db-release.ts apply`) refuses without `--url-env` (owner credentials whose user
belongs to the target's branch), without a passing rehearsal of the same set (applied rows
+ pending files, by hash) against that target in the last 24 h, for production without
`--confirm-production` or while staging lacks a pending file with the same checksum (read
from staging), for a contract file without `--allow-contract <file>`, and while another
run holds the database advisory lock or a local lock. Nothing pending is a no-op pass.

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
# 2. Rehearse against staging (read role via pscale, throwaway branch, deleted after).
bun $R/db-release.ts plan     --tree cmux-vm --target staging
bun $R/db-release.ts rehearse --tree cmux-vm --target staging [--allow-contract NNNN_x.sql]
# 3. Apply to staging with the owner credentials (env var only; never print it).
bun $R/db-release.ts apply --tree cmux-vm --target staging --url-env OWNER_URL [--allow-contract NNNN_x.sql]
# 4. Land the code that needs it; the staging deploy gate passes, deploys, smokes.
# 5. Production: rehearse against production, then apply (staging must already have it).
bun $R/db-release.ts rehearse --tree cmux-vm --target production
bun $R/db-release.ts apply --tree cmux-vm --target production --url-env PROD_OWNER_URL --confirm-production
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
schema confinement rule) and the Freestyle production account. Production apply, promote
and deploy also need a passing cmux-old compatibility receipt (contract diff + a v0.65.0
client smoke against staging) for the same change within 24 h: see the compat gate section
once it lands.
