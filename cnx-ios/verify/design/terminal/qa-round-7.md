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
