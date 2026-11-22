# Running-process completeness and idle history release

Recovery review of #44174 found that `recent_values` silently dropped running rows when their
aggregate reply exceeded its byte budget, and the page retained full history after closing the
last history panel in an idle chat. The source fixes reject an incomplete running set (using the
existing paginated fallback) and trim page state before the inactive subscription early return.

Detectors: `a_recent_reply_refuses_running_rows_that_only_fit_individually`,
`a_recent_reply_keeps_every_running_row_when_ended_rows_exceed_the_budget`, and
`a_recent_reply_refuses_a_running_identity_that_cannot_fit_as_a_stub` in the Rust process page
tests; `webviews/test/process-registry-history-close.test.tsx` covers idle close, retained running
rows and late full-history responses; `process-list-pages.test.ts` checks fallback completeness
and failure propagation. These cases were added during recovery review; execution receipts are
required before claiming they pass.

The overflow fallback still temporarily reads the full history. This is a visibility/correctness
fix, not evidence that aggregate heap or wire cost is independent of history on that path. The
mock god-chat open gate does not measure the mounted page's heap, rendering or idle callbacks.
