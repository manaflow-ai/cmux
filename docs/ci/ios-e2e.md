# iOS E2E gate

[.github/workflows/ios-e2e.yml](../../.github/workflows/ios-e2e.yml) proves
the whole Mac-to-iPhone product path on a pull request: a real Mac app on one
runner, a real iOS simulator app on another, the dev web backend on the
durable tailnet VM, then sign-in → pairing → an Iroh connection → a scripted
streamed terminal session. The per-step driver contract and the regression
each step covers live in [scripts/e2e/README.md](../../scripts/e2e/README.md).

## Topology

```
                        GitHub Actions run
  ┌─────────────────────────────────────────────────────────────┐
  │  route (Linux)ci──▶ backend (Linux)ci──────────────┐        │
  │                        │ ensure stack ci<PR#>/ci-main       │
  │                        ▼                            ▼       │
  │            ┌── mac-host (macOS) ──┐    ┌── ios-e2e (macOS) ─┐
  │            │ tagged cmux DEV app  │    │ fresh named sim    │
  │            │ signed-in, advertised│    │ sign-in, pair      │
  │            │ waits on done-file   │    │ 6-step terminal    │
  │            └───────▲──────────────┘    └──────┬─────────────┘
  └────────────────────│───────────────────────── │─────────────┘
                       │ (2) touch done-file      │
                       │  Tailscale SSH, port 22  │
        tailnet        │  tag:ci -> tag:ci        │
  ─────────────────────┴──────────────┬───────────┴──────────────
                                      │ (1) HTTPS web API: sign-in,
                                      ▼     pairing ticket, advertise
                    cmux-dev-backend-1.tail137216.ts.net
                    (per-tag web + Postgres Docker stacks)

          iOS ⇄ Mac terminal data itself flows over IROH
          (relay or direct), never over the tailnet — the
          ACL below makes the shortcut impossible.
```

## Job graph

| Job | Runner | Timeout | Does |
| --- | --- | --- | --- |
| `route` | Linux (`blacksmith-4vcpu-ubuntu-2404`) | 5m | Sets `run_e2e=true` for manual dispatch; pull-request runs are skipped, with a backend tag selected for dispatch. |
| `tailnet-preflight` | Linux | 5m | Optional manual connectivity check: GitHub identity authentication, backend SSH as `ubuntu`, and an existing Serve HTTPS URL. Skips app jobs. |
| `backend` | Linux | 10m | Joins the tailnet (`tailscale/github-action@v4`, tag:ci), pings the backend host, ensures the tagged stack (stub; real call is cmuxterm-hq `scripts/dev-backend.sh url --tag <tag>` over SSH). |
| `mac-host` | macOS (`MACOS_RUNNER_PR` or `blacksmith-6vcpu-macos-26`) | 45m | Downloads the prebuilt Mac app (reuse pending), joins the tailnet under the deterministic name `cmux-e2e-mac-<run_id>`, launches signed into the CI Stack account, advertises through the backend, waits on `/tmp/e2e-done-<run_id>` (bounded ~25m). |
| `ios-e2e` | macOS (`MACOS_RUNNER_IOS` fallback chain) | 45m | Downloads the sim app product (pending), boots a fresh per-run simulator, runs `scripts/e2e/ios-e2e-run.sh`, then ALWAYS signals the Mac's done-file over Tailscale SSH, uploads evidence, deletes the sim. |
| `ios-e2e-status` | Linux | 5m | `if: always()` aggregate; the only check to require. |

`mac-host` and `ios-e2e` both need only `backend` and run in parallel: the
sim's sign-in/pair sequence retries until the Mac is advertised, so
serializing them would just add queue time.

Teardown is a local done-file touched over Tailscale SSH, never GitHub API
polling from the Mac's wait loop: a ~25-minute per-PR status poll would draw
down the repo-wide API rate limit every workflow shares, and the file needs
no token on the Mac.

`ios-e2e-status` semantics: green when the route skipped the lane or every
needed job passed; red when the route said run and any needed job failed, was
cancelled, or was skipped unexpectedly; neutral-skip green on fork PRs (the
secret-fenced jobs cannot run there). It writes the route decision and each
job's result to the step summary.

## Authentication

Tailscale uses GitHub workload identity federation. Repository variables
`TS_OIDC_CLIENT_ID` and `TS_OIDC_AUDIENCE` contain non-secret configuration.
Only jobs joining the tailnet receive `id-token: write`. No Tailscale OAuth
secret or backend SSH private key is required.

The federated credential has only `auth_keys` Write and `tag:ci`. Restrict
its issuer to `https://token.actions.githubusercontent.com`, subject to
`repo:manaflow-ai/cmux:ref:refs/heads/main`, and custom claims to:

```json
{
  "repository_id": "1144115288",
  "repository_owner_id": "171392238",
  "workflow_ref": "manaflow-ai/cmux/.github/workflows/ios-e2e.yml@refs/heads/main",
  "event_name": "workflow_dispatch"
}
```

This permits the current manual-only lane on `main`. PR automation needs a
separately reviewed trust policy before promotion. To validate a migration
before merge, temporarily restrict the credential to the exact test branch
and `workflow_sha`, then restore the main-only trust after the run.

Dispatch `ios-e2e.yml` with `connectivity_only=true` and `backend_probe_url`
set to an existing, running dev-backend Serve origin including its port.
This checks authentication, SSH access to the backend control service, and
HTTP 200 from the HTTPS origin without modifying backend stacks or starting
app jobs. The aggregate labels this as connectivity verification, not an
app E2E pass.

### App secrets

| Secret | Jobs | Purpose |
| --- | --- | --- |
| `CMUX_DOGFOOD_STACK_EMAIL` / `CMUX_DOGFOOD_STACK_PASSWORD` | mac-host, ios-e2e | Dedicated CI Stack account, same pair as ios-streamed-validate.yml; both ends must resolve one account for pairing's same-account RPC gate. |

Secrets travel only through step environments, never argv, never echoed.
Every secret-mounting job is fenced with
`github.event.pull_request.head.repo.full_name == github.repository`, because
a fork PR controls the workflow file's own content; the aggregate reports
forks as a neutral skip instead of a red.

## Tailscale ACL requirements

- `tag:ci` → `tag:dev-backend` on 3800-4799 (Tailscale Serve web API for
  sign-in/pairing/advertise) and 22 (dev-backend control SSH). The SSH policy
  permits only `ubuntu`. Tailscale SSH owns tailnet port 22 on this host,
  so an OpenSSH private key does not authenticate this connection.
- `tag:ci` → `tag:ci` on port 22 ONLY (Tailscale SSH, for the done-file
  signal), with an SSH rule permitting only `runner`. The Mac host enables
  the Tailscale SSH server using `--ssh`.

The narrowness of the second rule is load-bearing: if runners could reach
each other on arbitrary ports, Iroh's path probing could discover the
runners' Tailscale IPs and carry the terminal stream host-to-host over the
tailnet. The run would go green while testing a transport path no customer
has, which is exactly the false confidence this lane exists to eliminate.
Port 22 alone is useless to Iroh and sufficient for one `touch`.

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

1. **Shadow.** The workflow runs on manual dispatch while pull-request runs are skipped, and
   on dispatch. Expected red until the TODOs land, in this order: real
   router via `scripts/ci/detect_ci_change_areas.py`; backend ensure with
   Tailscale SSH as `ubuntu`; Mac app product reuse
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
appearance releases the Mac host's bounded wait, our GitHub-API-free
teardown handshake; **infra-preflight** — a labeled failure in environment
setup (tailnet, cache, backend, simulator) as opposed to the product path
under test.
