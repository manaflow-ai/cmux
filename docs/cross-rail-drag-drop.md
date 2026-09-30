# Cross-rail drag and drop

Status: design proposal for the workspace sidebar, main pane area, and Cloud
outline.

Dragging a live terminal from Cloud into a pane already works. Dragging a
workspace row from the left rail or a workspace row in Cloud does not, because
those rows currently carry organization payloads while pane drops require a
live Bonsplit transfer. The rails need one explicit projection contract.

## Transfer contract

Use `SurfaceResourceGroup` as the cross-rail payload. A group contains stable
resource ids, optional remote workspace placement ids, a display title, and a
source ownership token. It describes what to materialize; it does not transfer
the source workspace or its layout ownership.

Sources export these groups:

- A terminal, display, or browser leaf exports one placement.
- A workspace row exports all visible placements in its current tab order.
- A local workspace row exports its live surfaces in tab order.
- Machine, pool, section, port, and placeholder rows remain organization-only.

The source remains intact. A drop into a pane edge is therefore a projection
operation: it creates a new split and materializes the group's placements as
tabs in the new pane. Existing resource identity and remote workspace identity
are preserved, so a Cloud terminal is still attached to the same remote
workspace after it opens locally.

Dropping on the pane body keeps the existing single-tab replacement policy. A
group drop on the body is rejected unless the target explicitly advertises a
replace-group action; this prevents an accidental whole-pane replacement.

## Ownership and failures

The drag payload is capability-scoped to the source snapshot and expires when
the source disappears or its ownership token is revoked. The destination asks
the same `PaneTransferSourceResolver` used by live tab drags to resolve every
placement. A stale placement produces a visible partial-drop result listing
which resources were materialized and which disappeared; it never silently
falls back to the currently selected workspace.

Cloud outline drops keep their existing meaning: dropping onto another Cloud
row reorganizes machines/workspaces in the Cloud tree. A pane projection drop
must target the main pane edge, which avoids overloading the Cloud outline's
organization semantics.

## Implementation sequence

1. Add a versioned `SurfaceResourceGroup` drag type for local workspace rows;
   keep the existing reorder payload alongside it for sidebar reordering.
2. Make Cloud workspace rows export their existing `explicitDragGroup` through
   the same adapter used by terminal leaves.
3. Extend `PaneTransferSourceResolver` and `PaneTransferDropRouter` to accept a
   group and plan an edge split with ordered tabs.
4. Add ownership, stale-resource, partial-drop, and Cloud-open regression tests.
5. Add a small affordance in both rails showing “Open in split” while a group is
   over a pane edge; leave organization-only Cloud drops unchanged.

The first implementation should not merge layouts or move source workspaces.
Those operations need a separate explicit command because they can close or
reparent user-visible surfaces.
