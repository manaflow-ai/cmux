# Canvas layout (cmux-next)

Status: slices 1 to 3 landed (INVENTORY row 31): every canvas action works. Slice 4 is open. Owner slug: `canvas-layout`.

Classic cmux has a freeform canvas (#5987, `docs/canvas-layout-design.md` on
`main`, packages `CmuxCanvas` and `CmuxCanvasUI`): every pane of a workspace is
a freely placed, resizable rectangle on a zoomable, pannable plane. cmux-next
had the 15 actions in its catalog, bound unavailable. This plan ports the
feature onto the cmux-next layout engine.

## Where the canvas state lives

The daemon owns the pane set and the split tree or column strip of every
screen. The canvas is a **client presentation of one screen**, like the column
strip's scroll offset: the App keeps it, the daemon does not know it.

- `LayoutModel.canvases: [ScreenID: CanvasScreen]` holds, per screen in canvas
  mode, each pane's frame in canvas points, the z-order and the camera
  (`CanvasCamera`: the canvas point at the viewport center and the zoom), and the
  camera to return to from Canvas Overview.
- Panes still come from the daemon. Every `apply(screens:)` reconciles each
  canvas with its screen's panes: a pane that left drops its frame, a new pane
  (a split, a tab moved out, another client's change) gets a free frame next to
  the focused pane (`CanvasPlacer`). Existing frames never move by themselves.
- Splits and columns keep working underneath. The daemon tree goes on changing
  with splits, closes and moves; the canvas ignores its shape and shows only its
  panes. Leaving canvas mode shows the daemon layout again, which never left.
- A zoomed pane (Toggle Pane Zoom) shows full size as before; the canvas comes
  back when the zoom ends.

Why not the daemon: a canvas frame is per-window presentation (two Macs on one
daemon may want two arrangements; iOS shows no canvas), and putting it in the
daemon needs a new layout kind that every pane command (split, close, move,
swap, rows, docks) would have to handle. If the canvas must sync between
clients later, a `canvas-v1` capability can store `CanvasScreen` as an opaque
per-screen blob on the daemon with no change to how the App draws it.

Persistence: in-memory for the first slices (a relaunch shows the daemon
layout). A later slice keeps `CanvasScreen` per daemon screen id in an
app-local JSON file, the way `WorkspaceBackgroundStore` keeps backgrounds.

## Drawing

`ScreenContentView` draws a canvas screen with the same hosts, springs, overlay
plane and visibility reports as a split screen:

- `ScreenGeometry.canvas(_:)` puts each pane at its canvas frame (content space
  = canvas space). No dividers, columns or docks.
- The camera is the view's **bounds**: origin = top-left canvas point, size =
  view size / zoom. AppKit scales drawing, hit testing and `convert(_:from:)`
  for the bounds, so focus rings (overlay plane), tab drops, pane hits,
  child-window pages and the visible and keep-alive bands all follow with no
  per-feature camera math. Zoom keeps each pane's own size in points: a
  terminal keeps its grid when zooming (drawn scaled), it does not reflow.
- Moving and resizing: handles in the gap around each pane (top band moves,
  sides and corners resize), sized in screen points at every zoom.
- Panning: a horizontal trackpad scroll anywhere, or any scroll over the empty
  canvas, pans (momentum included). Vertical scrolls over a pane still scroll
  that pane (terminal scrollback). Pinch zooms around the pointer.
- Keyboard focus moves (`moveFocus`) use the canvas frames
  (`FocusNavigation`), and a keyboard or programmatic focus pans the camera the
  least that shows the pane (`CanvasCamera.revealing`). A click never pans.

## Pure value types (CmuxNextLayout/Canvas)

All math is in pure `Sendable` values with Swift Testing coverage:
`CanvasCamera` (visible rect, zoom about a point, reveal, fit), `CanvasScreen`
(frames, z-order, reconcile with a pane set), `CanvasPlacer` (frame for a new
pane), `CanvasPaneDrag` (move and resize with minimum size), `CanvasArranger`
(align, equalize, distribute, tidy; classic `CanvasAligner` semantics: every
pane of the screen, the focused pane is the equalize reference).

## Actions

One shared path per action: the handler resolves the workspace (targeted pane
or focused window) and calls one `LayoutModel` method; palette, keyboard, the
View menu, the pane context menu, the CLI names in the catalog and MCP
`action.run` all reach it through the registry. `.canvasLayout` is published
while the active window's active screen is a canvas, and an explicit pane
target on a canvas screen implies it (`registry.targetContext`).

| Action | Behavior |
| --- | --- |
| `toggleCanvasLayout` | Screen to canvas, seeded from the frames shown now (it looks the same), or back to the daemon layout. |
| `canvasZoomIn` / `canvasZoomOut` | Zoom by 1.25 about the viewport center, 0.1...3. |
| `canvasZoomReset` | Zoom 1 about the viewport center. |
| `canvasOverview` | Fit every pane in the viewport; again returns to the camera before. |
| `canvasRevealFocusedPane` | Pan the least that shows the focused pane (with a margin). |
| `canvasTidy` | Rows by vertical center, packed at the canvas gap, sizes kept. |
| `canvasAlign{Left,Right,Top,Bottom}` | Every pane's edge to the outermost one. |
| `canvasEqualize{Widths,Heights}` | Every pane takes the focused pane's width or height. |
| `canvasDistribute{Horizontally,Vertically}` | Packed in order at the canvas gap. |

## Slices

1. Toggle, free placement (move, resize, new-pane placement), pan, zoom in,
   out and reset, the `.canvasLayout` context.
2. Overview, tidy, reveal focused pane.
3. Align, equalize, distribute.
4. Persistence across relaunch; snapping guides while dragging (classic
   `CanvasSnapEngine`).

## Not done (yet)

- Persistence across relaunch (slice 4): a relaunch shows the daemon layout.
- Snapping guides while dragging (classic had them).
- A canvas minimap.
- Sync of the arrangement between clients (`canvas-v1`).
- Chromium pages are child windows: at a zoom other than 1 they keep their
  size in points while their pane scales (WebKit pages and terminals scale).
- Pane chrome on a canvas is the gap band (cursor rects show where); there is
  no drawn title bar.
