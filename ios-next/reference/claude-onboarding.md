# Claude iOS launch and onboarding: reference capture

Source: `~/nxios-ref/claude/onboarding-device.mp4` (real iPhone 17 Pro Max screen
recording, 1320x2868 px = 440x956 pt @3x, 10.6 s). The container advertises
120 fps, but the frame timestamps (`ffprobe -show_entries frame=pts_time`) are a
60 Hz cadence: 635 frames, 630 deltas of 16.7 ms and 4 dropped-frame gaps of
18–25 ms. All times below are the real presentation timestamps; frame numbers
are 1-based indices of the passthrough extraction
(`ffmpeg -fps_mode passthrough`). Geometry is in points (px / 3).

Only dark appearance is visible (the device was in dark mode). The recording
covers Spotlight → launch → intro → sign-in options → a tap on "Continue with
Google" → its loading state. The Google sheet, the email entry and the code
step never appear, so their reference values are unknown; our implementation
extends the same motion language to them (see the last section).

Crops (Claude artwork, internal reference only, never shipped):
`claude-onboarding/01-launch-frame.png`, `02-signin-settled.png`,
`03-handoff-115-130.png` (every frame of the hand-off), `04-illustration-phases.png`,
`05-google-press.png`.

## Timeline

| t (s) | frames | event |
|---|---|---|
| 0.00–1.15 | 1–70 | Spotlight, user taps the app icon |
| 1.18–1.46 | 72–88 | System launch zoom; the launch screen (static) fades in under it |
| 1.47–1.93 | 89–116 | Launch frame holds, completely static (0.46 s) |
| 1.924 (T0) | 117 | Hand-off: everything starts on the same frame (fitted onset 1.924 s, first moved frame 1.950 s) |
| T0 + 0.20 | 129 | Lockup settled in the header; text and buttons fully opaque |
| T0 + 0.03 → +5 s | 118– | Line illustration draws itself and keeps evolving (12 fps, see below) |
| 4.55 | 273 | Tap on "Continue with Google": label swaps to a spinner on the same frame, button presses in |
| 4.88 | 293 | Press released (scale/fill back to rest) |
| 4.88–10.6 | | Spinner keeps running (web sheet not captured) |

## Launch frame (frames 89–116)

| element | value |
|---|---|
| background | `#151515` (21,21,21), uniform; no gradient, vignette or noise |
| lockup (mark + wordmark) | x 120.7–303.3, y 458.0–497.7 (182.6 x 39.7); centre (212.0, 477.9), i.e. 8 pt left of screen centre and 0.0 pt from the vertical centre (478) |
| mark (asterisk) | 39.7 x 39.7, centre (140.5, 477.9), colour `#D6694F` |
| wordmark | serif, cap height ≈ 30.7, colour `#F7F7F5` |
| bottom brand line | small caps-like wordmark y 884.7–896.7, x 167–273 (106 x 12), colour ≈ `#898989` |
| home indicator | y 941.7–946.7 |

The first app frame equals the launch screen pixel for pixel: there is no
cross-fade from launch storyboard to app; the same lockup simply starts moving.

## Settled sign-in screen (frame 300, dark)

| element | geometry (pt) | style |
|---|---|---|
| header lockup | y 70.0–94.0 (24 tall), x 165.0–275.0 (110 wide), centred at x 220; mark 23.3 sq, centre (177.0, 81.5) | same artwork at scale 0.587 |
| illustration | x 125.7–304.7, y 281.0–461.3 (≈180 x 180) | white hand-drawn stroke (≈5 pt, round caps) + one accent fill dot |
| headline | y 509.0–537.3 (glyph box 28.3), x 49.3–366+ | serif, ≈30 pt regular, `#F9F9F7`, single line, centred |
| button 1 (Google) | x 16–424, y 691.3–738.3 (408 x 47.3) | capsule (radius 23.7), fill `#FEFEFE`, label black SF ≈17 pt semibold, logo 18 pt |
| button 2 (Apple) | y 746.3–795.3 | same |
| email field | y 803.3–851.3 (408 x 48) | capsule, fill `#0F0F0F`, 1 px (0.33 pt) stroke `#424240`, placeholder `#464549` ≈15 pt centred |
| row pitch | 56 pt (48 + 8 gap) | |
| legal footer | y 874.3–906.0, two lines, x 36.7–403 | ≈13 pt, `#B9B9B9`, underlined links |
| side inset | 16 pt | |

## Hand-off (launch → sign-in), T0 = 1.924 s

Every element starts on the same frame; nothing is staggered. The lockup
translates and scales as one layer; everything else only fades (headline,
buttons, email field, footer do not move: their bounding boxes are constant
from the first visible frame). No blur and no scale on the fading layers.

| frame | t (s) | t−T0 (ms) | mark centre y | mark size | headline α | button fill α |
|---|---|---|---|---|---|---|
| 115 | 1.917 | -7 | 477.9 | 39.7 | 0.00 | 0.00 |
| 116 | 1.933 | 9 | 477.9 | 39.7 | 0.00 | 0.00 |
| 117 | 1.950 | 26 | 380.9 | 35.3 | 0.24 | 0.20 |
| 118 | 1.967 | 43 | 313.1 | 32.7 | 0.38 | 0.37 |
| 119 | 1.983 | 59 | 251.2 | 30.3 | 0.53 | 0.53 |
| 120 | 2.000 | 76 | 200.7 | 28.0 | 0.65 | 0.66 |
| 121 | 2.017 | 93 | 161.5 | 26.3 | 0.77 | 0.77 |
| 122 | 2.033 | 109 | 133.3 | 25.3 | 0.84 | 0.85 |
| 123 | 2.050 | 126 | 113.5 | 25.0 | 0.91 | 0.91 |
| 124 | 2.067 | 143 | 100.2 | 24.3 | 0.95 | 0.95 |
| 125 | 2.083 | 159 | 91.5 | 23.7 | 0.99 | 0.98 |
| 126 | 2.100 | 176 | 86.5 | 23.7 | 0.99 | 0.98 |
| 127 | 2.117 | 193 | 83.5 | 23.7 | 1.00 | 0.99 |
| 128 | 2.133 | 209 | 81.7 | 23.3 | 1.00 | 1.00 |
| 129 | 2.150 | 226 | 81.5 | 23.7 | 1.00 | 1.00 |

Spring fits (least squares on normalised progress, onset free, zero initial
velocity; `fit.py` model = SwiftUI `.spring(response:dampingFraction:)`):

| property | from → to | response | damping | onset | rms | 99 % settle |
|---|---|---|---|---|---|---|
| lockup centre y | 477.9 → 81.5 | 0.192 s | 1.00 | 1.924 s | 0.013 | 0.203 s (12 frames) |
| lockup scale | 1.0 → 0.587 | 0.190 s | 1.00 | 1.923 s | 0.017 | 0.201 s |
| lockup centre x | 212.0 → 220.0 | (same layer) | | | | |
| headline opacity | 0 → 1 | 0.238 s | 0.88 | 1.920 s | 0.016 | 0.185 s |
| button opacity | 0 → 1 | 0.222 s | 0.92 | 1.923 s | 0.010 | 0.191 s |
| bottom brand line | 1 → 0 | ≈0.1 s fade, cross-fades with the legal footer that appears over it | | | | |

So: one critically damped spring (response ≈0.19 s) for the lockup and the same
≈0.2 s curve for every opacity. The motion is fast and decisive; the
"extravagance" is the illustration, not the reveal.

## Illustration

- A single white, slightly wobbly monoline (≈5 pt, round caps and joins) is
  drawn on by a trim-path, starting 26 ms after T0 as a dot at (291, 283) and
  growing downward; the accent dot appears at T0 + 0.55 s.
- It is animated on twelves: the crop changes every 5 frames at 60 Hz
  (12 fps), with 10-frame holds at story beats (69 changes in 8.36 s). This
  stepped cadence is what makes it read as hand-drawn, against the 60 Hz UI.
- Beats (T0-relative): 0–0.6 s profile line draws; 0.6–1.1 s accent dot grows
  (r 2 → 9 pt); 1.1–1.5 s a hand draws in; 1.5–2.5 s the dot branches into a
  network of accent nodes and edges (accent area peaks at ≈3500 px @1x);
  2.6–3.0 s the network collapses back into one dot; 3.0–4.5 s the hand
  re-forms, holds a string; 4.3–4.7 s the dot inflates into a balloon
  (accent area ×4); then slow idle drift and a second branching at 7.3 s.
- The illustration never moves as a block; its bounding box stays within
  x 111–313, y 261–467.

## Press feedback ("Continue with Google", 4.55 s)

| property | rest | pressed (first frame) | release |
|---|---|---|---|
| width | 408 (x 16–424) | 404 (x 18–422), scale 0.990 | back to 408 by 4.88 s (≈0.33 s) |
| fill | `#FEFEFE` | `#F8F8F8` | back with the scale |
| label | logo + text | replaced by a 16 pt activity spinner on the same frame | spinner stays |

No haptic is observable in a recording; the system Sign in sheets normally
add their own. The tap is the only interaction captured.

## Colours (dark)

| token | value |
|---|---|
| background | `#151515` |
| primary text | `#F9F9F7` |
| secondary (legal) | `#B9B9B9` |
| primary button fill / label | `#FEFEFE` / `#000000` |
| field fill / stroke / placeholder | `#0F0F0F` / `#424240` / `#464549` |
| accent (mark, dot) | `#D6694F` |

## What cmux-next takes from this (and what it does not)

Taken: the static launch frame identical to the first app frame; a long
enough hold that the launch feels intentional; one simultaneous hand-off where
the brand lockup springs into the header (critically damped, response ≈0.19 s)
while everything else fades in on the same curve; a living monoline
illustration animated on twelves with a single accent; white ink capsules on a
near-black ground; 16 pt insets; 48 pt rows on a 56 pt pitch; immediate
spinner-in-place loading with a 0.99 press scale.

Not taken: Claude's wordmark, asterisk, illustration, serif face, wording,
colours (accent orange) or legal copy. cmux-next uses its own mark, SF Pro /
SF Mono, CNDesign ink and `highlight` as the only accent, and an original
terminal and cellular-automaton illustration drawn in code.
