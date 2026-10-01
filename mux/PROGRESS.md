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
- 2026-09-30: step 6 live. `run` executes in `env.LOADER.load` with `globalOutbound: null`; the only capability is `MuxApi` (WorkerEntrypoint via `ctx.exports`, props fix mux, owner, conversation). Link sockets and tokens live in AccountDO (`POST /api/link/token`, `/api/link/ws?token=`); agent events route back to the spawning mux and conversation.
- 2026-09-30: step 7 live: mux spawned a claude agent on this Mac through mux-link, the agent wrote the file, the turn_end event woke the mux and it reported the result. The acpmux codex harness fails at start on this Mac ("agent process closed", also from the acpmux CLI); use claude. Once seen: "Workers runtime canceled this request ... hung" during a failing run; not reproduced; logs (`"at"` JSON lines) now trace turns, runs, link calls and events.
- 2026-09-30: step 8 live. Stack API allows any origin, so email/password sign-in works from localhost and workers.dev without Stack config. Worker verifies ES256 tokens with jose against the project JWKS; display name from the `name` claim. Project: cmux dev (454ecd03, cmuxterm-dev) for now. Machines panel mints link tokens and shows the `mux-link login` command. The local build guard uses one global lock (/tmp/cmux-local-build-UID); cargo waits behind other sessions' xcodebuilds, so skip cargo when Rust is unchanged.
- 2026-10-01: step 9: `cf deploy` 0.13 sends no Authorization header in its deploy step (even with a fresh OAuth token), so deploy runs `wrangler deploy --experimental-new-config --secrets-file` with CLOUDFLARE_API_TOKEN taken from the cf OAuth file. Staging refuses dev identities (401). Link needs a rustls crypto provider (ring) for wss.
- 2026-10-01: step 4 live: messages, events and replies go to the log; wake (96 lines) goes into instructions; compaction runs from the alarm when the inbox is empty, 8 summaries per step, levels 1-3 on gpt-6-luna low. Cross-conversation recall and summaries checked live.
- 2026-10-01: step 5 live: one memory VM per account (`mux-mem-<sha>`), a git repo per mux (LOG.txt, TREE/), every write a commit. No server on the VM: operations run through Freestyle exec-await with data on stdin/env. Freestyle has no size below 4 vCPU / 8 GiB / 32 GiB (grow-only), so the VM pauses after 300 s idle; exec wakes it in ~0.1 s. The Durable Object keeps a SQLite write-through cache (log lines are immutable).
