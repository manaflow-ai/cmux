# Layout invariants (tab conservation)

Dogfood bug (2026-10-01): "dragging tab and dropping into its own pane has a bug where the tab/terminal pane just entirely disappears." The daemon kept every tab and terminal. The app's source strip hid the dragged tab for the drag and showed it again only when the model removed it, which a move into its own strip never does. This document names the bug class, its invariants, the operations, and the checks that keep the class out.

## Bug class

A tab, pane or terminal that the daemon holds is lost, duplicated or hidden by a layout operation (move, split, drop, reorder, tear-off, close) or by the app's projection of the daemon tree.

## Invariants

| Id | Invariant | Where it holds |
| --- | --- | --- |
| I1 | Tab conservation: a move, split, drop, reorder, column, tear-off or tab-group move never changes the set of tabs and their terminals. Only an explicit close removes a tab. The one op that adds a tab is a split with respawn, which names the created tab explicitly (a never-used id); conservation counts it as created, not as moved. | daemon tree; `LayoutModel` |
| I2 | Every tab is in exactly one pane. | daemon tree; `LayoutModel`; `DaemonStore` |
| I3 | Every pane has at least one tab, and every workspace at least one pane, or it is removed in the same transaction. | daemon tree; `LayoutModel` |
| I4 | A drop on the tab's own place (same pane and final index, same group; its pane's center when it is the last or only tab, where the center keeps the tab's group; a split of its own pane when it is the only tab, unless the daemon has `tab-split-respawn-v1`) is no operation and shows no drop highlight. Nothing is sent. The own place is read from the live strip at drop time. | `TabDragResolver`, `TabDragSession.liveContext` |
| P1 | Projection: after the deltas of a transaction are applied, the store equals the daemon tree for that transaction (`tab-changed` naming another pane moves the tab; an unknown pane resyncs). | `DaemonStore` |
| DP1 | Presentation: once no drag, landing flight or commit is in flight, every tab strip shows exactly its pane's tabs. Every drag ends its presentation exactly once (cancel, rejection, landed, connection lost). | app (`TabDragLifecycle.release`, input monitor) |

## Operations

Every drag ends in exactly one `TabDragOutcome` (the app's typed layout op), from one pure, total function, `TabDragResolver.outcome(for:insideWindow:screenPoint:context:)`. Each outcome is one daemon command (tab-drag-v1) or none:

| Outcome | Daemon command | Notes |
| --- | --- | --- |
| `.strip(strip, index, group)` | `move-tab` | own place resolves to `.cancel` (I4) |
| `.newSplit(pane, edge)` | `move-tab-to-split` | for the own pane's only tab: with `tab-split-respawn-v1`, `respawn` (see below); without it, refused (I4) |
| `.newColumn(screen, after)` | `move-tab-to-column` | |
| `.newWorkspace(group, index)` | `move-tab-to-new-workspace` | |
| `.workspace(id)` | `move-tab-to-workspace` | refused for the own workspace |
| `.tearOff(point)` | `move-tab-to-new-workspace` plus a new window | |
| `.moveWindow`, `.moveWorkspaceToNewWindow`, `.moveWorkspace` | none (frontend-local) | tabs do not move |
| `.cancel` | none | the tab springs back |

Split with respawn (user requirement 2026-10-02): a pane's only tab dropped on its own pane's edge splits that pane. The dragged tab moves into the new pane, and the old pane gets a fresh tab of the same kind: a new terminal in the dragged terminal's cwd, a new browser tab on the new tab page with the dragged tab's engine and profile. Only the kind is copied, never the URL, scrollback or session. It is one typed op, `MoveTabToSplit { respawn: Some(NewTab) }`, which the reducer validates as a whole (the moved tab plus the created one, I1-I3) before the daemon changes anything. The daemon then creates the fresh tab first, so the pane is never empty, and commits the split; if the split fails it closes the fresh tab again. The app sends it only when the daemon advertises `tab-split-respawn-v1` and the dragged tab is the only daemon tab of a respawnable kind (`TabDragContext.respawnsOnSplit`). Focus follows the moved tab. Agent (ACP) tabs are not daemon tabs and are not respawned yet.

A landed commit settles only once the store holds its result: `DaemonService.whenApplied` waits for the transaction's echo, the write barrier (every event the daemon emitted before the reply; bounds a command that changed nothing), or a snapshot (only for a waiter without a barrier: a resync that started before the reply can predate the move). Waiters run after a whole event batch, never inside it, and all of them run when the connection is lost. Then `TabDragLifecycle.release` pushes the store's tabs into the source strip and ends the presentation, so a tab that left never shows back for a moment.

Ownership note: the session's `commitsInFlight` (transactions sent and not yet settled) is drag gesture state that only gates DP1; it holds no copy of layout state.

## Checks

| Check | What | Run |
| --- | --- | --- |
| Swift property test | `TabDropPropertyTests`: 20000 seeded random layouts (1-3 workspaces, 1-3 panes, 1-3 tabs), dragged tabs and drop targets of every kind; the outcome applied to `LayoutModel` keeps I1-I3, never names a rejected target, never moves a tab to its own place. | `swift test -j 4 --filter TabDropPropertyTests` in `Packages/macOS/CmuxNext` |
| Swift unit tests | `TabDropConservationTests` (I4, release), `TransactionAppliedTests` (settle waits), `TabMoveDeltaTests` (P1) | `swift test -j 4 --filter 'TabDrop|TransactionApplied|TabMoveDelta'` |
| Swift property test (projection) | `IntentLogPropertyTests`: 2000 seeds x 80 steps of local move intents, owner serve/reject, other clients' moves, closes, opens and pane closes, batches with repeated deltas and tree-changed, stale snapshots and reconnects; checks I1 on the visible state, visible = confirmed + pending intents in order, each intent settled once and not before its outcome reached the store, and convergence (invariant 4). `IntentLogTests` pin the single cases | `swift test -j 4 --filter IntentLog` |
| Runtime (debug builds) | M1 in `debug.desync`: a mirror write outside daemon apply, the intent overlay and the legacy patches, or an overlay that changes the tab set (`DaemonStore.mirrorViolations`) | tagged build, `debug.desync {"check": true}` |
| Runtime | DP1 in `debug.desync {"check": true}` and the input monitor's desync reports and journal | tagged build, `CMUX_TAG=<tag> scripts/cmux-debug-cli.sh rpc debug.desync '{"check":true}'` |
| Rust reducer, daemon validation, proptest | pure crate `cmux-tui/crates/cmux-layout-reducer` (`apply(state, op) -> Result<(state, events), Reject>`); the daemon runs it on a copy before a tab-moving op and rejects with `layout-conservation-violation`; proptest I1-I5 (20000 reducer cases, 5000 daemon sequences of up to 30 ops). Not landed yet: branch `feat-cmux-next-layout-proptest` (00c53b4431d) waits for a green hosted run (the base is red). | `PROPTEST_CASES=20000 cargo test -p cmux-layout-reducer` on a Blacksmith Testbox |
| Model checking (respawn) | `TabLayout_respawn.cfg`: `RESPAWN = TRUE`, the own-pane split of the only tab is the op `SplitRespawn`, which creates one fresh tab with a never-used id; I1 counts created tabs. Results in `formal/README.md`. | `plans/cmux-next/formal/run-tlc.sh respawn` |
| Model checking | `plans/cmux-next/formal/TabLayout.tla` (2c4f2bb293e): owner, two clients with mirror + pending ops, request-settled barrier, reordered and duplicated batches, replay, reconnect, owner restart, drag presentation. TLC 1.7.4: fixed config 3,953,751 distinct states, depth 16, pass; live config (2 tabs, convergence) 573,873 states, pass; `BUGGY_DETACH` violates DP1 at depth 5 (the dogfood bug). | `plans/cmux-next/formal/run-tlc.sh` (about 33 min for the fixed config at load 300+) |
