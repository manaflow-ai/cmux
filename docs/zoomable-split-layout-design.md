# Zoomable Split Layout

## Goal

Add a third workspace layout mode between normal splits and canvas:
`zoomableSplits`. It keeps Bonsplit's packed split tree as the source of
truth, but hosts that split tree inside a native AppKit viewport so the whole
layout can pan and zoom as one surface. It deliberately does not expose canvas
pane placement, gaps, z-order, or free empty-space positioning.

## Model

`WorkspaceLayoutMode` gains:

- `splits`: current Bonsplit layout.
- `zoomableSplits`: Bonsplit layout wrapped in a zoom/pan viewport.
- `canvas`: current freeform canvas layout.

The split tree, focused pane, tab order, pane navigation, and split commands
remain Bonsplit-owned in both split modes. Canvas-only features continue to use
`CanvasModel`; zoomable splits only expose viewport operations.

`Workspace` owns a weak `zoomableSplitViewport` reference that conforms to the
same `CanvasViewportControlling` protocol used by canvas. `CanvasActionExecutor`
routes viewport actions to:

- `workspace.canvasModel.viewport` in `.canvas`.
- `workspace.zoomableSplitViewport` in `.zoomableSplits`.

Canvas alignment and distribution commands stay canvas-only because they mutate
freeform pane frames and would violate the packed split tree invariant.

## Rendering

`WorkspaceContentView` still constructs the normal `BonsplitView` once. The
final mode switch becomes:

- `.canvas`: `WorkspaceCanvasHostView`.
- `.zoomableSplits`: `ZoomableSplitHostView` wrapping the existing `bonsplitView`.
- `.splits`: the existing `bonsplitView` directly.

`ZoomableSplitHostView` is an `NSViewRepresentable` that embeds the SwiftUI
split tree in an `NSScrollView` document view. At 100 percent, the document is
the viewport size and Bonsplit fills it. Zooming in magnifies the document and
enables panning across the packed layout. Reset returns to 100 percent. Overview
fits the packed document in the viewport, mirroring the canvas command shape.

The wrapper opts hosted pane content out of window portals while zoomable splits
is active. Browser panes use the same inline hosting path canvas uses, and
terminal panes parent their real `GhosttySurfaceScrollView` into the split host
while reusing the existing terminal portal lease as a stale-host ownership guard.
That makes the magnified split tree scale pane content itself instead of
resizing placeholders and asking the portal layer to follow later.

## Scroll And Gesture Routing

Canvas currently owns the desired precedence:

- Trackpad pinch magnifies the whole layout.
- Cmd+scroll pans the outer viewport from anywhere.
- Option+scroll zooms the outer viewport toward the cursor.
- Plain scroll is delivered to pane content and does not pan the outer viewport.

This PR extracts that precedence into a reusable `CanvasCommandScrollEventRouter`
inside `CmuxCanvasUI`. `CanvasRootView` and `ZoomableSplitRootView` both install
that router, so the modifier precedence is shared rather than duplicated.

## Entry Points

The toolbar layout segmented control becomes three segments: splits, zoomable
splits, canvas.

Command palette adds `Toggle Zoomable Split Layout`, backed by a new shortcut
action `toggleZoomableSplitLayout`. It is unbound by default to avoid adding a
new global collision, but it is visible in Settings, supported in
`~/.config/cmux/cmux.json`, and documented with the other layout shortcuts.

The existing canvas zoom, overview, reveal, and reset shortcuts work in both
canvas and zoomable-split modes. Labels are updated to say "Canvas/Zoomable" so
the shared behavior is visible without duplicating shortcut actions.

The existing `canvas.set_mode`, `canvas.zoom`, `canvas.overview`,
`canvas.reveal`, and `canvas.set_viewport` socket verbs are extended to accept
and operate on `zoomableSplits`. Freeform-only verbs such as frame setting,
align, join, break, select-tab, and new-pane remain canvas-only.

## Divider Thickness Setting

Bonsplit already supports `BonsplitConfiguration.Appearance.dividerThickness`.
This PR adds a persisted cmux setting:

- JSON path: `canvas.splitDividerThickness`
- UserDefaults key: `canvasSplitDividerThickness`
- Default: `1`
- Range: `1...12`

The setting applies to Bonsplit globally because the same split tree is used in
normal splits and zoomable splits. It is surfaced in Settings, included in the
settings catalog/search/schema/docs, parsed from `cmux.json`, and tested through
the settings-file runtime path.

## Verification Plan

- Package tests for command-scroll router behavior if a practical AppKit seam is
  available; otherwise verify by build and tagged dogfood preflight.
- Settings-file tests for `canvas.paneGap`, `canvas.snappingEnabled`, and
  `canvas.splitDividerThickness` parsing into managed UserDefaults.
- Shortcut drift tests already cover the app/package action mirror after adding
  `toggleZoomableSplitLayout`.
- `jq empty Resources/Localizable.xcstrings web/data/cmux.schema.json`.
- Tagged reload with a short tag, then preflight via the tagged debug CLI:
  enter `zoomableSplits`, run zoom/overview/reset/set-viewport, and capture a
  screenshot before dogfood handoff.
