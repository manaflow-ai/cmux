# Tabs grid: Safari parity re-audit 3 (independent, adversarial)

**Verdict: REJECT.** The two data-loss blockers from re-audit 2 are fixed: a
long-press reorder no longer closes the dragged tab (12 of 12 drops keep it,
left, right and down), and a swipe Safari commits now commits while a drag that
stops before the release still springs back (Safari does the same for both
inputs, re-measured on this simulator). The ✕ on an ended terminal now
closes it on the real host. But the fling, the ✕ reflow, the drag onset, the
swipe up to the grid and the count label are still well outside one frame or
2 pt. Three curves that passed in re-audit 2 now fail by one to two frames
(1c, 3l, 4b), New Tab is still a menu, and the long-press and page menus still
lack Safari's items.

This re-audit checks app build `b497df09bc93` and kit build `2dd83bab3ec6`
against the Safari numbers in [`tabs-parity-audit.md`](tabs-parity-audit.md)
(items D1–D14 and the "matched" list). It also retests every failure in
[`tabs-parity-reaudit.md`](tabs-parity-reaudit.md) and
[`tabs-parity-reaudit-2.md`](tabs-parity-reaudit-2.md). It changes no code.

## Setup

- **Builds.** `~/nxios-ref/tabs-reaudit-3/SHAS.txt` lists them.
  - App: `feat-cmux-next-ios-app` at `b497df09bc93`, with a clean `ios-next`
    tree. Built with the Tabs scheme, Debug, on mini-cmux15 in slot
    `reaudit3`. Every `*-b497df0*` artifact comes from this build.
  - Kit: `feat-cmux-next-tabs-kit` at `2dd83bab3ec6`, a clean
    `Packages/iOS/CmuxTabsKit`, built as `CmuxTabsKitDemo` in
    `~/nx-ios/reaudit3-kit`. Every `*-2dd83ba*` artifact comes from it.
- **Device.** A dedicated iPhone 17 Pro simulator (iOS 26.5),
  `nx-ios-reaudit3`, headless, so no hardware keyboard. mini-cmux15 had
  12 GiB free and a load average of about 5. mini-cmux9s had a load average
  of 48 to 55, so it was not used.
- **Safari.** Safari ran on the same simulator, with pages served on the
  mini (`127.0.0.1:8766`, solid colour headers). Where a Safari number was in
  doubt, I re-measured it with the same input as ours. Those clips are in
  `safari/`.
- **Hosts.** The mock host (`CMUX_NEXT_MOCK=1`, 5 tabs: 3 browser and 2
  terminal) and the real cmux15 host through the test login over a direct LAN
  link. The live grid had 12 tabs at the start.
- **Input and recording.** AXe `tap`, `touch`, `swipe`, `drag` and `batch`.
  `simctl recordVideo`, with each frame's real `pts_time`.
- **Tools.** `~/nxios-ref/tabs-reaudit-3/tools/`: the audit's `ctrack.py` and
  `sheet.py`; the earlier re-audits' `pcmp.py`, `tmatch.py`, `region.py` and
  `strip.py`; and new `al.py`, `ser.py`, `frames.py`, `thr.py` (aligned at a
  threshold crossing), `chg.py` (first frame a region changes) and
  `fstrip.py` (every real frame of a window).
- **Pass rule.** Every crossing (t10, t50, t90, t99) within one frame
  (16.7 ms) of Safari's, or the whole curve within 2 pt. A behaviour Safari
  has and ours lacks is a FAIL. With several runs, one failing run fails the
  item.

All artifact paths are relative to `~/nxios-ref/tabs-reaudit-3/`. `audit:`
means `~/nxios-ref/tabs-audit/`.

## The drag versus swipe question, re-measured on Safari

The brief flagged one known doubt: a 100 pt / 1 s drag that stops before the
release, against a swipe that is released while moving. I ran both inputs on
Safari's slot 2 card on this simulator.

| Input | Safari | Ours (app) |
|---|---|---|
| AXe `drag` 100 pt over 1.0 s (60 steps; the finger stops, then lifts) | 3 of 3 spring back (`safari/saf-drag-{1,2,3}.mp4`) | 9 of 9 spring back (`3-close/drag-{1,2,3}-b497df0.mp4`, `drag-runs.log`) |
| AXe `swipe` 100 pt over 1.0 s (released while moving) | 3 of 3 close (`safari/saf-swipe1s-{1,2,3}.mp4`) | 3 of 3 close, 5 → 4 (`3-close/swipe1s-{1,2,3}-b497df0.mp4`) |

So the commit decision matches Safari for both inputs.

## Audit items D1–D14 and the earlier re-audits' failures (app)

| # | Item | Safari | Ours (measured, runs) | Δ | Verdict | Artifacts (SHA) |
|---|---|---|---|---|---|---|
| D1 | Fling close (AXe swipe 100 pt in 0.12 s) | Re-measured, 3 runs. After the finger ends (x1 ≈ 300) the card **holds 3 frames**, then accelerates to about 20 pt/frame (≈ 1200 pt/s) and slows. x1 at +100 / +200 / +300 ms: 249–264 / 145–153 / 52–57. Gone at about +430 ms | 3 runs, 5 → 4. Holds 2–5 frames, and in that hold it **steps right by 5–12 pt** (292 → 297, 286 → 298). Then a constant 21–26 pt/frame (1270–1560 pt/s). x1 at +100 / +200 ms: 173–263 / 16–135. Gone at +220 to +310 ms | Ahead of Safari by up to **85–134 pt** (runs 1–2) and 36 pt (run 3). Exits 120–210 ms early. A backward jerk at release | **FAIL** | `3-close/fling-{1,2,3}-b497df0.mp4`, `fling-*.csv`, `fling-1-zorder.png`; `safari/saf-fling-{1,2,3}-*.mp4`, `.csv` (b497df0) |
| D2 | Close the last tab | Re-measured, 2 runs. The lone card turns into the Start Page **in its slot** (x0 67.3, 0.67 width) and zooms. Page x0: t10/50/90/99 = 25–33 / 99–100 / 224–233 / 482–490 ms | 3 runs. A fresh page opens from the lone card's slot (x0 67.3), count 1. 19–20 / 91–94 / 213–218 / 457–460 ms | t99 **−18 to −21 ms**; up to 4.1–4.2 pt at 83–167 ms. The origin is now right | **FAIL** (marginal) | `3-close/lasttab-{1,2,3}-b497df0.mp4`, `lasttab-*-page.csv`, `d2-lasttab.png`; `safari/saf-lasttab-{1,2}.mp4` (b497df0) |
| D3 | Swipe tracking: AXe drag 100 pt over 1.0 s | Re-measured, 3 runs. The first frames move −2, −8, −15, −22 pt; −30 pt at +100 ms. Total −102.9 to −104.3 pt (2 frames of carry) | 3 runs. The first frame **jumps −10 to −11.6 pt**, then holds at −15 to −17 pt for about 4 frames while the finger moves; −17 to −19 pt at +100 ms. Total −100.0 pt, no carry | Behind Safari by **11.6–13.4 pt at +100 ms**, up to 14.7–15.7 pt at 167–200 ms (onset-aligned). End −3.9 pt | **FAIL** | `3-close/drag-{1,2,3}-b497df0.mp4`, `drag-*.csv`, `d3-drag.png`, `d3-drag-turn.png` (b497df0) |
| D3a | A slow drag closes the tab | Springs back (3 of 3) | **0 of 9** | — | **PASS** | `3-close/drag-runs.log` (b497df0) |
| D3-commit | AXe swipe 100 pt over 1.0 s | Closes (3 of 3) | Closes (3 of 3) | — | **PASS** (fixed) | `3-close/swipe1s-{1,2,3}-b497df0.mp4` (b497df0) |
| D3f | Right rubber band (100 pt drag) | Re-measured, 3 runs: x0 +35.4 pt (209.3 → 244.7). Audit: +36.7 | 3 runs: x0 +36.7 pt (209.3 → 246.0) | +1.3 pt (re-measured); 0 pt (audit) | **PASS** | `3-close/rdrag-{1,2,3}-b497df0.mp4`, `.csv`; `safari/saf-rdrag-*.mp4` (b497df0) |
| D4 | A bar swipe from ≡ or from the terminal title | Switches tabs; no menu | 8 runs: 3 right and 3 left from ≡, 1 right and 1 left from the terminal title. Each switched tabs; no menu opened | — | **PASS** | `6-barswipe/barswipe-{right,left}-{1,2,3}-b497df0.mp4`, `barswipe-term-{right,left}-b497df0.mp4` (b497df0) |
| D5 | New Tab from the grid (+) | (+) acts at once | (+) is **still a menu** (New Terminal / New Tab). No keyboard. Choosing New Tab: 3 mock runs, 5 → 6 each, the page grows centred. Page edge (y 300–600 band) reaches 395 / 400 / 402 at 107–150 / 165–213 / 327–350 ms; re-audit 2's Safari track of `audit:2-newtab/saf-new.mp4` gives 48 / 130 / 295 ms | A second tap is needed. The tail is 30–60 ms slower against that Safari track. My own Safari re-measure (`safari/saf-newtab-{1,2}.mp4`) was too noisy to confirm the tail | **FAIL** (menu) | `2-newtab/newtab-{1,2,3}-b497df0.mp4`, `newtab-*.csv`, `newtab-1-sheet.png`, `shots/plus-after.png` (b497df0) |
| D5 live | New Tab on the real host | One card | 12 → 13, stable after 5 s, one Start Page card. A second creation went 14 → 15 with one new card (`reauditthreec`). No keyboard | — | **PASS** | `live/live-newtab-1-b497df0.mp4`, `live/baseline-tabs.txt` (b497df0) |
| D5b | New Tab from inside a page | Present | The page menu has Reload, Show Keyboard, Share, Copy URL, Request Desktop Website, Open on Mac. **No New Tab** | — | **FAIL** | `shots/pagemenu.png` (b497df0) |
| D6 | Long press on a card | Lift about ×1.06; the others dim; Copy Link, Pin Tab, Duplicate Tab, Select Tabs, Move Tab, Close Tab, Close Other Tabs | 1 run. Lift ×1.062 (177 → 188); no keyboard. The menu has Copy Link, Duplicate Tab, Close Tab, Close Other Tabs | **Pin Tab, Select Tabs and Move Tab missing** | **FAIL** (partial) | `5-longpress/longpress-1-b497df0.mp4`, `shots/lp-after.png` (b497df0) |
| D6b | Long press then drag to reorder, with the drop | The cards swap and both tabs stay | **Left 6 of 6, right 3 of 3, down 3 of 3**: each reordered and kept 5 tabs. The left drop settles into slot 1 (x0 16.0), with no fly-off | — | **PASS** (fixed) | `5-longpress/reorder-{left,right,down}-{1,2,3}-b497df0.mp4`, `reorder-left-1.csv` (b497df0) |
| D7 | Swipe up on the address bar (250 pt in 0.25 s) | Re-measured with the same input, 3 runs: t10/50/90/99 = 13–27 / 82–131 / 316–382 / 438–504 ms. It slows near 250 pt wide, then springs | 3 runs, each opens the grid. 3 / 27–29 / 306–329 / 429–457 ms. The first frame **jumps 98 pt** (402 → 304). After the lift it **hovers at 244 → 233 pt for about 190 ms** | t50 **−55 to −104 ms**; up to 74–81 pt at 33 ms | **FAIL** | `1-zoom/swipeup-{1,2,3}-b497df0.mp4`, `swipeup-*.csv`, `1d-swipeup.png`, `1d-swipeup-sameinput.png`; `safari/saf-swipeup-{1,2,3}.mp4` (b497df0) |
| D8 | Reflow after ✕ (mock) | Audit: t10/50/90/99 = 42 / 119 / 243 / 343 ms, 0.7 pt overshoot. Re-measured, 3 runs: within 8 ms of the audit | 3 runs. 30–34 / 102–105 / 216–221 / 319–329 ms; 0.7 pt overshoot | t50 **−14 to −17**, t90 **−22 to −27**, t99 −15 to −24 ms; up to **14–17 pt at 117 ms** | **FAIL** (worse than re-audit 2) | `3-close/xclose-{1,2,3}-b497df0.mp4`, `3b-xreflow.png`, `.csv`; `safari/saf-xclose-{1,2,3}-*.mp4`, `saf-3b-check.png` (b497df0) |
| D8 live | Browser ✕ reflow on the real host | as above | 2 runs (my own tabs, template track). 36 / 106–108 / 222–226 / 320–321 ms | t50 −11 to −13, t90 −17 to −20, t99 −23 to −24 ms; up to 11–13 pt | **FAIL** | `live/live-xclose-{1,2}-b497df0.mp4`, `live-xclose-*-b.csv`, `live-3b.png` (b497df0) |
| D9 | Reflow z-order | Stacking stays fixed | 1 run checked frame by frame across the crossing: no swap | — | **PASS** | `3-close/xclose-1-cross-strip.png` (b497df0) |
| D10 | Count label on a close | Re-measured. ✕: an instant swap on the frame before the reflow's first motion (3 of 3). Fling: 5–12 ms after the finger ends | ✕, 3 runs: an instant swap **26.6–28.4 ms before** that frame. Fling, 3 runs: an instant swap **53–108 ms after** the finger ends | ✕ about −27 ms; fling +41 to +103 ms | **FAIL** | `3-close/xclose-*-b497df0.mp4`, `fling-*-b497df0.mp4` (`chg.py`, digit box 175,689–187,707); Safari box 216,802–233,822 (b497df0) |
| D11 / 1a | Zoom-in (tap a card) | Audit, 3 runs: 25–30 / 87–110 / 216–240 / 378–411 ms; first frame 7–11 pt | 3 fresh launches. First frame 8.6 pt. 24–38 / 89–107 / 221–225 / 390–404 ms | Every crossing within −11 to +13 ms | **PASS** | `1-zoom/zoom-{1,2,3}-b497df0.mp4`, `1a-zoomin.png`, `.csv` (b497df0) |
| D11b | First zoom after launch | No stall | The three runs above are first zooms after a fresh launch; no hold over one frame | — | **PASS** | as above |
| D12 | Swipe another card during a zoom-out | Accepted | 3 runs, 5 → 4 | — | **PASS** | `8-interrupt/e-swipe-zoomout-{1,2,3}-b497df0.mp4` (b497df0) |
| D13 | Mac-side new tab joins the grid | Joins with an animation | Mock, 3 runs (`CMUX_NEXT_MOCK_MAC_NEW_TAB=9`): the slot fades in, 10 % → 90 % in 197–198 ms, no one-frame pop. Real host: not re-run | Safari gives no number | **PASS** (mock); live not re-run | `7-macside/mock-macnew-{1,2,3}-b497df0.mp4` (b497df0) |
| 7b | Mac-side close | Same as the ✕ reflow | Not tested | — | **UNVERIFIED** | — |
| D14 | A card on screen with no accessibility element | — | Every card shown on screen had an element ending ", tab", identified by its on-screen title, in every grid I read: the fresh grid, the 2-tab grid, after ✕, fling, reorder, New Tab and scroll during a reflow, and the live grid with 12–15 tabs. The GitHub card's label is "terminal: debounce resize during rotation · Pull Request #1421 · manaflow-ai/cmux, tab" | — | **PASS** | `bin/lbl.sh`, `bin/cards.sh` output in the log; `live/baseline-tabs.txt` (b497df0) |

## The audit's "matched" items, re-checked (app)

| Item | Safari | Ours (measured, runs) | Δ | Verdict | Artifacts (SHA) |
|---|---|---|---|---|---|
| 1c Page → grid, button | Audit: 26–34 / 81–87 / 183–185 / 265–266 ms; 1.4 pt undershoot | 3 runs. 19–21 / 84–85 / 182–189 / **288** ms; 0.7 pt | t99 **+23 ms in all 3 runs**; up to 18.5–21 pt at 50 ms | **FAIL** (regression; re-audit 2 passed) | `1-zoom/zoomout-{1,2,3}-b497df0.mp4`, `1c-zoomout.png`, `.csv` (b497df0) |
| 3d Lift on a swipe | 176 → 192 over about 80 ms (re-measured: 177 → 192.7 over 75–85 ms) | 176.7 → 192.7 over about 100 ms, with the 10 pt position jump in its first frame | About 1 frame | **PASS** | `3-close/drag-*.csv` (b497df0) |
| 3g Spring back after a slow release | Audit 50 / 149 / 314 / 513 ms. Re-measured, 3 runs: within 5 ms of the audit | 3 runs. 40–45 / 138–142 / 307–311 / 487–491 ms | t99 **−22 to −27 ms**; up to 3.4–5.0 pt at 100–117 ms | **FAIL** (marginal) | `3-close/3g-snapback.png`, `.csv`, `drag-*-c.csv` (b497df0) |
| 3h Lift scale back to 1.0 | 38 / 133 / 281 ms | 3 runs | Whole curve within 1.4–1.7 pt | **PASS** | `3-close/3h-liftback.png` (b497df0) |
| 3i Spring back after a right drag | Audit: 43 / 186 / 336 / 535 ms. Re-measured, 3 runs: 56–62 / 157–166 / 331 / 510 ms | 3 runs. 51–53 / 174–175 / 345 / 456 ms | Within 1.6 pt of the audit curve; 1.9–2.1 pt of the re-measured curve | **PASS** (borderline) | `3-close/3i-rubber-release.png`, `3i-vs-resaf.png` (b497df0) |
| 3k Swiped card above its neighbour during the exit | Above | 4 fling runs: GitHub stays above cmux until it leaves; cmux does not move | — | **PASS** | `3-close/fling-1-zorder.png`, `fling-*-cmux.csv` (b497df0) |
| 3l 2 → 1 (lone tab) | Audit: 41 / 116 / 240 / 338 ms; 0.6 pt overshoot | 3 runs. 35–37 / 105–107 / 223–224 / 318 ms; 0.6 pt. Stays in the grid with "1 Tab" | t90 **−16 to −17**, t99 **−20 ms**; up to 7.3–8.5 pt | **FAIL** (marginal; regression) | `3-close/two2one-{1,2,3}-b497df0.mp4`, `3l-two2one.png` (b497df0) |
| 4a Grid flick | Native | Not re-measured | — | **UNVERIFIED** | — |
| 4b Rubber band at the top (200 pt drag) | Audit +91 pt. Re-measured, 2 runs: +91.3 / +92.6 pt; back within 0.5 pt 572–575 ms after the last peak frame | 2 runs: +93.3 pt; settled 568–582 ms | Peak +0.7 to +2.0 pt (re-measured), +2.3 pt (audit). t50 −3 / +17 ms; t99 +54 to +64 ms (the last 1 % of the span) | **FAIL** (marginal) | `4-scroll/rubber-top-{1,2}-b497df0.mp4`, `4b-rubber.png`; `safari/saf-rubber-{1,2}.mp4` (b497df0) |
| Rapid ✕ (0.15 s apart) | Both close | 3 runs, 5 → 3 | — | **PASS** | `8-interrupt/d-rapidx-{1,2,3}-b497df0.mp4` (b497df0) |
| Scroll during a reflow | Accepted; no overlap | 2 runs, 4 tabs laid out cleanly | — | **PASS** | `8-interrupt/c-scroll-reflow-{1,2}-b497df0.mp4`, `shots/c-end.png` (b497df0) |
| Tap another card during a zoom-out | Queues. From the zoom-out start, the tapped card grows at about 470–570 ms and is full at about 770 ms | **8 of 8 queued.** 3 recorded runs: grows at +675 to +715 ms, full at +1042 to +1075 ms | Behaviour matches; **150–300 ms slower** | **FAIL** (timing); behaviour PASS | `8-interrupt/b-tap-zoomout-{1..8}-b497df0.mp4` (b497df0) |
| Grab mid snap-back or mid-exit (two 100 pt / 1 s swipes, 0.15 s apart) | 5 → 3 | 3 runs, 5 → 3 | — | **PASS** (fixed) | `8-interrupt/a-grab-{1,2,3}-b497df0.mp4` (b497df0) |
| Done tapped twice, 0.1 s apart | No stuck state | 3 runs, back on a working grid | — | **PASS** | `8-interrupt/f-done-twice-{1,2,3}-b497df0.mp4` (b497df0) |

## Regression probes (app)

| Probe | Result | Verdict |
|---|---|---|
| Menus raise the keyboard | (+), the long-press menu and the page menu: no keyboard, mock and real host | PASS |
| The dragged card stays on top | Yes, through the snap-back, the fling exit and the reorder drop | PASS |
| Lone tab 2 → 1 | No jump; stays in the grid. The curve is 1 frame fast (3l) | PASS (behaviour) |
| Back to Terminals, real host, on a terminal I created and ended with `exit` | It zooms out and the ended card is removed (15 → 14). But **for about 350 ms (1.42 → 1.80 s) a white ghost of the closing card sits over the toolbar, hiding (+) and clipping the count pill** | **FAIL** (new, minor) — `live/live-backtoterms-b497df0.mp4`, `live-backtoterms-sheet.png`, `live-backtoterms-detail.png` |
| ✕ on an ended terminal, real host (my own `R3TERMB`) | Closed, 15 → 14, no error banner; still closed 5 s later | **PASS** (fixed) — `live/live-xclose-ended-b497df0.mp4` |
| Interruptions | Grab: PASS. Tap during a zoom-out: queues, slow. Rapid ✕: PASS. Done twice: PASS | timing FAIL only |
| Toolbar swipe | No menus; tabs switch (8 runs) | PASS |
| Swipe up to the grid | Opens the grid every time; the curve fails (D7) | behaviour PASS |
| Last-tab close | A fresh page, count 1 | behaviour PASS |
| New Tab on the real host | Exactly one card | PASS |

## Kit demo (2dd83bab3ec6)

| # | Item | Safari | Kit (measured, runs) | Δ | Verdict | Artifacts (SHA) |
|---|---|---|---|---|---|---|
| D3a kit | Slow drag (AXe drag 100 pt / 1 s) | Springs back | 9 of 9 spring back | — | **PASS** | `kit/kit-drag-{1,2,3}-2dd83ba.mp4` (2dd83ba) |
| D3-commit kit | AXe swipe 100 pt / 1 s | Closes | 3 of 3 close | — | **PASS** | `kit/kit-swipe1s-{1,2,3}-2dd83ba.mp4` (2dd83ba) |
| D3 kit | Drag tracking | −30 pt at +100 ms; −103.9 pt total | 3 runs (globe template). −7 to −18 pt at +100 ms; total −90 to −100 pt; the spring back overshoots the rest position by 4–6 pt in 2 runs | 12–23 pt behind at +100 ms | **FAIL** | `kit/kit-drag-*.csv` (2dd83ba) |
| D1 kit | Fling | as D1 | 3 runs, 5 → 4. Holds about 3 frames (like Safari) and passes **above** Springs, then leaves in about 170 ms (gone at about +255 ms) | Exits about 175 ms early | **FAIL** | `kit/kit-fling-{1,2,3}-2dd83ba.mp4`, `kit-fling-1-strip.png` (2dd83ba) |
| 3k kit | Swiped card above its neighbour | Above | Above Springs through the exit (fixed) | — | **PASS** | `kit/kit-fling-1-strip.png` (2dd83ba) |
| 3a kit | ✕: the closed card | Fades in place | Springs fades in place over about 100 ms (fixed) | — | **PASS** | `kit/kit-xclose-1-strip.png` (2dd83ba) |
| D8 kit | Reflow after ✕ | 42 / 119 / 243 / 343 ms | 3 runs. The first frame **jumps 34 pt**. −5 / 89–91 / 205–208 / 301–303 ms; 1.4 pt overshoot | t50 −28 to −30, t90 −35 to −37, t99 −41 to −43 ms; up to 29–32 pt | **FAIL** | `kit/kit-xclose-{1,2,3}-2dd83ba.mp4`, `kit-3b.png` (2dd83ba) |
| D2 kit | Last tab | Re-measured: 25–33 / 99–100 / 224–233 / 482–490 ms | 3 runs. The card turns into the new page in its slot and zooms. 39–42 / 102–103 / 227–230 / 464–470 ms. The 16 pt content jump is gone. For about 30 ms the old and new titles overlap under the card | Every crossing within −14 to +14 ms | **PASS** | `kit/kit-lasttab-{1,2,3}-2dd83ba.mp4`, `kit-d2-lasttab.png`, `kit-lasttab-1-strip.png` (2dd83ba) |

| D5 kit | New Tab (+) | (+) acts at once; the page appears centred, blurred, and grows | 3 runs, 5 → 6 each. (+) is **still a menu** (New Note / New Tab). The page now appears centred and blurred and grows (fixed). The curve could not be tracked: the page colour matches the grid's placeholder cards | — | **FAIL** (menu) | `kit/kit-newtab-{1,2,3}-2dd83ba.mp4`, `kit-newtab-1-strip.png` (2dd83ba) |
| D6 kit | Long press | Lift ×1.06; 7 items | Lift ×1.062 (177 → 188, fixed). Copy Link, Duplicate Tab, Close Tab, Close Other Tabs | Pin Tab, Select Tabs, Move Tab missing | **FAIL** (partial) | `kit/kit-longpress-1-2dd83ba.mp4`, `kit-longpress-1.csv`, `shots/kit-lp.png` (2dd83ba) |
| D6b kit | Reorder with the drop | Both tabs stay | Left 3 of 3, right 1 of 1, down 1 of 1: reordered, 5 tabs kept (fixed) | — | **PASS** | `kit/kit-reorder-{left-1,left-2,left-3,right-1,down-1}-2dd83ba.mp4` (2dd83ba) |
| D4 kit | Bar swipe from ≡ | Switches tabs; no menu | 2 runs (right, left): switched, no menu | — | **PASS** | `kit/kit-barswipe-{right,left}-2dd83ba.mp4` (2dd83ba) |
| D7 kit | Swipe up (250 pt / 0.25 s) | Re-measured same input: 11–28 / 80–121 / 316–382 / 438–504 ms | 3 runs, opens each time. 2 / 24–25 / 317–335 / 440–459 ms | t50 **−83 to −84**, t90 −21 to −39 ms; up to 84–94 pt | **FAIL** | `kit/kit-swipeup-{1,2,3}-2dd83ba.mp4`, `kit-1d.png` (2dd83ba) |
| D10 kit | Count label | ✕: on the frame before motion. Fling: 5–12 ms after the finger ends | ✕: 25 ms before that frame (3 of 3). Fling: 55–80 ms after | about −25 ms; +43 to +75 ms | **FAIL** | `kit/kit-xclose-*`, `kit-fling-*` (2dd83ba) |
| D11 kit / 1a kit | Zoom-in | 25–30 / 87–110 / 216–240 / 378–411 ms | 3 runs. First frame 8.7 pt. 49–52 / 114–117 / 241–243 / 399–401 ms | t10 **+22 to +25**, t50 **+19 to +22** ms; up to 29–34 pt at 67 ms | **FAIL** (marginal) | `kit/kit-zoom-{1,2,3}-2dd83ba.mp4`, `kit-1a.png` (2dd83ba) |
| 1c kit | Zoom-out (button) | 26–34 / 81–87 / 183–185 / 265–266 ms | 3 runs. 16–22 / 79–84 / 180–193 / 269–271 ms | Every crossing within −13 to +9 ms | **PASS** | `kit/kit-zoomout-{1,2,3}-2dd83ba.mp4`, `kit-1c.png` (2dd83ba) |
| D12 kit | Swipe another card during a zoom-out | Accepted | 3 runs, 5 → 4 | — | **PASS** | `kit/kit-e-swipe-zoomout-{1,2,3}-2dd83ba.mp4` (2dd83ba) |
| Tap during a zoom-out, kit | Queues | 3 of 3 queued (Pinch opened). Timing not measured (blank placeholder card) | — | **PASS** (behaviour) | `kit/kit-b-tap-zoomout-{1,2,3}-2dd83ba.mp4` (2dd83ba) |
| 3g / 3h / 3i / 3l kit | Spring backs and 2 → 1 | — | Not measured: the kit's blank cards give only a 1 pt template track, too noisy for a 2 pt rule | — | **UNVERIFIED** | — |

## Failures, ranked by severity

1. **The fling exit does not follow Safari (D1).** App: after a 2–5 frame
   hold that jerks the card 5–12 pt *right*, it leaves at a constant
   1270–1560 pt/s and is gone 120–210 ms before Safari's. Up to 85–134 pt
   ahead of Safari at +100 to +200 ms. The count swaps 53–108 ms after the
   finger ends; Safari's swaps 5–12 ms after. The kit leaves about 175 ms early
   and its count swaps 55–80 ms after.
2. **The ✕ reflow is too fast (D8), and got worse.** Mock: t50 −14 to −17,
   t90 −22 to −27 ms, up to 14–17 pt at 117 ms (re-audit 2: 11.8 pt). Real
   host, 2 runs: t90 −17 to −20, t99 −23 to −24 ms, 11–13 pt. Kit: a 34 pt
   first-frame jump, t50 −28 to −30 ms, up to 29–32 pt.
3. **The swipe-up-to-grid curve (D7).** With Safari re-measured on the same
   input, ours drops 98 pt in its first frame and its t50 is 55–104 ms early,
   then it hovers about 190 ms after the lift. The kit's t50 is 83–84 ms early.
4. **The drag onset (D3).** The first frame jumps 10–11.6 pt and then holds
   for about 4 frames while the finger moves. 11.6–13.4 pt behind Safari at
   +100 ms, up to 15.7 pt. No end carry (−100 against −103.9 pt). Kit: 12–23 pt
   behind.
5. **New Tab is still a menu (D5, kit too), and the page menu has no New Tab
   (D5b).**
6. **Regressions of one to two frames in curves that passed before:**
   1c t99 +23 ms (3 of 3) and 18.5–21 pt at 50 ms; 3l t90 −16 to −17 and
   t99 −20 ms; 4b peak +2.3 pt over the audit's +91 (0.7–2.0 pt over my
   re-measure). 3g is still t99 −22 to −27 ms and 3.4–5.0 pt.
7. **The count label on ✕ leads by about 27 ms (D10),** where Safari swaps on
   the frame before motion. Kit: 25 ms.
8. **The last-tab page (D2)** now starts in the lone card's slot, but its
   t99 is 18–21 ms early (4.1–4.2 pt). The kit's passes.
9. **The long-press menus lack Pin Tab, Select Tabs and Move Tab (D6, kit
   too).** The lift is fixed in both.
10. **A tap during a zoom-out queues but is 150–300 ms slower** to open the
    tapped card.
11. **Back to Terminals on the real host leaves a white ghost of the closing
    card over the toolbar for about 350 ms,** hiding (+) and clipping the
    count pill (new, minor, 1 run).
12. **The kit zoom-in is 19–25 ms late at t10 and t50** (marginal).
13. **Not verified:** 4a grid flick, 7b Mac-side close, the live D13 path, and
    the kit's 3g, 3h, 3i and 3l.

## Fixed since re-audit 2

- A long-press reorder keeps the dragged tab on every drop (app 12 of 12,
  kit 5 of 5).
- A swipe that Safari commits now commits, and the grab interruption ends
  5 → 3 like Safari's; slow drags still spring back (0 of 9 closed).
- ✕ on an ended terminal closes it on the real host, with no error banner.
- The last-tab page starts in the lone card's slot; the kit's content jump
  is gone.
- The kit's flung card passes above its neighbour; the kit's ✕ fades the
  closed card; the kit New Tab is centred and blurred; the kit lift is
  ×1.062.
- D11 / 1a zoom-in passes in the app; D14 passes.

## State left on the test host

The live grid had 12 tabs at the start (6 Start Page, 5 Example Domain, 1
ended Terminal). I created three browser tabs (renamed by their search,
`R3-A`, `reauditthreeb`, `reauditthreec`) and two terminals (`R3TERM`,
`R3TERMB`, ended with `exit`), and closed all five. Before every ✕ I re-read
the accessibility tree and checked that the card under the tap carried my
label (`bin/safex.sh`).

- **One stray interaction.** A "Terminal emulator - Wikipedia" tab that I
  did not create appeared during the run; another session was using the same
  test account. Once, after a grid scroll moved the toolbar down by 56 pt, my
  New Tab helper's taps opened that tab instead of the menu and typed
  `reauditthreec` plus Return into its page. Its URL stayed on
  en.wikipedia.org. Its title later read "Command-line interface - Wikipedia"
  and then "Terminal emulator - Wikipedia" again, which looks like its owner
  navigating. I closed nothing that I did not create.
- The grid ended with 13 tabs: the 12 it started with plus that foreign
  Wikipedia tab.
- The simulator `nx-ios-reaudit3`, the slot `~/nx-ios/reaudit3`, the kit build
  `~/nx-ios/reaudit3-kit` and the page server were removed from mini-cmux15.
