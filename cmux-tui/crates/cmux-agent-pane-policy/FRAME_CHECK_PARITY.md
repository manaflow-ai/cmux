# Frame-check parity prerequisites

These prerequisites do not select a Rust host or change the C ABI's gesture
acceptance. `check_frame` still refuses click-only grants on a generic key or a
raw ticket. `check_frame_with_answer_tickets` is an opt-in Rust integration seam.

A host adopting the seam must consume its ticket record even on failed redemption
and verify connection identity, age, exact pick and session, current approval,
and native input provenance. A Return answer additionally needs a single-use,
non-repeating native witness for the current question. Posted input is never a
witness. The checker accepts that origin only for a known question allow with
validated answers; Return without answers stays refused at this prerequisite
stage. The trait's test double proves checker ordering, not a production host's
freshness, replay or approval implementation.

`redeemed_answer` means the verifier already consumed the ticket/input credit.
The host must not spend another click or redeem the same ticket again. The other
facts still require their ordinary path, scope, setting and harness decisions.
A structural refusal still returns its carried ticket in `spend`; the host must
discard it even though the verifier has not run. Existing deny behavior stays.

Permission questions and options publish under one lock. Each check snapshots
only the permission it names, so history growth does not increase its copy cost.
The C ABI's Pane operation gate serializes checks, observations and state calls.
Rust callers that access the raw session/options handles must serialize their
combined observations and checks themselves; independent snapshots cannot make
two separately updated sources atomic.

The underlying gap was a boolean-only rule result plus a click-only interface
that could not describe consumed native answer provenance, with independently
locked permission fields. Detectors are `frame_refusal_parity`,
`answer_ticket_boundary`, `state_snapshot` and the existing `click_only`, FFI and
parity suites. Causes contain rule/key names, not submitted answer or parameter
values. Metadata facts contain sorted names, not values.

Before any host switch, run the same native click/Return, stale connection,
expired/revoked approval, changed question, repeated/posted key, mismatched intent,
operator-stop and replay traces against Swift and the adopting host, including
refusal ticket spending and no double consumption. This change supplies neither
that host implementation nor an end-to-end parity receipt.
