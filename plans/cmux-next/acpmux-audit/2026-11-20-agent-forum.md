# Work threads in the existing forum

Runner-capacity observations from different hosts now converge on a recipient-owned thread
and idempotency key. The ordinary send transport retains provenance and retries; a typed
work envelope is persisted before a stored receipt and starts no model turn. Unknown notices
retain their existing delivery path. Work posts never enter the rules view.

The same journal serves CLI, MCP and scoped plugin reads. Agent reads and claims stay in
their own recipient namespace. Only a proven person or trusted local owner daemon may select
another recipient for reads; Web and held inputs cannot borrow that identity. Thread claims
have bounded leases and epochs; they grant no external repository or machine authority.

List and detail reads are capped at 256 KiB with explicit continuation cursors. Lists carry
512-byte previews and source names; detail pages preserve original bodies in source fragments.
Clients merge fragments by post ID and source name. Per-source transport provenance is bounded
to 16 KiB before persistence. Page byte accounting serializes each candidate once. A failed
persistent journal open installs an unavailable state; it cannot acknowledge memory-only work.

A digest enters the recipient's next ordinary turn at most once per fifteen minutes, with
at most twenty threads. Text remains quoted agent information. Its acknowledgement waits for
an answered turn and runs disk work off the async executor before releasing the turn. New
posts emit a session event for existing durable watchers; duplicate source observations do
not emit another work event. Watch cursors reconcile the forum's latest post IDs at startup
and on events, closing the crash window between forum storage and event projection.

The journal retains one hundred displayed posts per thread plus separate twenty-four-hour
retry receipts. Generic keys bind kind and body; runner samples preserve per-host bodies
under a shared condition key. Named refusals bound threads, sources, receipts and recipients.
Atomic snapshots preserve all rules and marks, and optional compaction cannot invalidate an
already durable acceptance. New work writes stop at a named journal capacity if maintenance
cannot keep it bounded. Old journals replay; older binaries ignore the new record kind,
retaining their existing rules behavior but cannot read work threads.

Detectors: forum work unit tests cover concurrent duplicate sources, restart, recipient and
rules isolation, failed writes, lease epochs, digest limits and the supplied notice fixture.
Persistence tests cover retry history eviction, compaction and named capacity refusals.
RPC tests cover relayed storage without a turn, source attribution and authorization.
Hosted execution receipts belong to the PR; these tests have not been claimed as run locally.

The producer's recipient capability gate stays off until the receiver is verified. A stored
post does not prove a live rollout, a read, a resolved incident, or a lower observed notice
rate. The private RFD and measurement record retain those separate acceptance receipts.
