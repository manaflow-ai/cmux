# The daemon outranks the work it supervises (RFD 0049 R3)

PR manaflow-ai/cmux#51052 (draft). Agents were lowered (`qos.rs`, `session_scope.rs`), but the daemon
was never raised, so on a host loaded by builds that are not acpmux's children it competed as an
equal.

- `acpmux.service` (`cli/hosts.rs` `SYSTEMD_UNIT`) gains `CPUWeight=1000` and `IOWeight=1000`. The
  previous text joins `OLD_SYSTEMD_UNITS`, so `host update` and `daemon service install` rewrite it.
  `IOWeight` does nothing where the user manager has no `io` controller (stock systemd).
- `daemon run` asks for nice -5 (then 0 from an inherited positive nice) on the main thread before
  the runtime starts (`daemon_priority.rs`, called from `cli/entry.rs` `runtime`). Without
  `CAP_SYS_NICE` or `RLIMIT_NICE` this is refused, and the daemon starts as before. On macOS every
  runtime thread runs at `QOS_CLASS_USER_INITIATED`.
- Agent hosts, task runners (`qos::enter`) and harnesses (`cpu_class::start_at_normal`) are put back
  to nice 0 or above, so they never inherit a negative nice the daemon took.
- At start the daemon logs one line, `daemon priority: nice …; cpu.weight …; io.weight …; cgroup …`
  (macOS: `thread qos`, `base priority`). Each knob reads took, refused (why) or n/a. A daemon that a
  CLI under an agent spawned detached (Linux, no unit) says `inherited nice N from caller`.
