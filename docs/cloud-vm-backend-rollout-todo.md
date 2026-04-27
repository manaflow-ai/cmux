# Cloud VM Backend Rollout Todo

This is the scoped todo list for making the Cloud VM backend production-ready with application logic running in the existing Vercel `manaflow/cmux` project.

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
- WebSocket PTY/browser proxy data paths talk to provider VM endpoints after the REST handshake.
- No separate AWS app server is required for the current version.
- A separate `manaflow/cmux-staging` Vercel project exists for staging.

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
- [x] Add per-provider kill switches:
  - `CMUX_VM_E2B_ENABLED`
  - `CMUX_VM_FREESTYLE_ENABLED`
- [x] Set kill switches to enabled values in `manaflow/cmux` production and
  `manaflow/cmux-staging` production.
- [ ] Add a preview allowlist before paid provider calls if preview uses real provider keys:
  - Stack user ids
  - Stack org ids later, if org billing exists
- [ ] Set `CMUX_VM_DEFAULT_PROVIDER` in Vercel development, preview, and production.
- [ ] Set `E2B_API_KEY` in Vercel preview and production.
- [ ] Set `FREESTYLE_API_KEY` in Vercel preview and production.
- [ ] Set `E2B_CMUXD_WS_TEMPLATE` in Vercel preview and production.
- [ ] Set `FREESTYLE_SANDBOX_SNAPSHOT` in Vercel preview and production.
- [ ] Set Axiom/OpenTelemetry env in Vercel preview and production:
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
- [ ] Redeploy Vercel preview after env injection.
- [ ] Smoke test preview:
  - `cmux auth login`
  - `cmux vm new --provider freestyle`
  - `cmux vm new --provider e2b`
  - `cmux vm attach <id>`
  - browser proxy against a simple HTTP server inside each provider VM
- [ ] Redeploy production only after preview smoke tests pass.

## Phase 2: Local Secret Parity

- [ ] Keep local Stack/web runtime secrets in `~/.secrets/cmuxterm-dev.env`.
- [ ] Keep production Stack/web runtime secrets in `~/.secrets/cmuxterm.env`.
- [ ] Keep provider image-build secrets in `~/.secrets/cmux.env`.
- [ ] Add runtime VM vars to the relevant `~/.secrets/cmuxterm*.env` file:
  - `CMUX_VM_DEFAULT_PROVIDER`
  - `CMUX_VM_CREATE_ENABLED`
  - `CMUX_VM_E2B_ENABLED`
  - `CMUX_VM_FREESTYLE_ENABLED`
  - `E2B_CMUXD_WS_TEMPLATE`
  - `FREESTYLE_SANDBOX_SNAPSHOT`
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
  should fail closed if the active E2B/Freestyle image env vars are missing or not found in the
  manifest.
- [x] Record every known-good image version with:
  - image version
  - E2B template id
  - Freestyle snapshot id
  - cmuxd-remote commit
  - build timestamp
  - builder script version
  - validation status
  - notes for known limitations
- [x] Add docs for the active env selectors:
  - `E2B_CMUXD_WS_TEMPLATE`
  - `FREESTYLE_SANDBOX_SNAPSHOT`
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
- [ ] Keep old E2B templates and Freestyle snapshots until all active VMs using them are gone.

## Phase 4: Image Build and Promotion Workflow

- [x] Make image build script output a manifest entry instead of relying on chat notes.
- [x] Build E2B template and Freestyle snapshot from the same cmuxd-remote commit.
- [x] Record artifact provenance:
  - cmuxd-remote git commit
  - cmuxd-remote build command
  - binary SHA256
  - R2 object key or build artifact URL used by Freestyle snapshot creation
- [ ] Run provider smoke tests after image build:
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
- [ ] Add provider API key rotation runbooks for E2B and Freestyle.
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
  - E2B dashboard/API budget alert
  - Freestyle dashboard/API budget alert
  - Vercel spend alert for function usage

## Phase 7: Database and Rivet Removal Plan

Target outcome: remove Rivet completely for the Cloud VM feature. The current VM API does not use
Rivet for user-facing realtime, and the PTY/browser WebSockets already talk to provider VM endpoints
after the Vercel REST handshake. Rivet is only a temporary stateful control-plane convenience.

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
- [x] Do not use Rivet for create retries. Vercel can safely retry when the request includes an
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
- [x] No Rivet actor migration is needed for new Cloud VM state. If pre-merge actor state existed,
  treat those VMs as pre-production and clean them up provider-side.
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

- [ ] PR checks should run web typecheck and Bun tests.
- [ ] PR checks should not call paid providers by default.
- [ ] Provider tests should use a `MockVMProvider` by default.
- [ ] Staging smoke tests may call real E2B/Freestyle with tiny quotas.
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
  - actor create
  - attach endpoint minting
  - WebSocket attach
  - browser proxy startup
  - provider errors
  - rate-limit blocks
- [ ] Add dashboards or saved queries for:
  - VM create duration by provider
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
- [ ] Add security notes for:
  - Stack Auth bearer plus refresh tokens
  - internal Rivet header
  - signed actor params
  - provider attach lease handling
- [ ] Add a license/package-boundary note if future backend-only code is intended to use a different
  license from the rest of the repo.
- [ ] Add a future `cmux-infra` or `backend-rollout` skill so agents follow this workflow consistently.
