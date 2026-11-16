# Cold family reads from the snapshot kin table

Owner: v2 index/list lane, PR #44477. Design: v2 architect decisions 302–310,
374, 389, 391 and 392. Leo: "even if a chat is long, there should be no
percievable difference".

A cold family page can use the ancestor-closure sidecar. `coldUnread` on the
last hot page can now be false with a snapshot present. Cold pages name hot
children and depth-64 continuations in `deeper`; a table-served page carries
optional `closure`. Old clients ignore the field and keep their per-row asks.
No defaults change. The app FFI pin must be updated after this PR merges.

## Failure and continuation contract

An optional accelerator must hand its progress and resource charges to the
fallback. Dropping either restarts a cursor or charges the same seek twice.
One ask shares 256 KiB across the snapshot seek, table pages, frames, and any
pager fallback. Cursor placement uses the seek's offset, never frames from
an equal-activity run. A table failure after verified rows returns that prefix;
a failure before any row resumes the pager at the saved position and budget.
A missing or previously disabled table preserves the position too.

An accelerator and its fallback may expose different traversal depths. The
caller must not assume that a prefix served by the closure table proves the
rest of the walk is complete. If any cold page lacks `closure`, including an
empty page, the client follows every cold key it collected during that walk.
The existing seen/asked sets remove duplicate rows and requests.

Detectors: the physical-read wrapper in `snapshot.rs`; the worst-bucket sparse
file regression in `kin_table/lookup/position_tests.rs`; the public corruption
and no-sidecar continuation tests in `cold_kin_tests.rs`; and the four mixed
page-walk regressions in `agent_session_list_source_tests.rs`.

The three reader gates compare the same eight kin (including two grandchildren)
at 20 and 11,000 snapshot rows. All registry marks remain false until exact-head
cmux-ci evidence passes. The writer gate now includes a four-way tree, and
prints the stream, closure, and page-write phase timings.
