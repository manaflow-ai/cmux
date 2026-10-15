# Tabs grid: Safari parity re-audit 2 (independent, adversarial)

**Verdict: REJECT.** The previous blocker is fixed: menus no longer raise the
keyboard, and New Tab works, including on the real host. Slow drags no longer
close tabs. But a long press then a leftward drag-to-reorder **closes the
dragged tab when it is dropped**, in 3 of 3 app runs and 2 of 2 kit runs.
A swipe that Safari commits now springs back. The fling, the reflow and
several other curves are still more than one frame or 2 pt off Safari.

This re-audit checks app build `8d33469098cd` and kit build `f085ad3509d4`
against the Safari numbers in [`tabs-parity-audit.md`](tabs-parity-audit.md).
It retests every failure in [`tabs-parity-reaudit.md`](tabs-parity-reaudit.md).
It uses only the Safari columns, the Safari clips in `~/nxios-ref/tabs-audit/`
and the audit's method. It changes no code.

## Setup

- **Builds.** `~/nxios-ref/tabs-reaudit-2/SHAS.txt` lists them.
  - App: `feat-cmux-next-ios-app` at `8d33469098cd`, with a clean `ios-next`
    tree. Built with the Tabs scheme, Debug, on mini-cmux15 in slot
    `reaudit2`. Every `*-8d33469*` artifact comes from this build.
  - Kit: `feat-cmux-next-tabs-kit` at `f085ad3509d4`, a clean
    `Packages/iOS/CmuxTabsKit`, built as the `CmuxTabsKitDemo` app. Every
    `*-f085ad3*` artifact comes from this build.
- **Device.** A dedicated iPhone 17 Pro simulator, `nx-ios-reaudit2`, on
  mini-cmux15. mini-cmux15 had 5.2 GiB free at the start. mini-cmux9s had a
  load average of 29 to 47, so it was not used.
  - The simulator is headless, so it has no hardware keyboard. Focusing the
    address field raised the software keyboard (`shots/kbcheck.png`).
  - The simulator and both remote slots were deleted afterwards.
- **Hosts.**
  - The mock host (`CMUX_NEXT_MOCK=1`) had 5 tabs: 3 browser and 2 terminal.
  - The real cmux15 host was reached through the test login over a direct
    LAN link. Its grid had 13 tabs at the start.
- **Input and recording.** AXe `tap`, `touch`, `swipe`, `drag` and `batch`.
  Recordings use `simctl recordVideo`, with each frame's real `pts_time`.
- **Tools.** These are in `~/nxios-ref/tabs-reaudit-2/tools/`:
  - the audit's `ctrack.py`, `sfit.py` and `sheet.py`;
  - the first re-audit's `pcmp.py`, `tmatch.py`, `region.py` and `strip.py`;
  - new: `tcmp.py` (onset-aligned delta), `ecmp.py` (delta aligned where the
    finger ends), `x1cmp.py` (page-edge reach times), `snap.sh` and
    `maxsnap.sh` (`pcmp.py` from a release point).
- **Pass rule.** This is the first re-audit's rule. An item passes when every
  crossing (t10, t50, t90 and t99) is within one frame (16.7 ms) of Safari's,
  or when the whole curve is within 2 pt of Safari's. A behaviour that Safari
  has and ours lacks is a FAIL. With several runs, one failing run fails the
  item.

All artifact paths are relative to `~/nxios-ref/tabs-reaudit-2/`. Safari
references are in `~/nxios-ref/tabs-audit/` (written `audit:`).

## Audit items D1–D14 and the first re-audit's failures

| # | Item | Safari | Ours (measured, runs) | Δ | Verdict | Artifacts (SHA) |
|---|---|---|---|---|---|---|
| D1 | Fling close (AXe swipe of 100 pt in 0.12 s) | Re-tracked from `audit:3-close/saf-swipe.mp4`. No hold. The card leaves at about 20 pt/frame (about 1170 pt/s) and is gone 295 ms after x0 ≈ 102 | 3 runs, 5 → 4 each time. The card **holds at x0 101–103 for 4 frames (about 60 ms)** after release. It then moves at 20.6–21.3 pt/frame (1240–1280 pt/s), which is close to Safari's speed. It **freezes for 2–3 frames mid-exit**, at the same frame as the count swap. Gone 298–325 ms after x0 ≈ 102 | Aligned at release (x1 ≤ 296): **37–54 pt** behind Safari between +50 and +200 ms | **FAIL** | `3-close/fling-{1,2,3}-8d33469.mp4`, `fling-*.csv`, `saf-fling-crop.csv` (8d33469) |
| D1 kit | Kit fling | as above | 3 runs, 5 → 4. **Holds for about 80 ms** (5 frames), then moves at about 25 pt/frame. The flung card passes **under** its left neighbour (Springs) | Hold over 1 frame; z-order wrong | **FAIL** | `kit/kit-fling-{1,2,3}-f085ad3.mp4`, `kit-fling-1-strip.png` (f085ad3) |
| D2 | Close the last tab | `audit:3-close/saf-last.mp4`, re-tracked by the page edge. The lone card turns into the Start Page **in its own slot at about 0.67 width**, then zooms to full screen. 500 ms from the first frame to rest | 3 runs. A fresh page opens and the count is 1, with no blank frames. The page **first appears at 0.84 width** (x 32 → 369) and reaches rest in **323 ms**. Aligned at 0.84 width, the edge tracks Safari's within about 1.5 pt and settles about 80 ms early | At Safari's first frame the page is 70 pt wider (35 pt per edge). The 0.67 → 0.84 phase is missing | **FAIL** (motion); behaviour PASS | `3-close/lasttab-{1,2,3}-8d33469.mp4`, `lasttab-1-sheet.png`, `lasttab-*.csv`, `saf-last-page.csv`, `saf-last-check.png` (8d33469) |
| D2 kit | Kit last tab | as above | 3 runs. Content shows from the first frame. The page scales from about 0.86. About 425 ms after the first frame, the page content **jumps down 16 pt in one frame** (y 128.7 → 144.7) in all 3 runs | One-frame jump | **FAIL** | `kit/kit-lasttab-{1,2,3}-f085ad3.mp4`, `kit-lasttab-1-sheet.png` (f085ad3) |
| D3 | Swipe tracking: AXe drag of 100 pt over 1.0 s | Centre −104.65 pt: −100 at the end of the finger, then about 2 frames of carry. The lift reaches ×1.09 over about 80–90 ms | 9 runs. Total **−100.0 pt** every run, with no carry. Aligned where the finger ends, the tracking is within 0.2–4.3 pt for the whole drag. The one-frame jump of 32–45 pt is gone: the first frames move 3, 6 and 6 pt. The lift is ×1.09 over about 97 ms (177 → 193) | −4.65 pt at the end. After release: +2.3 to +3.0 pt at +100 ms, and **+5.5 to +14.4 pt at +200 ms** (ours holds, then springs back early) | **FAIL** (end carry, post-release) | `3-close/drag-{1..9}-8d33469.mp4`, `drag-*.csv` (8d33469) |
| D3a | **A slow drag closes the tab** (first re-audit: 4 of 9) | Springs back | **0 of 18.** 9 relaunched runs and 9 back-to-back runs on one grid all sprang back (5 Tabs each time) | — | **PASS** (fixed) | `3-close/drag-runs.log`, `drag-{1..9}-8d33469.mp4` (8d33469) |
| D3-commit | **New: AXe swipe of 100 pt over 1.0 s** (the audit's 3e and grab input) | Commits: the card leaves left on release (re-tracked from `audit:8-interrupt/saf-a-grab-snapback.mp4`; it held at x0 101.3, then released at 98 → 0) | 3 runs. Holds at x0 101.3 with the same input, then **springs back** (5 → 5). The first re-audit's build closed tabs with this input | A different commit decision | **FAIL** (regression against the first re-audit's 5 → 3) | `3-close/swipe1s-{1,2,3}-8d33469.mp4` (8d33469) |
| D3 kit | Kit drag | as above | 9 runs, all spring back. Total **−92 pt** (x1 386 → 297.3) | −12.65 pt | **FAIL** | `kit/kit-drag-{1,2,3}-f085ad3.mp4`, `kit-drag-*.csv` (f085ad3) |
| D3f | Right rubber band (100 pt) | x0 +36.7 (209.3 → 246.0) | 3 runs. x0 +36.7 (209.3 → 246.0) | 0 pt | **PASS** | `3-close/rdrag-{1,2,3}-8d33469.mp4`, `.csv` (8d33469) |
| D4 | A bar swipe that starts on ≡ or on the terminal title | Switches tabs; never opens a menu | 8 runs: 3 right and 3 left from ≡, and 2 from the terminal bar. Each switched tabs; no menu opened | — | **PASS** | `6-barswipe/barswipe-{menu,left}-{1,2,3}-8d33469.mp4`, `barswipe-term-{1,2}-8d33469.mp4` (8d33469) |
| D4 kit | Kit bar swipe from ≡ | as above | 3 runs. Rubber band on the first tab; no menu | — | **PASS** | descriptions in the log (f085ad3) |
| D5 | New Tab from the grid (+) | (+) acts at once. The Start Page appears centred and blurred, and grows. Re-tracked page edge (x1) after it passes 385: reaches 395 / 398 / 400 / 401.3 / 402 at **48 / 80 / 130 / 182 / 295 ms**; x1 is 398.7 at +100 ms | (+) is **still a Menu** (New Terminal / New Tab). **No keyboard** rises for (+), More, ≡ or the long-press menu. Choosing New Tab: 3 mock runs, 5 → 6 each time. The page now appears **centred and blurred** at about 0.69 width. Edge reach times: **130–160 / 153–190 / 190–223 / 257–272 / 345–365 ms**; x1 is 392.0 at +100 ms | Tail 60–93 ms slower; **6.7 pt** behind at +100 ms on the right edge (13 pt in width). (+) needs a second tap | **FAIL** (menu, tail); the origin and the look now match | `2-newtab/newtab-{1,2,3}-8d33469.mp4`, `newtab-1-sheet.png`, `newtab-*-b.csv`, `saf-new-page.csv`, `plus-probe-8d33469.mp4`, `shots/plus-after.png`, `shots/moremenu.png` (8d33469) |
| D5 live | New Tab on the **real host** | One card | 13 → 14, stable after another 5 s; one new Start Page card; no keyboard. Repeated 3 more times, +1 each time | — | **PASS** | `live/live-newtab-1-8d33469.mp4`, `live/baseline-tabs.txt`, `after-newtab-1.txt` (8d33469) |
| D5 kit | Kit New Tab | as above | 3 runs, 5 → 6. (+) is a menu (New Note / New Tab). The page now has content from the first frame, but it grows from an **off-centre, upper-right** position at about 0.8 scale, sharp and with **no blur** | Wrong origin and look | **FAIL** | `kit/kit-newtab-{1,2,3}-f085ad3.mp4`, `kit-newtab-1-sheet.png` (f085ad3) |
| D5b | New Tab from inside a page (… → New Tab) | Present | The page menu has Reload, Show Keyboard, Share, Copy URL, Request Desktop Website, Open on Mac and Close Tab. **No New Tab** | — | **FAIL** | `shots/pagemenu.png` (8d33469) |
| D6 | Long press on a card | Lift about ×1.06; the others dim; the menu has Copy Link, Pin Tab, Duplicate Tab, Select Tabs, Move Tab, Close Tab and Close Other Tabs | 3 runs. Lift **×1.062** (177 → 188); the others dim; no keyboard. The menu has only Copy Link, Duplicate Tab, Close Tab and Close Other Tabs | **Pin Tab, Select Tabs and Move Tab are missing** | **FAIL** (partial; the lift is fixed) | `5-longpress/longpress-{1,2,3}-8d33469.mp4`, `shots/lp-after.png` (8d33469) |
| D6 kit | Kit long press | as above | 1 run. **No lift** (176.7 → 177.3); the others dim; the same 4 items | No lift; 3 items missing | **FAIL** | `kit/kit-longpress-1-f085ad3.mp4`, `shots/kit-lp.png` (f085ad3) |
| D6b | **Long press then drag to reorder, including the drop** | The cards swap and both tabs stay | **Leftward (GitHub → cmux slot), 3 of 3 runs:** the long press opens the menu, the drag dismisses it, the lifted card reorders (cmux moves to slot 2), and **on the drop the dragged card flies off to the left and the tab closes (5 → 4)**. Vertical and rightward reorders keep 5 tabs (1 run each) | Data loss | **FAIL (new; blocker)** | `5-longpress/reorder-lp-{1,2,3}-8d33469.mp4`, `reorder-lp-1-sheet.png`, `shots/reorder-lp-after.png`, `reorder-lp-1-drop-strip.png`, `reorder-vert-8d33469.mp4`, `reorder-right-8d33469.mp4` (8d33469) |
| D6b kit | Kit reorder, leftward drop | as above | 2 of 2 runs closed the dragged tab (5 → 4) | Data loss | **FAIL** | `kit/kit-reorder-left-{1,2}-f085ad3.mp4` (f085ad3) |
| D7 | Swipe up on the address bar opens the grid | `audit:1-zoom/out-swipe.csv`. 2 runs: t10/50/90/99 = 8–37 / 49–104 / 273–313 / 391–442 ms | 3 runs (swipe 250 pt in 0.25 s), each opens the grid. 2 / 25–72 / 360–375 / 469–485 ms. After the finger lifts, the page **hovers at about 241 → 238.7 pt wide for 100–170 ms** before it springs | t90 **+62 to +77 ms**, t99 +47 to +62 ms; up to 30–48 pt after the first 3 frames. The input is not identical to Safari's | **FAIL** (numbers, with an input caveat); behaviour PASS | `1-zoom/swipeup-{1,2,3}-8d33469.mp4`, `1d-swipeup.png`, `.csv` (8d33469) |
| D7 kit | Kit swipe up | as above | 3 runs; opens each time. t90 +42 to +64, t99 +34 to +71 ms | as above | **FAIL** (numbers) | `kit/kit-swipeup-{1,2,3}-f085ad3.mp4`, `kit-1d.png` (f085ad3) |
| D8 | Reflow after ✕ (mock) | 0.432 / 0.890, 0.7 pt overshoot, at rest at 550 ms. t10/50/90/99 = 42 / 119 / 243 / 343 ms | 3 runs. Fit **0.426–0.428 / 0.903–0.905** (rms 0.27–0.36 pt). 34 / 107 / 228–231 / 349–366 ms. **No overshoot**; at rest at 398–415 ms | Lag −8 / −12 / −11 to −15 / **+5 to +22** ms. Up to **11.8 pt at 117 ms**. At rest about 140 ms early | **FAIL** (marginal: run 1 t99 +22 ms; 11.8 pt) | `3-close/xclose-{1,2,3}-8d33469.mp4`, `3b-xreflow.png`, `.csv` (8d33469) |
| D8 live | Browser ✕ reflow, **real host** | as above | 1 clean run (template track). It animates. 34 / 108 / 244 / 352 ms; at rest at 400 ms; no overshoot | Lag −8 / −12 / +1 / +8 ms; up to 11.3 pt at 117 ms | Crossings PASS; overshoot and rest FAIL (1 run) | `live/live-xclose-1-8d33469.mp4`, `live-xclose-1-x2.csv`, `live-3b.png` (8d33469) |
| D8 kit | Kit reflow after ✕ | as above | 3 runs. The reflowing card **jumps 33 pt in its first frame**. 3 / 90–92 / 214–216 / 325–352 ms; at rest at 383–385 ms | t50 −27 to −29 ms; up to **26–31 pt** | **FAIL** | `kit/kit-xclose-{1,2,3}-f085ad3.mp4`, `kit-3b.png` (f085ad3) |
| 3a kit | Kit ✕: the closed card | Fades and scales down | 3 runs. The closed card **vanishes in one frame** (0.977 → 0.997 s); only its title fades | No fade or scale | **FAIL** | `kit/kit-xclose-1-pre.png`, `kit-xclose-1-strip.png` (f085ad3) |
| D9 | Reflow z-order | Stacking stays fixed | 1 run checked frame by frame across the crossing: HN stays above GitHub, and zsh above HN. No swap | — | **PASS** | `3-close/xclose-1-cross-strip.png`, `xclose-1-sheet.png` (8d33469) |
| D9 kit | Kit reflow: no duplicate card | No duplicates | 3 runs. Always 4 cards; no duplicate seen. The unvisited cards are blank placeholders, which weakens this check | — | **PASS** (weak) | `kit/kit-xclose-1-strip.png` (f085ad3) |
| D10 | Count label on a close | ✕: an instant swap 1 frame (17 ms) before the reflow starts (`audit:3-close/saf-xclose.mp4`: label at 1.1417 s, motion at 1.1583 s). Fling: about 10 ms after x0 ≈ 102 | ✕, 3 runs: now an **instant swap**, but **47–48 ms (3 frames) before** the closed card and the reflow start to move. Fling: about 105–115 ms after the hold ends, which is about 165 ms after release | ✕ +30 ms; fling about +100 to +155 ms | **FAIL** | `3-close/xclose-*-8d33469.mp4` (region.py, label box 170,684–232,710), `fling-*-8d33469.mp4` (8d33469) |
| D11 | Zoom-in onset (tap a card) | The first frame moves 7–11 pt | 3 runs. The first frame moves **7.3 pt** (176.7 → 184.0), then 17 and 21 pt | — | **PASS** (fixed) | `1-zoom/zoom-{1,2,3}-8d33469.mp4`, `.csv` (8d33469) |
| 1a | Zoom-in curve | 3 runs: 25–30 / 87–110 / 216–240 / 378–411 ms; mean 27 / 95 / 227 / 401 | 3 runs: 27–36 / **112–116 / 245–248** / 414–417 ms; at rest at 598–602 ms | Against the Safari mean: t50 **+17 to +21**, t90 **+18 to +22** ms; up to 9–21 pt. Within 8 ms of Safari's slowest run (safB) | **FAIL** (marginal; now slightly slow) | `1-zoom/1a-zoomin.png`, `.csv` (8d33469) |
| D11 kit | Kit zoom-in | as above | 3 runs. The first frame moves 8 pt. Against the mean, runs 1 and 2 are within 1 frame (+3 to +12 ms); run 3 has t90 **+18 ms** and 15 pt | 1 of 3 over 1 frame | **FAIL** (marginal) | `kit/kit-zoom-{1,2,3}-f085ad3.mp4`, `kit-1a.png` (f085ad3) |
| D11b | First zoom after a fresh launch | No stall | 3 fresh launches. The longest hold before 395 pt is 17–18 ms (1 frame) | — | **PASS** | `1-zoom/zoom-*.csv` (8d33469) |
| D12 | Swipe another card during a zoom-out | Accepted (closes) | 3 runs, 5 → 4 | — | **PASS** | `8-interrupt/e-swipe-zoomout-{1,2,3}-8d33469.mp4` (8d33469) |
| D12 kit | Kit | as above | 3 runs, 5 → 4 | — | **PASS** | descriptions in the log (f085ad3) |
| D13 | A Mac-side new tab joins the grid | Joins with an animation | Mock: 3 runs (`CMUX_NEXT_MOCK_MAC_NEW_TAB=9`); the slot fades in over about 420 ms with no one-frame pop. Real host: 1 run (CDP `PUT /json/new` on cmux15). Count 15 → 16, and the card fades in over about 450 ms. It lands in the last row, mostly under the bottom toolbar | Safari gives no number | **PASS** (animated) | `7-macside/mock-macnew-{1,2,3}-8d33469.mp4`, `live/live-macnew-1-8d33469.mp4`, `live-macnew-1-sheet.png` (8d33469) |
| D14 | The GitHub card's accessibility element | Present | Missing from `describe-ui` in most grids after a close or reorder (the two-tab setup, the reorder runs, scroll during a reflow, the New Tab result). Present on the fresh 5-tab grid | — | **FAIL** (intermittent) | descriptions in the log (8d33469) |

## The audit's "matched" items, re-checked

| Item | Safari | Ours (measured, runs) | Δ | Verdict | Artifacts (SHA) |
|---|---|---|---|---|---|
| 1c Page → grid, button zoom | 26–34 / 81–87 / 183–185 / 265–266 ms; 1.4 pt undershoot | 3 runs. 15–21 / 78–91 / 190–193 / 272–276 ms; 2.0 pt undershoot | Every crossing within 1 frame (−14 to +10 ms) | **PASS** | `1-zoom/1c-zoomout.png`, `.csv` (8d33469) |
| 1c kit | as above | 3 runs. −12 to +7 ms | within 1 frame | **PASS** | `kit/kit-1c.png` (f085ad3) |
| 3d Lift on a swipe | 176 → 192 (×1.093) over about 80–90 ms | 9 drag runs. ×1.09 over about 97 ms (176.7 → 180.7 → 185.3 → 188.7 → 192.0 → 192.7) | About 1 frame | **PASS** (fixed) | `3-close/drag-*.csv` (8d33469) |
| 3g Spring back after a slow release | t10/50/90/99 = 50 / 149 / 314 / 513 ms; at rest at 567 ms | 9 runs. 41–50 / 138–149 / 305–316 / 490–494 ms; at rest at 550–568 ms | t10–t90 within 1 frame. t99 **−21 to −23 ms**; up to 1.0–5.4 pt at 83–117 ms | **FAIL** (marginal) | `3-close/3g-snapback.png`, `.csv` (8d33469) |
| 3g kit | as above | 3 runs. t99 −18 to −38 ms; up to 1.1–6.9 pt | as above | **FAIL** (marginal) | `kit/kit-3g.png` (f085ad3) |
| 3h Lift scale back to 1.0 | t50 133, t90 281 ms; 0.8 pt overshoot | 9 runs. t50 117–141, t90 291–326 ms; 0.7 pt overshoot | The whole curve within **1.4–1.9 pt** (16 pt span, 0.67 pt pixel steps) | **PASS** | `3-close/3h-liftback.png`, `.csv` (8d33469) |
| 3i Spring back after a right drag | t10/50/90/99 = 43 / 186 / 336 / 535 ms | 3 runs. 54–62 / 174–186 / 345–360 / 456–475 ms | Up to 1.6 / **2.3** / 1.5 pt | **FAIL** (marginal: run 2 is 0.3 pt, under one 0.67 pt pixel step, over the limit) | `3-close/3i-rubber-release.png`, `rdrag-*.csv` (8d33469) |
| 3k Swiped card above its neighbour during the exit | Above | Drag and fling: GitHub stays above cmux through the snap-back and the exit | — | **PASS** | `3-close/drag-1-zorder.png`, `fling-1-zorder.png` (8d33469) |
| 3k kit | Above | Drag and fling: the dragged card is **under** its neighbour | — | **FAIL** | `kit/kit-drag-1-zorder.png`, `kit-fling-1-strip.png` (f085ad3) |
| 3l 2 → 1 (lone tab) | 41 / 116 / 240 / 338 ms; 0.6 pt overshoot | 3 runs. 35–36 / 109–110 / 231–234 / 351–353 ms; 0.6 pt overshoot. Stays in the grid with "1 Tab" | −6 to +15 ms; up to 5.4–5.9 pt | **PASS** | `3-close/two2one-{1,2,3}-8d33469.mp4`, `3l-two2one.png` (8d33469) |
| 4a Grid flick | Native | Not re-measured | — | **UNVERIFIED** | — |
| 4b Rubber band at the top (200 pt drag) | +91 pt; at rest about 560 ms after release | 2 runs. **+93.3 pt**; back within 1 pt 567 and 598 ms after the peak | 2.3 pt peak | **FAIL** (marginal) | `4-scroll/rubber-top-{1,2}-8d33469.mp4`, `.csv` (8d33469) |
| Rapid ✕ (0.15 s apart) | Both close | 3 runs, 5 → 3 | — | **PASS** | `8-interrupt/d-rapidx-{1,2,3}-8d33469.mp4` (8d33469) |
| Scroll during a reflow | Accepted; no overlap | 2 runs. Accepted; 4 tabs laid out cleanly | — | **PASS** | `8-interrupt/c-scroll-reflow-{1,2}-8d33469.mp4`, `shots/c-end.png` (8d33469) |
| Tap another card during a zoom-out | Queues. From the zoom-out start, the tapped card starts to grow at about 470–570 ms and is full at about 770 ms (`audit:8-interrupt/b-saf.png`) | **8 of 8 queued** (HN opened every time). 3 recorded runs: it starts to grow at +550 / +550 / +687 ms and is full at +993 to +1163 ms | Behaviour fixed; full screen 220–390 ms later | **PASS** (queueing); timing slower | `8-interrupt/b-tap-zoomout-{1,2,3}-8d33469.mp4`, `b*-hn.csv` (8d33469) |
| Tap during a zoom-out, kit | Queues | 3 of 3 queued | — | **PASS** | descriptions in the log (f085ad3) |
| Grab a card mid snap-back or mid-exit (two 100 pt / 1 s swipes, 0.15 s apart) | The first swipe closes; the second closes the next card (5 → 3) | 3 runs, **5 → 5**: neither swipe commits (see D3-commit) | Commit lost | **FAIL** (regression) | `8-interrupt/a-grab-{1,2,3}-8d33469.mp4` (8d33469) |
| Done tapped twice, 0.1 s apart | No stuck state | 3 runs. Zooms in, then reverses to the grid about 600 ms later; no stuck state | — | **PASS** | `8-interrupt/f-done-twice-{1,2,3}-8d33469.mp4`, `f-done-1-sheet.png` (8d33469) |

## Regression probes

| Probe | Result | Verdict |
|---|---|---|
| Menus raise the keyboard | (+), More, ≡ and the long-press menu: no keyboard in any run, on the mock or the real host | PASS (fixed) |
| Slow drags close tabs | 0 of 18 | PASS (fixed) |
| The dragged card stays on top | App: yes. Kit: no; it passes under its neighbour | App PASS, kit FAIL |
| The lone-tab 2 → 1 | Within 1 frame of Safari | PASS |
| Back to Terminals, real host, on a terminal that ended on the Mac | Zooms out cleanly (about 300 ms). The ended card then fades out and the grid reflows, 16 → 15. No blank frames | PASS (`live/live-backtoterms-8d33469.mp4`, `live-backtoterms-sheet.png`) |
| **New: ✕ on a terminal that ended on the Mac, real host** | The card animates out and the grid reflows. Then a banner reads "Couldn't close the terminal: terminal s7 ended on the Mac", and **the card returns**. The tab cannot be closed from the grid | FAIL (`live/live-xclose-3-8d33469.mp4`, `live-xclose-3-sheet.png`) |
| Interruptions | Grab mid snap-back: FAIL (no commit). Tap during a zoom: PASS. Rapid ✕: PASS. Done twice: PASS | 1 FAIL |
| Long press, then a drag reorder, including the drop | A leftward drop closes the dragged tab (3/3 in the app, 2/2 in the kit) | FAIL |
| Toolbar swipe | No menus; tabs switch | PASS |

## Failures, ranked by severity

1. **A long-press reorder closes the dragged tab on the drop (new; data loss;
   a blocker).**
   - Long press GitHub, then drag it left onto cmux's slot (AXe drag of
     197 pt over 6 s in 6 steps). The menu opens, the drag dismisses it and
     the cards reorder.
   - On the drop, the dragged card flies off to the left and the tab closes
     (5 → 4). This happened in 3 of 3 app runs and 2 of 2 kit runs.
   - Vertical and rightward reorders keep the tab.
   - The drop seems to run the swipe-to-close commit on the drag's leftward
     translation.
2. **The ✕ on a terminal that ended on the Mac fails on the real host.** The
   card animates out, an error banner appears, and the card comes back.
3. **A swipe that Safari commits now springs back.**
   - The input is an AXe swipe of 100 pt over 1.0 s, which ends with a release
     velocity. Safari closes the tab.
   - Ours springs back in 3 of 3 runs. The grab interruption therefore ends
     5 → 5, where Safari ends 5 → 3. The first re-audit's build closed tabs
     with this input.
4. **The fling exit still deviates (D1).**
   - The card holds 4 frames (about 60 ms) after release.
   - It freezes 2–3 frames mid-exit, at the same frame as the count swap.
   - It is 37–54 pt behind Safari at +50 to +200 ms.
   - The count changes about 165 ms after release; Safari's changes about
     10 ms after.
   - The kit holds 5 frames, and its flung card passes under its neighbour.
5. **New Tab is still a menu, and the page menu has no New Tab (D5, D5b).**
   The keyboard blocker is fixed, and the page now grows centred and blurred
   like Safari's. But its tail is 60–93 ms slower, 6.7 pt behind at +100 ms on
   the right edge.
6. **The last-tab page skips Safari's 0.67 → 0.84 phase (D2).** It first
   appears at 0.84 width and rests 323 ms later; Safari takes 500 ms. The kit's
   last-tab page jumps 16 pt in one frame about 425 ms after it appears.
7. **The ✕ reflow is close but not within tolerance (D8).**
   - The fit is 0.426 / 0.90; Safari's is 0.432 / 0.89.
   - Up to 11.8 pt at 117 ms. No overshoot, and it comes to rest about 140 ms
     early.
   - One of three runs has t99 +22 ms.
   - The kit's reflow jumps 33 pt in its first frame and is up to 31 pt off.
8. **The count label leads the ✕ motion by 3 frames (D10).** Safari leads by
   1 frame.
9. **The long-press menu lacks Pin Tab, Select Tabs and Move Tab (D6).** The
   kit also has no lift.
10. **The zoom-in curve is now slightly slow (1a).** Against the Safari mean,
    t50 and t90 are 17–22 ms late. This is within Safari's own run-to-run
    spread.
11. **The swipe-up-to-grid curve is slower (D7).** t90 is 62–77 ms late, and
    the page hovers 100–170 ms after release. Part of that is the input.
12. **There is no carry after a slow release (D3, 3g).** The total is
    −100 pt; Safari's is −104.65. Ours is 5.5–14.4 pt off at +200 ms after
    release, and t99 is 21–23 ms early. The kit tracks only −92 pt.
13. **The marginal items.** 3i peaks at 2.3 pt and 4b at 2.3 pt (+93.3
    against +91). Each is one pixel step over the limit.
14. **The kit's ✕ removes the closed card in one frame,** with no fade or
    scale. The kit's New Tab grows off-centre with no blur.
15. **D14: the GitHub card's accessibility element is often missing.**
16. **4a (grid flick) was not re-measured.**

## Fixed since the first re-audit

These pass:

- menus no longer raise the keyboard, and New Tab makes exactly one card, on
  the mock and on the real host;
- slow drags never close a tab (0 of 18);
- a tap during a zoom-out queues (8 of 8);
- the D11 zoom-in onset (the first frame moves 7.3 pt);
- the 3d lift timing;
- the D3 tracking jump;
- New Tab's centred, blurred origin;
- D4, D9, D11b, D12 and D13;
- 1c, 3h, 3k (app), 3l, rapid ✕, scroll during a reflow and Done twice.

## State left on the test host

The real-host checks changed cmux15's test account. The grid had 13 tabs at the
start (11 browser and 2 terminal):

- I created four Start Page tabs and closed all of them. I opened one tab from
  the Mac side (`example.org/reaudit2`) and closed it from the phone. CDP lists
  no `reaudit2` target, so the close reached Chrome.
- **One unintended close.** In live ✕ run 2, the grid layout had shifted.
  My ✕ tap at (370, 115) hit a pre-existing **live terminal card** instead of
  my own tab, and that terminal tab closed. I did not create it. Its owner may
  need to reopen it.
- The ended terminal left the grid after the Back to Terminals probe.
- The grid ended with the 11 browser tabs it started with, and no terminal
  tabs.
