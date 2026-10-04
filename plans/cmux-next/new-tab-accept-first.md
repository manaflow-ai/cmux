# New tab reply on accept (R81, zero-wait IX2/IX3 for `new-tab`)

Owner: new tab lead. Design reviewer before code: protocol/daemon owner (coordinator, 2026-10-04).
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

### 3.1 Accept, on the request path

1. Validate the selectors and reserve the terminal id (the caller's id or a fresh one).
2. One SQLite transaction (one F_FULLFSYNC) writes: the creation intent already in state
   `executing`, the tab and pane placement, the terminal row with lifecycle `launching`, the
   launch spec, and the projection rows. Today these are 4 transactions (prepare, executing,
   first `commit_terminal`, effect projection). The order rule "mark executing before invoking
   the effect" still holds, because the effect is host activation, which comes after this commit.
3. Insert the surface into `State` as a launching surface (3.3), publish the tree delta, and
   reply `{surface, tab_id, terminal_id, lifecycle:"launching"}`.

The host launch already starts when the request arrives (`prelaunch_tab_terminal`), in parallel
with the accept. That is safe today and stays safe: a v4 host starts its child only on Activate.

### 3.2 Launch job, off the request path

On the terminal work pool, after the accept commit:

1. Wait for the prelaunched host (or launch one if the prelaunch failed).
2. Adopt it into the launching surface; commit lifecycle `running` (one F_FULLFSYNC). Combine
   this with the host record publication where possible.
3. Send Activate. The child starts.
4. Flush the typed-input queue (3.4) to the PTY, then live input continues.
5. Publish `terminal-lifecycle {terminal_id, from:"launching", to:"running", elapsed_ms}` and
   the first frames.

### 3.3 The launching surface

A surface exists in `State` before its host. It has no attachment yet; it has the launch spec, the
size, and the typed-input queue. Attach and claim are allowed. A launching surface gives an empty
grid with the lifecycle `launching` and the terminal theme colors. Resize is recorded and goes
into the launch (or a resize at once after adoption). Close of a launching surface cancels the
launch job: the prelaunched host is exact-killed, then the normal close path runs.

Question for the reviewer: a new backend state of `Surface` (a `Launching` variant that becomes
`Hosted` on adoption) or a separate placeholder entity in `State` that the hosted surface replaces?
The new tab lead prefers the variant: the surface id, tab id and client attachments stay the same,
so no client has to move its attachment.

### 3.4 Typed input while launching

One queue per launching terminal, 64 KiB. Bytes go to the PTY after Activate and before later
live input. A write that does not fit is refused with an error that names the budget; nothing is
dropped silently. Rule (from the zero-wait plan): queue when the peer is known not to have
started, drop when its state is unknown.

### 3.5 Launch failure after accept

The tab stays in place and its terminal row goes to `exited` with a cause string
(`launch-failed: <reason>`), in one commit. The `terminal-lifecycle` event carries the cause.
The app shows the cause in the tab where the terminal would be (the exited-terminal view), and a
retry action (`respawn`). The typed-input queue stays with the tab: the app shows the kept text,
and `respawn` replays it into the new launch. A journal observation
`terminal.input.retained {bytes}` records it. Closing the tab discards the queue.

### 3.6 Crash recovery

With stage A the accept is durable before the reply, so a daemon crash after the reply leaves a
terminal row in `launching`:

- No published host record: the child never started (Activate follows the `running` commit).
  The restarted owner relaunches a host with the same terminal id in the same placement and runs
  3.2. If that launch fails, the row goes to `exited` with its cause, as in 3.5.
- A published host record exists (crash between host publication and the `running` commit): the
  owner adopts the host through the existing `adopting` path, then sends Activate.
- The typed-input queue is in memory and is lost with the process. State this in the spec. The
  bytes were never written to a shell, so no command runs twice.
- A crash before the accept commit loses the request. The client has no reply, so it shows a
  launch error in the placeholder (app rule: a create with no reply after the daemon connection
  drops ends as failed, and the "!" text goes back into the new tab field).

`reconcile_interrupted_resource_creation` already sees interrupted creations by correlation key;
stage A adds the relaunch of a `launching` row to the restore path.

## 4. App side (CmuxNext)

- "!" today: a placeholder in the same frame, then the real `TerminalHostView` at about 80 ms.
  With stage A the view binds to the replied surface at about 15 ms and shows the empty launching
  grid; keys go to the daemon at once (queued there).
- A failed launch shows the cause in the tab, the kept input, and a retry button (localized).
- The bench (`scripts/cmux-next/new-tab-e2e.py --bench`) reports keypress to bound surface,
  keypress to first frame, and dropped frames.

## 5. Spec and journal changes (need a window)

- `spec/commands.md`: the `new-tab` reply comes before host Ready and carries `lifecycle`.
- `spec/events.md`: the `terminal-lifecycle` event with `from`, `to`, `elapsed_ms`, `cause`.
- `spec/session-journal.md`: `terminal.input.retained` and the restart rule for `launching` rows.
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
Results go into this section before stage A code starts.

## 8. Test plan (red first)

1. With `CMUX_TUI_TEST_HOST_READY_DELAY_MS=2000`, the `new-tab` reply arrives in under 200 ms
   with lifecycle `launching`, and the tab is in `list-workspaces`.
2. Input sent while launching reaches the shell in order, before later input.
3. Input over 64 KiB while launching is refused with the budget error.
4. A launch that fails after accept leaves the tab with `exited` and the cause; `respawn`
   replays the kept input.
5. SIGKILL of the daemon after the reply and before `running`: the restarted owner relaunches
   the tab in place; with a published host record it adopts the host.
6. Close of a launching tab kills the prelaunched host and leaves no row in `launching`.
7. Bench: reply p50/p95, keypress to bound surface, keypress to first frame, before and after.

## 9. Order

1. Debug marks (section 7), bench numbers in this file.
2. Reviewer approval of sections 3-6.
3. Window for the spec deltas (section 5), then the red tests, then stage A in the daemon.
4. App side (section 4).
5. Spare decision with numbers (R81(c) follow-ups stay frozen until then).
6. Stage B when its dependency is ready.
