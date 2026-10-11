# God files and god types

`scripts/cmux-next/check-no-godfiles.sh` runs in the merge gate and in CI (cmux-next.yml, "God files"). It enforces:

- Swift (Packages/macOS/CmuxNext): 400 lines per file (tests 600), 3 top-level types per source file, and 1,000 lines per type, counting the declaration plus every extension of it in the same module.
- Rust (tracked `cmux-tui/**/*.rs`, without `vendor/` and the generated bindings): 1,000 lines and 60 functions per file (test files 1,500 and 120).

Entries over budget when the rule landed are in `scripts/cmux-next/godfile-baseline.tsv`. They may shrink and never grow; `--update-baseline` lowers numbers and drops entries that pass, and refuses to run while anything fails. New code goes into a new type or module, never into a grandfathered one. The gate is the periodic check: every push and PR runs it, and a run prints a NOTE for each entry that shrank so the baseline can follow.

## Swift status

Fixed on 2026-10-01 (each a behavior-preserving split, full package tests green):

| Type | Before | After | Split |
| --- | --- | --- | --- |
| ActionCatalog | 4,253 | 70 | 28 `ActionCatalogGroup` types, one per domain (`Catalog/<Domain>ActionCatalog.swift`) |
| CEFTab | 1,124 | 909 | DevTools placement into `CEFDevToolsController` |
| CEFRuntime | 1,138 | 968 | `CEFExtensionStores`, `CEFExtensionPrompts`, `CEFOrphanTabs` |
| SidebarListView | 1,101 | 936 | `SidebarInlineRename`, `SidebarRowViewPool`, `SidebarDragAutoscroll` |
| DaemonStore | 1,046 | under 1,000 | ownership step 4 (intent log agent): optimistic patches became typed intents, overlay in `IntentOverlay` |
| TerminalSurfaceView | 1,382 | 1,118 (still listed) | `TerminalCopyMode`, `TerminalClipboardRequests` |

Still in the baseline, with the planned owner split:

| Type | Lines | Planned split | Waits for |
| --- | --- | --- | --- |
| TabStripView | 2,138 | drag/reorder and phantom-drop state machine (`Press`, `Drag`, order override, placeholder, pending drop; +Drag, +Phantom, +DropTarget, Groups/+GroupDrag, +TitlebarDrag, about 630 lines) into a strip drag controller; per-tab springs and scroll (`TabMotion`, `advance`, +Layout) into a layout animator; pointer, hover and press state (+Pointer, +HoverCards) into its own owner. More than 1,100 lines must move. | a quiet window: the strip had 31 commits in 3 days (hover cards, strip scrollbar, groups); a move this size conflicts with every in-flight strip branch, so the coordinator should schedule it |
| DaemonConnection | 1,481 | transport stays; command families (tab groups, profiles, screens, bookmarks, placement, remote terminals) become client types over the connection, like `ScreenGroupStateClient` | #16174 and ownership step 4 settle the command surface |
| TerminalSurfaceView | 1,118 | key and IME input state (`markedText`, `keyTextAccumulator`, `sendKey`, `syncPreedit`) into a key input owner; grid sizing (`TerminalGridPolicy` use, `updateSurfaceSize`, `publish`) into a sizing owner; Ghostty mouse/cursor mappings into a value type | nothing |
| WindowManager | 1,163 | workspace membership of windows (`+Membership`) and incognito windows into their own owners | intent log agent removes WindowManager pending claims |

## Rust: mux.rs and server.rs

Do not split these while https://github.com/manaflow-ai/cmux/pull/16174 (branch feat-cmux-next-acpmux) is open. It adds the `state` module family to `cmux-tui-core` and moves v2 state code; its edits in these files are small (the mux module header, `from_workspace_registry`, `commit_resource_mutation_plan`, `STATE_RESOURCES_CAPABILITY`), but it rewrites `mux/tab_groups.rs`, `mux/screen_groups.rs` and `mux/presentation.rs`. Start after it merges, from its merged tree. Line ranges below are from feat-cmux-next at fdd8288c51f and will move.

Targets follow ownership.md: session host (PTYs, sizing, transcripts, input, presence) versus workspace store (layout document, workspaces, panes, tabs, groups). Today `Mux.state` is one `Mutex<State>` that holds both the terminal catalog and the layout tree (lock order: registry, then state). A real role split needs `State` divided, which #16174's `state` module begins. So:

- Phase 1 (mechanical, no behavior change): move code into child modules that add `impl Mux` blocks with `use super::*`, as the 12 existing `mux/*` modules do. Child modules see mux.rs private items; only moved types that siblings touch need `pub(super)` fields. Move each test group with its code into `<module>/tests.rs`. First extract the shared test helpers (about 40 in mux.rs, 24 in server.rs) into `mux/test_support.rs` and `server/test_support.rs`.
- Phase 2 (after phase 1, behind the `state` module): extract real types (a session-host struct, the workspace-store side of `State`).

### mux.rs (34,522 lines, 1,036 fns; tests are 20652-34522, about 40%)

Execution order, smallest risk first. Approximate size includes moved tests.

1. `mux/sync.rs`: `SignaledMutex` (116-262). Neither role. ~150.
2. `mux/deadline_fanout.rs`: `DeadlineFanoutPool`, `bounded_deadline_map` (641-870) and tests. Neither. ~250.
3. `mux/kitty_budget.rs`: image budget fns and types (324-500), render attachments and the budget worker (12616-13291). Session host. ~1,000.
4. `mux/cell_pixels.rs`: cell pixel types (871-900), retry queue (2265-2353), reconcile (13291-13830). Session host. ~800.
5. `mux/client_sizing.rs`: `ClientSizingState` (1918-2264), sizing and terminal views (8516-10110). Session host. ~2,300 (split again by sizing policy and resize if over budget).
6. `mux/notifications.rs`: notification types (1123-1212) and handling (10805-11568). Terminal unread is session host, placement is store; keep together in phase 1. ~900.
7. `mux/agents.rs`: agent types and roster restore (1213-1570), hook records (6548-7031), reports and `list_agents` (11568-12132). Session host. ~3,500 with tests (split hooks and roster).
8. `mux/journal.rs`: journal (6033-6548) and diagnostics/checkpoints (7031-7441). Session host. ~900.
9. `mux/terminal_host.rs`: host and template adoption (3518-4354), connection loss and reconnect (7654-7917), exit and reap (16595-16905), host record cleanup (18966-19410). Session host. ~2,200.
10. `mux/terminal_create.rs`: spawn types (1571-1738) and terminal, screen, tab and browser-tab creation (14228-15568). Mixed. ~1,600.
11. `mux/layout.rs`: focus, ratio, navigation, swap, zoom, undo, apply layout (16905-18183), layout restore (19837-20093). Workspace store. ~4,500 with tests (split undo and apply).
12. `mux/workspace_ops.rs`: close, rename, move, select (15568-16595, 18183-18723, 20173-20651). Workspace store. ~2,000.
13. Small: `mux/provider_authority.rs` (528-616, 4494-4594), `mux/daemon.rs` (shutdown and handoff, 12132-12314), `mux/plugins.rs` (12314-12616).
14. Last, touching #16174's paths: `mux/bootstrap.rs` (construction and open 2790-4354, `restore_resource_state` 19513-19837) and `mux/resource_commit.rs` (4780-5765).

### server.rs (28,193 lines, 813 fns; tests are 16584-28193)

1. `server/command.rs`: `enum Command` and its impl (992-2528). ~1,550 (split the parser from the enum if over budget).
2. `server/wire_json.rs`: tree JSON serializers and parse helpers (11198-12279), VT/render/browser wire messages (12279-12909). ~1,700.
3. `server/outbound.rs`: render graphic cache, byte budget, `RenderService`, `MessageWriter`, `BoundedOutbound`, websocket stream (3135-4972). ~1,850.
4. `server/client_registry.rs`: client transport, view leases, `ClientRegistry` (4973-6411). Session host (presence). ~1,450.
5. `server/listen.rs`: socket setup, `serve`, websocket auth, connection handling, kick (6412-7332). ~920.
6. `server/resource/{conn,waits,attach,event_stream,journal_stream}.rs`: the protocol/2 resource layer (7333-10861). ~3,500.
7. `server/attach.rs`: attach commit and rollback (12909-13217).
8. `server/commands/{clients,terminal,browser,workspace,layout,tabs,personal,sizing}.rs`: the arms of `handle_command_with_cancellation` (13242-16303, one match of ~3,060 lines). The match stays as a thin router; each family handler takes one `CommandCtx` (mux, client, writer, cancellation).

### Other Rust offenders

app.rs (47,141 lines, 1,576 fns) in the `cmux-tui` crate is the largest file. #16174 does not change it (it rewrites `cli/` and `main.rs`), so it can be split before #16174 merges; it was left out of this round to keep the ratchet change alone. The full list is the baseline file (115 Rust files).
