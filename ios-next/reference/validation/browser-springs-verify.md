# Browser spring and timing constants: independent check

This is an independent re-measurement of every spring and timing constant in
`CNBrowserUI/BrowserTokens.swift` and `CNBrowserUI/TabZoom.swift` against the
Safari reference recordings. I did not reuse earlier numbers. The earlier
claims in `browser.md` are compared at the end.

## Method

- **Timestamps:** every sample uses the frame's real presentation time
  (`ffprobe -show_frames` pts; frames decoded with `-fps_mode passthrough`).
  Nothing is resampled to a fixed 60 fps grid.
  - Device recordings are 60 fps with a few 25–35 ms gaps: 9 in `tab-zoom-device`, 3 in `tab-reverse-device` and 23 in `safari-scroll-into-view-device`.
  - Simulator recordings are variable frame rate. Their stamps are jittery (2–20 ms intervals, often in near-duplicate pairs), and they stall for up to 100 ms or more.
- **Tracking:**
  - Tab zoom: the page content is tracked by multi-scale normalized
    cross-correlation of a large content template taken from the full-page
    frame. The scale is refined on the full 3x frames to 0.0005 (0.2 pt of card
    width). Card width = scale × 440 pt.
  - Reversal recording: in addition, the white card's left and right edges are
    measured at subpixel precision (median over 30 rows), because the
    content-scale metric and the frame both jump at a reversal.
  - Toolbar: centroid of the URL label's ink and the label's ink extent, at full
    resolution.
  - Side buttons: ink mass (opacity × area).
  - Keyboard: vertical NCC of two key rows.
  - Page menu: bright-panel edges.
  - Reflow: card translation by NCC.
- **Spring model:** SwiftUI `spring(response:dampingFraction:)` with mass 1,
  stiffness (2π/R)², damping 4πζ/R. The fit is a least-squares fit of
  `start + (end − start)(1 − u(t − t0))` with the onset `t0` free. The start
  and end are fixed from the rest frames unless noted. Fits were run with the
  initial velocity fixed at 0 and with it free.
- **Reported values:**
  - "±" is the 95% interval from the Jacobian covariance. Residuals are
    autocorrelated, so treat it as a lower bound.
  - "rms/max" is the residual of the best fit.
  - "code rms/max" is the residual of the constant in the code, with only `t0`
    refit.
  - "Settle" is the time until the curve stays within 0.5 pt of the end.
- **Glitch frames:** the iOS screen recorder emits single glitch frames that
  show the end state (`tab-zoom-device` f189, f430, f433; `scroll-into-view`
  f59; `tab-reverse` f258). These are excluded and named in each row.
- **Scripts:** throwaway scripts in `/tmp/sv/scripts`: `track.py`, `refine.py`,
  `fit.py`, `dofit.py`, `revfit.py`, `edges.py`, `ink.py`, `tailfit.py` and
  `fitfree.py`.

## Toolbar (`BrowserMotion`)

Reference: `vid/collapse.mp4` (simulator, 402 pt). The tracked value is the
URL label's center y (817.1 → 844.6 pt, a 27.5 pt span).

| Constant | Code | Fitted (R / ζ) | 95% range, residual | Frames used | Verdict |
|---|---|---|---|---|---|
| `collapse` | 0.39 / 0.86 | Run 1: 0.373 / 0.878. Run 2: 0.388 / 0.866 | ±0.006–0.008 / ±0.010–0.013. rms 0.12–0.13 pt (max 0.44). Code rms 0.13–0.15 pt (max 0.54). Settle 270 ms (fit) vs 269 ms (code) | 56 + 48 sim frames (f4–59, f272–319) | **MATCH** |
| `expandScroll` | 0.41 / 0.87 | 0.385 / 0.880 | ±0.009 / ±0.014. rms 0.10 pt. Code rms 0.16, max 0.54 pt | 52 (f178–229). The recorder stalled 108 ms just before onset, and the label first jumped 6 pt (f175) | **MISMATCH (minor)** → 0.385 / 0.88. Low–medium confidence because of the stall |
| `expandTap` | 0.37 / 0.90 | 0.390 / 0.879 | ±0.009 / ±0.015. rms 0.17 pt. Code rms 0.20, max 0.62 pt | 62 (f428–489) | **MISMATCH (minor)** → 0.39 / 0.88. The visual difference is ≤ 0.6 pt |
| `sideOut` | linear 0.14 s | Ink reaches 0 at 105–117 ms after onset in both collapses (100 → 54% at 47 ms → 18% at 80 ms). Modeled as opacity ramp × the collapse spring's scale², the ramp length is about 0.10–0.11 s | Ink proxy, not pure opacity | 2 collapses, about 14 frames each | **MISMATCH** → `linear(duration: 0.10)`. Medium–low confidence |
| `sideIn` | linear 0.18, delay 0.12 | Ink starts 85–94 ms after onset, 50% at about 158 ms, 90% at about 270 ms, 100% at about 330 ms. The shape is ease-out, not linear. The code gives 22% at 160 ms where Safari shows about 50% | Ink proxy | 2 expands (scroll, tap) | **MISMATCH** → about `easeOut(duration: 0.23).delay(0.09)` |

All three toolbar springs fit about 0.38–0.39 / 0.87–0.88 within noise. One
shared spring of 0.385 / 0.875 is defensible.

## Address editing

| Constant | Code | Fitted | 95% range, residual | Frames used | Verdict |
|---|---|---|---|---|---|
| `keyboard` (field rides with the keyboard) | 0.35 / 1.0 | Device keyboard rise: **0.337 / 1.007**. Simulator `edit.mp4`: 0.33 / 0.98 | Device: ±0.012 / ±0.013, rms 0.12 pt, settle 477 ms. Simulator: ±0.10 / ±0.11, rms 2.4 pt (timestamp jitter) | Device `tab-zoom-device` f767–795 (26 frames; the first about 3 frames are below the screen edge). Simulator f27–59 | **MATCH**. ζ is exact; R is 4% shorter, and 0.34 fits marginally better |
| `editEnd` (Go) | 0.30 / 1.0 | Simulator `go.mp4`, capsule left edge 33.7 → 89.6 pt: **0.320 / 1.056** | ±0.032 / ±0.075. rms 0.64 pt. Code rms 1.24, max 3.2 pt | 33 sim frames (f12–44) | **MATCH** (within the range). Low confidence: simulator jitter and a single edge |

The device keyboard dismissal (f854–861, 7 visible frames) fits 0.336 / 0.70
± 0.28. It is too short to use.

## Page menu

| Constant | Code | Fitted | 95% range, residual | Frames used | Verdict |
|---|---|---|---|---|---|
| `menu` | 0.40 / 0.78 | No single spring fits the whole droplet morph (rms 4–12 pt). Tail fits (from 2.543 s, free velocity): right edge **0.356 / 0.86** or 0.337 / 0.73 from the next frame; top edge **0.337–0.347 / 0.69–0.79**. Overshoot: right edge 6 pt (346 vs 339.7), top edge about 33 pt | ±0.016–0.06 / ±0.09–0.15. rms 0.85–2.2 pt | Sim `pagemenu.mp4` f4–47, stalls of 37 ms or more | **INCONCLUSIVE** (the reference is not a single spring). ζ is consistent; R leans to about 0.35 |

## Tab overview zoom (`TabZoom.swift`)

The `BrowserMotion.overviewOpen`, `overviewClose` and `newTab` tokens are
**dead**: nothing references them. The zoom runs on `ZoomSpring`, and a new tab
uses `.toPage` through `start(from: 1, …)`. The rows below verify `ZoomSpring`.

References (device, 440 pt wide):

- `tab-zoom-device.mp4`: 3 opens at f188, f638 and f877; 3 closes at f430,
  f727 and f1091.
- `tab-reverse-device.mp4` (1-tab layout, card 293.7 pt): 1 plain open (f178),
  1 plain close (f113) and 5 reversals.
- `safari-scroll-into-view-device.mp4`: 1 close (f61). It has many dropped
  frames.

| Constant | Code | Fitted | 95% range, residual | Frames used | Verdict |
|---|---|---|---|---|---|
| `toOverview` | 0.33 / 0.91 | **0.369 / 0.873** (Fotmob, all frames). 0.369 / 0.874 (Google). 0.365 / 0.882 (LinkedIn). **0.371 / 0.874** (1-tab). Initial velocity fits ≈ 0 | ±0.002–0.004 / ±0.004–0.006. rms **0.23–0.30 pt**. Code rms 1.4–2.7 pt, max 3.5–5.9 pt. Settle (0.5 pt, 245 pt span): 440–470 ms fitted vs 317 ms for the code. Overshoot 0.3–0.4% (about 1 pt) | 38 + 36 + 35 + 25 frames. Excluded: Google f189 (glitch) and f190–191 (stalled onset frames: the second sits 12 pt behind the other three opens); LinkedIn f639 (glitch) and f640–641 (onset; the fit with them kept is 0.328 / 0.925, rms 1.5) | **MISMATCH** → **0.37 / 0.875**. High confidence: 4 events agree within 0.006 / 0.009, including the 1-tab layout |
| `toPage` | 0.335 / 1.0 | v0 = 0 without the 1–2 onset frames: 0.332 / 1.045, 0.329 / 1.047, 0.305 / 1.098; Fotmob (no onset frames) 0.394 / 0.97. With the onset frames, no v0 = 0 spring fits. Safari reaches **1850–2700 pt/s within 2–3 frames**, while 0.335 / 1.0 peaks at 1690 pt/s at 53 ms. Free initial velocity: **0.385 / 0.993, v0 8.4 progress/s**; 0.404 / 0.978, v0 9.1/s; 0.44 / 0.95, v0 8.4/s (1-tab) | v0 = 0 trimmed: rms 0.31–0.49 pt. Free v0: rms 0.32–0.54 pt. Code: rms 1.5–2.6 pt, max 3.0–11 pt. Measured settle (0.5 pt) 480–500 ms vs 450 ms for the code | 42, 38, 34 and 40 frames (excluded f430, f433 and f1086–1092 as glitches) | **PARTIAL MISMATCH**: the middle and tail match, but the first 50–100 ms are too slow. Suggest `toPage` ≈ 0.39 / 1.0 with a starting velocity of about 8.5 progress/s, or at minimum ζ ≈ 1.05. Medium confidence |
| `reversal` + `velocityKeptOnReversal = 0.2` | 0.39 / 0.88, 1/5 velocity | Safari **jumps** toward the new target at a reversal: +19 to +22 pt in one frame toward the page (f16→17, f44→45), and −3 to −17 pt toward the grid (f267→268, f301→302, f330→331). Both the card edges and the content scale show it. After the jump the motion is a fresh spring with near-zero velocity, using the ordinary destination spring. Toward the page: 0.308 / 1.027 and 0.331 / 1.041 (≈ `toPage`). Toward the grid: 0.354 / 0.875, 0.346 / 0.842, 0.369 / 0.848 (≈ `toOverview`) | Tail fits: rms 0.14–0.30 pt, ±0.006–0.010 / ±0.009–0.020. A continuous model (the code's structure, free R / ζ / kept fraction) cannot fit: max error 4.5–17 pt, and the kept fraction is unidentifiable (interval spans −0.5…1.5). Code 0.39 / 0.88 with 0.2 kept: rms 2.0–5.4 pt, max 7.5–18 pt; with full velocity, rms 1.9–5.3 | 5 reversals (31, 33, 38, 30 and 27 frames) | **MISMATCH**. The recording does not support the 1/5 velocity. Suggest the destination's own spring (`toPage` / `toOverview`) with about 0 kept velocity; a short jump toward the target is optional |
| `release` (after a pinch) | 0.36 / 0.9 | No recording contains a pinch | — | — | **UNVERIFIABLE** |

**Open vertical position (observation, medium–low confidence).** On open, the
content origin's y leads the width: it reaches 70% when the width is at 50%,
then overshoots by about 6% (4 pt). Fitted alone, y gives 0.27–0.38 /
0.65–0.79. On close, y and width move together. The code drives x, y, width
and height from one progress value. The metric cannot separate the card frame
from the content offset inside it, so treat this as a lead to check, not a
verdict.

## Overview grid, new tab and swipe

| Constant | Code | Fitted | 95% range, residual | Frames used | Verdict |
|---|---|---|---|---|---|
| `reflow` | 0.38 / 0.85 | Card translation in `tabclose1.mp4`: x **0.427 / 0.887**, y **0.427 / 0.890**. x and y share one spring; there is no arc lag. Free v0: 0.46 / 0.86 | ±0.011–0.012 / ±0.017. rms 1.1–1.5 pt. Code rms 4.5–6.8 pt, max 11–16 pt | 43 sim frames (regular 17 ms stamps after onset) | **MISMATCH** → **0.43 / 0.89** |
| `newTab` | 0.40 / 0.9 | **Dead token.** The new tab actually uses `toPage`. Simulator `newtab.mp4`: 0.35 / 1.0, with the start scale assumed to be 0.45 because the first frames are blurred | ±0.06 / ±0.10. rms 2.1 pt. Code rms 2.7 pt | 42 sim frames | **UNVERIFIABLE** (weak data; the token is unused) |
| `swipe` | 0.40 / 0.9 | The release time is unknown. The outgoing page leaves the screen before it settles, and no fit converges (rms 3.6 pt or more). The incoming page settles about 300 ms after the finger stops, which is consistent with but does not confirm 0.4 / 0.9 | — | `tabswipe.mp4` f40–74 | **UNVERIFIABLE** |

## Code review: velocity handling in `TabZoom.swift`

- **Reversal:** `go(toOverview:)` while `.animating` with a different target
  calls `animate(…, spring: .reversal, keepVelocity: 0.2)`, which runs
  `velocity *= 0.2`. It does keep one fifth of the progress velocity, as
  documented. The recordings do not support it (see above).
- **Integrator:** `step` uses ω = 2π/R and damping 2ζω (= 4πζ/R), which is the
  SwiftUI definition. It uses semi-implicit Euler with h ≤ 1/600 s and dt
  clamped to 0.1 s. This is correct.
- **Release from a pinch:** `endInteraction` stores the gesture velocity and
  calls `animate(…, spring: .release, keepVelocity: 1)`, so the spring starts
  with the finger's velocity. This is correct. Units:
  - `pagePinch`: progress = (W − W·s)/span, so v = −ṡ·W/span. Correct chain
    rule.
  - `cardPinch`: progress = (W − card·s)/span, so v = −ṡ·card/span. Correct.
- **Minor issues:**
  - `PageSurface.pinch` passes `scale = g.scale / 0.94` but the raw
    `g.velocity`. The velocity is about 6% too small; it should be
    `g.velocity / 0.94`.
  - The DEBUG synthetic pinch always ends with velocity 0.
  - The `startedFromOverview` parameter is ignored.
  - `sideOut` and `sideIn` are not passed through `motion.resolve`. They are
    opacity-only, so this is harmless.

## Earlier claims in `browser.md` compared

- **Collapse 0.38 / 0.87:** consistent with mine (0.373–0.388 / 0.866–0.878).
- **Expand by tap 0.44 / 0.85:** mine is 0.39 / 0.88.
- **Expand by scroll, "not measured":** I measured 0.385 / 0.88.
- **Overview open 0.330 / 0.91, settles in 16 frames:** not reproduced.
  - Four events, measured with real timestamps and full-resolution content
    scale, give 0.365–0.371 / 0.873–0.882, settling at about 450 ms.
  - The claimed disagreement between the 2-tab and 1-tab recordings (0.33 vs
    0.39) does not exist. The 1-tab open fits 0.371 / 0.874.
- **Overview close 0.335 / 1.00, 23 frames:** the middle and tail agree. The
  onset is faster than any spring from rest, which matches the note that our
  frames 1–3 trail.
- **Reversal 0.39 / 0.88 with 0.2 kept velocity:** not supported.
  - Safari's frame jumps toward the new target at the reversal, then follows
    the destination's normal spring from near rest.
  - No continuous model fits the reversal frames to better than 4.5–17 pt max
    error.
- **Reflow ≈ 0.38 / 0.85, pass:** the measured value is 0.43 / 0.89, and the
  code's error reaches 11–16 pt.
