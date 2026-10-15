# Terminal QA round 8 (termqa implementer, 2026-10-15 01:45 PT onward, in progress)

Input: qa-round-7.md (`0889e650`). The shared rig (`cnx-e2e-604fc689` on mini-2, simulator `cnx-termqa-1`)
belongs to a fresh verifier: not touched. Simulator work is on `cnx-termqa-impl` (the only simulator this
implementer boots), Demo build in `build/impl-dd`. Laptop load 90-146: no timing claims.

## Status

| Item | Status | Evidence |
| --- | --- | --- |
| Two row numberings (scroll bug) | **confirmed and fixed, simulator** (red `5725bd38`, green `1be137a9`; hold red `e2cdc690`, green `71de2f83`) | below |
| V5-4 new tab replays the open tab | in progress | |
| G-17 old-SHA regression runner | not started | |
| G-14 selection limits | not started | |
| D6 onboarding Continue | not started | |
| Rig checks (V5-6, D11, V5-5, D1, selection, link reader, D10, V2-6, 60-min sessions, D7) | waiting for the rig | |

### Two row numberings

**Confirmed, and the cause is not an offset.** Demo phase `rowprobe` (`c158eea4`, DEBUG) reads rows by
each Ghostty point tag. Ghostty's C API clamps every exact point's y to the grid's last row, whatever the
tag (`ghostty-next` `src/apprt/embedded.zig`, `Point.pin`: `clamped_y = @min(self.y, screen.pages.rows -| 1)`).
On the simulator (grid 151 rows: 39 visible plus margins, scrollbar `456/305/151`):

| Read | Text |
| --- | --- |
| screen y 0 | `Last login: Mon Oct 12 0…` (row 0, correct) |
| screen y 150, 151, 152, 305, 455 | all `    Checking rand_core v…` (row 150, clamped) |
| viewport y 0, active y 0 | `cnx-ios/rust/cnx-hostd)` (row 305, correct) |

So screen y equals the scrollbar's absolute row only for the first `grid.rows` rows; every larger row
reads row `grid.rows - 1`. Round 7's "screen y 109 = row 305" was a misread of this clamp. Effects of
round 7's helpers (absolute rows passed as screen y):

- `lastNonBlankRow(from: cursor + 1, through: total - 1)` (an inline TUI's rows below the cursor) always
  read the clamped row, found text, and ended the document at the scrollback's end. After `clear` the
  document kept the active area's blank rows below the prompt: `rowprobe` before the fix logged
  `doc=0+1060` with the cursor at screen row 2 (148 blank rows below the prompt; the page showed blank
  rows with the prompt off screen).
- `TerminalReadingMark` (link-drop restore) read clamped rows for any row past the first 151, so its
  search compared against one repeated row.
- `leadingBlankRows` read at most the first 151 rows (harmless while the blank origin is above row 151).

**Fix:** `TerminalRowSpace.swift`. `TerminalAbsoluteRow` (the scrollbar's numbering) and the three
Ghostty numberings `TerminalViewportRow`, `TerminalActiveRow`, `TerminalScreenRow` are separate types;
the Ghostty ones are made only by `TerminalRowSpace` (total, grid rows, viewport top), which returns nil
for a row Ghostty cannot address (never another row). `TerminalSurfaceView` reads rows only through
`TerminalRowTextSource` (one method per type); the old Int-taking `rowText`, `lastNonBlankRow`,
`leadingBlankRows` and `screenRowsText` are gone. `TerminalRowReader` resolves an absolute row to the
active area, else the viewport, else the screen's first rows. The document end and origin scans, the
reading mark and selection read through it; the replay content check reads the active area.

A second cause of the same symptom: `TerminalEndHold` (D2) released its held end only when the cursor
was on the screen's first row. A prompt with a blank line above it (the mock shell, zsh with starship)
lands on row 2, so the end stayed at the screen's bottom. It now also releases when the cursor jumps up
by more than half the screen without the total shrinking (an inline TUI's cursor moves a few rows).

Tests: `TerminalRowSpaceTests` (6, a model of Ghostty's clamping addressing: scrollback, `clear`
without ESC[3J, ESC[3J, the mirror's blank top rows, history pruning): red 3 of 6 fail at `5725bd38`
(`clearLeavesNoContentBelowThePrompt`: end 751 instead of 603), green at `1be137a9`.
`TerminalEndHoldTests.aClearedScreenWithATwoLinePromptLetsTheEndMoveUp`: red at `e2cdc690` (end 1060
instead of 912), green at `71de2f83`. `CnxTerminalTests` 158 of 158 on mini-cmux11s.

Simulator after the fix: `rowprobe` logs `doc=0+912` after `clear` (cursor at 911), and the page shows
the remaining rows with the prompt just above the composer (`artifacts/shots/r8-clear-after-fix.jpg`).

Limit: an absolute row outside the active area, the viewport and the first `grid.rows` rows cannot be
read through the C API, so the reading mark's search beyond them falls back to the same distance from
the end (`TerminalReadingMark` step 3). Reading arbitrary rows needs a ghostty-next change (no clamp
for screen and history points); not made this round.

## Next

1. V5-4, G-17, G-14 limits, D6 (this round's list).
2. Rig checks when the rig is free.
