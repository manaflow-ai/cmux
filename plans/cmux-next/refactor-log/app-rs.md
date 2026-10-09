# Refactor log: lane refactor-app-rs (cmux-tui/crates/cmux-tui/src/app.rs)

Append-only. One line per landing: date, SHA, what moved where, old -> new lines, gates and minutes.

## Landings

- 2026-10-09 0fd87fc2d979 refactor-app-rs: app.rs OrderedSession -> app/ordered_session.rs + app/ordered_session/{attach,mutations,sizing,commands}.rs; app.rs 47140 -> 45278; Testbox fmt/clippy/cmux-tui tests 2327/Windows check, 7 min.
- 2026-10-09 4dad88cac4f9 refactor-app-rs: app.rs session mutation, surface sync claims, remote attach executor -> app/{session_mutation,surface_sync,remote_attach}.rs; app.rs 45278 -> 44525; Testbox fmt/clippy/cmux-tui tests 2342/Windows check, 6 min.
- 2026-10-09 1343d3013612 refactor-app-rs: app.rs host input, app events, frontend journal, mux ingress -> app/{host_input,events,frontend_journal,mux_ingress}.rs; app.rs 44525 -> 43325.
- 2026-10-09 0d59d0e932a6 refactor-app-rs: app.rs layout types, menu model (MenuItem/MenuLevel), context menu, menu items, overlays -> app/{layout,menu,menu/context_menu,menu/items,overlays}.rs (MenuAction and keyboard_action_for_menu stay in app.rs: check-spec-inventory.py reads them there); app.rs 43325 -> 42019.
- 2026-10-09 889e21be5cbf refactor-app-rs: app.rs selection, pointer types, rendered pointer route, deferred input, graphics keys, viewport motion, pane-area projection -> app/{selection,pointer,pointer/route,pointer/deferred,graphics,viewport,pane_projection}.rs; app.rs 42019 -> 40528.
- 2026-10-09 916ef13b546c refactor-app-rs: app.rs status segments, status command capture, frame geometry, machine action worker + update pump, run entry, terminal guard -> app/{status_segments,status_command,frame_geometry,machine_worker,run,terminal_guard}.rs; app.rs 40528 -> 38125.
- 2026-10-09 93f663f26314 refactor-app-rs: impl App machine controller, machine UI, durable notices, sidebar rails -> app/{machine_controller,machine_ui,durable_notice,sidebar_rails}.rs (each its own impl App block); app.rs 38125 -> 36269.
- 2026-10-09 3f6c053b3ab7 refactor-app-rs: impl App event loop, presentation journaling, pointer frame commit, deferred replay, session apply -> app/{event_loop,presentation,pointer_frame,deferred_replay,session_apply}.rs; app.rs 36269 -> 34673.
- 2026-10-09 20a0ab2cf64e refactor-app-rs: impl App render, graphics emit, config/status upkeep, layout sync -> app/{render,graphics_emit,config_status,layout_sync}.rs; app.rs 34673 -> 33207.
- 2026-10-09 9ca387f63c6d refactor-app-rs: impl App input dispatch, input admission, surface focus, drag/resize, selection ops -> app/{input_dispatch,input_admission,surface_focus,drag_resize,selection_ops}.rs; app.rs 33207 -> 31500.
- 2026-10-09 e45682739c04 refactor-app-rs: impl App pane ops, managed machine/workspace ops, keyboard ingress, sidebar keys, machine/provider menus -> app/{pane_ops,managed_ops,keyboard,sidebar_keys,machine_menus}.rs; app.rs 31500 -> 29986.
- 2026-10-09 8575e3a010c9 refactor-app-rs: impl App prompt/dialog keys, action dispatch, browser ops, menu activation, focus navigation -> app/{prompt_keys,actions,browser_ops,menu_activate,focus_nav}.rs; app.rs 29986 -> 28415.
- 2026-10-09 (pending) refactor-app-rs: impl App key forwarding, hit testing + tab moves, mouse dispatch, PTY mouse, PTY writes -> app/{key_forward,tab_moves,mouse_dispatch,pty_mouse,pty_write}.rs; app.rs 28415 -> 26886.

## Target module map for cmux-tui/crates/cmux-tui/src/app.rs (2026-10-09)

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
