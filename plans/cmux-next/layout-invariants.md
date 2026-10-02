# Layout invariants (tab conservation)

Dogfood bug (2026-10-01): "dragging tab and dropping into its own pane has a bug where the tab/terminal pane just entirely disappears." The daemon kept every tab and terminal. The app's source strip hid the dragged tab for the drag and showed it again only when the model removed it, which a move into its own strip never does. This document names the bug class, its invariants, the operations, and the checks that keep the class out.

## Bug class

A tab, pane or terminal that the daemon holds is lost, duplicated or hidden by a layout operation (move, split, drop, reorder, tear-off, close) or by the app's projection of the daemon tree.

## Invariants

| Id | Invariant | Where it holds |
| --- | --- | --- |
| I1 | Tab conservation: a move, split, drop, reorder, column, tear-off or tab-group move never changes the set of tabs and their terminals. Only an explicit close removes a tab. | daemon tree; `LayoutModel` |
| I2 | Every tab is in exactly one pane. | daemon tree; `LayoutModel`; `DaemonStore` |
| I3 | Every pane has at least one tab, and every workspace at least one pane, or it is removed in the same transaction. | daemon tree; `LayoutModel` |
| I4 | A drop on the tab's own place (same pane and final index, same group; its pane's center when it is the last or only tab; a split of its own pane when it is the only tab) is no operation. Nothing is sent. | `TabDragResolver` |
| P1 | Projection: after the deltas of a transaction are applied, the store equals the daemon tree for that transaction (`tab-changed` naming another pane moves the tab; an unknown pane resyncs). | `DaemonStore` |
| C1 | Presentation: once no drag, landing flight or commit is in flight, every tab strip shows exactly its pane's tabs. Every drag ends its presentation exactly once (cancel, rejection, landed). | app (`TabDragLifecycle.release`, input monitor) |

## Operations

Every drag ends in exactly one `TabDragOutcome` (the app's typed layout op), from one pure, total function, `TabDragResolver.outcome(for:insideWindow:screenPoint:context:)`. Each outcome is one daemon command (tab-drag-v1) or none:

| Outcome | Daemon command | Notes |
| --- | --- | --- |
| `.strip(strip, index, group)` | `move-tab` | own place resolves to `.cancel` (I4) |
| `.newSplit(pane, edge)` | `move-tab-to-split` | refused for the own pane's only tab (I4) |
| `.newColumn(screen, after)` | `move-tab-to-column` | |
| `.newWorkspace(group, index)` | `move-tab-to-new-workspace` | |
| `.workspace(id)` | `move-tab-to-workspace` | refused for the own workspace |
| `.tearOff(point)` | `move-tab-to-new-workspace` plus a new window | |
| `.moveWindow`, `.moveWorkspaceToNewWindow`, `.moveWorkspace` | none (frontend-local) | tabs do not move |
| `.cancel` | none | the tab springs back |

A landed commit settles only once the store holds its result: `DaemonService.whenApplied` waits for the transaction's echo, the write barrier (every event the daemon emitted before the reply; bounds a command that changed nothing), or a snapshot. Then `TabDragLifecycle.release` ends the presentation.

## Checks

| Check | What | Run |
| --- | --- | --- |
| Swift property test | `TabDropPropertyTests`: 20000 seeded random layouts (1-3 workspaces, 1-3 panes, 1-3 tabs), dragged tabs and drop targets of every kind; the outcome applied to `LayoutModel` keeps I1-I3, never names a rejected target, never moves a tab to its own place. | `swift test -j 4 --filter TabDropPropertyTests` in `Packages/macOS/CmuxNext` |
| Swift unit tests | `TabDropConservationTests` (I4, release), `TransactionAppliedTests` (settle waits), `TabMoveDeltaTests` (P1) | `swift test -j 4 --filter 'TabDrop|TransactionApplied|TabMoveDelta'` |
| Runtime | C1 in `debug.desync {"check": true}` and the input monitor's desync reports and journal | tagged build, `CMUX_TAG=<tag> scripts/cmux-debug-cli.sh rpc debug.desync '{"check":true}'` |
| Rust property test and daemon validation | I1-I3 checked before a layout op commits; proptest over random op sequences | see `cmux-tui/crates/cmux-tui-core/src/mux/layout_invariants.rs` once landed |
| Model checking | TLA+ model of the daemon layout, two clients, reordered and duplicated deltas, optimistic projection and the drag presentation | `plans/cmux-next/formal/README.md` once landed |
