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
