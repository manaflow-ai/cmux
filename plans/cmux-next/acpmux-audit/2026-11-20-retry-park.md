# Retry parking before a provider handoff

`session park-retry local/SESSION --expect-revision LASTSEQ` adds a local-only, revision-checked
retry fence. It never contacts the harness or changes the failed turn. The recovery worker can
start its successor only after the receipt says `parked: true`.

Admission holds the turn lease, retry state and queue before the journal lock. A firing retry,
active turn, queued work or changed revision refuses the operation. The existing turn-scoped
`auto_resume_stopped` boundary and, when needed, `rate_limit_parked` survive restart; success
requires flush and exact-record readback. The readback stops at the newest matching journal
record, so it does not scan growing history. No new journal schema or idle task is introduced.

Detector: Rust tests matching `park_retry` exercise refusal without cancellation, queue lock
contention, timer admission, restore, rate holds, append/flush failure, CLI validation and remote
origin refusal. The protocol IR and generated clients include the unique operation; an old
daemon returns unknown method without executing a destructive fallback.
