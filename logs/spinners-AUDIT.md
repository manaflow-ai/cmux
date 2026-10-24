# Spinner and loading-indicator audit (cmux NEXT)

Ask (Lawrence, 2026-10-21): "for the loading spinners, is it running on main thread? should it be or
is it wasteful in terms of cpu?"

Short answer: the app's own spinners already run in the render server. Each one is a Core Animation
layer animation, so the app's main thread does no work per frame. Two loops in the agent chat page
did repaint on the page's main thread every frame. They are fixed in this change:

- the "Thinking" shimmer, which animated `background-position`,
- the breathing working dot, which animated a shape inside an svg.

The paths in the first report (`Packages/CmuxUpdaterUI/.../UpdateBadge.swift`,
`Sources/SettingsNavigation.swift`) belong to the classic app. cmux NEXT does not build them.

Cost per frame means work that the app process (or the page's WebContent / renderer process) does on
its main thread for each display frame while the loop runs.

## Native (AppKit, Core Animation)

| Indicator | Where | How it animates | Main-thread cost per frame | Stops when hidden / occluded / Reduce Motion |
|---|---|---|---|---|
| Sidebar row, group header, row badges | `CmuxNextSidebar/Views/WorkspaceRowView.swift`, `GroupHeaderRowView.swift`, `RowBadgeView.swift` -> `StatusIndicatorView` | `StatusIndicatorLayer`: `CABasicAnimation` on `transform.rotation.z` (arc), stepped rotation (native spokes), `contents` keyframes (braille), opacity (pulse/breathe). Phase from `SpinnerClock`. | 0 (render server) | Yes: the sidebar list sets `isWindowVisible` from occlusion; `Motion.indicators.animatesLoops` is off under Reduce Motion and the static look |
| Tab strip status badge | `CmuxNextTabs/TabCell+StatusBadge.swift` | `StatusIndicatorLayer` (same as above) | 0 | Yes (same config) |
| Chrome spinners (`ThemedSpinner`, `StatusIndicatorView.spinner()`): accounts rows, app scene loading, server views, palette search, sidebar notice card, remote pane connecting card | `CmuxNextDesign/StatusIndicator/ThemedSpinner+SwiftUI.swift`, `StatusIndicatorView+Spinner.swift` | `StatusIndicatorLayer` in an `NSViewRepresentable`; SwiftUI does not redraw it per frame | 0 | Yes: `tracksWindowOcclusion = true` |
| Workspace hover card activity | `CmuxNextSidebar/Views/WorkspaceHoverCard.swift` | `StatusIndicatorLayer` | 0 | Yes (`tracksWindowOcclusion`) |
| Home chat typing dots | `CmuxHomeRender/Scene/RowLayer.swift` `startTypingDots` (`Animate.typingDot`) | Layer opacity keyframes per dot | 0 | Reduce Motion: still (`HomeMotion`). Occluded: WindowServer does not composite an occluded window, so the cost is 0 there too |
| MessagesLab typing dots / breathing | `CmuxMessagesLab/.../Transcript.swift` `startTypingDots` | Layer keyframes ("typing dots that animate on the render server") | 0 | Reduce Motion: still |
| Update sheet progress bar | `CmuxNextUpdater/UpdateSheetView.swift` | SwiftUI `ProgressView(.linear)` -> AppKit `NSProgressIndicator` (AppKit animates its own layer) | ~0 | Shows only while an update downloads |
| App scene determinate bar | `CmuxNextApps/Render/AppSceneNodeView.swift` | Determinate `ProgressView`; redraws only when the value changes | 0 at rest | n/a |
| Sleepy Mode sky (not a spinner) | `CmuxNextApp/SleepyMode/SleepySceneView.swift` | `TimelineView(.animation(minimumInterval: 0.1))`: SwiftUI body at 10 fps on the main thread | 10 body runs per second while Sleepy Mode shows | Motion off: still sky. Left as it is: a deliberate 10 fps full-screen scene, not a loading indicator |

No native spinner uses `TimelineView(.animation)`, a `Timer`, a `CVDisplayLink` or `FrameScheduler`.
`FrameScheduler` / `MotionClock` drive pane motion and live resize, not the loops above.

App inactive (another app in front, window still visible): the native loops keep turning on purpose.
They cost the app nothing, and a spinner that freezes while it is still visible would show the wrong
state. An occluded or hidden window stops them.

## Web pages (agent chat, settings, Home channels)

All page spinners run CSS keyframes. No spinner uses `requestAnimationFrame` or JS timers to drive
its motion. `ui/spinnerClock.ts` only sets each animation's `startTime` once, when the
`animationstart` event fires.

| Indicator | Where | Animates | Compositor only? | Stops |
|---|---|---|---|---|
| Ring spinner (`cmux-spin`): `.cv-spinner`, plan mark, harness rows, model picker refresh, diff spinners | `pages/shared/desktop.css`, `conversation.css`, `acpmux/styles.css`, `harnesses.css`, `styles.css` | `transform` on an svg box or an HTML box | Yes | Reduce Motion, static look |
| **Thinking line shimmer** (default while a turn runs) | `conversation/Thinking.tsx`, `conversation.css` | **Before:** a text-clipped gradient's `background-position` (`cmux-shimmer`). **After:** `ShimmerText.tsx`, a masked band and its lit copy of the words, with two `transform` loops (`cmux-shimmer-band`, `cmux-shimmer-lit`) | **Before: no** (the words restyled and repainted every frame). **After: yes** | Reduce Motion, static look |
| **Working dot breathe** (default working look) | `conversation.css` `.cv-spinner[data-working]` | **Before:** `opacity` on the `<circle>` inside the svg. **After:** `opacity` on the svg box (the arc is hidden in this look) | **Before: no** (a shape in an svg has no layer of its own). **After: yes** | Reduce Motion, static look |
| **Tool-row shimmer** (Debug Settings working look "shimmer", not the default) | `conversation/ToolText.tsx`, `conversation.css` `.cv-tool__text` | **Before:** `background-position` (`cmux-shimmer`). **After:** `ToolText.tsx`, a masked band and its lit copy of the row's words (the same children: aria-hidden, inert, skipped by find), with the Thinking line's two `transform` loops; `cmux-shimmer` is gone (perf-lead row 23) | **Before: no** (repainted the row every frame). **After: yes** (`static-status-loops.test.ts` checks every pane loop's keyframes) | Reduce Motion, static look |
| Running wave (subagent avatars, running items) | `ui/wave.css` | `opacity` | Yes | Reduce Motion, motion gate, static look, hidden page |
| Floating / Chief dock status breathe | `acpmux/styles.css` | `opacity` | Yes | Reduce Motion |
| Jump-to-latest dots | `conversation.css` | `opacity`, `transform` | Yes | Only while shown and working |
| Home channels "writing" / ledger pulse | `pages/home-channels/styles.css`, `ledger.css` | `opacity` | Yes | Reduce Motion |
| Settings accounts busy dot | `pages/settings/styles.css` | `opacity` | Yes | Not gated on Reduce Motion (a small gap, not fixed here) |
| Apps skeleton breathe | `pages/apps/styles.css` | `opacity` | Yes | Reduce Motion, static look |

A hidden page (its tab is not shown) gets no frames from WebKit or Chromium, so its CSS loops cost
nothing there.

## Tests and measurements

- `webviews/test/working-loops-compositor.test.tsx` renders the real `Thinking` line and `Spinner`
  marks with the real stylesheets in Chromium and WebKit. It checks that every running loop animates
  only `transform` / `opacity` on a box that gets its own layer. It also checks that the line reads
  its words once and that Reduce Motion stops every loop. It fails on the old shimmer and the old
  dot.
- `webviews/test/working-loops-main-thread.test.tsx` counts the page main thread's style recalcs per
  second and its task ms per second, for 1 and 20 shimmering lines, old against new (Chromium, CDP).
  It fails when the current lines restyle on each frame.
- `scripts/perf-bench/spinners.py` is a phase of a436's `cmux-budget` session. It runs with 0, 1 and
  20 visible loading spinners (workspaces with indeterminate progress) and records:
  - tree CPU %,
  - wakeups per second,
  - the app's main-thread CPU % (`ps -M`).

  The budget rows in `scripts/perf-bench/budgets.json` are advisory.

Results: see the report for the fleet run.
