# Refactor log: cmux-tui-core server.rs (lane refactor-server-rs)

Append-only. One line per landing: date, SHA, what moved where, old -> new lines, gate and minutes.

## Landings

- 2026-10-09 e82ce2d3d2c8: ProtocolKeyInput, key/modifier wire enums, clear-history payload -> server/protocol_key.rs (339 lines). server.rs 27339 -> 27018. Gate 7 min (fmt, clippy -D warnings core+cmux-tui, Windows check, cmux-tui-core tests 2657 pass).
- 2026-10-09 46a0b68843c8: VtStateMessage, AttachWireShape, render-state/delta/graphics JSON, RenderClientState, browser-state/frame payloads -> server/render_messages.rs (571 lines). server.rs 27018 -> 26472. Gate 7 min (same gate set, 2657 tests pass).
- 2026-10-09 39af50031b94: JournalStreamFilter, journal regex filter, kind validation, sensitivity/class helpers -> server/journal_filter.rs (332 lines). server.rs 26472 -> 26157. Gate 8 min (fmt, clippy -D warnings core+cmux-tui, Windows check, spec inventory, cmux-tui-core tests).
- 2026-10-09 04ab8c42a39f: PendingServer, runtime socket directory checks, SocketStartLock, serve_paused, serve -> server/listen.rs (394 lines). server.rs 26157 -> 25790. Gate 8 min (fmt, clippy -D warnings core+cmux-tui, Windows check, spec inventory, cmux-tui-core tests).
- 2026-10-09 f14ea9a798c0: resource client and session selectors, snapshots, metadata, sizing, cell pixels, terminal/browser viewer resize and release -> server/resource_clients.rs (608 lines). server.rs 25790 -> 25218. Gate 8 min (fmt, clippy -D warnings core+cmux-tui, Windows check, spec inventory, cmux-tui-core tests).
- 2026-10-09 8399a57c4301: resource waits -> server/resource_waits.rs (268 lines); resource surface attach streams (terminal, browser, sidebar), outbound install, response writer -> server/resource_attach.rs (925 lines). server.rs 25216 -> 24116. Gate 7 min (fmt, clippy -D warnings core+cmux-tui, Windows check, spec inventory, cmux-tui-core tests).
- 2026-10-09 22a092931815: session event stream -> server/session_event_stream.rs (370 lines); journal extension requests and session journal stream -> server/journal_stream.rs (736 lines). server.rs 24116 -> 23084. Gate 8 min (fmt, clippy -D warnings core+cmux-tui, Windows check, spec inventory, cmux-tui-core tests).
- 2026-10-09 949be41381d8: outbound writer -> server/render_service.rs (505 lines), server/message_writer.rs (381), server/bounded_outbound.rs (711). server.rs 23084 -> 21604. Gate 8 min (fmt, clippy -D warnings core+cmux-tui, Windows check, spec inventory, cmux-tui-core tests).
- 2026-10-09 1b52d5bb65e8: client registry -> server/client_registry.rs (978 lines) + server/client_registry_views.rs (604, second impl block). server.rs 21604 -> 20137. Gate 8 min (fmt, clippy -D warnings core+cmux-tui, Windows check, spec inventory, cmux-tui-core tests).
- 2026-10-09 f4f28165249f: workspace command arms (19) + provider-authority helpers -> server/cmd_workspaces.rs (381 lines); check-spec-inventory.py follows arms into cmd_* handlers. server.rs 20137 -> 19961. Gate 8 min (fmt, clippy -D warnings core+cmux-tui, Windows check, spec inventory, cmux-tui-core tests).
- 2026-10-09 cf5a716a616f: tab and tab-group command arms (33) + resolve_pane_ref, surface_placement -> server/cmd_tabs.rs (551 lines). server.rs 19961 -> 19792. Gate 9 min (fmt, clippy -D warnings core+cmux-tui, Windows check, spec inventory, cmux-tui-core tests).

## Map: cmux-tui-core/src/server.rs (lane refactor-server-rs, base 2dba648cdbde, 27,370 lines)

Line ranges are at the base commit. Lines 1-15,916 are production code; lines 15,917-27,370 are the inline `mod tests` (11,450 lines). Godfile budget for every new file: 1,000 lines and 60 fns (test files 1,500 / 120).

Dispatch path: `handle_connection_frame` (10436) is the entry for one wire frame. It routes in this order: remote relay, pending handoff, resource lines (`origin_gate`), then the family modules that own their own command enum (`loopback_forward`, `agent_session_attach`, `apps`, `scripts`, `fs_wire`, each `try_handle`), then serde `Request{id, cmd: Command}` through `ConnectionSurfaceScheduler::dispatch` or `handle_request_with_cancellation` (10500), which special-cases async commands (`url_open`, `chief_inspect`, `cloud_conversations`, `VtState`) and then calls `handle_command_with_cancellation` (12618-15642, one 3,025-line match with 224 arms).

Production families and their target modules (each one landing, file-disjoint):

| lines | family | target module |
| --- | --- | --- |
| 87-201 | child mod declarations and re-exports | stays (server.rs becomes the module root) |
| 202-424 | capability and protocol-version constants (`pub`, used by clients) | `server/protocol_consts.rs`, re-exported |
| 427-500 | client focus id check, machine usage and listening-TCP JSON | `server/machine_json.rs` |
| 425, 502-827 | terminal key input wire shape (`ProtocolKeyInput`), clear-history payload | `server/protocol_key.rs` (landing 1) |
| 830-1016 | `Request`, receipt and provider requests, client identity, detach notices | `server/wire_request.rs` |
| 1017-2498 | `Command` enum (1,399 lines) and `impl Command` | stays: one serde enum cannot meet the 1,000-line budget by a move; splitting it into family sub-enums changes the wire parser (design task, not move-only) |
| 2499-2756 | tab/pane refs, batch close JSON, workspace group JSON, `Response`, delivery errors | `server/command_support.rs` |
| 2755-3062 | outbound limits, resource worker admission, surface-operation admission, connection surface state | `server/connection_scheduler.rs` (with 3888-4213) |
| 3063-3530 | render graphic base64 cache, budgeted JSON writer, `RenderService`, kitty replay JSON writers | `server/render_service.rs` |
| 3531-3887 | `OutboundStream`, `MessageSink`, `MessageWriter` | `server/message_writer.rs` |
| 3888-4213 | `ConnectionSurfaceScheduler` impl, dispatcher thread | `server/connection_scheduler.rs` |
| 4214-4897 | `BoundedOutbound`, queued sink, synchronized TCP/WebSocket stream, connection permits | `server/bounded_outbound.rs` |
| 4898-6376 | client records, view leases, resource streams/waits, `ClientRegistry` (impl is 1,161 lines) | `server/client_registry.rs` + `server/client_registry_resources.rs` (impl split in two blocks) |
| 6377-6760 | `PendingServer`, socket directories, `SocketStartLock`, `serve`/`serve_paused` | `server/listen.rs` |
| 6759-6941 | disconnect, kick, daemon shutdown after ack, detach own view / size participant | `server/disconnect.rs` |
| 6942-7290 | journal stream filter (regex, kinds, sensitivity) | `server/journal_filter.rs` |
| 7291-7574 | resource connection message routing and session shutdown | `server/resource_connection.rs` |
| 7575-7859 | resource waits (terminal wait, exit wait) | `server/resource_waits.rs` |
| 7860-8444 | resource client snapshot/metadata/sizing/viewer resize | `server/resource_clients.rs` |
| 8445-9308 | resource attach (terminal, browser, sidebar streams) | `server/resource_attach.rs` |
| 9309-9643 | session event stream | `server/session_event_stream.rs` |
| 9644-10435 | journal extension requests, session journal stream, stream cancel/end | `server/journal_stream.rs` |
| 10436-10709 | frame dispatch, request handling, vt-state response, auth helpers | stays (dispatch core) |
| 10710-10757, 10958-11455 | layout/pane/workspace/tree JSON views | `server/tree_json.rs` |
| 10756-10957 | `create_surface_with_receipt` | `server/surface_receipt.rs` |
| 11454-11690 | browser provider registration/JSON, notification/agent parsing, colors JSON | `server/provider_json.rs` |
| 11689-12239 | render and browser wire messages, `RenderClientState` | `server/render_messages.rs` |
| 12240-12617 | attach lifecycle (mark attached, commit, rollback, initial browser resize) | `server/attach.rs` |
| 12618-15642 | `handle_command_with_cancellation` | arms move by family into `server/cmd_*.rs` handlers (`cmd @ (Command::A{..} \| ...) => cmd_x::handle(...)`, the existing `url_open` pattern): sizing/views, workspaces, tabs and groups, terminals, profiles and sessions, frontend projection, notifications |
| 15643-15689 | list-workspaces reply, placed terminal result, build stamps | with the matching `cmd_*` family |
| 15690-15865 | `subscribed_event_json` | `server/event_json.rs` |
| 15917-27370 | inline unit tests | `server/tests/*.rs` by the same families, each at most 1,500 lines |

Dependency rule for the later crate split: each new module imports only what it uses (no `use super::*` in production modules), items are `pub(super)` unless a client crate already uses the `crate::server::` path, and `pub` items stay re-exported from server.rs so outside paths do not change.
