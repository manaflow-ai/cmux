# Notice to PL-acpmux: a client's `$/cancel_request` is honored (2026-11-11)

PR #41285 (owner acpmux-outbound-volume) closes the "Known gap" in `hub/pool/mod.rs`: a
cancel used to be accepted and change nothing, so the request kept its connection slot and its
agent or peer work ran to the end.

- What changed: `server/in_flight.rs` keeps each connection's requests in flight by id, each
  entry holding its work slot. A cancel takes the entry, which frees the slot, answers -32800
  (JSON-RPC RequestCancelled) at once and drops the request's future inside the
  `request_cancel.rs` task-local scope. What the future waited on reads that scope while it is
  dropped: `agent.rs` takes its pending entry out and only then sends `$/cancel_request` to the
  agent (stdin or its agent host), `peer.rs` sends it on the link the request went out on, and
  neither sends it when the answer came first. Both keep the id (at most 1024), so the late
  answer is dropped on purpose and logged on target `acpmux::cancel`, never taken as an orphan
  or lost unlogged. `request_within` (`_acpmux/mcp_reconnect`, rename, recap) does the same, and
  drops its entry on any other drop too. The cancel arm comes before every connection class's
  notification filter, so a read-only machine, a carrier teammate and a trigger connection can
  cancel their own requests (it touches nothing else). A peer cancel frame waits for room in a
  full outbound queue instead of being dropped. A list reply (`server/list_reply.rs`), which is
  queued from inside its request, takes its entry as it is queued, under the outbound lock: a
  cancel read after that finds nothing, so a request never gets both its list and -32800.
- Cost: one map insert and remove per request on its connection, under a per-connection lock
  held for a hash-map operation; one relaxed atomic per insert and remove for
  `Hub::requests_in_flight`; one more lock taken per list reply sent. A cancelled request holds
  one remembered id until its late answer comes or 1024 newer ones push it out. A cancel spawns
  at most one short task (the cancel frame's send, or the cleanup when the pending map is busy);
  no I/O beyond the one cancel frame.
- Wire and capability: no new message; the standard `$/cancel_request {requestId}` (LSP's `id`
  is read too). New `initialize` feature `cancelRequestV2`; the old `cancelRequest` only said
  the notification is accepted. A peer link forwards a cancel only to a peer that lists
  `cancelRequestV2`. New capability `cancel-request-v1` for the app to gate its own cancels on.
- Risk: a client that cancels a request whose answer was already queued gets that answer and
  no -32800 (one terminal answer either way). An older peer ignores the forwarded cancel, so its
  work still runs to the end there; this daemon still answers -32800 and frees its side. A
  translated harness (Claude stream-json, Codex app-server) has no cancel message: its request
  is forgotten and its late answer dropped, but the harness keeps working on it. The agent-host
  path is not covered by a test yet (#41290).
- What still holds: every request gets exactly one answer (`tests/cancel_request.rs`,
  `tests/cancel_list_reply.rs`); a future dropped for any other reason (a turn handed to the next
  daemon, a timeout) behaves as before; across a real peer link the peer and its agent hear the
  cancel and free their side, and an older peer hears nothing (`tests/cancel_peer_link.rs`). The
  cancel frame carries its request's link epoch, so a reconnected link drops it (not tested
  across a reconnect).

Follow-up (review F1 and F2 of #41285): a cancel of a request sent on two paths stops whichever
copy runs on the peer (`server/dual_requests.rs` `cancel`: the copy that runs answers -32800 on
its own connection, a later copy takes that answer and never runs), and the link sends the cancel
on its shadow too when the shadow carried a copy. Cancelled ids are kept 600 s (the peer's request
deadline) and at most 1024; every id that goes is logged by name on `acpmux::cancel`, and once one
went, an answer for an unknown id logs "unknown id, possibly evicted cancel", never silence.
