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

Detectors:

- `hub_tasks_that_ignore_cancellation_are_cut_at_one_shared_deadline` holds 22
  pending hub tasks and verifies one shared `SHUTDOWN_BUDGET` boundary.
- `restart_to_chat_visible_is_under_two_seconds` runs the real small-home
  daemon twice, sends the cache-first attach after the restart, prints
  `restartChatVisibleMs`, and fails above 2,000 ms. The ignored god harness
  runs the same measurement for the small and god shapes.
