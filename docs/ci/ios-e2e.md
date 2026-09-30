# iOS E2E gate

[.github/workflows/ios-e2e.yml](../../.github/workflows/ios-e2e.yml) proves
the whole Mac-to-iPhone product path on a pull request: a real Mac app on one
runner, a real iOS simulator app on another, a fresh backend on a third
(Linux) runner, then sign-in → pairing → an Iroh connection → a scripted
streamed terminal session. The per-step driver contract and the regression
each step covers live in [scripts/e2e/README.md](../../scripts/e2e/README.md).

## Topology

```
                        GitHub Actions run
  ┌─────────────────────────────────────────────────────────────────┐
  │  route (Linux) ──┬──────────────────┬────────────────────┐      │
  │                  ▼                  ▼                    ▼      │
  │  ┌─ backend (Linux) ─┐  ┌─ mac-host (macOS) ─┐  ┌─ ios-e2e (macOS) ─┐
  │  │ Postgres, web/,   │  │ tagged cmux DEV    │  │ fresh named sim   │
  │  │ iroh-v2 + presence│  │ signed in,         │  │ sign-in, pair,    │
  │  │ Workers (DOs) in  │  │ advertised,        │  │ 6-step terminal   │
  │  │ local workerd     │  │ waits on done-file │  │                   │
  │  │ waits on done-file│  └────────▲───────────┘  └───┬───────────┬───┘
  │  └──▲───────▲────────┘           │ (2) touch        │           │
  └─────│───────│────────────────────│─ done-files ─────┘           │
        │       │ (2) touch          │  Tailscale SSH :22           │
 tailnet│       └────────────────────┴──────────────────────────────┤
        │ (1) HTTPS via Tailscale Serve: :443 web, :8443 iroh-v2,   │
        └─────────  :10000 presence (health, tickets, register, ────┘
                    directory/advertise, relay credentials)

          iOS ⇄ Mac terminal data itself flows over IROH through the
          managed relays, never over the tailnet — the ACL below
          makes the shortcut impossible. Stack Auth and the relays
          are the only shared services.
```

## Job graph

| Job | Runner | Timeout | Does |
| --- | --- | --- | --- |
| `route` | Linux (`blacksmith-4vcpu-ubuntu-2404`) | 5m | Decides `run_e2e` (stub: always true, `detect_ci_change_areas.py` integration pending) and `run_clients` (false for a `backend_only` dispatch). |
| `backend` | Linux (`blacksmith-8vcpu-ubuntu-2404`) | 60m | Joins the tailnet as `cmux-e2e-backend-<run_id>-<attempt>`, runs `scripts/e2e/backend-up.sh up` (see [Per-run backend](#per-run-backend)), then holds on `/tmp/e2e-backend-done-<run_id>-<attempt>` (bounded 45m) and uploads its logs. |
| `mac-host` | macOS (`MACOS_RUNNER_PR` or `blacksmith-6vcpu-macos-26`) | 45m | Downloads the prebuilt Mac app (reuse pending), joins the tailnet as `cmux-e2e-mac-<run_id>-<attempt>`, waits for the backend's health endpoints, execs the app with the per-run origins, signs into the CI Stack account, advertises, waits on `/tmp/e2e-done-<run_id>-<attempt>` (bounded ~25m). |
| `ios-e2e` | macOS (`MACOS_RUNNER_IOS` fallback chain) | 45m | Downloads the sim app product (pending), waits for the backend, boots a fresh per-run simulator, runs `scripts/e2e/ios-e2e-run.sh`, then ALWAYS signals both holders' done-files over Tailscale SSH, uploads evidence, deletes the sim. |
| `ios-e2e-status` | Linux | 5m | `if: always()` aggregate; the only check to require. |

All three runners start in parallel after `route`. The macOS jobs cannot
`needs: backend`, because the backend job stays alive until the iOS job
finishes; they poll its health endpoints instead
(`scripts/e2e/backend-env.sh wait`). Every job addresses the others by a
tailnet name derived from `run_id` and `run_attempt`, because job outputs
only publish when the producing job completes.

Teardown is a local done-file per holder touched over Tailscale SSH, never
GitHub API polling from a wait loop: a ~25-minute per-PR status poll would
draw down the repo-wide API rate limit every workflow shares, and the file
needs no token on the holder.

## Per-run backend

Each run gets its own backend on a Blacksmith Linux runner
([scripts/e2e/backend-up.sh](../../scripts/e2e/backend-up.sh)), instead of a
stack on the shared dev VM. Nothing is shared with other runs, agent dogfood
stacks, or staging except Stack Auth (the CI account in the dev project) and
the managed relays.

| Service | Why the path needs it | Origin |
| --- | --- | --- |
| `workers/iroh-v2` (`TeamControl`, `UserUsage` Durable Objects) | API tickets, challenges, device registration, directory/advertise, relay credentials | `https://<backend>:8443` |
| `workers/presence` (`TeamPresence`, `AccountControlPlane`, `WorkspacePresence`) | Heartbeat, subscribe, reply relay | `https://<backend>:10000` |
| `web/` (Next.js, `next start`) | Device registry, push, legacy broker, general API | `https://<backend>` |
| Postgres 16 | web's database (`drizzle-kit migrate`) and iroh-v2's ownership tables (`workers/iroh-v2/ownership-drizzle`) | runner-local |

Both Workers run in local workerd via `wrangler dev`, so their Durable
Object state starts empty every run and nothing is deployed to Cloudflare.
Tailscale Serve publishes the three origins with the runner's public
`ts.net` certificate; the apps accept only https origins. iroh-v2 connects to
Postgres with verified TLS, so Postgres serves the same `tailscale cert`
certificate on the runner's own tailnet address (port 5432 is not in the
ACL). API ticket keys are generated per run.

The apps reach these origins through
[scripts/e2e/backend-env.sh](../../scripts/e2e/backend-env.sh) `env`:
`CMUX_IROH_V2_BASE_URL`, `CMUX_IROH_V2_ENVIRONMENT=development`,
`CMUX_IROH_V2_FORCE_RELAY=1`, `CMUX_PRESENCE_BASE_URL`, and the web origins
(`CMUX_API_BASE_URL`, `CMUX_DEVICE_REGISTRY_API_BASE_URL`,
`CMUX_PUSH_API_BASE_URL`, `CMUX_IROH_BROKER_BASE_URL`, ...). The Mac reads
them only because `mac-host.sh` execs the binary: `open` would apply the
LSEnvironment that `reload.sh` bakes with staging origins. iOS reads the v2
and presence origins from `SIMCTL_CHILD_*` at launch; its general API origin
is Info.plist-only (`CMUXApiBaseURL`), so the sim product step must stamp it.

Caching, so a warm bring-up is dominated by process start, not builds:

- **node_modules** for web, iroh-v2, and presence live on Blacksmith sticky
  disks (`useblacksmith/stickydisk`), so `bun install --frozen-lockfile` only
  applies the lockfile delta.
- **The web build** is cached with `actions/cache` (Blacksmith-backed on
  these runners) under the git tree SHA of `web/` plus the relay catalog it
  checks. An exact hit restores the finished `.next` and skips `next build`;
  a partial hit restores `.next/cache` so the rebuild is incremental. The
  save happens before the hold, so a run still serving already warms the
  next one. The key has a `v1` prefix to bump when the CI Stack project
  changes, since `NEXT_PUBLIC_*` values are baked into the build.
- The Workers need no build step: `wrangler dev` bundles them at start.

A `backend_only` dispatch brings the backend up, proves all three published
origins over TLS, saves the cache, and stops without the macOS jobs:

```bash
gh workflow run ios-e2e.yml --repo manaflow-ai/cmux --ref <branch> -f backend_only=true
```

`ios-e2e-status` semantics: green when the route skipped the lane or every
needed job passed; red when the route said run and any needed job failed, was
cancelled, or was skipped unexpectedly; neutral-skip green on fork PRs (the
secret-fenced jobs cannot run there). It writes the route decision and each
job's result to the step summary.

## Secrets

| Secret | Jobs | Purpose |
| --- | --- | --- |
| `TS_OAUTH_CLIENT_ID` / `TS_OAUTH_SECRET` | backend, mac-host, ios-e2e | Tailnet OAuth join, tag:ci. |
| `CMUX_DOGFOOD_STACK_EMAIL` / `CMUX_DOGFOOD_STACK_PASSWORD` | mac-host, ios-e2e | Dedicated CI Stack account, same pair as ios-streamed-validate.yml; both ends must resolve one account for pairing's same-account RPC gate. |
| `CMUX_E2E_STACK_PROJECT_ID` / `CMUX_E2E_STACK_PUBLISHABLE_KEY` / `CMUX_E2E_STACK_SERVER_KEY` | backend | The dev Stack project that owns the CI account. iroh-v2, presence, and web verify the apps' tokens against it. |
| `CMUX_E2E_RELAY_SIGNING_KEY` / `CMUX_E2E_RELAY_KEY_ID` | backend | The development iroh-v2 relay EdDSA key (PEM) and key id. The managed relays accept only keys they were configured with, so a per-run key would break every relay-only run. |

Secrets travel only through step environments, never argv, never echoed.
Every secret-mounting job is fenced with
`github.event.pull_request.head.repo.full_name == github.repository`, because
a fork PR controls the workflow file's own content; the aggregate reports
forks as a neutral skip instead of a red.

## Tailscale ACL requirements

- `tag:ci` → `tag:ci` on TCP 22 (Tailscale SSH, for the done-file signals),
  with an SSH rule mapping to the runner login user.
- `tag:ci` → `tag:ci` on TCP 443, 8443 and 10000 (the backend's Tailscale
  Serve origins).

The narrowness of these rules is load-bearing: if runners could reach each
other on arbitrary ports or on UDP, Iroh's path probing could discover the
runners' Tailscale IPs and carry the terminal stream host-to-host over the
tailnet. The run would go green while testing a transport path no customer
has, which is exactly the false confidence this lane exists to eliminate.
Iroh's direct and relay paths are QUIC over UDP, so four TCP ports are
useless to it. The CI jobs need no access to the shared dev VM.

## Infra-preflight failure labeling

Steps that can only fail for infrastructure reasons — tailnet join, backend
ping/ensure, product downloads, simulator boot, the teardown signal — emit
errors prefixed `[infra-preflight]`. Triage rule: an `[infra-preflight]` red
is a fleet/ACL/cache problem for CI infra, never a product regression, and it
does not count against the lane's flake budget during shadow. A red with no
`[infra-preflight]` marker is the E2E itself and gets a
`E2E FAIL step=<id>` line naming the failed step
(see [scripts/e2e/README.md](../../scripts/e2e/README.md)).

## Promotion plan

1. **Shadow.** The workflow runs on every PR (route-gated, not required) and
   on dispatch. Expected red until the TODOs land, in this order: real
   router via `scripts/ci/detect_ci_change_areas.py`; the per-run backend
   secrets and ACL rules above; Mac app product reuse
   (`scripts/ci/reuse_app_host_products.py` consumer path); iOS sim product
   reuse (test-ios.yml's `ios-test-product-*` artifact); the two driver
   scripts. During shadow, track pass rate and `[infra-preflight]` rate
   separately.
2. **Required inside the ios aggregate.** Once the lane holds a stable pass
   rate with infra-preflight reds at fleet-noise level, `ios-e2e-status`
   joins the required iOS aggregate check rather than becoming its own
   branch-protection entry, keeping one required conclusion per area. The
   neutral-skip semantics (route skip, fork PRs) already match what a
   required check needs.

Dictionary: **aggregate** — the single always-run job whose conclusion
branch protection requires on behalf of a lane's many conditional jobs;
**shadow** — running a check on every PR without requiring it, to measure
reliability before it can block merges; **done-file** — the local file whose
appearance releases a holder's (Mac host or backend) bounded wait, our GitHub-API-free
teardown handshake; **infra-preflight** — a labeled failure in environment
setup (tailnet, cache, backend, simulator) as opposed to the product path
under test.
