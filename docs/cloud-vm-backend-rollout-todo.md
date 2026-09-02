# Cloud VM Backend Rollout Todo

This is the scoped todo list for making the Cloud VM backend production-ready with application logic running in the existing Vercel `manaflow/cmux` project.

> **2026-09-02:** Freestyle on the public platform (`api.freestyle.sh`) is the
> only active Cloud VM provider. E2B, Blaxel, Daytona, the old `cmuxd-remote`
> gateway, and Rivet actors are historical migration records. They are not
> valid values for current deployment or dogfood commands.

## Current State

- Vercel project exists: `manaflow/cmux`.
- Vercel root directory is `web`.
- Production URL is `https://cmux.com`.
- Vercel custom `staging` environment exists for the `manaflow/cmux` project and tracks the
  `staging` git branch.
- VM application logic already runs in the Vercel Next app:
  - `web/app/api/vm/**`
  - `web/services/vms/**`
- Current durable VM control-plane state is in Postgres:
  - `cloud_vms`
  - `cloud_vm_leases`
  - `cloud_vm_usage_events`
- WebSocket PTY and browser proxy data paths use the authenticated `cmux-remote`
  link after the REST handshake.
- No separate AWS app server is required for the current version.
- A separate `manaflow/cmux-staging` Vercel project exists for staging.

The checked-in image manifest is the source of truth for active and rollback
images. Its newest validated Freestyle base entry is
`freestyle-cmux-devbox-20260902c`
(`sh-940ec3bc46224c019e5e8d9a97053293`). The entries ending in `b` and `a` are
validated rollback images. The retired beta snapshot remains in the manifest
only to preserve provenance.

## State and rename synchronization contract

The cmux-tui daemon owns the canonical remote graph: machines contain
workspaces, workspaces contain tab views, and tab views point to terminals,
browsers, and agents. The macOS app must not create a second remote graph.

- `CloudMachineLink` owns one authenticated subscription per VM, its cursor,
  reconnect policy, and bounded recovery.
- `CloudVMState` is one immutable graph with an explicit synchronization mode.
  `journaled` state has a `(generation, revision)` cursor. A legacy
  `snapshot_only` state has a null cursor but keeps the complete graph for
  inspection and agent export. `SurfaceCatalog` installs that graph and its
  derived rows in one main-actor transaction, so UI, CLI, and restored
  projections read the same version.
- Full snapshots are authoritative. A delta is accepted only when it is
  contiguous and complete. Unknown or malformed events are barriers, trigger a
  coalesced snapshot repair, and stop after five barriers with an explicit
  warning. Recovery never loops without a bound.
- Event-feed recovery has one phase model, not independent retry flags. A
  reconnect keeps its consecutive-failure count until an accepted journaled
  stream remains healthy for ten seconds or a new authenticated connection is
  made. The first exhausted run gets one snapshot-recovery restart without
  erasing the spent budget. Ordinary later refreshes cannot reset an exhausted
  feed.
- IDs are identity and names are labels. Resolve an exact ID first. Resolve a
  name only when it is unique. Ambiguous or stale placement fails closed.
- A tab rename changes one exact tab placement. A terminal rename is an
  explicit compatibility operation that changes every placement of that
  terminal. Workspace rename uses revision compare-and-set and retries once
  only when no other client changed the old name.
- Remote events reconcile every local projection that stores the exact remote
  workspace and tab IDs. Local write-through uses the same mutation path and
  never echoes a daemon-originated update back to the daemon.
- Projection lifecycle reconciliation fills a missing local workspace binding
  after record, restore, or move only when all identity-bearing cloud panes
  agree on one `(machine, remote_workspace_id)` and no local pane is present.
  Identity-less cloud displays, ports, and pool terminals are neutral; mixed or
  ambiguous workspaces stay unbound. Explicit `workspace.cloud_vm_bind` values
  remain authoritative across disconnects.
- Rename intents are serialized by `(machine, scope, remote_id)` in one
  process-wide coordinator, so two local windows cannot send the same remote
  tab or workspace out of order. A local binding or projection stores the
  exact remote ID; legacy fallback is allowed only for one unambiguous view.
- Delta publication uses an explicit impact set and a materialized typed-graph
  index. Title, lifecycle, agent, and same-placement tab changes update only
  the touched index entries and rebuild only the affected resource rows. Any
  relationship-root, creation, deletion, move, or content change rebuilds the
  complete derived resource set. The raw graph is always updated first, and the
  index is a non-persisted cache, so a targeted row is still derived from the
  same authoritative bytes as a full snapshot.
- Freshness is explicit: `current`, `stale`, and `unavailable` are distinct
  states. A cached graph may be displayed as stale, but it may not authorize a
  new placement or rename.
- Snapshot-only compatibility is explicit. The app suspends the event reader for
  an unversioned Freestyle daemon, keeps all rows visible, and rejects workspace
  and tab rename writes until the daemon is upgraded. A malformed non-null
  cursor is rejected rather than treated as legacy.
- Freestyle route selection reads the canonical `vpcs` addresses when that
  field is present, uses the deprecated `networks` alias only when `vpcs` is
  absent, and uses public IPv6 only for a machine with no private address list.
  Private machines require the owner's WireGuard tunnel. `cmux-remote` Noise
  enrollment remains the only session transport; legacy WebSocket and SSH
  paths fail explicitly.

Agent-facing controls are JSON-first and composable: `cmux vm tree --json`,
`surface.catalog`, `surface.project`, `vm tab rename`, and the explicit
`vm terminal rename` compatibility command. The full graph costs more parsing
than a row-only cache, but it prevents divergent identity maps. Derived rows
keep UI updates small. Bounded recovery caps provider and CPU use, with an
operator-visible warning when the event stream remains incompatible.

## Current Blockers

- [x] Create AWS IAM migration roles trusted by GitHub OIDC for the two Cloud VM environments.
- [x] Add GitHub Environment secret `AWS_MIGRATION_ROLE_ARN` to both `cloud-vm-staging` and `cloud-vm-production`.
- [x] Copy minimal DB migration variables from Vercel into both GitHub Cloud VM environments:
  - `PGHOST`
  - `PGPORT`
  - `PGUSER`
  - `PGDATABASE`
  - `CMUX_DB_SSL_REJECT_UNAUTHORIZED`
- [x] Copy Stack smoke variables from Vercel into both GitHub Cloud VM environments:
  - `NEXT_PUBLIC_STACK_PROJECT_ID`
  - `NEXT_PUBLIC_STACK_PUBLISHABLE_CLIENT_KEY`
  - `STACK_SECRET_SERVER_KEY`
- [x] Add Axiom/OpenTelemetry env to both Vercel projects:
  - `OTEL_SERVICE_NAME`
  - `OTEL_EXPORTER_OTLP_ENDPOINT`
  - `OTEL_EXPORTER_OTLP_HEADERS`
- [x] Publish and validate the current Freestyle snapshot with the cmux-tui daemon.
- [x] Promote the validated public snapshot configuration to the active provider
  manifest and local dogfood environment.
- [x] Verify Freestyle create/attach, `cmux-remote` session state, and tab/workspace
  rename persistence against a live sandbox.
- [x] Verify local-to-cloud workspace and exact tab rename write-through from the
  catalog projection lifecycle, including restore and existing-target opens.
- [x] Preserve complete state from legacy Freestyle snapshots without a cursor;
  expose `snapshot_only` to agents and fail revision-fenced writes clearly.
- [ ] Persist the claimed cmux-tui device fingerprint/device id in each lease and
  revoke only those device records on sign-out. Freestyle currently revokes the
  control-plane lease rows, but not daemon enrollment records.
- [ ] Make missing Freestyle VPC member-rule repair a visible degraded create
  result or a retried provider operation. The current attach path is best-effort
  and can leave a private VM unreachable when the provider rejects the rule.
- [ ] Run authenticated preview and staging create/attach/browser-proxy smoke
  after the next deployment.
- [ ] Decide whether provider create needs an asynchronous status flow after
  measuring the Vercel function duration on a real Freestyle create.
- [ ] Rotate the Freestyle key and complete the secret-leak audit before a broad
  production rollout.

## Current Operational State

- [x] GitHub environments `cloud-vm-staging` and `cloud-vm-production` exist.
- [x] GitHub environment variable `AWS_REGION=us-west-2` is set for both Cloud VM environments.
- [x] GitHub OIDC provider `token.actions.githubusercontent.com` exists in AWS.
- [x] Staging migration role is scoped to `repo:manaflow-ai/cmux:environment:cloud-vm-staging` and the staging Aurora cluster resource id.
- [x] Production migration role is scoped to `repo:manaflow-ai/cmux:environment:cloud-vm-production` and the production Aurora cluster resource id.
- [x] Staging and production Cloud VM default provider are set to Freestyle.
- [x] Freestyle creates are enabled in the verified deployment configuration.
- [x] Freestyle create, `cmux-remote` attach, state recovery, and rename smoke passed
  without creating a production VM during the audit.
- [x] Production auth/list smoke passed without creating a production VM.
- [x] Axiom/OpenTelemetry env is set and redeployed in staging and production.
- [x] GitHub Cloud VM smoke workflows no longer require `VERCEL_TOKEN`.

## Existing Vercel Env Vars

These are already configured in Vercel for development, preview, and production:

- `RESEND_API_KEY`
- `CMUX_FEEDBACK_FROM_EMAIL`
- `CMUX_FEEDBACK_RATE_LIMIT_ID`
- `NEXT_PUBLIC_STACK_PROJECT_ID`
- `NEXT_PUBLIC_STACK_PUBLISHABLE_CLIENT_KEY`
- `STACK_SECRET_SERVER_KEY`

## Phase 1: Finish Current Vercel Backend Setup

- [x] Use a dedicated Vercel staging project instead of sharing preview secrets.
- [x] Add a global VM create kill switch, `CMUX_VM_CREATE_ENABLED`.
- [x] Add the Freestyle provider kill switch, `CMUX_VM_FREESTYLE_ENABLED`.
- [x] Set the global and Freestyle create switches to enabled values in the
  verified deployment configuration.
- [ ] Add a preview allowlist before paid provider calls if preview uses real provider keys:
  - Stack user ids
  - Stack org ids later, if org billing exists
- [x] Set `CMUX_VM_DEFAULT_PROVIDER=freestyle` in the verified local and deployed
  environments.
- [x] Set `FREESTYLE_API_KEY` and `FREESTYLE_SANDBOX_SNAPSHOT` in the verified
  provider environments. Values are never printed by audit tools.
- [x] Set Axiom/OpenTelemetry env in the verified staging and production
  environments:
  - `OTEL_SERVICE_NAME`
  - `OTEL_EXPORTER_OTLP_ENDPOINT`
  - `OTEL_EXPORTER_OTLP_HEADERS`
- [ ] Confirm Vercel function max duration for VM routes. `POST /api/vm` can wait on real provider
  provisioning, so the route either needs a sufficient `maxDuration` or must become an async
  create-status flow before production.
- [ ] Confirm Stack Auth callback and trusted domains include:
  - `https://cmux.com`
  - the Vercel preview domain pattern used by this project
  - local `CMUX_PORT` development callback URLs
- [ ] Redeploy Vercel preview after the rename branch merges.
- [ ] Smoke test the deployed preview:
  - `cmux auth login`
  - `cmux vm new --provider freestyle`
  - `cmux vm attach <id>`
  - browser proxy against a simple HTTP server inside the VM
- [ ] Redeploy production only after preview and staging smoke tests pass.

## Phase 2: Local Secret Parity

- [ ] Keep local Stack/web runtime secrets in `~/.secrets/cmuxterm-dev.env`.
- [ ] Keep production Stack/web runtime secrets in `~/.secrets/cmuxterm.env`.
- [ ] Keep provider image-build secrets in `~/.secrets/cmux.env`.
- [ ] Add runtime VM vars to the relevant `~/.secrets/cmuxterm*.env` file:
  - `CMUX_VM_DEFAULT_PROVIDER`
  - `CMUX_VM_CREATE_ENABLED`
  - `CMUX_VM_ALLOW_FREE_PROVISIONING` (leave unset; the paid-plan gate is the safe default and
    `audit-vercel-env.mjs` fails when a shared environment sets it to `1`/`true`/`yes`/`on`/`enabled`)
  - `CMUX_VM_REQUIRE_PRO` (legacy compatibility alias only: `0`/`false`/`no`/`off`/`disabled`
    enables free provisioning **only while** `CMUX_VM_ALLOW_FREE_PROVISIONING` is unset; any set
    value of the new switch wins, and every other legacy value or unset keeps the gate on)
  - `CMUX_VM_FREESTYLE_ENABLED`
  - `FREESTYLE_SANDBOX_SNAPSHOT`
  - Axiom/OpenTelemetry vars
- [x] Document the split between `~/.secrets/cmuxterm-dev.env`, `~/.secrets/cmuxterm.env`, and
  `~/.secrets/cmux.env` in `AGENTS.md`.
- [x] Replace `web/.env.local` local development with the committed `web/.envrc` and `bun dev`
  loader.
- [ ] Make the script print missing keys by name only, never values.

## Phase 3: Image Manifest and Rollback

Keep the exact Freestyle snapshot ID in `FREESTYLE_SANDBOX_SNAPSHOT`. This gives
simple rollback by changing one env var and redeploying.

- [x] Add a checked-in image manifest, `web/services/vms/images/manifest.json`.
- [x] Stop relying on hardcoded default image ids in deployed environments. Production and preview
  fail closed if the active Freestyle snapshot env var is missing or invalid.
- [x] Record every known-good Freestyle snapshot with:
  - image version
  - Freestyle snapshot id
  - cmux-tui daemon artifact provenance
  - build timestamp
  - builder script version
  - validation status
  - notes for known limitations
- [x] Add docs for the active env selector, `FREESTYLE_SANDBOX_SNAPSHOT`.
- [x] Add docs for rollback:
  - choose previous known-good manifest entry
  - set Vercel env vars back to that entry
  - redeploy
  - confirm new VMs use the old image
- [x] Ensure VM create responses or internal telemetry record:
  - provider
  - selected image id
  - manifest image version when available
- [x] Validate active Vercel image env vars against the manifest during VM create.
- [x] Add tests for deployed image resolution:
  - missing image env fails before provider call
  - unknown image id fails before provider call
  - known manifest image resolves to the expected provider id
- [ ] Keep old Freestyle snapshots until all active VMs using them are gone.

## Phase 4: Image Build and Promotion Workflow

- [x] Make image build script output a manifest entry instead of relying on chat notes.
- [x] Build the Freestyle snapshot from the pinned cmux-tui daemon artifact.
- [x] Record artifact provenance:
  - cmux-tui release/artifact manifest entry
  - cmux-tui install and bootstrap command
  - binary SHA256
  - artifact URL used by Freestyle snapshot creation
- [ ] Run Freestyle smoke tests after image build:
  - shell starts
  - WebSocket PTY authenticates
  - command execution works
  - browser proxy can reach an HTTP server inside the VM
  - locale/sudo/python sanity checks pass
- [ ] Add the validated manifest entry in the same PR as any snapshot ID update.
- [ ] Promote the snapshot in this order:
  - preview/staging env vars
  - preview smoke tests
  - production env vars
  - production redeploy
  - production smoke tests
- [ ] Do not delete old Freestyle snapshots during the same promotion.

## Phase 5: VM Create Rate Limits

- [x] Add per-team active VM limits before paid provider create calls.
- [x] Limit `POST /api/vm` more strictly than other VM endpoints through active VM limits.
- [x] Keep `GET /api/vm`, attach, and status endpoints generous.
- [x] Include idempotency keys in create handling so retries do not double count active VM creates.
- [x] Decide first implementation: Postgres active VM limits, no Redis/Upstash dependency yet.
- [x] Add tests for:
  - unauthenticated create blocked before provider call
  - over-limit create blocked before provider call
  - retry with same idempotency key does not create a duplicate provider VM
- [x] Add a provider-budget circuit breaker so a provider outage or runaway loop can disable new
  creates while leaving attach/delete available.

## Phase 5.5: Security Hardening Before Production

- [x] Add CSRF/origin protection for cookie-authenticated mutating VM routes. Native bearer-token
  calls are not CSRFable, but browser cookie fallback for `POST`/`DELETE` should check `Origin` or
  `Sec-Fetch-Site`.
- [x] Add ownership tests for every mutating per-VM endpoint:
  - another user cannot `DELETE /api/vm/:id`
  - another user cannot `POST /api/vm/:id/exec`
  - another user cannot mint attach or SSH endpoints
- [x] Remove raw `/api/rivet/*`; there is no raw actor action surface to test.
- [ ] Add a provider API key rotation runbook for Freestyle.
- [ ] Audit logs, spans, JSON responses, and terminal startup commands for secret leakage:
  - provider API keys
  - Stack access/refresh tokens
  - attach PTY tokens
  - attach RPC tokens
  - Freestyle SSH passwords/identity handles
- [ ] Harden the browser proxy contract:
  - leases are scoped to one VM and one session
  - proxy cannot become an arbitrary public open proxy
  - target host/port policy is explicit and tested
- [ ] Add a production emergency cleanup procedure:
  - list VMs by user
  - destroy by provider VM id
  - revoke attach/SSH credentials
  - disable new creates globally or per provider

## Phase 6: Usage Ledger

This should be a follow-up after the current VM PR unless billing becomes a launch blocker.

- [ ] Add durable usage storage.
- [ ] Record VM lifecycle events:
  - user id
  - provider
  - provider VM id
  - image id
  - manifest image version
  - created timestamp
  - destroyed timestamp
  - failure reason when provisioning fails
- [ ] Record attach events:
  - PTY lease minted
  - RPC lease minted or reused
  - transport
  - provider
- [ ] Record exec events:
  - command count
  - timeout
  - exit code
  - duration
- [ ] Do not store raw command text, PTY output, browser traffic, or attach tokens in the usage
  ledger unless a separate privacy review explicitly approves it.
- [ ] Add cost rollups by user, provider, and day.
- [ ] Make cleanup jobs idempotent so orphan cleanup cannot double count usage.
- [ ] Add provider spend alerts independent of app telemetry:
  - Freestyle dashboard/API budget alert
  - Vercel spend alert for function usage

## Phase 7: Database Control Plane and Legacy Removal

Postgres is the durable control plane for Cloud VMs. The current VM API has no
Rivet dependency. PTY and browser traffic uses the authenticated `cmux-remote`
link after the Vercel REST handshake. The remaining work is cleanup and
operational proof, not a provider migration.

- [x] Add Postgres as the durable control plane foundation for Cloud VMs.
- [x] Use Drizzle for TypeScript schema and migrations.
- [x] Add CMUX_PORT-derived local Postgres so parallel worktrees do not collide.
- [x] Add CI migration verification against a real Postgres service.
- [x] Add the first internal DB-backed VM read model and real Postgres test.
- [x] Add a Vercel Marketplace Aurora OIDC/RDS IAM runtime DB adapter.
- [x] Add a dedicated `bun db:migrate:aws-rds-iam` migration command for production/staging.
- [x] Seed Vercel staging and production with app/provider DB driver env names.
- [ ] Connect the Vercel Marketplace Aurora resource to `manaflow/cmux` for both `staging` and production so these env names are present:
  - `AWS_ROLE_ARN`
  - `AWS_REGION`
  - `PGHOST`
  - `PGPORT`
  - `PGUSER`
  - `PGDATABASE`
- [ ] Keep app runtime DB user separate from migration DB user.
- [ ] Run migrations through protected GitHub Actions, never during Vercel build/startup.
- [x] Replace `userVmsActor` and `vmActor` with Vercel route handlers plus database tables:
  - users
  - VMs
  - leases
  - idempotency keys
  - usage events
- [x] Replace `userVmsActor.list` with `SELECT ... FROM vms WHERE user_id = ...`.
- [x] Replace `userVmsActor.create` with a Vercel route handler using:
  - `Idempotency-Key`
  - a unique DB constraint on `(user_id, idempotency_key)`
  - `status = provisioning | running | failed | destroyed`
  - a provider VM id recorded once available
- [x] Do not use an actor for create retries. Vercel can safely retry when the request includes an
  idempotency key and the DB row is the source of truth.
- [x] Define create retry behavior:
  - first request inserts a `provisioning` row
  - duplicate request with same idempotency key returns the existing row
  - if provider create finished, return the provider VM id
  - if create is still in progress, return `409`
  - if create failed, return the recorded failure and allow an explicit new idempotency key
- [ ] Decide whether provider create stays synchronous or becomes async:
  - synchronous is simpler but depends on Vercel function duration
  - async requires a queue or background worker but avoids long HTTP requests
- [ ] Add `GET /api/vm/:id/status` or equivalent before moving long creates fully async.
- [x] Replace actor serialization with DB correctness:
  - unique constraints for idempotency
  - row locks or advisory locks around destroy/attach/snapshot
  - conditional status transitions
  - retry-safe cleanup jobs
- [ ] Add a replacement for actor-owned cleanup:
  - expired lease cleanup
  - orphan provider VM cleanup
  - stuck provisioning cleanup
- [x] No legacy actor migration is needed for new Cloud VM state. If pre-merge
  actor state existed, treat those VMs as pre-production and clean them up
  provider-side.
- [x] Remove Rivet env requirements after the DB-backed routes are live:
  - `RIVET_ENDPOINT`
  - `RIVET_PUBLIC_ENDPOINT`
  - `RIVET_RUNNER_VERSION`
  - `RIVET_TOKEN`
  - `RIVET_NAMESPACE`
  - `CMUX_RIVET_INTERNAL_SECRET`
- [x] Remove `/api/rivet/**` routes after no VM code path depends on Rivet.
- [x] Remove `rivetkit` dependency after the route migration and state migration are complete.

## Phase 8: CI/CD Guardrails

- [ ] PR checks should run web typecheck, Bun tests, and the remote-state contract tests.
- [ ] PR checks should not call paid providers by default.
- [ ] Provider tests should use a `MockVMProvider` by default. Only the explicit
  staging smoke job may call Freestyle.
- [ ] Staging smoke tests may call real Freestyle with tiny quotas.
- [ ] Vercel preview checks should verify the project root is still `web`.
- [ ] Add a CI check that required deployed env var names are documented in `web/.env.example` and
  `web/services/vms/README.md`.
- [ ] Add a safe Vercel env audit command to the runbook that prints names/scopes only, never values.
- [ ] Production promotion should require manual approval.
- [ ] Production promotion should redeploy Vercel after env/image changes.
- [ ] Production promotion should run smoke tests without destructive cleanup of user VMs.

## Phase 9: Observability

- [ ] Confirm Axiom preview dataset receives spans from Vercel preview.
- [ ] Confirm Axiom production dataset receives spans from Vercel production.
- [ ] Add or verify spans for:
  - VM create route
  - provider create
  - control-plane create transaction
  - attach endpoint minting
  - WebSocket attach
  - browser proxy startup
  - provider errors
  - rate-limit blocks
- [ ] Add dashboards or saved queries for:
  - VM create duration for Freestyle
  - provider failure rate
  - attach latency
  - browser proxy failures
  - rate-limit blocks by user
- [ ] Add alerts, not just dashboards:
  - provider create failure spike
  - p95 VM create duration regression
  - attach endpoint failures
  - browser proxy startup failures
  - unexpected increase in active VM count

## Phase 10: Documentation

- [ ] Update `web/services/vms/README.md` with the final Vercel env list.
- [ ] Add image promotion and rollback instructions.
- [ ] Add local env setup instructions.
- [ ] Add production promotion instructions.
- [ ] Add Vercel environment variable audit instructions.
- [ ] Add `CMUX_VM_CREATE_ENABLED` and provider kill-switch docs.
- [x] Add security notes for Stack Auth bearer plus refresh tokens, provider
  attach leases, and `cmux-remote` invitation/device-key handling.
- [ ] Document secret redaction for provider keys, attach tokens, and daemon
  startup commands.
- [ ] Add a license/package-boundary note if future backend-only code is intended to use a different
  license from the rest of the repo.
- [ ] Add a future `cmux-infra` or `backend-rollout` skill so agents follow this
  workflow consistently, including the state/rename contract above.

## Historical migration record

The following systems are retained only for auditability and rollback history:

- E2B, Blaxel, and Daytona provider adapters and image selectors were removed.
- The old `cmuxd-remote` WebSocket gateway and its lease-file protocol were
  replaced by the cmux-tui daemon and `cmux-remote` transport.
- Rivet actor routes and state were replaced by Postgres route handlers.

Do not restore these names to deployment env, provider selection, or new image
build instructions. Historical references in migration files, audit tests, and
the daemon spike document must remain labelled as historical.
