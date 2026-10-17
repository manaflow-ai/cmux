# Run API provider views

The repository rows in `repository.ts` are internal worker state. User-facing
Run snapshot and event routes pass through `view.ts`, which exposes typed
execution/provider/admission/routing fields and removes lease tokens, attach
ticket digests, provider handles, credentials, and raw provider metadata.

`cloud-vm` currently maps to the Freestyle backend. A requested Huge Blue
backend is rejected by creation with `reasonCode: adapter_not_configured` and
is represented as unavailable by the mapper; no Freestyle execution is
started on behalf of a Huge Blue request.

Routing selection is not persisted yet. If a future adapter needs a durable
requested/selected-provider value, add it to `runs` in a migration and update
`RunSnapshotView` from that column rather than encoding it in source or event
payloads.

## Attempt promotion seam

`promotion.ts` owns the authenticated mutation boundary for promoting a
successful, evidence-ready attempt. It reads an owner-scoped source, reserves
the request key and attempt atomically through `AttemptPromotionStorePort`, and
passes the existing provider VM/workspace/terminal handles to
`AttemptPromotionRuntimePort`. The runtime port is the integration seam for
the persistent Runtime repository and Freestyle workspace lifecycle; those
adapters keep provider handles internal and must preserve the stable
`sessionId`. The route returns only `PromotionView` and never provider tokens,
credentials, or raw handles.

`createRunAttemptPromotionStore()` is the current durable adapter. It uses a
private marker on the terminal attempt's result JSON, locks the tenant-owned
run and attempt during reservation, and redacts that marker from Run views.
The marker can be moved to a dedicated promotion table later without changing
the service or route ports.
