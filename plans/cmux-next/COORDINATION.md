See plans/cmux-next/coordination/INDEX.md for the generated coordination ledger.

Cloud VM receiving-policy ownership and surfaces: [backend lane](coordination/backend.md).

The Cloud agent serves that public policy through its existing protected socket;
the backend lane records the VM-only surface exemption and runtime follow-up.

Verified receiving streams share the token verifier's bounded authority leases;
policy/key changes and expiry cancel both SSH copies and daemon handoffs.

The VM receiver authority owner publishes keys, policy and issuer time in one
step. Protected agent reads are fenced by owner/intent so stale replies and
failures cannot reopen or clear newer authority.

Receiving handshakes acquire bounded authority before reading a hello, so
revocation and expiry also close partial frames before service admission.
