# iOS E2E gate

[.github/workflows/ios-e2e.yml](../../.github/workflows/ios-e2e.yml) builds the
Mac app and iOS simulator app on one macOS runner while a Blacksmith Linux
runner serves a fresh per-run backend. The apps sign into the CI Stack account,
pair, are forced to Iroh relay-only transport through the per-run relay, and
run the six-step streamed-terminal driver in
[scripts/e2e/README.md](../../scripts/e2e/README.md).

## Topology

```
                      GitHub Actions run (environment ios-e2e, OIDC)
  route (Linux) --+---------------------------------+
                  |                                 |
     backend (Linux, tag:e2e-backend)     mac-ios-e2e (macOS, tag:ci)
     iroh-v2 + presence (workerd),        builds Mac + iOS apps,
     Postgres, iroh-relay                 fresh simulator, 6 steps
                  ^                                 |
                  +-- HTTPS :8443 iroh-v2 ----------+
                  +-- HTTPS :8444 presence ---------+
                  +-- HTTPS :10000 relay (terminal) +
                  +-- SSH :22 as runner (release) --+
```

The Mac and simulator share the runner's operating system. Their terminal
traffic is forced relay-only, so it rides the per-run relay and local
networking cannot turn this into a direct-path test.

## Job graph

| Job | Runner | Timeout | Does |
| --- | --- | --- | --- |
| `route` | Linux | 5m | Chooses `run_e2e`, `run_clients` (false for a `backend_only` dispatch) and the app tag. |
| `backend` | Linux (`LINUX_RUNNER`) | 150m | Starts the per-run backend ([Per-run backend](#per-run-backend)), then holds until the macOS job releases it. |
| `mac-ios-e2e` | macOS (`MACOS_RUNNER_IOS`, then `MACOS_RUNNER_PR`) | 120m | Builds both apps with the backend's origins baked in, waits for the backend, boots an isolated simulator, signs in, pairs, verifies relay-only defaults, runs the six steps, uploads evidence, and releases the backend. |
| `ios-e2e-status` | Linux | 5m | Always-run aggregate that reports the routed conclusion. |

`backend` and `mac-ios-e2e` start together after `route`. The macOS job does
not `needs: backend`, because the backend must stay alive for it; it polls the
backend's health endpoints right before sign-in, by which time the app builds
have hidden the backend's start-up. The workflow has only a `workflow_dispatch`
trigger until the owner approves promotion.

## Per-run backend

[scripts/e2e/backend-up.sh](../../scripts/e2e/backend-up.sh) runs only the
services on the path under test:

| Service | Why the path needs it | Origin |
| --- | --- | --- |
| `workers/iroh-v2` (`TeamControl`, `UserUsage` Durable Objects) | API tickets, challenges, device registration, directory/advertise, relay credentials | `https://<name>:8443` |
| `workers/presence` (`TeamPresence`, `AccountControlPlane`, `WorkspacePresence`) | Heartbeat, subscribe, reply relay | `https://<name>:8444` |
| `iroh-relay` 1.0.2 (n0 release, SHA-256 pinned) | The relay-only terminal path | `https://<name>:10000` |
| Postgres 16 | iroh-v2's endpoint ownership tables | runner-local |

Nothing is built. Both Workers run in local workerd (`wrangler dev`), so their
Durable Object state starts empty every run and nothing is deployed to
Cloudflare. Nothing is reachable from the internet: the services listen on
loopback, and a TLS front listens only on the runner's tailnet address.

### TLS

Every origin's host is one fixed name, `cmux-e2e-backend.tail137216.ts.net`
(`<name>` above). The apps accept only `https` origins, and the iOS Iroh
client checks relay TLS against built-in public roots (`iroh-ffi`
`src/relay_tls.rs`), so a private CA cannot serve the relay. A Tailscale
certificate for each run's own hostname took 37 s per run and would exhaust
Let's Encrypt's 50 new certificates per week for the tailnet domain (`ts.net`
is on the Public Suffix List).

So the name's publicly trusted certificate is issued once, about every 60
days, and stored in the `ios-e2e` environment as `CMUX_E2E_TLS_CERT` and
`CMUX_E2E_TLS_KEY`. No tailnet node keeps the name. The macOS runner maps it in
`/etc/hosts` to this run's backend runner (`backend-env.sh hosts`); the
simulator shares that resolver. The backend maps it to loopback for Postgres.
[scripts/e2e/tls-forward.mjs](../../scripts/e2e/tls-forward.mjs) terminates TLS
and forwards bytes, so WebSockets and the relay protocol pass through
unchanged. Postgres serves the same certificate, so iroh-v2's verified-TLS
connection needs no test-only switch in product code.

### Renewing the backend certificate

`backend-up.sh` warns when the certificate has fewer than 21 days left and
fails the run at 7. Renew from a cmuxterm-hq checkout with tsadmin access:

```bash
./scripts/ios-e2e-backend-cert.sh
```

It creates the `cmux-e2e-backend` node for a moment with a one-use,
ephemeral, 10-minute `tag:e2e-backend` key, runs `tailscale cert`, stores the
result in the environment, and always revokes the key, logs the node out,
stops its daemon and deletes its temp directory.

The relay is the upstream server that `manaflow-ai/cmux-relay` wraps, without
cmux-relay's credential check (that repository tests it). iroh-v2 signs relay
credentials with a key minted for the run, so no production relay key reaches
CI and relay key rotation cannot break the lane. The real relay fleet is not
exercised here.

`web/` is not started. Sign-in goes to Stack Auth directly and the Mac mints
the attach URL locally. The apps' web side paths (device registry, push, What's
New, the Mac compatibility policy, the legacy broker for older iOS clients) use
shared staging through `CMUX_DEV_BACKEND_MODE=local` and
`CMUX_DEV_API_BASE_URL`.

[scripts/e2e/backend-env.sh](../../scripts/e2e/backend-env.sh) `env` sets
`CMUX_IROH_V2_BASE_URL`, `CMUX_IROH_V2_ENVIRONMENT`, `CMUX_IROH_V2_FORCE_RELAY`
and `CMUX_PRESENCE_BASE_URL`; the reload scripts bake them into both apps, and
the Mac's presence origin is also written to its `presenceServiceURL` default.

Speed: sparse checkout of the three paths the backend runs; no certificate
issuance and no Tailscale Serve; Bun's package
cache restored with `actions/cache` (Blacksmith-backed); both installs and the
Postgres image pull run in parallel; the relay tarball is cached; Postgres runs
without fsync; both Workers, the relay and Postgres start concurrently and each
readiness poll ticks every 200 ms. The step summary of `Start per-run backend`
lists every phase's time since start.

Cache safety: the backend job holds the Stack server key, so it never runs
code from a cache another branch could write. Blacksmith sticky disks are not
used because their keys are repository-wide. `actions/cache` entries are
branch-scoped (a run reads its own ref's and the default branch's), `bun
install --frozen-lockfile` checks packages against the lockfile's integrity
hashes, and the relay tarball's SHA-256 is verified on every run, cache hit or
not.

```bash
gh workflow run ios-e2e.yml --repo manaflow-ai/cmux --ref <branch> -f backend_only=true
```

## Secrets and tailnet identity

Only `workflow_dispatch` runs the lane, which needs write access. Both jobs
that join the tailnet or read a secret run in the GitHub environment
`ios-e2e`; its deployment branch policy is the allow-list of branches that may
run it.

No stored Tailscale secret is used. Jobs join with GitHub OIDC against the
federated identity "cmux iOS E2E protected manual runs", which trusts only
this repository, `.github/workflows/ios-e2e.yml`, `workflow_dispatch`, and the
`ios-e2e` environment. It has the `auth_keys` scope and `tag:ci`, which owns
`tag:e2e-backend`. The workflow reads its client ID and audience from the
repository variables `TS_E2E_OIDC_CLIENT_ID` and `TS_E2E_OIDC_AUDIENCE`.

| Secret | Scope | Job | Purpose |
| --- | --- | --- | --- |
| `CMUX_E2E_STACK_PROJECT_ID` / `CMUX_E2E_STACK_PUBLISHABLE_KEY` / `CMUX_E2E_STACK_SERVER_KEY` | environment `ios-e2e` | `backend` | The dev Stack project of the CI account; the Workers verify the apps' tokens against it. |
| `CMUX_E2E_TLS_CERT` / `CMUX_E2E_TLS_KEY` | environment `ios-e2e` | `backend` | Certificate chain and key for the backend's fixed name ([TLS](#tls)). Its key can only impersonate that name, which no real service uses. |
| `CMUX_DOGFOOD_STACK_EMAIL` / `CMUX_DOGFOOD_STACK_PASSWORD` | repository | `mac-ios-e2e` | The CI Stack account both apps sign into. |

## Tailscale ACL requirements

The policy is cmuxterm-hq `skills/infra/tsadmin/acl.manaflow.hujson`, with a
policy test for each rule:

- `tag:ci` to `tag:e2e-backend` on TCP 8443, 8444 and 10000. The relay has no
  authentication of its own, so this rule is its access control. Postgres and
  the local Worker and relay ports stay closed.
- `tag:ci` to `tag:e2e-backend` on TCP 22, with Tailscale SSH for `runner`
  only, to release the backend's hold. The backend fails early unless it runs
  as `runner`, and it cannot SSH anywhere.
- No access to the shared dev VM is needed.

The relay-only setting is enforced in both app configurations:

- Mac defaults: `cmux.iroh.debug.transport-mode=relayOnly` and
  `cmux.iroh.v2.force-relay=true`.
- iOS simulator defaults: `cmux.iroh.debug.transport-mode=relayOnly` and
  `cmux.iroh.v2.config.CMUX_IROH_V2_FORCE_RELAY=1`.

The workflow reads both values back before pairing and after launch. The E2E
driver also asserts the tagged Mac socket and simulator rendering for every
terminal step.

## Infra-preflight failure labeling

Tailnet join, backend start-up, backend serving, missing runner tools,
simulator boot, and cleanup failures emit `[infra-preflight]` when the failure
is outside the product path. A driver failure ends with `E2E FAIL step=<id>`
and is treated as a product-path result. Evidence is uploaded with seven-day
retention on every run.

## Promotion plan

1. Run the workflow manually with the final ACL and confirm one complete
   relay-only pass, including the uploaded evidence artifact.
2. Integrate `scripts/ci/detect_ci_change_areas.py` into `route` so unrelated
   changes skip the expensive Mac job while `ios-e2e-status` still concludes.
3. Enable the `pull_request` trigger and require `ios-e2e-status` after the
   lane has a stable pass rate and infrastructure failures are understood.

Dictionary: **Tailscale SSH** means SSH authorization supplied by the
Tailscale ACL and node identity instead of a private key; **TLS front** means
the process that holds the certificate and forwards decrypted bytes to a
loopback service; **OIDC
identity** means a Tailscale credential GitHub proves with a short-lived
signed token, so no long-lived secret is stored; **relay-only**
means Iroh is prevented from selecting a direct peer path; **aggregate** means
the one always-run check that represents conditional jobs; **shadow** means a
check runs for measurement before branch protection requires it.
