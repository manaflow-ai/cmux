# cmux-next motion

Living document. Owner of every animation duration, curve and spring in
cmux-next. Code: `Packages/macOS/CmuxNext/Sources/CmuxNextDesign/Motion/`.
Gate: `scripts/cmux-next/check-motion.sh` (no literal timing outside that
directory). User request (2026-09-29): "animations need to be faster, think
about how apple would do it." Earlier decisions that still apply: Cmd-D and
Cmd-Shift-D splits applied in one frame until 2026-10-10, when Leo asked
for panes that grow from their edge (cx-f6i7); the sidebar is only
shown or hidden; tab animations must be fast and smooth.

## Scale (Leo 2026-10-20)

Leo: "animations all around are a bit slow". Every animation now keeps to one
short scale, `schemas/motion-scale/motion-scale.json` (generated into
`MotionScale`, the webviews' `--cmux-motion-*` and `scale.generated.ts`):
quick 80 ms (hover and pressed fills, focus rings, anything leaving), micro
120 ms, standard 180 ms, large 240 ms, the ceiling. Every timed fade default
is a step or 0, and every spring ends visibly (within 0.5%,
`perceivedDuration`) by 240 ms; entering eases out, and nothing delays input.
Off-scale fades went to the nearest step that is not longer (focus and
crossfade, the Reduce Motion cap, 80 ms; paneDim and theme 120 ms; clickPulse,
cursorHide, hibernateIcon, the attention swell and the agent cursor glide limit
240 ms). The color change is a user setting
(`appearance.colorTransition.duration`, 200 ms) and keeps its default. Springs over the
ceiling kept their damping and got a shorter response: zoom 0.2 (was 0.30,
354 ms visible), exit 0.2 (0.24, 283 ms), split 0.23 (0.28, 287 ms), popover
0.24 (0.25, 248 ms), pinDrag 0.215 (0.351, 390 ms); scroll and screen 0.2,
panel 0.165 and popoverClose 0.15 now end by 180 ms. `settle` stays at 235 ms
(it carries the release velocity). Exceptions: the long ambient fades
`highlight` (1.2 s) and `hibernateRing` (1 s), loops, and hover-intent
delays (tooltip, hover card aim and grace, marquee, launch), which are waits,
not animations. `MotionScaleTests` holds all of this; where the tables below
disagree, the code and this paragraph win.

## Redesign (hq-1d, 2026-10-12)

Lawrence: "new tab animation and new workspace animation needs to be redone
from first principles", "ensure there's option to toggle animations of
splits/new tabs", "better curves for animations of splits, think how apple
would do it, spring curves", "proper physics". Design:
`.cmux-scratch/motion-redesign/DESIGN.md` in hq (principles P1 to P7).

- Physics: `SpringValue.step` is the closed-form damped harmonic
  oscillator (under-, critically and over-damped), exact at any frame rate,
  retargetable with its velocity. `SpringParameters(duration:bounce:)` is
  SwiftUI's `Spring(duration:bounce:)`.
- One source (hq-1d D2, Lawrence: "decouple from swift app as much as
  possible"): the tokens live in the spec's design-tokens.json `motion`
  (springs, fades, loops, speed, settle thresholds, the structural set, the
  bounce and the per-kind defaults). cmux-tui/crates/cmux-motion reads them
  at build time (build.rs) and owns the closed-form step
  (`SpringValue::solve`, `advance_spring`), the structural bounce rule
  (`MotionPolicy::spring`) and the switches (`AnimationSwitches`,
  `set_animation_switches`); cmux-app-ffi exposes them to macOS as
  `cmux_motion_*` (include/cmux_motion_ffi.h). Until the app's FFI pin
  carries that ABI, the Swift `SpringValue` keeps the same solution and
  `scripts/cmux-next/motion-parity.py` compares its paths with
  cmux-motion's (`debug.motion {action: "trajectory"}` vs the
  `motion_trajectories` example).
- One clock: `MotionClock` is the one chrome animation client of a window's
  `FrameScheduler`. The tab strips, the layout (panes, dividers, columns,
  screens, drop zones) step on it with the same `dt` and it goes idle with
  the last spring (`debug.motion` `display_links` is 0 at rest).
- Bounce: structural tokens (`move`, `appear`, `disappear`) are critically
  damped by default (never past the target); `ui.animations.bounce`
  "subtle" gives them bounce `motion.spring.subtleBounce` (0.15).
- Per kind, under `ui.animationSpeed`: `ui.paneAnimations` (pane layout,
  rule 9) and `ui.animations.newWorkspace` off by default (Lawrence
  2026-10-14: no big animations by default), `ui.animations.newTab` on
  (Lawrence 2026-10-14 after the instant build: keep the tab-open motion; then
  "match google chrome perfectly": the tab strip moves on Chrome's tweens, see
  "Tab strip (Chrome)" below).
  Off applies that change in one step; true opts into its spring. cmux-motion
  `MotionKind` / `AnimationSwitches` carry exactly these three keys
  (`MotionKind::config_path`). Palette: Toggle New Tab / New Workspace
  Animations, Use Bouncy Animations, Use Animations Without Bounce.
- Reduce Motion: no movement and no crossfade standing in for it; chrome
  takes its new places in one step (the tab strip and sidebar crossfades are
  gone).
- Splits (only with `ui.paneAnimations` on): every pane edge and divider of a split, a close or a released
  divider springs together from rest (or from the release velocity, in
  fractions of the travel), so the change is one spring on the divider
  fraction. Every moving pane is laid out live at the rect its spring presents
  on every display frame, its tab strip, terminal and page included, as a
  live window resize is (Lawrence 2026-10-18: "content must move while it
  animates"); nothing holds a final-size layout under a clip. A zoom or
  unzoom does the same on the `zoom` spring: the zooming pane is the topmost
  layer, its tab strip whole in every frame, and covers the other panes,
  which stay opaque and still. A released divider flung onto a snap within
  `motion.divider.releaseProjection` of its velocity lands there.
  A split (Cmd-D, Cmd-Shift-D) moves on its own `split` spring (0.28 s, damping 0.95; Lawrence
  2026-10-19: "resize all of them while adding a new one"), and the even sizing of its chain
  shows in the key's frame with the split (`LayoutModel.showSplitSizing`), not after the
  daemon's reply: one target, one motion (split-spring-animation/DESIGN.md).
- New tab (only with `ui.animations.newTab` on; off, every entry point shows
  the tab in its final slot at once, and a closed tab's room closes at once
  too; the store's tab takes its provisional stand-in's cell in place, so a
  new tab is one element): Cmd-T, +, New Terminal Tab and the socket all open the tab the
  Chrome way (below); what a New Tab page turns into takes the
  page's cell in place (`TabStripView.expectReplacement(of:)`).
- Tab strip (Chrome, the default; Lawrence 2026-10-14 "match google chrome
  perfectly", "keep 200"; spec .cmux-scratch/chrome-tab-motion/SPEC.md, Chromium
  6d3c98f4fe5): tab x and width are TWEENS, not springs (design-tokens.json
  `motion.tweens`: `tabOpen`, `tabClose`, `tabMove`, 200 ms, 1-(1-t)^2 =
  cubic-bezier(1/3, 2/3, 2/3, 1)); a new target restarts the 200 ms from the
  value on screen with no velocity, a target equal after pixel rounding never
  restarts. Open: from the previous tab's right edge at width 0, no fade; the
  tabs and + move on the same tween. Close: to width 0 with the left edge
  pinned to the previous tab's right edge, no fade. (Chrome starts and ends at
  width 18 at prev.right - 18, but 18 is its tab overlap, so nothing shows; our
  tabs do not overlap, so `motion.tabStrip` openStartWidth/closeEndWidth are 0.) A mouse close keeps the widths
  (closing mode) until the pointer leaves the strip extended 40 pt below and 60 pt
  past its trailing edge, then 300 ms (mouse and middle-click closes only; Cmd-W,
  the CLI and agents never freeze widths). A dragged tab follows the pointer, reorders
  after 16 x width / 200 pt of pointer travel since the last reorder, and settles
  on `tabMove` when released. Widths: max 200 compact / 240 comfortable (today's
  maxima, appearance tabMaxWidth), every tab
  shrinks evenly to the selected minimum, then the inactive ones to theirs, pinned 64
  (`motion.tabStrip`). The minimums are Chrome's 56 selected / 32 inactive
  (Lawrence 2026-10-16 "chrome 32"; 76/96 for a readable title was tried in cx-kp9b4 and reverted); `tabs.overflow` scroll keeps every tab at
  `TabTunables.scrollTabMinWidth` (7/10 of the max: 140 compact) and scrolls sooner. All four widths
  are settings (Tabs group, `appearance.metrics.tabMaxWidth`, `tabMinActiveWidth`,
  `tabMinInactiveWidth`, `tabPinnedWidth`; Lawrence 2026-10-15 "keep chrome's minimums but needs to
  be customizable"): unset is the density default, the strip keeps the active minimum between the
  icon-and-close floor (and the inactive minimum) and the max. Reduce Motion, speed off and a live resize: 0 ms. Geometry and
  tweens come from cmux-motion through the app FFI (`MotionTween`, `MotionTabStrip`).
- New workspace: the row opens at its index and the rows below slide; the
  whole-sidebar snap for Cmd-N is gone, and rows open only on animated
  applies.
- Check (DESIGN P1): `debug.new_tab` frame_strip asserts content in one step
  (`content_intermediate`, `blank`) and chrome continuous (`moving`,
  `reversals`, `jumps`, `max_step`). Proof: `scripts/cmux-next/motion-proof.py`.

## Rules

1. One module. Every animation asks a `Motion` gate (`Motion.<category>`) for a token. No module
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
   movement (position, size, scale, scroll) is instant, and a structural
   change (tab, row, pane) is not replaced by a crossfade; other opacity
   changes stay as a crossfade of at most 0.1 s, and hover and pressed fills
   are instant; spinners and pulses stop and show a static glyph.
8. `ui.animationSpeed` in cmux.json: `"fast"` (default), `"normal"` (every
   time constant x1.5, about Apple's system pacing), `"off"` (every change in
   one frame, no crossfade, no loops). Palette actions: Use Fast Animations,
   Use Normal Animations, Turn Off Animations
   (`appearance.animationSpeed.{fast,normal,off}`). "off" wins over Reduce
   Motion.
   On top of the speed: the master switch `ui.animations.enabled` and one switch
   per area, `ui.animations.<category>` (sidebar, tabs, panes, overlays,
   hoverCards, home, cursor, indicators, feedback, web). Every animation asks its
   category's gate (`Motion.sidebar`, `Motion.tabs`, ...), and a switch that is
   off acts as "off" for its area ([motion-DESIGN.md](motion-DESIGN.md)).
9. Pane layout motion is OFF by default (Lawrence 2026-10-14: "get rid of
   big animations by default for the panes"). `ui.paneAnimations` (toggle
   "Animate Panes", default false) gates every pane layout spring:
   split grow-in, close and move-away, swap, zoom and unzoom
   (`PaneZoomMotion`), divider ratio changes from the model, the column
   strip's programmatic reveal and centering, row reveal and the screen
   switch slide. Off: they apply in one frame (`Motion.animatesPaneLayout`,
   read by `LayoutViewContext.animatesPaneLayout`). Why instant and not a
   short fade: a terminal reflows once at the final size, nothing draws a
   half-moved pane, and a crossfade over a reflowing terminal reads as
   flicker; it also matches classic cmux, whose splits apply at once. Kept
   on: direct manipulation (trackpad fling settle, wheel notches, divider
   drag), focus ring and dim fades, hover feedback, tab strip motion and
   the drop-target overlay. `ui.paneAnimations` true restores the springs;
   `ui.animationSpeed` "off" and Reduce Motion still snap them.
10. Performance (architecture.md sections 3 and 5): hot-path animation is
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
| `move` | 0.15 / 1.00 | 183 ms | 258 ms | tab reflow and reorder, sidebar row moves, inserts (a row grows in its own slot) and removals (it shrinks in place), all on this one spring (cx-bqm6), pane and divider frames (ratio, equalize, unzoom), sidebar drag gap |
| `zoom` | 0.32 / 0.90 | 292 ms | 375 ms | a pane zooming to fill its screen: its terminal takes the full size once and the spring rect reveals it (Leo 2026-10-13) |
| `exit` | 0.12 / 1.00 | 158 ms | 233 ms | the panes a zoom leaves fading out; `Motion.exit(nearness:)` gives the farthest (the 2x2 opposite corner) this and neighbours up to 25% longer, so the opposite corner is gone first (under 0.05 opacity by 100 ms) |
| `appear` | 0.135 / 1.00 | 167 ms | 233 ms | palette scale-in (from `Motion.panelOpenScale` 0.97 about the panel center), tab grow-in, tab group expand, sidebar show (timed equivalent), browser toolbar show, ghost card/inline morph |
| `disappear` | 0.11 / 1.00 | 133 ms | 200 ms | tab close (width to 0), group collapse, sidebar hide (timed equivalent), browser toolbar hide |
| `settle` | 0.22 / 0.85 | 175 ms | 342 ms | release after drag: tab drop, drag ghost landing, sidebar row drop (carries pointer velocity; 0.8 pt overshoot on 200 pt) |
| `scroll` | 0.22 / 0.90 | 208 ms | 267 ms | tab strip reveal, strip column reveal, wheel notch, trackpad fling snap |
| `screen` | 0.22 / 0.90 | 208 ms | 267 ms | screen switch slide |
| `track` | 0.12 / 0.90 | 117 ms | 167 ms | drop-zone highlight, drag ghost jumps between targets |
| `selection` | 0.15 / 0.90 | 142 ms | 200 ms | page info toggle (the sidebar selection does not animate, SIDEBAR-SELECTION-NO-TRAVEL-ANIMATION) |
| `panel` | 0.18 / 0.85 | 142 ms | 283 ms | hover card slide |
| `pinDrag` | 0.351 / 0.839 | 375 ms | 525 ms | Home list pin drag: tiles making room, rows below the grid, a dropped tile landing (MessagesLab `SidebarPinDragging.spring`: stiffness 320, damping 30, mass 1; about 1.6 pt overshoot on 200 pt) |

| Fade token | Duration | Used by |
| --- | --- | --- |
| `hover` | 0.08 s | hover and pressed fills easing in (tabs, chips, buttons, toolbar, menu and palette rows, sidebar rows, New Tab rows; `ChromeHover.fade`); tab bar trailing buttons and the tab x fading in on hover; sidebar hover buttons; divider and resize-handle hover; refused-drop dim. Instant under Reduce Motion |
| `hoverOut` | 0 s | a hover or pressed fill clearing: instant, as in Edge, so a fast sweep leaves no trail (about 0.12 s in Debug Settings leaves a short one). A press shows at once. Sidebar rows are the exception: their fill and hover buttons fade out with `hover` too, in place (Leo 2026-10-13: moving between workspace rows snapped). Instant under Reduce Motion |
| `focus` | 0.10 s | pane focus ring |
| `paneDim` | 0.15 s | the veil over an unfocused pane easing in and out when focus moves (Leo 2026-10-21: a short ease, not a jump) |
| `focusFlash` | 0.50 s | the focus ring shown at once on a pane focus moved to without a click (a link open, the pane after a close, an agent handoff), fading out; Debug toggle `focus.flashOnMove`, off by default |
| `fadeIn` | 0.12 s | palette, find bar, notices, hover card, group editor, sidebar pill appear |
| `fadeOut` | 0.08 s | palette close (with a shrink to `Motion.panelCloseScale` 0.98 about the center), find bar, notices, hover card, sidebar pill hide |
| `crossfade` | 0.10 s | hover card thumbnail swap; the Reduce Motion ceiling |
| `lift` | 0.12 s | sidebar drag lift shadow |
| `theme` | `appearance.colorTransition.duration` (200 ms) | every theme and color change, through `ColorTransition` (cx-3rf4z): the window backdrop blends from the color on screen in OKLab (or sRGB) keyframes, so a quick A, B, C switch retargets from the blend in flight; a theme, light/dark, app theme or accent change fades each window from its last composited frame (`WindowColorFade`: the frame on screen lies over the window and fades out on the curve, so a second change mid-fade starts from the blend; terminal surfaces have no single color); scope overrides fade their roots' areas; a workspace switch fades the sidebar and titlebar areas and blends the Liquid Glass tint on the window's MotionClock; a room takes a workspace's colors at any light/dark; curves, spring timing and the color mix come from cmux-motion (app FFI ABI 3); web pages transition their `--cmux-*` colors (registered `<color>` properties) with the same duration, curve and blend space. Curve: `easeOut` default, `easeInOut`, `linear`, `spring` (response, damping; colors hold at the target), `cubicBezier`. `enabled: false` or duration 0 is instant; Reduce Motion: a crossfade of at most 0.1 s by default (`reduceMotion: instant` or `full`); `ui.animationSpeed: off` is instant. The content swap of a workspace switch never fades. |
| `launch` | 0.24 s | the cmux mark resolving on the glass of a window still connecting (`LaunchMarkView`); 0.36 s at normal speed, under 400 ms; a plain fade under Reduce Motion |
| `pinLift` | 0.15 s, linear | Home list pin drag: the tile scaling up to the lift (MessagesLab `beginPinDrag`, a `CABasicAnimation` with no timing function) |
| `pinSettle` | 0.25 s, linear | Home list pin drag: a dropped tile scaling back (`landPinDrag`, the same) |
| `pinShrink` | 0.22 s | Home list pin drag: a ghost shrinking onto its row's avatar and fading out (`landPinDrag`) |
| `highlight` | 1.20 s | Settings row highlight after a search jump or `openSettings setting:` deep link fades out; under Reduce Motion it holds this long and goes in one frame |

| Loop | Period | Used by |
| --- | --- | --- |
| `spinner` | 0.9 s | busy tab spinner, sidebar agent spinner |
| `pulse` | 1.8 s (at least 0.5 s) | sidebar agent-waiting pulse |
| `flash` | 1.0 s (at least 1.0 s) | pane attention flash (two blinks half a period apart; the attention ring's blinks take half a period each; one 0.5 s fade under Reduce Motion) |

The 2 Hz cap (cx-sya4n): nothing flashes faster than twice a second, in any
mode. Every on-off-on cycle of an opacity loop lasts at least 0.5 s
(`MotionLoop.shortestFlashCycle`), so the `pulse` period is at least 0.5 s and
the `flash` period at least 1.0 s, Debug Settings overrides included
(`MotionLoop.minimumPeriod`). `normal` speed slows the flash and the
attention blinks; the pulse keeps its period at every speed.
`BlinkRateCapTests` checks every flash at the fastest settings.

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

- Structural springs (`move`, `appear`, `disappear`) are critically damped
  (hq-1d D1, 2026-10-13): a tab, row or pane never passes its target, as
  Apple's default `Spring(duration:bounce: 0)`. The long sub-pixel tail of
  critical damping is paid with a shorter response instead of a lower
  damping: `move` 0.15 s ends visibly at 183 ms (120 Hz), inside the 200 ms
  budget the GPUI motion tests hold (225 ms tolerance). `ui.animations.bounce`
  "subtle" (0.15, damping 0.85) is opt-in. Release, scroll and overlay
  springs keep 0.85 to 0.9.
- Response 0.15 to 0.22 s. Apple's system defaults (`.smooth` / `.snappy`
  at 0.5 s perceptual duration, NSAnimationContext 0.25 s) suit consumer
  apps; a tab strip is used hundreds of times an hour. Our `move` ends
  visibly at 183 ms, with a spring's continuity: an interrupted move
  retargets instead of restarting.
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
| Sidebar row reorder, insert, remove; workspace group collapse | SwiftUI spring(0.32, bounce 0.12) for all rows | moves, inserts and removals all `move` (cx-bqm6: one spring, inserts open their slot, removals close it) | 275 / 458 ms | 192 / 175 / 142 ms visible | move 341 ms, insert 114 ms (AppKit completion) |
| Sidebar selection | none: the selected row or item paints selectionFill in place, at once (SIDEBAR-SELECTION-NO-TRAVEL-ANIMATION) | - | - | 0 ms | - |
| Sidebar drag gap | CASpring(0.32, bounce 0.12) | `move` | 275 / 458 ms | 192 / 250 ms | - |
| Sidebar drag lift / drop | shadow group 0.22 s ease-out; drop spring(0.28, bounce 0.18); refused dim spring 0.26 | `lift`, `settle`, `hover` | 220 / 308 / 258 ms | 120 / 175 / 80 ms | - |
| Sidebar hover buttons, resize line | 0.14 s ease-out | `hover` | 140 ms | 80 ms | - |
| Sidebar agent spinner / pulse | 0.9 s loops | `spinner`, `pulse` | loop | loop | - |
| Palette open | opacity 0.18 s linear; scale CASpring k 420 c 30 (0.307/0.73, 3% overshoot) | `fadeIn` + `appear` from presentation, about the panel center (was `panel`, pivoting on the left edge until 2026-09-30) | 180 ms; 350 / 433 ms | 120 ms; 142 / 283 ms | fade 132-179 ms, scale 231-277 ms |
| Palette close | opacity + shrink 0.14 s ease-in | `fadeOut` | 140 ms | 80 ms | 83-92 ms |
| Palette reopen during close | removed animations, restarted from 0 (jump) | continues from presentation | jump | no jump | - |
| Palette actions menu | fade 0.14 s | `fadeIn` / `fadeOut` | 140 ms | 120 / 80 ms | - |
| Palette result changes | instant | instant (unchanged) | 0 | 0 | - |
| Omnibar fill / ring | CATransaction 0.12 s | `hover` | 120 ms | 80 ms | - |
| Omnibar dropdown | instant show and hide | instant (unchanged) | 0 | 0 | - |
| Browser find bar, notices | fade in 0.14 s, out 0.12 s, curve (0.2, 0.9, 0.3, 1) | `fadeIn` / `fadeOut` | 140 / 120 ms | 120 / 80 ms | - |
| Browser toolbar show / hide | constraint 0.2 s, same curve | `appear` / `disappear` (timed equivalent) | 200 ms | 175 / 142 ms | - |
| Browser progress line | CATransaction 0.2 s | `move` (timed equivalent) | 200 ms | 192 ms | - |
| strip column scroll (reveal, wheel, fling) | display-link spring 0.42/0.96 | `scroll` | 458 / 592 ms | 208 / 267 ms | 366-377 ms (reveal of a full-width column; rest is longer for long travel) |
| Screen switch | display-link spring 0.38/0.92 | `screen` | 367 / 475 ms | 208 / 267 ms | 244-249 ms |
| Splits (Cmd-D, Cmd-Shift-D) | one frame | `split` (0.28 / 0.95, 2026-10-19; was `move`): the new pane grows from the far edge of the pane it split while its whole even chain makes room on the same spring, and the divider slides in from that edge (cx-f6i7, split-spring-animation) | 0 | 195 ms (95%) / 375 ms (700 pt) | - |
| Pane close, move | one frame | one frame (unchanged) | 0 | 0 | - |
| Pane ratio, equalize, width presets, pane zoom | display-link spring 0.34/0.88 | `move` | 292 / 483 ms | 192 / 250 ms | 258 ms (column width preset) |
| Drop-zone overlay | display-link spring 0.20/0.90 | `track` | 192 / 250 ms | 117 / 167 ms | - |
| Focus ring | CATransaction 0.16 s | `focus` | 160 ms | 100 ms | - |
| Inactive pane dim | CATransaction 0.16 s | `paneDim` | 160 ms | 150 ms | - |
| Divider hover | CATransaction 0.12 s | `hover` | 120 ms | 80 ms | - |
| Pane attention flash | keyframes 0.9 s (0.35 s fade reduced) | `flash` 1.0 s (0.5 s reduced; none when off) | 900 ms | 1000 ms | - |
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
and of layer animations starts from the presented value), `AnimationSpeedSettingsTests`.

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
The palette now opens with `fadeIn` plus an `appear`
spring from 0.97 about its center (visible end 175 ms), and closes with
`fadeOut` (80 ms) plus a shrink to 0.98. Result changes stay instant. The
palette keeps a fixed height, so there is no list-height animation yet.

## Not verified

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
