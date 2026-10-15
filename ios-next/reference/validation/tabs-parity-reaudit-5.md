# Tabs grid: Safari parity re-audit 5 (independent, adversarial)

**Verdict: REJECT.**

The worst defect is new. After any long-press menu closes, the card that was
long-pressed stops drawing and loses its accessibility element. This happens
when the menu is dismissed, after Copy Link, Duplicate Tab, Pin Tab, Unpin
Tab, Select Tabs or Close Other Tabs, and after a long-press drag that ends on
the menu. The card leaves an empty slot until the grid is rebuilt, and a tab
pinned on its own is invisible in the pinned row. The app and the kit both do
it.

Four other results fail against Safari:

- A long-press drag **up** reorders the grid. Safari keeps the touch in the
  menu (0 of 3 reorders, measured below).
- The fling is 17–40 ms behind Safari.
- The drag onset is 9–12 pt behind Safari.
- A tap during a zoom-out opens its card about 0.7–1.0 s late.

These still pass or are now fixed:

- ✕ reflow and its count label
- swipe up
- zoom in and out
- last tab
- right rubber band
- page keyboard
- toolbar swipe
- Close All confirmation
- New Tab on the real host
- VoiceOver on a settled grid
- the white ghost after Back to Terminals
- the dragged card blanking during a left or right reorder

This re-audit checks app build `f5a45b69c586` and kit build `0504df8ae4ad`
against these sources:

- The Safari numbers in [`tabs-parity-audit.md`](tabs-parity-audit.md),
  [`tabs-parity-reaudit.md`](tabs-parity-reaudit.md),
  [`-2`](tabs-parity-reaudit-2.md), [`-3`](tabs-parity-reaudit-3.md) and
  [`-4`](tabs-parity-reaudit-4.md).
- The re-measured Safari clips in `~/nxios-ref/tabs-reaudit-3/safari/`.
- The Safari long-press reference in `~/nxios-ref/safari/longpress/`.
- New Safari clips recorded on this simulator for the long-press drag and the
  grid flick.

It changes no app code. I did not read `browser.md` or any implementer notes,
and I did not use the repository's tabs-curves or grid-reorder scripts.

## Setup

- **Builds.** `~/nxios-ref/tabs-reaudit-5/SHAS.txt` lists them.
  - **App.** `feat-cmux-next-ios-app` at `f5a45b69c586`, from a detached
    worktree (`/tmp/reaudit5`), built with `remote-ios.sh build --slot
    reaudit5 --scheme Tabs` (Debug) on mini-cmux15. Every `*-f5a45b6*`
    artifact comes from this build.
  - **Kit.** `feat-cmux-next-tabs-kit` at `0504df8ae4ad`, from a detached
    worktree (`/tmp/reaudit5-kit`). `CmuxTabsKitDemo` was built on
    mini-cmux15 in `~/nx-ios/reaudit5-kit`; the project was generated with
    xcodegen from the kit's own `Demo/project.yml`. Every `kit/kit-*`
    artifact comes from this build.
- **Device.** A dedicated iPhone 17 Pro simulator, `nx-ios-reaudit5`
  (`7C41B135…`), headless with no hardware keyboard. mini-cmux15 had 32 GiB
  free and a load average of about 4.5.
- **Hosts.**
  - The mock host: `CMUX_NEXT_MOCK=1`, 5 tabs, 3 browser and 2 terminal.
  - The real cmux15 host, through the test login over a direct LAN link. Its
    grid had 17 tabs at the start.
- **Safari.** Safari ran on the same simulator. Its pages were served from the
  mini at `127.0.0.1:8767`, with solid colour headers. The page server has
  been stopped.
- **Input and recording.**
  - AXe `tap`, `touch`, `swipe` and `drag`, plus `batch` step files.
  - The long-press drag holds 1.0 s, then makes 30 `touch --down` moves and
    lifts. A control run showed that repeated `touch --down` steps act as
    moves: they scroll the grid.
  - `simctl recordVideo` at 60 fps, with bursts up to 85 fps. The analysis
    uses each frame's real `pts_time` and drops duplicate frames.
- **Tools.** All tools are in `~/nxios-ref/tabs-reaudit-5/tools/`.
  - Reused from the earlier re-audits: `ctrack.py`, `region.py`, `onset.py`,
    `thr.py` and `addcx.py`.
  - New for this audit:
    - `cx.py` gives the crossings, the deltas against Safari, and the
      distance outside the Safari envelope. Onset is the last rest frame,
      capped at one frame before the first move.
    - `lvl.py` gives the time to reach each position after the fling.
    - `cnt.py` and `cnt2.py` time the count label.
    - `follow.py` checks whether a card follows the finger.
    - `decay.py` gives the flick deceleration.
- **Pass rule.**
  - A curve passes when its t10, t50, t90 and t99 crossings all fall inside
    Safari's own run-to-run range, widened by one frame (16.7 ms), or when the
    whole curve stays within 2 pt of the Safari mean.
  - Where a curve passes the range rule but misses the Safari mean by more
    than one frame, the table says so.
  - A behaviour Safari has and ours lacks is a FAIL.
  - With several runs, one failing run fails the item.

Artifact paths are relative to `~/nxios-ref/tabs-reaudit-5/`. SHA-256 sums of
all 340 artifacts are in `SHA256SUMS.txt`. The "SHA" column gives the build
(`f5a45b6` for the app, `0504df8` for the kit, `Saf` for Safari) and the first
12 hex digits of the clip's SHA-256 where it is cited.

## Safari: long-press, then drag (asked for explicitly)

Safari was measured on this simulator with a 6-tab grid and the same input as
ours, 3 runs per direction. Every card started in the top row, except for the
up drag.

| Direction | Safari | Ours (app, mock) | Kit | Verdict |
|---|---|---|---|---|
| **Down** (300 pt, onto the menu) | **0 of 3 drag.** The card stays lifted, the menu opens below it and keeps the touch, and the lift activates the row under the finger: Select Tabs, 3 of 3 | 0 of 3 reorder; the menu keeps the touch, like Safari. But the row under the finger is **not** activated, and the dragged card **vanishes** from the grid in 3 of 3 runs: the slot is empty, there is no AX element, and the count stays at 5 until the grid is rebuilt | Same as the app, 3 of 3 | **FAIL** (the card vanishes; the row is not activated) |
| **Up** (300 pt; the card is in row 2, so the menu opens above it) | **0 of 3 drag.** The menu opens above the card and keeps the touch | **3 of 3 reorder** (zsh moves to slot 2). The menu opens **below** the card, over the bottom bar | **3 of 3 reorder** | **FAIL** (ours drags where Safari does not) |
| **Left** (190 pt) | 3 of 3 reorder | 3 of 3 reorder, 5 tabs kept | 1 of 1 | **PASS** |
| **Right** (190 pt) | 3 of 3 reorder | 3 of 3 reorder, 5 tabs kept | 1 of 1 | **PASS** |

So **down not reordering matches Safari**. What does not match is the vanished
card, the release that does nothing, and the up drag.

Artifacts:

- Safari: `5-longpress/saf2-lpdrag-{down,up,left,right}-{1,2,3}.mp4`
  (`down-1` `5fc1ebd16b35`), `saf2-lpdrag.log`, `shots/saf2-lpdrag-*.png`.
- Ours: `5-longpress/ours-lpdrag-*-f5a45b6.mp4` (`down-1` `ecbf15e87272`),
  `ours-lpdrag.log`, `shots/ours-lpdrag-down-3.png`.
- Kit: `kit/kit-lpdrag-*-f5a45b6.mp4`.

My first Safari attempt ran while the grid was in Select mode, which an
earlier test release had triggered. It is kept, but not counted, in
`5-longpress/safari-select-mode-invalid/`.

## Motions (app, mock host)

| # | Item | Safari | Ours (measured, runs) | Δ | Verdict | Artifacts (SHA) |
|---|---|---|---|---|---|---|
| 1a | Zoom-in (tap a card) | 25–30 / 87–110 / 216–240 / 378–411 ms (3 runs) | 3 runs: 23–24 / 93–109 / 219–240 / 399–415; first frame 8.6 pt | Inside Safari's range. Against the mean: −4..+14 / −7..+15 / +9..+25 ms. Up to 5 pt outside the envelope | **PASS** | `1-zoom/zoom-{1,2,3}-f5a45b6.mp4` (f5a45b6) |
| 1c | Zoom-out (Tabs button) | 26–34 / 81–87 / 183–185 / 265–266 ms; 1.4 pt undershoot | 3 runs: 21–40 / 77–94 / 180–198 / 263–281; 1.4 pt undershoot | Inside the range. Run 1 is +10..+16 ms against the mean. Up to 11.6–19 pt outside the narrow envelope of 2 Safari runs | **PASS** | `1-zoom/zoomout-{1,2,3}-f5a45b6.mp4` (f5a45b6) |
| D7 | Swipe up on the address bar (250 pt in 0.25 s) | 13–25 / 73–116 / 314–382 / 438–504 ms | 3 runs: 12–14 / 91–109 / 330–354 / 469–487 | 0.3–1.4 pt outside the envelope | **PASS** (fixed) | `1-zoom/swipeup-{1,2,3}-f5a45b6.mp4` (f5a45b6) |
| D8 | ✕ reflow | 34–41 / 119–122 / 235–246 / 338–345 ms; 0.7 pt overshoot | 3 runs: 43 / 118 / 241–243 / 349–359; 0.7 pt | Inside the range; max 4.5–4.8 pt from the mean. Run 3 t99 is +18 ms against the mean | **PASS** (marginal) | `3-close/xclose-{1,2,3}-f5a45b6.mp4` (`5d2a0d5d9840`) |
| D10 ✕ | Count label on ✕ | An instant swap on the frame before the reflow moves | 3 of 3 swap instantly on the last rest frame, 18–20 ms before the first move | One frame | **PASS** (fixed) | `3-close/xclose-*` (`cnt.py`, box 175,689–188,707) |
| D1 | Fling (AXe swipe 100 pt in 0.12 s), aligned at x1 ≤ 300 | Time to reach x1 = 250 / 200 / 150 / 100 / 50 / 20: 86–113 / 140–159 / 182–202 / 227–247 / 289–310 / 348–367 ms | 3 runs, 5 → 4: 114–130 / 163–179 / 211–221 / 248–259 / 305–323 / 377–395. It eases at about 5 pt per frame for about 100 ms, then accelerates. No backward step | **+9 to +40 ms behind the mean; 2 of 3 runs outside the range**. 23–46 pt behind at +100 to +217 ms | **FAIL** | `3-close/fling-{1,2,3}-f5a45b6.mp4` (`f3b02427f963`) |
| D10 fling | Count label on a fling (count change minus the x1 ≤ 300 time) | −9 / −9 / +8 ms (the same tool on the Safari clips) | 3 runs: +6 / +1 / +0 ms | Inside one frame | **PASS** (fixed) | `3-close/fling-*-f5a45b6.mp4` |
| D3 | Drag onset and carry (AXe drag 100 pt in 1 s, 60 steps), card centre | −29..−31 pt at +100 ms; −38.6..−39.3 at +200 ms; −102.9..−104.3 pt total | 9 runs. 8 of 9: −18..−21 at +100 ms and −26..−28.6 at +200 ms. Run 1: −31 at +100 ms, but with a 18 pt jump in a single frame. Total −103.3..−104.6 pt | **9–12 pt behind** for the whole tracking phase; the carry matches | **FAIL** | `3-close/drag-{1..9}-f5a45b6.mp4`, `drag-*.csv` (f5a45b6) |
| D3a | Close safety: 9 slow-stop drags | All spring back | 9 of 9 spring back (5 Tabs) | — | **PASS** | `3-close/drag-runs.log` |
| D3-commit | Close safety: 3 moving swipes (100 pt in 1.0 s) | Close (3 of 3) | 3 of 3 close (5 → 4) | — | **PASS** | `3-close/swipe1s-{1,2,3}-f5a45b6.mp4`, `swipe1s.log` |
| 3d | Lift on a swipe | 176.7 → 192.7 in 83–102 ms | 176.7 → 193.3 in 70–92 ms | +0.6 pt; within one frame | **PASS** | `3-close/drag-*.csv` |
| 3g | Spring back after a slow release (from the turnaround) | 47 / 145–146 / 310–315 / 507–517 ms | 6 runs. 2 within 3 ms. 4 runs: t90 −15..−17 and t99 −18..−22 ms, max 4.0–8.4 pt from the mean; run 2's t99 is outside the range | Up to 8.4 pt | **FAIL** (marginal) | `3-close/drag-{1..6}-c.csv` |
| 3h | Lift scale back to 1.0 | audit 38 / 133 / 281 / 329; re-measured 53 / 141 / 292 / 411 ms | 6 runs: max 1.3–2.5 pt from the mean; 3 runs over 2 pt (2.5, 2.1, 2.4) | The width is quantised at 0.67 pt | **FAIL** (marginal) | `3-close/drag-*-c.csv` |
| D3f | Right rubber band (100 pt drag) | x0 +35.4 pt (209.3 → 244.7) | 3 runs: +36.0 (→ 245.3) | +0.6 pt | **PASS** | `3-close/rdrag-{1,2,3}-f5a45b6.mp4` |
| 3i | Spring back after the right drag | 56–63 / 157–166 / 331 / 509–510 ms | 3 runs: 63–65 / 165–168 / 344–358 / 476–494 | Curve within 1.2–1.7 pt (t90 +13..+27 ms, over a 36 pt span) | **PASS** | `3-close/rdrag-*.csv` |
| 3l | 2 → 1 (lone tab) | audit 41 / 116 / 240 / 338 ms; 0.6 pt | 3 runs: 41–44 / 117–120 / 239–241 / 348–356; 0.6 pt | Run 1's t99 is +18 ms, outside one frame; up to 5.4–7.3 pt at about 150 ms | **FAIL** (marginal) | `3-close/two2one-{1,2,3}-f5a45b6.mp4` |
| D2 | Last tab | Re-measured: 20–27 / 92–95 / 220–228 / 381–388 ms | 3 runs. It opens a Start Page in the lone card's slot and zooms: 24–25 / 93 / 218–220 / 349–357. **No keyboard**; count 1 | Whole curve within 1.2–1.3 pt of Safari. t99 is −28..−36 ms, in the last 0.7 pt | **PASS** (the keyboard regression from re-audit 4 is fixed) | `3-close/lasttab-{1,2,3}-f5a45b6.mp4`, `shots/lasttab-end.png` |
| 4a | Grid flick (12 tabs in both; AXe swipe 200 pt in 0.08 s; deceleration fitted over 0.04–0.45 s) | 3 runs: rate 0.9980–0.9982 per ms (τ 489–569 ms) | Runs 1–2: 0.9981–0.9982 (τ 533–553 ms). Run 3: 0.9966, because it reaches the top edge about 0.5 s after the peak | Native deceleration matches | **PASS** (2 clean runs) | `4-scroll/flick-{1,2,3}-f5a45b6.mp4`, `saf-flick-{1,2,3}.mp4` (Saf) |
| 4b | Rubber band at the top (200 pt drag) | Peak +91.3 / +92.6 pt; release 5–6 / 66–72 / 245–246 / 449–454 ms | 3 runs: peak +93.3 pt; release 6–14 / 67–83 / 256–265 / 493–508 | Peak +0.7..+2.0 pt; t99 **+42..+57 ms**; 1.7–8.1 pt outside the envelope | **FAIL** (marginal) | `4-scroll/rubber-top-{1,2,3}-f5a45b6.mp4` |
| tap | Tap another card during a zoom-out (batch: tap Tabs, wait 0.1 s, tap a card) | Queues. From the zoom-out start the card grows at +470–570 ms and is full at about +770 ms | 3 of 3 queue, but the card grows at **+1250 to +1500 ms** and is full at **+1730 to +1960 ms** | **+700 to +1000 ms**. A control shows about 450 ms between two batched taps, so even after subtracting that, ours is about 0.7 s late | **FAIL** (worse than re-audit 4's +260..+400) | `8-interrupt/tap-zoomout-{1,2,3}-f5a45b6.mp4` (`f4252b0cd8e1`), `ctl-tap-latency-f5a45b6.mp4` |
| D6b | Long-press reorder, left and right | Reorders | 3 of 3 each, 5 tabs kept. The dragged card is on top and shows real content (it is not blank) | — | **PASS** (fixed since re-audit 4) | `5-longpress/ours-lpdrag-{left,right}-*` |
| D6b-preview | Drag preview while reordering | About 184.7 pt wide (×1.04) and translucent | About **118 pt wide (×0.67)** and opaque | −67 pt | **FAIL** | the same clips; `/tmp` frames at 8 s (ours) and 9 s (Safari) |
| D6b up and down | See the long-press drag table above | — | — | — | **FAIL** | — |

## Long-press menu (app)

| Item | Safari (`~/nxios-ref/safari/longpress/`) | Ours (light and dark, 1 run each plus item runs) | Verdict |
|---|---|---|---|
| Lift and preview box | Preview group 16, 109, 195.7 × 275 | Preview group 16, 109, 195.7 × 275.3. The card grows to 186.7 pt while pressed, then settles into the preview | **PASS** |
| Menu box and rows | x 16, width 250, row height 42. Rows at y 410 / 452 / 494 / 536 / **578 Move Tab** / 620 Close Tab, a 21 pt gap, then 683 Close Other Tabs | x 16, width 250, row height 42. Rows at 410.3 / 452.3 / 494.3 / 536.3 / 578.3 Close Tab, a 21 pt gap, then 641.3 Close Other Tabs | **FAIL**: **Move Tab is missing** |
| Icons | link, pin, duplicate, selected, arrow.forward and its chevron, Close | The same frames to 0.1 pt, except for the missing Move Tab icon and chevron | **PASS** (except Move Tab) |
| Order | Copy Link, Pin, Duplicate, Select, Move, Close, separator, Close Other | The same, without Move | **FAIL** (Move) |
| Dark | Same geometry (`dark-lp-b.png`) | Same geometry as in light; Move Tab missing | **FAIL** (Move) |
| Pinned-tab menu | Copy Link, Unpin Tab, Select Tabs, Move Tab, Close Tab; preview 203 × 34.7 | Copy Link, Unpin Tab, Select Tabs, Close Tab; preview 204 × 34 | **FAIL** (Move) |
| Terminal card menu | — | Pin Tab, Select Tabs, Close Tab, Close Other Tabs. It opens below a row-2 card, over the bottom bar; Safari opens it above for that slot | Note |
| **The card after the menu closes** | The card returns to its slot | **The long-pressed card vanishes**: no pixels and no AX element. This happened after a dismiss, Copy Link, Duplicate, Pin, Unpin, Select Tabs and Close Other Tabs, every time I tried. A tab pinned on its own is invisible in the pinned row (`shots/pinned2.png`). It comes back only when the grid is rebuilt (zooming into a page and out again) | **FAIL (critical)** — `shots/after-dismiss.png` (`105740e63d32`), `after-Copy_Link.png`, `after-Duplicate_Tab.png`, `pinned2.png` (`2f495452e65c`), `unpinned.png`, `select1.png`, `close-others.png` |
| Copy Link | Copies the URL | The pasteboard holds `https://cmux.dev` | **PASS** |
| Pin and unpin | Pins into the pinned row, then unpins | Both work (AX shows `…, Pinned`). The single-pin strip is invisible (the bug above) | **FAIL** (visibility) |
| Select Tabs: header | Close, Move, More, Search, Done | Close, More, Done. **Move and Search are missing** | **FAIL** |
| Select Tabs: bulk More | Pin 2 Tabs and Copy 2 Links at x 16, y 72 | Pin 2 Tabs and Copy 2 Links at x 33, y 76 (+17 / +4 pt) | **FAIL** (position) |
| Bulk Copy | — | The pasteboard holds both URLs | **PASS** |
| Bulk Pin | — | Both tabs pinned, and both strips visible | **PASS** |
| Bulk Close | "Close 2 Tabs" | "Close 2 Tabs" closes both (5 → 3) | **PASS** |
| Duplicate | Adds a tab next to the original | 5 → 6, inserted after the original; the original then vanishes (the bug above) | **PASS** (action) |
| Close Other Tabs, with pinned tabs | Pinned tabs are kept | Both pinned tabs kept, 3 tabs left. The kept card is invisible (the bug above) | **PASS** (action) |

## Regression probes (app)

| Probe | Result | Verdict | Artifacts |
|---|---|---|---|
| Menus raising the keyboard | (+), the page menu (≡) and the long-press menu: no keyboard | **PASS** | AX reads in the log |
| The dragged card on top and real | Left and right reorders: on top and real. But see D6b-preview, and the vanished card after the menu | PASS (reorder), FAIL (menu) | `5-longpress/ours-lpdrag-left-1-f5a45b6.mp4` |
| Back to Terminals, real host, on my own terminal ended with `exit` | It zooms out and the card is removed (19 → 18). **No white ghost over the toolbar** (15 fps strip). The card disappears in one frame, with no fade | **PASS** (ghost fixed); the removal is a pop | `live/live-backtoterms-1-f5a45b6.mp4` |
| Interruptions | Grab (two swipes 0.15 s apart): 3 of 3 end at 5 → 3. Rapid ✕: 3 of 3 end at 5 → 3. Swipe during a zoom-out: 3 of 3 end at 5 → 4. Done twice: 3 of 3 end on a working grid. A tap during a zoom-out queues but is late (above) | PASS, except the tap timing | `8-interrupt/*-f5a45b6.mp4` |
| Toolbar swipe | 6 runs from the terminal ≡, the terminal title and the page ≡: each switched tabs; no menu opened. Swipes that start on Back or on Tabs did not switch (not covered by the Safari reference) | **PASS** | `6-barswipe/bar-*-f5a45b6.mp4` |
| Terminal cards show the prompt | Mock and real host: yes (`cmux@cmux15 ~ %`). Only the very first launch after install showed the zsh card black with only a cursor (`shots/grid0.png`). The prompt font scale differs between two live terminal cards | PASS (minor note) | `shots/live-grid-term.png` |
| Close All asks first | The sheet "Close 3 Tabs and 2 Terminals?" offers "Close 3 Tabs and 2 Terminals" and "Close 3 Tabs, Keep Terminals" | **PASS** | `shots/closeall-ask.png` |
| New Tab on the real host | 17 → 18 with exactly one new card, stable after 7 s. A second one: 18 → 19, one card | **PASS** | `live/after-newtab-tabs.txt`, `live/live-newtab-1-f5a45b6.mp4` |
| New Tab from the grid (+) | Still a **menu** (New Terminal / New Tab). Safari acts at once. New Tab focuses the address field with the keyboard up, as Safari does | **FAIL** (menu) | `2-newtab/plus-1-f5a45b6.mp4`, `shots/plus-after.png` |
| New Tab from inside a page | The page menu has Reload, Show Keyboard, Share, Copy URL, Request Desktop Website, Open on Mac and Close Tab. **No New Tab** | **FAIL** | `shots/pagemenu.png` |
| VoiceOver, every visible card and its ✕ | Settled grids: every card has a `…, tab` element and a Close button, on the mock (5) and the live grid (17 of 17). **But a long-pressed card loses its element (above).** Also, the Done button's frame is 38, 673, 326 × 48 and covers (+) and the count; in select mode the "N Tabs" label takes that frame too | **FAIL** (lost element; wrong Done frame) | `live/final-ax.json`, `5-longpress/lp-light-ax.json` |
| Page keyboard | A tap in the page's search field raises it. A 370 pt drag down over 1.2 s dismisses it interactively: it follows the finger frame by frame | **PASS** | `9-regress/kb-dragdown-1-f5a45b6.mp4`, `shots/page-kb.png` |
| ✕ on the real host | My two tabs (`reaudit5a`, `reaudit5b`) closed with an animated reflow, 19 → 18 → 17. I re-read the tree before each tap (`bin/safex.sh`) | **PASS** | `live/live-xclose-{1,2}-f5a45b6.mp4` (`13573c73fa0d`) |

## Kit demo (0504df8ae4ad)

| # | Item | Safari | Kit (measured, runs) | Δ | Verdict | Artifacts |
|---|---|---|---|---|---|---|
| 1a | Zoom-in | 25–30 / 87–110 / 216–240 / 378–411 ms | 3 runs: 26–27 / 93–95 / 225–227 / 403–404 | Inside the range | **PASS** (fixed since re-audit 3) | `kit/kit-zoom-{1,2,3}-f5a45b6.mp4` |
| 1c | Zoom-out | 26–34 / 81–87 / 183–185 / 265–266 ms | 3 runs: 20–21 / 72–77 / 171–174 / 250–259 | Inside the range; −7..−15 ms against the mean | **PASS** | `kit/kit-zoomout-*` |
| D8 | ✕ reflow (Note card, diagonal path) | 34–41 / 119–122 / 235–246 / 338–345 ms | 3 runs: 27–28 / 120–121 / 241–242 / 322–342; first frame 10 pt | Inside the range | **PASS** (fixed since re-audit 3) | `kit/kit-xclose-{1,2,3}-f5a45b6.mp4` (`7dc63a12cadd`) |
| D10 | Count on ✕ and on a fling | On the frame before motion; fling −9..+8 ms | ✕: on the last rest frame. Fling: +1 / +18 / +18 ms | Inside the range | **PASS** | as above |
| D1 | Fling | Flies off lifted and opaque | 3 runs, 5 → 4. **The card's content turns blank (a placeholder) as soon as it lifts**, in slot 1 and slot 2; the curve cannot be tracked | — | **FAIL** | `kit/kit-fling-{1,2,3}-f5a45b6.mp4` (`434d75b1457d`), `kit-fling-slot1-f5a45b6.mp4` |
| D3 | Drag onset (x1) | −21..−23 pt at +100 ms; −30.7..−31.3 at +200 ms | 3 runs: −22..−23 at +100 ms, but with a **15 pt jump in a single frame** at about 30 ms; −27.5..−29 at +200 ms | 2–4 pt at +200 ms; a jerk at the onset | **FAIL** (marginal) | `kit/kit-drag-{1,2,3}-f5a45b6.mp4` |
| D7 | Swipe up | 13–25 / 73–116 / 314–382 / 438–504 ms | 3 runs: 7–8 / 87–89 / 324–326 / 445–452 | Inside the range; t90 −26..−28 ms against the mean; 11–14 pt outside the envelope | **PASS** (range rule; fails against the mean) | `kit/kit-swipeup-*` |
| D6 | Long-press menu | 7 rows | The same 6 rows as the app; **Move Tab missing**. The **long-pressed card vanishes after a dismiss** | — | **FAIL** | `shots/kit-lp.png`, `kit-lp-dismissed.png` |
| D6b | Long-press drag | Down 0 of 3 and up 0 of 3 drag; left and right reorder | Down: 3 of 3 the card vanishes. **Up: 3 of 3 reorder.** Left 1 of 1 and right 1 of 1 reorder | — | **FAIL** (up; down vanish) | `kit/kit-lpdrag-*-f5a45b6.mp4` |
| — | 3g, 3h, 3i, 3l, last tab, New Tab | — | Not measured. The kit's placeholder cards give no colour to track | — | **UNVERIFIED** | — |

## Failures, ranked

1. **A long-pressed card vanishes after its menu closes (app and kit).** The
   slot is empty and has no AX element after a dismiss, Copy Link, Duplicate,
   Pin, Unpin, Select Tabs, Close Other Tabs and a down drag: 3 of 3 runs and
   every action tried. A tab pinned on its own is invisible. The card comes
   back only when the grid is rebuilt. Users see tabs disappear, and
   VoiceOver loses them.
2. **A long-press drag up reorders (app 3 of 3, kit 3 of 3), where Safari
   keeps the touch in the menu (0 of 3).** On a down drag, Safari activates
   the row under the finger when it lifts (Select Tabs, 3 of 3); ours
   activates nothing. Our menu for a row-2 card opens below the card, over the
   bottom bar, where Safari opens it above.
3. **A tap during a zoom-out opens its card about 0.7–1.0 s late.** The card
   grows at +1250 to +1500 ms against Safari's +470–570 ms. That is worse than
   re-audit 4's +260 to +400 ms.
4. **The fling lags Safari by 9–40 ms**, with 2 of 3 runs outside Safari's
   range. It ramps at about 5 pt per frame for 100 ms, and is 23–46 pt behind
   at +100 to +217 ms. The kit's flung card turns blank.
5. **The drag onset is 9–12 pt behind Safari** in 8 of 9 runs (−18..−21 pt
   against −29..−31 pt at +100 ms). The other run has a 18 pt jump in one
   frame. The kit has a 15 pt jump in one frame.
6. **The drag preview during a reorder is ×0.67 (about 118 pt) and opaque**;
   Safari's is ×1.04 (184.7 pt) and translucent.
7. **Missing Safari items:** Move Tab (card menu and pinned menu); Move and
   Search in the Select header; New Tab in the page menu. (+) is still a menu.
   The bulk More menu sits at x 33, y 76 instead of x 16, y 72.
8. **Marginal curve misses:** 4b rubber-band t99 +42..+57 ms and peak +0.7..+2.0
   pt; 3g snap-back t99 −18..−22 ms and up to 8.4 pt (4 of 6 runs); 3l t99
   +18 ms in 1 of 3 runs and 5.4–7.3 pt; 3h lift scale-back 2.1–2.5 pt in 3 of
   6 runs.
9. **Minor:**
   - The Done button's AX frame covers (+) and the count.
   - Back to Terminals removes the card in one frame, without a fade.
   - The first launch after install showed a terminal card with no prompt.

## Fixed since re-audit 4

- ✕ reflow (now inside Safari's range, 4.5–4.8 pt) and its count label (now
  on the frame before motion).
- The count label after a fling (0–6 ms).
- Swipe up to the grid (≤ 1.4 pt outside Safari's envelope).
- Zoom-out.
- The last tab: no keyboard, and the curve is within 1.3 pt.
- The right rubber-band release (within 1.7 pt).
- Left and right reorder: the dragged card is real and on top, not a blank
  rectangle.
- The white ghost after Back to Terminals.
- Kit zoom-in and kit ✕ reflow.

## State left behind

- **Real host.** The grid started with 17 tabs: 10 Start Page, 3 Example
  Domain, 3 Terminal and 1 Wikipedia. I created two browser tabs (searches
  `reaudit5a` and `reaudit5b`) and one terminal (the last card, ended with
  `exit` and removed through Back to Terminals). All three are closed. The
  grid ended with the same 17 tabs, the same multiset
  (`live/baseline-tabs.txt`, `live/final-tabs.txt`). Before every ✕ I re-read
  the tree and checked that the card under the tap carried my label.
- **Mock.** Pin state persists across launches. I unpinned both test pins
  before finishing.
- **Removed.** The simulator `nx-ios-reaudit5`, the slot `~/nx-ios/reaudit5`,
  `~/nx-ios/reaudit5-kit`, the page server and `~/nx-ios/reaudit5-pages` on
  mini-cmux15, and the worktrees `/tmp/reaudit5` and `/tmp/reaudit5-kit`.
