# Freeform canvas layout for workspace panes

A workspace can opt into a freeform 2D canvas layout: every panel (terminal,
browser, markdown, file preview, agent session, ...) becomes a freely placed,
individually resizable pane on an infinite scrollable canvas. Canvas layout
coexists with the default bonsplit split layout; a workspace switches modes
without losing panels, and switching back restores the previous split tree.
The same pane/tab model also has a Niri-style Pages mode: each surface pane is
available through a native AppKit page strip. Pages mode does not run inside
the canvas `NSScrollView`: horizontal swipes are handled by `NSPageController`,
vertical scroll remains with the surface, and canvas zoom/drag behaviors are
inactive.

## Why

Static splits stop scaling past a handful of live agent sessions. A spatial
canvas gives every pane a stable place you can flick to with trackpad panning
or spatial focus keys, instead of nesting ever-smaller splits.

## Architecture

Two layers, enforced by SPM separation:

1. `Packages/CmuxCanvas` — the pure model. Pane frames, gap math, snapping,
   alignment/distribution commands, spatial focus, placement of new panes,
   viewport math (scroll-to-reveal, fit-all). Foundation-only, no
   AppKit/CoreGraphics, deterministic, fully unit tested. Declares macOS and
   iOS platforms so the same model can drive a touch canvas later.
2. `Sources/Canvas/` — the thin AppKit rendering and input layer (app target,
   one type per file). `NSScrollView` + flipped document view; panes are real
   AppKit subviews of the document view.

### Hosting: direct subviews, not window portals

In split mode, terminal views are hosted by `TerminalWindowPortalRegistry` at
window level and their frames are intersected with ancestor bounds
(`effectiveAnchorFrameInWindow`), i.e. a partially visible pane is *resized*
to its visible rect. On a scrolling canvas that would continuously resize and
reflow Ghostty surfaces as panes cross the viewport edge.

Canvas mode therefore does not mount the portal-anchored SwiftUI panel views
for terminals. The pane's `GhosttySurfaceScrollView` is detached from the
portal (`TerminalWindowPortalRegistry.detach(hostedView:)`, the same path used
when moving panels between workspaces) and parented directly into the canvas
pane view. Full size is preserved at all times; clipping at the viewport edge
is the scroll view's clip view doing its normal job; scrolling is native
(momentum, rubber-banding, interruptible) because it *is* `NSScrollView`.

Non-terminal panel kinds keep their existing SwiftUI views inside an
`NSHostingView` per pane in v1. Their embedded window-portal content (web
views) is kept in sync during scrolling via the clip-view bounds-change
notification driving a portal geometry sync. Known v1 caveat: portal-hosted
content clips by resizing at the viewport edge and always renders above
direct-hosted content; terminals are the flawless path and the others are
correct-but-not-perfect until they get direct hosting too.

### Mode switching

- splits → canvas: seed each pane's canvas frame from the bonsplit
  `LayoutSnapshot` pane frames, so the canvas initially looks identical to
  the split layout, then normalize to the canonical gap.
- splits/canvas → niri: keep the same canvas pane/tab model, but render it in
  `CanvasPagesRootView`, a native `NSPageController` host. The mode selects
  one pane per page instead of scrolling a 2D canvas and snapping back.
- canvas → splits: the workspace's previous bonsplit tree is kept while in
  canvas mode (panels are never removed from bonsplit bookkeeping); leaving
  canvas mode re-mounts the bonsplit view. Panels created while in canvas
  mode are appended as tabs to the focused bonsplit pane so nothing is lost.

### Pane lifecycle and offscreen cost

Explicit, not incidental: `CanvasPaneLifecycle` classifies each pane every
time the visible rect changes (scroll/resize/zoom):

- `visible` — intersects the viewport (plus one viewport-margin): live.
- `nearby` — within prefetch margin: live (terminals keep rendering; cheap).
- `offscreen` — terminal surfaces get the same occlusion treatment as
  hidden split panes (`setVisibleInUI(false)` equivalent hint); browser
  panes keep their existing hidden-webview discard policy.

Frames never change while offscreen, so no reflow happens on re-entry.

## Model (CmuxCanvas)

- `CanvasRect/CanvasPoint/CanvasSize` — Double-based, Codable, Hashable.
- `CanvasLayout` — ordered pane list (back→front z-order), frames, focused
  pane id; mutations: add/remove/move/resize/bring-to-front. Codable for
  persistence.
- `CanvasMetrics` — canonical gap, snap threshold, min pane size; injected,
  user-configurable.
- `CanvasSnapEngine` — candidate snap targets while dragging/resizing:
  neighbor edge alignment, neighbor edge + gap, center alignment; returns the
  adjusted rect plus guide lines for the overlay.
- `CanvasAlignment` — align lefts/rights/tops/bottoms, equalize
  widths/heights, distribute horizontally/vertically at the canonical gap,
  and `tidy` (row-band packing that preserves sizes and spatial order) —
  one command from messy to grid.
- `CanvasSpatialNavigator` — nearest pane left/right/up/down from the focused
  pane (directional half-plane + orthogonal misalignment penalty,
  deterministic tie-break).
- `CanvasPlacement` — frame for a new pane near the focused pane at the
  canonical gap (right, below, left, above, then outward scan), never
  disturbing existing panes.
- `CanvasViewportMath` — minimal scroll offset to reveal a rect with margin;
  fit-all magnification for overview.

## Actions (one shared entrypoint each)

`CanvasActionExecutor` (app target) is the single execution path; keyboard
shortcuts, command palette, View menu, and the `canvas.*` debug-socket verbs
all call it. Spatial focus reuses the existing split-focus actions when the
workspace is in canvas mode (same shortcut, mode-appropriate behavior).

Actions: cycle layout mode, focus left/right/up/down, focus previous,
reveal focused pane, overview (fit all), zoom to 100%, align
lefts/rights/tops/bottoms, equalize widths/heights, distribute
horizontally/vertically, tidy canvas.

The hidden layout toggle path (`Cycle Layout Mode`, `canvas mode toggle`)
cycles Splits → Canvas → Pages → Splits so existing keyboard, palette, menu,
and socket entrypoints can reach Pages without requiring the toolbar selector.

`canvas.set_mode` accepts `splits`, `canvas`, `niri`, and `toggle`. The Niri
mode still reports through `canvas.info` and uses the same `canvas.*` control
verbs because it shares the canvas pane/tab model, not because it is rendered
by the canvas scroll view.

All new shortcuts are registered in `KeyboardShortcutSettings`, editable in
Settings, configurable in `~/.config/cmux/cmux.json`, and documented in the
web docs. Settings: `canvas.paneGap` (points), `canvas.snapping` (bool).
All user-facing strings localized (en + ja).

## Persistence

`SessionWorkspaceSnapshot` gains `layoutMode` and an optional encoded
`CanvasLayout`. Restore rebuilds the canvas exactly; panes keep their frames
across restarts.
