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
  - `web/app/api/rivet/**`
  - `web/services/vms/**`
- Current durable VM control-plane state is in RivetKit actors:
  - `userVmsActor`
  - `vmActor`
- WebSocket PTY/browser proxy data paths talk to provider VM endpoints after the REST handshake.
- No separate AWS app server is required for the current version.
- No separate staging Vercel project is documented yet. Current Vercel environments are development,
  preview, and production.

## Existing Vercel Env Vars

These are already configured in Vercel for development, preview, and production:

- `RESEND_API_KEY`
- `CMUX_FEEDBACK_FROM_EMAIL`
- `CMUX_FEEDBACK_RATE_LIMIT_ID`
- `NEXT_PUBLIC_STACK_PROJECT_ID`
- `NEXT_PUBLIC_STACK_PUBLISHABLE_CLIENT_KEY`
- `STACK_SECRET_SERVER_KEY`

## Phase 1: Finish Current Vercel Backend Setup

- [ ] Decide whether staging is:
  - a dedicated Vercel project, or
  - the existing Vercel preview environment with a stable branch alias.
- [ ] Add a global VM create kill switch, for example `CMUX_VM_CREATE_ENABLED`.
- [ ] Add per-provider kill switches, for example:
  - `CMUX_VM_E2B_ENABLED`
  - `CMUX_VM_FREESTYLE_ENABLED`
- [ ] Add a preview allowlist before paid provider calls if preview uses real provider keys:
  - Stack user ids
  - Stack org ids later, if org billing exists
- [ ] Set `CMUX_RIVET_INTERNAL_SECRET` in Vercel development, preview, and production.
- [ ] Set `CMUX_VM_DEFAULT_PROVIDER` in Vercel development, preview, and production.
- [ ] Set `E2B_API_KEY` in Vercel preview and production.
- [ ] Set `FREESTYLE_API_KEY` in Vercel preview and production.
- [ ] Set `E2B_CMUXD_WS_TEMPLATE` in Vercel preview and production.
- [ ] Set `FREESTYLE_SANDBOX_SNAPSHOT` in Vercel preview and production.
- [ ] Set Rivet deployment env in Vercel preview and production:
  - `RIVET_ENDPOINT`, or
  - `RIVET_TOKEN` plus `RIVET_NAMESPACE`
- [ ] Set `RIVET_PUBLIC_ENDPOINT` if the selected Rivet deployment flow requires public metadata.
- [ ] Set `RIVET_RUNNER_VERSION` and document the monotonic bump rule.
- [ ] Set Axiom/OpenTelemetry env in Vercel preview and production:
  - `OTEL_SERVICE_NAME`
  - `OTEL_EXPORTER_OTLP_ENDPOINT`
  - `OTEL_EXPORTER_OTLP_HEADERS`
- [ ] Confirm Vercel function max duration for VM routes. `POST /api/vm` can wait on real provider
  provisioning, so the route either needs a sufficient `maxDuration` or must become an async
  create-status flow before production.
- [ ] Confirm `/api/rivet/start` works with Vercel Deployment Protection. If previews are protected,
  configure the correct bypass for trusted Rivet engine requests without exposing raw actor actions.
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

- [ ] Keep Stack/web runtime secrets in `~/.secret/cmuxterm.env`.
- [ ] Keep provider image-build secrets in `~/.secrets/cmux.env`.
- [ ] Add runtime VM vars to `~/.secret/cmuxterm.env`:
  - `CMUX_RIVET_INTERNAL_SECRET`
  - `CMUX_VM_DEFAULT_PROVIDER`
  - `E2B_CMUXD_WS_TEMPLATE`
  - `FREESTYLE_SANDBOX_SNAPSHOT`
  - Rivet endpoint/token vars
  - Axiom/OpenTelemetry vars
- [x] Document the split between `~/.secret/cmuxterm.env` and `~/.secrets/cmux.env` in `AGENTS.md`.
- [x] Replace `web/.env.local` local development with the committed `web/.envrc` and `bun dev`
  loader.
- [ ] Make the script print missing keys by name only, never values.

## Phase 3: Image Manifest and Rollback

Phase 1 should keep exact image IDs in Vercel env vars. This gives simple rollback by changing env vars and redeploying.

- [ ] Add a checked-in image manifest, for example `web/services/vms/images/manifest.json`.
- [ ] Stop relying on hardcoded default image ids in deployed environments. Production and preview
  should fail closed if the active E2B/Freestyle image env vars are missing or not found in the
  manifest.
- [ ] Record every known-good image version with:
  - image version
  - E2B template id
  - Freestyle snapshot id
  - cmuxd-remote commit
  - build timestamp
  - builder script version
  - validation status
  - notes for known limitations
- [ ] Add docs for the active env selectors:
  - `E2B_CMUXD_WS_TEMPLATE`
  - `FREESTYLE_SANDBOX_SNAPSHOT`
- [ ] Add docs for rollback:
  - choose previous known-good manifest entry
  - set Vercel env vars back to that entry
  - redeploy
  - confirm new VMs use the old image
- [ ] Ensure VM create responses or internal telemetry record:
  - provider
  - selected image id
  - manifest image version when available
- [ ] Validate active Vercel image env vars against the manifest during VM create.
- [ ] Add tests for deployed image resolution:
  - missing image env fails before provider call
  - unknown image id fails before provider call
  - known manifest image resolves to the expected provider id
- [ ] Keep old E2B templates and Freestyle snapshots until all active VMs using them are gone.

## Phase 4: Image Build and Promotion Workflow

- [ ] Make image build script output a manifest entry instead of relying on chat notes.
- [ ] Build E2B template and Freestyle snapshot from the same cmuxd-remote commit.
- [ ] Record artifact provenance:
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

- [ ] Add per-user rate limiting before paid provider create calls.
- [ ] Limit `POST /api/vm` more strictly than other VM endpoints.
- [ ] Keep `GET /api/vm`, attach, and status endpoints generous.
- [ ] Include idempotency keys in rate-limit handling so retries do not double count.
- [ ] Decide implementation:
  - Vercel Firewall if it supports the exact per-user keying we need, or
  - Redis/Upstash/Vercel KV for explicit per-user counters
- [ ] Add tests for:
  - unauthenticated create blocked before provider call
  - over-limit create blocked before provider call
  - retry with same idempotency key does not create a duplicate provider VM
- [ ] Add a provider-budget circuit breaker so a provider outage or runaway loop can disable new
  creates while leaving attach/delete available.

## Phase 5.5: Security Hardening Before Production

- [ ] Add CSRF/origin protection for cookie-authenticated mutating VM routes. Native bearer-token
  calls are not CSRFable, but browser cookie fallback for `POST`/`DELETE` should check `Origin` or
  `Sec-Fetch-Site`.
- [ ] Add ownership tests for every mutating per-VM endpoint:
  - another user cannot `DELETE /api/vm/:id`
  - another user cannot `POST /api/vm/:id/exec`
  - another user cannot mint attach or SSH endpoints
- [ ] Add tests that raw `/api/rivet/*` actor actions are rejected without the internal header even
  for authenticated users.
- [ ] Add a secret rotation runbook for `CMUX_RIVET_INTERNAL_SECRET`. Decide whether to support a
  temporary previous-secret window for zero-downtime rotation.
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
- [ ] Replace `userVmsActor` and `vmActor` with Vercel route handlers plus database tables:
  - users
  - VMs
  - leases
  - idempotency keys
  - usage events
- [ ] Replace `userVmsActor.list` with `SELECT ... FROM vms WHERE user_id = ...`.
- [ ] Replace `userVmsActor.create` with a Vercel route handler using:
  - `Idempotency-Key`
  - a unique DB constraint on `(user_id, idempotency_key)`
  - `status = provisioning | running | failed | destroyed`
  - a provider VM id recorded once available
- [ ] Do not use Rivet for create retries. Vercel can safely retry when the request includes an
  idempotency key and the DB row is the source of truth.
- [ ] Define create retry behavior:
  - first request inserts a `provisioning` row
  - duplicate request with same idempotency key returns the existing row
  - if provider create finished, return the provider VM id
  - if create is still in progress, return `202` with a status endpoint
  - if create failed, return the recorded failure and allow an explicit new idempotency key
- [ ] Decide whether provider create stays synchronous or becomes async:
  - synchronous is simpler but depends on Vercel function duration
  - async requires a queue or background worker but avoids long HTTP requests
- [ ] Add `GET /api/vm/:id/status` or equivalent before moving long creates fully async.
- [ ] Replace actor serialization with DB correctness:
  - unique constraints for idempotency
  - row locks or advisory locks around destroy/attach/snapshot
  - conditional status transitions
  - retry-safe cleanup jobs
- [ ] Add a replacement for actor-owned cleanup:
  - expired lease cleanup
  - orphan provider VM cleanup
  - stuck provisioning cleanup
- [ ] Add a migration plan from existing Rivet actor state to Postgres if any real users create VMs
  before the removal PR lands.
- [ ] Remove Rivet env requirements after the DB-backed routes are live:
  - `RIVET_ENDPOINT`
  - `RIVET_PUBLIC_ENDPOINT`
  - `RIVET_RUNNER_VERSION`
  - `RIVET_TOKEN`
  - `RIVET_NAMESPACE`
  - `CMUX_RIVET_INTERNAL_SECRET`
- [ ] Remove `/api/rivet/**` routes after no VM code path depends on Rivet.
- [ ] Remove `rivetkit` dependency after the route migration and state migration are complete.

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
