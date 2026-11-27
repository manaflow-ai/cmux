# IROH v2 backend observability

Accepted coverage: **all logical backend activity**, including successful and rejected operations, rate limits, response codes and major events. Cloudflare logs/metrics, Axiom operation events and Sentry exceptions are accepted. This is the instrumentation contract, not a claim that v2 has been deployed.

## Accepted collection plan

| Layer | Coverage |
| --- | --- |
| Cloudflare platform metrics and logs | Worker requests, duration/CPU, errors, DO/storage usage and platform failures. Keep development and production distinguishable. Confirm the exact available fields during deployment. |
| Structured operation/event stream (Axiom, adopted from Lawrence’s PR) | One completion record for every HTTP request and incoming application socket operation, plus significant server-generated events. Successes are included. Search by request/session/team context. |
| Sentry | Unexpected exceptions grouped by release and operation, with scrubbed context. Expected denials and 429s remain ordinary operation records and metrics. |
| Durable authority-change history | Enrollment, ownership change, permission removal and recovery recorded with the committed team revision. An external logging outage cannot erase the authoritative record. Reuse the required ordered change history where possible. |

Use a common operation wrapper at HTTP and socket entry points. Start a timer, validate input with Zod, check user/team/permission and limits, run the operation, validate its output, emit the result in a finally path, and return the response. Business logic and database calls add phase timings and outcome fields to that operation. Separate internal jobs create their own record. Do not double-count a Worker-routed request as two user operations: use distinct component/span IDs under one operation ID.

## Activity coverage

| Activity | Required records / metrics |
| --- | --- |
| HTTP routes and fallback calls | Route template, method, actual response status including 101/204/4xx/5xx, stable error code, latency, request bytes and response bytes where available. Record failures before DO routing too. |
| Socket requests and responses | Schema ID, message type, request ID, outcome, application error code, handler latency and response size. A socket frame has no new HTTP status; do not invent one. |
| Authentication and team access | User-auth result, membership/permission check source and latency, ticket reuse/refresh, denial reason, team mismatch and known access removal. Never log credentials. |
| Rate limits | Every checked operation records policy ID, allowed/limited result and retry delay. Every rejection includes HTTP 429 or socket rate_limited. Track counts by user and operation; do not use user IDs as unbounded metric labels. |
| Enrollment and identity | Challenge created/replaced/consumed and expiry rejection when used, registration success/conflict, approved recovery/key rotation, global ownership reservation outcome and team revision. No nonce, signature, private key or raw token. |
| Credentials | API/relay issuance and renewal outcomes, rejected authority, expiry/refresh timing and signing-key ID where safe. No credential contents. |
| Directory and metadata | Snapshot/change delivery, revision resume/gap/resync, metadata mutation and subscriber count. No direct addresses/ports or full device lists in logs. Distinguish queued, sent and client-acknowledged updates; queueing alone is not delivery proof. |
| Permission changes | Requesting user, affected team/device opaque ID, decision, committed revision and subsequent notification/closure outcome. Durable audit accompanies the mutation. |
| Socket lifecycle and output | Open/resume/reauthenticate/replacement/close, reason, queued bytes, queue-bound hit, dropped connection/resync and recipient count. Distinguish backend connection from actual IROH reachability. |
| SQLite and PlanetScale work | Read/write/transaction counts, duration, rows/bytes where available, conflict/quota/full errors, migration version/start/end/failure and ownership coordination. Never log SQL parameters or record payloads. |
| Alarms and maintenance | For features that require scheduled work: reason, due/start/finish time, rows processed and remaining work. No challenge/credential cleanup job, presence timer, or wakeup just to log that a timestamp elapsed. |
| Relay servers | Token verification outcomes, expiry/audience failures, per-user limiter result, connection lifecycle and aggregate bytes. Relays record locally without a new backend query per handshake. |
| Deployment/environment | Worker release, environment, migration version, deployment/rollback markers, branch creation/cleanup and failures. |
| Telemetry health | Export failures/timeouts, backlog/dropped-record counters and last successful export. Logging must not silently appear complete during an outage. |

Minimal common fields: timestamp, event name, component, environment, release, schema/operation ID, trace ID, request ID, optional session/connection-attempt ID, verified team and user identifiers (or stable opaque references), outcome, HTTP status when applicable, application error code and duration. Record unknown users as unauthenticated; never attribute a limit to an unverified user claim. Validate/bound correlation IDs from clients.

Full raw IPs, terminal bytes, API/relay tokens, Stack credentials, challenge nonces, signatures, request/response bodies and SQL parameter values are excluded. Format exception messages safely; field truncation alone is not redaction. Access to identifiers and audit history is restricted, with explicit retention.

## Complete coverage with bounded cost

- Capture 100% of logical operation completions and required major events in normal operation. Aggregate all counters/histograms; detailed debug traces are opt-in and separately bounded. Do not silently sample away normal successes or rate-limit events.
- Keep compact records, batch exports, compress where supported, bound export memory/concurrency/time and use background delivery. Avoid a new SQLite write for every normal log line. Critical authority history shares the existing committed mutation.
- Do not add a repeating DO timer just to flush telemetry. Use existing events or a suitable platform exporter. A telemetry request or retry still has cost; include it in usage estimates once the delivery path is selected.
- Maintain explicit log-retention and spend budgets. Under sink overload, retain durable security history and expose dropped normal telemetry. Best-effort delivery cannot guarantee a record survives every infrastructure failure; do not claim a lossless audit for ordinary logs.
- Platform-managed WebSocket ping/pong does not enter our DO handler. Use platform counters if exposed; do not add a heartbeat or wake the object merely to log protocol pings. Aggregate relay traffic rather than logging every encrypted packet.
- The backend cannot observe direct IROH connection success or terminal responsiveness by itself. App-side connect/admission/RPC timings require separate privacy-safe client telemetry. The new application sequence identifies those events; backend logs alone must not label a Mac reachable.

Recommended dashboards: operation latency/error/status mix; rate-limit hits; auth/renewal outcomes; team directory/update delivery; socket backlog/resync; SQLite/PlanetScale growth and errors; maintenance/deployment failures; relay outcomes/bandwidth; telemetry delivery health. Add alerts for sustained failure/latency increases, storage/memory pressure, mass revocation-processing failures and renewal failures near expiry. Thresholds require load measurements.

## What Lawrence’s inspected PR already provides

Cloudflare `observability.enabled = true` is set in both Wrangler configurations. Optional Axiom DO fetch events include trace ID, path, method, status and duration; alarms include outcome and duration. Sentry hooks cover Worker/DO exceptions. Socket handlers catch exceptions, but do not yet emit completion metrics for every socket operation. Axiom/Sentry secrets and actual deployed dashboards were not verified in this session.

[DO request events](https://github.com/manaflow-ai/cmux/blob/a96093decaba279eba2f1124a7830282ba3a487c/workers/presence/src/controlPlaneDo.ts#L125), [Axiom helper](https://github.com/manaflow-ai/cmux/blob/a96093decaba279eba2f1124a7830282ba3a487c/workers/presence/src/axiom.ts#L1), [Sentry helper](https://github.com/manaflow-ai/cmux/blob/a96093decaba279eba2f1124a7830282ba3a487c/workers/presence/src/sentry.ts#L1).

Dictionary: Observability makes system behavior visible through events, metrics and traces. A trace connects related operations. A metric summarizes counts or timings. A telemetry exporter sends diagnostic records to the chosen service.
