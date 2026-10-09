# Refactor log: lane refactor-mux-rs (cmux-tui/crates/cmux-tui-core/src/mux.rs)

Append-only. One line per landing: date, SHA, what moved where, old -> new lines, gates and minutes.

## Landings

- 2026-10-09 2d9638bc9d2a refactor-mux-rs: cmux-tui-core mux.rs inline tests -> mux/tests.rs + 30 files in mux/tests/; mux.rs 32824 -> 18991; Testbox fmt, clippy, cmux-tui-core lib 2657 passed, Windows check, about 6 min.
- 2026-10-09 384c6377a0eb refactor-mux-rs: mux.rs SignaledMutex -> mux/signaled_mutex.rs, deadline fanout pool -> mux/deadline_fanout.rs (leaf modules, no Mux dependency); mux.rs 18991 -> 18619; Testbox fmt, clippy, lib 2657 passed, Windows check, about 6 min.
- 2026-10-09 400208246643 refactor-mux-rs: mux.rs ProviderWorkspaceAuthority, status, update error, ProviderWorkspaceState, constant_time_eq, validate_mux_generation -> mux/provider_authority.rs (leaf, std + zeroize only); mux.rs 18577 (after W2) -> 18469; Testbox fmt, clippy, lib 2633 passed, Windows check, about 6 min.
- 2026-10-09 afdfc2a58ce5 refactor-mux-rs: mux.rs now_ms -> mux/time.rs, NotificationLevel -> mux/notification_level.rs (leaf, for the terminal_host_runtime crate split); mux.rs -> 18449; gated together with the previous line.
- 2026-10-09 7671cf088b31 refactor-mux-rs: mux.rs MuxEvent, GraphicsStatus, MachineUsage, TreeDelta(Kind) -> mux/events.rs; NotificationSource/Event, ResourceNotification, SurfaceNotification -> mux/notification_types.rs; mux.rs 18449 -> 18158; Testbox fmt, clippy, lib 2634 passed, Windows check, about 8 min.
- 2026-10-09 00dae5e213a3 refactor-mux-rs: mux.rs agent status types, roster host, report origin/target and hook helpers -> mux/agent_types.rs; mux.rs 18158 -> 17952; Testbox fmt, clippy, lib 2634 passed, Windows check, about 4 min.
- 2026-10-09 7c787c5b0454 refactor-mux-rs: mux.rs layout specs, Direction, ZoomMode/State, applied pane results, layout undo and viewport width errors -> mux/layout_types.rs (leaf); mux.rs -> 17831; Testbox fmt, clippy, lib 2634 passed, Windows check, about 6 min.
- 2026-10-09 b8cbccc1455c refactor-mux-rs: mux.rs constructors -> mux/construct.rs (474), startup terminal adoption -> mux/terminal_adoption.rs (950); mux.rs 17831 -> 16425; Testbox fmt, clippy, lib 2634 passed, Windows check, about 6 min.
- 2026-10-09 89b4f32da12e refactor-mux-rs: mux.rs workspace identity/authority -> mux/workspace_identity.rs (251), resource workspace mutations -> mux/resource_workspace.rs (826), resource effects -> mux/resource_effects.rs (332); mux.rs 16425 -> 15057; Testbox fmt, clippy, lib 2634 passed, Windows check, about 6 min.
- 2026-10-09 728664a53df5 refactor-mux-rs: mux.rs terminal exit waits -> mux/terminal_exit_wait.rs (258), journal plumbing -> mux/journal.rs (527), agent roster fold -> mux/agent_roster_fold.rs (411), journal maintenance -> mux/journal_maintenance.rs (329); mux.rs 15057 -> 13563; Testbox fmt, clippy, lib 2634 passed, Windows check, about 6 min.
- 2026-10-09 b22727e7b566 refactor-mux-rs: mux.rs frontend projections -> mux/frontend_projection.rs (195), emission/subscriptions -> mux/event_emit.rs (223), terminal host link -> mux/terminal_host_link.rs (268), pairing -> mux/pairing_requests.rs (135), surface spawn -> mux/surface_spawn.rs (480); mux.rs 13563 -> 12296; Testbox fmt, clippy, lib 2598 passed, Windows check, about 6 min.
- 2026-10-09 923656199bcf refactor-mux-rs: mux.rs client resizes -> mux/client_resize.rs (737), terminal sizing -> mux/terminal_sizing.rs (850), test hooks -> mux/test_hooks.rs (138), browser providers -> mux/browser_providers.rs (251); mux.rs 12267 -> 10318; Testbox fmt, clippy, lib 2602 passed, Windows check red only on the known W2 base file, about 6 min.
- 2026-10-09 847b2f8a67f9 refactor-mux-rs: mux.rs terminal close -> mux/terminal_close.rs (293), notifications -> mux/notifications.rs (649), launch snapshot + shell history -> mux/shell_history_feed.rs (88), agent reports -> mux/agent_reports.rs (473), lifecycle -> mux/lifecycle.rs (290); mux.rs 10318 -> 8555; Testbox fmt, clippy, lib 2602 passed, Windows check, about 6 min.
- 2026-10-09 23f1ece6fc0a refactor-mux-rs: mux.rs sidebar plugin -> mux/sidebar_plugin.rs (263), kitty budget -> mux/kitty_budget.rs (563), cell pixels -> mux/cell_pixels.rs (552), terminal defaults + resize_surface -> mux/terminal_defaults.rs (157); mux.rs 8555 -> 7044; Testbox fmt, clippy, lib 2602 passed, Windows check, about 6 min.
- 2026-10-09 78752b5d782f refactor-mux-rs: mux.rs creation families -> mux/{workspace_create (244), terminal_create (455), browser_create (238)}.rs, closes -> mux/tree_close.rs (527), rename -> mux/workspace_rename.rs (203); mux.rs 7044 -> 5407; Testbox fmt, clippy, lib 2602 passed, Windows check, about 6 min.
- 2026-10-09 7bf60bcf938a refactor-mux-rs: mux.rs layout resize, focus, layout undo, apply layout, terminal move, workspace move, startup restore -> mux/{layout_resize,focus,layout_undo,apply_layout,terminal_move,workspace_move,startup_restore}.rs; server.rs test site assertion accepts mux/; mux.rs 5407 -> 3617; Testbox fmt, clippy, lib 2602 passed, Windows check, about 6 min.
- 2026-10-09 73c6dbc03542 refactor-mux-rs: mux.rs free state helpers -> mux/{terminal_exit_snapshot,terminal_records,terminal_host_records,terminal_runtime_index,restore,tree_edit}.rs; mux.rs 3617 -> 1968; Testbox fmt, clippy, lib 2602 passed, Windows check, about 6 min.
- 2026-10-09 22a41b82bed8 refactor-mux-rs: mux.rs private state types -> mux/{kitty_budget_state,cell_pixel_state,client_sizing_state,terminal_exit_waiters}.rs; mux.rs 1970 -> 1301; Testbox fmt, clippy, lib 2603 passed, Windows check, about 6 min.
- 2026-10-09 a2e7e5efab61 refactor-mux-rs: resource_topology.rs part 1 -> mux/resource_topology/{topology_test_hooks,rename_focus,layout_ops,topology_operation}.rs; resource_topology.rs 6636 -> 5296; Testbox fmt, clippy, lib 2604 passed, Windows check, about 5 min.
- 2026-10-09 99d4c42175ea refactor-mux-rs: resource_topology.rs part 2 -> mux/resource_topology/{pane_tab_moves,tab_workspace_move,effectful_operation,close_effects}.rs; resource_topology.rs 5296 -> 3237; Testbox fmt, clippy, lib 2604 passed, Windows check, about 5 min.
- 2026-10-09 38f2e21b1006 refactor-mux-rs: resource_topology.rs part 3 -> mux/resource_topology/{creation_settlement,effect_execution}.rs; resource_topology.rs 3237 -> 1887; Testbox fmt, clippy, lib 2604 passed, Windows check, about 4 min.
- 2026-10-09 PENDING refactor-mux-rs: resource_topology.rs part 4 -> mux/resource_topology/{effect_fields,layout_document,topology_lookup,focus_plan,registry_layout,creation_recovery_tests}.rs; resource_topology.rs 1888 -> 363; tests 5 == 5; gate-run receipt (fmt, clippy, lib, Windows, godfile).

## Module map

Base 2dba648cdbde: mux.rs has 32,824 lines. Lines 1-2,744 are types and helpers, 2,745-17,215 are one
`impl Mux` block (469 methods), 17,216-18,978 are free functions over `State`, and 18,980-32,824 are the
inline `mod tests` (332 fns). Every target below is a child module of `mux`: moved methods stay in an
`impl Mux` block there, a private item becomes `pub(super)` (same reach as before), and `pub`/`pub(crate)`
items keep their visibility and their `crate::mux::` path through a re-export.

Order: tests first (largest, no runtime risk), then leaf infrastructure with narrow dependencies (crate-split
candidates), then the `impl Mux` families.

Tests (`mux/tests/<topic>.rs`, each under the 1,500-line test-file budget):
tab_workspace_move, signaled_mutex + diagnostics, resource_selectors, resource_restore, resource_effects,
restart, terminal_registry, cell_pixels, kitty_budget, deadline_fanout, terminal_views, agent_reports,
notifications, agent_hook_retry, agent_hook_fences, journal_roster, view_close_replay, layout_apply_focus,
viewport_columns, layout_undo, tabs_and_zellij, split_ratio, workspaces, terminal_exit_restart,
terminal_moves, workspace_materialize. Shared fixtures (test_mux, restore fixtures, selector fixtures) stay
in the parent test module until the last step makes it `mux/tests.rs`.

Leaf infrastructure (no `Mux` dependency; can move to a crate as a unit):
- signaled_mutex.rs: SignaledMutex + guard + hold telemetry.
- deadline_fanout.rs: DeadlineFanoutPool, bounded_deadline_map.
- provider_authority.rs: ProviderWorkspaceAuthority, status, update error, constant_time_eq.
- events.rs: MuxEvent, TreeDelta, TreeDeltaKind, MachineUsage, GraphicsStatus (re-exported).
- notification_types.rs: NotificationLevel/Source/Event, ResourceNotification, SurfaceNotification.
- agent_types.rs: AgentState, AgentSource, AgentRecord, hook-kind mapping helpers.
- layout_types.rs: LayoutSpec, LayoutLeafSpec, ZoomMode, Direction, AppliedLayout, ZoomState, undo errors.

`impl Mux` families (methods + their private helper types):
- construct.rs: new*, open_persistent*, from_workspace_registry, *_for_test constructors.
- terminal_adoption.rs: adopt_terminal_hosts, template adoption, schedule_terminal_adoption, restored bindings.
- restore.rs: restore_resource_state, restore_layout_node* (free fns over registry snapshots).
- workspace_identity.rs: workspace keys/names, provider authority install/authorize, lifecycle guards.
- resource_workspace.rs: selector helpers, commit_resource_mutation_plan, resource create/rename/move workspace.
- resource_effects.rs: effect prepare/commit/projection, input receipt HMAC, resource surface lookups.
- terminal_exit_wait.rs: exit state/output read, exit waiters (TerminalExitWaiters, detach tracker).
- journal.rs: journal events, session journal readers, producers, ingress append/finish.
- journal_hooks.rs: hook deliveries, checkpoints, segments, diagnostics reporter.
- agents.rs: agent hook records, roster fold/reconcile, report_agent, commit_agent_report, list_agents.
- frontend_projection.rs, events_emit.rs (subscribe/emit_*), terminal_host_link.rs (pending host,
  connection lost/reconnected, lifecycle transitions), pairing.rs.
- spawn.rs: spawn_surface_with, sidebar plugin and browser surface spawn.
- client_resize.rs: resize_surface_for_client*, rollback, size-client removal.
- terminal_sizing.rs: ClientSizingState, participants, size policies, sub-views, control_clients_json.
- browser_runtime.rs, terminal_close.rs (resolve/close_terminal*), notifications.rs (post/ack/clear, durable).
- lifecycle.rs: purge side tables, shutdown, daemon handoff, server lifecycle.
- sidebar_plugin.rs, kitty_budget.rs (budget worker + reservations), cell_pixels.rs (retry worker, fanout use).
- terminal_defaults.rs (default colors), create_workspace.rs, create_terminal.rs, create_browser.rs.
- workspace_close.rs, workspace_rename.rs, split_ratio.rs, viewport_width.rs, layout_undo_apply.rs,
  apply_layout.rs, terminal_move.rs, workspace_move.rs, focus.rs.
- tree_edit.rs: remove_surface, collapse_empty_pane, move_tab_in_state, close_*_delta, layout helpers.
- terminal_records.rs: commit_terminal_*, host record cleanup, insert/remove runtime checked.
