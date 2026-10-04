# New tab reply on accept (R81, zero-wait IX2/IX3 for `new-tab`)

Owner: new tab lead. Design reviewer before code: protocol/daemon owner (coordinator, 2026-10-04).
Review 2 (2026-10-04, 92557d82cb2): approved; A1 and A2 added below without further review.
Review 1 (2026-10-04): stage A approved in direction with required changes R1-R6, which this
revision adds (marked R1-R6 below). Coordinator: do stage A now; stage B waits for the write path
(PR2-PR6 not started, no owner); the stage A accept commit must be able to become a writer intent
later without a protocol change.
Background: `plans/cmux-next/new-tab.md` status (R81(c)) and the hq working doc
`plans/cmux-tui-zero-wait-interaction.md` (L1-L4, IX2, IX3). This file narrows that plan to the
`new-tab` path that the app's "!" and Cmd-T terminal use, and pins what the lane builds first.

## 1. Problem, measured

A daemon `new-tab` replies after the whole launch: about 100 ms p50 and 140 ms p95 on
cmux-lawrence-2 (`scripts/cmux-next/new-tab-daemon-bench.py`). The request thread waits for
5 SQLite commits (prepare intent, mark executing, `commit_terminal` twice, effect projection),
3-4 host record syncs, and the host bootstrap/launch handshake. One F_FULLFSYNC costs 3.9 ms p50
on that Mac. The R81(c) spare host removes only the host exec, so it changed nothing.
Debug marks (`CMUX_TUI_DEBUG_SPANS`, section 7) measure the rest.

## 2. Target

- The reply for `new-tab` takes at most one durable commit plus CPU: p50 at most 15 ms and
  p95 at most 25 ms on cmux-lawrence-2 (stage A). Stage B (section 6) removes the commit.
- The tab is in the tree and attachable at the reply, with lifecycle `launching`.
- Time to the first shell prompt does not get worse (it is limited by shell startup).
- The app swaps its "!" placeholder for the real terminal view when the reply arrives, in one
  frame, with no dropped frames.

## 3. Stage A: reply after one durable accept commit (IX2 for `new-tab`)

### 3.0 One shared terminal-creation path

The accept transaction and the launch job are one shared path for every create that makes a
terminal. `new-tab` is its first caller; split, new-pane, new-screen and new-workspace move onto
it after. There is no copy for `new-tab` only. New-workspace fits: its workspace ledger
(`commit_resource_patch_with_workspace_ledger`) is written in the same SQLite transaction today,
so it joins the accept transaction.

Forward compatibility with stage B: the accept step takes a typed `TerminalCreationIntent`
(selectors, placement, reserved terminal id, launch spec, correlation key) and returns an
`AcceptReceipt` (revision, tab, surface, terminal id, incarnation). In stage A the caller commits
the receipt before the reply; in stage B the single writer accepts the same intent and commits it
in a batch. The reply fields do not change between the stages, only the time of the reply.

### 3.1 Accept, on the request path

1. Validate the selectors and reserve the terminal id (the caller's id or a fresh one).
2. One SQLite transaction (one F_FULLFSYNC) writes: the creation intent already in state
   `executing`, the tab and pane placement, the terminal row with lifecycle `launching`, the
   launch spec, and the projection rows. Today these are 4 transactions (prepare, executing,
   first `commit_terminal`, effect projection). The order rule "mark executing before invoking
   the effect" still holds, because the effect is host activation, which comes after this commit.
   Consequence (spec rule): the `prepared` step goes away, so recovery can never cancel an
   interrupted create. Every accepted create is reconciled: relaunched or adopted (3.6).
3. Insert the surface into `State` as a launching surface (3.3), publish the tree delta, and
   reply `{surface, tab_id, terminal_id, lifecycle:"launching"}`.

The host launch already starts when the request arrives (`prelaunch_tab_terminal`), in parallel
with the accept. A v4 host starts its child only on Activate.

R1, what a prelaunched host leaves on disk before the accept commit: the host process, its
endpoint socket under `/tmp/cmux-th-<uid>/`, and its published discovery record
(`<terminal>.json` in the host root); the host writes the record during Launch, before the accept
commit. A daemon crash in that gap leaves a host and a record with no terminal row and no creation
intent. Rule: at startup the owner exact-kills every host whose record has no terminal row and no
creation intent, then deletes its record and endpoint. The terminal-work module states that a
restarted owner already ends hosts whose terminal id the registry does not know; red test R1
proves it (and covers the record and endpoint) before stage A changes the order.

### 3.2 Launch job, off the request path

On the terminal work pool, after the accept commit:

1. Wait for the prelaunched host (or launch one if the prelaunch failed).
2. Adopt it into the launching surface; commit lifecycle `running` (one F_FULLFSYNC). A1: the
   `running` commit checks, under the registry lock, that the row is still `launching` with the
   same incarnation. If the tab was closed meanwhile, the job exact-kills the host and commits
   nothing.
3. Send Activate. The child starts. R2: a crash between this commit and Activate leaves a
   `running` row with a published host whose child never started (3.6).
4. Flush the typed-input queue (3.4) to the PTY, then live input continues.
5. Publish `terminal-lifecycle {terminal_id, from:"launching", to:"running", elapsed_ms}` and
   the first frames.

### 3.3 The launching surface

A surface exists in `State` before its host. It has no attachment yet; it has the launch spec, the
size, and the typed-input queue. Attach and claim are allowed. A launching surface gives an empty
grid with the lifecycle `launching` and the terminal theme colors. Resize is recorded and goes
into the launch (or a resize at once after adoption). Close of a launching surface cancels the
launch job: the prelaunched host is exact-killed, then the normal close path runs.

Decision (review 1): a typed `Launching` state of the surface backend, which becomes `Hosted` on
adoption. Hosted-only operations are methods of the hosted state; on a launching surface they
return a typed refusal, so no call site checks an optional attachment. The surface id, tab id and
client attachments stay the same through adoption. The launching state and its queue go in a new
module (`surface/launching.rs`); `surface.rs` and `mux.rs` do not grow.

R3, every operation on a launching terminal:

| operation | result while `launching` |
| --- | --- |
| attach, claim | works; empty grid, lifecycle `launching`, theme colors |
| resize | works; recorded, applied by the launch |
| input, send, paste (terminal ops and resource ops) | queued (3.4) |
| terminal.read, screen, scrollback | works; empty screen, lifecycle `launching` |
| move tab, rename, focus | works; placement and metadata only |
| close tab, workspace.close | works; cancels the launch job, exact-kills the prelaunched host |
| terminal.list, resource list | works; `lifecycle:"launching"`, `running:false` |
| respawn | refused: `terminal-launching` |
| agent and hook reports for the terminal | queued in order behind the launch, as for a new terminal today |

`terminal.list` already reports `running:false` with `lifecycle:"launching"` for an adopting
terminal. Before stage A, check every client (Swift app, TUI, SDK bindings) for code that reads
`running:false` as dead, and change it to read `lifecycle`.

### 3.4 Typed input while launching

One queue per launching terminal, 64 KiB. Bytes go to the PTY after Activate and before later
live input. A write that does not fit is refused whole with an error that names the budget, so a
paste is never cut in half; nothing is dropped silently. R4: with `supports_input_ack`, a queued
write is acked as `queued`; the `delivered` ack follows when the bytes reach the PTY. A `queued`
ack is not durable: a daemon crash loses queued bytes even after their `queued` ack (3.6). Rule (from the zero-wait plan): queue when the peer is known not to have
started, drop when its state is unknown.

### 3.5 Launch failure after accept

The tab stays in place and its terminal row goes to `exited` with a cause string
(`launch-failed: <reason>`), in one commit. The `terminal-lifecycle` event carries the cause.
The app shows the cause in the tab where the terminal would be (the exited-terminal view), and a
retry action (`respawn`). R5: the typed-input queue stays with the tab, and the app shows the kept
text, but nothing replays it automatically. `respawn` starts a clean shell. A separate action
"send kept input", with the text visible, sends it to the new shell only when the user chooses.
A journal observation `terminal.input.retained {bytes}` records the kept input. Closing the tab
discards it.

### 3.6 Crash recovery

With stage A the accept is durable before the reply, so a daemon crash after the reply leaves a
terminal row in `launching`:

- No published host record: the child never started (Activate follows the `running` commit).
  The restarted owner relaunches a host with the same terminal id in the same placement and runs
  3.2. If that launch fails, the row goes to `exited` with its cause, as in 3.5.
- A published host record exists (crash between host publication and the `running` commit): the
  owner adopts the host through the `adopting` path, then sends Activate.
- R2: a `running` row whose host reports launch activation still pending (the v4 Hello carries
  `FLAG_LAUNCH_ACTIVATION_REQUIRED`): crash between the `running` commit and Activate. The owner
  adopts the host and sends Activate. Today's adopting path expects a started child; stage A makes
  it read the flag and activate.
- R6: a relaunch in place gets a new terminal incarnation. It keeps the terminal id and placement,
  but a client that holds the old incarnation cannot drive the new host (its ops are refused as for
  any stale incarnation).
- The typed-input queue is in memory and is lost with the process. State this in the spec. The
  bytes were never written to a shell, so no command runs twice.
- A crash before the accept commit loses the request. The client has no reply, so it shows a
  launch error in the placeholder (app rule: a create with no reply after the daemon connection
  drops ends as failed, and the "!" text goes back into the new tab field).

`reconcile_interrupted_resource_creation` already sees interrupted creations by correlation key;
stage A adds the relaunch of a `launching` row and the activation of a pending `running` row to
the restore path.

Events: the tree delta is published at accept with lifecycle `launching`. Then exactly one
`terminal-lifecycle` event is sent per transition (`launching -> running`,
`launching -> exited` with cause, and the restart transitions), so no client polls.

## 4. App side (CmuxNext)

- "!" today: a placeholder in the same frame, then the real `TerminalHostView` at about 80 ms.
  With stage A the view binds to the replied surface at about 15 ms and shows the empty launching
  grid; keys go to the daemon at once (queued there).
- A failed launch shows the cause in the tab, the kept input, and a retry button (localized).
- The bench (`scripts/cmux-next/new-tab-e2e.py --bench`) reports keypress to bound surface,
  keypress to first frame, and dropped frames.

## 5. Spec and journal changes (need a window)

- `spec/commands.md`: the `new-tab` reply comes before host Ready and carries `lifecycle`; the
  R3 table; `respawn` refuses `terminal-launching`.
- `spec/events.md`: the `terminal-lifecycle` event with `from`, `to`, `elapsed_ms`, `cause`, and
  `terminal_incarnation` (A2: after a crash relaunch the event carries the new incarnation, so a
  client rebinds without a refetch).
- `spec/session-journal.md`: `terminal.input.retained`; the rule that every accepted create is
  reconciled (relaunched or adopted, never cancelled); the restart rules of 3.6 (R1, R2, R6).
- Input-ack spec (where `supports_input_ack` is defined): the `queued` ack and whole-write refusal
  (R4).
- `spec/terminal-host.md`: no change. The activation barrier (Activate only after durable
  topology) holds by construction.
- New `spec/interaction-lifecycle.md` (from the zero-wait plan) for the lifecycle states and the
  input rule.

## 6. Stage B: reply before the commit (IX3)

Accept on the single writer, publish at accept, commit in a batch after. This needs the
write-path plan's single-writer work (its PR2-PR6). Crash between accept and commit loses the
accepted tab; the new boot generation makes every frontend refetch, and the tab disappears. The
app must then show "the new tab was lost when the daemon restarted" and put the "!" text back.
Stage B starts only after stage A lands and the reviewer confirms the write-path state.

## 7. Measurement first (in progress)

`CMUX_TUI_DEBUG_SPANS=FILE` writes one JSON line per create: the time since request arrival at
each step (job start, prelaunch target, spare take, host publication, bootstrap, launch, record,
connect, workspace persist, commit start, `new_tab` selectors/commit/events, every registry
commit start, every mutex wait of 0.5 ms or more with its call site, reply queued).
`SPANS=1 scripts/cmux-next/new-tab-daemon-bench.py BIN` prints the gap before each mark.
Results (2026-10-04, cmux-lawrence-2, 2 x 20 tabs per build), mean per tab:

| step | marks only (nt13) | plus barrier sync (nt14) |
| --- | --- | --- |
| daemon request to reply, p50 | 94.9 / 76.8 ms | 55.6 / 45.1 ms |
| host Launch handling (host process) | 36 / 26 ms | 23 / 18 ms |
| publication lock | 10 ms | 0.4 ms |
| `persist_workspace` | 10-11 ms | 3 ms |
| 5 registry SQLite commits | 31 / 24 ms | 23 / 20 ms |
| bootstrap, connect, lock waits | 1-3 ms | 1-3 ms |

Stage A takes the host Launch (about 20 ms) and 4 of the 5 commits (about 16 ms) off the reply
path. The next marks go into the host's Launch step (PTY open, terminal setup).

## 8. Test plan (red first)

1. With `CMUX_TUI_TEST_HOST_READY_DELAY_MS=2000`, the `new-tab` reply arrives in under 200 ms
   with lifecycle `launching`, and the tab is in `list-workspaces`.
2. Input sent while launching reaches the shell in order, before later input.
3. Input over 64 KiB while launching is refused with the budget error.
4. A launch that fails after accept leaves the tab with `exited` and the cause; `respawn` starts a
   clean shell with no replay; "send kept input" sends the kept bytes once (R5).
5. SIGKILL of the daemon after the reply and before `running`: the restarted owner relaunches
   the tab in place with a new incarnation, and an op with the old incarnation is refused (R6);
   with a published host record it adopts the host.
6. Close of a launching tab kills the prelaunched host and leaves no row in `launching`.
7. Bench: reply p50/p95, keypress to bound surface, keypress to first frame, before and after.
8. R1: SIGKILL of the daemon between the prelaunch and the accept commit leaves no host process,
   no record and no endpoint after restart.
9. R2: SIGKILL after the `running` commit and before Activate: after restart the host is adopted
   and activated, and the shell runs.
10. R4: with input acks on, a write to a launching terminal is acked `queued`, then `delivered`;
    a write over the budget is refused whole.
11. A1: a close during adoption (a test hook holds the launch job between adopt and the `running`
    commit) leaves no host process and no `running` row.

## 8a. Gaps found while writing the red tests (2026-10-04)

Decided by the reviewer the same day: G1 yes, plus the rule that while a terminal is launching an
op that names an incarnation is refused (stale-incarnation error) and an op that names none (for
example closing its tab) is accepted. G2 yes as cmux.protocol/2 operations `terminal.relaunch`
(only on an exited or launch-failed terminal; always a new incarnation) and
`terminal.input.send_kept` (refused when nothing is kept; the clear and the send are one step; the
normal input path, so origin rules apply); raw commands only if the app needs them. G3 yes; the
spec says `queued` is not durable, and `terminal.launch_input_budget` carries
`{budget_bytes, queued_bytes}`. G4 yes only under `#[cfg(any(test, debug_assertions))]` behind the
crate's test seam; release builds ignore the variables.

- G1, incarnation in the reply (A2): the host picks the incarnation during Bootstrap, so at accept
  time the daemon does not know it. Stage A without a host wire change: the reply carries
  `terminal_incarnation: null` while `launching`, and the `terminal-lifecycle` event for
  `launching -> running` carries it. The other choice, the daemon picks the incarnation and sends
  it in Bootstrap, changes the host protocol (cloud guest upgrade rules apply). The red tests use
  the first choice.
- G2, no terminal respawn op exists today. Stage A adds `relaunch-terminal {terminal_id, env?,
  shell_args?, cwd?}` (same id and placement, new incarnation, clean shell) and
  `send-kept-input {terminal_id}` (sends the kept bytes once, then clears them).
- G3, `send` to a launching terminal returns `{delivery:"queued"}` (today `{}`); `paste:true`
  decides the bracketed-paste wrapping when the queue is flushed, from the started terminal's
  mode 2004. A refused write uses error code `terminal.launch_input_budget`.
- G4, test hooks for the crash windows (test daemons only): `CMUX_TUI_TEST_LAUNCH_JOB_DELAY_MS`,
  `CMUX_TUI_TEST_ACCEPT_COMMIT_DELAY_MS`, `CMUX_TUI_TEST_ACTIVATE_DELAY_MS`,
  `CMUX_TUI_TEST_ADOPT_HOLD_MS`.

## 9. Order

1. Debug marks (section 7), bench numbers in this file.
2. Reviewer approval of sections 3-6.
3. Window for the spec deltas (section 5), then the red tests, then stage A in the daemon.
4. App side (section 4).
5. Spare decision with numbers (R81(c) follow-ups stay frozen until then).
6. Stage B when its dependency is ready.
