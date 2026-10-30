# Cloud environments (cmux-next)

Status: core, CloudDO ops and the Vitess table landed. The Mac UI is next (section 8).

## 1. What an environment is

An environment is what a new cloud workspace already has when it opens. It has three inputs:

| Input | Example | Where it goes |
|---|---|---|
| Repository | `manaflow-ai/cmux@feat-cmux-next` | Cloned (depth 1) to `~/work/<name>` |
| Setup script | `cd web && bun install --frozen-lockfile` | Runs once in the checkout, at build time |
| Variables | `NODE_ENV=development`, `OPENAI_API_KEY` from the vault | Plain values: `/etc/profile.d/cmux-environment.sh`. Secrets: the name only |

There is no Dockerfile, no image picker and no language list. This is the "ChatGPT work" model: a
person names a repo and how to set it up, and every new workspace starts from the result. The other
model ("Codex": a container image per task, set up again on every run) pays the setup on every
workspace. The setup is the slow part (sections 7 and 9), so we pay it once per environment.

## 2. Build: one snapshot per environment

```
base image ─boot─▶ builder ─clone+setup (detached)─▶ snapshot ─warm boot─▶ ready
                       └─────────── deleted in every case ───────────┘
```

1. Boot a builder from the deployment's base image (the CloudDO image, `CLOUD_FREESTYLE_SNAPSHOT`).
2. Wait until the guest answers an exec (bounded probe; the provider has no readiness event).
3. Start the build script detached (`nohup`), then poll its exit file. A provider exec has a hard
   cap (Freestyle refused a 30-minute `exec-await` with HTTP 400), and a real clone plus install
   took 124-175 s. With the detached run, a build can take up to 30 minutes.
4. Snapshot only after the script exited 0. A failure keeps the last 4 KB of the log for the person.
5. Warm boot: boot one machine from the new snapshot and delete it. One of six snapshot boots in
   the first run took 16.7 s to create; the others took 0.3-0.5 s. The build pays that risk, not the
   first workspace (0.54 s measured).
6. Delete the builder, on success, failure or interruption.

The script never writes a secret value. It writes the plain variables to a profile file, clones,
runs the setup in the checkout, and writes `~/.cmux/environment.json` with the build digest and the
names of the secret variables.

## 3. Staleness: the build digest

`digest = sha256(base image, repo, setup script, variables sorted by name)`. The digest does not
include the display name or the variable order. A snapshot serves a workspace only when all three
match: its digest equals the current digest, it was built by the same provider, and it is ready.
After an edit to a build input, or a rebake of the base image, the snapshot is stale:

- New workspaces boot cold: base image, then the same build script on the new machine. This is
  slower, but the result is the same. An edit never blocks a workspace on a rebuild.
- The next build replaces the snapshot. A failed build keeps the previous snapshot serving.

## 4. Secrets (Vault, a714)

Secret variables name a vault item (`{ "name": "OPENAI_API_KEY", "secret": "openai" }`). The value
never enters the snapshot. At boot, the hosted vault (`plans/cmux-next/cmux-vault-CLOUD-DESIGN.md`,
Azure Key Vault KEK, broker contract) delivers the values into the workspace's session environment
over the bind channel, the same way the bind file arrives. The hosted vault is not provisioned yet
(its section 9 waits on the user: Azure subscription, database). Until then, a build with a secret
variable is refused with `environment_secrets_unavailable` (no silent boot without them).

## 5. Boot: a new cloud workspace in an environment

`environmentBootPlan(spec, snapshot, baseImage, provider)` gives one of two answers:

- `snapshot`: create the machine from the environment's snapshot (CloudDO's existing restore path,
  `cloud.snapshot.restore` / create `from_snapshot`). No setup runs.
- `cold` (`unbuilt` or `stale`): create from the base image, then run `setupExec` once on the machine.

#26078 (Austin, "each new workspace gets its own Freestyle VM") decides *whether* a New Workspace
goes to the cloud (`CloudNewWorkspacePlan`). Environments decide *what the machine starts with*.
The hook is one optional field: the plan gains an environment id (the team's default environment,
or the one the person picks). With an environment, the create is `cloud.environment.boot` instead
of a plain `cloud.machine.create`, and the folder copy of #26078 is skipped when the environment
already has a repo. Nothing in #26078 changes direction.

Leo's setup wizard (#26150) asks "Empty VM" or "From repository" on every create. An environment is
that repository answer, saved and pre-built. The wizard gains a third source, "Environment", and a
"Save as environment" action on "From repository".

## 6. One provider interface

`CloudSandbox` (`backend/packages/cloud-env/src/sandbox.ts`) is the only interface the
environment code uses to talk to a provider:

```ts
interface CloudSandbox {
  readonly provider: string
  boot(o: { name: string; snapshot?: string }): Promise<{ id: string }>
  exec(id: string, command: string, timeoutMs: number): Promise<{ exitCode: number; stdout: string; stderr: string }>
  snapshot(id: string, name: string): Promise<{ id: string }>
  destroy(id: string): Promise<void>
}
```

Implementations:

| Implementation | Where | Notes |
|---|---|---|
| `GuardedCloudSandbox` | `backend/apps/api/src/cloud-env-sandbox.ts` | Over CloudDO's `GuardedCloudDriver`, so it covers every `RawCloudDriver`: Freestyle direct, the cmux VM API, and the test fake. Names and slugs are checked against the environment's prefix, and machines are checked against the team tag. Exec runs as uid 1000, not as root. |
| `MemorySandbox` | `@cmux/cloud-env` | In-memory, for tests. |
| `LocalSandbox` | `@cmux/cloud-env` tests | Machines are directories, and exec is real bash. The whole detached build, the snapshot and the snapshot boot run end to end. |

A Firecracker (or other) provider implements five calls, either as a `RawCloudDriver` (then it
also gets machines, power and snapshots in CloudDO) or directly as a `CloudSandbox`. The interface
needs no "capabilities" flags, because every provider we would use has boot-from-snapshot.

## 7. Storage

The user's rule for cmux-next (2026-10-28): no Postgres. New tables go in `cmux-next-vitess`
(PlanetScale), with no triggers and no foreign keys.

- Source of truth: rows in the team's CloudDO (table `environment`), next to the `machine` and
  `snapshot` rows it already holds. A build's snapshot is an ordinary CloudDO snapshot row. Quota,
  deletion and the provider ledger are therefore the same code as for manual snapshots, in the
  same transaction.
- Read model: the CloudDO projects a summary row of each environment to Vitess
  (`cloud_environments`: id, team, name, repo, status, snapshot id, creator, times). The table is
  created by `backend/db/drizzle-mysql/0003_cloud_environments.sql` (`-- phase: expand`), has an `id`
  primary key and a `(team_id, deleted_at)` index, and has no foreign keys and no triggers. The
  projection kinds `cloud.environment.upsert` and `cloud.environment.delete` exist only for MySQL;
  the Postgres drain skips them. A delete is a soft delete under the `(source_stream, source_seq)`
  guard, so a replayed older upsert cannot bring the row back. The setup script and the variable
  values never leave the CloudDO.

### Ops (owner `cloud:CloudDO`)

| Op | Risk | What |
|---|---|---|
| `cloud.environment.list` | read | The team's environments with their status: unbuilt, building, ready, stale or failed. |
| `cloud.environment.set` | mutate-shared, person | Create (name required) or edit. An edit of the repo, the script or the variables makes the snapshot stale. A rename does not. At most 20 per team. |
| `cloud.environment.build` | money, person | Answers at once with `building`. The CloudDO alarm runs the build (an `env_build` ledger row), after every other due provider call. The setup has a 10-minute limit inside the 15-minute alarm. A matching snapshot answers `built: false`. |
| `cloud.environment.boot` | money, person | `cloud.machine.create` from the fresh snapshot (`boot: snapshot`), or cold with the setup started on the machine (`boot: cold`). |
| `cloud.environment.delete` | destructive, person | Deletes the row and its snapshot (a `snapshot_delete` ledger row). |

Installs go through the person's approval (G8), like the other money ops. Agents are refused for
every write. A build or a boot with a secret variable answers `cloud.environment.secrets_unavailable`.

## 8. Plan and status

| Step | Status |
|---|---|
| Spec, validation, digest, build script, boot plan (`@cmux/cloud-env`) | Landed, 34 tests (real bash for the script and the detached build) |
| `CloudSandbox` interface, `GuardedCloudSandbox` over `RawCloudDriver` | Landed |
| Measured on Freestyle through the CloudDO driver stack | Landed (section 9) |
| CloudDO ops `cloud.environment.{list,set,delete,build,boot}`, `environment` rows | Landed, 7 tests in the Workers runtime |
| Vitess table and projection `cloud_environments` | Landed (migration 0003, expand; CI applies it to staging with `CMUX_NEXT_VITESS_STAGING_ADMIN_URL`) |
| Generated clients (catalog, TS, Rust `cmux-cloud-wire`) | Landed |
| Mac: wizard source "Environment", "Save as environment", Settings list | Next, after the ops |
| Secrets at boot from the hosted vault | Waits on the hosted vault (a714, its section 9) |

## 9. Measurements

Freestyle, the cmux-next development image (`cmuxnp-dev-vmimg-ci-40270232246-1`), through
`FreestyleCloudDriver` → `GuardedCloudDriver` → `GuardedCloudSandbox`
(`backend/apps/api/scripts/bench-cloud-env.ts`). The environment is `manaflow-ai/cmux@feat-cmux-next`,
`cd web && bun install --frozen-lockfile`. "Ready" means the checkout and `environment.json` exist
in the work home.

| Path | Run 1 | Run 2 |
|---|---|---|
| Cold boot to ready (boot + guest ready + clone and install) | 187.8 s (6.2 + 6.2 + 175.4) | 135.9 s (6.4 + 5.7 + 123.8) |
| Snapshot boot to ready, 3 boots | 0.63 s, 0.78 s, 17.7 s (one slow create) | 0.40 s, 0.56 s, 0.44 s |
| Snapshot taken | 1.7 s | 1.7 s |
| Warm boot inside the build | not run | 0.54 s |

Median snapshot boot over the 6 boots: about 0.6 s, against 136-188 s cold, or about 230-310x
faster. On the classic image (`web/` driver, same environment), cold boot was 50-67 s and snapshot
boot was 0.79-0.94 s.
