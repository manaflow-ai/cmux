# Development backend diagnostics

Tagged DEBUG apps report real connection outcomes from `DevBackendStartup`.
`DevBackendDiagnostics` owns a private outbox of at most 100 records and drops
records older than 24 hours. Failed uploads retry every 60 seconds while the
app is alive. The next connection attempt resumes retained records after a
restart. Release builds and test hosts do not enable this sender; the normal
telemetry consent policy applies.

`https://cmux.com/api/observability/dev-backend` is independent of GCP and does
not require sign-in. The public route accepts only a bounded versioned schema
and applies `CMUX_CLOUD_DIAGNOSTICS_RATE_LIMIT_ID` before parsing. Its fixed
Axiom destination is `cmux-dev-otel-traces`, authorized by the server-only
`CMUX_DEV_BACKEND_DIAGNOSTICS_TOKEN`. Neither token nor account information is
included in the app or event. Submitted tag/revision fields are untrusted
operational observations, not authenticated identities.

The route returns an event-ID receipt only after Axiom acknowledges the full
batch. Ambiguous delivery may repeat an event; deduplicate `event_id` in
queries. `record_type == "dev_backend_app_outcome"` distinguishes these app
reports from legacy external monitor records.

For a tagged isolated app, `debug.dev_backend.check` runs the same connection
path as the Cloud panel against that app's configured backend. It accepts no
URL argument and is denied by the default remote-relay policy. Inspect the
real connection result, the app's outbox and Axiom to verify delivery.

No cron job, LaunchAgent, process scanner or independent host service is
installed by this implementation.
