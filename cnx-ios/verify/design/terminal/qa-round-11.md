# Terminal QA round 11 (termqa implementer, 2026-10-15 04:20 PT onward)

Input: qa-round-10.md (`b763a1a5`) and VERIFY-round8.md (`origin/feat-cnx-ios-termverify8` `e0789e41`).
`origin/feat-cnx-ios` was already merged (`b763a1a5` = its head). Laptop load 50-140 at the start: no
timing claims.

Code fixes for coordinator items 2, 5, 6, 7a (rendering) and 3, 4, 7b (tabs) run in two sibling
worktrees/branches, `feat-cnx-ios-termqa-render` and `feat-cnx-ios-termqa-tabs`, merged here when done.

## Status

| Item | Status | Evidence |
| --- | --- | --- |
| 1. T-LIFE-09/15 (`60dc5462`) on the rig | **green, 10 of 10**: G-D 5 runs (read1 ×2, read2 ×3), W-T 5 runs (read1 ×2, read2 ×3); top row id before = after +12 s = after +15 s in every run (OCR, GEN ids), one G-D run judged by the log only (OCR read the `seq` rows); the restore keeps the row or moves it by exactly the prune (`15721 -> 14834` with an 887-row prune). Build b0b88bc7 | `qa11/{gd,wt}-read{1,2}-*-result.json` |
| 1b. One-frame black at a reattach (new) | **found** in `wt-read2-a` (1 of 10 runs, 13 ms, at the 2nd reattach's mirror reset); **fixed in code** `aae30f1f` (red) / `af867ded`, not yet re-run | `qa11/wt-read2-a-12.19s-oneframe-black.jpg` |
| 2. One-frame black at Jump to bottom | **reduced, not zero**: wt-fling-a (b0b88bc7) 3 in 60 jumps, wt-fling-b (246ef796) 2 in 60 (round 8: 37 in 65); both blacks in b come one frame before the end's frame is placed. **Fix** `7b3ae4ec` (red) / `eec85bd4` (interim offset; the pill hides at the tap); not yet re-run. Prune while following: 0 black in 150 s, 9 prunes (wt-hold-a) | `qa11/wt-fling-b-*-jump-black.jpg` |
| 3. V5-5 / T-TABS-08 | **green 3 of 3** (idle shell): + → New Terminal, close its card: no confirmation, the Mac's `terminal list` drops it 0.52-0.55 s after the tap. Fix `efaaaf09` (red) / `1c1692c8`: the phone sends `close-terminal` after `close-surface` | `events.jsonl` `close_tab` |
| 4. T-TABS-01 inactive card | **fix `e550150f`/`c34a8576` partly works**: after a relaunch the t1 card shows the Mac's current rows (not an old frame) but **crops the bottom ~10 rows** (rows 21-52 of a screen 21..60 + marker + prompt). **New regression**: the active card draws the composer across its middle. Both sent to the render branch | `qa11/card-a-grid-*.jpg`, `qa11/grid-composer-in-card.jpg` |
| 5. ~15 s saved-frame hitch | **green on the frame log**: wt-hold-a (W-T, 150 s following at the cap): 0 frames > 100 ms (max 45.6 ms; round 8: 150-214 ms every 15.1 s). The save's main-thread part is now counted (`frame-save` 17-28 ms every 15 s, in `work_ms`): still one long frame's worth of work every 15 s | `qa11/wt-hold-a-framelog.json` |
| 6. Frame-log `blank` | **agrees with the video** in every run so far: 0 flagged where the video has 0 black (wt-hold-a 9579 frames, 9 of 10 drop runs); 1 flagged where the video had the one black frame (wt-read2-a) | |
| 7a. Saved relaunch frame hides the glyph under the cursor | fix `73500f19`/`86b86a94`, not checked on the rig yet | |
| 7b. "WireGuard TURN" while hostd says Direct | **no phone bug**: with Relay only on the path is TURN; hostd's label was wrong and is fixed in cnx-link `0b6e4f61`/`e8d42d40` (the rig's hostd `604fc689` is older). Pin test `99734367`. Also seen on the rig: hostd logs `kind=WireGuard path=Relay` while Relay only is off and the phone says "WireGuard direct" | |
| D6 Continue (coordinator) | fix `f1bc78f9` (test) / `906b9799`: one button `setup.pair-mac.cta`, label/style change only; 1 of 1 first tap advanced on b0b88bc7 (load 38). Loaded-simulator probe not run yet | |
| journey.py "Home" row (coordinator) | fixed `7949c462`: the Mac rows of kind `home` are left out | |
| 8-10 | not started | |

Other: the round-9 rig on mini-cmux10s (`~/cnx-ios-e2e/termqa-impl9`) was quit and its leftover helpers killed (coordinator note: a broad pkill there may have restarted its terminals). The shared simulator `cnx-termqa-1` was wedged (SpringBoard blocked on LaunchServices, containermanagerd not running; `simctl` install/terminate hung): shut down, **erased**, booted headless and set up again with `rigsetup.py` (new seed workspace, same names e2e-t1/e2e-t2).

## Rig

- Shared rig: `cnx-e2e-604fc689` on mini-2, simulator `cnx-termqa-1` (C906E217…). Shut down and booted
  headless at the start (the verifier's taps had timed out). The verifier's GEN loop in e2e-t2 had
  already ended (`GEN-60000`, prompt).
- Tools: `verify/termqa/q11.py` (the verifier's `v8v.py` wrapper, evidence to `qa11/`, raw video to
  `~/cnx-ios-e2e/termqa-raw/tq11/`; `q11.py install APP` installs a tagged build, launches it with
  `-CnxFrameLog YES` and opens e2e-t2). The verifier's `v8v_*.py` tools are taken as is.
- Phone builds: `~/cnx-ios-e2e/impl11/<sha>/CnxApp.app`, tag tq10 (`dev.cmux.cnx.tq10`), selected with
  `TQ_BUNDLE=dev.cmux.cnx.tq10`.
