# Remote start permissions and failure reports

An authenticated owner's explicit approve-all policy selects the Linux host
profile through `hub/vm_boundary.rs`, the same decision folder selection and
sandbox launch already consume. This covers joined machines without a fleet
registry entry. Asking starts keep their existing sandbox; the receiver can
still opt out with `vmHost: false`. Mesh receiver authority comes from a matched
sameUser grant and the hub-stamped sender, never the request body. Other mesh
grants are stamped as device requests. Nested mesh starts use the same person
check as session/new before forwarding policy.

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
`remote_new_hints.rs`, `remote_sandbox.rs`, `mesh_relay.rs`,
`mesh_control_send.rs`, `hub/harness_sandbox.rs`, and `session_liveness.rs`.
The host-profile probe checks repository metadata, isolated HOME writes, Unix
sockets and loopback TCP from the launched harness. The NIGHTLY canary still
needs a real cross-machine start, wt new, and a PR branch.
