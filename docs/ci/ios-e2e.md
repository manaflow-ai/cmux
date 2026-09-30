# iOS E2E gate

[.github/workflows/ios-e2e.yml](../../.github/workflows/ios-e2e.yml) builds the
Mac app and iOS simulator app on one macOS runner. The runner provisions a
tagged web and Postgres backend on the durable GCP VM, signs both apps into the
CI Stack account, pairs them, forces Iroh relay-only transport, and runs the
six-step streamed-terminal driver in
[scripts/e2e/README.md](../../scripts/e2e/README.md).

## Topology

```
                       GitHub Actions run
  route (Linux) ------------------------------+
                                              |
                              mac-ios-e2e (macOS)
                              |                |
                    builds Mac + iOS       fresh simulator
                              |                |
                              +-- backend HTTPS/API --+
                              |                        |
                    Iroh relay-only terminal path    |
                              |                        |
                 cmux-dev-backend-1.tail137216.ts.net
                 per-tag web + Postgres Docker stacks
```

The Mac and simulator share the runner's operating system. Their terminal
traffic is still forced through Iroh relays, so local networking cannot turn
this into a direct-path test. The backend HTTPS connection uses the private
Tailscale Serve URL for sign-in, pairing tickets, and Mac advertisement.

## Job graph

| Job | Runner | Timeout | Does |
| --- | --- | --- | --- |
| `route` | Linux | 5m | Chooses `run_e2e` and the backend tag, `ci<PR#>` for PRs that change `web/`, otherwise `ci-main`. |
| `mac-ios-e2e` | macOS (`MACOS_RUNNER_IOS`, then `MACOS_RUNNER_PR`) | 120m | Joins the tailnet, provisions the GCP stack, builds both apps, boots an isolated simulator, signs in, pairs, verifies relay-only defaults, runs the six steps, uploads evidence, and cleans up. |
| `ios-e2e-status` | Linux | 5m | Always-run aggregate that reports the routed conclusion. |

The workflow currently has a `workflow_dispatch` trigger. The
`pull_request` trigger stays commented until the owner approves promotion after
the live ACL and one complete run are verified.

## GCP backend setup

The persistent VM is `cmux-dev-backend-1` in GCP project `cmux-489202`. It is an
`n2d-standard-32` with Docker, the `devbackendd` control daemon on loopback
port 8477, and the backend's Stack and APNs runtime files installed under
`/srv/cmux-dev`. The VM has the Tailscale tag `tag:dev-backend`.

The one-time VM installation is already owned by the backend administration
flow:

```text
./scripts/dev-backend.sh vm-install
./scripts/dev-backend.sh vm-status
```

The CI runner does this for each routed run:

```text
scripts/dev-backend.sh start --tag <tag> --checkout <cmux checkout> --transport direct
scripts/dev-backend.sh url --tag <tag>
```

The helper archives only `web/` from the PR checkout, sends it to the VM over
Tailscale SSH, asks `devbackendd` to create or update the tagged Docker web and
Postgres stack, and returns a private URL such as
`https://cmux-dev-backend-1.tail137216.ts.net:3916/`. The allocated Serve port
is in the reserved `3800-4799` range. The workflow places that URL in
`CMUX_DEV_BACKEND_URL`, `CMUX_DEV_API_BASE_URL`, and
`CMUX_IROH_BROKER_BASE_URL` before either app is built.

The backend's runtime secrets stay on the VM. The CI Stack account is kept on
the runner in `$HOME/.secrets/cmuxterm-dev.env` with mode `0600`, read by the
agent auth profile, and removed in the final cleanup step.

## Why `CMUX_DEV_BACKEND_SSH_KEY` is unnecessary

That secret would be a conventional SSH private key for `ubuntu` on the GCP
VM. It was proposed when a Linux backend job was going to call the helper.
The final topology runs the helper on the macOS job, where its existing local
forwarder support works, and authenticates the SSH connection with the
runner's Tailscale identity. The Tailscale OAuth client lets the runner join
the tailnet as `tag:ci`; the Tailscale SSH ACL then authorizes `ubuntu` on the
backend. The OAuth client and a VM SSH private key solve different problems.

There is no `CMUX_DEV_BACKEND_SSH_KEY` reference in the workflow or required
secret list. Removing it avoids another long-lived credential, key rotation,
and a second SSH trust path into the VM.

## Secrets

| Secret | Job | Purpose |
| --- | --- | --- |
| `TS_OAUTH_CLIENT_ID` / `TS_OAUTH_SECRET` | `mac-ios-e2e` | Join the ephemeral runner to the tailnet with `tag:ci`. |
| `CMUX_DOGFOOD_STACK_EMAIL` / `CMUX_DOGFOOD_STACK_PASSWORD` | `mac-ios-e2e` | CI Stack account used by both app endpoints. The workflow writes these values under the `CMUX_UITEST_*` names required by the `agent` profile. |

Secrets travel through step environments and the mode `0600` credentials file.
They are never passed as account values on a command line or written to the
repository checkout.

## Tailscale ACL requirements

The current direct backend helper returns an HTTPS URL on the VM's allocated
Serve port. Configure both network access and Tailscale SSH:

- Network ACL: `tag:ci` to `tag:dev-backend` on TCP `22` and TCP
  `3800-4799`.
- Tailscale SSH policy: accept `tag:ci` to `tag:dev-backend` for user
  `ubuntu`.
- No `tag:ci` to `tag:ci` rule is needed. The Mac and simulator are on one
  runner and do not signal each other over SSH.

An ACL that allows only ports `443` and `22` does not cover the current direct
Serve URLs because they include an allocated port such as `3916`. Add the
reserved range or change the helper and workflow together to use a fixed
443 endpoint.

The relay-only setting is enforced in both app configurations:

- Mac defaults: `cmux.iroh.debug.transport-mode=relayOnly` and
  `cmux.iroh.v2.force-relay=true`.
- iOS simulator defaults: `cmux.iroh.debug.transport-mode=relayOnly` and
  `cmux.iroh.v2.config.CMUX_IROH_V2_FORCE_RELAY=1`.

The workflow reads both values back before pairing and after launch. The E2E
driver also asserts the tagged Mac socket and simulator rendering for every
terminal step.

## Infra-preflight failure labeling

Tailnet join, backend reachability, backend serving, missing runner tools,
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
Tailscale ACL and node identity instead of a VM private key; **Serve** means a
tailnet-only HTTPS listener forwarding to a VM-local service; **relay-only**
means Iroh is prevented from selecting a direct peer path; **aggregate** means
the one always-run check that represents conditional jobs; **shadow** means a
check runs for measurement before branch protection requires it.
