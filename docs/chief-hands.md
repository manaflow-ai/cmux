# Chief hands

A hand is a machine that runs `cmux-hand` (the `acpmux hand` subcommand) for a Cloud Chief. The hand dials out to the Cloud API over one WebSocket. It has no inbound port. Its owner, or a Chief with the `hands` grant, sends it typed requests:

- `fs.read`, `fs.write`, `fs.edit`, `fs.patch`, `fs.list`, `fs.glob` and `fs.grep`, with sha256 preconditions;
- `exec`;
- `agent.*`, for acpmux agent sessions (claude, codex, opencode).

Code: `cmux-tui/crates/acpmux/src/hand/` (the hand) and `backend/apps/api/src/hand-*.ts` (HandDO, routes, installer, levels, classifier, providers, sweep).

## Install

```sh
curl -fsSL https://<api>/hand/install.sh | sh -s -- --pair <code> [--profile mac]
```

- A code is single-use and lives 10 minutes. The owner mints it (`POST /v1/hands/pair-codes`), or a Chief does (`hands pair_code`).
- The profile is fixed when the code is minted.
- The installer checks the published binary's sha256 against the tree's `completion.json`.
- A Chief can install a hand on another host by running that line over ssh from a hand it already has.

## Permission levels

| Level | Classifier | Approvals | Hard denies | Integrity guard |
| --- | --- | --- | --- | --- |
| `full` (sandbox default) | no | no | no | yes |
| `auto` (Mac default) | yes | risky actions | yes | yes |
| `ask` | no | every write, program run, agent session | yes | yes |
| `read-only` | no | no (writes refused) | yes | yes |

- An owner can set a default level per profile for new hands. The built-in defaults stay as above.
- A Chief can only lower a level.
- A raise needs the owner's presence proof. That is a signature over a single-use challenge (`POST /v1/hands/<hand>/level-challenge`), made by a Secure Enclave key with the `userPresence` access-control flag (Touch ID or Face ID) that the app registered for its install (`PUT /v1/hands/presence-key`, signed by the install key).
- An approval answer (allow) uses the plain install key. A deny needs only the owner's session.
- The shared trust rule: the owner's own device signs a per-request nonce with its key; the verifier holds only what it needs to check it. (acpmux's person key is a symmetric secret that stays on the Mac, so the Cloud uses the install key and the presence key, whose public halves it holds.)
- The owner's app gets `hand-approval-pending {hand, id, summary, at, sign}` and `hand-approval-settled {hand, id, outcome}` on its user wire socket (no polling); `GET /v1/hands/<hand>/approvals` is the read at launch.

## Sandboxes and providers

`hand-providers.ts` defines the provider interface: create, exec, pause, remove and list. Freestyle is the first implementation, with the hands-only key `HAND_FREESTYLE_API_KEY` and the image `cmuxnp-<env>-hand-vN` baked by `backend/apps/api/scripts/bake-hand-sandbox.ts`. E2B, Daytona, Modal, Blaxel, a Docker host, a Kubernetes pod and an SSH host are stubs that answer "no key configured". The bring-your-own path works on any machine: run the install line there with a `sandbox` code.

Hand sandboxes are separate from the cmux Cloud VM product. Cloud VMs run on Freestyle only, with no fallback provider. A hand sandbox runs on a provider that the person chooses.

## Known limits

- At `full`, the integrity guard is a mistake guard, not a boundary. It checks paths and argv words. A program that the person allowed can still read the hand's key. The planned fix is to keep the key in the Keychain, or to run the hand as a separate user.
- The hard denies on a Mac hand catch the plain cases only (for example `rm -rf ~` or a disk erase). An encoded command can get past them. The classifier and the person's choice of level are the main guard.
- There is no iOS approval surface yet. The Mac app answers through its approval banner.
- A level change does not change running agent sessions. A session keeps the policy it started with (approve-all at `full`). To apply a lower level to an agent, stop the session and start it again.
- The hand runs its agents on its own acpmux daemon (`<hand home>/acpmux`) and proves the person with a key it makes at each start. When that daemon is a signed (Team) daemon, which ignores the key, the hand restarts it at most once per run. After that it refuses every agent permission prompt.
- The idle stop (`CMUX_HAND_AGENT_IDLE_MINUTES`, default 30, `0` = never) skips a session whose turn is still running. A turn that hangs keeps its session until the Chief stops it.
