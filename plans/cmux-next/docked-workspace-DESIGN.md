# cmux next: docked workspaces (the window frame)

Status: prototype (2026-10-27), behind Debug Settings `window.dockedWorkspaces` (default off).
User request (Lawrence, verbatim): "build some prototypes of docked columns/rows that are docked
to window, not workspace … needs to have same tabbing/pane/column/row system, so it is in a
sense, a workspace itself. so ig it should be a docked workspace. can you think of a better way
to design it?"

Builds on: layout-model.md (the screen frame: four edge docks around the column strip,
Docked/Floating, orientation), dock-column.md (docked columns inside a workspace),
`WindowRecord.multiView` (Leo 2026-10-21 item D: several workspaces side by side in one window),
tab-lifecycle.md (parked workspaces stay mounted).

## Recommendation in one paragraph

The window is the root layout. A window has a **frame**: up to four edge **docks** around a
**stage**. Each dock holds one ordinary workspace (a *docked workspace*); the stage shows the
workspace the sidebar selects. Switching workspaces changes only the stage; the docks stay. A
docked workspace is not a new kind of object: it is a workspace with every tab, pane, split,
column, row, docked column, shortcut, drag, undo and persistence rule it already has, because the
daemon cannot tell it apart from any other workspace. What is new is one per-window, client-side
record, `WindowRecord.docks`, and one pure placement function. The vocabulary, the edge set, the
Docked/Floating modes, the extent rule and the orientation rule are the screen frame's
(layout-model.md), one level up: a screen frames columns, a window frames workspaces.

## Vocabulary

| Word | Meaning |
| --- | --- |
| frame | the window's content area: a stage and up to four docks |
| stage | the frame's center; shows the selected workspace (or a `multiView` set) |
| dock | one edge of the frame (left, right, top, bottom) holding one workspace |
| docked workspace | a workspace held by a dock; an ordinary workspace in every other respect |
| Docked / Floating | dock mode: takes space from the stage, or floats over its edge (wire `docked` / `floating`) |
| hidden | a dock that keeps its workspace but takes no space and draws nothing (Toggle) |
| orientation | `column_major` (side docks own the corners, default) or `row_major` (top/bottom own them) |

## Designs compared

- **F, the window frame (chosen).** Docks name whole workspaces; the stage follows the sidebar.
- **S, sticky columns.** The user's first sketch, literally: a docked column that "follows" the
  window, moved into each workspace's screen on every switch.
- **N, a new dock container.** A window-level container with its own tabs, panes and splits that
  is not a workspace.
- **T, a free workspace tree.** Generalize `multiView` (a split tree of workspaces) with one leaf
  marked "follows the sidebar"; docks are just tree shapes.
- **D, daemon-owned docks.** Docks stored in the shared workspace tree.

| Question | F frame | S sticky | N container | T tree | D daemon |
| --- | --- | --- | --- | --- | --- |
| Same tab/pane/column/row model | yes, it is a workspace | yes | a second copy of every rule | yes | yes |
| Cost of a workspace switch | O(1): the stage swaps one view | O(panes): daemon move ops per switch, journaled | O(1) | O(1) | O(1) |
| Undo history | untouched by switches | every switch writes undo steps | separate | untouched | untouched |
| Hidden workspaces do no work (CLAUDE.md) | yes | no: a switch rewrites two layouts | yes | yes | yes |
| CLI/MCP/agents address it | as a workspace, by id | the column changes owner, ids move | new object kind everywhere | as a workspace | as a workspace |
| Per-edge toggle, Floating, extent | yes | yes | yes | no edges, no floating | yes |
| Other clients (iOS, a second Mac, TUI) | each window/client has its own frame | shows a column jumping between workspaces | new kind to render | each has its own | every client would show one Mac's window chrome |
| Change to today's code | one record field, placement, actions | new daemon op, races with automation | new model, every action twice | `multiView` + one leaf kind | daemon schema, spec, every client |

Strongest objection to each rejected design:

- S: the column has one owner workspace at a time, so "persists across switches" means moving
  it on every switch: daemon writes, journal churn, undo pollution, agents and the CLI seeing
  panes change workspace under them, and a race with any automation running in that column.
- N: a container that has tabs, panes, splits and columns but is not a workspace is a workspace
  under another name; every action, drop, focus and persistence rule would need a second path.
- T: the most general, but it has no edges, so "toggle the bottom dock", Floating, and a dock
  that hides without reflowing the stage do not exist. T stays available as `multiView`, and the
  stage may itself hold a `multiView` set (F contains T at the center).
- D: windows are frontend-local (cmux-tui-contract 2.6). A dock is window chrome, like the
  sidebar width; a phone or a second Mac attached to the same daemon must not grow docks.

## Model (F)

Per window, client view state in the personal window-state projection (`WindowRecord`,
schema unchanged: an optional field older builds ignore):

```
WindowRecord.docks: [WindowDock]?        // nil or empty: no frame
WindowDock {
  edge: left | right | top | bottom,
  workspace_key: WorkspaceKey,           // the docked workspace (listed by this window)
  mode: docked | floating,
  extent_permille: 100..=900,            // width (left/right) or height (top/bottom) of the frame
  hidden: bool                           // Toggle: kept, not drawn
}
WindowRecord.dock_orientation: column_major | row_major   // nil: column_major
WindowRecord.stage_key: WorkspaceKey?    // the stage's workspace while a dock has focus
```

cmux-tui uses the same record shape for its client view (one frame per TUI client), stored in its
own frontend projection, so a dock reads the same in both frontends.

Invariants:

| Id | Invariant |
| --- | --- |
| W1 | At most one dock per edge. Docking a workspace on an occupied edge replaces the old one (it goes back to the sidebar, not closed). |
| W2 | A workspace is in at most one place of one window: one dock, or the stage. Docking the stage's workspace moves the stage to the most recently shown other workspace (a new one when there is none). |
| W3 | A docked workspace is listed by its window (`workspace_keys`), so the sidebar shows it, marked with its edge; closing it or moving it to another window removes its dock in the same turn. |
| W4 | Selecting a docked workspace (sidebar, palette, CLI `workspace select`) focuses it in its dock and never moves it to the stage; a hidden dock shows again. |
| W5 | The stage shows the last selected workspace that is not docked (`stage_key` while a dock holds focus). |
| W6 | Extents are permille of the frame; each client clamps to its own maximum share: side docks at most 1/2 each (2/5 with both), bands at most 1/2 (1/3 with both), never below one pane's minimum. The record never stores points. |
| W7 | Orientation changes only corner ownership and dock lengths, never membership, order or extents (layout-model.md E7, one level up). |
| W8 | A hidden or Floating dock never resizes the stage: hiding, showing or floating a dock does no layout in the stage workspace (no terminal reflow). |

## Geometry (client, pure: `WindowFrameGeometry`)

- G1. Placement order follows orientation. Column-major: left and right docks take the full
  height first; top and bottom docks span between their inner edges. Row-major: top and bottom
  take the full width first; side docks span between them. Same rule as layout-model.md F1.
- G2. Docked: the stage ends one gap from the dock's inner edge. Floating: the stage keeps the
  full frame and the dock floats over its edge, inset one gap from the window edge, above every
  stage pane (V1). Hidden: not placed.
- G3. Clamping per W6, then rounding to whole points (`integral`), so a resize never leaves a
  half-pixel seam.
- G4. Hit testing: a click or drop inside a dock's frame belongs to the docked workspace; the
  stage under a Floating dock takes nothing there (dock-column.md D2, one level up).

## View

- V1. Each on-screen workspace is its own `WorkspaceContentController` view in the window's
  content host (the mechanism `multiView` uses): the focused one is `content`, the others are
  parked-but-drawn companions. A switch swaps the stage view only; the docks' views are not
  touched (no layout, no surface work).
- V2. Floating docks draw a Liquid Glass rim and shadow (`OverlaySurfaceView`, opaque under
  Reduce Transparency) and sit above the stage in z-order.
- V3. Hiding or showing a dock goes through the Motion gate (`Motion.panes`), and works with no
  animation (W8 means only the dock's own view moves).
- V4. Top pages (Home, Settings pages) fill the content area as today; the frame returns when a
  workspace shows (default picked for the prototype: Home already has its own dock).

## Focus

- K1. A press in a docked workspace focuses it first (`focusOnScreenWorkspace`, today's
  `multiView` path), so focus, titlebar and actions follow the workspace you type in.
- K2. Cmd-Opt-arrows stay inside the focused workspace in the prototype; crossing from the
  stage's edge pane into the dock is listed under "Next".
- K3. Automation never moves focus: CLI/MCP dock actions change the frame without focusing
  unless they say `focus: true` (socket focus policy).

## Actions (palette, CLI, MCP; no default shortcuts)

| Action id | Title | CLI | Effect |
| --- | --- | --- | --- |
| `workspace.dockLeft` / `Right` / `Top` / `Bottom` | Dock Workspace Left/Right/Top/Bottom | `workspace dock-left` … | the target workspace (default: focused) docks on that edge of its window (W1, W2) |
| `workspace.undock` | Undock Workspace | `workspace undock` | the docked workspace becomes the stage's workspace |
| `window.toggleDockLeft` / `Right` / `Top` / `Bottom` | Toggle Left/Right/Top/Bottom Dock | `window toggle-dock-left` … | shows/hides that dock; with no dock there, docks a new workspace (same directory) on that edge: off by default, toggled per edge |
| `workspace.toggleDockFloating` | Float Docked Workspace | `workspace toggle-dock-floating` | Docked <-> Floating for the target's dock |
| `window.toggleDockOrientation` | Toggle Dock Corners | `window toggle-dock-orientation` | column-major <-> row-major (W7) |

MCP follows the CLI (`action-surfaces.json`). Every action is disabled with a reason while
`window.dockedWorkspaces` is off. Context menus: the workspace row menu (Move folder) holds Dock
Left/Right/Top/Bottom and Undock.

## Drag and drop

- DD1. Tabs drag into and out of a docked workspace's panes exactly as between any two on-screen
  workspaces (`content(atScreen:)` resolves the dock under the pointer; the move is the daemon's
  cross-workspace `move-tab`).
- DD2. Next: a sidebar row dropped on a window edge band docks that workspace there; a tab
  dropped on the band docks a new workspace holding it.

## Persistence

`docks`, `dock_orientation` and `stage_key` save with the window record on settle (same CAS path
as the sidebar width). A relaunch mounts each docked workspace as a parked-but-drawn companion. A
record whose docked workspace is gone drops that dock (W3); a record from a build without docks
has none. Hibernation counts docked workspaces as shown (they are on screen) unless hidden.

## Clashes checked

- Right sidebar (a501): outside the content host, unchanged; docks are inside the main pane card.
- Home's pinned dock: a top page; V4 keeps them apart.
- Docked columns (dock-column.md): inside a workspace; a docked workspace may have its own docked
  columns, which dock to its frame rect, not the window.
- Pane tab-bar placement (a757): per pane; unaffected.
- `multiView`: the stage may hold a `multiView` set; docks are carved first.

## Prototypes (Debug Settings > Window, `window.dockedWorkspaces`)

1. **Docked edges**: Dock Workspace Left/Right/Top/Bottom take space; the stage switches with the sidebar.
2. **Floating drawer**: a dock in Floating mode floats over the stage; Toggle hides/shows it with
   no stage reflow (W8), like a per-window drop-down terminal.
3. **Row-major corners**: the same docks with top/bottom owning the corners.

cmux-tui: the same frame in the TUI client (docks around the active workspace's screen,
persisted per client), with the same action names in its menu and keymap.

## Next (after the prototype)

Edge drop bands (DD2), focus crossing (K2), a sidebar "Docked" section, resize handles on dock
inner edges (today extent changes through `extent` arguments and cmux.json), and docks around top
pages if people want them.
