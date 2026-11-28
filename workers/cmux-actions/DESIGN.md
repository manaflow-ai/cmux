# cmux Actions: design

Experiment under decision CMUX-ACTIONS-EXPERIMENT (A1-A5) in the cmux-next spec,
built on the cmux VM API (decision CMUX-VM-API, V1-V7 and amendment 1). Tracking:
beads `cx-0uj`.

cmux Actions is our own GitHub Actions engine. GitHub supplies events and receives
commit statuses. Everything else (parsing, scheduling, execution, caching, logs)
runs on Cloudflare Workers, Durable Objects (DOs), R2 and cmux VMs. It is not a
self-hosted runner and never registers with GitHub.

Inputs read for this design: every file in `.github/workflows` and
`.github/actions` at `origin/main` 8f8fd09a25ac, the cmux VM OpenAPI document
`workers/cmux-vm/openapi.json` on `feat-cmux-vm-s1` 4b55de6bf66d (PR 18194),
the S2 red tests on `feat-cmux-vm-s2` dcacaed6dc29, and the pinned provider
document `workers/cmux-vm/upstream/openapi.json` (88 operations).

## 0. Top risk: IPv6-only VM egress

Finding: hq `scripts/freestyle-run` (commit 83880c677a5e, 2026-10-06) records
that Freestyle VMs are IPv6-only, so GitHub release downloads fail there (its
bun install goes through npm for that reason). GitHub's web, API, git and asset
hosts (`github.com`, `api.github.com`, `codeload.github.com`,
`objects.githubusercontent.com`, `release-assets.githubusercontent.com`,
`raw.githubusercontent.com`) have no IPv6 today as far as we know, so the risk
is wider than release assets: `actions/checkout`, `git submodule update`,
`setup-node` (its first source is the `actions/node-versions` release assets),
`mlugg/setup-zig`, `rustup` self-install from `sh.rustup.rs`, and any step that
curls a GitHub URL would fail. npm, crates.io, PyPI and Ubuntu apt mirrors
answer over IPv6 and are not affected. The provider schema does list an
optional `egressIpv4` on a VM, so IPv4 egress may exist for some accounts or
plans; we ask (need N19).

Options compared:

| option | how | where it runs | cost | transparency | risks |
| --- | --- | --- | --- | --- | --- |
| P1 pre-bake tools | runner image holds every toolchain our workflows pin (node 22.14.0 and 24 in `RUNNER_TOOL_CACHE`, bun 1.3.14 and 1.4.2, go, python, zig from `scripts/install-zig-ci.sh`, rustup with the `rust-toolchain.toml` channels, apt packages); `setup-*` actions find the toolcache entry and skip the download | inside the snapshot | bake time plus snapshot storage only | full for pinned versions | does not fix `actions/checkout`, submodules or `api.github.com`; every new version needs a re-bake |
| P2 egress Worker tunnel | the agent runs a local HTTP CONNECT proxy on `127.0.0.1`; steps get `HTTPS_PROXY`, `HTTP_PROXY`, `https_proxy`, `http_proxy`, `ALL_PROXY`, `NODE_USE_ENV_PROXY=1` and a git `http.proxy`. For each CONNECT the local proxy connects directly when the host has an AAAA record, else tunnels the bytes over a WebSocket to an egress Worker that opens the IPv4 TCP connection with `connect()` (TLS stays end to end; the Worker sees only host and byte counts) | Cloudflare Workers (reachable over IPv6), no new server | Workers requests plus CPU; Cloudflare egress is free; expected well under the VM cost | everything that honors proxy env (git, curl, `@actions/http-client`, `@actions/tool-cache`, rustup, cargo, npm, bun, pip, apt with `Acquire::https::Proxy`) | binaries that ignore proxy env; per-connection throughput of `connect()` is unmeasured; `connect()` refuses Cloudflare-hosted IPs and port 25 |
| P3 NAT64 plus DNS64 | a dual-stack gateway (for example a GCP e2-small with its external IPv6 /96 as the NAT64 prefix, Jool plus Unbound DNS64); the agent points `/etc/resolv.conf` at it | one small GCP VM (or the existing dev-backend VM) | about USD 15 to 30 per month for the VM plus internet egress about USD 0.12 per GB (estimate: 0.5 GB of GitHub traffic per job) | transparent at the IP layer, also for binaries that ignore proxies | a single gateway to run and patch; the NAT64 prefix must be routed to the gateway from the provider network (unverified); the resolver override needs root at boot |
| P4 provider IPv4 egress | enable IPv4 egress on job VMs if the provider offers it | provider | provider price | transparent | unknown availability; needs a cmux VM API setting (N19) |
| P5 public NAT64 services | point DNS64 at a third-party NAT64 | third party | free | transparent | untrusted operator on every connection, rate limits; rejected |

Recommendation: P1 plus P2, with P4 adopted if the provider offers it, and P3 as
the fallback if P2's measured throughput is too low. P1 is required anyway for
warm snapshots (no step should download a toolchain on a warm run). P2 covers
checkout, submodules, the GitHub API and release assets with no new server and
no new bill, and the dual path (direct IPv6 when an AAAA record exists) keeps
npm, crates.io and PyPI traffic off the tunnel. The egress Worker accepts only
an authenticated job token, only ports 443 and 80, and records host and bytes
per job for the cost line. Proxy env is set by the agent before the first step,
like the other runner env, so workflows stay unmodified.

Slice 2 tests, first in an IPv6-only container on CI (no IPv4 route; real VMs
are out of scope until VM calls are allowed), then on a cmux VM:
`actions/setup-node@48b55a01` with a toolcache hit (22.14.0) and a toolcache miss
(forces the release-asset download through P2); a `curl -fL` of a GitHub
release asset; `git ls-remote` and `actions/checkout` of `manaflow-ai/cmux`
with `git submodule update --init --depth 1 ghostty`. Each must pass through
P2, and a control run without the proxy must fail, which proves the container is
really IPv6-only.

## 1. Operating mode: shadow runs on an allowlist

GitHub keeps running every workflow on Blacksmith. cmux Actions runs the same
event in parallel and reports under its own status contexts
(`cmux-actions/<workflow name>/<job name>`). Nothing on GitHub depends on these
statuses during the experiment, so a broken cmux Actions run cannot block a
merge.

Because both engines run the same YAML, any job with side effects would run
twice. So a job runs on cmux Actions only if its `(workflow path, job id)` is on
the per-repo allowlist (default empty), and the static classifier (section 5.6)
also accepts it. The proof allowlist is `cmux-tui.yml` jobs `validate-inputs`,
`lint` (linux leg) and `test` (linux leg).

## 2. Architecture

```
GitHub webhook (push, pull_request, workflow_dispatch)
   |  HMAC X-Hub-Signature-256
   v
Worker  /github/webhook ............................. RepoDO(repo)
   |                                                     | dedupe delivery, filters,
   |                                                     | fork gate, concurrency groups,
   |                                                     | secrets, vars, allowlist,
   |                                                     | snapshot registry
   |                                                     v
   |                                                  RunDO(run)  parse YAML at SHA,
   |                                                     | job graph, matrix, if, needs,
   |                                                     | reusable workflows, statuses
   |                                                     v
   |                                                  JobDO(job attempt) ---- FleetDO (global)
   |                                                     | VM lease, snapshot pick,     cap 20 VMs, queue,
   |                                                     | agent socket, logs, timeout  budget, orphan reaper
   |                                                     v
   |                                               cmux VM API (service binding)
   |                                                     v
   |                                               job VM: cmux-actions-agent (TypeScript, node)
   |                                                     | WebSocket: step events + logs
   |                                                     | Twirp: cache + artifact control
   v                                                     v
Worker  /twirp/...  /blob/... ............ CacheDO(repo), RunDO artifacts, R2
Worker  /runs/... run page (graph + live logs)
```

The VM never calls the provider. JobDO is the only caller of the cmux VM API.
Package: `workers/cmux-actions` (TypeScript, Effect, Workers, DOs, R2), license
`GPL-3.0-or-later` like `workers/cmux-vm`. The in-VM agent lives in
`workers/cmux-actions/agent` and shares the workflow model and expression engine
with the Worker.

## 3. Durable Objects: ownership and state

All DO state lives in DO SQLite. Every timer is a DO alarm. Every external call
that creates something carries an idempotency key derived from DO state, so a DO
restart repeats the call safely.

| DO | Key | Owns | State |
| --- | --- | --- | --- |
| RepoDO | `owner/repo` | webhook intake, delivery dedupe, trigger filters, fork gate, concurrency groups (workflow and job level), allowlist, vars, secrets (encrypted), run numbering, warm snapshot registry | `deliveries(id, received_at)` 7-day window; `runs(run_id, workflow, sha, ref, event, state)`; `concurrency(group, running_run_or_job, pending)`; `allowlist`; `vars`; `secrets(name, ciphertext, iv, dek_version)`; `snapshots(key, scope, snap_id, created_at, last_used_at, bytes, state)` |
| RunDO | run id | workflow fetch and parse at the exact SHA, job graph, matrix expansion (static and deferred), `if` and `needs` evaluation, reusable workflow inlining, run-level cancel, commit statuses, artifacts index, run page data | `run`, `jobs(job_key, state, result, outputs_json, attempt)`, `statuses_outbox`, `artifacts(id, name, job, r2_key, size, digest, expires_at)` |
| JobDO | `run/job_key/attempt` | one VM from lease to delete: lease, snapshot choice, create, job spec upload, agent start, agent WebSocket (hibernation), log buffering to R2, timeout, cancel, post-job snapshot, delete by exact id | `job`, `vm(cmux_vm_id, state)`, `steps(idx, state, conclusion, started, ended)`, `log_cursor`, `lease_id`, `token_jti` |
| FleetDO | singleton | global VM cap, admission queue, VM-minute budget, kill switch, orphan reaper, global snapshot count | `leases(lease_id, job_do, vm_id, since, vcpus)`, `queue(job_do, repo, enqueued_at, priority)`, `budget(day, vm_seconds)` |
| CacheDO | `owner/repo` | Actions cache index (key, version, scope), pending uploads, LRU eviction, repo size cap | `entries(scope, key, version, r2_key, size, created, last_access)`, `uploads(upload_id, blocks_json, expires)` |

Why this split: RepoDO serializes per-repo decisions (concurrency, dedupe,
snapshot registry). RunDO and JobDO keep hot write traffic (job state, log
frames) off RepoDO. FleetDO is the only global serialization point and handles
only lease grant and release (a few writes per job). CacheDO is separate from
RepoDO because cache traffic is bursty and should not delay webhook intake.

## 4. Event intake and run creation

1. Worker verifies `X-Hub-Signature-256` with the repo's webhook secret, then
   forwards to RepoDO. Unknown repos get 404.
2. RepoDO drops a repeated `X-GitHub-Delivery`.
3. Fork gate: a `pull_request` event whose `pull_request.head.repo.full_name`
   differs from the base repo is dropped and recorded, never run. `pull_request_target`,
   `workflow_run`, `issue_comment` and other triggers are not consumed in the
   experiment.
4. RepoDO lists `.github/workflows` at the event SHA with one Git trees call
   (recursive tree; blob SHAs are content hashes) and fetches only changed or
   unseen blobs into R2 (`blobs/<sha>`, immutable).
5. For each workflow whose `on:` matches the event (branches, branches-ignore,
   tags, paths, paths-ignore, types, workflow_dispatch inputs), and that has at
   least one allowlisted job, RepoDO creates a RunDO. Path filters use the
   compare API for `push` and the PR files API for `pull_request`, with GitHub's
   300-file limit semantics.
6. Workflow-level `concurrency` is applied in RepoDO before the run starts.

`github.run_id` is a 53-bit integer minted by RepoDO (time-ordered, never
reused). `github.run_number` counts per workflow. `github.run_attempt` starts at 1.

## 5. Workflow model and expressions (slice 1)

### 5.1 Parsing
YAML 1.2 core schema (`yaml` package, eemeli), so `on` stays a string key and
`ports: [5432:5432]` parses (Ruby's YAML 1.1 parser rejects
`web-validation.yml` line 115; GitHub accepts it). Source positions are kept for
error messages. The parsed tree is decoded with Effect Schema into a typed model
(workflow, triggers, jobs, steps, strategy, services, defaults, permissions,
concurrency, workflow_call inputs/outputs/secrets). Unknown keys are recorded,
not fatal.

### 5.2 Expression engine
Lexer, Pratt parser and evaluator for `${{ }}`, matching GitHub semantics:
loose equality and coercion rules, case-insensitive string compare, `null`
handling, property dereference and `*` object filters, short-circuit `&&`/`||`
returning operand values (our `runs-on` expressions depend on that), and literal
templates mixed with text. Functions: `contains`, `startsWith`, `endsWith`,
`format`, `join`, `toJSON`, `fromJSON`, `hashFiles`, `success`, `always`,
`cancelled`, `failure`. Contexts: `github`, `env`, `vars`, `secrets`, `inputs`,
`matrix`, `strategy`, `needs`, `jobs`, `steps`, `runner`, `job`.

Usage in our workflows (`.github/workflows` + `.github/actions`, 135 files, 318
jobs): `fromJSON` 128, `contains` 125, `cancelled` 69, `hashFiles` 55, `always`
50, `format` 49, `startsWith` 42, `failure` 16, `toJSON` 14, `success` 8,
`endsWith` 4. Contexts: `github` 1841, `steps` 1068, `inputs` 872, `vars` 848,
`needs` 704, `matrix` 462, `runner` 336, `secrets` 286, `env` 84, `jobs` 11,
`job` 1.

### 5.3 Where each expression is evaluated
- RunDO: `on`, workflow `env`/`concurrency`/`run-name`, job `if`, `runs-on`,
  `strategy`, `needs`, `timeout-minutes`, `concurrency`, `services`, job `env`,
  `outputs` (after the job ends), reusable `with`/`secrets`.
- Agent (in the VM): step `if`, `with`, `env`, `run` interpolation,
  `working-directory`, `shell`, `continue-on-error`, `timeout-minutes`, composite
  action steps, `hashFiles` (needs the workspace), job `outputs` from `steps`.
The same TypeScript module runs in both places, so results cannot diverge.

### 5.4 Matrix, needs, conditions
Matrix expansion follows GitHub's include/exclude algorithm exactly, with the
256-job limit, `fail-fast` (default true), `max-parallel`. Dynamic matrices
(`fromJSON(needs.x.outputs.y)`, 3 jobs today) expand when the needed jobs
finish. Default job `if` is `success()`. A failed or cancelled dependency skips
the job unless its `if` uses a status function. `needs.<id>.result` and
`.outputs` follow GitHub.

### 5.5 Reusable workflows and composite actions
Reusable workflows: local `./.github/workflows/*.yml` only (all 29 calls in our
repo are local), resolved at the same SHA, inlined as a sub-graph with
`workflow_call` inputs (typed, with defaults), `secrets` (explicit or `inherit`),
and outputs mapped through the `jobs` context. Nesting depth limit 4 (GitHub's).
Composite actions: local (`./.github/actions/*`, 5 today) and remote, steps run
by the agent with their own `inputs`, `github.action_path`, and `outputs`.
JavaScript actions: `node20` and `node24`, with `pre`, `main`, `post`,
`pre-if`, `post-if`, `INPUT_*`, `GITHUB_STATE`/`STATE_*`. Remote actions must be
pinned to a 40-character SHA (every external `uses:` in our repo is pinned); the
Worker fetches the tarball once into R2 (`actions/<owner>/<repo>/<sha>.tar.gz`).

### 5.6 Static job classifier
Before a job is scheduled, RunDO marks it `unsupported` (reported as an
`error` status with the reason, never run) if any of these hold: `runs-on`
resolves to a non-Linux label; `container:` or a `docker://` / Dockerfile
action; `permissions` asks for `id-token: write` (no OIDC provider); an
`environment:`; a step that needs a GitHub token with write scope
(`actions/create-github-app-token`, `github-script` with write calls,
`softprops/action-gh-release`, `actions/attest*`, publish actions); a secret not
present in our store. Counts in today's tree: 30 files use `environment:`, 16
use `id-token: write`. The full per-job table is slice 3.

## 6. Job lifecycle

```
queued -> admitted (FleetDO lease) -> provisioning (create VM from snapshot)
  -> booting (write job spec, start agent) -> running (steps)
  -> finishing (post steps, outputs, logs flushed)
  -> capturing (snapshot, only if eligible) -> releasing (delete VM by id, release lease)
  -> completed(success | failure | cancelled | skipped | error)
```

1. RunDO creates JobDO with the resolved job (steps unexpanded), labels, timeout,
   the job token, and the secrets the job references.
2. JobDO asks FleetDO for a lease (vCPUs from the label map). FleetDO grants or
   queues. Queue order: FIFO per priority (push to default branch, then dispatch,
   then PR), with one admitted job per repo guaranteed before a second repo job.
3. JobDO picks a snapshot (section 8), then `POST /v1/vms` with `snapshotId`,
   resources, labels, `idleTimeoutSeconds`, `maxRunSeconds`, idempotency key
   `job:<run>/<job_key>/<attempt>`.
4. JobDO writes `/run/cmux-actions/job.json` (job spec, no secrets) through the
   files API, then starts the agent with one short exec:
   `cmux-actions-agent start --spec /run/cmux-actions/job.json` (detaches,
   returns in under 1 s). Secrets and the job token are passed in that exec's
   `env`, never written to disk by us.
5. The agent opens a WebSocket to JobDO
   (`/agent/<job>?token=<job token>`), sends `hello`, and runs steps. Each step
   sends `step.start`, log frames, `step.end(outcome, conclusion, outputs)`.
6. On completion the agent sends `job.end`, flushes, stops its children and
   exits. JobDO then captures a snapshot if eligible, deletes the VM by its exact
   `vm_` id, releases the lease, and reports to RunDO.

Why an agent instead of one exec per step: provider exec is `exec-await` only,
capped at 300 s (`timeoutMs` 1 to 300000), with buffered output.
`test (linux)` in `cmux-tui.yml` takes 9 to 11 minutes on Blacksmith (runs
37564471089, 37563631384, 37562472059 on 2026-10-07). Steps must outlive a
single exec, and logs must stream while a step runs.

## 7. Runner image and labels

The runner image is a cmux VM snapshot baked by a script in this package: Ubuntu
24.04 userland, user `runner` (uid 1001) with passwordless sudo, `/home/runner/work`
as the workspace root, git, curl, zstd, tar, unzip, jq, python3, node 20 and 24,
docker (for `services:`), `/opt/hostedtoolcache`, `JAVA_HOME_17_X64` (used by
`cmux-tui.yml` bindings-e2e), and the agent. The image id is a versioned
`snap_` id recorded in RepoDO config; a new image version is a new cache key
component, so it invalidates warm snapshots by construction.

Label map (after `runs-on` evaluation with our `vars` and
`github.repository_owner == 'manaflow-ai'`):

| label | VM |
| --- | --- |
| `ubuntu-24.04`, `ubuntu-latest` | 4 vCPU, 16 GiB |
| `blacksmith-<N>vcpu-ubuntu-2404` | N vCPU, 4N GiB (Blacksmith's ratio; to confirm), N <= 32 |
| anything with `macos`, `windows`, `depot-` | unsupported |

Today 107 + 71 + 28 jobs resolve to a Linux Blacksmith label by default; the
rest are macOS or Windows. Disk: 64 GiB default, per-job override in config.
`RUNNER_OS=Linux`, `RUNNER_ARCH=X64` assume x86_64 VMs; to confirm with the cmux
VM workers.

## 8. Warm snapshots (A3a)

### 8.1 Key
```
snapshot_key = sha256(
  repo, workflow_path, job_id, canonical(matrix values),
  runner image snapshot version, label (vCPU/memory/disk),
  lockfile_digest)
lockfile_digest = sha256 of sorted "(path, git blob sha)" for files matching the
  job's lockfile globs at the event SHA
```
Lockfile globs per job: every literal glob passed to `hashFiles(...)` in the
job's steps and the composite actions they use, plus a default set
(`**/Cargo.lock`, `**/rust-toolchain.toml`, `**/package-lock.json`,
`**/bun.lock`, `**/bun.lockb`, `**/go.sum`, `**/uv.lock`, `**/requirements*.txt`,
`.gitmodules` plus submodule gitlink SHAs). Blob SHAs come from the same Git
trees call as section 4, so computing the digest downloads no file content.

### 8.2 Scope (poisoning control)
A snapshot carries the scope of the run that produced it, with GitHub cache
rules: a run reads snapshots of its own ref, then the PR base ref, then the
default branch; it writes only its own ref's scope. Default-branch snapshots are
written only by `push` or `workflow_dispatch` on the default branch. A same-repo
branch can only warm its own branch. Fork PRs never run, so they never read or
write.

### 8.3 Selection
Exact key in the run's readable scopes, newest first. On miss: newest snapshot
with the same key minus `lockfile_digest` (a partial match, like
`restore-keys`). On miss: the runner image (cold). The choice and the reason are
in the job log header.

### 8.4 Capture and eligibility
Capture after `job.end` only if all hold: job conclusion `success`; the job
received no secret from our store (job token and the read-only GitHub token are
allowed, section 10); the job did not opt out (`cmux-actions: snapshot: false`
in repo config); scope rule 8.2 allows the write. Before capture the agent
stops its own processes and removes `/run/cmux-actions`, `$RUNNER_TEMP`, and git
`extraheader` config in the workspace. Snapshot memory and disk both persist,
so background daemons started by the job (for example `sccache`) resume warm.

### 8.5 Retention and invalidation
At most 2 snapshots per key (LRU by `last_used_at`), 50 per repo, provider
`autoDeleteSeconds` 7 days without use, `ttlSeconds` 14 days. Invalidation is by
key change (image version, lockfiles, matrix, label) plus explicit delete
(admin API, or automatic after a job on that snapshot fails with an infra
error twice in a row). Every delete is by exact `snap_` id.

### 8.6 What the snapshot cannot keep warm
`actions/checkout` with the default `clean: true` runs `git clean -ffdx` and
`git reset --hard`, which removes ignored build output in the workspace (for
`cmux-tui.yml`, `cmux-tui/target`). We do not change checkout semantics. The
snapshot keeps everything outside the workspace warm (rustup toolchains, zig,
apt packages, `~/.cargo/registry`, `~/.cache`, npm and bun caches, sccache), and
the workspace build output comes back through `Swatinem/rust-cache` from the
local cache tier (section 9.4) at disk speed instead of the network. See
trade-off T3.

### 8.7 Forked memory and randomness (requirement)
A VM booted from a memory snapshot starts with the parent's kernel RNG state,
machine id, host keys and clock. Parallel jobs forked from one snapshot would
produce the same random values. This is a security requirement (coordinator
decision C4), not only a risk:

After every restore from a memory snapshot, and before the first step runs, the
agent must:
1. reseed the kernel RNG: write 64 bytes of fresh entropy, sent by JobDO in the
   start exec and generated with `crypto.getRandomValues` in the Worker, to
   `/dev/urandom` with the `RNDADDENTROPY` ioctl (credited), then read and
   discard 64 bytes;
2. regenerate `/etc/machine-id` (and `/var/lib/dbus/machine-id`);
3. regenerate every host key present (`/etc/ssh/ssh_host_*`);
4. sync the clock to the time JobDO sends in the start exec, and refuse to run
   if the skew after sync is above 2 s;
5. report the new machine id and a hash of 32 random bytes in `hello`. JobDO
   refuses the job (infra error) if either value equals one already seen for
   the same snapshot.
Slice 2 tests it: two VMs forked from one snapshot must produce different random
bytes and different machine ids. Provider behavior (VM generation ID) is still
asked of the cmux VM workers (need N14), but the agent steps above run either
way.

## 9. Cache and artifact protocols on R2 (A3b)

### 9.1 Environment given to steps
`ACTIONS_RUNTIME_TOKEN` (job JWT), `ACTIONS_RESULTS_URL`
(`http://127.0.0.1:<agent port>/`), `ACTIONS_CACHE_SERVICE_V2=true`; no
`ACTIONS_CACHE_URL` (the v1 service), no `ACTIONS_ID_TOKEN_REQUEST_URL`. The
agent proxies Twirp calls to the Worker with the job token, and serves blob
URLs locally (9.4).

### 9.2 Cache service (Twirp `github.actions.results.api.v1.CacheService`)
Used by `actions/cache@27d5ce7f` (v5.0.5), `actions/cache/restore|save`,
`Swatinem/rust-cache`, `actions/setup-node` with `cache:`, and
`.github/actions/cache-restore|cache-save`.
- `CreateCacheEntry(key, version)`: CacheDO reserves `(scope=ref, key, version)`
  (first writer wins, like GitHub) and returns a signed upload URL.
- `FinalizeCacheEntryUpload(key, version, sizeBytes)`: commits the R2 object,
  records size, enforces the repo cap (10 GiB, LRU eviction).
- `GetCacheEntryDownloadURL(key, restoreKeys, version)`: exact key then prefix
  match over readable scopes (8.2 order), newest first; returns a signed URL and
  the matched key.

### 9.3 Artifact service (Twirp `github.actions.results.api.v1.ArtifactService`)
Used by `upload-artifact` (v4 and v7 pins) and `download-artifact` (three pins).
`CreateArtifact`, `FinalizeArtifact`, `ListArtifacts`, `GetSignedArtifactURL`,
`DeleteArtifact`, stored per run in RunDO and R2 under
`artifacts/<repo>/<run>/<id>.zip`. The artifact toolkit reads the run and job
backend ids from the JWT `scp` claim (`Actions.Results:<run>:<job>`), so the job
token is a JWT with that claim. `retention-days` is clamped to 7.
Cross-run download (`download-artifact` with `run-id` and `github-token`) calls
GitHub's REST API and is unsupported.

### 9.4 Blob transport and the local tier
The toolkit uploads with the Azure Blob SDK (single `Put Blob` up to 128 MiB for
cache archives, otherwise `Put Block` plus `Put Block List`; artifacts always use
blocks) and downloads with plain HTTP GET and `Range`. A Worker request body is
capped at 100 MB, below the 128 MiB single shot. So signed URLs point at the
agent (`http://127.0.0.1:<port>/blob/<token>`), which:
- stores the blob in the VM's local blob store (`/var/lib/cmux-actions/blobs`,
  content-addressed, 20 GiB LRU), and
- streams it to R2 through presigned S3 multipart part URLs that the Worker
  mints (direct to R2, no Worker body limit; Azure blocks are staged locally and
  re-cut into equal R2 parts, since R2 requires equal part sizes except the
  last).
On restore, if the local store already holds the object (it does in a warm
snapshot), the agent serves it from disk; otherwise it streams from R2 and
keeps a copy. The local store is part of the VM-level snapshot, which is how A3a
and A3b combine. Toolkit behavior on non-Azure hosts is the riskiest protocol
assumption; slice 2 verifies it with the pinned toolkit versions against our
server before any VM exists.

## 10. Secrets, variables and tokens (A4)

- Store: RepoDO table `secrets`, AES-256-GCM, per-repo data key wrapped by a key
  encryption key held only in the Worker secret `CMUX_ACTIONS_KEK`. Key rotation
  re-wraps data keys. Values are write-only through the admin API; reads return
  names and update times.
- GitHub secrets are not readable and are not copied. A job that references a
  secret we do not hold is `unsupported`, not run with an empty value.
- Delivery: only the secrets a job references (static scan of the job, its
  composite actions and reusable workflow `secrets:` mapping) go to the agent,
  in the start exec `env`. Never in the job spec file, never in the snapshot.
- Masking: the agent masks every secret value, each line of multiline values,
  and `::add-mask::` values before a log frame leaves the VM. JobDO masks again
  with the values it holds (defense in depth).
- Variables: our own per-repo `vars` store (plain). For the experiment `vars`
  is empty, so `runs-on` expressions fall to their Blacksmith defaults.
- `github.token`: GitHub requires a token for `actions/checkout`. Jobs get a
  GitHub App installation token (coordinator decision C3), minted per job with
  `repositories: [cmux]` and `permissions: {contents: read, metadata: read}`;
  it expires within one hour. Write-scoped actions are `unsupported`.
  Checkout's post step removes its credential and the agent scrubs
  `extraheader` before capture. The App manifest and its registration flow are
  in `github-app/` (section 19).
- Job token: JWT signed by the Worker (HMAC key in Worker secrets), claims
  `repo`, `run`, `job`, `attempt`, `scp`, `cache_read_scopes`,
  `cache_write_scope`, `exp` = job timeout + 15 min. JobDO revokes it at job end
  (JobDO rejects tokens for finished jobs), so a token left in a snapshot is
  dead.

## 11. Security model

1. Fork PRs never run (section 4, step 3). Only `push`, same-repo
   `pull_request`, and `workflow_dispatch` are consumed.
2. Allowlist plus static classifier (sections 1 and 5.6): no deploy, publish,
   OIDC or environment-protected job runs here.
3. One VM per job attempt, created from a snapshot, deleted by exact id after
   capture. No VM is reused for another job. Snapshots never hold our secrets
   (8.4).
4. Snapshot scopes follow cache scopes (8.2), so a branch cannot poison main.
5. Tokens: job JWT is per job, short-lived, revoked at job end. The GitHub token
   is a read-only App installation token that expires within one hour. The App
   private key and the cmux VM API key never reach a VM.
6. Webhook HMAC, delivery dedupe, admin API behind an admin key (hash in Worker
   secrets). Run page and logs require a cmux session of the manaflow team
   (coordinator decision C6).
7. Agent channel: the agent can only report on its own job (token binds job);
   JobDO ignores frames after `job.end`.
8. Supply chain: remote actions only at 40-character SHAs, fetched once and
   pinned by content in R2.
9. VM egress is open over IPv6; IPv4-only hosts go through the authenticated
   egress Worker (section 0). Egress control is a later option (need N12).

## 12. Cap and cost controls

- FleetDO cap: 20 concurrent VMs across all repos (A4), counted from lease
  grant to confirmed delete, so snapshot capture counts. Config can lower it.
- Every VM: `idleTimeoutSeconds` 300 (decision limit for dev/test VMs), the
  agent heartbeats over the WebSocket every 30 s so a CPU-bound compile is not
  idle (to confirm what "idle" means, need N7), and `maxRunSeconds` =
  job timeout + 10 min as a provider-side backstop.
- Job `timeout-minutes` honored, clamped to 60 in the experiment (GitHub
  default 360). JobDO alarm enforces it: cancel steps, wait 5 min, delete VM.
- Budget: daily VM vCPU-seconds limit in FleetDO; above it, new leases are
  refused and jobs end `error: budget`. Kill switch var stops all admission.
- Rate: at most 30 runs per hour per repo; a newer push to the same ref cancels
  pending (not running) cmux Actions runs of the same workflow.
- Storage: one R2 lifecycle rule deletes every object 14 days after creation
  (coordinator decision C2). Snapshots per section 8.5; cache 10 GiB per repo
  (LRU); per run: logs at most 64 MiB per job and 256 MiB per run (JobDO stops
  storing and marks the log truncated), artifacts at most 2 GiB per run
  (`CreateArtifact` refuses above it), artifact retention clamped to 14 days.
- Cost line: the run page shows a daily cost line (VM vCPU-seconds and GiB-
  seconds by day, snapshot storage, R2 bytes stored and operations), computed by
  FleetDO from lease records and R2 counters with the unit prices in config
  (coordinator decision C2).
- Reaper: FleetDO alarm every 5 min lists VMs with label
  `cmux-actions=1` and deletes, by exact id, any VM without a live lease.

## 13. Failure and retry

| failure | handling |
| --- | --- |
| cmux VM create 5xx, timeout, `QuotaExceeded` | retry with backoff (honor `retryAfterSeconds`), same idempotency key; after 3 tries the job attempt is an infra error |
| agent does not connect in 120 s | infra error; VM deleted |
| agent socket drops | 60 s grace for reconnect (agent buffers frames with sequence numbers and resends); then `GET /v1/vms/{id}`; gone or stopped means infra error |
| infra error | new attempt on a fresh VM, up to 2 automatic retries; second retry boots cold (no snapshot); two infra errors on one snapshot marks it bad |
| step failure | job failure, no automatic retry (GitHub behavior); manual re-run from the run page creates attempt N+1 |
| DO restart | state in SQLite, alarms re-armed, external calls repeated with the same idempotency keys |
| webhook redelivery | deduped by delivery id |
| status post failure | outbox in RunDO, retried by alarm; statuses are last-write-wins |
| snapshot capture failure | job result unchanged, warning in the log, VM still deleted |
| VM delete failure | lease stays held, reaper retries; the cap therefore never undercounts |

## 14. Logs and GitHub reporting

- Agent: per step, splits stdout and stderr into lines, masks, parses workflow
  commands (`::group::`, `::endgroup::`, `::error::`, `::warning::`,
  `::notice::`, `::debug::`, `::add-mask::`, `::stop-commands::`, and the
  `GITHUB_OUTPUT`/`GITHUB_ENV`/`GITHUB_PATH`/`GITHUB_STEP_SUMMARY`/`GITHUB_STATE`
  files), and sends frames `{seq, step, ts, stream, text}` in batches every 250 ms
  or 32 KiB.
- JobDO: appends to a buffer, writes 1 MiB or 10 s chunks to R2
  (`logs/<repo>/<run>/<job>/<attempt>/<n>.ndjson`), fans out to run page viewers
  through hibernatable WebSockets, and writes a final plain-text log on
  completion.
- GitHub: the experiment reports commit statuses (A1) through the GitHub App.
  Check runs (`checks: write`, optional in the manifest) can later add
  annotations and a summary; there is no log UI on GitHub either way. Each job
  posts a commit status: `pending` on admission, description
  updated at step boundaries (at most once per 30 s, 140 characters, current
  step and elapsed time), final `success`/`failure`/`error`, `target_url` = run
  page. Annotations and step summaries render on the run page.
- Run page: `/runs/<owner>/<repo>/<run_id>` served by the Worker: job graph,
  per-step logs (R2 for history, WebSocket for live), artifacts, timings, and
  the snapshot choice per job.

## 15. What cmux Actions needs from the cmux VM API

Compared against `workers/cmux-vm/openapi.json` on `feat-cmux-vm-s1`
4b55de6bf66d (10 operations: health, create, list, get, delete, start, stop,
pause, resume, fork; only get is served, the others answer 501 until S2) and the
S2 red tests on `feat-cmux-vm-s2` dcacaed6dc29 (exec, files content, files
entries).

| # | need | used for | in openapi.json now | gap |
| --- | --- | --- | --- | --- |
| N1 | create VM from a snapshot: `snapshotId`, `idleTimeoutSeconds`, `displayName`, `Idempotency-Key` | every job | yes (`POST /v1/vms`) | 501 until S2 |
| N2 | create with resources: vCPU, memory MiB, disk MiB (up to 32 vCPU / 64 GiB) | label sizing | no; `Vm.resources` is output only | add `resources` to `CreateVmRequest` (provider has only grow-only `resize`, so create then resize inside the API) or add `POST /v1/vms/{id}/resize` |
| N3 | create with `maxRunSeconds` (and `autoDeleteSeconds`) | provider-side backstop for a lost JobDO | no | add to `CreateVmRequest`; provider supports both |
| N4 | labels on VMs: set at create, returned on get/list, list filter by label | reaper, attribution | no (`list` filters only `state`) | add `labels` (string map, caller-owned, distinct from the tenant tag the API adds) and `?label=k:v` on list; provider has `metadata` and a metadata filter |
| N5 | snapshot from VM: `POST /v1/vms/{id}/snapshots` with `displayName`, `ttlSeconds`, `autoDeleteSeconds`, labels, `Idempotency-Key`; works on running or paused VM; returns `snap_` id usable at once | warm bases, runner image bake | no | S3a; provider `snapshot_vm` supports all fields except labels |
| N6 | snapshots: get, list (by label, with `createdAt`, `lastUsedAt`, size), delete by exact id | registry, LRU, invalidation | no | S3a; provider has get/list/delete, `lastUsedAt`; size is not in the provider schema, so we track it ourselves |
| N7 | idle definition: what counts as activity for `idleTimeoutSeconds` (network only, per provider `lastNetworkActivity`?) and what happens at idle (pause or stop) | long CPU-bound steps | not documented | document it; if idle is network-based our heartbeat covers it |
| N8 | exec with exit code, env, stdin, `timeoutMs`, `linuxUser` (root and `runner`) | agent start, diagnostics | S2 red tests: `POST /v1/vms/{id}/exec` returns `{exitCode, stdout, stderr}`, `timeoutMs` <= 300000; no `linuxUser` or `stdin` in the tests | 501 until S2; add `linuxUser` and `stdin` |
| N9 | streaming exec: stdout and stderr as separate live streams, then exit code; no 300 s cap; detach and reattach by name | fallback log path when the agent socket is down, debugging a stuck job | no (S2 "streams" the buffered await body; terminal/PTY is S3a) | add an async exec (start returns `execId`; stream endpoint with stdout/stderr frames and final exit code), or expose the provider PTY with `exec` and `slug` (merges stdout and stderr). Not on the critical path because the agent pushes logs |
| N10 | files: write bytes (up to 64 MiB, mode), read with `Range`, stat | job spec, agent update, crash forensics | S2 red tests: files content GET/PUT with `Range`, entries | 501 until S2; add `mode` on write (agent binary needs 0755) |
| N11 | delete and pause by exact id | teardown | yes | 501 until S2 |
| N12 | egress firewall rules at create | later hardening | no | optional; provider has `firewall` |
| N13 | quota semantics: `QuotaExceeded` with `retryAfterSeconds` for the tenant VM cap; a tenant cap >= 20 running VMs | admission | `QuotaExceeded` exists | confirm the tenant quota for `manaflow-ai` is >= 20 plus snapshot capture overlap |
| N14 | fork and snapshot restore semantics: RNG reseed (VM generation ID), clock, machine id after restore | parallel forks of one snapshot | no | document provider behavior |
| N15 | API key for tenant `manaflow-ai` with `vm:read`, `vm:write`, `vm:exec`, `vm:files`, `snapshot:read`, `snapshot:write`; call through a Cloudflare service binding | JobDO auth | scopes exist (`vm:*`, `snapshot:*`) | service binding to `cmux-vm` (no public hop, no DNS); key issuance is an operator step |
| N16 | base image: create without `snapshotId` boots a documented Ubuntu 24.04 x86_64 image, or a public base snapshot id | baking the runner image | no `image` field; default image undocumented | document the default image and architecture, or accept `image` |
| N17 | VM state events or a cheap batch get (`GET /v1/vms?ids=`) | reaper and lease checks without N gets | no | optional; list with label filter (N4) is enough |
| N18 | `@cmux/vm` TypeScript SDK covering all of the above, usable inside a Worker | JobDO client | lifecycle verbs on `feat-cmux-vm-s4` 409ba9c2d6b4 | regenerate as S2/S3a land |
| N19 | network settings on create: IPv4 egress (on or off, if the provider has it), report `egressIpv4` and `egressIpv6` on get, a DNS resolver override, and attach to a network with routes (for a NAT64 prefix, option P3) | section 0 | no network or egress field on `CreateVmRequest` or `Vm` | add them; first answer whether provider IPv4 egress exists for our account |

`forkVm` (snapshot, create, delete snapshot) is not needed: we keep the
snapshot and create from it, which N1 plus N5 already give.

## 16. Trade-offs and decisions made for convenience

- T1 Agent in the VM instead of exec per step. Forced by the 300 s exec cap and
  buffered output. Cost: an agent we must version and bake into the image.
  TypeScript (shares the expression engine), not Rust; amendment 1's Rust rule
  covers the CLI, not this agent.
- T2 Shadow mode with an allowlist. Safe and comparable side by side, but every
  allowlisted job costs twice (GitHub plus us) during the experiment.
- T3 We keep `actions/checkout` semantics, so workspace build output is not kept
  by the VM snapshot, only by the local cache tier. A faster but non-standard
  option (preserve ignored build dirs across checkout) is rejected because it
  changes results relative to GitHub, which breaks "identical pass/fail".
- T5 No secrets in snapshots means any job that uses one of our secrets is
  always cold. Simple and safe; costs warmth for secret-using jobs.
- T6 GitHub App installation tokens (C3) instead of a PAT. Costs one manual
  registration click by an org owner; gains one-hour tokens scoped to one repo.
- T7 Commit statuses instead of check runs (A1). No annotations or logs in the
  GitHub UI.
- T9 Snapshot key uses blob SHAs from the Git tree, not `hashFiles` content
  hashes. Same invalidation power, zero content downloads; the digest does not
  equal any `hashFiles()` value, which nothing needs.
- T12 Slice 1 core (`src/expr`, `src/workflow`, `src/plan`) is plain TypeScript
  with no Effect dependency, so the in-VM agent can bundle it small and the
  same code evaluates expressions on both sides. Effect starts at the Worker
  and DO layer (slice 2), where Layers and typed errors pay off.

### Experiment-only (coordinator decision C5)
These choices are for the experiment and must be revisited before cmux Actions
serves anything beyond it:
- E1 Branch-scoped warm snapshots. A3 says warm bases come from green
  default-branch runs; the proof runs on a branch, so a branch may warm its own
  scope (section 8.2). Main stays protected.
- E2 One admin key (SHA-256 hash in Worker secrets) protects the admin API.
  Stack Auth team roles later.
- E3 Job `timeout-minutes` clamped to 60. A legitimately longer job fails here
  and passes on GitHub (recorded as a compat difference).
- E4 Unconfirmed sizes: the label map assumes Blacksmith's 4 GiB per vCPU; the
  proof records both machines' sizes.
- E5 Unconfirmed architecture: `RUNNER_ARCH=X64` assumes x86_64 cmux VMs (need
  N16).

## 17. Coordinator decisions (2026-10-07)

- C1 Webhook: approved for when the intake slice is ready, shadow mode only, HMAC
  secret piped from a file (never typed or printed). Ask the coordinator before
  creating it. Because C3 adds a GitHub App that subscribes to the same events,
  the intake uses the App webhook and no separate repo webhook is created
  (two webhooks would deliver every event twice); this still waits for the
  coordinator's go.
- C2 Approved: R2 bucket `cmux-actions` and DOs with SQLite. Conditions: an R2
  lifecycle rule deletes objects after 14 days, logs and artifacts are
  size-capped per run, and the run page shows a daily cost line (section 12).
  Nothing is created in slice 1.
- C3 A GitHub App, not a PAT; installation tokens also serve as `github.token`.
  The manifest and the registration flow are in the repo (section 19). Lawrence
  registers it once as org owner when slice 2 needs it. Agents do not create it.
- C4 N14 is a security requirement (section 8.7), tested in slice 2.
- C5 Convenience choices are listed under "Experiment-only" (section 16).
- C6 License `GPL-3.0-or-later`. Run page and logs: manaflow team session only.
- C7 The 39-character `upload-artifact` pin in `ci.yml` is fixed by the
  coordinator, not here.
- Still open: a cmux VM API key for tenant `manaflow-ai` (N15) and the 20-VM
  quota (N13).

## 18. Slices

1. Workflow model and expression engine: parser, expressions, matrix, needs,
   `if`, reusable workflows, composite actions, static classifier. Fixture tests
   load every file in `.github/workflows` and `.github/actions` and compare the
   planned job graph to checked-in expectations. Red first. No deploy.
2. Protocol servers against the pinned toolkits (cache v2, artifacts) on
   miniflare with R2 bindings; agent with a local fake VM (a container in CI).
3. DOs, cmux VM client, runner image bake, proof: `cmux-tui.yml` lint and test
   (linux) cold, warm, warm, versus Blacksmith on time and result. Then the
   compatibility table for every Linux job.

## 19. GitHub App registration (C3)

`github-app/manifest.json` is the App manifest: name "cmux Actions
(experiment)", private, permissions `statuses: write`, `contents: read`,
`metadata: read`, `checks: write` (optional, for later annotations), events
`push`, `pull_request`, `workflow_dispatch`. The webhook is created inactive
(`hook_attributes.active: false`) because no Worker host exists yet; it is
activated only after C1's go.

Manifest flow: GitHub accepts the manifest as a form POST to
`https://github.com/organizations/manaflow-ai/settings/apps/new?state=<random>`.
`github-app/register.mjs` (Node, no dependencies) does the whole flow from a
trusted checkout: it serves an auto-submitting form on `127.0.0.1`, receives
GitHub's redirect with the one-time `code`, exchanges it at
`POST /app-manifests/{code}/conversions`, writes the response (App id, private
key, webhook secret, client secret) to
`~/.secrets/cmux-actions-github-app.json` with mode 0600, and prints only the
App id, slug and the installation URL. Install it on `manaflow-ai/cmux` only
("Only select repositories"); the manifest cannot restrict that. Not run yet.
