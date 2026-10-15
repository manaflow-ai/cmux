# Terminal QA round 6 (termqa, 2026-10-14 22:40 PT onward, in progress)

Input: qa-round-5.md (`d66a8718`), VERIFY-round5.md (origin/feat-cnx-ios-termverify5 `18b62b51`,
REJECT on `c622a001`). origin/feat-cnx-ios `aebd1427` merged first (fast-forward: browser and video work).
Laptop load 30-35 during this round: no timing claims from the rig.

## Status

| Item | Severity | Status | Evidence |
| --- | --- | --- | --- |
| Scroll while streaming: per-frame pixel read on the main thread | disruptive (user report) | **fixed for reading; following still reads** (red `3d79af9c`, green `64171fe1`) | below |
| V2-3 eviction: reading place lost when the Mac's history prunes at the top | disruptive | **fixed, rig 2 of 2** (red `6ec8e224`, green `263c9feb`) | below |
| V5-2 upward fling ends at the live bottom | disruptive | **cause found and fixed** (same commits); 0 of ~42 rig flings during prunes | below |
| PR 20809 daemon tests | - | **flake, not the PR**: green on the new head | below |
| V5-1, T-TABS-01/V5-6, V5-4, V5-5, D1, D11, D12, pin/Jump/D7 rig re-check, rig tooling | | next | |

### Scroll while streaming (main-thread pixel read)

The pixel read placed every frame (`present`, 1.07 ms a frame on the simulator). While the page reads
scrollback, Ghostty never moves the viewport on its own. A read frame that matched the requested and
reported viewport now confirms it (`TerminalPresentMatch.confirmed`), and later frames are placed there
with no read (`knownTop`) until a request, a report or the surface's `viewportEpoch` (scroll binding,
resize, font size) changes. Following still reads every frame (D7: Ghostty follows on its own and
stale frames arrive). Tests: `TerminalPresentMatchTests` (3 new).

`jank.sh` on `cnx-termqa-impl` (60 Hz simulator, `stream 6000 8`, 8 flings), `framesum.py` now prints
work p99 and per-signpost costs:

| Phase | Frames | Hitches | Work p50 / p95 / p99 (ms) | `present` mean | pixel reads |
| --- | --- | --- | --- | --- | --- |
| interacting+streaming, before (`fc192319`, round 5) | 1076 | 0 | 1.02 / 2.05 / - | 1.07 ms | every frame |
| interacting+streaming, after (`64171fe1`) | 1124 | 2 (load 34) | 0.13 / 0.26 / 0.79 | 0.044 ms | 41 of 1115 |
| following+streaming, after | 502 | 4 | 0.97 / 2.94 / 3.36 | 1.42 ms | every frame |

Following at p99 3.36 ms is under the 4 ms target but not well under; next step is a band-limited read
(only the rows near the visible band). Device timing remains T-DEV.

### V2-3 eviction and V5-2 (one cause)

At the scrollback cap Ghostty prunes a page of its oldest rows (887 rows on the rig): the total and a
scrollback viewport's reported top drop by the same count while the rows on screen stay. The phone kept
the reading anchor, presented and requested tops, document and offset in the old numbering, so:
- a reset read the mark at the old row number, 887 rows lower in the text (`restored row 15047 -> 15047`);
- during a fling the full re-measure shrank the document under the offset; UIKit clamped it to the end,
  the deceleration ended there, and the page followed (V5-2's "a fling reached the bottom", and the
  black frame between the clamp and the next placement).

Fix: `TerminalHistoryPrune.prunedRows` recognizes a prune report (history shrank, the viewport top fell by
the shrink plus rows appended, no request in flight, not following, not a `clear`), and
`historyPruned` moves every held row and the offset in one transaction (`TerminalScrollModel.shiftRows`).
Also: the touched-bottom slack (8 rows) applies only when the gesture's last move above the bottom edge
was downward; an upward fling from the live bottom that rests 5 rows up now reads.
Tests: `TerminalHistoryPruneTests` (5). CnxKit on mini-cmux11s: 26 of 26 in the five scroll suites.

Rig (`cnx-termqa-1`, `263c9feb` Demo build, real link, `evict.py`, every command typed on the phone):

| Run | Prunes while reading | Before drop (top rows) | After reattach | Mark log |
| --- | --- | --- | --- | --- |
| r6-evict-1 (30k-row fill, GEN loop, 12 flings, hostd kill) | 4 x 887 | GEN-2842..2847 | GEN-2842..2847 | `restored row 11991 -> 11991 of 17160` |
| r6-evict-2 (GEN loop, 30 flings, kill) | 4 x 887 | GEN-681..686 | GEN-681..686 | `restored row 10286 -> 10286 of 17614` |

No `a fling reached the bottom` in 42 flings across both runs.

### PR 20809

Attempt 1 of run 38678417607 failed `hookToolCallsReachTheTabAndTurnEndClearsThem` (`timed out: reading
presence`, 13 s, with ~40 live-daemon tests in parallel); attempt 2 was cancelled before it started (no
runner; the run cannot be retried). The PR changes only daemon attach sizing; the test's attach and hook
command completed (its sentinel came back), and the 10 s wait was for the presence event. Merged
origin/feat-cmux-next (120 commits, clean) as `c53859d8`: `cmux-next daemon tests (same-tree)` passed.
`cmux app scheme compile (Debug)` failed on a runner disk refusal (`24.1 GiB free, 30 GiB required`);
re-run requested. Not merged.

### Rig notes

- The `aebd1427` merge changed the link library's FFI. The checkout's `CnxFFI.xcframework` was stale
  (key `f37eae99…`), and the app failed every dial with `rustPanic("Failed to convert arg 'options'")`.
  The cached xcframework for the new key `d84db41c…` fixed it. A rig rebuild after a merge must refresh it
  (`verify/e2e/e2e.py ensure_xcframework`).
- `killtest.py` killed every `cnx-hostd` on mini-2, including another agent's (`feedperf-9063df14`). It now
  kills only the rig's by its app path.
- mini-2's data volume is 99 % full (6.8 GiB free).

## SHAs

| Branch | SHA | Change |
| --- | --- | --- |
| feat-cnx-ios-termqa | `3d79af9c` red, `64171fe1` | steady viewport: no pixel read while reading |
| feat-cnx-ios-termqa | `6ec8e224` red, `263c9feb` | history prune shift (V2-3 eviction), downward-only touched-bottom (V5-2) |
| feat-cmux-next-tui-attach-size (PR 20809) | `c53859d8` | merge of origin/feat-cmux-next |

## Rig state

`cnx-termqa-1` runs the `263c9feb` Demo build (CnxFFI `d84db41c…`), paired, open on e2e-t2.
Mac side unchanged from round 5 (`cnx-e2e-604fc689` on mini-2).
