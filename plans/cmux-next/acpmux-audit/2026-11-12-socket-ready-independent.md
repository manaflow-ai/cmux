# Notice to PL-acpmux: socket-ready must precede durable setup (2026-11-12)

PR #42177 fixes the daemon startup boundary measured by `tests/god_daemon.rs`.
The Unix endpoint and the `socket ready` gauge now begin at the bind boundary,
before WebSocket, hub, store or per-chat setup; the serving task and public
ready line remain behind the startup gate. This keeps a client able to ask for
status while per-chat durable work is still running.

- Detector: `crates/acpmux/tests/god_daemon.rs` runs the same small and god
  homes and records `gauges.startup` marks, including `socket ready`. Compare
  the god/small values for that mark; a ratio above 1.2 means startup work is
  scaling with chat size. The lifecycle test
  `socket_answers_before_post_hub_setup_finishes` holds post-listener setup and
  asserts `_acpmux/status` answers with `ready: false` before the public ready
  line.
- Root cause: `daemon::run` originally marked socket-ready only after hub
  construction and durable setup, so the benchmark's mark included work
  proportional to the home and its chat logs. The corrected boundary is the
  successful Unix bind; the listener then starts serving once the hub exists.
- Invariant: bind the local socket before any per-home or per-chat durable
  setup; keep serving, the public ready line and `ready: true` gated until the
  hub startup work is ready.
- Verification: baseline from cmuxterm-hq#10084 was small 24 ms, god 31 ms
  (1.29x). Record the exact-head post-fix values in PR #42177 after the hosted
  Linux benchmark completes.
