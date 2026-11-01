# Animation reference: iOS AI chat apps (measured)

Measured 2026-10-12. The source was public online video only: YouTube screen-recording walkthroughs and App Store pages. No phone was used.

## Method

- **Downloads.** Videos were fetched with yt-dlp 2026.08.19 into `~/cnm-refs/videos/<app>/yt-<id>/`, one directory per file. Contact sheets are in `~/cnm-refs/videos/<app>/sheets/`. Raw per-frame tracks are in `~/cnm-refs/work/*.txt`.
- **Tools.** Scripts are in `~/cnm-refs/tools/scripts/`:
  - `track.py`: normalized cross-correlation (NCC) template tracking along x or y, 1 px resolution.
  - `fit.py`: fits a SwiftUI spring and cubic-bezier curves.
  - `bbox.py` and `stream.py`: backdrop and streaming analysis.
  - `scan.py`: motion-event finder.
  - `sheet.sh`: per-frame tiles.
- **Tracking.** Each frame was cropped to the device screen inside the video. A patch from a rest frame (for example, the hamburger and nav row of the main content) was then located by NCC in every frame. NCC is printed per frame, so low-confidence frames are visible.
- **Normalization.** Offsets are reported in source pixels, as a fraction of the visible screen width, and in points. Points assume a 390 pt device for the ChatGPT recording (notch iPhone, "9:41" status bar) and 393 to 402 pt for the Claude and Grok recordings (Dynamic Island).
- **Timing.** Time is frame index divided by source fps. Source fps was 30 for ChatGPT, 24 or 30 for Claude, and 60 for Grok. Durations are measured from the last still frame to the frame where motion settles within 1 px (or 1%). They are therefore quantized to one frame: ±33 ms at 30 fps, ±17 ms at 60 fps.
- **Fits.** `fit.py` grid-searches a sub-frame start time together with:
  - `.spring(response:dampingFraction:)`, with damping 0.5 to 2.0 and the exact SwiftUI spring equations, including overdamped;
  - named bezier curves;
  - a locally refined free `.timingCurve`.

  RMS error is in source pixels.

> **Confidence key.** **High**: 60 fps or clean 30 fps, NCC above 0.9, repeated at least twice with matching results. **Med**: one clean sample, or a recorder that dropped frames. **Low**: inferred, partly occluded, or cut by editing.

## Sources

| App | Video | Notes |
|---|---|---|
| ChatGPT | https://www.youtube.com/watch?v=zOetZN8TMNs ("How to Use ChatGPT on iPhone: Beginner's Guide for Seniors", Ellen's Tips For iOS, 2025-09-01) | Real iOS screen recording, 1080p30, with a touch indicator. Screen is 461×1000 px in the video. Used for the drawer (×4 opens, ×3 closes), typed and dictated send, streaming, and the thinking dot. Pre-Liquid-Glass build. |
| Claude | https://www.youtube.com/watch?v=mvupWYRatl0 ("5 Ways iPhone Users Are Using Claude Wrong", Ryan's App List) | Screen recording, 1080p30, newer build with a "Code" row in the drawer. Used for drawer open ×2, close-on-select, and the "Create a project" sheet. |
| Claude | https://www.youtube.com/watch?v=duUQk9xxMfg ("How To Change The Voice In Claude App", Phones with Peter) | Screen recording in a 24 fps file. **Duplicated frames** show the recorder dropped frames, so it was used only for drawer geometry, the shadow, and the corner. |
| Claude | App Store preview, `apptrailers.itunes.apple.com/.../P1436015280_default.m3u8` (from apps.apple.com/us/app/id6473753684) | 6 s brand video ("The AI for problem solvers"). No UI motion. |
| Grok | https://www.youtube.com/watch?v=5-xt-NXeB5w ("How to Use Grok on iPhone 2026", Techrona) | Screen recording at **60 fps**, composited on a desk mockup. Screen is 410×892 px. Signed out, so there is **no drawer**. Real-time speed was checked against the iOS keyboard (a 250 px rise settled in about 0.33 s with the usual ~0.76 per-frame decay). Used for welcome, send, streaming, and the model menu. |
| Cursor | https://www.youtube.com/watch?v=ovxL42LkKNg ("Introducing Cursor for iOS", Cursor, 24 fps) | Camera-filmed phone. **Not measurable.** |
| T3 Code | https://www.youtube.com/watch?v=gIddBu2yQHs | Shows desktop only, no iOS screen recording. **Not measurable.** |
| Rejected | `frQU5fO8DrY`, `7ESMpnnVq6w`, `SqtsdLe5uCA`, `t-FrZmLMmN4`, `j0thXscVah0`, `auZ7pf7o-PU` (X app's Grok tab), `KYzu29JN06Q` / `amnmEH3UMUU` (desktop), `ocQ7ZKhHU5Q`, `p5KxBTUncoE` (OpenAI, 24 fps camera) | Handheld camera footage, desktop UI, or the wrong app. |

None of the App Store pages for ChatGPT (6448311069), Grok, Cursor, or T3 Code embed an app-preview video. Only Claude's page has one.

---

## 1. Side drawer

### ChatGPT (high confidence; 4 opens and 3 closes, all tap-driven)

| Metric | Value |
|---|---|
| Final drawer width | **385/461 px = 0.835 W**, about **326 pt on 390 pt (W − 64 pt)** |
| Style | **Push, rigid.** The drawer and content move together. Drawer offset + content offset = 385 px in every frame, so there is **no parallax**. |
| Content dim | Uniform black overlay on content. White 254 becomes 226, so **α ≈ 0.11** at full open. Status-bar glyphs are not dimmed. |
| Content corner and shadow | **None.** The leading edge is square and no shadow was detected. |
| Open trajectory (px, 30 fps, tap) | 0, 115, 225, 299, 341, 363, 374, 380, 382, 384, 385. Identical in 3 of 3 samples; the 4th was sampled at a different phase. |
| Open duration | **≈ 270–300 ms** to within 1 px (8–9 moving frames). The fitted curves reach 99% at about 260 ms. |
| Open peak velocity | 3450 px/s = **7.5 W/s ≈ 2900 pt/s** in the first frame, so velocity is at its maximum at t = 0 (pure ease-out). |
| Open overshoot | **0** |
| Open best fit | `.spring(response: 0.18, dampingFraction: 1.20)` (rms 1.5–1.9 px). `.timingCurve(0.27, 0.98, 0.32, 0.99, duration: 0.35)` (rms 0.5 px). Named curve: easeOutQuint over 340–350 ms. |
| Close (tap a chat, or tap content) | 385, 353, 234 (or 211), 134 (or 119), 71 (or 62), 36 (or 31), 18 (or 15), 9, 4, 2, 1, 0. Duration about **300 ms**, peak 3570–4260 px/s, no overshoot. |
| Close best fit | `.spring(response: 0.18–0.23, dampingFraction: 1.0–1.2)` (rms 0.6–1.2 px). `.timingCurve(0.22, 1.08, 0.42, 0.98, duration: 0.35)`. |
| Drag-driven | Not present in the footage. |

### Claude (medium-to-high confidence; 2026 build, 2 clean opens and 1 close-on-select)

| Metric | Value |
|---|---|
| Final drawer width | **343/455 px = 0.75 W** in the 2026 build (≈ 296–303 pt). The older build in duUQk9xxMfg measured about 0.81 W (≈ 318 pt). Both point to a fixed width of roughly 300–320 pt, about W − 80 to 90 pt. |
| Style | **Content-card slide over a static drawer.** Tracking the drawer's "Claude" title gave an offset of 0 in every frame, so there is **no parallax**. The content slides right as a card. |
| Drawer dim (unusual) | The *drawer* starts dimmed and brightens as the card leaves. Measured drawer brightness was 166, 181, 208, 221, 231, 236, then 240 at progress 0.31, 0.46, 0.69, 0.83, 0.91, 0.96, and 1. That fits a black overlay with **α ≈ 0.45 × (1 − progress)** within ±0.01. The content card itself is not dimmed (≈ 248 against the drawer's 240). |
| Content corner and shadow | Leading-edge **corner radius ≈ 35 px ≈ 28–32 pt**, low-medium confidence because the edge is soft in video. A **soft shadow** to the left of the card ramps from 243 down to 233 over about 20 px, so roughly radius 16 pt at about 4–8% black. The card is **not scaled**: it spans the full height. |
| Open trajectory (px, 30 fps) | 0, 23, 123, 213, 272, 306, 330, 334, 340, 341, 343 |
| Open duration | **≈ 250–270 ms** (8 moving frames). |
| Open peak velocity | 3000 px/s = **6.6 W/s ≈ 2600 pt/s** |
| Open overshoot | **0** |
| Open best fit | **`.spring(response: 0.25, dampingFraction: 0.98)`** (rms 1.3 px, 99% at 252 ms). `.easeOut`-family cubic over 250–260 ms. |
| Second open | 0, 106, 157, 236, 286, 313, 328, 336, 340, 342, 343. One sampling glitch in the first frame; ≈ 300 ms. |
| Close on tapping "Projects" (content swaps to Projects) | 343, 262, 178, 112, 67, 39, 30, 17, 9, 4, 3, 1, 0. **≈ 330 ms**, peak 2520 px/s (5.5 W/s). Fit: `.spring(response: 0.22, dampingFraction: 1.26)`, or `.timingCurve(0.24, 1.02, 0.37, 0.98, duration: 0.45)`. |
| Older build (24 fps file, dropped frames) | Open ≈ 0.5–0.8 s with an S-shaped start because the keyboard was dismissed at the same time. Close ≈ 0.5–0.6 s. **Low confidence**; recorder artifacts. |

### Grok

The recording is signed out, and the signed-out build has no hamburger or drawer, only new-chat and "Sign in". **The drawer was not measured.**

## 2. Sending a message

### ChatGPT (high confidence; typed send and dictation send agree)

- **Send to stop.** The arrow glyph is replaced by a stop square within **1 frame (≤ 33 ms)**. That reads as an instant swap or a very short crossfade. No scale morph was visible; the touch indicator partly occludes the button.
- **User bubble.** The bubble emerges at the composer text position and travels about 395–720 px (330–610 pt) up to its slot at the top of the viewport. This is effectively "scroll the new turn to the top". Each frame closes a constant ~0.66–0.75 of the remaining distance, which is an exponential, overdamped approach.

| Sample | Trajectory (px to final, 30 fps) | Duration | Peak velocity | Fit |
|---|---|---|---|---|
| Typed send (t = 207.0 s) | 340, 262, 193, 136, 94, 62, 42, 28, 18, 12, 8, 5, 3, 2, 1, 1, 0 | **≈ 430 ms** to 1%, about 530 ms to 1 px | 2340 px/s ≈ 1980 pt/s | **`.spring(response: 0.34, dampingFraction: 1.10)`** (rms 2.2 px). `.timingCurve(0.26, 1.01, 0.32, 0.99, duration: 0.61)` (rms 0.4 px). |
| Dictation send (t = 452.8 s) | 707\*, 572, 429, 308, 215, 146, 97, 64, 42, 27, 18, 11, 7, 5, 3, 2, 1, 0 | ≈ 430 ms to 1% | 4290 px/s ≈ 3630 pt/s (longer travel) | `.spring(response: 0.35, dampingFraction: 1.08)` (rms 2.5 px). `.timingCurve(0.24, 0.98, 0.18, 1.00, duration: 0.72)`. |

\* Low NCC (0.54): the bubble overlapped the composer in that frame.

- **Keyboard.** The keyboard dismisses at the same time, using the system curve.
- **Suggestions.** Suggestion chips fade out over about 150 ms.

### Grok (medium confidence, 60 fps)

- **First send from the empty state.** The composer begins to ride down with the keyboard for about 5 frames (83 ms). Then, in a single frame, the screen **hard-cuts** to the conversation with the user bubble already in place and "I'm" streaming. There is no bubble fly-in. This may be an edit cut, but nothing else in the clip is cut.
- **Send inside an existing chat:**
  1. The keyboard disappears in about 1 frame.
  2. The composer text pops into a blurred ghost bubble that rises about 100 px in roughly 4 frames (≈ 70 ms).
  3. The list then scrolls the new turn to the top: 327 px over **≈ 200 ms at near-constant velocity** (54, 28, 31, 33, 34, 32, 30, 26, 21, 15, 9 px per frame). It ends with a **3 px (≈ 3 pt) overshoot**, settled by about 350 ms.
  4. Fit: `.timingCurve(0.00, 0.13, 0.84, 1.05, duration: 0.18)` (rms 3 px), close to linear plus a small settle. The nearest spring is `.spring(response: 0.34, dampingFraction: 0.80)` (rms 8 px, a poor fit).
- **Peak velocity** was 3420 px/s ≈ 3280 pt/s.
- **Stop button.** It is a white circle with a black square, shown while streaming. The swap from send was not separately resolvable.

### Claude

No send was captured in a usable recording.

## 3. Streaming text and the thinking row

| App | Behavior | Numbers |
|---|---|---|
| ChatGPT | **Thinking indicator:** a solid black dot at the assistant's leading edge. It **grows 0 → 20 px (≈ 17 pt) in about 200 ms**, holds, then breathes down to about 17 px (scale 0.85) over roughly 330 ms. It is replaced by text after about 530 ms on a fast reply (the indicator lasts as long as time-to-first-token). | High |
| ChatGPT | **Text reveal:** per-word **opacity fade-in**. Words are laid out in place (no reflow or slide); each fades 0 → 1 in **≈ 520 ms** (10% to 90% in about 370 ms). Fit: **`.easeOut(duration: 0.52)`** (rms 0.8%). Measured word-to-word stagger was "Garlic" → "Lemon" 33 ms, → "Chicken" about 70 ms, → "with" about 33 ms, so roughly **30–70 ms per word**. Several words are mid-fade at once, which gives a soft trailing gradient. | High |
| ChatGPT | **Auto-scroll:** the viewport stays pinned while text streams below the user bubble. It scrolls only when content passes the composer. | Med |
| Grok | **Text reveal:** tokens arrive in **chunks about every 100 ms**. Each chunk fades in over **≈ 170–300 ms (median ≈ 200 ms)**, 10% to 90%. The visual result is a moving **left-to-right gradient mask about 100–200 px wide** over the trailing characters ("gro|k.com, x.com, or" fading). | High (60 fps) |
| Grok | **Thinking:** a "Think harder" pill floats above the composer. No separate reasoning row appeared in this Auto-mode clip. | Med |
| Claude | Not captured in a usable recording. A static screenshot in `UX-SPEC.md` shows a collapsible thinking summary row. | — |

## 4. Menus and sheets

| App | Element | Measured |
|---|---|---|
| Grok | Model picker (system `Menu` anchored to the "Auto" button above the composer) | The backdrop blur and dim ramp in over **≈ 220–270 ms**. Fit: `.spring(response: 0.30, dampingFraction: 0.88)`, or the iOS default curve over 270 ms. The menu panel scales in from the anchor and is complete by about 150 ms. Close fades out in **≈ 170 ms to 90%, about 250 ms total**. Rows: Heavy, Expert, Fast, Auto ✓, Grok 4 Fast, each with a subtitle. |
| Claude | "Create a project" sheet | A system page sheet (large detent). The presenting view stays visible as a dimmed strip at the top. Travel is 940 px. **≈ 370 ms** to settle, peak 6300 px/s, no overshoot. Fit: **`.spring(response: 0.31, dampingFraction: 1.06)`** (rms 3.8 px). Background dims **230 → 180 (≈ 22% black)** in about 250 ms. |
| ChatGPT | Model picker or new chat | Not present in the footage. A static screenshot of the picker is in `~/cnm-refs/chatgpt/mobbin-model-picker.png`. |

## 5. Welcome and sign-in

| App | Measured |
|---|---|
| Grok (60 fps) | After the splash, the X logo fades out over about 250 ms. At the same moment the sign-in stack ("Continue with X / Google / Apple", "Other options") **fades in over ≈ 200 ms, 10% to 90% (about 300 ms total, ease-out)**. The "Grok" wordmark then fades and brightens slowly over **≈ 0.9 s**. Sign-in is inline on the welcome screen, not a sheet; "Skip" is top-right. |
| ChatGPT and Claude | The welcome-to-sign-in transition is not present in the usable footage. Static layouts are in `UX-SPEC.md` §1. |

---

## Recommended values for cmux

The spring values below are SwiftUI `.spring(response:dampingFraction:)`. The measured apps are all critically damped or overdamped: no overshoot anywhere except Grok's 3 pt scroll settle.

| Interaction | Recommendation | Basis |
|---|---|---|
| **Drawer open or close (tap)** | **`.spring(response: 0.25, dampingFraction: 1.0)`**, which reaches 99% at about 250 ms. A snappier ChatGPT feel is `.spring(response: 0.20, dampingFraction: 1.0)`. The bezier equivalent is `.timingCurve(0.25, 1.0, 0.35, 1.0, duration: 0.33)`. | Claude 0.25/0.98; ChatGPT 0.18–0.23 at 1.0–1.2 |
| **Drawer drag release** | Use the same spring with the gesture's velocity, for example `.interpolatingSpring` or `withAnimation(.spring(response: 0.25, dampingFraction: 1.0, blendDuration: 0))` seeded from the translation velocity. Decide the target by projected end position: `x + v·0.15 s` past 50% of the width. Track the finger 1:1 while dragging. | Neither app's drag was captured; this follows the platform norm |
| **Drawer width** | **`min(0.80 × W, 320 pt)`**, which gives 314 pt on a 393 pt screen. Always leave at least 64 pt of content visible. | ChatGPT 0.835 W (326 pt); Claude 0.75–0.81 W (≈ 300–318 pt) |
| **Drawer style** | Rigid push with **no parallax** (both apps). For depth on iOS 26, use **Claude's card treatment**: a leading-edge continuous corner of **≈ 30 pt** on the content, a shadow of `radius 16, opacity 0.08`, and a black overlay on the *drawer* with **α = 0.45 × (1 − progress)**. The simpler alternative is ChatGPT's square edge with a content dim of **α = 0.10 × progress**. Pick one; do not combine both dims. | Measured |
| **Send to stop** | Swap within a frame: `.contentTransition(.symbolEffect(.replace))` with an animation of ≤ 0.15 s. Do not run a long morph. | ChatGPT ≤ 33 ms |
| **User bubble on send** | Insert the bubble and scroll the new turn to the top with **`.spring(response: 0.35, dampingFraction: 1.0)`** (≈ 430 ms, no overshoot). The bezier equivalent is `.timingCurve(0.25, 1.0, 0.3, 1.0, duration: 0.6)`. The bubble should start at the composer text position (matched geometry), not fade in place. | ChatGPT 0.34–0.35 at 1.08–1.10, ×2 |
| **Keyboard on send** | Dismiss at the same moment using the system keyboard animation. Do not add a custom curve. | All apps |
| **Streaming reveal** | Fade each arriving token chunk in place: opacity 0 → 1 with **`.easeOut(duration: 0.30)`** and a **30 ms per-word stagger, capped at 150 ms per chunk**. Never slide or reflow text; lay it out final and animate only opacity. This sits between ChatGPT (0.52 s per word) and Grok (≈ 0.2 s per 100 ms chunk). Batch UI updates at about 10–20 Hz. | Measured |
| **Thinking indicator** | Show a dot or row at the assistant's leading edge: scale it in 0 → 1 over **0.2 s ease-out**, then breathe scale **1.0 ↔ 0.85**, `.easeInOut(duration: 0.4).repeatForever(autoreverses: true)`. Crossfade to the first text in 0.15 s. | ChatGPT dot |
| **Menus (model picker, new chat)** | Use the system `Menu`. The system timing is ≈ 250 ms in and ≈ 200 ms out. Do not hand-roll it. | Grok |
| **Sheets (sign-in, settings, new project)** | Use the system `.sheet`. The measured equivalent is `.spring(response: 0.31, dampingFraction: 1.0)` with a background dim of about 22%. | Claude |
| **Welcome to sign-in buttons** | Splash logo fades out over 0.25 s. Buttons fade in with **`.easeOut(duration: 0.3)`** starting at the same moment, with an optional 40 ms stagger per button. A wordmark can take a slower 0.8–0.9 s fade. | Grok |

### Caveats

- ChatGPT's recording predates Liquid Glass (Sept 2025). Its drawer geometry and timing were stable across samples, but the current build may add glass chrome.
- Claude's 2025 recording dropped frames, so only its geometry is used. Timing comes from the 2026 recording.
- Point conversions assume a 390–402 pt device width. Fractions of W are the reliable figures.
- YouTube re-encoding softens edges, so the corner radius and shadow are ±25%.
- Not captured anywhere:
  - drag-driven drawer gestures;
  - Claude streaming and send;
  - ChatGPT and Claude welcome-to-sign-in transitions;
  - the Grok drawer;
  - any Cursor or T3 Code iOS motion.

  Before shipping, verify these against a device or simulator recording with `skills/debug/verify-ui-video`.
