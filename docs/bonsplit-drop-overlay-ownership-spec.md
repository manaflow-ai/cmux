# Bonsplit Drop-Overlay Ownership Spec (Living)

Status: Implemented on `task-white-rect-frame-cmd-d-ctrl-d`  
Last updated: 2026-02-25  
Scope: `vendor/bonsplit/Sources/Bonsplit/Internal/Views/PaneContainerView.swift`, `.../SplitViewController.swift`

## Problem
During tab drag/drop across panes, stale `dropUpdated`/missing `dropExited` callbacks can leave multiple panes visually highlighted at once (the "double blue" jank).

## Goal
Guarantee single-owner pane drop overlay rendering at all times during a drag session, without path-specific hacks.

## Invariants
1. Drop-overlay ownership is global, not per-pane local state.
2. At most one pane may render a pane-edge drop zone at a time.
3. A pane that does not own hover cannot re-activate itself from stale updates while another pane is active.
4. Drag end must always clear overlay ownership.
5. `dropExited` must not introduce a transient no-owner frame during active drag handoff.
6. External tab drops (another Bonsplit controller/window) must still resolve through payload fallback when local drag state is absent.

## Design
1. `SplitViewController` owns:
   - `activeDropPaneId`
   - `activeDropZone`
2. `PaneContainerView` derives visual zone from controller ownership:
   - render zone only when `pane.id == activeDropPaneId`
3. `UnifiedPaneDropDelegate` lifecycle:
   - `dropEntered` -> claims ownership (`setActiveDropTarget`)
   - `dropUpdated` -> only accepted when no owner or same owner
   - `dropExited` -> deferred clear (one actor turn) while drag is active
   - `performDrop`/drag-clear -> immediate clear
4. Existing per-pane lifecycle guard (`idle`/`hovering`) remains to ignore post-drop stale callbacks.
5. Deferred clear uses token invalidation:
   - any new `setActiveDropTarget` cancels pending clear
   - deferred clear applies only if owner+zone are unchanged when resumed
6. Cross-window drag compatibility:
   - if local `draggingTab`/`activeDragTab` is missing in `performDrop`, decode `tabTransfer` payload from drag pasteboard
   - forward external drop intent through `BonsplitController.onExternalTabDrop`
   - require same-process payload for `validateDrop` when local drag state is absent

## Observability
Added ownership logs:
- `pane.dropTarget oldPane=... oldZone=... newPane=... newZone=...`
- `pane.dropTarget.clear pane=... zone=... reason=...`
- `pane.dropTarget.clear.defer pane=... zone=... reason=dropExited`
- `pane.dropTarget.clear.deferSkip reason=tokenInvalidated|ownerChanged`
- `pane.dropUpdated.skip ... reason=other_active_pane owner=...`

## Acceptance Criteria
1. No simultaneous multi-pane drop highlight from a single drag stream.
2. No stale-pane re-highlight after pointer transitions to another pane.
3. Drop ownership always clears on drag end / performDrop.
4. No one-frame drop-overlay flash caused by `dropExited`/`dropEntered` handoff ordering.

## Regression Coverage
Bonsplit unit tests:
1. `testPaneDropOverlayVisibilityIsOwnedByActivePane`
2. `testPaneDropOverlayUpdatePolicyRejectsStaleNonOwnerUpdates`
3. `testDropTargetClearDefersForDropExitedDuringActiveDrag`
4. `testDropTargetDeferredClearCancelsWhenNewOwnerArrives`
5. `testTabTransferDataMarksCurrentProcessPayload`
6. `testTabTransferDataLegacyPayloadDefaultsToForeignProcess`
