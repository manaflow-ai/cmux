# V2 connection and cursor delivery (PR #42361)

The v2 socket driver owns its outbound queue and partial-write progress. Sources
own their delivery tasks, offer without awaiting capacity, and retain a cursor
when credit stops delivery. A dropped generation frees its queued data and keeps
one bounded notice until written; a reused sid cannot accept an old task's offer.

The first v1 request may negotiate `_acpmux/v2`; the existing line codec preserves
HTTP rejection, size errors, EOF and read-ahead through the handoff. The default
`acpmux.v2` remains empty. Existing v1 components remain enabled.

Evidence is tracked in PR #42361. The release harness is
`cmux-tui/crates/acpmux/tests/v2_connection.rs`: shared small/god fixtures,
Unix streams, a continuously consuming reference reader, process peak RSS,
sequence/row equality, retained bytes, and 1-versus-256 offer timing. The chat
stopped-reader row remains unmeasured until its source exists. No passing release
measurement is claimed by this notice.

Raw JSON extension fields must be deserialized directly from their struct fields.
Serde's buffered internally tagged enum representation cannot preserve a
`RawValue`; the shared delta decoder reads the fields directly before choosing
the operation. The detector is the raw-extension delta round-trip regression,
which compares the original JSON bytes, plus live list delivery through the
connection. Linux run 43376789216 exposed this class; the next run's regression
passed after the decoder changed.

A reserved reply must transfer its reserved bytes to the queue under the same
lock as the enqueue. A synchronous request handler is not an exclusion boundary:
an actor on another runtime thread can offer between its locks. The detector is
`ordinary_reply_consumes_reserve_before_another_thread_offers`, which offers in
that interval and requires the frame to fit without dropping its subscription.

A delivery cursor and an initial viewport anchor have different lifetimes.
The anchor selects the first window; resumes carry no anchor. When retained
history is insufficient, a resume returns the head of the list view at its new
exact cursor. The detector is `expired_list_resume_and_live_lag_open_the_head`,
covering both credit-driven resume and live lag after an anchored subscription.

Returning a transport from an I/O task changes its drop lifetime. A v1 writer
must still drop its half when its last line finishes, even while request handlers
hold the outbound sender. The stream writer regressions cover that behavior;
the upgrade retains a write half only to hand it to the framed connection.
