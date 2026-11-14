# Preserve status and derived state in list projections

Detector: A0's review of the list callers, decision 211 (2026-11-14).

A v1 session row has two meanings: `status` describes the session, while `state`
can override it with `stuck` or `stopping`. Collapsing the two into one field
changes what callers observe, even when ordinary rows still round-trip.

The local and remote tee both put v1's `state` in `Summary.state`. They retain
`status` in `extra` only when it differs, including through peer masking.
`v1_row` restores both fields. Old peers without `state` use their `status`.
This changes no record layout and adds no extra field to ordinary summaries.

The class's regression detector is `list_tee::status_state_tests`: compare the
converted row against the producer's two fields for ordinary, stuck and stopping
rows, locally, remotely and after masking. Recovery from stuck must remove the
extra field and publish exactly one changed summary. The existing lifecycle
round-trip fixture continues to compare the remaining row fields.

Verification runs on hosted Linux with `cargo test -p acpmux --lib` and clippy;
the PR records the exact head and terminal receipts. There is no new list walk,
timer, workflow or default change.
