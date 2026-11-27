# classic-migrate: copy a classic user or team into NEXT Cloud

A CLI for the classic → NEXT Cloud migration. It **never writes classic**: classic is read over SQL inside a
`BEGIN READ ONLY` transaction (or from a JSON fixture), and every write goes to NEXT through one idempotent HTTP
route, cmux-platform's internal classic migration route. A classic VM is copied, never moved: classic keeps its row,
VM, billing and keys.

```
bun scripts/cmux-next/classic-migrate/main.ts plan     --user STACK_USER_ID | --team STACK_TEAM_ID [...]
bun scripts/cmux-next/classic-migrate/main.ts apply    --plan plan.json --ledger ledger.jsonl [--fresh] [...]
bun scripts/cmux-next/classic-migrate/main.ts verify   --ledger ledger.jsonl [--json]
bun scripts/cmux-next/classic-migrate/main.ts rollback --ledger ledger.jsonl [--json]
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
| `copy` | each running or paused Freestyle VM the subject owns | The platform snapshots the upstream VM, registers it under the team's VM API tenant and creates a NEXT machine from it, sized like the classic VM. |
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
A personal VM copies into the creator's NEXT personal team; a shared VM copies into the NEXT shared team. The
platform resolves the team's VM API tenant itself in both cases. `--user` copies only that user's personal VMs;
`--team` only the team's shared VMs; the others are listed with the command that migrates them.

**Classic safety (postgres source).** Refuses to connect unless the URL's host is on `CLASSIC_DB_HOST_ALLOW`
(a comma list of classic staging hosts; required, no default). `--allow-production-read` skips that list for a
later runbook step; the read stays read only. Each read is one connection: `BEGIN READ ONLY`,
`SET TRANSACTION READ ONLY`, `SET LOCAL statement_timeout = 15000`, a check that `transaction_read_only` is `on`,
then SELECT statements only (anything else is refused in code before it is sent), then `ROLLBACK`.

## 2. `apply`

```
CMUX_PLATFORM_ORIGIN=https://… INTERNAL_TOKEN=… \
  bun scripts/cmux-next/classic-migrate/main.ts apply --plan /tmp/mig/plan.json --ledger /tmp/mig/ledger.jsonl \
  [--only CLASSIC_VM_ID] [--dry-run] [--fresh] [--json]
```

Per `copy` entry, one request:
`POST {PLATFORM}/internal/v1/migrations/classic/machines` (bearer `INTERNAL_TOKEN`)
`{team, creator_user, migration_id, classic_vm_id, upstream_vm_id, name?, size: {cpu?, memory_mb?, disk_mb?}}` →
201 `created` or 200 `existing`, `{status, machine, snapshot, migration}`. The platform makes the VM API import
(with its own key, under the team's tenant), a ready CloudDO snapshot row and the machine; each of its steps is keyed
by (migration_id, classic_vm_id), so a re-send goes on from where the last one stopped and never makes a second
machine. `migration_id` and `classic_vm_id` must match `[A-Za-z0-9._:/@-]{1,63}`; anything else is refused before
it is sent.

Size: classic records each VM's shape in `provider_metadata.cmuxResourceReservation` (`{vcpus, memoryMb, diskMb}`,
classic `services/vms/machineSpec.ts`), mapped to `{cpu, memory_mb, disk_mb}`. An axis that is missing or outside
the route's bounds (cpu 1-64, memory 512-262144 MB, disk 1024-1048576 MB) is left out and the platform picks its
default. The creator's NEXT plan must still offer that size (`cloud.size.locked` otherwise); the machine counts are
waived for migrated machines.

The ledger is append-only JSONL: a `started` line with the exact request before each request, then `done` or
`failed`. A re-run skips `done` VMs and re-sends the recorded request of an unfinished one, so a killed run costs at
most the one in-flight request again, and a re-run of a finished apply sends nothing. One ledger belongs to one
migration (one plan subject). `--dry-run` sends nothing and writes no ledger.

The direct VM API import step (`POST {VM_API}/v1/imports/classic-vm-snapshots`, then the platform route with
`vm_api_snapshot_id`) is gone: the platform calls that route itself, and its rollback deletes those imports, so a
second path only added a step to fail and a tenant to resolve.

**Ledgers of the earlier CLI.** A ledger that CLI wrote holds `vm_api_import` lines (and platform requests with
`vm_api_snapshot_id`). It stays readable: `status` shows both steps and the VM API snapshot id, `verify` reads it, and
`rollback` deletes the machine through the platform, then the VM API snapshot that CLI made itself through
`DELETE {VM_API}/v1/imports/classic-vm-snapshots/{id}` when `CMUX_VM_API_ORIGIN` (or `--vm-api`) and
`CMUX_VM_IMPORT_KEY` are set. Without them, or when the import never answered with its id, rollback prints
`MANUAL CLEANUP` with the classic VM, the migration id and the snapshot id, and exits 1. `apply` never re-sends such
a VM (roll back, then `apply --fresh`). A line with a step name the CLI does not know is ignored and listed in
`status`.

## 3. `verify`, `rollback`, `status`

`verify --ledger FILE` reads `GET {PLATFORM}/internal/v1/migrations/classic/machines?team=&migration_id=` for each
attempt in the ledger and compares: every VM `done` in the current attempt has its recorded machine live in NEXT,
every rolled-back VM (and every VM of an earlier attempt) has none, and NEXT holds no live machine of the migration
the ledger does not know. A machine still `deleting` (the provider delete running) counts as gone. Exit 1 on any
mismatch.

`rollback --ledger FILE` undoes, newest VM first, everything the current attempt sent: one
`DELETE {PLATFORM}/internal/v1/migrations/classic/machines {team, migration_id, classic_vm_id}` per VM, which
removes the machine, its CloudDO snapshot row and every VM API import of that VM (including one a cut-off run never
recorded), answering `deleted`, `deleting` or `absent`. Each undo is recorded, so a second rollback sends nothing.
`status` shows each VM's step and an overall state (`done`, `in_flight`, `failed`, `pending`, `rolled_back`,
`rollback_incomplete`).

**Re-migration after a rollback: `apply --fresh`.** A VM rolled back in the current attempt is not applied again
(plain `apply` says so). `--fresh` starts a new attempt in the same ledger, migration id `<plan id>.r2`, `.r3`, …,
which the platform sees as new provenance (none of the rolled-back rows or idempotency keys apply). It is refused
while the current attempt still has anything not rolled back, so two copies of one classic VM never exist at once.
`rollback` and `status` act on the current attempt; `verify` checks all of them.

## 4. The staging proof

`.github/workflows/classic-migration-staging.yml` (manual dispatch, environment `cloud-vm-staging`) runs
`staging-proof.ts`: SETUP makes a throwaway smoke user and a two-member team with one classic VM each through
classic staging's own API and writes a nonce on each. Every classic request sends its VM's account scope
(`X-Cmux-Team-Id`: the owner's personal Stack team, made and marked personal when Stack made none, or the shared
team), and each create is recorded with its Idempotency-Key before it is sent; DRY RUN runs `plan --user` and `plan --team` against classic
staging Postgres (read only, `CLASSIC_DB_HOST_ALLOW`) and requires each VM as `copy`, nothing `needs-decision`;
MIGRATE runs `apply`, `verify`, reads the nonce back on each NEXT machine as the smoke user, and requires a second
`apply` to send nothing; ROLLBACK runs `rollback`, `verify` (none), a second `rollback` (nothing sent) and reads the
nonce on classic again; TEARDOWN always deletes the classic VMs, the team and the users, rolling NEXT back first if
MIGRATE or ROLLBACK did not finish (a second, `always()` step repeats it from the state file, running the rescue
rollback and the classic teardown both and reporting their failures together). Teardown first resolves an unanswered
create (classic can answer 503 `vm_operation_in_progress` and go on): the VM with its display name in its scope's
list, else the same request replayed with the same Idempotency-Key. A 404 on DELETE counts as gone only under the
VM's own scope; a team is deleted only once no VM under it is left, and the owner is kept while any VM or create is. Without
`PLATFORM_STAGING_INTERNAL_TOKEN` MIGRATE and ROLLBACK are reported not-run and the run passes with a notice. The
job summary has each step's seconds and result; the artifact has `proof.json` and the ledgers.

## Layout and tests

| file | what |
| --- | --- |
| `main.ts` | CLI |
| `source.ts` | classic rows: fixture and read-only Postgres sources, host allowlist |
| `plan.ts` | the planner (pure) and its text/Markdown output |
| `clients.ts` | typed client for the platform's migration route |
| `ledger.ts` | the append-only ledger and its attempts |
| `apply.ts` | apply, rollback, status, verify |
| `staging-proof.ts` | the staging proof (step order and teardown are pure and unit-tested) |
| `ids.ts` | NEXT id derivation (same as backend/apps/api domains/user.ts) |
| `fixtures/staging-test.json` | a user with two VMs (one destroyed), a team with one VM, Stripe customers, a `crk_` key, a publication |

```
bun test scripts/cmux-next/classic-migrate </dev/null
```

The tests use the fixture, a recording fake Postgres connection (read-only transaction, refusals) and a fake
HTTP server for the platform route: apply is killed mid-request with SIGKILL and re-run, verified, rolled back twice,
re-migrated with `--fresh` and rolled back again. `stress.test.ts` runs 300 seeded random sequences of apply,
rollback and `--fresh` per subject against a route that fails before or after its side effect, and checks that no
classic VM ever has two live copies and that a clean rollback leaves nothing. `staging-proof.test.ts` covers the
proof's step order, teardown on every failure path and the idempotent teardown, with fakes.
