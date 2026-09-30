# iOS E2E gate

The gate runs a real Mac app and a fresh iOS simulator against a fresh backend
for the same GitHub Actions run. The backend job owns Postgres, Next.js, and the
local `iroh-v2` and `presence` Workers, then publishes them with Tailscale
Serve. The macOS job builds both apps, signs them into the CI Stack account,
pairs them, forces relay-only Iroh transport, and runs the six terminal steps.

```
route (Linux)
   +--> backend (Linux, per-run Postgres + web + Workers, Tailscale Serve)
   +--> mac-ios-e2e (macOS, Mac app + iOS simulator)
             |             |
             +-- HTTPS/API-+
             +-- Iroh relay-only terminal path
```

The Mac app and simulator share one macOS runner. Their terminal traffic is
still forced through managed Iroh relays. The backend is isolated per run and
is released when the iOS job touches its done-file over Tailscale SSH.

## Job graph

| Job | Runner | Timeout | Does |
| --- | --- | --- | --- |
| `route` | Linux | 5m | Selects the shadow lane and per-run tag. Fork dispatches become a deterministic skip. |
| `backend` | Linux | 60m | Starts Postgres, web, `iroh-v2`, and `presence`; publishes HTTPS endpoints and holds until teardown. |
| `mac-ios-e2e` | macOS | 120m | Builds both apps, boots an isolated simulator, signs in, pairs, verifies relay-only defaults, runs E2E, and signals teardown. |
| `ios-e2e-status` | Linux | 5m | Always-run aggregate for branch protection. |

The workflow currently has only `workflow_dispatch`. Promote the
`pull_request` trigger after one complete relay-only run and stable
infrastructure results.

## Per-run backend

`scripts/e2e/backend-up.sh` runs on the Linux backend runner. It creates a
fresh Postgres container, applies web and `iroh-v2` ownership migrations,
starts Next.js and both Workers in local workerd, and publishes these private
origins through Tailscale Serve:

- `https://<run>.tail137216.ts.net` — web and sign-in/pairing API
- `https://<run>.tail137216.ts.net:8443` — `iroh-v2`
- `https://<run>.tail137216.ts.net:10000` — presence

`scripts/e2e/backend-env.sh` emits the matching app environment and waits on
all three health endpoints. Backend state and databases disappear with the
runner. No GCP VM, persistent dev-backend tag, or VM SSH key is involved.

The backend job uses a web build cache keyed by the `web/` tree and the managed
relay catalog. A cache miss builds the exact checkout before the backend starts.

## Secrets

| Secret | Job | Purpose |
| --- | --- | --- |
| `TS_OAUTH_CLIENT_ID` / `TS_OAUTH_SECRET` | backend, mac-ios-e2e | Join the backend as `tag:e2e-backend` and the macOS runner as `tag:ci`. The `tag:ci` owner is authorized to mint the per-run backend role. |
| `CMUXTERM_DEV_ENV_B64` | backend | Existing 0600 dev bundle. The workflow maps its Stack and relay variables to the `backend-up.sh` interface without writing them to GitHub outputs or command arguments. |
| `CMUX_DOGFOOD_STACK_EMAIL` / `CMUX_DOGFOOD_STACK_PASSWORD` | mac-ios-e2e | Dedicated CI Stack account used by both app endpoints. |

The backend bundle must contain `STACK_PROJECT_ID` (or
`NEXT_PUBLIC_STACK_PROJECT_ID`), `STACK_PUBLISHABLE_KEY` (or
`NEXT_PUBLIC_STACK_PUBLISHABLE_CLIENT_KEY`), `STACK_SERVER_KEY` (or
`STACK_SECRET_SERVER_KEY`), `RELAY_SIGNING_KEY`, and `RELAY_KEY_ID`.

## Tailscale ACL requirements

The backend joins as `tag:e2e-backend`; the macOS runner joins as `tag:ci`.
Both use deterministic hostnames derived from `github.run_id` and
`github.run_attempt`. The ACL must allow `tag:ci` to `tag:e2e-backend` for:

- TCP 22, with Tailscale SSH mapping to the runner user used by the teardown
  step (`runner` in the workflow).
- TCP 443, 8443, and 10000 for the backend Serve endpoints. The existing ACL
  already covers 8443 and 10000; add 443 for the web/sign-in endpoint.

Do not allow arbitrary UDP or broad runner-to-runner access. Relay-only mode is
what makes this a transport test rather than a direct Tailscale path.

## Failure classification

Tailnet join, missing runner tools, backend startup/health, simulator boot, and
teardown failures print `[infra-preflight]`. A streamed-terminal failure ends
with `E2E FAIL step=<id>` and is a product-path result. Evidence and backend
logs are uploaded for seven days.

## Promotion plan

1. Run the workflow manually on the owner repository and verify backend health,
   relay-only defaults, and one complete six-step pass.
2. Confirm the `tag:ci` ACL and runner SSH username from the teardown logs.
3. Integrate `scripts/ci/detect_ci_change_areas.py` into `route` so unrelated
   changes skip the expensive macOS job.
4. Enable `pull_request` and require `ios-e2e-status` after the lane is stable.
