# Peer registry snapshots keep prompt handoff available

The peer registry used one `std::Mutex` for both lookups and mutations. A peer notice could hold
that mutex while waiting for the remote-session rows writer. Prompt handoff calls `Hub::peer`, so
the notice could park every Tokio worker behind the rows writer and leave accepted outbox sends
without a session reply.

`PeerTable` now publishes an `ArcSwap` snapshot for reads. Mutations still serialize through the
writer mutex and publish each change before taking the rows writer lock. Row projection therefore
keeps its existing ordering while peer lookups do not wait on a writer. The restored queue path
also settles only the queue entry's `(promptId, turnId)` incarnation, so a late completion cannot
remove a requeued copy of the same prompt.

Detectors:

- `a_peer_lookup_never_waits_behind_a_notice_waiting_on_the_rows_writer`
- `wedge_stale_restored_success_preserves_requeued_prompt`
- `wedge_stale_restored_failure_preserves_requeued_prompt`
- `wedge_matching_restored_success_removes_current_prompt`
- `first_acceptance_*` tests for outbox receipts that are accepted without a new turn

The changes are confined to the NEXT acpmux daemon. Classic `main` has no port because its daemon
surface is frozen separately from `feat-cmux-next`.
