# Terminal QA round 7 (termqa implementer, 2026-10-15 00:45 PT onward, in progress)

Input: qa-round-6.md (`3a634b2a`). origin/feat-cnx-ios `9b8deeb8` merged first, then `2f5ef34c` (Feed perf).
The shared rig (`cnx-e2e-604fc689` on mini-2, simulator `cnx-termqa-1`) belongs to a fresh verifier this
round: not touched. Simulator work here is on `cnx-termqa-impl` with the Demo build in `build/impl-dd`
(never `build/dd`, which `termqa-state.json` names). Laptop load 30-40: no timing claims.

## Status

| Item | Status | Evidence |
| --- | --- | --- |
| V5-6 active card crop | **fixed, simulator** (red `e2fe44ff`, green `0ad88455`) | below |
| Frame recorder consolidation (coordinator) | **done** (`b0765db8`) | below |
| D1 keyboard hide overshoot | **not reproduced** on the simulator: 30 hides, 0 reversals (`1ac1e149` scenario) | below |
| Following cost (present reads every frame) | **reduced** (red `daca9746`, green `59125147`): work p99 2.81 -> 2.22 ms | below |
| D11 no saved frame after a kill | **cause fixed** (red `0d768942`, green `58b54bdf`); rig re-check needed (live link only) | below |
| V5-5 closed tab's session lingers | **fixed** (`see SHAs`): the close path now stops the session | below |
| V5-4 new tab replays the open tab; 39 vs 42 rows | **analysed, not fixed** (Mac side) | below |
| D6 onboarding Continue | **not reproduced, not fixed** | below |
| Rig link-status reader returns "" | **fixed** (`c793f8e2`): reads the Filter button's value; mock checked, rig not run | below |

### V5-6 active card

Cause of round 6's black static card: the snapshot used `drawHierarchy(afterScreenUpdates: false)`, the
render server's copy of the page. While the grid covers the page that copy is opaque black for every view,
and the full-page joystick-thumb host then covered the whole image (the DEBUG dump `-CnxDumpCard` showed a
fully black 804 x 1748 snapshot, composer included). The IOSurface Ghostty presented was fine (1170 x 7248
BGRA, 3 % lit).

Fix (`TerminalViewController.snapshot`): fill the terminal background; draw the surface from
`TerminalSurfaceView.presentedImage()` (the presented IOSurface through Core Image) at its layer's frame,
clipped to its container; render every other subview with `layer.render(in:)`. The settled grid now shows
the active tab's snapshot (`showsStaticCard`, on by default; `-CnxLiveActiveCard` keeps the live page for
A/B). `TerminalCardCrop.bottomTrim` ends every terminal card 12 pt under the composer instead of at the
blank toolbar band. The same snapshot is the saved cold-launch frame, so that frame now carries the rows too.

Simulator (`cnx-termqa-impl`, `-cnx-demo ws-terminal-card`, mock auth): the zsh card shows the newest rows,
the prompt line and the composer at its bottom edge (`artifacts/shots/r7-active-card-static.jpg`); before,
the live page showed the page's top (`r7-active-card-live-before.jpg`). Rig check: not run (rig busy).

### Frame recorders

`CnxDesign/FrameIntervalLog.swift` now holds `FrameClock` (one shared display link), `FrameLogSwitch`
(`CNX_FRAMELOG=1` or `-CnxFrameLog`) and `FrameLogFile`. `FrameIntervalLog` (Feed windows,
`Caches/framelog.jsonl`) and `TerminalFrameLog` (per-frame ndjson, `Documents/frame-log.ndjson`) both run
on them; outputs unchanged. Checked: `-CnxTerminalDemo -CnxFrameLog` wrote 300 frame lines in 9 s;
`FrameIntervalStatsTests` 2/2 on mini-cmux11s.

### D1 (keyboard hide overshoot)

Scenario: `kbcodex.py` (demo phase `kbcodex`): a mock Codex inline TUI (`codex N`: N earlier rows, the box,
the cursor in the input row and a hint row below it, after `ESC[3J`), then 10 keyboard shows and hides,
recorded and run through `motion.py --top 110 --bottom 0.62`. The impl simulator was erased first: an
earlier `axe type` had attached a hardware keyboard, so no soft keyboard showed (never `axe type` on it).

| Document | Keyboard down / up offset | Moves | Reversals |
| --- | --- | --- | --- |
| 22 rows (shorter than the rows above the keyboard) | -116 / -106 | 131 | 0 |
| 30 rows (between the two) | -116 / 22 | 341 | 0 |
| 42 rows (taller than the page) | -112 / 214 | 381 | 0 |

The 42-row run lists 7 "flashes"; each is inside a monotonic keyboard move (shifts 73, 27, 22, 15, 12,
9, 7, 5 pt in consecutive frames), a motion.py false positive on fast moves, not a jump. D1 (round 1, 1 of
4 hides with real Codex) is not reproduced on the current code; T-SIZE-05 on the rig with real Codex decides.

### Following cost

While following, a present reads only the surface rows on screen and 16 rows each side
(`TerminalPresentMatch.readBand`); other rows are `unread` and never compared. The blank row is found once
per match (a sort) instead of a dictionary per candidate shift. Same-load A/B on `cnx-termqa-impl`, Demo
build, demo phase `follow` (`stream 3000 8`, 32 s, no touch):

| Following+streaming | Frames | Work p50 / p95 / p99 (ms) | `present` mean | `present-read` mean / p99 |
| --- | --- | --- | --- | --- |
| full read (`-CnxFullPresentRead`) | 2069 | 1.32 / 2.57 / 2.81 | 1.455 | 0.942 / 1.678 |
| band read (`59125147`) | 2074 | 1.00 / 1.98 / 2.22 | 1.061 | 0.567 / 1.011 |

Round 6 measured 3.36 ms p99 under a heavier laptop load; the A/B above is the same load. The remaining
`present` time is the match and placement (about 0.5 ms). Device timing remains T-DEV.

### D11 (saved frame after a kill)

The page's frame is saved on drawn output (since round 3), but the save ran in the same turn as the first
output batch, before Ghostty presented it: a tab whose only output was the reattach replay saved the frame
from before it. `TerminalFrameSaveSchedule`: every save waits 0.5 s after drawn output and runs at most
every 3 s. With the V5-6 snapshot the saved frame also always carries the rows (the old `drawHierarchy`
copy could be black). Needs a live link (`frameSaver` is set only for live tabs): rig re-check, kill
without backgrounding, relaunch.

### Link-status reader

`journey.link_status` opened the Filter menu and read the rig Mac's subtitle by OCR, which returned ""
on the rig. The Filter button's accessibility value is now the chosen Mac plus its presence and link line;
the reader takes it from there. Mock check: `Aziz's Mac Studio, Online` after choosing the Mac. The
transport switch also needs the link line to name the transport (`Connected over WireGuard`); not checked
without the rig.

### V5-5 (closed tab's session)

`GhosttyTerminalTabContent.host(for:in:)` released a closed tab's host but never called
`session.stop()` (the warm-set `cool` path did), so the `DaemonTerminalSession` kept its handler and, on
the next drop, logged `link dropped, waiting to reattach` for it. The close path now stops it
(`stop()` clears the handler, so `channelEnded` and `reconnect()` are no-ops). Rig re-check: close a tab,
drop the link, expect no line for its surface.

### V5-4 and the 39 vs 42 rows

- **Who holds 39 rows:** the Mac app's own pane for that terminal. Under the shared sizing contract
  (`docs/shared-terminal-sizing.md`, reducer `cmux-terminal-sizing`) the grid fits every attached view
  ("Fit everyone", `Smallest`), so the Mac pane's 39 rows win over the phone's 42. That is correct; the
  phone handles it (`DaemonTerminalSession` records `overruled` and reattaches at 53x39 without asking
  again, no PTY resize). To confirm on the rig: the Mac pane's size chip reads `53x39 · <Mac name>`.
- **V5-4:** the reset log `mirror reset cause=resized-event (rows 39, last size asked 53x42)` came while
  the grid was already 53x39 (every reattach before it logged 53x39), so the Mac sent a `resized` frame
  with an unchanged grid, and its replay reset the open tab. Hypothesis: creating a tab changes the Mac
  pane's pixel size (cell pixels) but not its grid; `hosted_stager` emits `Resized { cols, rows,
  cell_pixels }` for any change, and the phone treats every `resized` as a reset. Next: on the rig, log
  the `resized` event's cols/rows/cell pixels on the phone at a + -> New Terminal; if the grid is
  unchanged, either the daemon skips a grid-unchanged resize for mirror clients or the phone skips the
  reset when cols/rows equal the current grid (needs the daemon's `pending` semantics checked first, so
  no output is lost or doubled).

### D6 (onboarding Continue)

Read through `PairMacStep` and `SetupFlow.advance`: Continue calls `advance(from: .pairMac)`, which pushes
the next step or finishes. No code path drops the tap; the round-1 report (3 taps ignored, a 4th 20 s
later worked) is consistent with the setup plan changing under the page (`setupSteps` is
`[.team, .pairMac]` until `planSetup` runs, which waits for `asksNotifications`). Not reproduced; needs
the real onboarding with a real account (the rig's phone is paired, so a fresh simulator is required).
