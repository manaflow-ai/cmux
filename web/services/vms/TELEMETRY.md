# Cloud VM telemetry

## Traces

`web/instrumentation.ts` exports directly to Axiom when both `AXIOM_TOKEN` and `AXIOM_DATASET` are set. `AXIOM_DOMAIN` defaults to `api.axiom.co`. Otherwise the existing Vercel/OTLP exporter configuration remains in effect. The Cloud priority sampler, dependency span processor and Sentry privacy filtering remain enabled.

Authenticated routes use `withAuthedVmApiRoute`. Route spans carry `enduser.id`, operation, outcome, latency, trace references and `cmux.vm.timing.<stage>_ms`. Errors retain redacted, bounded messages and cause chains; `cmux.error_tag` adds the bounded Effect error type. Freestyle provider spans measure SDK operations, including resume.

The authenticated `/api/cron/vm-reconcile` sweep records a priority `vm.reconcile` span with checked, updated, destroyed, skipped and no-get-status counters. Reconciliation still revokes model-plane credentials for missing machines.

## Product events

`productAnalytics.ts` decorates successful usage-ledger writes through `withVmProductAnalytics`. It retains the canonical `cloud_vm_*` event names, typed per-event metadata allowlists, team grouping, natural deduplication IDs and account-deletion suppression. Failed writes emit no product event. Failure and credit-bookkeeping rows remain in the ledger; request failures already flow through operational telemetry.

Ledger product events use the shared `services/analytics/serverEvents.ts` sender. It enables delivery in production or with `CMUX_SERVER_ANALYTICS_FORCE=1`, defers work past the response, uses bounded requests and retries once on transient failure. Server geolocation is disabled. Commands, credentials and arbitrary ledger metadata are never forwarded. Attach events include a `reattach` boolean without exporting the requested session ID; resume events include `duration_ms` when measured.

Existing `cloud_vm_request` events cover route outcomes and latency, and `cloud_vm_provision` events cover create/fork/restore outcomes and stage timings. These canonical events supersede the proposed duplicate `vm.create.completed` and `vm.attach.completed` events.

Supplemental signals use the same shared sender:

| Event | Properties |
| --- | --- |
| `vm.wake.completed` | provider, triggering source, duration_ms, reserved; emitted after a successful control-plane wake and durable running transition, including personal scopes |
| `vm.limit_hit` | plan_id, limit, upgrade_shown, phase; authenticated active-limit responses |
| `vm.desktop.opened` | port, wrapped; successful desktop wrapper opens |

Supplemental events also accept `CMUX_VM_ANALYTICS_FORCE=1` for development. `CMUX_VM_ANALYTICS_DISABLED=1` disables ledger product events and supplemental signals; it does not disable existing operational request/error telemetry. This preserves the current incident-reporting behavior.
