# Notice to PL-acpmux: socket-ready must precede durable setup (2026-11-12)

PR #42177 fixes the daemon startup boundary measured by `tests/god_daemon.rs`.
The Unix listener and the `socket ready` gauge now start immediately after
`Hub::new_loading_with_wireguard`; forum, outbox, watches, peers, WebSocket
and chat-log work remains behind the startup gate. This keeps a client able to
ask for status while per-chat durable work is still running.

- Detector: `crates/acpmux/tests/god_daemon.rs` runs the same small and god
  homes and records `gauges.startup` marks, including `socket ready`. Compare
  the god/small values for that mark; a ratio above 1.2 means startup work is
  scaling with chat size. The lifecycle test
  `socket_answers_before_post_hub_setup_finishes` holds post-listener setup and
  asserts `_acpmux/status` answers with `ready: false` before the public ready
  line.
- Root cause: `daemon::run` called `hub.begin_startup` and spawned the Unix
  serving task only after durable setup, so the benchmark's socket-ready mark
  included work proportional to the home and its chat logs.
- Invariant: bind and serve the local socket before any per-home or per-chat
  durable setup; keep the public ready line and `ready: true` gated until that
  setup finishes.
- Verification: baseline from cmuxterm-hq#10084 was small 24 ms, god 31 ms
  (1.29x). Record the exact-head post-fix values in PR #42177 after the hosted
  Linux benchmark completes.
