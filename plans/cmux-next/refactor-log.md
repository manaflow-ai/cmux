# Refactor log

Append-only. One line per landing: date, SHA, lane, what moved where, old -> new lines, gate and minutes. Rules: plans/cmux-next/code-quality.md (R1-R10). Design notes for later phases go under "Phase 2 designs" at the end.

## Landings

- 2026-10-09 82fa0c39103c refactor-swift-ts: plans/cmux-next/code-quality.md added (docs only, no gate).
- 2026-10-09 7a6fbf50b615 refactor-swift-ts: webviews/src/App.tsx -> webviews/src/diff-viewer/{state,session,item-languages,item-navigation}.ts; App.tsx 3311 -> 2649; nx-remote web gate (bundles, check, budgets, 331 test files) 2 min.
- 2026-10-09 1fcf1f23a7a9..999d5b6a4d70 refactor-swift-ts: webviews/src/App.tsx -> webviews/src/diff-viewer/{Toolbar,FileHeader,FilesSidebar,Loading,WorkerRenderOptionsSync}.tsx, useSyncedRef.ts, useRenderDiff.ts, useDiffComments.ts, bootstrap.ts, page-effects.ts; App.tsx 2649 -> 697; nx-remote web gate (332 test files) 3.5 min.
- 2026-10-09 e6c55a6eab8d refactor-swift-ts: HomeStore.swift -> HomeStore+{Cache,Paging,Writing,Attachments,Uploads,Backoff,BlobCache,Events,Hooks}.swift (phase 1, extension split); file 1427 -> 285, type unchanged; cmux-ci CmuxHomeCoreTests 120/120, about 5 min.
- 2026-10-09 2d9638bc9d2a refactor-mux-rs: cmux-tui-core mux.rs inline tests -> mux/tests.rs + 30 files in mux/tests/; mux.rs 32824 -> 18991; Testbox fmt, clippy, cmux-tui-core lib 2657 passed, Windows check, about 6 min.
- 2026-10-09 (this commit) refactor-mux-rs: mux.rs SignaledMutex -> mux/signaled_mutex.rs, deadline fanout pool -> mux/deadline_fanout.rs (leaf modules, no Mux dependency); mux.rs 18991 -> 18619; Testbox fmt, clippy, lib 2657 passed, Windows check, about 6 min.

- 2026-10-09 cdde5b4d3a34 refactor-swift-ts: MobileCoreRPCSession.swift -> MobileCoreRPCSession+{TearDown,Connect,ReadWrite,PendingRequests,CancelledWrites,ControlStreamRepair,TransportClose}.swift (phase 1); 1741 -> 430; cmux-ci CmuxMobileRPCTests 221/223 (2 named reds, bead filed), about 6 min.
- 2026-10-09 3a3629c3d9b6 refactor-swift-ts: MobilePairedMacStore.swift -> MobilePairedMacStore+{Migrations,Upsert,RouteAuthority}.swift (phase 1); 1616 -> 362; cmux-ci CmuxMobilePairedMacTests 45/45, about 5 min.

## Lane refactor-crate-split: cmux-tui-core domain crates (2026-10-09)

Goal: split `cmux-tui/crates/cmux-tui-core` (about 295k lines, 1 crate) into
domain crates. Each step moves one domain into its own crate under
`cmux-tui/crates/`; cmux-tui-core re-exports it at the old path
(`pub use <crate> as <module>;`) so no caller and no `crate::<module>::...`
path changes in the same step. mux.rs and server.rs belong to their own
refactor lanes; this lane never edits them.

### Module graph (feat-cmux-next 2dba648cdbde)

Edges are `crate::<module>` references (root re-exports resolved to their
module). "Closure" is the transitive set of crate-local modules a module needs.

- The crate is one strongly connected tangle: every module that reaches
  `mux` or `server` reaches all 73 others (resource -> request_origin ->
  state -> mux -> server -> ...). So only modules whose closure avoids
  mux/server can move as they are.
- Movable now (closure has no mux/server), by size: cloud_conversations
  3063 (no crate-local deps), fs_ops 2778 (none, unix), platform 2298
  (+windows_processes 451), unix_process_scope 1689 (none), terminal_backend
  1610 (platform, terminal_end, terminal_host_protocol),
  terminal_host_protocol 1311 (none), terminal_host 967
  (terminal_host_protocol), sizing_policy 776, process_resources 648
  (host_exe, windows_processes), image_paste* 1368 (unix), host_exe 489
  (platform), terminal_loss_log 386 + terminal_loss_cause 157 +
  process_identity 123, user_settings 301 (platform), pairing 300,
  terminal_end 270, stream_interrupt 262, remote_relay_state 226,
  conversation_drafts 181, pty_write 169, debug_spans 115, backoff 113,
  terminal_respawn_text 86, conversation_search 77, short_id 65,
  machine_name 35.
- The brief's first candidates all reach mux today through thin edges:
  - terminal_host_runtime (15.8k with its folder): server only for
    `encode/decode_terminal_host_clear_history`, surface only for
    `VT_REPLAY_MAX_BYTES`, plus shell_integration, terminal_metadata and
    program_status (which reach mux). Moving those 2 functions and 1 const
    down (to terminal_host_protocol) and the shell/metadata pieces it uses
    makes it movable.
  - browser (12k): `Weak<Mux>` and the `Surface` enum are threaded through
    the frame/navigation loops (emit_browser_status/dirty/failure, connect,
    open). Needs a small host seam (a trait the mux implements) before a
    move; that is a design step, not move-only, so it comes after the leaf
    crates.
  - surface (14.4k), workspace_registry (39.8k), apps (9.8k), scripts (0.6k),
    git_ops (6k): depend on Mux, resource_router and workspace_registry in
    both directions. They need seams (traits or id-only APIs) first.
  - diagnostics (0.7k): depends on journal_ingress (-> mux).

### Crate order

1. cmux-tui-cloud-conversations: cloud_conversations (3063). No deps.
2. cmux-tui-fs-ops: fs_ops (2778, unix). No deps.
3. cmux-tui-platform: platform, windows_processes, host_exe,
   process_identity, process_resources, unix_process_scope (about 5.7k).
   Prerequisite for 4 and 6 (15 modules use platform).
4. cmux-tui-terminal-host-protocol: terminal_host_protocol, terminal_end,
   terminal_host, terminal_loss_cause, terminal_loss_log, terminal_backend,
   pty_write (about 4.9k).
5. Small leaf utilities that 1-4 or later crates need (backoff,
   stream_interrupt, debug_spans, short_id, machine_name, sizing_policy) go
   with the first crate that needs them, or into cmux-tui-util if two do.
6. cmux-tui-terminal-host-runtime: terminal_host_runtime and its folder,
   after the thin edges above move down (about 16k).
7. cmux-tui-browser: browser, browser/*, browser_provider after the host
   seam (about 12.3k).
8. Later (need seams): surface, workspace_registry, apps + scripts, git_ops,
   journal_*.

godfile-baseline.tsv keys are file paths: moving a baselined file
(platform.rs, unix_process_scope.rs, terminal_host_runtime.rs, browser.rs)
changes its key, so that step also edits the baseline (WINDOW-LITE token).
cmux-tui/scripts/*.py hold 33 hard-coded cmux-tui-core source paths; each
step updates the ones it moves.

## Phase 2 designs

### HomeStore owner split (proposed, needs hq-6d agreement)

Phase 1 only spread HomeStore over extension files; the type still owns about 30 stored properties and every concern. Phase 2 moves each concern's state into its own type that HomeStore owns, so HomeStore is a thin `@MainActor` coordinator of the mirror, the intent log and the connection. Each step is one landing with tests unchanged (the public HomeStore API stays) plus focused tests for the new type.

1. `HomeConversationHookRegistry` (struct): owns `hooks`; register, unregister, prune, live hooks for an intent. Smallest, no async. First, to prove the pattern.
2. `HomeClientViewCache` (`@MainActor` final class): owns `drafts`, `scrollAnchors`, `cacheWrite`, `restoringCache`, the clock-coalesced write and restore. HomeStore passes it a snapshot provider closure for mirror and log state.
3. `HomeTranscriptPager` (`@MainActor` final class): owns `viewers`, `openEpochs`, `loads`, `olderLoading`; open, close, loadOlder, the single transcript read. Calls back into the store only to apply pages to the mirror.
4. `HomeBlobCache` (`@MainActor` final class with `@concurrent` statics): owns `blobCacheDirectory`, `localFiles`, `pruneLoop`, `pruning`, `preparing`, `createdAt`; prepare, prune, local stand-ins, fetch. It reads the pinned hashes from a closure that the store supplies (pending sends and the session's attachments).
5. `HomeSendPipeline` (`@MainActor` final class): owns `uploads`, `sendQueue`, `turnWaiters`, `backoffTasks`, `backoffAttempts`, and `UploadJob`; the upload passes, the per-conversation send order, and backoff. It talks to the store through a narrow protocol (submit an intent, bump a row, report a refusal or an unanswered op). It is the largest and riskiest step, so it goes last, after 1-4 show the pattern.

Decided (hq-6d, 2026-10-09): steps 1-4 stay in Swift as above. Step 5 moves to the Rust conversation owner instead, so the app, `cmux chief` and the JS runtime share one send queue and retry rule. Step 5 needs the CORE token and v2 upload ops; design it with hq-6d before any code. HomeSendPipeline is not built in Swift.

### Same rule for the other phase-1 splits

MobileCoreRPCSession (actor) and MobilePairedMacStore (actor) get the same treatment after their phase-1 landings: MobilePairedMacStore's schema migrator (open connection, run migrations, tableColumns, user_version) becomes a `MobilePairedMacSchema` value that owns the connection setup; MobileCoreRPCSession's control-stream repair state and cancelled-write resolution become owned helper types.

### mux.rs module map (lane refactor-mux-rs, 2026-10-09)


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
