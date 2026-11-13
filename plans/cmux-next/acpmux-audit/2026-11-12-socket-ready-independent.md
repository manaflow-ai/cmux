# Socket bind must not depend on chat persistence (2026-11-12)

Leo: "even if a chat is long, there should be no percievable difference".

`daemon::run` opened the event journal before binding its Unix listener. That
constructor scans checkpoint temporaries, replays records and applies repairs.
Generated WebSocket configuration writes also preceded bind. Both now follow
binding, immediately after the daemon lock and held-home identity checks.
A socket ownership guard removes only this launch's socket if later setup fails.

Binding and serving are distinct boundaries. Launch tokens and trust setup still
precede serving requests. `socket ready` records the bind; `requests ready`
preserves the old mark's position, and the public ready line retains its meaning.
Starting request handling before token initialization would reintroduce the
reconnecting-pane token race.

Detectors:

- `socket_ready_does_not_wait_for_store_open` holds the real journal writer
  lock, connects while the lock is held, releases it, and verifies readiness
  and graceful shutdown. It needs no artificial delay in production code.
- `failed_startup_removes_bound_socket` verifies cleanup after validation fails.
- `local_app_origin::the_endpoint_is_never_served_before_this_launchs_token`
  preserves token-before-serving ordering.
- `god_daemon` uses unchanged small/god fixtures and adds `socketConnectUs`,
  measured by an external client before reading the ready line. The same harness
  can use `ACPMUX_GOD_DAEMON_BIN` for an immutable baseline artifact; children
  still run in the hermetic test environment. Compare actual connection timing
  as well as `marksMs["socket ready"]`, and retain every run.

The historical table in hq#10084 reports 24 ms / 31 ms (1.29x), at the old
mark's later boundary. Local baseline 288be5d3594e reports 17 ms / 34 ms (2.00x).
Moving only journal open after the old bind location measured 3 ms / 12 ms
(4.00x) at 175dd57, so it did not meet the goal. Final paired control/treatment
results belong in the PR body; a changed timestamp alone is not evidence of a fix.

## Restart handoff and the visible chat

The same class includes work after the socket binds: shutdown used to serialize
22 cancellation-ignoring hub tasks and remote peer teardown, and the pane's
attach waited for the global log restore. The daemon now gives owned tasks one
absolute one-second deadline, stops peers before joining their scopes, and joins
the peer scopes and hub scope concurrently. Startup keeps bulk log loading and
peer adoption behind the local request path; `_acpmux/attach {waitLogs:false}`
reads only the selected chat, while the pane's disk tail cache paints its last
visible rows first.

Session and transport cleanup reserve the last 250 ms of that deadline for
persistence. Store sealing, metadata barriers, audit and cost-ledger drains run
off the runtime. The ledger closes after pending metadata updates. An aborted
session cleanup is joined before sealing, and the daemon's ownership lock stays
with the persistence task until its writers and PID/token cleanup finish. At the
deadline the CLI exits with ownership retained; a new daemon cannot race a
detached writer in the same home. The final diagnostic flush shares the deadline.

The native document resource supplies the selected chat identity before `ready`.
The saved HTML frame remains the preferred presentation. If that frame is absent,
the pane folds the retained event tail before the handshake without opening a
socket or accepting live permissions, queue state or sends. Cache responses later
than the transport's 250 ms cap can still paint while the handshake is pending.
The normal handshake still establishes transport authority; local attach does not
wait for all logs or `startup complete`.

Detectors:

- `hub_tasks_that_ignore_cancellation_are_cut_at_one_shared_deadline` holds 22
  pending hub tasks and verifies one shared `SHUTDOWN_BUDGET` boundary.
- `handoff_persistence_does_not_block_the_runtime_and_still_seals_the_store`
  holds the store seal, verifies the runtime deadline, then verifies the fence,
  retained audit and reopened journal.
- `daemon_peer_gate_waits_for_local_initialization` holds local readiness and
  verifies the deferred daemon gate.
- `restart_to_chat_attach_is_under_two_seconds` runs the real small-home
  daemon twice, sends the cache-first attach after the restart, prints
  `restartChatAttachMs`, and fails above 2,000 ms or 1,000 ms shutdown. The
  ignored god harness runs the same measurement for the small and god shapes.
  This measures a nonempty RPC attach, not a rendered frame.
- `restore-monotonic-trace.test.tsx` withholds native ready and verifies actual
  transcript rows plus `pane.painted` within 2,000 ms, including cache responses
  at 300 and 1,500 ms, wrong identities and late answers after unmount.
- `first-load-after-restart.bench.ts` with `MODE=all GATE=1` measures production
  Chromium frames with the daemon down, slow initialize, and delayed native ready
  with both a saved HTML frame and only a retained tail. It fails above 2,000 ms.
  Its paired baseline uses the same harness and immutable original pane source.

The whole native flow remains a distinct read-back: in the promoted NIGHTLY,
compare `agent_pane.painted` to `first_window_frame_committed`, corroborate the
selected transcript text and capture, and check one daemon stop, shutdown below
one second, and requests-ready before peer dialing. Only the designated app
driver performs that read-back; neither daemon RPC nor browser navigation proves it.
