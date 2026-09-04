# Cloud VM Backend Rollout Todo

This is the scoped todo list for making the Cloud VM backend production-ready with application logic running in the existing Vercel `manaflow/cmux` project.

> **2026-09-02:** legacy Cloud VM deployment paths have been removed; one
> managed path remains. Completed `[x]` items below are kept as a record of
> work done at the time. Deployment-specific names and credentials are omitted.

Neutral image and edge labels introduced in this runbook describe the target
contract. They are not promises about current environment-variable names until
the corresponding runtime migration lands.

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
- WebSocket PTY/browser proxy data paths talk to managed VM endpoints after the REST handshake.
- No separate AWS app server is required for the current version.
- A separate `manaflow/cmux-staging` Vercel project exists for staging.

## Rust parity gate

Backend readiness is necessary but does not make Cloud usable from npm, PyPI,
or a guest. The Rust client and backend must converge on the contract in
[docs/cloud-rust-system-design.md](cloud-rust-system-design.md), with the
vertical slices tracked in
[plans/feat-cloud-rust-cli/DESIGN.md](../plans/feat-cloud-rust-cli/DESIGN.md).
Before a Cloud command is marked ready, the backend must provide:

- a versioned facade and generated request and response fixtures;
- explicit team scope, machine principal scope, and action metadata;
- idempotency lookup, operation receipts, cancellation tombstones, and
  stale-backend reconciliation;
- stable error codes, request and trace IDs, absolute-deadline behavior, and
  event cursors;
- cleanup for leases, ports, private routes, publications, sessions, and
  backend resources;
- redacted usage references for billing and CodeRouter attribution;
- a readiness report that proves the guest daemon and requested action
  preconditions;
- the existing domains list, zones, verify, publish, access, and rm verbs,
  including URL-first output, labelled DNS instructions, generated-name
  defaults, and the sign-in or denial flow;
- a package and hosted behavior check that does not open the desktop app.

Deployment SDKs, DNS, TLS, billing, and secret custody stay in backend
services. Adding a web route without a Rust fixture, action check, and headless
acceptance test is an incomplete slice.

## Current Blockers

### Fast machine creation gate

- [ ] Keep a scrubbed warm machine pool by region, size, image family, and
  persistence profile.
- [ ] Keep separate warm storage profiles for ephemeral and persistent
  machines. A persistent claim must attach an unused encrypted home volume.
- [ ] Claim a warm machine in one idempotent transaction, reset daemon state,
  bind a new owner, apply the display label, and return only after one
  daemon-ready probe.
- [ ] Return a cold-create operation immediately when the warm pool has no
  healthy slot. The Rust client follows it to readiness by default;
  `--no-wait` returns the operation immediately.
- [ ] Measure create-to-ready p50 and p95 in the request trace. The release
  target is p50 under 3 seconds and p95 under 10 seconds on the warm path.
- [ ] Measure ready-to-open separately. Local pane projection must not delay the
  create receipt or make a ready machine look unready.
- [ ] Prove that a claimed slot contains no prior files, routes, credentials,
  publications, or event cursors before assigning it to a new owner.

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
- [ ] Publish a new managed VM image with cmuxd-remote started with
  `--rpc-auth-lease-file`.
- [ ] Resolve image publication returning backend `INTERNAL_ERROR`.
- [ ] Promote the managed image to staging and rerun create/attach/browser
  proxy smoke.
- [x] Keep new creates disabled and non-default until the current image
  supports RPC/browser proxy.
- [x] Use the managed image path as the staging and production default while
  the replacement image is blocked.

## Current Operational State

- [x] GitHub environments `cloud-vm-staging` and `cloud-vm-production` exist.
- [x] GitHub environment variable `AWS_REGION=us-west-2` is set for both Cloud VM environments.
- [x] GitHub OIDC trust `token.actions.githubusercontent.com` exists in AWS.
- [x] Staging migration role is scoped to `repo:manaflow-ai/cmux:environment:cloud-vm-staging` and the staging Aurora cluster resource id.
- [x] Production migration role is scoped to `repo:manaflow-ai/cmux:environment:cloud-vm-production` and the production Aurora cluster resource id.
- [x] Staging and production Cloud VM default deployment are configured.
- [x] New creates are disabled in staging and production with the legacy-image
  switch set to `0`.
- [x] Staging create, WebSocket attach, and destroy smoke passed on the managed
  image path.
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
- [x] Add per-image-family kill switches:
  - `CMUX_VM_MANAGED_IMAGE_ENABLED`
  - `CMUX_VM_LEGACY_IMAGE_ENABLED`
- [x] Set kill switches to enabled values in `manaflow/cmux` production and
  `manaflow/cmux-staging` production.
- [ ] Add a preview allowlist before paid backend calls if preview uses real infrastructure keys:
  - Stack user ids
  - Stack org ids later, if org billing exists
- [ ] Set `CMUX_VM_DEFAULT_IMAGE_FAMILY` in Vercel development, preview, and production.
- [ ] Set the managed-edge API credential in Vercel preview and production.
- [ ] Set the managed VM image selector in Vercel preview and production.
- [ ] Set Axiom/OpenTelemetry env in Vercel preview and production:
  - `OTEL_SERVICE_NAME`
  - `OTEL_EXPORTER_OTLP_ENDPOINT`
  - `OTEL_EXPORTER_OTLP_HEADERS`
- [ ] Make `POST /api/vm` a hybrid fast-create endpoint. It claims a scrubbed warm
  machine and returns ready within the short request budget. If no warm slot is
  available, it returns `202` with an operation and never holds the request on
  cold boot. The Rust client follows that operation by default; `--no-wait`
  returns it to the caller.
- [ ] Confirm Stack Auth callback and trusted domains include:
  - `https://cmux.com`
  - the Vercel preview domain pattern used by this project
  - local `CMUX_PORT` development callback URLs
- [ ] Redeploy Vercel preview after env injection.
- [ ] Smoke test preview:
  - `cmux auth login`
  - `cmux vm new --detach --json`
  - `cmux vm attach <id>`
  - browser proxy against a simple HTTP server inside the VM
- [ ] Redeploy production only after preview smoke tests pass.

## Phase 2: Local Secret Parity

- [ ] Keep local Stack/web runtime secrets in `~/.secrets/cmuxterm-dev.env`.
- [ ] Keep production Stack/web runtime secrets in `~/.secrets/cmuxterm.env`.
- [ ] Keep deployment image-build secrets in `~/.secrets/cmux.env`.
- [ ] Add runtime VM vars to the relevant `~/.secrets/cmuxterm*.env` file:
  - `CMUX_VM_DEFAULT_IMAGE_FAMILY`
  - `CMUX_VM_CREATE_ENABLED`
  - `CMUX_VM_ALLOW_FREE_PROVISIONING` (leave unset; the paid-plan gate is the safe default and
    `audit-vercel-env.mjs` fails when a shared environment sets it to `1`/`true`/`yes`/`on`/`enabled`)
  - `CMUX_VM_REQUIRE_PRO` (legacy compatibility alias only: `0`/`false`/`no`/`off`/`disabled`
    enables free provisioning **only while** `CMUX_VM_ALLOW_FREE_PROVISIONING` is unset; any set
    value of the new switch wins, and every other legacy value or unset keeps the gate on)
  - `CMUX_VM_LEGACY_IMAGE_ENABLED`
  - the managed VM image selector
  - Axiom/OpenTelemetry vars
- [x] Document the split between `~/.secrets/cmuxterm-dev.env`, `~/.secrets/cmuxterm.env`, and
  `~/.secrets/cmux.env` in `AGENTS.md`.
- [x] Replace `web/.env.local` local development with the committed `web/.envrc` and `bun dev`
  loader.
- [ ] Make the script print missing keys by name only, never values.

## Phase 3: Image Manifest and Rollback

Phase 1 should keep exact image IDs in Vercel env vars. This gives simple rollback by changing env vars and redeploying.

- [x] Add a checked-in image manifest, `web/services/vms/images/manifest.json`.
- [x] Stop relying on hardcoded default image ids in deployed environments. Production and preview
  should fail closed if the active image selectors are missing or not found in
  the manifest.
- [x] Record every known-good image version with:
  - image version
  - managed image template id
  - managed snapshot id
  - cmuxd-remote commit
  - build timestamp
  - builder script version
  - validation status
  - notes for known limitations
- [x] Add docs for the active image selectors. Secret names are kept in the
  deployment system, not in this public runbook.
- [x] Add docs for rollback:
  - choose previous known-good manifest entry
  - set Vercel env vars back to that entry
  - redeploy
  - confirm new VMs use the old image
- [x] Ensure VM create responses or internal telemetry record:
  - image family
  - selected image id
  - manifest image version when available
- [x] Validate active Vercel image env vars against the manifest during VM create.
- [x] Add tests for deployed image resolution:
  - missing image selector fails before backend call
  - unknown image id fails before backend call
  - known manifest image resolves to the expected machine image id
- [ ] Keep old managed snapshots until all active VMs using them are gone.

## Phase 4: Image Build and Promotion Workflow

- [x] Make image build script output a manifest entry instead of relying on chat notes.
- [x] Build the managed template and snapshot from the same cmuxd-remote commit.
- [x] Record artifact provenance:
  - cmuxd-remote git commit
  - cmuxd-remote build command
  - binary SHA256
  - R2 object key or build artifact URL used by image creation
- [ ] Run managed-image smoke tests after image build:
  - shell starts
  - WebSocket PTY authenticates
  - command execution works
  - browser proxy can reach an HTTP server inside the VM
  - locale/sudo/python sanity checks pass
- [ ] Add the validated manifest entry in the same PR as any image id update.
- [ ] Promote images in this order:
  - preview/staging env vars
  - preview smoke tests
  - production env vars
  - production redeploy
  - production smoke tests
- [ ] Do not delete old templates/snapshots during the same promotion.

## Phase 5: VM Create Rate Limits

- [x] Add per-team active VM limits before paid backend create calls.
- [x] Limit `POST /api/vm` more strictly than other VM endpoints through active VM limits.
- [x] Keep `GET /api/vm`, attach, and status endpoints generous.
- [x] Include idempotency keys in create handling so retries do not double count active VM creates.
- [x] Decide first implementation: Postgres active VM limits, no Redis/Upstash dependency yet.
- [x] Add tests for:
-  - unauthenticated create blocked before backend call
  - over-limit create blocked before backend call
  - retry with same idempotency key does not create a duplicate machine
- [x] Add a deployment-budget circuit breaker so a backend outage or runaway loop can disable new
  creates while leaving attach/delete available.

## Phase 5.5: Security Hardening Before Production

- [x] Add CSRF/origin protection for cookie-authenticated mutating VM routes. Native bearer-token
  calls are not CSRFable, but browser cookie fallback for `POST`/`DELETE` should check `Origin` or
  `Sec-Fetch-Site`.
- [x] Add ownership tests for every mutating per-VM endpoint:
  - another user cannot `DELETE /api/vm/:id`
  - another user cannot `POST /api/vm/:id/exec`
  - another user cannot mint attach or SSH endpoints
- [x] Remove the raw temporary-actor route; there is no raw actor action
  surface to test.
- [ ] Add a managed-edge credential rotation runbook.
- [ ] Audit logs, spans, JSON responses, and terminal startup commands for secret leakage:
  - infrastructure API keys
  - Stack access/refresh tokens
  - attach PTY tokens
  - attach RPC tokens
  - VM SSH passwords/identity handles
- [ ] Harden the browser proxy contract:
  - leases are scoped to one VM and one session
  - proxy cannot become an arbitrary public open proxy
  - target host/port policy is explicit and tested
- [ ] Add a production emergency cleanup procedure:
  - list VMs by user
  - destroy by backend machine id
  - revoke attach/SSH credentials
  - disable new creates globally or per image family

## Phase 6: Usage Ledger

This should be a follow-up after the current VM PR unless billing becomes a launch blocker.

- [ ] Add durable usage storage.
- [ ] Record VM lifecycle events:
  - user id
  - image family
  - backend machine id
  - image id
  - manifest image version
  - created timestamp
  - destroyed timestamp
  - failure reason when provisioning fails
- [ ] Record attach events:
  - PTY lease minted
  - RPC lease minted or reused
  - transport
  - deployment path
- [ ] Record exec events:
  - command count
  - timeout
  - exit code
  - duration
- [ ] Do not store raw command text, PTY output, browser traffic, or attach tokens in the usage
  ledger unless a separate privacy review explicitly approves it.
- [ ] Add cost rollups by user, image family, and day.
- [ ] Make cleanup jobs idempotent so orphan cleanup cannot double count usage.
- [ ] Add deployment spend alerts independent of app telemetry:
  - managed-edge budget alert
  - Vercel spend alert for function usage

## Phase 7: Database and temporary-actor removal plan

Target outcome: remove the temporary stateful control-plane dependency for the
Cloud VM feature. The current VM API does not use it for user-facing realtime,
and the PTY/browser WebSockets already talk to managed VM endpoints after the
Vercel REST handshake.

- [x] Add Postgres as the durable control plane foundation for Cloud VMs.
- [x] Use Drizzle for TypeScript schema and migrations.
- [x] Add CMUX_PORT-derived local Postgres so parallel worktrees do not collide.
- [x] Add CI migration verification against a real Postgres service.
- [x] Add the first internal DB-backed VM read model and real Postgres test.
- [x] Add a Vercel Marketplace Aurora OIDC/RDS IAM runtime DB adapter.
- [x] Add a dedicated `bun db:migrate:aws-rds-iam` migration command for production/staging.
- [x] Seed Vercel staging and production with app and database driver env names.
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
  - a backend machine id recorded once available
- [x] Do not use a stateful actor for create retries. Vercel can safely retry when the request includes an
  idempotency key and the DB row is the source of truth.
- [x] Define create retry behavior:
  - first request inserts a `provisioning` row
  - duplicate request with same idempotency key returns the existing row
  - if backend create finished, return the backend machine id
  - if create is still in progress, return `409`
  - if create failed, return the recorded failure and allow an explicit new idempotency key
- [ ] Add `GET /api/vm/:id/status` and operation lookup by idempotency key so a
  killed client can recover a cold create without guessing whether a machine
  exists.
- [x] Replace actor serialization with DB correctness:
  - unique constraints for idempotency
  - row locks or advisory locks around destroy/attach/snapshot
  - conditional status transitions
  - retry-safe cleanup jobs
- [ ] Add a replacement for actor-owned cleanup:
  - expired lease cleanup
  - orphan backend machine cleanup
  - stuck provisioning cleanup
- [x] No actor migration is needed for new Cloud VM state. If pre-merge actor
  state existed, treat those VMs as pre-production and clean them up through
  the backend.
- [x] Remove the temporary actor env requirements after the DB-backed routes
  are live.
- [x] Remove temporary actor routes after no VM code path depends on them.
- [x] Remove the temporary actor dependency after route and state migration.

## Phase 8: CI/CD Guardrails

- [ ] PR checks should run web typecheck and Bun tests.
- [ ] PR checks should not call paid infrastructure by default.
- [ ] Backend tests should use a `MockCloudMachineBackend` by default.
- [ ] Staging smoke tests may call the managed edge with tiny quotas.
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
  - backend create
  - actor create
  - attach endpoint minting
  - WebSocket attach
  - browser proxy startup
  - backend errors
  - rate-limit blocks
- [ ] Add dashboards or saved queries for:
  - VM create duration by image family
  - backend failure rate
  - attach latency
  - browser proxy failures
  - rate-limit blocks by user
- [ ] Add alerts, not just dashboards:
  - backend create failure spike
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
- [ ] Add `CMUX_VM_CREATE_ENABLED` and image-family kill-switch docs.
- [ ] Add security notes for:
  - Stack Auth bearer plus refresh tokens
  - internal actor header
  - signed actor params
  - backend attach lease handling
- [ ] Add a license/package-boundary note if future backend-only code is intended to use a different
  license from the rest of the repo.
- [ ] Add a future `cmux-infra` or `backend-rollout` skill so agents follow this workflow consistently.
