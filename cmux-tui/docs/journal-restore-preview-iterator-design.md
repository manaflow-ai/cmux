# Journal restore preview iterator design

## Problem

`Mux::journal_restore_preview` advances through the journal with repeated calls
to `session_journal_after(sequence, 1024)`. `archived_records_after` selects
archive segments and calls `decode_journal_segment` for each selected segment on
every call. When a segment contains more than one page, the same compressed
bytes are decompressed repeatedly. For `S` segments and page size `P`, the
current path can perform `O(S * ceil(R/P))` decodes for `R` archived records,
instead of `O(S)`.

## Safe design

Add an owned restore cursor on the registry reader. The cursor stores:

* the checkpoint/source sequence and the fixed target head captured at start;
* the next archive segment row in `start_sequence` order;
* one decoded segment and its record offset;
* the active-journal cursor after the last yielded record.

`next_page(limit)` consumes the cached decoded segment before selecting another
segment. A segment is decoded once, then its records are yielded in sequence
order until exhausted. It then advances to the next segment and validates
contiguity exactly as `archived_records_after` does. Active rows are read only
after archived rows are exhausted, with the existing `ORDER BY sequence ASC`
and limit.

The cursor must use one read transaction (or an equivalent SQLite snapshot)
from construction through `finish`. This preserves the current head and
ordering semantics if the writer appends while preview runs. The existing
page API remains unchanged for other callers; only restore preview uses the
cursor. Do not cache decoded segments globally, because immutable segment
replacement and connection lifetime make that cache harder to invalidate.

## Tests before implementation

1. Build a checkpoint followed by one sealed segment containing more than two
   pages of records. Run preview with a small internal page size and assert the
   concatenated result equals the one-shot reducer result, including ordering,
   `head_sequence`, and reducer counters.
2. Instrument the decoder behind a test-only counter. Assert one decode for a
   segment spanning multiple pages and one decode per segment for a multi-
   segment replay.
3. Append to the journal while preview is paused. Assert the preview uses the
   initial head snapshot and does not include the concurrent append.
4. Corrupt a segment digest or introduce a sequence gap. Assert the cursor
   fails with the same validation error as the existing page path.

SQLite's planner documentation confirms that ordered scans and `LIMIT` can
avoid unnecessary work when the order is represented by an index, but it does
not make repeated application-level decompression free. Tokio's stream model
supports an owned asynchronous iterator with state between `next` calls; the
same ownership rule applies to this synchronous SQLite cursor.
