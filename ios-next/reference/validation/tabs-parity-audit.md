# Tabs grid: Safari parity audit (independent)

This audit compares every Tabs-grid animation in the app, and in the
CmuxTabsKit demo, with Mobile Safari on iOS 26. It covers physics, timing and
interruptibility. It records measurements and a defect list. It changes no
code.

## Setup

- **Device.** One iPhone 17 Pro simulator (iOS 26), `nx-ios-audit`, on
  mini-cmux15. Safari and our app ran on the same simulator. The simulator was
  deleted after the audit.
- **Safari.** Default Compact tab layout. Five to eight tabs from local pages
  with solid colour headers, so header colour could be tracked. The tab counts
  matched ours for each test.
- **Ours.** The Tabs scheme on the mock host (`CMUX_NEXT_MOCK=1`), with 5 tabs:
  3 browser and 2 terminal.
- **Builds.** `~/nxios-ref/tabs-audit/SHAS.txt` records the build behind every
  artifact.
  - Build A is `586de4ea3529`.
  - Build B is `4daaf015e476`. All four known bugs were re-measured on Build B.
  - The kit is `nx-tabs-kit` at `274892104153`.
- **Input.** AXe `tap`, `drag`, `swipe`, `touch` and `batch`. `batch` gives
  timed sequences inside one HID session, which the interruption tests need.
  Pinch can't be scripted with AXe, so pinch rows are unverifiable.
- **Recording.**
  - `simctl recordVideo`. Timestamps are each frame's real `pts_time`.
  - Most clips ran at about 60 fps with even spacing. Some ran at 120 fps in
    bursts.
  - Every curve is resampled to a 1/60 s grid only for the delta columns.
- **Tracking.**
  - `ctrack.py`: the bounding box of the page or card header colour.
  - `rowrun.py`: the longest bright or dark run on one row.
  - `vshift.py`: the grid's vertical scroll, by row-profile matching. It
    integrates, so it drifts by a few pt per flick.
  - `sfit.py`: a fit of SwiftUI `spring(response:dampingFraction:)`, with the
    onset and optionally the initial velocity free.
  - `cmp.py`: t10, t50, t90 and t99, the settle time, and the largest delta
    against Safari in pt.
  - Tools are in `~/nxios-ref/tabs-audit/tools/`.
- **Repeats and noise.** Repeat runs in one clip differ by up to 25 pt in the
  first 50 ms, because the recorder bunches frames. Treat a single-run
  difference under about 10 pt in the first 3 frames as noise.

Artifact root: `~/nxios-ref/tabs-audit/<item>/`. Each item folder has the
raw `.mp4`s, the tracked `.csv`s, a `*-side-by-side.png` contact sheet
(row A is Safari, row B is ours, aligned at onset; labels show ms after
onset), and `cmp` overlay plots (`*.png`, with matching `.csv` progress on a
1/60 s grid).

## Per-animation results

The "Δ" column is ours minus Safari. Verdicts:

- **MATCH**: within 1 frame and 2 pt, or inside the recorder noise.
- **DEVIATES**: over 1 frame or 2 pt, repeatable.
- **MISSING**: Safari has the behaviour; we don't.

| # | Animation | Safari (measured) | Ours (measured) | Δ | Verdict | Evidence |
|---|---|---|---|---|---|---|
| 1a | Grid → page, tap a card (zoom in). Card width 177 → 402 | 3 runs. t10/t50/t90/t99 = 25–29 / 87–110 / 216–240 / 372–409 ms. Settles (0.5 pt) at 523–542 ms. The first frame moves 7–11 pt, the second about 21 pt. No overshoot | 3 runs (A). 5–24 / 69–96 / 202–227 / 373–397 ms. Settles at 538–563 ms. The first frame moves **31 pt** every run (launch 8.5 progress/s) | Ahead by about 1 frame in the first 50 ms (20–34 pt at 33–50 ms). t90 and t99 match | DEVIATES (onset only) | `1-zoom/open-tap-4.png`, `open-side-by-side.png`, `ours-zoom3.csv`, `saf-zoom3.csv` |
| 1b | Grid → page via Done | Same curve as the tap: t50 87, t90 221, t99 380 ms | Done zooms the active card, with the same curve as 1a | as 1a | MATCH (as 1a) | `saf-zoom3.mp4` at 15.49 s |
| 1c | Page → grid, button (Safari: … → All Tabs) | 2 runs. 27–34 / 81–86 / 183–184 / 266 ms. Undershoots by **1.4 pt**, then creeps back to rest at 560 ms | 3 runs (A). 21–22 / 81–91 / 193–195 / 266–276 ms. Undershoots by **2.0 pt**, at rest at 403–408 ms | t50–t99 within 1 frame. Tail rest 150 ms earlier; undershoot 0.6 pt deeper | MATCH | `1-zoom/out-button.png`, `close-side-by-side.png` |
| 1d | Page → grid, swipe up on the address bar | Interactive: the page follows the finger, then springs. 2 runs: t99 390–442 ms, at rest 740–783 ms | **No response.** A swipe up on the toolbar does nothing (screenshots before and after are identical) | — | MISSING | `1-zoom/out-swipe.png`, `shots/o-a.png` and `o-b.png` |
| 1e | Pinch in or out | Not scriptable with AXe | Not scriptable | — | UNVERIFIABLE | — |
| 1f | First zoom after launch | — | Run 1 (A) holds at width 392.7 for **230 ms** (1.378 → 1.607 s), then jumps 7 pt. Later runs are smooth | — | DEVIATES (one-off stall; possibly a first-use hitch) | `1-zoom/ours-zoom.csv` |
| 2a | New Tab from the grid (+) | (+) acts at once. The count changes about 20 ms after the tap. About 50–70 ms later the Start Page appears **centred at about 0.6–0.77 scale, blurred, over the blurred grid**, and grows to full screen. Fit of the button edge from the first sharp frame: 0.34 / 0.97 with v0 10/s. Tap to rest about 540 ms; first visible frame to rest about 490 ms | Build B. (+) opens a **menu** (New Terminal / New Tab), which costs a second tap. The page grows **from the grid slot** of the new card (bottom right). First visible frame to rest **≈ 360 ms**. Fit 0.49 / 0.98, v0 14.5/s | Ours is about 130 ms **faster**, and the origin differs (the slot, against Safari's centred scale and blur) | DEVIATES (shape and origin, not speed) | `2-newtab/newtab-side-by-side.png`, `saf-new-sheet.png`, `ours-new-4daaf01-sheet.png`, `newtab-4daaf01.png` |
| 2b | New Tab from inside a page | … → New Tab. The new page cross-fades in place | **No path.** The page menu has no New Tab; only a swipe past the last tab creates one | — | MISSING | `shots/o-menu.png`, `desc` dump in the notes |
| 3a | Close with ✕: the fade and scale of the closed card | The card fades and scales down. The count changes about 66–99 ms after the tap | The card fades with a 0.9 scale. The count crossfades at about 132–165 ms | Count about 2–4 frames late | DEVIATES (count timing, eyeballed) | `3-close/xclose-sheet.png` |
| 3b | Close with ✕: reflow of the remaining cards | 0.432 / 0.890 (rms 2.0 pt). 0.7 pt overshoot. At rest at 557 ms (prior `tabclose1`: 0.427 / 0.887) | Build A 0.396 / 0.952; build B 0.391 / 0.944 (rms 0.7–1.0 pt). No overshoot. At rest at 433–435 ms. The code says 0.43 / 0.89 | Mid-curve ahead by up to **11–13 pt at 100–117 ms**. At rest about 120 ms early | DEVIATES | `3-close/xclose-reflow-4daaf01.png`, `.csv` |
| 3c | Reflow z-order (cards crossing) | Each card keeps its stacking for the whole move | Build A: two terminal cards ("top" and "zsh") **swap z-order mid-flight**. "zsh" is above at 1.25 s and "top" is above at 1.27 s | — | DEVIATES (glitch) | `3-close/ours-xclose.mp4` at 1.22–1.33 s |
| 3d | Swipe left: lift | Scale 1.093 (176 → 192) within about 80 ms | Scale 1.097 (171 → 188) within about 45–95 ms | — | MATCH | `ours-swipe-c.csv`, `saf-swipe-c.csv` |
| 3e | Swipe left: tracking | For the same AXe drag (100 pt over 1.0 s), the card centre moves **−104.6 pt**. About 27 pt of that comes in the first 80 ms, as Safari catches up the touch slop | **−90.3 pt**. The first 80 ms add only about 12 pt; the rate after that is the same (about 78 pt/s) | **−14 pt** behind the finger for the whole drag | DEVIATES | `3-close/swipe-slow-side-by-side.png` |
| 3f | Swipe right: rubber band | **+44 pt** for 100 pt of finger. Always springs back | **+34 pt** (the formula gives f(90 pt), because of the lost slop) | −10 pt | DEVIATES | same |
| 3g | Spring back after a slow release (−100 pt) | From the turnaround: 0.562 / 0.918 (rms 0.3 pt). t50 149, t90 314, at rest 565 ms. Safari keeps the finger's leftward velocity for 1–2 frames before reversing | 0.637 / 0.884 (rms 0.27 pt; the code says 0.66 / 0.86, from a device fit). t50 148, t90 324, at rest 532 ms | Under 1 frame; largest delta 4 pt at 83 ms | MATCH | `3-close/snapback.png` |
| 3h | Lift scale back to 1.0 on spring back | t50 133 ms, t90 281 ms. 0.7 pt overshoot | t50 123 ms, t90 291 ms | 1.3 pt at most | MATCH | `3-close/lift-scale-back.png` |
| 3i | Spring back after a right drag | 0.75 / 0.81, at rest 468 ms | 0.82 / 0.89, at rest 467 ms. The card's right edge clips at the screen edge, so it tracks poorly (rms 2 pt) | At rest within 1 ms | MATCH | `3-close/rubber-release.png` |
| 3j | Fling close (100 pt in 0.12 s): fly-off | The card stays lifted and opaque and **keeps going left at about 1170 pt/s**. It leaves through the left screen edge and is gone about 190 ms after it starts to accelerate. The count changes at about 99 ms | Builds A and B. The card **stops at about x = 210 pt (centre) for 100–130 ms**. Then it **fades out in place** (translucent over about 4 frames), gone at about 400 ms. It never reaches the screen edge. The count changes at about 297 ms | About 200 ms longer, a different motion (stop then fade, where Safari slides off), and the count about 200 ms late | DEVIATES (**most visible**) | `3-close/fling-4daaf01-sheet.png`, `fling-sheet.png`, `ours-close-4daaf01.csv` |
| 3k | Fling: z-order of the swiped card during the exit | The card is above its neighbour | Build B. The fading card stays **above** its neighbour (cmux), and the incoming reflow card passes beneath it | — | MATCH (known bug 1 is not reproduced) | `3-close/fling-4daaf01-sheet.png` |
| 3l | 2 → 1 (lone tab) | The remaining card grows into the centred slot: 0.450 / 0.869, at rest at 425 ms, 0.6 pt overshoot. Stays in the grid with "1 Tab" | Build B. 0.435 / 0.843, at rest at about 320 ms (tracking was lost at the end). Stays in the grid with "1 Tab". **No 46 pt jump** (the Round 17 artifact is gone) | t50 within 1 frame. Largest delta 5.9 pt at 100 ms | MATCH | `3-close/two-to-one.png`, `two-to-one-side-by-side.png` |
| 3m | Closing the last tab | Safari closes it and **at once presents a fresh Start Page tab**. The page scales up from about 0.95 over about 200 ms, and the count becomes "1" | Build B. **Empty grid, "0 Tabs"**, no page | — | MISSING | `3-close/last-tab-side-by-side.png`, `saf-last-sheet.png` |
| 4a | Grid flick deceleration | Native UIScrollView | Native: same decay shape; the peak and rest within the vshift drift | — | MATCH | `4-scroll/flick-top-side-by-side.png`, `*-scroll.csv` |
| 4b | Rubber band at the top or bottom (200 pt drag) | +91 pt / −91 pt; at rest about 560 ms after release | +91 pt / −91 pt; at rest about 560 ms | 0 pt | MATCH | `4-scroll/*-scroll.csv` |
| 4c | Active card kept in view on return to the grid | After 4 address-bar swipes to an off-screen tab, the grid opens scrolled to it | The run was spoiled by defect D7 (a swipe opened the page menu and closed a tab). Not re-measured | — | INCONCLUSIVE | `6-barswipe/` |
| 5a | Long press on a card | The card lifts (the others dim), and a **context menu** opens: Copy Link, Pin Tab, Duplicate Tab, Select Tabs, Move Tab, Close Tab, Close Other Tabs | **Nothing happens** | — | MISSING | `5-longpress/longpress-side-by-side.png`, `shots/saf-lp.png`, `ours-lp.png` |
| 5b | Drag to reorder | Long press, then drag: the cards swap (zsh and HackerNews traded slots) | No reorder | — | MISSING | `5-longpress/saf-reorder.mp4` |
| 6a | Swipe between tabs on the address bar | The page slides to the neighbour; the tabs change one per swipe | It switches tabs, but a swipe that **starts on a toolbar button** (≡ page menu, or the terminal title capsule) also **opens that menu** on touch-up. A later swipe that started on the menu's "Close Tab" **closed Hacker News** | — | DEVIATES (gesture conflict; data loss) | `6-barswipe/bar-side-by-side.png`, `ours-bar.mp4` at 0.5–5.5 s |
| 6b | Toolbar, title and ✕ fades during the zooms | See browser.md Round 10 / 11 | Not re-measured; the 1a / 1c contact sheets show no flash | — | not re-measured | `1-zoom/*-side-by-side.png` |
| 7a | A Mac-side new tab while the grid shows | Nearest Safari equivalent: a new tab adds a card while the count changes | **Not reproducible on the mock** (no host trigger). From code, `BrowserModel.handle(.browserUpdated)` runs `tabs.append(tab)` and `terminalUpdated` runs `syncOrder()` with **no animation transaction**. The new card and the shifted neighbours jump in a single frame | — | UNVERIFIED (code reading) | `CNBrowserUI/BrowserModel.swift:167`, `TabsModel.swift:270–276` |
| 7b | A Mac-side close while the grid shows | Same as the ✕ reflow | From code, `.browserClosed` is animated on `reflow` (586de4e) | — | UNVERIFIED (code reading) | `BrowserModel.swift:171–176` |
| K | CmuxTabsKit demo (274892104) | — | ✕ close: fade, then reflow; count at about 143 ms. **Fling: the card fades and shrinks in place within about 100 ms** (no stall), with no slide off the screen. Like the app, it doesn't fly off | Same as 3j, minus the stall | DEVIATES | `kit/kit-sheet.png`, `kit/kit-fling-sheet.png` |

## Interruptibility

All tests ran on Build B (ours) and Safari with timed AXe `batch` steps.

| Test | Safari | Ours | Verdict | Evidence |
|---|---|---|---|---|
| Grab a card mid snap-back / mid-exit (AXe `swipe` of 100 pt over 1 s, then a second 100 pt swipe 0.15 s later) | The **first swipe closed** the card (AXe `swipe` ends with release velocity). The second swipe grabbed the **next card mid-reflow** and closed it too (5 → 3) | The **first swipe sprang back**: the same input didn't commit (D3, the lost slop). The second swipe grabbed the card mid snap-back and closed it (5 → 4). Both grab from the current position | DEVIATES (commit), MATCH (retarget) | `8-interrupt/a-sheet.png` |
| Tap another card during a zoom-out | **Queues.** The zoom-out finishes, then the tapped card opens (about 380 ms after the tap) | **Queues.** The zoom-out finishes, then the tapped card opens (about 480 ms after the tap) | MATCH (about 100 ms slower, one run) | `8-interrupt/b-saf.png`, `b-ours.png` |
| Scroll during a reflow | The scroll is accepted; the reflow continues | The scroll is accepted; the reflow continues; no overlap left | MATCH | `8-interrupt/*-c-scroll-during-reflow.mp4` |
| ✕ twice, 0.15 s apart | Both close (4 → 2) | Both close (3 → 1) | MATCH | `8-interrupt/*-d-rapid-x.mp4` |
| Swipe a card during the zoom-out (0.1 s after the start) | **Accepted**: the swiped card closed (3 → 2) | **Ignored**: no close, and no card left offset | DEVIATES (6A.2 edge case 1 allows "does nothing" only for the card that is zooming; Safari accepts other cards) | `8-interrupt/*-e-swipe-during-zoomout.mp4` |
| Done tapped twice, 0.1 s apart | The second tap lands on the page's "…" button and opens its menu (that button sits where Done was) | The second tap lands on the tabs button and **reverses** to the grid (that button sits where Done was) | Matches each layout; no stuck state | `8-interrupt/*-f-done-twice.mp4` |
| Reversal mid-zoom | Previously measured (`browser-springs-verify.md`) | Not re-measured | — | — |

## Known bugs (re-measured on 4daaf015e476)

| Known bug | Result | Numbers |
|---|---|---|
| A swiped card slides under its neighbour on release | **Not reproduced.** It stays above its neighbour during the exit and the spring back | `3-close/fling-4daaf01-sheet.png`. The real defect here is D1 (stop, then fade in place) |
| Closing a browser tab doesn't animate the reflow, while a terminal close does | **Not reproduced** (mock) for ✕ and swipe closes. A browser ✕ reflows on 0.39 / 0.94, and a terminal swipe-close reflows too. A host-originated `browser.closed` wasn't exercised (no host on the mock) | `3-close/xclose-reflow-4daaf01.csv`, `ours-close-4daaf01-sheet.png` at about 6.0 s |
| New Tab creates two cards | **Not reproduced** (mock, A and B): one card each time (5 → 6). Not run against the real host, where the device clip was recorded | the `desc` dumps in the notes; `2-newtab/ours-new-4daaf01-sheet.png` |
| The New Tab zoom is slower than Safari's | **Not reproduced: ours is faster.** First visible frame to rest is about 360 ms for ours and about 490 ms for Safari; tap to rest is about 400 ms and about 540 ms. What differs is the origin and the look (D5) | `2-newtab/newtab-side-by-side.png` |

## Ranked defects (most visible first)

1. **D1. The fling or swipe close doesn't fly off; it stops, then fades in place.**
   - Safari keeps the lifted, opaque card moving left at the release speed
     (about 1170 pt/s for a 100 pt / 0.12 s flick). It exits through the left
     edge about 190 ms after it starts to accelerate.
   - Ours (Builds A and B) parks the card at about x = 210 pt (centre) for
     100–130 ms after release. It then fades it out in place over about 4
     frames and removes it at about 400 ms.
   - The count changes at about 297 ms for ours and about 99 ms for Safari.
   - The kit fades and shrinks it in place in about 100 ms, with no stall.
   - Likely cause: the exit waits for the host's close confirmation (Round
     15), and the confirmed removal uses the `.opacity + .scale(0.9)` removal
     transition instead of continuing the fly-off. Safari's motion is
     independent of the close result.
2. **D2. Closing the last tab leaves an empty grid ("0 Tabs").** Safari closes
   it, opens a fresh Start Page at once, and zooms it in (scale about 0.95 → 1
   over about 200 ms; the count becomes 1).
3. **D3. The swipe tracking loses the touch slop.**
   - With the same 100 pt drag, ours moves the card 90.3 pt and Safari moves
     it 104.6 pt. Safari catches up about 27 pt in the first 80 ms; ours about
     12 pt.
   - The right rubber band gives 34 pt for ours and 44 pt for Safari.
   - Result: the same AXe `swipe` (100 pt / 1.0 s) closes the tab in Safari
     and springs back in ours.
   - Fix: measure the translation from touch-down, not from gesture
     recognition, or add the recognition offset.
4. **D4. A swipe on the toolbar opens toolbar menus.** A horizontal swipe that
   starts on ≡ (page menu) or on the terminal title capsule opens that menu
   on touch-up after 210 pt of travel. In this run, a following swipe then
   landed on "Close Tab" and **closed a tab**. Safari never opens a menu from
   a swipe. The buttons must cancel once the pan is recognised.
5. **D5. The New Tab transition has the wrong origin and look, and (+) is a
   menu.**
   - Safari: (+) acts at once. About 50–70 ms later the Start Page appears
     centred at about 0.6–0.77 scale with a blur, and grows to full screen.
     The tail fits 0.34 / 0.97 with v0 about 10/s, and the grid behind is
     blurred.
   - Ours: (+) needs a second tap in a menu. The page grows from the new
     card's grid slot and reaches rest in about 360 ms (fit 0.49 / 0.98, v0
     14.5/s), about 130 ms sooner than Safari.
   - From inside a page, Safari's … → New Tab has no equivalent in ours.
6. **D6. Long press and drag to reorder are missing.**
   - Safari: a long press lifts the card (scale about 1.06, the other cards
     dim) and opens a menu with Copy Link, Pin Tab, Duplicate Tab, Select
     Tabs, Move Tab, Close Tab and Close Other Tabs.
   - Safari: a long press then a drag reorders the cards.
   - Ours does nothing.
   - Note: Round 14's "no long press on a card in Safari" is wrong for this
     iOS 26 build.
7. **D7. Swipe up on the address bar doesn't open the grid.** In Safari this
   is the main way to open the grid in the Compact layout. It is interactive:
   the page follows the finger, and the curve reaches t99 at 390–442 ms and
   rests at 740–783 ms.
8. **D8. The ✕ reflow spring is too stiff and too damped.**
   - Measured 0.39 / 0.94–0.95 in two builds (rms 0.7–1.0 pt). Safari is
     0.43 / 0.89 (here and in `tabclose1`), and `BrowserMotion.reflow` says
     0.43 / 0.89.
   - Ours leads by 11–13 pt at 100–117 ms and rests about 120 ms early,
     without Safari's 0.7 pt overshoot.
   - The 2 → 1 reflow fits 0.435 / 0.84, close to Safari. So some other
     animation probably overrides the ✕ path's transaction; one candidate is
     a static-bitmap card moved by a different `withAnimation`.
9. **D9. The reflow z-order flips mid-flight.** On Build A, two terminal cards
   crossing during a reflow swapped stacking between 1.25 s and 1.27 s
   (`ours-xclose.mp4`). Safari keeps the stacking fixed for the whole move.
10. **D10. The count label updates late on a close.** On a ✕ close it changes
    at about 132–165 ms for ours and about 66–99 ms for Safari. On a fling it
    changes at about 297 ms and about 99 ms. These times are eyeballed from
    the sheets.
11. **D11. The zoom-in onset leads by about 1 frame.** Ours always jumps 31 pt
    in frame 1 (launch 8.5 progress/s); simulator Safari moves 7–11 pt, then
    about 21 pt. The delta is 20–34 pt at 33–50 ms, and the curves agree from
    t90 on. The launch came from the device recording
    (`browser-springs-verify.md`), so confirm on a device before changing it.
    The low-priority one-off stall of 230 ms on the first zoom after launch
    (1f) belongs here too.
12. **D12. A swipe on another card during a zoom-out is ignored.** Safari
    accepts it and closes the card.
13. **D13. Mac-side new tabs pop in (from code, unverified).** In
    `BrowserModel.handle(.browserUpdated)`, `tabs.append` and the terminal
    `syncOrder()` run without an animation transaction.
14. **D14. The non-streamable GitHub card often has no accessibility element.**
    It is missing from `axe describe-ui` on grid load, and when it does show
    its label lacks the ", tab" suffix. This is minor and not an animation
    issue.

Matches worth keeping: the page → grid button zoom, the lift scale, the spring
back after a slow release, the lift scale back to 1.0, the 2 → 1 reflow, grid
scroll and rubber band, rapid ✕, scrolling during a reflow, a tap queued
during a zoom-out, and the swiped card's z-order during the exit.
