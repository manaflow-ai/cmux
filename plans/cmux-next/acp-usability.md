# ACP pane usability: harness switch latency and the top blockers

Audit of the cmux-next agent pane (`webviews/src/agent-session/acpmux`, owner: ACP UI lead) and the acpmux daemon (`cmux-tui/crates/acpmux`, owner: acpmux code owner), measured on 2026-10-04 against dev slot 12 (`dev-slot.sh up 12`, acpmux `0.1.0 (7841386ef)` run with `--log debug`, branch base `origin/feat-cmux-next` at `b3105b0f003`). No pane or daemon file was changed. New files only:

- `webviews/scripts/agent-pane/bench-harness-switch.mjs`: switches harness in the production pane and times every WebSocket frame (patched in before the pane loads) and the first frame that paints the new harness.
- `webviews/scripts/agent-pane/bench-usability.mjs`: reopen a stored session, its first prompt, model switch, interrupt, an unavailable harness, daemon restart.
- `webviews/scripts/agent-pane/bench-switch-race.mjs`: a prompt sent during a switch.
- `webviews/bench/switch/` (`index.html`, `bench.ts`, `pool.ts`, `run.mjs`): the instant-switch prototype, `?mode=before` (production path) against `?mode=after` (optimistic UI, cached catalog, warm session pool, queued prompt), both on the production `AcpmuxDirectClient`.

Daemon-side stage times come from each session's wire log (`$ACPMUX_HOME/sessions/<id>/events/*.ndjson`, millisecond `at` on every line acpmux writes or reads), process data from `ps` sampled every 50 ms, adapter boot outside the daemon from a stdio JSON-RPC driver. The laptop ran other agents' work during the audit, and latencies rose as leaked adapters piled up (blocker 2), so ranges are wide. Adapters on this machine: `claude-agent-acp 0.74.0` and `codex-acp` under `~/.local/share/cmux-acp` (bash wrapper, then node), `opencode acp` (Bun binary). The pane's `claude` resolves to the `claude-sr` profile (Claude through the subrouter).

## 1. Harness switch latency

### What a switch does today

The picker's harness row (`modelMenuNodes.tsx` `harnessRow`, `ModelPickerDrill.tsx`) calls `onHarness`, which is `callNative("chat.new", { harness })` (`App.tsx:853`), which runs `AcpmuxDirectClient.create()` (`direct.ts:1369`): `await session/new`, then `select()` (`_acpmux/detach` of the old session, `_acpmux/attach`, `_acpmux/events`). The daemon's `Hub::new_session` (`hub/lifecycle.rs:73`) answers `session/new` only after `ensure_child` spawns the adapter, sends ACP `initialize`, sends the adapter's `session/new`, and applies any default model and effort. Until that reply the pane keeps the old session, the old transcript and the old picker on screen and shows nothing pending.

### Measured, page clock (production pane, `bench-harness-switch.mjs`, 3 runs)

| switch | n | pick to `session/new` reply | reply to new harness painted | total to usable composer |
|---|---|---|---|---|
| Claude to Codex | 6 | 1,601 to 4,912 ms | 6 to 16 ms | 1,607 to 4,912 ms |
| Codex to Claude | 5 | 1,184 to 5,860 ms | 3 to 10 ms | 1,187 to 5,860 ms |
| to opencode | 4 | 5,886 to 14,880 ms | 5 to 10 ms | 5,895 to 14,880 ms |
| new tab, first session (prewarmed on connect) | 2 | 4,186 ms | 26 ms | 4,924 ms after navigation |

"Repeat" switches (the same harness a second time) were no faster (Codex 1,607 vs 1,700 ms; opencode 10,374 vs 5,895 ms): nothing is kept warm per harness, every switch spawns a new adapter. The catalog (`_acpmux/harnesses` + `_acpmux/models`) answers in 6 to 7 ms from the daemon's startup probe (`probe_models`), so the model catalog is not on the critical path. The pane's own work after the reply (detach, attach, events, permission groups, handoff) is 6 to 16 ms.

### Daemon stages (wire log, 21 sessions)

| harness | exec | `initialize` (adapter boot) | `session/new` in the adapter | `available_commands_update` after ready |
|---|---|---|---|---|
| Claude (claude-acp, node) | 2 to 6 ms | 324 to 1,192 ms | 776 to 2,355 ms | 0 to 2 ms |
| Codex (codex-acp, node, then `codex app-server`) | 1 to 5 ms | 324 to 1,635 ms | 1,168 to 3,090 ms | 51 to 463 ms |
| opencode (Bun) | 2 to 17 ms | 4,280 to 6,971 ms | 1,342 to 3,390 ms | 0 to 1 ms |

The same adapters driven directly over stdio (3 runs each), plus a second `session/new` on the already initialized process:

| adapter | `initialize` | first `session/new` | second `session/new`, same process |
|---|---|---|---|
| claude-acp | 680 to 1,781 ms | 1,290 to 2,298 ms | 655 to 2,455 ms |
| codex-acp | 299 to 1,076 ms | 2,384 to 4,168 ms | 889 to 1,144 ms |
| opencode | 4,878 to 7,925 ms | 2,155 to 4,072 ms | 21 to 168 ms |
| codex through `npx -y @agentclientprotocol/codex-acp@1.10.0` (the fallback in `config/codex_adapter.rs` when no `codex-acp` is on PATH) | 3,889 to 21,699 ms | 1,739 to 2,911 ms | 1,983 to 2,421 ms |

Why the switch is slow, in order:

1. **The whole adapter cold start is on the critical path.** `session/new` = spawn + `initialize` + adapter `session/new` + config replay, 1.2 to 10.4 s, and the pane waits for all of it before it paints anything.
2. **A warm process alone does not fix Claude or Codex.** Their adapter `session/new` costs 0.65 to 2.5 s (Claude) and 0.9 to 1.1 s (Codex) even on an initialized process, because it starts the CLI session and that session's MCP servers: each Claude session spawned `npm exec @linqapp/sdk-mcp@latest` (a registry check on every start), each Codex session spawned `cua-repl`, `node_repl` and an MCP `server.mjs`. Only a pre-created session (process and session both ready) reaches the target. opencode is the exception: its second `session/new` is 21 to 168 ms.
3. **npx on the critical path** exists only through the Codex fallback profile, and it costs 3.6 to 21 s per spawn. This machine has `~/.acpx` entries, so it did not hit it; a machine without `codex-acp` pays it on every Codex session.
4. **`warm.rs` warms the wrong thing for a switch.** `_acpmux/warm` (called by `warmRecentProjects` on every pane connect) respawns the children of the three most recent sessions, one per cwd, so reopening those sessions is fast. It never prepares a harness that the user is not on, and nothing reuses a process across sessions.
5. **No UI wait is spurious.** The pane does wait for `session/new` before it paints, but the 6 to 16 ms after the reply is already small. The fix is to stop waiting, not to make the waits shorter.

## 2. Design: an instant switch

Target: under 50 ms from the pick to a composer that shows the new harness and accepts a prompt, warm or not.

### 2a. Optimistic switch in the pane (owner: ACP UI lead)

On the pick, in the same frame:

- The picker, the composer chips and the header show the picked harness and its last-used (or catalog-default) model and effort from the cached catalog, marked as starting.
- The transcript shows the new empty chat. The old session is detached only after the new one is selected.
- The composer accepts input. A prompt sent before the session is ready is held in the pane as a pending row of the new chat ("Starting Codex, sends when ready"), then goes out as the first `session/prompt` of the new session. A cancel before then drops it; a failed start puts the text back in the composer and the picker back on the old harness with the error.
- Slash commands are empty until `available_commands_update` (0 to 463 ms after ready); show the last commands seen for that harness from a per-harness cache and refresh them.
- On hover or keyboard highlight of a harness row (and when the picker opens on the harness submenu) send `_acpmux/prewarm { harness, cwd }`; on a pick send `session/new` with `_meta.acpmux.pool: true` so the daemon may answer with a pooled session.
- Pick-time catalog: TanStack Query already caches it (`catalog.ts`); keep it per harness, refresh it in the background on `_acpmux/models` changes, never await it in the switch path.

This also fixes a correctness bug found here: today a prompt sent while a switch runs goes to the OLD harness's session and the pane then moves to the new chat, so the reply lands out of view (`bench-switch-race.mjs`: picked Codex, prompt landed in `claude-sr`, pane then showed Codex). `send()` uses `ensureSession()`, which returns the still-selected old session during `create()`.

Files: `App.tsx` (`chat.new` action, `onHarness`), `direct.ts` (`create`, `ensureSession`, `send`: a pending-session state that owns the queued prompt; `select`), `ComposerPickers.tsx` and `modelMenuNodes.tsx` (show the pending harness; hover/highlight calls prewarm), `ModelPickerDrill.tsx`, `catalog.ts` and `modelCatalog.ts` (per-harness cached defaults), `slashCommands.ts` (per-harness cache), `Composer.tsx` (pending prompt row), `i18n.ts` (two strings, English and Japanese).

### 2b. Warm session pool in the daemon (owner: acpmux code owner; needs a cmux-tui window)

Per the coordinator's binding conditions (R137):

- **What is warm.** At most two pooled sessions per cwd: the LAST-USED harness other than the current one, and the harness under the pointer or picker highlight (`_acpmux/prewarm`). Never every enabled harness. A pooled session is a fully created acpmux session (adapter spawned, `initialize`d, adapter `session/new` done, defaults applied) that is hidden from `_acpmux/watch` and the session store until claimed.
- **Claim.** `session/new` with `_meta.acpmux.pool: true` and a matching (harness, cwd, preset, model, effort) takes the pooled session: it is inserted into `sessions`, saved, gets its `created` event and is returned (measured 7 to 10 ms end to end in the prototype). A mismatch falls back to today's path. The daemon refills the role after a claim.
- **Idle exit on an injected clock.** A pooled session that holds no role for `pool.idle` (proposed 10 min) is killed and purged. The timer is a `Clock` trait object (`now()`, `sleep_until()` cancelled through a `CancellationToken` tied to the pool entry), never `tokio::time::sleep` in the pool logic, so tests advance time by hand.
- **Idle CPU 0%.** Measured idle CPU of a pooled adapter tree: Claude 0.3 to 1.2%, Codex 0 to 0.33%, opencode 0.85 to 1.93%. That fails the 0% condition, so a pooled session's process group is parked with `SIGSTOP` once it is ready and resumed with `SIGCONT` on claim. Measured: 0.00% CPU while stopped, `SIGCONT` 0.03 to 0.07 ms, and a prompt after resume works for Codex (first text 8.4 s, backend time) and opencode (5.9 s). Claude after resume is UNVERIFIED: the standalone Claude driver did not finish a prompt with or without `SIGSTOP`, so the test harness, not the stop, failed; verify through the daemon before shipping.
- **Memory per pooled session** (tree RSS, steady): Claude 235 to 287 MB (4 processes), Codex 173 to 386 MB (6 to 10 processes, mostly its MCP servers), opencode 135 to 525 MB (1 process, grows while idle). Two pooled sessions cost 0.35 to 0.9 GB. Report it in `_acpmux/status` and cap it (`pool.max_rss_mb`, default 1,024; evict the hover entry first).
- **Never npx on the critical path.** For the npx fallback profile, run `npx` once in the background at startup to resolve the package's bin path, cache it under `$ACPMUX_HOME/bin-cache/<package@version>`, and spawn `node <bin>` directly; fall back to npx only when the cache is missing.
- **Prerequisite race fix.** `ensure_child` publishes `session.child` before `initialize` and `session/load` finish (`hub/lifecycle.rs`, the `*session.child.lock().await = Some(child.clone())` before the `initialize` request), so `child_for` hands a half-loaded child to a prompt. Measured: after `_acpmux/warm` respawned a stored Claude session, its `session/load` took 6.3 s and a prompt sent 5.3 s in failed with `Session not found` (turn error, the user's prompt lost). Publish the child only after load or new completes, or make `child_for` wait on the spawn lock. The pool must use the fixed path.

Files: `src/hub/warm.rs` (the pool: entries, roles, claim, refill, park/resume, idle release), `src/hub/lifecycle.rs` (`new_session` claims; `ensure_child` publish-after-load fix; config replay shared with the pool), `src/hub/mod.rs` (pool state on `Hub`, the `Clock`, shutdown kills pooled sessions), `src/server/` dispatch for `_acpmux/prewarm` and `_acpmux/pool_status`, `src/schema.rs` and the handoff schema JSON if the pane validates replies, `src/config.rs` (`pool.idle`, `pool.max_rss_mb`, `pool.enabled`), `src/config/codex_adapter.rs` (resolved-bin cache), `src/agent.rs` (`park()`/`resume()` with `killpg(SIGSTOP|SIGCONT)`).

### 2c. How a switch to a harness that is NOT warm still feels instant

The optimistic UI makes the switch itself frame-fast whether or not the pool has the harness; only the first prompt waits, and it waits without user action. Prototype numbers (`webviews/bench/switch`, user hovers 300 ms, clicks, types for 800 ms, presses Enter):

| case | n | pick to picker painted | pick to session ready | Enter to prompt sent | sent to |
|---|---|---|---|---|---|
| before (production), Codex | 2 | 4,211 to 4,912 ms | same | 0 ms (after a 4 to 5 s wait for the UI) | new harness only because the bench waited |
| before (production), opencode | 1 | 14,880 ms | same | 0 ms (after the wait) | new harness |
| after, pool hit (Claude, Codex, opencode) | 7 | 4 to 7 ms | 7 to 10 ms | 0 ms | new harness |
| after, miss, Codex | 2 | 5 to 8 ms | 3,351 to 7,024 ms | 2,529 to 6,197 ms, automatic | new harness |
| after, miss, opencode | 2 | 7 ms | 12,809 to 16,473 ms | 12,004 to 15,661 ms, automatic | new harness |

Measured worst case for a cold harness: 16.5 s until the queued prompt goes out (opencode on a loaded laptop with about 30 leaked adapters running), during which the composer, picker and draft are already on the new harness. On an unloaded run the cold miss is 1.2 to 5.9 s (section 1). The hover prewarm starts the cold path 300 ms earlier; the last-used role makes the common back-and-forth (Claude to Codex to Claude) always a hit.

### Strongest objections and the answers

- **Memory and CPU of idle adapters.** 0.35 to 0.9 GB for two pooled sessions, and nonzero idle CPU. Answer: two entries per cwd, an RSS cap, `SIGSTOP` parking (0.00% measured), a 10-minute idle exit, and no pool on battery or under memory pressure (`pool.enabled` off when `NSProcessInfo` reports low power or the daemon sees memory pressure). Today's leak (blocker 2) costs far more than the pool.
- **Auth expiry in a warm process.** A session parked for minutes can hold a stale OAuth token or a dead subrouter connection. Answer: the idle exit bounds age at 10 minutes; on claim the daemon checks the entry's age against `pool.max_age` (proposed 5 min for ClaudeStdio and Codex) and refreshes; the first `session/prompt` failure with an auth error retries once on a fresh session with the same prompt.
- **Account switching.** A pooled session was created under the account and env that were current at pool time. Answer: the pool key includes a hash of the resolved spawn env (profile env, login env, `ANTHROPIC_*`/`CODEX_*`/subrouter variables) and the account id the daemon knows; a config reload, login env import, or account change drains the pool.
- **Pooled sessions write harness state.** Claude and Codex may create session files on `session/new`. Answer: a discarded pooled session is purged through the harness's own close or delete where it supports one (Claude advertises `sessionCapabilities.close` and `delete`), otherwise it stays unnamed and empty, which `_acpmux/watch` already hides.
- **cwd mismatch.** A pool is per cwd. A switch in a cwd with no pool entry is a miss and takes the optimistic path.

## 3. Other usability blockers, ranked by user impact

Measured where a number exists. "Pane" = ACP UI lead, "daemon" = acpmux code owner.

| # | blocker | measured | proposed fix | owner, files |
|---|---|---|---|---|
| 1 | Harness switch blocks on a full adapter cold start, with no feedback | 1.2 to 14.9 s, old harness shown meanwhile | Section 2 | both, section 2 |
| 2 | Every new session's adapter stays alive forever (no idle reaping); a switch leaks one adapter tree | 7 switches: 14 adapters, 3.3 GB RSS; about 25 sessions: 36 adapters, 187 processes, 9.4 GB; idle CPU 0.3 to 1.9% each. Latencies on the same daemon rose from 1.6 to 4.9 s (Codex) and 5.9 to 14.9 s (opencode) as they piled up | Detach a session's child when no client attaches and no turn runs for `idle_child` (proposed 5 min, injected Clock); keep at most N live children per daemon (LRU); the pane's `_acpmux/detach` already exists, so the daemon can act on it | daemon: `hub/mod.rs`, `hub/turns.rs` `detach_child`, `hub/lifecycle.rs` |
| 3 | A prompt sent during a harness switch goes to the old session and the reply lands out of view | reproduced 1 of 1 (`bench-switch-race.mjs`) | Pending-session state owns the prompt (2a) | pane: `direct.ts` `create`/`ensureSession`/`send`, `App.tsx` |
| 4 | A prompt during `session/load` of a respawned session fails with `Session not found` | load 6.3 s; prompt 5.3 s in failed and was lost | Publish the child after load (2b prerequisite); the pane retries a turn error with `-32603 Session not found` once | daemon: `hub/lifecycle.rs` `ensure_child`; pane: `direct.ts` turn error handling |
| 5 | Time to first token is backend-bound and the pane cannot hide it | Enter to first text: Claude 2.1 to 4.5 s (one 11.3 s), Codex 4.6 to 21.7 s, opencode 5.2 to 8.7 s; page adds under 5 ms over the daemon's arrival time | Show the model's own progress early (`session_info_update`, thought chunks, tool starts) in the "Thinking" row; report per-harness TTFT in `_acpmux/status`; route Codex overload (gpt-6-astra at capacity) to the subrouter's fallback | pane: `conversation/`, `model.ts`; daemon: `hub/stream.rs` (metrics) |
| 6 | Streaming is stop-go, code blocks blank out, pinned scroll jumps | see `plans/cmux-next/acp-streaming.md` (branch `feat-cmux-next-acp-stream-audit`): text on 7 to 13% of frames, code cards blank on up to 218 frames per turn, line jumps up to 131 px | land that audit's RevealPacer and incremental Markdown slices | pane |
| 7 | A new chat's first session costs the same cold start | 4.2 s `session/new` on connect; 4.9 s from navigation to a usable composer (dev bundle) | Same pool, with the default harness's role filled at daemon start for the most recent cwd; optimistic composer as in 2a | both |
| 8 | A harness that cannot start is offered anyway, and fails after a wait | Gemini: probe failed at daemon start ("API key is missing"), the picker still lists it, `chat.new` errors after 5.1 s | Mark probe failures in `_acpmux/models` (`unavailable` with the reason, as `model_availability.rs` does for models); the picker shows it disabled with the reason and a fix hint | daemon: `hub/lifecycle.rs` `probe_models_with`, `hub/model_availability.rs`; pane: `modelMenuNodes.tsx`, `modelCatalog.ts` |
| 9 | Per-session MCP servers and npx inside the harness slow every session start | Claude: `npm exec @linqapp/sdk-mcp@latest` per session; Codex: 3 to 7 MCP helper processes per session; Codex npx fallback 3.6 to 21 s | Resolve-once cache for the npx profile (2b); surface slow MCP startup in the session's status ("starting MCP: linqapp") from the adapter's stderr; suggest pinning `@latest` MCP servers | daemon: `config/codex_adapter.rs`, `hub/stream.rs` |
| 10 | Daemon restart: shutdown and resume costs | restart command 2.1 s (shutdown grace); pane reconnected 134 ms after the new daemon was ready (daemon log); first prompt after restart 2.35 s to reply; the reconnect check in the bench page could not read "connected" from `chatState().connection` (it reads "session changed") | Expose a stable `connection` state (`connected`, `reconnecting`, `lost`) in `chatState()` for automation; keep `_acpmux/warm` but only after the race fix (4) | pane: `direct.ts`, `automation.ts`; daemon: `hub/lifecycle.rs` |
| 11 | Slash commands are missing for the first moment of a session | `available_commands_update` 0 to 463 ms after ready (Codex the slowest) | Per-harness command cache (2a) | pane: `slashCommands.ts` |
| 12 | Interrupt | 117 ms from cancel to turn stopped (Claude) | none needed; keep as a regression check | none |
| 13 | Model switch | 21 ms from pick to chip | none needed; a combo of model and effort waits for the model's report (`ComposerPickers.tsx` pending effort), keep | none |
| 14 | Session switching | 24 ms from select to rows shown (stored Claude session, 3 rows, 37 sessions) | none for small sessions; measure a 5,000-event session before claiming more (`direct.ts` asks `_acpmux/events` and `_acpmux/attach` for 400 events per page, 5,000 on a missed-events fetch) | pane: `direct.ts` |
| 15 | Steering and permissions are not measured here | Claude ran with `mode: auto` (no permission asks); prompts during a turn are queued by the daemon and shown in the composer queue (`Composer.tsx`), there is no mid-turn steer although Claude advertises `steering.supported` | Measure the permission card path with a default-mode session next; add steer (inject into the running turn) behind Claude's capability | pane: `Composer.tsx`, `PermissionCard.tsx`; daemon: `hub/turns.rs` |

Not measured, left as known gaps: attachments (the dev host has no native file picker), history paging on a long session, keyboard-only flow through the picker (it has keyboard navigation, `useMenuTree.ts`, but no timing), and session search over the real store (51 sessions, 28 MB in `~/.acpmux/sessions`; search is a client-side title filter in `SearchChats.tsx`, so it is fast until titles are missing).

## 4. Routing summary

| change | owner | files |
|---|---|---|
| Optimistic switch, pending session owns the first prompt, race fix (3) | ACP UI lead | `App.tsx`, `direct.ts`, `ComposerPickers.tsx`, `modelMenuNodes.tsx`, `ModelPickerDrill.tsx`, `Composer.tsx`, `i18n.ts` |
| Cached per-harness catalog defaults and slash commands | ACP UI lead | `catalog.ts`, `modelCatalog.ts`, `slashCommands.ts` |
| Prewarm on hover/highlight, `pool: true` on `session/new` | ACP UI lead | `modelMenuNodes.tsx`, `useHoverIntent.ts`, `direct.ts` |
| Unavailable harness shown disabled | ACP UI lead | `modelMenuNodes.tsx`, `modelCatalog.ts` |
| Stable connection state for automation | ACP UI lead | `direct.ts`, `automation.ts` |
| Warm session pool (last-used + hover, Clock idle exit, SIGSTOP parking, RSS cap, env/account key) | acpmux code owner | `hub/warm.rs`, `hub/mod.rs`, `hub/lifecycle.rs`, `agent.rs`, `config.rs`, `server/` |
| Publish child after load (4) | acpmux code owner | `hub/lifecycle.rs` |
| Idle child reaping, live-child cap (2) | acpmux code owner | `hub/mod.rs`, `hub/turns.rs`, `hub/lifecycle.rs` |
| npx resolve-once cache | acpmux code owner | `config/codex_adapter.rs`, `config.rs` |
| Probe failures marked unavailable in `_acpmux/models` | acpmux code owner | `hub/lifecycle.rs`, `hub/model_availability.rs` |

Order: daemon (4) and (2) first (they are bugs and they make every later number honest), then the pane's optimistic switch with the queued prompt (it alone takes perceived switch time from seconds to under 10 ms), then the daemon pool (it removes the wait before the first prompt for the common back-and-forth).

## Reproduce

```bash
webviews/scripts/agent-pane/dev-slot.sh up 12            # with ACPMUX_BIN set
URL="$(webviews/scripts/agent-pane/dev-slot.sh url 12 | sed -n 's/^agent pane: //p')"
cd webviews
bun scripts/agent-pane/bench-harness-switch.mjs --url "$URL" --sequence codex,claude-sr,codex,opencode --prompt "Reply with exactly: ok"
bun scripts/agent-pane/bench-switch-race.mjs --url "$URL"
bun scripts/agent-pane/bench-usability.mjs --url "$URL"
node bench/switch/run.mjs --origin http://127.0.0.1:4192 --fragment "${URL#*#}"
```

The dev server does not watch `webviews/bench/`: bump the `?v=` on the script tag in `bench/switch/index.html` after editing the bench. The prototype's pool runs in the page and pre-creates sessions through the production client's `session/new`; the daemon pool replaces it.
