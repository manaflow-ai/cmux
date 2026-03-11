# Workspace State Machine Redesign

This branch is for a full rework of the workspace, pane, terminal, and browser lifecycle.

## Current shape

Today the state is split across four layers:

- `TabManager` owns the window-level workspace list, selected workspace, workspace handoff, and background mounting.
- `Workspace` owns panel registries, split delegate callbacks, panel metadata, focus repair, geometry repair, and portal visibility repair.
- `vendor/bonsplit` owns the pane tree, pane focus, selected tab per pane, drag state, and zoom state.
- `TerminalSurface` and `BrowserPanel` each own a separate host-lease and portal lifecycle for their rendered AppKit/WebKit content.

`ContentView` adds another layer on top by deciding which workspaces stay mounted, which workspace is retiring, and when stale portal-hosted views must be hidden during handoff.

## Why it feels flaky

The same facts are derived in multiple places:

- Which workspace is active
- Which pane is focused
- Which panel is selected in a pane
- Which rendered host currently owns a terminal or web view
- Which panels are allowed to stay visible during handoff

That creates repair code instead of a stable transition model. The current tree has many “fix up next tick” paths:

- `TabManager` defers unfocus until handoff completes.
- `ContentView` manually keeps a retiring workspace mounted, then explicitly hides its portal views before unmount.
- `Workspace` runs `scheduleFocusReconcile()`, `scheduleTerminalGeometryReconcile()`, and portal visibility follow-up passes.
- `TerminalPanel` uses `viewReattachToken` to force representable updates after split churn.
- `BrowserPanel` preserves `shouldRenderWebView`, DevTools intent, and portal host ownership separately from pane selection.

Those loops are covering inconsistent ownership boundaries, not just slow rendering.

## Concrete duplication

- Workspace selection exists in `TabManager.selectedTabId`, `ContentView.mountedWorkspaceIds`, and `ContentView.retiringWorkspaceId`.
- Pane selection exists in Bonsplit state, but `Workspace.applyTabSelection(...)` re-applies and repairs it when delegate callbacks are skipped.
- Terminal visibility is derived from Bonsplit layout, then re-derived into terminal portal visibility.
- Browser visibility is derived from Bonsplit layout, then re-derived into browser portal visibility plus host ownership locks.
- Terminal and browser both implement host-lease arbitration with nearly identical geometry heuristics, but they are not the same state machine.

## Target architecture

We should move to one `@MainActor` state machine for the entire window.

Proposed domain tree:

- `WindowGraphState`
- `WorkspaceState`
- `PaneNode`
- `PanelState`
- `PanelRenderState`

`PanelState` should hold semantic state only:

- panel id
- panel kind
- persistent content state
- focus target
- loading/unread/pinned state

`PanelRenderState` should hold renderer attachment state only:

- `detached`
- `mounting(hostCandidate)`
- `attached(hostLease)`
- `suspended`
- `closing`

That render state should be shared by terminal and browser panels. The host-lease logic, stale-host rejection, visibility, z-priority, and detach semantics should live in one place.

## Bonsplit direction

Bonsplit should stop being the source of truth for pane selection and layout semantics.

Two acceptable paths:

1. Keep Bonsplit as a rendering/input shell, but drive it from the window graph and dispatch actions back into the reducer.
2. Replace Bonsplit state ownership entirely and keep only the parts worth preserving, mostly split layout presentation and drag/drop affordances.

Either way, the graph reducer has to own:

- selected workspace
- focused pane
- selected panel per pane
- zoomed pane
- detach/attach moves
- workspace mount and retire transitions

## Transition rules

We need explicit transitions for the cases that currently rely on repair code:

- workspace switch
- split create
- split close
- drag tab across panes
- move panel across workspaces/windows
- panel host replaced because SwiftUI kept an old host alive
- browser web view temporarily hidden but not destroyed
- terminal surface detached and reattached during split churn

The reducer should produce a single render plan for the frame:

- mounted workspaces
- visible panels
- focused panel
- renderer lease owner per panel
- side effects to apply after state commit

## First implementation slice

The first PR in the actual rewrite should not touch everything at once.

Start with this:

1. Introduce `WindowGraphState` plus reducer actions for workspace selection, pane selection, split create, split close, and panel move.
2. Mirror current UI into that graph without removing Bonsplit yet.
3. Replace `mountedWorkspaceIds`, `retiringWorkspaceId`, and deferred unfocus bookkeeping with reducer-driven handoff state.
4. Introduce a shared renderer host-lease type used by both terminal and browser panels.

If that slice is correct, the later UI rewrite gets much smaller because visibility, focus, and host ownership stop fighting each other.

## Non-goals for slice one

- No visual redesign yet
- No new shortcut behavior
- No browser feature work
- No terminal feature work

The first step is to delete repair loops by making ownership explicit.
