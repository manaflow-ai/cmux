# Cloud VMs service

Backend for `cmux vm new/ls/rm/exec/attach` and the sidebar Cloud VM surface. Stack Auth gates every public route. Provider API keys stay server-side. Every machine attaches through the cmux-tui remote daemon (transport `cmux-remote`). The legacy `cmuxd-remote` WebSocket PTY and the Freestyle SSH gateway are gone.

## Layout

```text
services/vms/
  auth.ts             Stack Auth request verification helpers
  billingGateway.ts   Stack Auth VM create-credit reservations
  entitlements.ts     Team plan and active VM limit resolution
  drivers/            Provider SDK adapter for Freestyle
  privateNetwork.ts   Per-user private networks and WireGuard tunnel enrollment
  images/             Checked-in known-good provider image manifest
  errors.ts           Typed Effect errors for VM workflows
  config.ts           Runtime kill switches and deployment guards
  providerGateway.ts  Effect service wrapper around provider drivers
  repository.ts       Effect service for Postgres state and usage rows
  routeHelpers.ts     Shared authenticated REST route helpers
  workflows.ts        Effect workflows for create, list, destroy, exec, attach
db/
  schema.ts           Drizzle schema for VM state, leases, and usage events
  migrations/         SQL migrations applied by `bun db:migrate`
```

## HTTP surface

- `/api/vm`, authenticated `GET` list and `POST` create.
- `/api/vm/:id`, authenticated `DELETE` destroy.
- `/api/vm/:id/exec`, authenticated `POST` command execution.
- `/api/vm/:id/attach-endpoint`, authenticated `POST` PTY/RPC attach lease minting.
- `/api/vm/tunnel`, authenticated `POST` WireGuard tunnel enrollment for the calling
  computer, `GET` tunnel/list state, `DELETE` unenrollment. Not Pro-gated: a lapsed
  subscription must still be able to reach machines it already owns.

There is no raw actor or provider protocol endpoint. The old `/api/rivet/*` gateway has been removed.

## Authentication model

Public callers only use `/api/vm/*`. Each route calls Stack Auth first and returns `401` before any Postgres or provider operation when the caller is unauthenticated.

Ownership checks happen inside the Effect workflow by loading the VM row with both `user_id` and `provider_vm_id`. A user cannot destroy, exec, attach, or mint SSH credentials for a VM owned by another Stack Auth user.

Cookie-authenticated browser mutations also require a same-origin browser request. Native macOS
calls use `Authorization: Bearer` plus `X-Stack-Refresh-Token` and are not subject to browser CSRF.
For cookie calls, `POST`/`DELETE` routes reject cross-site `Origin` or `Sec-Fetch-Site` requests
before any VM workflow runs.

Cloud VM billing is team-scoped. The native client sends the selected Stack team in
`X-Cmux-Team-Id`; browser callers may send that header or `teamId`/`billingTeamId` in the request.
The backend validates membership before create or team-filtered list. If Stack returns one team,
the backend treats it as the personal team created on sign-up. If Stack returns no team, or multiple
teams without a selected/requested team, create fails before providers or billing are called.

The auth regression tests live in `web/tests/vm-route-auth.test.ts`. They verify unauthenticated create, list, destroy, attach, SSH endpoint, and exec requests return `401` before the VM workflow runs, and that cross-site cookie mutations are rejected.

## State model

- `cloud_vms` owns VM lifecycle state, provider ids, image ids, billing team/plan ids, and per-user idempotency keys.
- `cloud_vm_leases` stores hashed PTY/RPC/SSH lease tokens, provider identity handles, session ids, expiry, and revocation timestamps.
- `cloud_vm_usage_events` records lifecycle, attach, SSH, and exec events with billing team/plan ids for billing and audit rollups.
- `cloud_vm_networks` records the one provider private network per (user, provider).
- `cloud_vm_tunnels` records each computer's WireGuard tunnel: provider tunnel id, device
  fingerprint, the client's **public** key, and its address inside the network. No private
  key is ever sent to or stored by the backend.

Create idempotency is enforced by the partial unique index on `(user_id, idempotency_key)`. A retry with the same key returns the existing VM after provisioning succeeds. A concurrent retry while the first create is still provisioning returns `409` instead of starting a second paid provider VM.

Active VM limits are enforced inside the same Postgres transaction that inserts the create row. The transaction takes a billing-team advisory lock before counting active VMs, so two concurrent creates for the same team cannot both pass the free-plan limit.

## Image manifest and rollback

Known-good images are recorded in `services/vms/images/manifest.json`. Each entry records the
provider, image id, cmux image version, build metadata (`repoCommit`, agent pins), and
validation status. **The manifest is the only source of truth for the image users get; no env
var selects or overrides it.**

Image policy:

- Clients request a machine **kind** (`kind: "desktop" | "base"` on `POST /api/vm`,
  `POST /api/vm/base/open`, and `POST /api/vm/base/reset`) rather than pinning an image id. With
  no `image`, the resolver serves the manifest entry flagged `kind` + `defaultForKind` at the
  plan's **size** (a body with neither `image` nor `kind` gets the `base` default) and otherwise
  fails closed with `vm_image_config_error`. Sizes are Freestyle's ladder (`sm` … `2xl`,
  `services/vms/images/sizes.ts`): one snapshot per size, and the smallest whose memory covers
  the plan's `defaultMemoryMbForPlan` is served, so machines boot at their shape and the driver
  never resizes. Create responses and `limits.imageKinds` carry the `size`. `image` still wins when present, but a client-requested `image` must be
  in the manifest (or `CMUX_VM_ALLOW_UNMANIFESTED_IMAGES=1`, which local dev implies). Responses
  and `GET /api/vm` entries echo `kind`; `GET /api/vm` `limits.imageKinds` lists the kinds the
  default provider can serve and the image each resolves to.
- `vm_image_config_error` responses carry client-safe `details.imageRequested`, `details.kind`,
  `details.source` (`request` | `default`), and `details.allowedKinds`; the provider, manifest
  image ids, and reason go to the server log (`[vm-image-config-error]`) because API error
  payloads must not leak provider implementation details (see
  `expectNoCloudVmImplementationLeaks` in `tests/vm-route-auth.test.ts`).
- Local development and every deployed runtime serve the same `defaultForKind` entry; there is no
  separate local default and nothing to copy into `.env`.
- Today's base default is `freestyle-cmux-devbox-20260902e`, image
  `sh-e4dc9393a82e4dfaaa8f90b01b0d247c`, baked and verified on cmux's Freestyle account from
  https://github.com/manaflow-ai/cmux/pull/11666 (`6a1243bfd7`, baked cmux-tui daemon, `freestyle/ubuntu-sm` base). The retired beta entry stays listed for the record and is never a default; earlier
  public entries stay for rollback.
- Snapshots are account-scoped: a manifest id is only bootable by the Freestyle account whose
  `FREESTYLE_API_KEY` the deployment uses. `freestyle-cmux-devbox-20260902h` (the desktop devbox,
  `ubuntu` work user, cmux login banner) is validated but listed as a non-default reference bake
  for that reason; re-promote it under cmux's key to make it the default.
- Promotion is `bun run devbox:promote -- freestyle` (bake → verify → manifest write), then a PR
  with the manifest diff; merging promotes. See
  `services/vms/images/devbox/README.md`. `tests/vm-image-manifest.test.ts` holds the invariants:
  one `defaultForKind` per provider and kind, unique versions, every default
  `validationStatus: "passed"`.
- Baked agent tools are installed at image-build time. They are not auto-updated on VM startup, so
  startup latency stays bounded and the manifest remains the source of truth.
- To update tool versions, bump the Dockerfile ARG pins and `CMUX_IMAGE_EPOCH`, then promote a new
  image. `CMUX_CLOUD_IMAGE_<TOOL>_NPM_SPEC` overrides must be exact npm package version pins, for
  example `@openai/codex@0.130.0`, or `none` to disable a tool. The image builder rejects ranges
  and tags such as `latest`.

A leftover `FREESTYLE_SANDBOX_SNAPSHOT` in a deployment is ignored; the env audit reports it as
stale configuration to remove.

Rollback is a manifest change:

1. Revert the promotion PR (or flip `defaultForKind` back to a previous entry with
   `validationStatus: "passed"`; entries are never removed).
2. Deploy staging, smoke test, then production.
3. Keep old snapshots until all VMs using them are gone.

## Baked tools and VM-local cmux CLI

The Freestyle devbox image is defined in
`web/services/vms/images/devbox/` and baked with `web/scripts/build-devbox-freestyle.ts`
(chatmux devbox
parity: devtools, mise node/python/bun, uv, gh, Chrome + cua-driver, pinned coding
agents, ble.sh devshell, agent-config generator). The session daemon is cmux-tui,
baked at `/root/.cmux/bin/cmux-tui` from the files.cmux.com artifacts manifest pin
current at bake time (recorded as `cmuxTuiCommit` in the manifest entry). Its identity
is bound to the machine's instance id by `cmux-devbox-boot`, so create runs no guest
bootstrap. See the devbox README for the bake + verify + manifest flow. The legacy cmuxd-remote image builder
(`build-cloud-vm-images.ts`) has been deleted; images it produced remain in the
manifest for reference but cannot serve the cmux-remote transport.

## Browser automation from Cloud VM SSH

`cmux browser ...` inside a `cmux ssh` or Cloud VM SSH session controls the local cmux browser
through the authenticated relay. It does not start Chrome inside the VM. This keeps browser UI,
cookies, profiles, and screenshots on the local Mac while agent computation runs remotely.

The Linux relay CLI supports the common browser automation subcommands: `open`, `navigate`, `back`,
`forward`, `reload`, `get-url`, `snapshot`, `eval`, `wait`, `click`, `dblclick`, `hover`, `focus`,
`check`, `uncheck`, `fill`, `type`, `press`, `select`, and `screenshot`. Existing-browser commands
default to `CMUX_SURFACE_ID`; `open` defaults to `CMUX_WORKSPACE_ID`.

## SSH session lifecycle

`cmux vm ssh <id>` and `cmux vm attach <id>` open a cmux-managed remote workspace. For providers
that return SSH attach info, the CLI resolves the VM endpoint and then uses the same workspace,
relay, startup, and session-state path as `cmux ssh`. `cmux vm ssh-info <id>` is the print-only
debugging command.

Plain `cmux ssh` uses OpenSSH control sockets and `ControlPersist` by default. If the foreground
SSH process exits after sleep or a network transition, the startup wrapper retries the same command
before reporting the session ended. `cmux ssh` and `cmux vm ssh` share this wrapper, so both paths
surface reconnect progress in the terminal and keep workspace remote state visible while the daemon
or proxy controller reconnects. Cloud VM provider sessions that expose only short-lived gateway
credentials may still require a fresh attach lease; after the retry limit is exhausted, the terminal
prints the existing disconnect banner instead of falling back silently to a local shell.

Manual sleep/network smoke:

1. Start a Cloud VM, then attach with `cmux vm ssh <id>`.
2. Confirm the terminal reaches a remote prompt and the sidebar shows the workspace as connected.
3. Disable Wi-Fi or sleep the Mac long enough for OpenSSH to exit.
4. Restore the network and confirm the terminal prints a reconnect attempt and either lands back in
   a remote prompt or clearly reports that the remote session ended.
5. Confirm the sidebar shows `Reconnecting` during retry and `Connected` after recovery.

## Effect conventions

Routes stay thin. They parse HTTP input, set span attributes, and run an Effect workflow.

`workflows.ts` composes explicit services:

- `VmRepository`, Postgres reads and writes.
- `VmProviderGateway`, provider SDK calls wrapped in typed Effect errors.

Provider SDKs remain Promise-based adapters under `drivers/`, but all route-visible backend logic is modeled as Effect values with typed errors and explicit dependencies.

## Deployment

Vercel runs the Next.js application and all VM REST routes. Postgres is the persistent control plane. There is no Rivet deployment for this feature.

Production and staging use Vercel Marketplace AWS Aurora PostgreSQL with OIDC federation and RDS IAM auth. The runtime does not need a long-lived database password.

Set these Vercel environment variables per production/staging environment:

- `CMUX_DB_DRIVER=aws-rds-iam`.
- `AWS_ROLE_ARN`, IAM role Vercel assumes.
- `AWS_REGION`, Aurora region.
- `PGHOST`, Aurora cluster endpoint.
- `PGPORT`, usually `5432`.
- `PGUSER`, IAM-enabled Postgres role.
- `PGDATABASE`, app database name.
- `CMUX_DB_POOL_MAX`, small pool size for Vercel Functions. Start with `5`.
- `CMUX_DB_SSL_REJECT_UNAUTHORIZED`, optional. Leave unset for the current Vercel Marketplace Aurora databases so Node uses its default trust store.
- `CMUX_VM_CREATE_ENABLED`, global create kill switch. Set `0` to block new paid creates while
  keeping list, attach, and delete available.
- `CMUX_VM_ALLOW_FREE_PROVISIONING`, explicit opt-out of the paid-plan Cloud VM gate. Leave unset
  (or set to `0`) in every shared environment; set to `1` only for a deliberate demo/rollback. When
  enabled, `CMUX_VM_FREE_MAX_ACTIVE_VMS` and the plan-specific free limit are honored again.
- `CMUX_VM_REQUIRE_PRO`, legacy compatibility spelling for the paid-plan gate. Unset now means the
  gate is **on**. `0`/`false`/`off` is treated as the old permissive escape hatch only when
  `CMUX_VM_ALLOW_FREE_PROVISIONING` is absent; prefer the clearly named allow switch for new
  deployments.
- `CMUX_VM_FREESTYLE_ENABLED`, per-provider Freestyle create kill switch.
- `CMUX_VM_PRIVATE_NETWORK_ENABLED`, private networking rollback switch. Unset/`1`: new
  Freestyle machines join their owner's VPC, open no public inbound port, and are
  attached at their private VPC address through the owner's WireGuard tunnel. `0`: later
  creates revert to the public-IPv6 posture (inbound 1337 open). Machines keep working
  across a flip either way, because reachability is resolved from the addresses each
  machine actually holds.
- `CMUX_VM_ALLOWED_ORIGINS`, optional comma-separated extra origins allowed for cookie mutations.
- `FREESTYLE_API_KEY`, Freestyle provider key.
- `CMUX_VM_DEFAULT_PROVIDER`, only `freestyle` (and its default).
- `CMUX_VM_DEFAULT_PLAN`, optional fallback for accounts without plan metadata. It defaults to `free`;
  paid values are ignored unless `CMUX_VM_ALLOW_FREE_PROVISIONING=1`, so deployment configuration
  cannot silently grant every unclassified account a paid entitlement.
- `CMUX_VM_PLAN_FREE_CREATE_CREDIT_ITEM_ID`, optional Stack Auth team item used as the free-plan create-credit bucket. Leave unset to skip free-plan create-credit accounting; set to `none`, `disabled`, `off`, or `false` to explicitly opt out.
- `CMUX_VM_PLAN_FREE_CREATE_CREDIT_COST`, optional free-plan per-create cost. Defaults to `1`.
- `CMUX_VM_PLAN_FREE_INITIAL_CREATE_CREDITS`, optional first-use seed for the free-plan Stack Auth create-credit item. Defaults to `20`.
- `CMUX_VM_CREATE_CREDIT_ITEM_ID`, optional global Stack Auth item used as a prepaid create-credit bucket for every plan without a plan-specific item. Set to `none`, `disabled`, `off`, or `false` to opt out of create credits for plans without a plan-specific value.
- `CMUX_VM_CREATE_CREDIT_COST`, default `1`.
- `CMUX_VM_CREATE_CREDIT_COST_FREESTYLE`, optional provider-specific override.
- `CMUX_VM_FREE_MAX_ACTIVE_VMS`, default `0` and ignored while the paid-plan gate is enforced.
- `CMUX_VM_PLAN_<PLAN>_MAX_ACTIVE_VMS`, optional incident-only cap for one paid plan. Unset means
  paid plans have no active-machine limit.
- Stack Auth environment variables.
- Axiom/OpenTelemetry exporter variables.

Local development keeps using Docker Postgres through `DATABASE_URL`, derived from `CMUX_PORT`.

Run production/staging migrations explicitly, never during Vercel build or route startup. The local operator path pulls deployed Vercel env. The GitHub Actions path uses the minimal DB metadata copied into protected GitHub environments, generates an RDS IAM auth token, and applies Drizzle migrations:

```bash
bun run cloud-vm:migrate -- staging
bun run cloud-vm:migrate -- production
```

For local Docker Postgres, keep using:

```bash
bun db:migrate
```

Before a staging or production migration, run the preflight:

```bash
bun run cloud-vm:preflight -- --schema-only .
```

Audit deployed env names without printing values:

```bash
bun run cloud-vm:env:audit -- staging --strict
bun run cloud-vm:env:audit -- production --strict
```

This audit is a local operator command. It intentionally does not run in GitHub Actions because
reading all Vercel env values from Actions would require a broad Vercel env-read token.

Smoke deployed API auth/list behavior without creating production VMs:

```bash
bun run cloud-vm:smoke -- staging
bun run cloud-vm:smoke -- production
```

Staging may run a real create/destroy smoke with tiny quotas:

```bash
bun run cloud-vm:smoke -- staging --create --provider freestyle
```

Run default-provider stress before changing provider defaults or after provider incidents:

```bash
bun run cloud-vm:stress -- staging --count 8 --concurrency 4 --provider default
bun run cloud-vm:stress -- production --count 12 --concurrency 4 --provider default
```

## GitHub operations

Cloud VM migrations and smoke checks are exposed as manual GitHub Actions:

- `Cloud VM DB migration`
- `Cloud VM smoke`

They use these GitHub Environments:

- `cloud-vm-staging`
- `cloud-vm-production`

Each environment needs:

- variable `AWS_REGION`, usually `us-west-2`
- variables `PGHOST`, `PGPORT`, `PGUSER`, and `PGDATABASE`
- variable `CMUX_DB_SSL_REJECT_UNAUTHORIZED`, usually `true`
- variables `NEXT_PUBLIC_STACK_PROJECT_ID` and `NEXT_PUBLIC_STACK_PUBLISHABLE_CLIENT_KEY`
- secret `STACK_SECRET_SERVER_KEY` for smoke workflows
- secret `AWS_MIGRATION_ROLE_ARN` for migration workflows

Production migration runs staging migration first on the same commit, then waits on the protected production environment approval.

## Local database development

Use `CMUX_PORT` to run multiple isolated web and database environments on one machine:

```bash
CMUX_PORT=10180 bun dev
```

`bun dev` sources `~/.secrets/cmuxterm-dev.env` (falling back to the legacy secret files), derives the local database URL from `CMUX_PORT`, starts this worktree's Docker Postgres, applies Drizzle migrations, then starts Next.js. When it exits or is interrupted, it stops the matching Docker container and network while preserving the Postgres volume.

The dev Postgres port is `CMUX_PORT + 10000`, so `CMUX_PORT=10180` maps to `localhost:20180`. `bun db:test` starts a separate test DB on `CMUX_PORT + 30000`, applies migrations twice, and runs behavior tests against a real Postgres container.

## Provider matrix

| Verb | Freestyle |
| --- | --- |
| `cmux vm new` | yes |
| `cmux vm new --workspace` | yes |
| `cmux vm new --detach` | yes |
| `cmux vm attach <id>` | yes |
| `cmux vm ssh <id>` | yes |
| `cmux vm ssh-info <id>` | no (cmux-remote only) |
| `cmux vm exec <id> -- ...` | yes |
| `cmux vm ls / rm` | yes |
| snapshot / restore | yes |

`cmux vm ssh <id>` is the user-facing interactive alias and opens the same managed workspace path
as `cmux vm attach <id>`. No provider serves an SSH gateway any more, so `cmux vm ssh-info <id>`
has nothing to print and `POST /api/vm/:id/ssh-endpoint` is gone.

Freestyle machines boot the shared devbox snapshot (definition in
`services/vms/images/devbox/`, baked with `web/scripts/build-devbox-freestyle.ts` against
the public platform `api.freestyle.sh`): chatmux-devbox tool parity (mise node/python/bun,
uv, gh, devtools, pinned coding agents, ble.sh, half-life prompt, seeded history). Machines
run no cmuxd-remote: the **cmux-tui remote daemon is the machine's only session daemon**,
and the bake installs the pinned static-musl build at `/root/.cmux/bin/cmux-tui` with
`sha256sum -c` verification. A create is `vms.create`, the grow-only resize, and one
model-plane env file write; the baked supervisor starts the daemon with a fresh identity
within a second of resume (the snapshot is a memory image, so the identity is keyed on
the platform instance id). Attach heals a daemon that is not listening, reinstalling only
when the binary is missing or behind the manifest pin. The daemon runs as root with
`HOME=/root`; the build and its digest come from the artifacts manifest published by
`.github/workflows/cmux-tui-artifacts.yml`, nothing is pinned by hand, and a new pin
reaches new machines through a rebake. Config: `FREESTYLE_API_KEY` (or `FREESTYLE_STACK_ACCESS_TOKEN` +
`FREESTYLE_TEAM_ID`); optionally `FREESTYLE_API_URL` to point
at a non-default edge and `CMUX_VM_CMUX_TUI_MANIFEST_URL` to pin a deployment to one
commit's `https://files.cmux.com/cmux-tui/<commit>/manifest.json` instead of the rolling
`latest`.

There is no HTTP ingress proxy to arbitrary VM ports on the public platform (a TLS edge rule
needs a customer-verified domain), so the daemon is reached directly at a VM address.

**Private networking is the default.** Every Freestyle machine joins the one VPC that
belongs to its owner (provisioned on first create, slug `cmux-net-<hash>`); the owner's
computers join the same VPC over WireGuard tunnels (`/api/vm/tunnel`, `cmux vpn up`). The
route is then the VM's *private* address — `ws://[<vpc ipv6>]:1337/v1/link` — and creates
state outbound-only firewall rules: no public inbound port at all. The VPC's single
members-reach-each-other rule is what admits the owner's other machines and tunnels to the
daemon port. Machines created before private networking (or while
`CMUX_VM_PRIVATE_NETWORK_ENABLED=0`) keep the older posture: inbound 1337 open and the
route at the stable public IPv6. The daemon binds dual-stack (`[::]:1337`), re-asserted on
every attach-time heal, which is also what makes the VPC address reachable.
The Noise handshake encrypts and authenticates the session end to end, so carrier TLS is not
required; the route token exists only for the lease ledger. Creates take no ports field and
no create-time env, so the coderouter model-plane vars are delivered by writing the persisted
`/root/.config/cmux/model-plane.env` (0600) that `/etc/cmux/agent-config.sh` already sources.

Every guest command is run with `linuxUser: "root"`. The 0.2 API's default is *not* root but
"the account holding uid 1000, or root in an image with no such account", and the devbox image
ships a uid-1000 user — leaving it unset would silently move the daemon, its install, and the
model-plane write off the root layout they are baked around.

`POST /api/vm/[id]/attach-endpoint` with
`{"transport":"cmux-remote","clientCapabilities":[...]}` returns
`{route, token, session, daemonBuild?, invitation?}` where `invitation` is a single-use
`cmux://enroll/…` URI minted only when the caller's device is not enrolled. The client
connects with `cmux-tui remote connect <route> --invite-file …`, then
`POST /api/vm/[id]/cmux-remote/approve {invitationId}` approves the pending claim (poll
until `state` is `approved`). The legacy websocket/SSH attach (`attach-endpoint` without a
transport, `POST /api/vm/[id]/sessions`) answers `409 vm_attach_transport_unsupported` with
`details.supportedTransports: ["cmux-remote"]`. `cmux vm shell`, `cmux vm new`,
`cmux vm base open` and the Machines panel all drive this from the Mac.
See docs/cloud-cmux-tui-daemon.md for the design.

Freestyle machines run the cmux-tui daemon and only the `cmux-remote`
transport. The route is the VM's stable public IPv6 straight to the daemon
(`ws://[<ipv6>]:1337/v1/link`): the platform has no HTTP ingress proxy to
arbitrary VM ports, so the carrier is plain ws and the daemon's Noise
enrollment is what gates sessions. The backend writes only a hash of attach
tokens to Postgres; raw tokens are returned once to the Mac client. Machines
created by the old cmuxd-remote drivers cannot serve this transport and need
recreation.

Operational note: before rollout, verify the deployed
`CMUX_VM_DEFAULT_PROVIDER`, `CMUX_VM_FREESTYLE_ENABLED`, `FREESTYLE_API_KEY`,
env values with
`bun run cloud-vm:env:audit -- <target> --strict`, then confirm attach and
daemon health with `bun run cloud-vm:stress -- <target> --provider default`.

## Usage, limits, and pricing

The usage ledger is in Postgres. VM create pricing gates can use Stack Auth payment items, but free-plan create credits are opt-in. Configure `CMUX_VM_PLAN_FREE_CREATE_CREDIT_ITEM_ID` only when the free plan should consume a prepaid create-credit bucket. When enabled, the create workflow records a one-time local grant row, seeds the configured Stack Auth item credits once per billing team, reserves one create credit only for a newly inserted row, calls the provider, and refunds the credit if provisioning fails before a usable VM exists.

Plan limits are team-based. Stack Auth personal teams should stay enabled for both dev/staging and production projects (`createTeamOnSignUp` / `teams.createPersonalTeamOnSignUp`). New VM rows store `billing_team_id` and `billing_plan_id`; the free plan allows zero active VMs by default and remains at zero regardless of stale free-limit env values while the paid-plan gate is on. A deliberate `CMUX_VM_ALLOW_FREE_PROVISIONING=1` escape hatch re-enables the configured free allowance for local demos or a controlled rollback; paid plans get the allowance sold on /pricing, 50 active machines per billing team, multiplied by the Team subscription's paid seats (`cmuxSeats` in the team's Stack metadata, written from the Stripe quantity) so "50 per user" holds for the whole team (`PAID_MAX_ACTIVE_VMS_DEFAULT`; `maxActiveVms` in entitlements and the list response). Every machine is the plan machine: 20 GB memory, 5 vCPU (one per 4 GB), and a 200 GB disk, which the Freestyle driver grows the VM to at create (`CMUX_VM_DISK_MB` overrides the disk). Destroyed VMs do not count against a limit; pausing does not free quota on the production provider. Paid plan activation should write a readable plan id such as `pro` into Stack Auth team read-only metadata (`cmuxVmPlan`) or equivalent billing sync metadata. `CMUX_VM_PLAN_<PLAN>_MAX_ACTIVE_VMS` and `CMUX_VM_PAID_MAX_ACTIVE_VMS` exist only as incident brakes; the product number lives in code. Paid plans only consume Stack Auth create credits when `CMUX_VM_PLAN_<PLAN>_CREATE_CREDIT_ITEM_ID` or the global `CMUX_VM_CREATE_CREDIT_ITEM_ID` is configured.

### The free limit is the paywall moment

`vmActiveLimitExceededResponse` (routeHelpers) renders every provisioning verb's over-limit error. On unpaid plans the message sells the upgrade — with the default zero allowance it is the subscribe gate ("Cloud VMs require a cmux Pro subscription") with `upgradeRequired: true` and `upgradeUrl` pointing at `/pricing` — so clients can show a real upgrade prompt (checkout flow per `skills/cmux-billing`) instead of a dead error. Paid plans see it at the plan allowance (50 active machines, times paid seats on Team) or at an operator incident brake; then the message is operational "delete one" guidance, not a paywall.

### Pricing is flat

Paid plans include up to 50 active VMs (per paid seat on Team) for a flat subscription price, every one the plan machine. There is no usage metering, no overages, and no per-hour VM size pricing; an earlier GB-RAM-awake-seconds metering design was considered and dropped to keep pricing simple.
