# Remote start permissions and failure reports

An authenticated owner's explicit approve-all policy selects the Linux host
profile through `hub/vm_boundary.rs`, the same decision folder selection and
sandbox launch already consume. This covers joined machines without a fleet
registry entry. Asking starts keep their existing sandbox; the receiver can
still opt out with `vmHost: false`. Mesh receiver authority comes from a matched
sameUser grant and the hub-stamped sender, never the request body. Other mesh
grants are stamped as device requests. Nested mesh starts use the same person
check as session/new before forwarding policy.

A grant with both `sameUser` and `daemonId` admits either identity. Admission
alone therefore does not prove ownership: selecting the host profile additionally
requires a nonempty hub-stamped user equal to this machine's recorded person.
The detector `only_a_same_person_mesh_start_gets_the_full_access_host_profile`
covers mixed grants with another, missing, empty, and matching user, including
forged host-profile metadata. This keeps authorization to send a control request
from becoming authorization to execute as the machine's owner.

PR #44541 moves remote-start failure delivery onto the starter's existing durable
watch/outbox. A child denied repository or socket access cannot reliably report
its own failure through those same tools. The failure watch survives ordinary
turns and permission prompts, reads the journal from sequence zero, and stops
on blockage or closure. Recipient resolution precedes remote creation.

The existing event-driven watcher owns reconnect/restart reconciliation. No new
timer or whole-inventory scan is introduced. Refusal inspection is bounded by the
existing tool-result scan and preview limits. Shared lane projections carry the
same refusal to app rows and CLI listings.
Hub-only sources reuse the mesh read transport and address-book events; their
heartbeat carries the bounded failure reason into the same row projection.
Linked-peer watches read the returned exact id even before inventory catches up,
so a delayed list update cannot consume a failure watch as a closed chat.

Detector: remote product dogfood, hq#11835 row 21. Regression coverage lives in
`remote_new_hints.rs`, `remote_sandbox.rs`, `mesh_relay.rs`,
`mesh_control_send.rs`, `hub/harness_sandbox.rs`, and `session_liveness.rs`.
The host-profile probe checks repository metadata, isolated HOME writes, Unix
sockets, loopback TCP and a real acpmux send from the launched harness. The NIGHTLY canary still
needs a real cross-machine start, wt new, and a PR branch.
