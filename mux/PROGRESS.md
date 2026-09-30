# mux slice 1 progress

Loop state for slice 1 (DESIGN.md "Slice 1"). Read first, update last.

| #   | Step                                                                                                                                 | State |
| --- | ------------------------------------------------------------------------------------------------------------------------------------ | ----- |
| 1   | `cloud/worker`: Worker + ConversationDO + MuxDO + AccountDO, chat WebSocket protocol, runs under `cf dev`                            | todo  |
| 2   | Web `ChatSource` over the worker (REST + WebSocket), send and live receive                                                           | todo  |
| 3   | `packages/brain`: coderouter Responses client (gpt-6.1-sol, high, priority), mux replies in chat                                     | todo  |
| 4   | OptMem memory in `packages/brain` (log, tree, wake, recall, zoom, compaction policy) behind `MemoryStore`; DO SQLite store for tests | todo  |
| 5   | Memory host: git-backed memory service on a small `mux-*` Freestyle VM, `MemoryStore` client in `cloud/`                             | todo  |
| 6   | Code mode: one `run` tool in a Dynamic Worker with the typed `mux` API (`messages`, `memory`, `agents`)                              | todo  |
| 7   | `link/` (Rust): outbound WebSocket to the worker, drives acpmux (spawn, prompt, status, events)                                      | todo  |
| 8   | Stack Auth sign-in in web, JWT verification in the worker                                                                            | todo  |
| 9   | Staging deploy `mux-staging` (worker serves the web build), link pointed at staging                                                  | todo  |
| 10  | Live end-to-end: sign in, chat, mux spawns an acpmux agent on this Mac and reports back; handoff                                     | todo  |

## Log

- 2026-09-30: step 1 live under `cf dev` (port 8787). `cf dev` needs `cloudflare.config.ts` + `wrangler.config.ts` (experimental new config), not wrangler.jsonc. `bun cloud/worker/scripts/smoke.ts` passes. Dev identity: `?dev_user=` when `MUX_DEV_AUTH=1` (.dev.vars).
- 2026-09-30: step 3 live: mux answers through coderouter. Coderouter requires `stream: true`; with `store: false` the completed event has empty output, so items come from `response.output_item.done`. Failed turns retry 3 times with backoff, then the mux posts the error and drops the message. Kill stray `cf-wrangler.js dev` children before restarting `cf dev` (port 8787 conflict).
- 2026-09-30: step 2 live. Conversation state is an external store (useSyncExternalStore, socket per subscriber set, reconnect on drop). `vp dev` proxies /api to 8787; `cf dev` also serves apps/web/dist. Browser check: `bun apps/web/scripts/e2e.ts` (Playwright, installed chromium 1243).
- Next order: 6 code mode + 7 link (so the mux can drive acpmux), then 4/5 memory, then 8/9 auth and staging.
