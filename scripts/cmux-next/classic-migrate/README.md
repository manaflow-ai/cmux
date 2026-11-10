# classic-migrate: copy a classic user or team into NEXT Cloud

A CLI for the classic → NEXT Cloud migration. It **never writes classic**: classic is read over SQL inside a
`BEGIN READ ONLY` transaction (or from a JSON fixture), and every write goes to NEXT through two idempotent HTTP
routes. A classic VM is copied, never moved: classic keeps its row, VM, billing and keys.

```
bun scripts/cmux-next/classic-migrate/main.ts plan     --user STACK_USER_ID | --team STACK_TEAM_ID [...]
bun scripts/cmux-next/classic-migrate/main.ts apply    --plan plan.json --ledger ledger.jsonl [...]
bun scripts/cmux-next/classic-migrate/main.ts rollback --ledger ledger.jsonl
bun scripts/cmux-next/classic-migrate/main.ts status   --ledger ledger.jsonl [--plan plan.json] [--json]
```

## 1. Dry run: `plan`

```
# From a fixture (no database):
bun scripts/cmux-next/classic-migrate/main.ts plan --user 11111111-1111-4111-8111-111111111111 \
  --source fixture scripts/cmux-next/classic-migrate/fixtures/staging-test.json --out /tmp/mig

# From classic staging Postgres (a read-only role or replica):
CLASSIC_DATABASE_URL=postgres://ro:…@HOST/db CLASSIC_DB_HOST_ALLOW=HOST \
  bun scripts/cmux-next/classic-migrate/main.ts plan --team STACK_TEAM_ID --stack-project PROJECT --out /tmp/mig
```

It prints every classic object and its action, and writes `plan.json` and `plan.md` (counts, stable order, no
clock: the same rows give the same bytes).

| action | objects | meaning |
| --- | --- | --- |
| `carried` | user, teams, memberships, plan metadata, applied admin plan grants | Same Stack project: NEXT already has them. Nothing is written; the plan shows the NEXT ids (`user_…`, `team_…`). |
| `copy` | each running or paused Freestyle VM the subject owns | Snapshot the upstream VM, register it under the NEXT VM API tenant, create a NEXT machine from it. |
| `link` | Stripe customer (with its subscriptions) | Report only: NEXT's team billing link. Nothing is written. |
| `not-migrated` | destroyed/failed/provisioning VMs, classic snapshots, publications, domains, tunnels, `crk_` keys, `crt_` route tokens, Apple IAP, open admin grants, runs, vault transcripts | Stays on classic; the reason is on the line. Classic keys stay valid on classic. |
| `needs-decision` | a VM whose owner the rules below cannot settle | Not copied. Decide personal or team, then re-plan. |

NEXT ids: user `user_` + sha256("stack:<project>:<stackUserId>")[:20]; personal team `team_` +
sha256("personal:<NEXT user id>")[:20]; shared team `team_` + sha256("stack-team:<project>:<stackTeamId>")[:20].

**Personal or team VM.** Classic writes `owner_team_id = coalesce(owner_team_id, billing_team_id, user_id)`, usually
the creator's personal Stack team. A VM is personal when `owner_team_id` is the creator's user id, or its Stack team
is marked personal (a boolean `isPersonal`/`is_personal`/`personal`/`personalTeam`/`cmuxPersonalTeam` in its
metadata), or, with no marker, the team's only member is the creator and it has no team subscription. Two or more
members is shared. Anything else (team missing from the mirror, a sole member who is not the creator, a sole-member
team with a team subscription) is `needs-decision`. Each VM line shows the rule that fired (`personal_reason`).
A personal VM copies into the creator's NEXT personal team (VM API tenant resolved at apply); a shared VM copies
into the NEXT shared team under VM API tenant = the Stack team id. `--user` copies only that user's personal VMs;
`--team` only the team's shared VMs; the others are listed with the command that migrates them.

**Classic safety (postgres source).** Refuses to connect unless the URL's host is on `CLASSIC_DB_HOST_ALLOW`
(a comma list of classic staging hosts; required, no default). `--allow-production-read` skips that list for a
later runbook step; the read stays read only. Each read is one connection: `BEGIN READ ONLY`,
`SET TRANSACTION READ ONLY`, `SET LOCAL statement_timeout = 15000`, a check that `transaction_read_only` is `on`,
then SELECT statements only (anything else is refused in code before it is sent), then `ROLLBACK`.

## 2. `apply`

```
CMUX_VM_API_ORIGIN=https://… CMUX_VM_IMPORT_KEY=… CMUX_PLATFORM_ORIGIN=https://… INTERNAL_TOKEN=… \
  bun scripts/cmux-next/classic-migrate/main.ts apply --plan /tmp/mig/plan.json --ledger /tmp/mig/ledger.jsonl \
  [--personal-tenants tenants.json] [--only CLASSIC_VM_ID] [--dry-run]
```

Per `copy` entry, two steps:

1. `POST {VM_API}/v1/imports/classic-vm-snapshots` (bearer `CMUX_VM_IMPORT_KEY`)
   `{tenant_id, created_by, classic_vm_id, upstream_vm_id, migration_id}` → `{id: "snap_…"}`
2. `POST {PLATFORM}/internal/v1/migrations/classic/machines` (bearer `INTERNAL_TOKEN`)
   `{team, creator_user, migration_id, classic_vm_id, vm_api_snapshot_id, name, size}` → `{machine, snapshot}`

The ledger is append-only JSONL: a `started` line with the exact request before each request, then `done` or
`failed`. A re-run skips `done` steps and re-sends the recorded request of an unfinished one (both routes are
idempotent on `migration_id` + `classic_vm_id`), so a killed run costs at most the one in-flight request again.
One ledger belongs to one migration id (one plan subject). `--dry-run` sends nothing and writes no ledger; it
prints what each step would do. Personal VM API tenants come from `--personal-tenants` (JSON: Stack user id or NEXT
user id → tenant id); the resolver is a hook (`PersonalTenantResolver` in `clients.ts`) for the real lookup.

## 3. `rollback` and `status`

`rollback --ledger FILE` undoes, newest VM first, exactly what the ledger shows apply sent: `DELETE` the platform
machine (`{team, migration_id, classic_vm_id}`, which also drops its CloudDO snapshot row), then `DELETE` the VM API
snapshot. An import that never answered is asked again with its recorded request to learn the snapshot id, then
deleted. "Not found" counts as done, and each undo is recorded, so a second rollback sends nothing. A VM rolled back
in a ledger is not applied again from that ledger. `status` shows each VM's two steps and an overall state
(`done`, `in_flight`, `failed`, `pending`, `rolled_back`, `rollback_incomplete`).

## Layout and tests

| file | what |
| --- | --- |
| `main.ts` | CLI |
| `source.ts` | classic rows: fixture and read-only Postgres sources, host allowlist |
| `plan.ts` | the planner (pure) and its text/Markdown output |
| `clients.ts` | typed clients for the two NEXT routes; tenant resolver hook |
| `ledger.ts` | the append-only ledger |
| `apply.ts` | apply, rollback, status |
| `ids.ts` | NEXT id derivation (same as backend/apps/api domains/user.ts) |
| `fixtures/staging-test.json` | a user with two VMs (one destroyed), a team with one VM, Stripe customers, a `crk_` key, a publication |

```
bun test scripts/cmux-next/classic-migrate </dev/null
```

The tests use the fixture, a recording fake Postgres connection (read-only transaction, refusals) and a fake
HTTP server for both NEXT routes: apply is killed mid-request with SIGKILL and re-run, then rolled back twice.
