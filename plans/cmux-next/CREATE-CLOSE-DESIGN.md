# Create and close at any session size (a336)

User (2026-10-20): "Making screens and closing screens is very laggy when I
have a ton of workspaces open ... fix it from first principles ... a
thousand times faster." Data and wire changes are approved.

Goal: creating or closing any object (workspace, workspace group, screen,
pane/split, terminal/browser/Markdown/Monaco/Files/agent tab, window,
Chief/subagent workspace) costs O(size of what changed), never O(session).
At 1000 workspaces an op costs what it costs at 10.

## 1. What an op costs today

One create or close crosses three stages. Each has work that grows with
the session (W workspaces, T tabs in total):

| Stage | Work per op today | Grows with |
| --- | --- | --- |
| Daemon commit | full projection on every tab/pane/screen close: reads every stored screen/pane/tab/terminal, rebuilds every index, restates every row, one SQLite `SELECT` per restated row (`prune_unchanged_resource_changes`) | T |
| Daemon commit | `state.clone()` of the whole tree for the close plan; `rebuild_split_screen_index` | T |
| Daemon commit | legacy workspace create/close: registry projection of all workspaces, N `UpsertWorkspace`, full topology read, `registry.snapshot()` for one revision number | W |
| Daemon commit | `tree_decorations()` before each op: notifications and git HEAD for every surface | T |
| Daemon events | delta payloads (`tree_entity_json`) built by serializing the whole tree and searching it | T |
| Wire | every topology op except pane create/split also emits a bare `tree-changed`; a selection move emits `tree-changed` to delta clients | - |
| App | `tree-changed` = full resync: `list-workspaces` (whole tree encoded by the daemon, decoded by the app), reconcile every workspace, `rebuildIndex()`, sidebar recompute | T |
| App | `personal-changed` (every Cmd+N pins the new workspace to its room) = full resync | T |
| App | after any list change: `reconcileMembership` sorts every window's list, sidebar section rebuild per window, window-record save | W per window |

The sum is several full passes over the session per op, on both sides of
the socket. The measured table is in section 5.

## 2. Target shape

1. **Daemon commit is O(changed).** Every commit projects only the
   workspaces it touched (the scoped projection creates already use,
   nx-scale W2c). Workspace order is one row (`SetWorkspaceOrder`), not N
   upserts. No whole-state clone; the close plan edits a copy of the
   touched workspace's subtree only.
2. **Events are deltas, complete.** Each op emits deltas that fully
   describe it: `*-added` / `*-closed` / `*-changed`, plus a new
   `selection-changed` delta (workspace, screen, pane, active tab) instead
   of a selection resync. A delta's payload is built from the touched
   entity, not from a serialized tree.
3. **No redundant resync signal.** A client that declares
   `tree-delta-complete-v1` never gets `tree-changed` for an op whose
   deltas were sent. Old clients keep getting it (versioned by capability,
   no break). `tree-changed` stays only for changes deltas cannot express
   (rare), and `overflow`.
4. **App applies a delta in O(1) on the same frame.** Optimistic insert
   or remove at the action (Cmd+N, Cmd+T, Cmd+W, split, close screen),
   reconciled by the echo's transaction id. Membership/sidebar passes
   become incremental: insert or remove one row id, no full re-sort.
5. **Persistence is async and incremental.** Journal writes stay in the
   commit (they are O(changed) once projection is scoped); window records
   and sidebar snapshots save the changed entries off main.

## 3. Wire changes (versioned)

| Change | Old client | New client (`tree-delta-complete-v1`) |
| --- | --- | --- |
| bare `tree-changed` after a delta-covered op | sent (unchanged) | not sent |
| selection move (focus workspace/screen/pane) | `tree-changed` | `selection-changed` `{workspace, screen, pane, tab}` |
| `personal-changed` | refetch `list-personal` and tree | refetch `list-personal` only (personal state is not the tree) |

### C2 prerequisites (found 2026-10-20; the daemon may not claim
`tree-delta-complete-v1` until each holds)

Today the trailing `tree-changed` hides these delta gaps:

| Gap | Where | Fix |
| --- | --- | --- |
| ScreenCreate in an existing workspace sends no delta at all | `effect_add_screen` (`mux/resource_topology/screen_create.rs`) | emit `screen-added` with the screen entity |
| Hosted terminal bind (every real daemon) sends a bare `TreeChanged`, no delta, for create-terminal-in-workspace and WorkspaceCreate's first tab | `create_terminal_in_workspace_impl` hosted branch (`mux/terminal_create.rs` ~291) | emit `tab-added` / `screen-added` as the non-hosted branch does |
| Pane `active_tab` changes are not in deltas; the app's `PaneModel.defaultTabIndex` and `focusedAt` are set only from snapshots | `tree_edit.rs` `remove_surface`; app `PaneModel.insertTab/removeTab` | carry `active_tab` (and `focused_at`) in `tab-added` / `tab-closed` / `pane-closed`; app applies them |
| Activated new tab and new active workspace send `TreeSelectionChanged` = resync | `event_emit.rs` `emit_tree_delta(_, true)` | `selection-changed {workspace, screen, pane, tab, active_tab}` for capable clients |

Capability plumbing: Rust const next to `SHARED_SIZING_CAPABILITY`, the
`set_info` allowlist (`client_registry.rs`), `advertised_capabilities`
(`capabilities.rs`), checked once in `subscribe_command`; Swift
`DaemonCapabilities.treeDeltaComplete` in `optional`. The trailing
`TreeChanged` stays for every other client (TUI, coarse subscribers).

## 4. Guards

- Daemon (Rust, `cmux-tui-core`):
  - `closing_inside_a_workspace_restates_no_resource_of_another_workspace`:
    tab, browser, pane and screen close read no full topology and restate
    nothing of another workspace (red 08c187b5da3, green 4365308449).
  - `create_close_cost_per_kind_at_scale`: the per-kind table at
    10/100/500/1000 workspaces, written to
    `.build/artifacts/create-close-bench.txt`.
- App (Swift, `CmuxNextDaemonTests`): a store fed N workspaces applies a
  create/close delta batch with zero resyncs and a work count independent
  of N.

## 5. Numbers

Filled in from the fleet runs (cmux-ci, Mac minis; debug build, cross-check
off as in release). See the report table in the a336 report.

## 6. Order of work

1. C1: scoped projection for tab/pane/screen close (landed first).
2. C2: `tree-delta-complete-v1` + `selection-changed`: no resync per op.
3. C3: app `personal-changed` refetches personal state only.
4. C4: workspace create/close registry path: order as one row.
5. C5: delta payloads from the entity, not the serialized tree.
6. C6: app membership/sidebar passes incremental.

Coordinate: a168 (tab switch), a301 (group fold), a268 (tab-write lag,
journal under registry lock), a305/a323 (CPU), a211/a121 (close/split
animation), a315 (Cmd-T self-close).
