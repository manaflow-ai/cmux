# Cloud VM telemetry

Two sinks, both env-gated and both no-ops when unconfigured. Spans go to Axiom over OTLP/HTTP; product analytics go to PostHog over its capture API. Neither sink can fail or slow a request: span export is batched out of band by `@vercel/otel`, and every PostHog capture is fire-and-forget behind a 2s timeout.

## Axiom spans

Enabled when `AXIOM_TOKEN` and `AXIOM_DATASET` are both set (`AXIOM_DOMAIN` optional, default `api.axiom.co`; `OTEL_SERVICE_NAME` optional, default `cmux-web`). Wiring lives in `web/instrumentation.ts`; span helpers in `web/services/telemetry.ts` and `web/services/vms/telemetry.ts`.

### Route spans (`cmux.api.<METHOD> <route>`, tracer `cmux-api`)

Every authed VM route runs inside `withAuthedVmApiRoute` (`web/services/vms/routeHelpers.ts`). Routes: `/api/vm` (list, create), `/api/vm/[id]` (get, rename, destroy), `/api/vm/[id]/attach-endpoint`, `/api/vm/[id]/exec`, `/api/vm/[id]/fork`, `/api/vm/[id]/open-port`, `/api/vm/[id]/sessions`, `/api/vm/[id]/snapshot`, `/api/vm/[id]/ssh-endpoint`, `/api/vm/[id]/stats`, `/api/vm/base/open`, `/api/vm/base/reset`, `/api/vm/leases/revoke`, `/api/vm/restore`.

Common attributes: `cmux.subsystem=vm-cloud`, `http.request.method`, `http.route`, `url.path`, `http.response.status_code`, `cmux.http.response_error`, `cmux.duration_ms`, `enduser.id` (authed Stack user id). Per-stage timings appear as `cmux.vm.timing.<stage>_ms` (for example `auth`, plus create stages emitted through `web/services/vms/timings.ts`). Route-specific attributes use `cmux.vm.*`: `cmux.vm.id`, `cmux.vm.provider`, `cmux.vm.image`, `cmux.vm.memory_mb`, `cmux.vm.operation`, `cmux.vm.outcome`, `cmux.vm.port`, `cmux.vm.fork_id`, `cmux.vm.attach.*` (transport, session_id, require_daemon, daemon_available, daemon_reused, fallback, expiries).

Failures set span status ERROR with `cmux.error_name`, `cmux.error_message`, and `cmux.error_tag` (the Effect `Data.TaggedError` `_tag`, e.g. `VmProviderOperationError`, `VmLimitExceededError`).

### Provider driver spans (`cmux.vm.provider.<op>`, tracer `cmux-vm`)

Every provider SDK call (`web/services/vms/drivers/{blaxel,freestyle,e2b,daytona}.ts`) is a child span: `create`, `destroy`, `exec`, `fork`, `get_status`, `open_port`, `open_ssh`, `open_websocket_pty`, `open_attach_ssh_fallback`, `pause`, `restore`, `resume`, `revoke_ssh_identity`, `snapshot`, plus `vm.stats`. Attributes: `cmux.vm.provider`, `cmux.vm.id`, `cmux.duration_ms`, op-specific extras, and the same error attributes on failure. Wake latency is therefore readable directly off `cmux.vm.provider.resume`.

### Reconcile span (`vm.reconcile`, tracer `cmux-vm`)

`/api/cron/vm-reconcile` wraps the sweep with `cmux.vm.trigger=cron`, `cmux.vm.outcome`, and counters `cmux.vm.reconcile.{checked,updated,destroyed,skipped,no_get_status}`.

## PostHog events

Server-side, from `web/services/vms/productAnalytics.ts`. Enabled in production (`VERCEL_ENV=production`) or when `CMUX_VM_ANALYTICS_FORCE=1`; killed by `CMUX_VM_ANALYTICS_DISABLED=1`. Project key/host come from `POSTHOG_PROJECT_KEY` / `POSTHOG_HOST` (defaults in `web/services/analytics/iosEventPolicy.ts`). `distinct_id` is always the Stack user id. All events carry `schema_version`, `$insert_id`, and `$geoip_disable`; string properties are truncated to 200 chars and anything key-matching token/secret/credential/command patterns is dropped.

### Mirrored usage events (chokepoint: `VmRepository.recordUsageEvent`)

Every persisted `cloud_vm_usage_events` row is mirrored under its `eventType`, with `provider`, `image`, `plan_id`, `team_scoped`, `vm_row_id_set`, plus scrubbed row metadata:

| event | notable metadata |
| --- | --- |
| `vm.create.requested` | idempotency retry context |
| `vm.created` | provider, image, memory |
| `vm.create.failed` | `operation`, `message` |
| `vm.create.billing_failed` | `errorTag`, billing operation |
| `vm.create.credit.reserved` | `itemId`, `amount`, `customerType` |
| `vm.create.credit.granted` / `vm.create.credit.grant_failed` | grant context |
| `vm.create.credit.refunded` | `itemId`, `amount` (create failed after reserve) |
| `vm.resumed` | `source` (exec/attach/ssh/fork/open_port), `durationMs` |
| `vm.destroyed` | destroy source, incl. reconcile-observed deaths |
| `vm.forked` | source vm context |
| `vm.snapshot.created` | snapshot named or not |
| `vm.attach` | transport; `reattach` derived from `requestedSessionId` |
| `vm.ssh_endpoint` | credential kind |
| `vm.exec` | `commandLength` (never the command) |
| `vm.open_port` | port |
| `vm.base.opened` / `vm.base.reset` / `vm.base.create.failed` | base-VM lifecycle |

### Route/workflow-layer events (signals the chokepoint cannot know)

| event | properties |
| --- | --- |
| `vm.create.completed` | `outcome`, `http_status`, `duration_ms`, `provider`, `image`, `plan_id`, `memory_mb`, `timing_<stage>_ms` per create stage |
| `vm.attach.completed` | `outcome`, `http_status`, `duration_ms`, `reattach` (reconnect vs fresh), `require_daemon`, `transport` |
| `vm.wake.completed` | `provider`, `source` (triggering verb), `duration_ms` (wake latency), `reserved`; fired for every control-plane resume, including personal-plan resumes that record no usage row |
| `vm.limit_hit` | `plan_id`, `limit`, `upgrade_shown` (free-plan paywall funnel), `phase` |
| `vm.desktop.opened` | `port`, `wrapped` (`true` = noVNC desktop wrapper URL, i.e. a VNC open) |

## Dashboards cheat sheet

Create latency by stage: `vm.create.completed` `timing_*_ms`, or Axiom `cmux.api.POST /api/vm` spans by `cmux.vm.timing.*`. Wake latency: `vm.wake.completed.duration_ms` by `provider`, or `cmux.vm.provider.resume` span duration. Failure taxonomy: Axiom `cmux.error_tag` on any `vm-cloud` span; PostHog `vm.create.failed.operation`. Paywall funnel: `vm.limit_hit` → checkout events.
