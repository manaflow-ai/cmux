# cmux-next motion

Living document. Owner of every animation duration, curve and spring in
cmux-next. Code: `Packages/macOS/CmuxNext/Sources/CmuxNextDesign/Motion/`.
Gate: `scripts/cmux-next/check-motion.sh` (no literal timing outside that
directory). User request (2026-09-29): "animations need to be faster, think
about how apple would do it." Earlier decisions that still apply: Cmd-D and
Cmd-Shift-D splits apply in one frame (no animation); the sidebar is only
shown or hidden; tab animations target Chrome quality.

## Rules

1. One module. Every animation asks `Motion` for a token. No module
   hard-codes a duration, curve or spring constant.
2. Springs, described by response and damping fraction as SwiftUI
   `.spring(response:dampingFraction:)`. No long ease-in-out curves. Timed
   fades use ease-out.
3. Direct manipulation (tab drag, sidebar drag, trackpad column scroll)
   follows the pointer with no smoothing. On release, a spring starts from
   the presented position with the pointer's velocity (`Spring.follow` /
   `release`, `TabDragSession.samplePointer`, the column fling projection).
4. Micro feedback (hover, press, focus ring) is 0.1 s or less, or instant.
   Press is instant.
5. Structural changes (tab insert and remove, group collapse, sidebar,
   palette) end visibly in 0.15 to 0.25 s. Appearing uses a faster spring
   than moving; disappearing is faster still and fades out quickly.
6. Every animation can be interrupted and retargeted from its presentation
   value. A new change never waits for an old one, never restarts from the
   model value, and never queues:
   - display-link springs (`SpringValue`, tab `Spring`, `AnimatedFrame`)
     keep value and velocity when the target changes;
   - AppKit `animator()` changes run through `NSAnimationContext.animate`
     with a SwiftUI animation, which AppKit retargets from the presented
     value with velocity;
   - layer animations (`Motion.set`) read `presentation()` and replace the
     animation under the same key;
   - timed animators that do not take springs (NSWindow frame and alpha,
     NSLayoutConstraint constants such as the sidebar width) use
     `Motion.animateTimed`, the token's visible-end duration with ease-out;
     AppKit starts a new one from the value on screen.
7. Reduce Motion (`NSWorkspace.accessibilityDisplayShouldReduceMotion`):
   movement (position, size, scale, scroll) is instant; opacity changes stay
   as a crossfade of at most 0.1 s; spinners and pulses stop and show a
   static glyph.
8. `ui.animationSpeed` in cmux.json: `"fast"` (default), `"normal"` (every
   time constant x1.5, about Apple's system pacing), `"off"` (every change in
   one frame, no crossfade, no loops). Palette actions: Use Fast Animations,
   Use Normal Animations, Turn Off Animations
   (`appearance.animationSpeed.{fast,normal,off}`). "off" wins over Reduce
   Motion.
9. Performance (architecture.md sections 3 and 5): hot-path animation is
   CALayer or display-link driven; a display link runs only while something
   moves and pauses itself; idle CPU stays 0%; nothing blocks the main
   thread. The token lookup is a Bool and a multiply per spring step.

## Tokens (speed "fast")

"Visible end" is the last frame that moves a 200 pt travel by more than
1 pt (what a viewer reads as the length). "Rest" is when the display link
stops (0.25 pt and 2 pt/s). Both are simulated at 120 Hz with the same spring
code the app runs; the measured column comes from `debug.motion` on tag
nxmot (MacBook Pro, 120 Hz).

| Token | Response / damping | Visible end | Rest | Used by |
| --- | --- | --- | --- | --- |
| `move` | 0.20 / 0.90 | 192 ms | 250 ms | tab reflow and reorder, sidebar row moves, pane and divider frames (ratio, equalize, zoom), sidebar drag gap |
| `appear` | 0.18 / 0.90 | 175 ms | 225 ms | palette scale-in (from `Motion.panelOpenScale` 0.97 about the panel center), tab grow-in, tab group expand, sidebar row insert, sidebar show (timed equivalent), browser toolbar show, ghost card/inline morph |
| `disappear` | 0.15 / 0.90 | 142 ms | 200 ms | tab close (width to 0), group collapse, sidebar row removal, sidebar hide (timed equivalent), browser toolbar hide |
| `settle` | 0.22 / 0.85 | 175 ms | 342 ms | release after drag: tab drop, drag ghost landing, sidebar row drop (carries pointer velocity; 0.8 pt overshoot on 200 pt) |
| `scroll` | 0.22 / 0.90 | 208 ms | 267 ms | tab strip reveal, strip column reveal, wheel notch, trackpad fling snap |
| `screen` | 0.22 / 0.90 | 208 ms | 267 ms | screen switch slide |
| `track` | 0.12 / 0.90 | 117 ms | 167 ms | drop-zone highlight, drag ghost jumps between targets |
| `selection` | 0.15 / 0.90 | 142 ms | 200 ms | sidebar selection pill |
| `panel` | 0.18 / 0.85 | 142 ms | 283 ms | hover card slide |

| Fade token | Duration | Used by |
| --- | --- | --- |
| `hover` | 0.08 s | tab, chip, button and omnibar hover fills; tab bar trailing buttons and the tab x fading in on hover; sidebar hover buttons; divider and resize-handle hover; refused-drop dim |
| `focus` | 0.10 s | pane focus ring and inactive dim |
| `fadeIn` | 0.12 s | palette, find bar, notices, hover card, group editor, sidebar pill appear |
| `fadeOut` | 0.08 s | palette close (with a shrink to `Motion.panelCloseScale` 0.98 about the center), find bar, notices, hover card, sidebar pill hide |
| `crossfade` | 0.10 s | hover card thumbnail swap; the Reduce Motion ceiling |
| `lift` | 0.12 s | sidebar drag lift shadow |
| `theme` | 0.16 s | room, workspace or terminal theme switch (a `CATransition` fade on the scope's root layer; no layout change) |

| Loop | Period | Used by |
| --- | --- | --- |
| `spinner` | 0.9 s | busy tab spinner, sidebar agent spinner |
| `pulse` | 1.8 s | sidebar agent-waiting pulse |
| `flash` | 0.6 s | pane attention flash (two blinks; one 0.3 s fade under Reduce Motion) |

| Marquee (`MotionMarquee`) | Value | Used by |
| --- | --- | --- |
| `delay` | 0.6 s pointer rest (Core Animation `beginTime`, no timer) | clipped tab and workspace titles on hover (plans/cmux-next/tabs.md) |
| `pointsPerSecond` | 40 pt/s, at least `minimumScroll` 0.4 s, ease in and out | same |
| `hold` | 1.2 s at the end, then back with `move`'s timed equivalent | same |

Leaving stops the marquee at once; a title caught mid-scroll springs back
with `disappear` from its presented position. `normal` scales delay,
scroll and hold by 1.5; Reduce Motion and `off` never start it.

"normal" multiplies every response and fade duration by 1.5; damping does
not change. Loops keep their period (they show state, not transitions).

## Why these values

- Damping 0.9, not 1. A critically damped spring spends its last third
  crawling through sub-pixel distances: at response 0.22 it covers 95% in
  167 ms but reaches its last visible pixel at 269 ms. Damping 0.9
  overshoots 0.05% (0.1 pt on 200 pt, invisible after pixel snapping) and
  ends visibly at 200 ms. Apple's own `.snappy` and UIKit's default
  interactive spring are under-damped for the same reason.
- Response 0.15 to 0.22 s. Apple's system defaults (`.smooth` / `.snappy`
  at 0.5 s perceptual duration, NSAnimationContext 0.25 s) suit consumer
  apps; a tab strip is used hundreds of times an hour. Chrome's tab strip
  animates bounds with `views::BoundsAnimator`'s default 200 ms ease-out and
  its title fade in 100 ms ([Chromium tab.cc](https://github.com/chromium/chromium/blob/main/chrome/browser/ui/views/tabs/tab.cc),
  [analysis of BoundsAnimator's 200 ms default](https://danglingpointer.fun/posts/FasterChromium)).
  Our `move` ends visibly at 192 ms: Chrome-level length with a spring's
  continuity (Chrome's linear-time animations restart on interruption; ours
  retarget). Safari, Finder and Spotlight timings were not measured here
  (see "Not verified").
- `scroll` is a spring with stiffness 800 (response 0.222 s) and 0.9
  damping; damping 1 leaves a slow sub-pixel tail.
- Hover in 0.08 s and focus in 0.1 s: fast enough to read as instant
  feedback, slow enough that sweeping the pointer across tabs does not
  strobe. Press states have no animation.
- Disappear faster than appear, appear faster than move: removed content is
  no longer interesting, new content should arrive before the eye moves on,
  and moving content is being tracked.

## Audit: before and after

Before is `origin/feat-cmux-next` at 649cd743d3e. "Before visible / rest"
uses the old constants in the same simulation; "after measured" is
`debug.motion` on tag nxmot (display link or completion span, first start to
rest).

| Area | Before: mechanism, curve, duration | After: token | Before visible / rest | After visible / rest | After measured (rest) |
| --- | --- | --- | --- | --- | --- |
| Tab open (grow-in) | display-link spring 0.28/0.92; alpha 0.20/1 | `appear` | 275 / 392 ms | 175 / 225 ms | 224-233 ms |
| Tab close | display-link spring 0.28/0.92 to width 0 | `disappear` (+ neighbors `move`) | 275 / 392 ms | 142-192 / 250 ms | 199-233 ms |
| Tab reorder (drop, move actions) | spring 0.28/0.92, dragged tab snapped, no velocity | `move`; drop `settle` with pointer velocity | 275 / 392 ms | 192 / 250 ms | 232-249 ms (move action) |
| Tab shrink / reflow | spring 0.28/0.92 | `move` | 275 / 392 ms | 192 / 250 ms | - |
| Tab strip scroll reveal | spring 0.32/1 | `scroll` | 392 / 608 ms | 208 / 267 ms | - |
| Tab hover, close button, new-tab and trailing buttons | CA action 0.14 s ease-out; buttons 0.14 / 0.12 s | `hover` 0.08 s | 140 ms | 80 ms | - |
| Tab busy spinner | CA rotation 0.9 s loop (ran under Reduce Motion) | `spinner` (stops under Reduce Motion / off) | loop | loop | - |
| Tab drag ghost | pointer-locked; jump spring 0.22/0.84; morph 0.26/1 | pointer-locked; `track`, `appear`; landing `settle` with velocity | 167 / 342 ms; 325 / 417 ms | 117 / 167 ms; 175 / 225 ms | - |
| Tab drop / tear-off landing | jump spring 0.22/0.84, no velocity | `settle` + pointer velocity | 167 / 342 ms | 175 / 342 ms | - |
| Hover preview card | window frame slide 0.16 s ease-out; fade in 0.12 s, out 0.10 s; thumbnail crossfade 0.15 s | `panel` (timed equivalent), `fadeIn`, `fadeOut`, `crossfade` | 160 / 120 / 100 / 150 ms | 142 / 120 / 80 / 100 ms | - |
| Tab group collapse | tab springs 0.28/0.92 to width 0, alpha 0.20/1 | `disappear` (+ neighbors `move`) | 275 / 392 ms | 142 / 200 ms | 224-239 ms |
| Tab group expand | same | `appear` | 275 / 392 ms | 175 / 225 ms | 232 ms |
| Tab group chip hover | CA action 0.14 s | `hover` | 140 ms | 80 ms | - |
| Tab group editor panel | window fade 0.12 s | `fadeIn` | 120 ms | 120 ms | - |
| Sidebar show / hide | width constraint animator with a SwiftUI spring(duration 0.30, bounce 0), which constraint animators ignore: it ran AppKit's 0.25 s default (measured 263-272 ms at every speed) | `appear` / `disappear` as timed equivalents (constraint animators take only timed curves) | 250-270 ms measured | 175 / 142 ms | 174 ms show, 150 ms hide |
| Sidebar row reorder, insert, remove; workspace group collapse | SwiftUI spring(0.32, bounce 0.12) for all rows | moves `move`, inserts `appear`, removals `disappear` | 275 / 458 ms | 192 / 175 / 142 ms visible | move 341 ms, insert 114 ms (AppKit completion) |
| Sidebar selection pill | CASpring(perceptual 0.26, bounce 0.08); fade 0.16 s | `selection`, `fadeIn` / `fadeOut` | 258 / 342 ms | 142 / 200 ms | 199-211 ms |
| Sidebar drag gap | CASpring(0.32, bounce 0.12) | `move` | 275 / 458 ms | 192 / 250 ms | - |
| Sidebar drag lift / drop | shadow group 0.22 s ease-out; drop spring(0.28, bounce 0.18); refused dim spring 0.26 | `lift`, `settle`, `hover` | 220 / 308 / 258 ms | 120 / 175 / 80 ms | - |
| Sidebar hover buttons, resize line | 0.14 s ease-out | `hover` | 140 ms | 80 ms | - |
| Sidebar agent spinner / pulse | 0.9 s loops | `spinner`, `pulse` | loop | loop | - |
| Palette open | opacity 0.18 s linear; scale CASpring k 420 c 30 (0.307/0.73, 3% overshoot) | `fadeIn` + `appear` from presentation, about the panel center (was `panel`, pivoting on the left edge until 2026-09-30) | 180 ms; 350 / 433 ms | 120 ms; 142 / 283 ms | fade 132-179 ms, scale 231-277 ms |
| Palette close | opacity + shrink 0.14 s ease-in | `fadeOut` | 140 ms | 80 ms | 83-92 ms |
| Palette reopen during close | removed animations, restarted from 0 (jump) | continues from presentation | jump | no jump | - |
| Palette actions menu | fade 0.14 s | `fadeIn` / `fadeOut` | 140 ms | 120 / 80 ms | - |
| Palette result changes | instant | instant (unchanged, as Spotlight and Raycast) | 0 | 0 | - |
| Omnibar fill / ring | CATransaction 0.12 s | `hover` | 120 ms | 80 ms | - |
| Omnibar dropdown | instant show and hide | instant (unchanged, as Chrome) | 0 | 0 | - |
| Browser find bar, notices | fade in 0.14 s, out 0.12 s, curve (0.2, 0.9, 0.3, 1) | `fadeIn` / `fadeOut` | 140 / 120 ms | 120 / 80 ms | - |
| Browser toolbar show / hide | constraint 0.2 s, same curve | `appear` / `disappear` (timed equivalent) | 200 ms | 175 / 142 ms | - |
| Browser progress line | CATransaction 0.2 s | `move` (timed equivalent) | 200 ms | 192 ms | - |
| strip column scroll (reveal, wheel, fling) | display-link spring 0.42/0.96 | `scroll` | 458 / 592 ms | 208 / 267 ms | 366-377 ms (reveal of a full-width column; rest is longer for long travel) |
| Screen switch | display-link spring 0.38/0.92 | `screen` | 367 / 475 ms | 208 / 267 ms | 244-249 ms |
| Splits (Cmd-D, Cmd-Shift-D), close, move | one frame | one frame (unchanged) | 0 | 0 | - |
| Pane ratio, equalize, width presets, pane zoom | display-link spring 0.34/0.88 | `move` | 292 / 483 ms | 192 / 250 ms | 258 ms (column width preset) |
| Drop-zone overlay | display-link spring 0.20/0.90 | `track` | 192 / 250 ms | 117 / 167 ms | - |
| Focus ring and inactive dim | CATransaction 0.16 s | `focus` | 160 ms | 100 ms | - |
| Divider hover | CATransaction 0.12 s | `hover` | 120 ms | 80 ms | - |
| Pane attention flash | keyframes 0.9 s (0.35 s fade reduced) | `flash` 0.6 s (0.3 s reduced; none when off) | 900 ms | 600 ms | - |
| Programmatic window close | window fade 0.18 s ease-in | instant (the windows work on this branch made it close in the same turn as the transition) | 180 ms | 0 | - |
| Notifications and bubbles | no dedicated animation; tab badge color changes with the tab fill fade | `hover` | 140 ms | 80 ms | - |

## Verification

`debug.motion` (`{"action": "start" | "read" | "stop"}`) records spans from
an animation's first frame to rest: `tabs` (strip display link), `layout`
(pane, column, screen, drop-zone display link), `appkit.<token>` (animator
completions) and `layer.<keyPath>.<token>` (Core Animation completions).
`debug.frames` records display-link frame intervals and `debug.hangs` main
thread stalls over 50 ms. Tests: `MotionTokenTests` (token ranges, normal,
off, Reduce Motion), `MotionInterruptionTests` (midway retarget of a spring
and of layer animations starts from the presented value), tab `SpringTests`
(pointer follow and release velocity), `AnimationSpeedSettingsTests`.

### Results (tag nxmot, 2026-09-30, MacBook Pro 120 Hz, fleet-free local build)

Speeds were switched with `debug.motion` `speed` (in memory; cmux.json was
not written). Spans are first frame to rest.

| Scenario | fast | normal | off |
| --- | --- | --- | --- |
| Tab open | 224-233 ms | 382 ms | no animation |
| Tab reorder (move action) | 232-249 ms | 324 ms | no animation |
| Tab close | 199-233 ms | 341 ms | no animation |
| Tab group collapse / expand | 224-239 / 232 ms | - / 307 ms | no animation |
| Sidebar hide / show | 150 / 174 ms | 217 / 250 ms | no animation |
| Palette open (fade / scale) | 132-179 / 231-277 ms | 206 / 358 ms | no animation |
| Palette close | 83-92 ms | 132 ms | no animation |
| Column reveal / width preset | 366 / 258 ms | 383 / 458 ms | no animation |
| Screen switch | 244-249 ms | 351-357 ms | no animation |

Interruption: sidebar hide then show 60 ms later ran 71 ms of hide and 172
ms of show from the partial width (no jump, no queue); palette
open-close-open within 90 ms continued from the on-screen opacity and scale.

Frames (`debug.frames`, 120 Hz, refresh 8.33 ms): during tab, sidebar,
group, column and screen animations p50 and p99 were 8.33 ms. Single frames
of 17-33 ms appear at the start of tab open (new Ghostty surface) and a
43-127 ms first frame at palette open (panel ordering and first layout).
The base build (649cd743d3e, same machine) shows the same palette-open
frame (42-95 ms) and also long frames at palette close (up to 67 ms), which
the new close no longer has (max 8.33 ms).

`debug.hangs`: no stall came from animation code. Stalls seen during the
runs, all outside animation paths and also present on the base build: first
palette open (row and text-field creation, NSGlassEffectView init, 86-256
ms; `makeKeyAndOrderFront` window-server IPC), `CefInitialize` (159 ms,
the allowed Chromium exception), and one AppKit menu-bar replicant window
creation (771 ms, window server).

Idle after the runs: 0.2% CPU over 30 s. A 5 s `sample` of the main thread
shows no display link or animation callback; the only work is
`CEFMessagePump` (CEF was started by the palette's Chromium warm-up; the
30 Hz pump is the known follow-up in REWRITE.md). Every span above closed,
so every animation display link paused.

## Scale pivot (2026-09-30)

AppKit gives a view's backing layer an anchor point of (0, 0), and Core
Animation applies `transform` and `sublayerTransform` about the anchor
point. The palette's scale math assumed a centered anchor, so it pivoted
on the bottom-left corner and grew in from the left (about 10 pt of
sideways travel at 0.97). `Motion.scale(_:about:in:)` builds a scale about
an explicit pivot for any anchor point; every panel scale goes through it.
The palette now opens like Linear's command menu: `fadeIn` plus an `appear`
spring from 0.97 about its center (visible end 175 ms), and closes with
`fadeOut` (80 ms) plus a shrink to 0.98. Result changes stay instant. The
palette keeps a fixed height, so there is no list-height animation yet.

## Not verified

- Safari, Finder, Chrome and Spotlight timings were not measured on this
  machine; the Chrome numbers above come from Chromium sources and a
  published analysis.
- Visual smoothness (screenshots or video) was not captured: the Computer
  Use tool was unavailable in this session. Evidence is span timing, frame
  intervals and stalls.
- Direct-manipulation paths (tab drag and drop, tear-off, sidebar drag,
  trackpad column fling, drop-zone overlays, hover card) were not driven
  live; their springs and release velocity are covered by unit tests only.
- Reduce Motion was not toggled live (a system setting); its policy is
  unit-tested.
- The palette actions for `ui.animationSpeed` were not invoked live because
  they write the shared `~/.config/cmux/cmux.json`; the parse and apply
  path is unit-tested and the live speeds were set with `debug.motion`.
