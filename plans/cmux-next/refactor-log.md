# Refactor log

Append-only. One line per landing: date, SHA, lane, what moved where, old -> new lines, gate and minutes. Rules: plans/cmux-next/code-quality.md (R1-R10). Design notes for later phases go under "Phase 2 designs" at the end.

## Landings

- 2026-10-09 82fa0c39103c refactor-swift-ts: plans/cmux-next/code-quality.md added (docs only, no gate).
- 2026-10-09 7a6fbf50b615 refactor-swift-ts: webviews/src/App.tsx -> webviews/src/diff-viewer/{state,session,item-languages,item-navigation}.ts; App.tsx 3311 -> 2649; nx-remote web gate (bundles, check, budgets, 331 test files) 2 min.
- 2026-10-09 1fcf1f23a7a9..999d5b6a4d70 refactor-swift-ts: webviews/src/App.tsx -> webviews/src/diff-viewer/{Toolbar,FileHeader,FilesSidebar,Loading,WorkerRenderOptionsSync}.tsx, useSyncedRef.ts, useRenderDiff.ts, useDiffComments.ts, bootstrap.ts, page-effects.ts; App.tsx 2649 -> 697; nx-remote web gate (332 test files) 3.5 min.
- 2026-10-09 e6c55a6eab8d refactor-swift-ts: HomeStore.swift -> HomeStore+{Cache,Paging,Writing,Attachments,Uploads,Backoff,BlobCache,Events,Hooks}.swift (phase 1, extension split); file 1427 -> 285, type unchanged; cmux-ci CmuxHomeCoreTests 120/120, about 5 min.

## Lane refactor-app-rs: target module map for cmux-tui/crates/cmux-tui/src/app.rs (2026-10-09)

Map of app.rs at 2dba648cdbde (47,140 lines): lines 1-25138 are code, 25139-47140 are one `mod tests`
(22,000 lines). Code: 412 top-level items. The largest is `impl App` (lines 10225-24778, 14,554 lines,
479 methods), then `impl OrderedSession` (1,802 lines), `run_with_machine_updates_inner` (462),
`impl ContextMenu` (419), `impl MachineActionWorker` (282). Call graph: `run_with_machine_updates`
builds the `App` and drives `App::event_loop`; the event loop drains `AppEvent`s (session events,
host input, mux titles, PTY failures, machine updates) into `App::handle_inner` (1,001 lines: the
key/mouse/paste dispatcher), which fans out to the keyboard, mouse, menu, prompt, sidebar, machine
and action families; every session write goes through `OrderedSession` (one ordered worker queue);
`App::draw_terminal` / `sync_layout` project the tree into pane areas, graphics and the hit map that
the pointer families read back. Free types and helpers above `impl App` have no dependency on `App`.

Rules for the split: Rust allows `impl App` / `impl OrderedSession` blocks in any child module, so
each method family moves as its own `impl` block. Moved items get `pub(super)` (or
`pub(in crate::app)` one level deeper) only where another app module uses them; `pub` items keep
`pub` and are re-exported from app.rs as `pub(crate) use` when other crate modules import them.
Every new file stays under the godfile budget (1,000 lines / 60 fns; test files 1,500 / 120), so a
family over budget is split further. `App::handle_inner` (1,001 lines) stays in app.rs until a later
non-move step decomposes it. Child modules import explicitly (no `use super::*`).

Target modules under `src/app/` (one per responsibility; landing order = biggest independent first):

| module | responsibility | from app.rs (approx lines) |
| --- | --- | --- |
| `ordered_session.rs` + `ordered_session/{attach,mutations,sizing,commands}.rs` | the ordered session type and its impl | 2129-3990 |
| `session_mutation.rs` | `SessionMutationOutcome`, `SessionCompletion`, `PendingSessionMutation`, `MutationImpact` | 1354-1550 |
| `surface_attach.rs` | surface attach/resize claims, `perform_surface_attach`, remote attach executor, sidebar plugin sync claim | 1551-2128 |
| `events.rs` | `AppEvent`, `SessionEventSender`, cancellation, session/owner-reload workers | 299-566 |
| `host_input.rs` | `TerminalInput`, input classes, crossterm reader, host input ingress/runtime/producer | 113-298, 1094-1353 |
| `mux_ingress.rs` | mux event forwarding, `start_ordered_session`, mux title and PTY failure ingress | 743-1093 |
| `frontend_journal.rs` | frontend journal queue/worker, presentation snapshots, `App::journal_frontend_presentation` | 567-742, 4281-4317, App 12355-12487 |
| `layout_types.rs` | `Hit`, `FocusTarget`, `SidebarLayout`, `PaneArea`, rail placement types | 4126-4462 |
| `menu/model.rs`, `menu/context_menu.rs`, `menu/items.rs` | `MenuAction`, `MenuItem`, `MenuLevel`, `ContextMenu`, pane/size/client menu items | 4463-5535 |
| `menu/build.rs`, `menu/activate.rs` | App: `build_context_menu`, menu resources, `activate_menu`, `handle_menu_key` | App 23894-24428, 20509-20793, 19938-20000 |
| `overlays.rs` | `Prompt`, `PairingDialog`, connection dialog, `ShortcutHelp`, `OmnibarState`, `Toast` | 5536-5743 |
| `selection.rs`, `selection/app.rs` | selection types and App selection/clipboard methods | 5744-5872, App 17352-17892, 23449-23520 |
| `pointer/types.rs`, `pointer/route.rs` | drag/pointer-route/deferred-input types, `RenderedPointerFrame`, `DeferredInputQueue` | 5873-6692 |
| `pointer/replay.rs`, `pointer/admission.rs` | App: pointer frame commit, deferred replay, input admission/deferral | App 12488-13202, 16338-16961 |
| `mouse/{pty,left,hover,scroll,scrollbar,resize}.rs` | App mouse handlers | App 21227-24703 |
| `viewport.rs`, `pane_projection.rs` | viewport motion, pane-area projection, size leases | 6693-7275 |
| `graphics.rs`, `graphics/app.rs` | graphics identity/route/scene cache, App graphics emit/commit | 6054-6149, 7276-7327, App 13964-14386 |
| `status_segments.rs`, `status_command.rs` | status template/worker, status command capture | 7740-8388, App 14440-14624 |
| `sidebar_layout.rs` | rail widths, `sidebar_layout_for_state`, split minimum heights, pane parts | 7734-7754, 8389-8798 |
| `machine/worker.rs` | `MachineActionWorker`, `MachineUpdatePump`, machine session preparation | 8799-9354 |
| `machine/{connection,controller,durable_notice,managed,provider,rail}.rs` | App machine/provider/connection families | App 10250-10388, 11110-12324, 18134-18440, 18719-19283 |
| `run.rs`, `terminal_guard.rs` | `RunRequest`, `run_with_machine_updates`, panic reporting; terminal restore guard, host keyboard protocol | 9355-10164 |
| `sidebar/{rails,actions,keys,plugin}.rs` | App sidebar/rail focus, actions, sidebar keys, plugin sync | App 10389-10893, 14625-14666, 15061-15161, 19284-19409, 20875-20950, 23954-24091 |
| `event_loop.rs`, `session_apply.rs` | App event loop, host input drain, session completion/tree replacement | App 10894-11109, 13203-13708 |
| `render.rs`, `layout_sync.rs` | App draw/frame prep, viewport/layout sync, surface size reassert | App 13709-13963, 14678-15060, 17134-17337 |
| `keyboard.rs`, `prompt_keys.rs`, `actions.rs`, `browser.rs`, `pane_ops.rs` | App keyboard ingress/forwarding, prompt/dialog/omnibar keys, action dispatch, browser surface ops, pane/workspace creation | App 18521-18718, 20990-21226; 19410-20000, 20257-20345; 20001-20256, 20794-20989; 20345-20508, 24704-24778; 17893-18133, 18355-18520 |
| `app/tests/*.rs` | `mod tests`, split to mirror the modules above (last) | 25139-47140 |

## Phase 2 designs

### HomeStore owner split (proposed, needs hq-6d agreement)

Phase 1 only spread HomeStore over extension files; the type still owns about 30 stored properties and every concern. Phase 2 moves each concern's state into its own type that HomeStore owns, so HomeStore is a thin `@MainActor` coordinator of the mirror, the intent log and the connection. Each step is one landing with tests unchanged (the public HomeStore API stays) plus focused tests for the new type.

1. `HomeConversationHookRegistry` (struct): owns `hooks`; register, unregister, prune, live hooks for an intent. Smallest, no async. First, to prove the pattern.
2. `HomeClientViewCache` (`@MainActor` final class): owns `drafts`, `scrollAnchors`, `cacheWrite`, `restoringCache`, the clock-coalesced write and restore. HomeStore passes it a snapshot provider closure for mirror and log state.
3. `HomeTranscriptPager` (`@MainActor` final class): owns `viewers`, `openEpochs`, `loads`, `olderLoading`; open, close, loadOlder, the single transcript read. Calls back into the store only to apply pages to the mirror.
4. `HomeBlobCache` (`@MainActor` final class with `@concurrent` statics): owns `blobCacheDirectory`, `localFiles`, `pruneLoop`, `pruning`, `preparing`, `createdAt`; prepare, prune, local stand-ins, fetch. It reads the pinned hashes from a closure that the store supplies (pending sends and the session's attachments).
5. `HomeSendPipeline` (`@MainActor` final class): owns `uploads`, `sendQueue`, `turnWaiters`, `backoffTasks`, `backoffAttempts`, and `UploadJob`; the upload passes, the per-conversation send order, and backoff. It talks to the store through a narrow protocol (submit an intent, bump a row, report a refusal or an unanswered op). It is the largest and riskiest step, so it goes last, after 1-4 show the pattern.

Open question for hq-6d: whether `HomeSendPipeline` should instead move into the Rust conversation owner (lane rule "Swift paper cuts go to Rust"), which would make step 5 a deletion, not a move.

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
