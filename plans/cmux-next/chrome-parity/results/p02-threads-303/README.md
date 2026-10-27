# p02-threads-303: RUN-5 suites (T1r), first run

Head: cp/p02-threads-303 at the fixer's merge of origin/perf/chrome-parity
(96960323425; has 210, 220 and 225), sweep scripts at 706b8c3e0f1. Not landed
there: 211, 221 and 231.
Their branches do not merge cleanly into this head (211: websocket_listener.rs;
231: chief_brains.rs, mux/lifecycle.rs, server/connection_frame.rs,
terminal_host_runtime/shared/host_serve.rs), so this run does not include them.
Host: 360-core Linux VM, Debug, ghostty-next at 723c4ab93e7.

Command: `python3 cmux-tui/scripts/daemon-blocking-sweep.py suites --binary-timeout 300`
(cargo test --no-fail-fast -p cmux-tui-core -p cmux-tui, record mode and then panic mode).

## Verdict: RUN-5 fails

```
RUN-5 fail panic_only_failures=254 shared_failures=215 blocking_panics=15 sites=21 mq13_tasks=204
```

- `shared_failures`: tests that fail in record mode too (environment and base
  failures on this VM: cloud, remote runtime, browser CLI, load). They do not
  count against RUN-5.
- `panic_only_failures`: tests that fail only in panic mode. Most are daemon
  integration tests: a request or output thread panics and the test waits for
  a reply with no timeout. Binaries stopped after 300 s are rows with
  `<no test result: ...>` in `run5-suites.txt`.
- `blocking_panics`: the 15 distinct sites that panicked outside test code.
  They are the first fix tasks (each blocks many tests):
  - `server/bounded_outbound.rs:469` condvar-wait on `mux-line-out`
  - `server/origin_gate.rs:458` fs on `mux-conn`
  - `server/line_connection.rs:165` join on `mux-conn` / `mux-remote-conn`
  - `server/cmd_attach.rs:525` recv on `mux-attach-out`
  - `surface/directory.rs:104, 201` sqlite on `surface-N-reader`
  - `surface/construct.rs:319` process-spawn on `mux-pty-input`
  - `session/mod.rs` (8 sites) sqlite on `mux-pty-input`

## Files

- `mq13-record-sites.json`: the MQ-13 list, record mode, one row per
  (location, kind, thread class). 204 tasks and 10 fixtures. Most rows are
  sqlite on `mux-conn` (resource_router, server, state, history_ops, git_ops,
  mux) and on `surface-N-host`; 221 and 231 own most of those files.
- `mq13-panic-sites.json`: the sites panic mode reached before the first panic
  of each process.
- `run5-suites.txt`: every SUITE, SWEEP and RUN-5 line of the run.

## Not run

- The T3 half (`daemon-blocking-sweep.py bench`, perf-10x-lifecycle
  part=daemon against the merge base) runs only on the fleet. It is not run.
- Rerun both halves after 211, 221 and 231 land and the blocking-panic sites
  above are fixed.
