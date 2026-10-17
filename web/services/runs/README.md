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
