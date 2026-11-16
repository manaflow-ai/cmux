# Remote start failure reports

PR #44541 moves remote-start failure delivery onto the starter's existing durable
watch/outbox. A child denied repository or socket access cannot reliably report
its own failure through those same tools. The failure watch survives ordinary
turns and permission prompts, reads the journal from sequence zero, and stops
on blockage or closure. Recipient resolution precedes remote creation.

The existing event-driven watcher owns reconnect/restart reconciliation. No new
timer or whole-inventory scan is introduced. Refusal inspection is bounded by the
existing tool-result scan and preview limits. Shared lane projections carry the
same refusal to app rows and CLI listings.

Detector: remote product dogfood, hq#11835 row 21. Regression coverage lives in
`remote_new_hints.rs`, `hub/harness_sandbox.rs`, and `session_liveness.rs`.
Permission-policy forwarding and receiver admission remain separate from report
transport; this change does not grant access.
