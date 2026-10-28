# Motion from first principles

Status: Part 1 (the split fade) on `cp/motion-split-fade`; Part 2 (every other animation) planned and ranked here,
one branch per area, not started. Owner of the switches and tokens: [motion-DESIGN.md](motion-DESIGN.md) and
[motion.md](motion.md). This file owns the rules below and the ranked work list.

## Ask

Lawrence, 2026-10-27: "we need to make better + more performant animations of everything from first principles too.
Making a new split needs a more subtle animation for the split that is coming in (just an opacity fade maybe)."

## Principles

Copied from how Chrome (cc, ui/compositor, views) and macOS (Core Animation, AppKit, the HIG) animate. Every new or
rewritten animation follows them; a reviewed exception says which rule it breaks and why.

1. **Animate only compositor properties.** Opacity and transform (and, on macOS, a layer's position and bounds when no
   content inside lays out again) run on the render server: Core Animation, like Chrome's compositor
   (`cc/animation/keyframe_model.h`, `ui/compositor/layer_animator.h`), interpolates them with no main-thread work per
   frame. Width, height, constraints, `NSView.frame` of a view whose content lays out, SwiftUI state and CSS `width`,
   `height`, `left`, `margin` are not compositor properties: animating them is a layout per frame.
2. **Never lay out per frame.** One layout to the final state, in the input's turn; then animate the visual from the
   old picture to the new one (Chrome's "commit once, animate on the impl thread"; FLIP on the web). A terminal or a
   page that resizes per frame reflows per frame.
3. **Interruptible from the current value.** A new input retargets from what shows, with its velocity where it has one
   (additive Core Animation springs, `RenderSpring`; `SpringValue` on the CPU). Nothing restarts from its model value
   or jumps.
4. **Motion explains a change; it never decorates.** Animate only what the person needs to follow: where something
   came from, where it went. A change the person caused at the place they look at needs little or no motion.
5. **Short and subtle for frequent actions.** Splits, tabs, focus, hover: 80 to 150 ms, opacity first
   (`MotionScale.quick`, `micro`). Larger moves (up to `large`, 240 ms) only for rare spatial changes: a zoom, a
   window, a panel that slides from an edge.
6. **Input first.** Focus, keys and clicks reach the new state in the input's turn, before and during the animation.
   The model holds the final value from the first frame (Core Animation's model/presentation split); the animation is
   presentation only.
7. **No animation where no one looks.** Hidden windows, background workspaces and occluded panes change the model only
   (`Motion.canAnimate(in:)`, visibility nodes); their next show is one layout at the final state.
8. **Work with no animation at all.** Every animation goes through its `Motion.<category>` gate; with the master switch,
   its category or speed off (and under Reduce Motion for movement) the change shows in one frame and completions run.
9. **Measure from the input to the frame shown.** Distributions (p50, p95, p99, max) and dropped frames at the
   display's full refresh, light and STRESS, before and after (perf-lead.md).

## Part 1: the split fade (`cp/motion-split-fade`)

Before: Cmd-D grew the new pane from a sliver on its neighbour's edge while the whole chain sprang to its new sizes
(`split` spring, about 290 ms visible). Every pane of the chain was laid out on every display frame (host frame, tab
strip, terminal or page view), and the overlay plane re-synced per frame: rules 1, 2 and 5 broken on the most frequent
layout action. The render-server variant of the same spring (`motion.renderServer`) is off by default.

After (`SplitArrival.fade`, the default; Debug Settings `motion.split.arrival` = grow keeps the old spring to compare):

- The key's turn lays the split out once at its final layout (`ScreenContentView.reconcile`): the new pane at its rest
  frame, every pane beside it at its new size, the dividers at rest. No display frame moves a pane; the CPU asks for no
  motion frames for it.
- The new pane's host layer and its chrome layer (border, ring, dim) fade in on the render server, opacity only, from
  0 to 1 (`MotionFade.fadeIn`, 120 ms at the default speed, ease-out; 180 ms at "normal"). The model opacity stays 1,
  so focus, keys and clicks reach the new pane in the key's turn (focus already moved in that turn; unchanged).
- No wait for the content. The pane comes in on its own background from the key's turn: a terminal host paints its
  theme background in that turn (over a see-through window the window's sheet shows through it), so the fade starts
  at once. Its content fades in when it first draws (`LayoutPaneContentProvider.paneArrived`,
  `PaneController.contentArrives`): a terminal's surface (text and cursor) is held at 0 on the render server until
  its first frame after its first content (the daemon's snapshot or the shell's output), then fades in; a page from
  its first paint. Content that drew already (a handoff's chat, a page) is not held. The hold ends at most 1 s after
  the pane arrived (a shell slow to print), done by one Core Animation keyframe animation, no timer. Cost: the first
  prompt or echo shows about two display ticks after it is parsed (the first-frame rule) and fades in over 120 ms.
- Why not "first frame within one frame of the split": the text is the new shell's output. The daemon creates the PTY
  and the shell only after the split request (about 80 to 110 ms reply), and a shell such as oh-my-zsh then takes
  30 to 260 ms more to print (first-seconds-lag-result.md). No app-side change makes that text exist in one frame;
  a prewarmed shell in the daemon would, and is a separate daemon item (none exists today).
- `Motion.panes` gates it: master switch, panes category, speed off: no animation, the split shows in one frame.
  Reduce Motion and `ui.paneAnimations` off: the split shows in one frame, as before.
- A content handoff (a split of a browser tab, the New Tab page or a chat that moves the old content to the new pane)
  fades the pane with the new content in place instead of sliding it in from the screen edge. A new dock column still
  grows from its edge (rare, spatial).

Known limits: a page drawn in a Chromium child window ignores its host layer's opacity and shows at once while its
border and ring fade.

Visible changes to judge in the clips: no growth from the edge; the panes beside the split take their new size in one
frame; the new pane and its ring appear with a short fade. Content in a Chromium child window (a page tab in the new
pane) shows at once: a child window does not take its host layer's opacity.

Tests: `SplitFadeMotionTests` (red on the base: the plan sets the split at rest, the key's turn lays it out at rest and
no frame moves a pane; the key's turn tells the provider which pane arrived), `MotionFadeInWaitTests` (the content
hold: opacity only, model at rest, the first drawn content starts the fade, a still gate animates nothing),
`SplitFadeWindowTests` (pane bench, a real window: opacity on the new pane's layers only, no hold on the pane).

Results: see "Part 1 results" at the end.

## Inventory

133 distinct animations: 115 native and 18 web groups (the web groups cover about 330 CSS and WAAPI declarations). By
how they run:

- (a) CPU-stepped on the main thread, a frame or layout write per frame: the pane layout springs (split, close, zoom,
  divider release, strip, row and area cameras, canvas camera, screen switch, drop highlight), the tab drag ghost, the
  sidebar and tab drag autoscroll.
- (b) AppKit `animator()` in an `NSAnimationContext` (AppKit steps it on the main thread; constraints and frames lay
  out per frame): the sidebar width, the collapsed titlebar band, most `Motion.<category>.animate(fade) {
  view.animator().alphaValue }` fades, the browser toolbar rows, window frames (zoom, quick composer).
- (c) Core Animation on the render server (no main-thread work per frame): tab open, close and reflow tweens, sidebar
  row frames (`SidebarDragSpring`), popups, palette, toasts, hover cards, tooltips, focus ring, dim, attention flash,
  hover fills, loops, the split fade.
- (d) SwiftUI: a few server and Apps views, the update sheet's symbol effects.
- (e) Web pages: CSS transitions and WAAPI; `WebTheme`'s bootstrap zeroes all of them when `ui.animations.web` is off.

Bypasses found: no CSS transition ignores `data-cmux-motion`; requestAnimationFrame-driven JS (scroller ink fade,
streaming reveal, glass lens) is not covered by that stylesheet. Implicit layer actions with a 0 s gate action rely on
callers to write inside a gate transaction. Doc mismatch: motion.md rule 9 says pane animations are off by default;
the code has `ui.paneAnimations` on.

## Ranked work list (frequency seen x cost per frame)

Each line: the animation, its main call site (relative to `Packages/macOS/CmuxNext/Sources` or `webviews/src`), the
fix by the principles, and the visible change. One branch per area, each with a test that fails first, a fleet frame
measurement before and after, light and STRESS, and a clip.

| # | Animation | Call site | Cost now | Fix | Visible change | Branch | Status |
|---|---|---|---|---|---|---|---|
| 1 | Split grow | CmuxNextLayout/Views/ScreenContentView+Motion.swift:83 (step), :199 (applyPresentation) | layout of the whole chain per frame | one layout, opacity fade of the new pane | fade instead of growth | cp/motion-split-fade | done |
| 2 | Pane close | CmuxNextLayout/Views/ScreenContentView.swift:318 (departing) + step | neighbours laid out per frame | one layout; the closed pane's last picture fades out over its neighbours at rest (a snapshot layer), or no motion | neighbours take the space in one frame; the closed pane fades | cp/motion-pane-close | pending |
| 3 (p03-025) | Strip column reveal / center | ScreenContentView+Motion.swift:121; LayoutRootView.swift:442 | host origins and clips per frame | lay out at rest once; spring the strip container's translation on the render server (as `StripPanContainer` does for pans) | none | cp/motion-strip-camera | pending |
| 4 | Sidebar show/hide | CmuxNextSidebar/Views/SidebarContainerView.swift:404 | Auto Layout of the window root per frame | final width in one layout; slide the sidebar layer (transform) and fade; content area at its final width at once | the content area no longer slides with the sidebar | cp/motion-sidebar | pending |
| 5 | Collapsed titlebar band reveal | CmuxNextDesign/CollapsedBandReveal+CPUStep.swift:48 | root layout per frame, on hover | the render-server variant (CollapsedBandReveal.swift:163) by default | none | cp/motion-band-reveal | pending |
| 6 | Screen switch | CmuxNextLayout/Views/LayoutRootView.swift:556 | setFrameOrigin + alpha + overlay sync per screen per frame | screens at rest; translate their layers on the render server | none | cp/motion-screen-switch | pending |
| 7 | Theme / workspace colour fade | CmuxNextDesign/ColorTransition/ColorTransition.swift:183 + web colours | every web page restyles and every terminal redraws per frame | crossfade a snapshot over the new colours (one repaint), or no transition on workspace switch | a crossfade, not a colour blend | cp/motion-color-transition | pending |
| 8 | Tab drag ghost | CmuxNextApp/Drag/TabDragSession+Ghost.swift:90 | window origin, alpha and layer frames per frame | the render-server ghost (TabDragGhostPanel.swift:405) by default | none | cp/motion-tab-drag | pending |
| 9 | Drop-zone highlight | CmuxNextLayout/Views/DropHighlightView.swift:206 | renderer update per frame | its render-server variant by default | none | cp/motion-drop-highlight | pending |
| 10 | Sidebar row opacity + group lines | CmuxNextSidebar/Views/SidebarRowMotion.swift:119 | AppKit spring writes alpha and line frames per frame | layer opacity and position on the render server (`MotionGate.animate(_:in:frame:alpha:)`) | none | cp/motion-sidebar-rows | pending |
| 11 | Main-thread hover fades | CmuxNextDesign/HoverReveal.swift:238; CmuxNextApp/WindowRootView+TitlebarReveal.swift:22; CmuxNextSidebar/Views/Sections/SidebarSectionHeaderView.swift:66 | alpha written per frame | layer opacity via `Motion.<category>.set(layer, "opacity", fade:)` | none | cp/motion-hover-fades | pending |
| 12 | Divider release / equalize | CmuxNextLayout/Views/ScreenContentView+DividerDrag.swift:121 | affected panes laid out per frame | one layout at the final ratios; no motion (the drag already showed the path) or a short layer move | the panes take their final size at the release | cp/motion-divider-release | pending |
| 13 | Web conversation fold | webviews/src/agent-session/acpmux/conversation/fold.ts:158 | WebKit lays out the transcript per frame (height) | FLIP: final height at once, animate a transform/clip of the content, opacity for the text | none | cp/motion-web-fold | pending |
| 14 | Browser toolbar show/hide | CmuxNextBrowser/UI/BrowserChromeView+Toolbar.swift:45 | row frames and the page resize per frame | the render-server slide (:107) by default | none | cp/motion-browser-toolbar | pending |
| 15 | Window zoom, quick composer frame | CmuxNextDesign/Windows/WindowZoom.swift:50; CmuxNextFloating/QuickComposer/QuickComposerPanel+Floating.swift:55 | full window resize per frame | final frame at once; no motion (macOS's own zoom is instant with Reduce Motion) or a snapshot scale | rare | cp/motion-window-frames | pending |

Owned elsewhere (2026-10-28): items 3 (strip camera), 5 (band reveal: its render-server variant), 6 (screen switch),
8 (tab drag ghost), 9 (drop highlight) and 14 (browser toolbar) already have render-server variants or tasks in
chrome-parity p03-rendering (025 camera springs, 030 screen switch, 032 drop highlight, 035 tab drag ghost; 022c
turns `motion.renderServer` on by default after its measurements). This work does not duplicate them; it feeds them
the measurements. Its own order is 1, 2, then the sidebar Cmd-N burst (Lawrence 2026-10-28), then 4, 10, 11, 7, 12,
13, 15.

Runners-up: the web scroller ink fade (`scrollers.ts:84`, a custom property per frame), the streaming reveal
(`RevealedMarkdown.tsx`, a layout per token), the tab strip drag autoscroll. Items 3, 5, 6, 8, 9 and 14 already have a
render-server variant behind `motion.renderServer` (off by default): turning it on per kind, after its own measurement,
is the cheapest path for them.

## Part 1 results

Filled in by the branch's fleet runs (see the handoff note for job ids).
