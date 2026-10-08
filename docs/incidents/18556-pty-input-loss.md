# Local PTY input loss after sleep/wake (#18556)

The report describes one long-lived local terminal continuing to render child
output after a Mac sleep/wake cycle while keyboard input and `cmux send`/
`send-key` no longer reach the child PTY. The report is from cmux 0.64.22
(build 102), macOS 26.6.2 on an M3 Pro. Local reproduction has not been
obtained.

## What the current evidence establishes

Keyboard input enters `GhosttyNSView.sendGhosttyKey`; socket input enters
`TerminalSurface.sendInputResult`, `sendNamedKey`, or `sendTextResult`. These
paths call `ghostty_surface_key`, `ghostty_surface_text_input`, or
`ghostty_surface_text` and return once the native API accepts the event. The
return value does not mean that the child consumed the bytes.

For an exec surface, Ghostty's `Surface.keyCallback` queues a message on the
per-surface `termio.Mailbox` and calls `Mailbox.notify()`. The I/O thread waits
on an xev async watcher, drains that mailbox, and only then schedules the PTY
write in `termio.Exec.queueWrite`. PTY output is read by a separate reader
pipeline. Therefore output can remain live while the input writer is asleep.

The report's `FIONREAD == 0`, healthy child, and `sample` showing the I/O
threads in `kevent64` place the failure after cmux's native input call and
before `Exec.ttyWrite`. The strongest hypothesis is a lost or non-rearmed
per-surface xev/Mach-port mailbox wakeup during sleep/wake. A stale cmux
surface pointer is a weaker hypothesis: both input entrypoints fail, while the
surface continues to render, and the report did not observe a surface restart.

## Opt-in capture for the next reproduction

DEBUG builds now accept `CMUX_TRACE_PTY_INPUT=1`. The debug log records, for
each keyboard or socket native input call:

- channel and key/text byte count;
- native surface pointer and `runtimeSurfaceGeneration`;
- native return/handled value and call duration.

The power observer records `workspace.willSleep` and `workspace.didWake`, and
the app records every live surface's pointer, generation, and pending socket
queue before and after wake rearming. These probes are DEBUG-only and do not
retry or reset the runtime.

Reproduce with a tagged DEBUG build and collect the debug log plus a sample of
the tagged process immediately after the first failed input:

```sh
CMUX_TRACE_PTY_INPUT=1 CMUX_TAG=pty-input-18556 scripts/reload.sh --tag pty-input-18556
# Keep the long-lived TUI running, sleep/wake the Mac, then send one keyboard
# key and one `cmux send-key`/`cmux send` request to the affected surface.
sample "$(pgrep -f 'cmux.*pty-input-18556' | head -1)" 10 -file out/perf-incident-20261008-pty-input/sample-after-failure.txt
```

Interpretation:

1. If a dispatch and native-return pair is present with the same pointer and
   generation on both keyboard and socket input, cmux routing and the runtime
   handle are not where the bytes disappear.
2. If the pointer or generation changes, or a stale-surface lifecycle event is
   logged, investigate runtime replacement/teardown ordering instead.
3. If dispatch/return pairs are present, output callbacks continue, the
   surface identity is stable, and the I/O thread remains in `kevent64`, the
   next proof must cover Ghostty's mailbox notify, mailbox drain, and
   `ttyWrite` completion. That requires Ghostty-side debug logging or a
   targeted Ghostty harness; an arbitrary wake retry would not establish a
   fix.

The current branch has no fix claim. The next implementation decision should
be based on this capture: repair the Ghostty wake/rearm owner only if the
mailbox remains queued while its xev watcher is idle; otherwise follow the
observed lifecycle or PTY-write failure.

