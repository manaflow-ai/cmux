# Tabs grid: Safari parity re-audit (independent, adversarial)

**Verdict: REJECT.** Five of the fourteen audit defects still fail, and the
re-audit found four new regressions. One of them makes New Tab unusable in the
app, and another closes tabs the user only meant to drag.

This re-audit checks build `161a722c0f8f` against the Safari numbers in
[`tabs-parity-audit.md`](tabs-parity-audit.md). It uses only the Safari columns
and the audit's methodology. It changes no code.

## Setup

- **Builds.** `~/nxios-ref/tabs-reaudit/SHAS.txt` lists them.
  - App: `feat-cmux-next-ios-app` at `161a722c0f8f`. The `ios-next` tree was
    clean. Built in the Tabs scheme, Debug, on mini-cmux15 in slot `reaudit`.
  - Kit: `feat-cmux-next-tabs-kit` at `5aa0c998b11b`, the `CmuxTabsKitDemo`
    app.
  - Every artifact named `*-161a722*` comes from the app build, and every
    `*-5aa0c99*` from the kit build.
- **Device.** A dedicated iPhone 17 Pro simulator (iOS 26.5), `nx-ios-reaudit`,
  on mini-cmux15. It had 6.8 GiB free at the start. mini-cmux9s was not used
  because its load average was 39. The simulator and both remote slots were
  deleted afterwards.
- **Hosts.**
  - The mock host (`CMUX_NEXT_MOCK=1`, 5 tabs: 3 browser and 2 terminal).
    `CMUX_NEXT_MOCK_MAC_NEW_TAB=9` simulates a new tab opened on the Mac.
  - The real cmux15 host, through the test login and a direct LAN link. The
    grid had 26 to 29 tabs.
- **Input and recording.** The audit's own tools:
  - AXe `tap`, `touch`, `swipe`, `drag` and `batch`;
  - `simctl recordVideo` with real `pts_time`;
  - `ctrack.py`, `sfit.py` and `sheet.py` from `~/nxios-ref/tabs-audit/tools`.

  Tools I added, in `~/nxios-ref/tabs-reaudit/tools/`:
  - `pcmp.py` compares one of our tracks with the audit's Safari progress grids
    on a 1/60 s grid. It reports the lag at t10, t50, t90 and t99, the largest
    delta in pt, the settle time and the overshoot.
  - `tmatch.py` follows a template, for cards with no colour header on the real
    host.
  - `region.py`, `strip.py` and `darkbox.py` measure the count label and the
    fades.
- **Pass rule.** PASS needs one of two things:
  - every crossing time (t10, t50, t90, t99) within one frame (16.7 ms) of
    Safari's; or
  - the whole curve within 2 pt of Safari's.

  A behaviour that Safari has and ours lacks is a FAIL.
- **Repeat runs.** Our runs repeat to the frame. The per-frame positions are
  identical from run to run, so the spread in the timings is recorder jitter.

All artifact paths are relative to `~/nxios-ref/tabs-reaudit/`.

## Audit items D1–D14

The "Safari" column takes its numbers from `tabs-parity-audit.md`, except where
it says "re-measured". Those values were re-measured from the audit's own Safari
clips.

| # | Item | Safari | Ours (measured, runs) | Δ | Verdict | Artifacts (SHA) |
|---|---|---|---|---|---|---|
| D1 | Fling close (100 pt in 0.12 s) | The card keeps moving left at about 1170 pt/s and is gone about 295 ms after reaching x0 ≈ 102 (re-measured from `saf-swipe.mp4`, 7.123 → 7.418 s). The count changes about 10 ms after x0 ≈ 102 | 3 runs. The card is now opaque and leaves through the left edge, and the total time matches: 278–292 ms from x0 ≈ 101 to gone. But it **holds at x0 = 101.3 for 55–85 ms** (4–5 frames) after release, then moves at a constant 27.3 pt/frame (about **1640 pt/s**). It also **freezes for 3–4 frames mid-exit** (x1 = 132.7). The count changes about **205–240 ms** after x0 ≈ 101 | Up to **38 pt** behind Safari at 205 ms and 32 pt at 55 ms. The count is about 200 ms late | **FAIL** | `3-close/fling-{1,2,3}-161a722.mp4`, `fling-*.csv`, `fling-1-sheet.png`, `fling-1-zorder.png` (161a722) |
| D1 kit | Kit fling | as above | 1 run. Exits at about 20 pt/frame (≈ Safari's speed) after a **57 ms hold** (3 frames) | Hold of more than 1 frame | **FAIL** | `kit/kit-fling-5aa0c99.mp4`, `kit-fling.csv` (5aa0c99) |
| D2 | Close the last tab | A fresh Start Page appears and scales up. The audit says 0.95 → 1 over about 200 ms. Re-measured from `saf-last.mp4` (blue button width): about 0.84 → 1, resting about 275 ms after the first frame. Content is visible throughout | 3 runs. A fresh page opens and the count is 1, so the behaviour is fixed. The motion is a **blur and fade, with no scale**: the heading's x0 moves only 3 pt (20.5 → 17.5), and it is sharp about 100 ms after it first appears | No scale-up | **FAIL (motion)**; behaviour PASS | `3-close/lasttab-{1,2,3}-161a722.mp4`, `lasttab-1-sheet.png`, `saf-last-ref-sheet.png`, `saf-last-blue.csv` (161a722) |
| D2 kit | Kit last tab | as above | 1 run. A page-shaped card at about 0.96 grows to full screen within about 100 ms, but its **content is blank for about 330 ms** | Blank page for about 20 frames | **FAIL** | `kit/kit-lasttab-5aa0c99.mp4`, `kit-lasttab-sheet.png` (5aa0c99) |
| D3 | Swipe tracking (drag 100 pt over 1.0 s) | Centre −104.65 pt (−100 at the end of the finger's travel, then 2 frames of carry). The touch slop is caught up over about 80 ms, with the lift reaching scale 1.093 over the same time | 3 runs. Total **−100.0 pt**, and the tracking rate is the same (79 against 78 pt/s). The earlier −14 pt lag is gone. But the card **jumps 32–45 pt and lifts fully in a single frame**, after showing no motion while the finger moves. There is no carry after release | −4.65 pt at the end of the drag. Up to about 25 pt ahead in the first 50 ms | **FAIL** | `3-close/drag-{1,2,3}-161a722.mp4`, `drag-*.csv` (161a722) |
| D3a | **New: a slow drag closes the tab** | The same slow drag springs back | **4 of 9 identical drags closed the tab** (run 2 of the recorded set, plus 3 of 6 more runs) | Data loss | **FAIL (new regression)** | `3-close/drag-2-161a722.mp4` (161a722); the counts 5→4→3→3→3→2→2 are in the log |
| D3 kit | Kit drag | as above | 1 run. Total −100 pt, and it springs back. The onset is gradual, with no one-frame jump | −4.65 pt | **FAIL** (marginal) | `kit/kit-drag-5aa0c99.mp4`, `kit-drag.csv` (5aa0c99) |
| D3f | Right rubber band (100 pt) | x0 +36.7 pt (209.3 → 246.0); centre +44 pt | 3 runs. x0 **+36.0 pt** (209.3 → 245.3). The first frame jumps 12 pt | 0.7 pt | **PASS** (extent) | `3-close/drag-*.csv` (161a722) |
| D4 | A bar swipe that starts on ≡ or on the terminal title capsule | Switches tabs; never opens a menu | 8 runs: 3 to the right from ≡, 3 to the left from ≡, and 2 from the terminal title. Each switched tabs or rubber-banded. No menu opened and no tab closed | — | **PASS** | `6-barswipe/barswipe-{menu,left}-{1,2,3}-161a722.mp4`, `barswipe-term-{1,2}-161a722.mp4` (161a722) |
| D4 kit | Kit bar swipe from ≡ | as above | 3 runs. Three tab switches, no menu | — | **PASS** | descriptions in the log (5aa0c99) |
| D5 | New Tab from the grid (+) | (+) acts at once. The Start Page appears centred at about 0.6–0.77 scale with a blur and grows (0.34 / 0.97). About 540 ms from tap to rest | (+) is still a **Menu** (New Tab / New Terminal). **New regression: opening any menu in the grid raises the software keyboard.** For (+), the keyboard covers the menu, which is gone about 450 ms after the tap. A second tap at 0.30, 0.42, 0.50 or 0.65 s could not choose New Tab. Mock: 6 attempts; real host: 1 attempt. **No new tab could be created from the grid.** The "More" menu raises the keyboard too | Not usable | **FAIL (blocker)** | `2-newtab/newtab-{1,2,3}-161a722.mp4`, `newtab-2-tiles.png`, `newtab-2-menu.png`, `live/live-plus-1-161a722.mp4`, `shots/plus-cd.png`, `live-plus.png` (161a722) |
| D5 kit | Kit New Tab | as above | 1 run. (+) is a menu (New Note / New Tab), and it raises **no keyboard**. Choosing New Tab adds exactly **one** card (5 → 6). The page grows from the **top-left**, not from the centre, and is **blank for about 300 ms** (content at about 466 ms) | Wrong origin; blank content | **FAIL** | `kit/kit-newtab-{1,2}-5aa0c99.mp4`, `kit-newtab-2-sheet.png` (5aa0c99) |
| D5b | New Tab from inside a page (… → New Tab) | Present | The page menu has Reload, Show Keyboard, Share, Copy URL, Request Desktop Website, Open on Mac and Close Tab. **There is no New Tab** | — | **FAIL** | `shots/pagemenu.png` (161a722) |
| D6 | Long press on a card | The card lifts to about 1.06 and the others dim. The menu has Copy Link, Pin Tab, Duplicate Tab, Select Tabs, Move Tab, Close Tab and Close Other Tabs | 1 run. The card lifts to about **1.09** (177 → 193 pt) and the others dim. The menu has Copy Link, Duplicate Tab, Close Tab and Close Other Tabs. **Pin Tab, Select Tabs and Move Tab are missing.** No keyboard appears | Lift +0.03 (about 5 pt); 3 menu items missing | **FAIL** (partial) | `5-longpress/longpress-1-161a722.mp4`, `shots/lp-after.png` (161a722) |
| D6b | Long press then drag to reorder | The cards swap | 1 run (an AXe drag over 8 s). cmux and GitHub swapped | — | **PASS** | `5-longpress/reorder-1-161a722.mp4`, `shots/reorder-after.png` (161a722) |
| D6 kit | Kit long press | as above | Copy Link, Duplicate Tab, Close Tab, Close Other Tabs (the same 3 are missing) | — | **FAIL** (partial) | `shots/kit-lp.png` (5aa0c99) |
| D7 | Swipe up on the address bar opens the grid | Interactive. 2 runs: t50 49–104 ms, t99 391–442 ms, at rest 733–783 ms | 3 runs (swipe 250 pt in 0.25 s). It opens the grid every time. t50 156–174, t90 330–381, t99 429–494 ms, at rest 557–610 ms | t50 +78 to +97 ms; up to 64 pt. The input is not identical to the Safari clip's, so this delta is partly input. The behaviour now exists | **FAIL** (numbers, with an input caveat); behaviour PASS | `1-zoom/swipeup-{1,2,3}-161a722.mp4`, `1d-swipeup.png`, `.csv` (161a722) |
| D7 kit | Kit swipe up | as above | 3 runs. Opens every time; t50 +83, t90 +76 to +81 ms | as above | **FAIL** (numbers); behaviour PASS | `kit/kit-swipeup-{1,2,3}-5aa0c99.mp4`, `kit-1d.png` (5aa0c99) |
| D8 | Reflow after ✕ (mock) | 0.432 / 0.890, 0.7 pt overshoot, at rest at 550 ms. t50 119, t90 243 ms | 3 runs. Fit **0.403–0.413 / 0.926–0.940**, no overshoot, at rest at 430–432 ms. t50 102–109, t90 226–233 ms | Up to **10–16 pt** at 117 ms; t50 −11 to −17 ms; at rest about 120 ms early | **FAIL** (unchanged) | `3-close/xclose-{1,2,3}-161a722.mp4`, `3b-xreflow.png`, `.csv` (161a722) |
| D8 live | Browser ✕ reflow, **real host** | as above | 3 runs. It animates, so "a browser close doesn't animate" is not reproduced. Fit 0.38–0.41 / 0.92–0.95, at rest at 397–410 ms | Up to 11–17 pt; t50 −10 to −18 ms | **FAIL** (spring) | `live/live-xclose-{1,2,3}-161a722.mp4`, `live-3b-xreflow.png` (161a722) |
| D9 | Reflow z-order | Stacking stays fixed | 3 runs, checked frame by frame in the crossing region. "top" stays above "zsh", and HN stays under zsh | — | **PASS** | `3-close/xclose-{1,2}-cross-strip.png`, `xclose-1-zorder.png` (161a722) |
| D9 kit | Kit reflow | Stacking stays fixed, with no duplicates | 2 runs. After ✕ on the active card, the next card's **live content fades in at the closed card's slot while its own placeholder is still showing in the old slot**: two "Liquid Glass" cards for about 5 frames | Duplicate card | **FAIL** | `kit/kit-xclose-{1,2}-5aa0c99.mp4`, `kit-xclose-{1,2}-zorder.png` (5aa0c99) |
| D10 | Count label on a close | Instant swap. On ✕ it is about 1 frame before the reflow starts (re-measured, `saf-xclose.mp4`). On a fling it is about 10 ms after x0 ≈ 102 | ✕, 3 runs: a **crossfade** that starts 30–47 ms after the reflow starts and reads "4" at about 130 ms. Fling: about 205–240 ms after x0 ≈ 101 | +47 to +147 ms on ✕; about +200 ms on a fling | **FAIL** | `3-close/xclose-1-count-strip.png`, `fling-*-161a722.mp4` (161a722) |
| D11 | Zoom-in onset (card tap) | 3 runs. t10/t50/t90/t99 = 25–30 / 87–110 / 216–240 / 378–411 ms. The first frame moves 7–11 pt | 3 runs. The first frame moves **31.3 pt every run** (176.7 → 208.0). t50 68–83 ms, t90 204–223 ms | t50 −12 to −27 ms; up to 26–37 pt at 50–67 ms | **FAIL** (unchanged) | `1-zoom/zoom-161a722.mp4`, `1a-zoomin.png`, `.csv` (161a722) |
| D11 kit | Kit zoom-in | as above | 2 runs. The same 31.3 pt first frame | t50 −27 to −31 ms; up to 39–43 pt | **FAIL** | `kit/kit-zoom-5aa0c99.mp4`, `kit-1a.png` (5aa0c99) |
| D11b | First zoom after launch: stall (1f) | — | 3 fresh launches with no hold over 50 ms. The sequence is identical to later zooms | — | **PASS** | `1-zoom/firstzoom-{1,2,3}-161a722.mp4` (161a722) |
| D12 | Swipe another card during a zoom-out | Accepted (the card closes) | 3 runs. Accepted, 5 → 4 | — | **PASS** | descriptions in the log (161a722) |
| D12 kit | Kit | as above | 3 runs, 5 → 4 | — | **PASS** | (5aa0c99) |
| D13 | Mac-side new tab joins the grid | Joins with an animation | Mock: 3 runs (`CMUX_NEXT_MOCK_MAC_NEW_TAB=9`). The card fades in over about 450 ms, with no one-frame pop. Real host: 1 run (a CDP `/json/new` on cmux15). The card fades in over about 350 ms; its content is blank | Safari gives no number | **PASS** (animated) | `7-macside/mock-macnew-{1,2,3}-161a722.mp4`, `live/live-macnew-2-161a722.mp4`, `live-macnew-2-strip.png` (161a722) |
| 7b | Mac-side close | Same as the ✕ reflow | **Not testable on cmux15.** The host's Chrome for Testing acknowledges `Target.closeTarget` and `/json/close` ("success", "Target is closing") but never destroys the target, so no close event reaches the phone | — | **UNVERIFIED** (counts against approval) | `live/live-macnew-close-1-161a722.mp4` (161a722) |
| D14 | The GitHub card has no accessibility element | — | Missing from `describe-ui` in most fresh grids: the drag runs, the 2-tab setup and the more-menu check. It is present after a reorder | — | **FAIL** (intermittent) | descriptions in the log (161a722) |

## The audit's "matched" items, re-checked

| Item | Safari | Ours (measured, runs) | Δ | Verdict | Artifacts (SHA) |
|---|---|---|---|---|---|
| 1c Page → grid, button zoom | t10/50/90/99 = 26–34 / 81–87 / 183–185 / 265–266 ms; 1.4 pt undershoot | 3 runs. 16–21 / 78–91 / 186–193 / 270–275 ms; 2.0 pt undershoot | Every crossing within 1 frame (−13 to +9 ms) | **PASS** | `1-zoom/1c-zoomout.png`, `.csv` (161a722) |
| 1c kit | as above | 3 runs. Lag −11 to +8 ms | within 1 frame | **PASS** | `kit/kit-1c.png` (5aa0c99) |
| 3d Lift on a swipe | 176 → 192 (×1.093) over about 80 ms | ×1.091, but **in a single frame** (drag runs). The fling lifts over about 70 ms | Slow-drag lift about 60 ms early | **FAIL** | `3-close/drag-*.csv`, `fling-*.csv` (161a722) |
| 3g Spring back after a slow release | t50 149, t90 314, t99 513 ms; at rest at 567 ms | 2 runs (the third closed the tab, see D3a). t50 153–161, t90 335–340, t99 491–500 ms; at rest at 537–550 ms. Fit 0.63–0.64 / 0.885–0.893 | t90 **+21 to +27 ms**; up to **3.4–5.2 pt** at 233 ms | **FAIL** (marginal) | `3-close/3g-snapback.png`, `.csv` (161a722) |
| 3h Lift scale back to 1.0 | t50 133, t90 281 ms; 0.8 pt overshoot | 2 runs. t50 132–135, t90 311 ms; no overshoot | Up to 2.0–2.1 pt (on a 16 pt span, with 0.67 pt pixel steps) | **PASS** (borderline) | `3-close/3h-liftback.png` (161a722) |
| 3i Spring back after a right drag | t50 186 ms; at rest at about 468–483 ms | 2 runs. At rest at 475 ms in run 3; the run 1 onset is noisy (the card is clipped at the screen edge). Run 3: t50 −24, t90 −22 ms, up to 3.8 pt | Over 1 frame and 2 pt | **FAIL** (marginal; edge clipping) | `3-close/3i-rubber-release.png` (161a722) |
| 3k Swiped card above its neighbour during the exit | Above | 3 fling runs and the snap-back runs. It stays above the cmux card until it settles or leaves | — | **PASS** | `3-close/fling-1-zorder.png`, `drag-1-snap-zorder.png` (161a722) |
| 3l 2 → 1 (lone tab) | t10/50/90/99 = 41 / 116 / 240 / 338 ms; at rest at 433 ms; 0.6 pt overshoot | 3 runs. 36–38 / 109 / 230–234 / 351–353 ms; at rest at 402–405 ms; fit 0.415–0.419 / 0.912–0.914. It stays in the grid with "1 Tab" | Every crossing within 1 frame (−10 to +15 ms); up to 6 pt at 100 ms | **PASS** | `3-close/two2one-{1,2,3}-161a722.mp4`, `3l-two2one.png` (161a722) |
| 4a Grid flick | Native | Not re-measured | — | **UNVERIFIED** | — |
| 4b Rubber band at the top (200 pt drag) | +91 pt; back within 1 pt about 428 ms after release | 2 runs. **+92 pt**; back within 1 pt about 523 ms after release. The mid-curve is within 2 pt; at 450 ms ours is still 2.7 pt out (Safari's `vshift` has a few pt of drift) | 1 pt peak | **PASS** | `4-scroll/rubber-top-{1,2}-161a722.mp4`, `rubber-top-*-y.csv` (161a722) |
| Rapid ✕ (0.15 s apart) | Both close | 3 runs, 5 → 3 | — | **PASS** | `8-interrupt/d-rapidx-{1,2,3}-161a722.mp4` (161a722) |
| Scroll during a reflow | Accepted; no overlap | 2 runs. Accepted, the cards are laid out cleanly, 4 tabs | — | **PASS** | `8-interrupt/c-scroll-reflow-{1,2}-161a722.mp4`, `shots/c-end.png` (161a722) |
| Tap another card during a zoom-out | **Queues**: the tapped card opens about 380 ms after the tap | 8 runs. The tapped card opened in 4 and the **tap was dropped in 4**: 3 of 3 recorded runs and 1 of 5 unrecorded runs, which stayed on the grid | Lost input | **FAIL (regression)** | `8-interrupt/b-tap-zoomout-{1,2,3}-161a722.mp4`, `b-1-sheet.png` (161a722) |
| Grab a card mid snap-back or mid-exit (two 100 pt / 1 s swipes, 0.15 s apart) | The first swipe closes; the second grabs the next card mid-reflow and closes it (5 → 3) | 3 runs, 5 → 3 | — | **PASS** | `8-interrupt/a-grab-{1,2,3}-161a722.mp4` (161a722) |
| Done tapped twice, 0.1 s apart | No stuck state | 3 runs. Zooms in, then reverses to the grid; no stuck state | — | **PASS** | `8-interrupt/f-done-twice-{1,2,3}-161a722.mp4` (161a722) |

## Regressions retested

| Check | Result | Verdict |
|---|---|---|
| The dragged card stays on top until it settles | It stays above its neighbour through the snap-back and the fly-off (frame strips) | PASS |
| New Tab makes exactly one card, **on the real host** | **Could not be run.** The (+) menu raises the keyboard and hides itself on cmux15 too (`live/live-plus-1-161a722.mp4`), so New Tab cannot be chosen. The kit makes one card (5 → 6) | **FAIL (blocked by D5)** |
| The lone-tab 2 → 1 transition | Within 1 frame of Safari; no jump | PASS |
| Back to Terminals on a terminal that ended on the Mac (real host) | Zooms out to the grid cleanly in about 500 ms, with no blank frames or stuck state (`live/live-backtoterms-161a722.mp4`, `live-backtoterms-sheet.png`). The count went from 26 to 25 within 2 s, so the ended terminal was removed. That is not checked against any spec | PASS |
| Grab mid snap-back, tap during a zoom, rapid ✕, Done twice | Grab: PASS. Tap during a zoom: **FAIL** (4 of 8 taps dropped). Rapid ✕: PASS. Done twice: PASS | 1 FAIL |

## Failures, ranked by severity

1. **New Tab is unreachable in the app (new; a blocker).**
   - Opening any grid menu, (+) or More, raises the software keyboard. This
     happens on the mock and on the real host.
   - The keyboard covers the (+) menu, which is gone about 450 ms after the
     tap. New Tab could not be chosen in 7 attempts.
   - This also blocks the real-host check that New Tab makes one card.
   - (+) is still a menu, not Safari's immediate action, and the page menu
     still has no New Tab.
2. **A slow 100 pt drag closes the tab in 4 of 9 runs (new; data loss).**
   Safari springs back for this input.
3. **The fling exit still deviates.**
   - The card holds for 55–85 ms (4–5 frames) after release.
   - It then flies at about 1640 pt/s; Safari's is about 1170 pt/s.
   - It freezes for 3–4 frames in the middle of the exit.
   - Up to 38 pt off Safari's path.
   - The count changes about 200 ms late.
   - The kit holds for 3 frames.
4. **A tap on another card during a zoom-out is dropped in 4 of 8 runs (new).**
   Safari queues it. The audit found ours queued it too, on Build B.
5. **The ✕ reflow spring is unchanged (D8).**
   - Mock: 0.40–0.41 / 0.93–0.94. Real host: 0.38–0.41 / 0.92–0.95. Safari is
     0.432 / 0.890.
   - Up to 10–17 pt off at 67–117 ms.
   - Comes to rest about 120–150 ms early, with no overshoot.
6. **The zoom-in onset (D11) is unchanged.**
   - The first frame moves 31.3 pt every time, in the app and in the kit.
   - t50 is 12–31 ms early.
   - Up to 26–43 pt off in the first 67 ms.
7. **The count label (D10) crossfades late.**
   - On a ✕ close it starts 30–47 ms after the reflow and reads "4" at about
     130 ms. Safari swaps instantly, 1 frame before the reflow.
   - On a fling it is about 200 ms late.
8. **The last-tab page (D2) has no scale-up.**
   - Ours blurs in. Safari scales up from about 0.84–0.95 over about 200–275
     ms.
   - The kit's page is blank for about 330 ms.
9. **The swipe onset (D3 and 3d) jumps.**
   - The card jumps 32–45 pt and lifts fully in a single frame.
   - Safari catches up over about 80 ms, and its end carry adds −4.65 pt.
   - The marginal snap-back deltas (3g: +21 to +27 ms at t90, 3.4–5.2 pt) and
     3i (3.8 pt) are in the same family.
10. **The kit New Tab grows from the top-left** and is blank for about 300 ms.
    Safari's grows from the centre at 0.6–0.77 scale.
11. **The kit reflow shows a duplicate card for about 5 frames** when the active
    card is closed.
12. **The long-press menu lacks Pin Tab, Select Tabs and Move Tab.** The lift is
    ×1.09; Safari's is ×1.06.
13. **The swipe-up-to-grid curve (D7) works but is slower.** t50 is 78–97 ms
    late. Part of that is the input.
14. **The GitHub card's accessibility element is often missing (D14).**
15. **Mac-side close (7b) is unverified**, because cmux15's Chrome never
    destroys targets. The grid flick (4a) was not re-measured.

## Fixed since the audit

These pass:

- D4 bar swipes;
- D6b reorder;
- D9 app z-order;
- D11b first-zoom stall;
- D12 swipe during a zoom-out;
- D13 Mac-side new tab;
- the D3 tracking total (now −100 pt);
- the D3f rubber-band extent;
- D2's fresh page and count.

## State left on the test host

The real-host checks changed cmux15's test account:

- I closed three leftover Start Page and Example Domain tabs.
- I opened two tabs from the Mac side, `example.org/reaudit1` and `reaudit2`,
  and closed them from the phone. The host hides them, but Chrome still lists
  their targets, which it never destroyed.
- After Back to Terminals, the ended terminal left the list.
