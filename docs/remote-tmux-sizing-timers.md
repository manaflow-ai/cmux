# Remote-tmux mirror sizing: why two timers are load-bearing

The mirror's feed-forward sizing is event-driven everywhere it can be: the
pushed client size is a pure function of container pixels + layout structure +
measured constants, and pane geometry publishes only from verified `list-panes`
rects. Two timers remain in `RemoteTmuxControlConnection`. Neither is a race
repair; each waits on a real-world quantity that emits no observable event.
This doc records the evidence so the next person doesn't "clean them up" into a
regression — a mistake that once passed the full unit + e2e suite and was only
caught in review.

## The attach redraw kick gap (`attachRedrawKickGapMs`, ~350 ms)

### What the kick does

Attaching the mirror usually leaves the remote window at the size cmux itself
left behind, so the size push is a no-op — no pane resize, no `SIGWINCH`, and a
running TUI keeps its stale pre-attach frame. The kick forces the repaint a real
attach would: push the client one row shorter, then push the true size back. The
window resizes twice, the app gets its `SIGWINCH`, it repaints.

### Why the restore cannot be event-gated

The obvious "improvement" is to drop the timer and send the restore when an
event confirms the shrink applied. There is no such event.

- Layout recomputation **is** visible to control clients (`%layout-change`,
  `list-panes`) and happens immediately when the size command is processed.
- The `SIGWINCH` the kick exists to force is the pane **PTY ioctl**, which tmux
  defers behind its own internal resize-coalescing timer (~250 ms). That timer
  emits **nothing** on the control channel when it expires.

So every control-visible event confirms the wrong fact (layout recomputed), not
the fact that matters (ioctl delivered). Gating the restore on a layout
publication fires it one control-channel round trip after the shrink —
milliseconds on a local link — well inside the coalescing window, so tmux
collapses shrink+restore into a net-zero change and delivers no `SIGWINCH`. The
stale frame the kick exists to fix silently returns. (A per-window confirmation
predicate is also spuriously satisfiable by an unrelated window that already
sits at the shrunken height.)

The restore must therefore wait a fixed interval that exceeds tmux's coalescing
window. The timer is correctness-neutral otherwise: it re-checks the size ledger
before both sends, so a user resize during the gap supersedes cleanly.

### Exploring it by hand

The coalescing is real but awkward to observe cleanly — worth knowing the
confounds before you trust a quick experiment:

- **POSIX already coalesces signals.** Two `SIGWINCH`s delivered before the
  handler runs collapse to one at the OS level, independent of tmux. A counter
  in a `trap` cannot distinguish "tmux coalesced the resizes" from "the kernel
  merged two signals."
- **The path matters.** `resize-window` forces an immediate layout recompute and
  is *not* the client-size path the kick uses; only `refresh-client -C` (from an
  attached client) exercises tmux's client-size coalescing.
- **You need a real client.** `refresh-client -C` sets the issuing client's
  size, so a faithful probe must hold a control-mode client open and drive its
  size — and even then the observation is timing-sensitive enough that a scripted
  assertion is unreliable (which is why this is documented, not encoded as a
  test).

A rough manual exploration, scoped to a throwaway socket so it never touches
your own tmux servers:

```bash
export TMUX_TMPDIR="$(mktemp -d)"           # isolated server; never the default socket
tmux new-session -d -s probe -x 80 -y 24
# A foreground bash child records each delivered resize. NOT an interactive
# shell: an interactive zsh/bash owns SIGWINCH for its line editor and never
# runs a user WINCH trap mid-loop.
tmux send-keys -t probe:0 \
  'bash -c '\''trap "echo WINCH $(stty size)" WINCH; while :; do sleep 0.2; done'\''' Enter

# Change the window size and watch which changes reach the pane. Compare a
# back-to-back shrink+restore against a gapped one; the gapped pair is the
# behaviour the kick relies on.
tmux resize-window -t probe:0 -y 23; tmux resize-window -t probe:0 -y 24   # back-to-back
sleep 1; tmux capture-pane -t probe:0 -p | grep '^WINCH'

tmux kill-server                              # tears down only the isolated server
```

Treat the output as directional, not proof — the confounds above mean the clean
statement of the fact lives in this doc, not in the shell.

## The size-send debounce (`clientSizeDebounceMs`, 180 ms)

SwiftUI layout settle makes the rendered grid oscillate (~15 distinct sizes in
~1.3 s at attach). Un-debounced, each becomes a `refresh-client -C` → a
`SIGWINCH`/redraw storm on the remote per attach. The debounce coalesces them
into one send after the size stops changing.

This timer is a **rate limiter**, not a correctness dependency: the size ledger
(`lastClientSize` / `lastWindowSizes`) is written synchronously before any
deferral, dedup makes a late or duplicate send idempotent, and the reconnect
reseed replays the ledger — so the pushed size converges even if the timer never
fires. Reply-gated coalescing is not a substitute: it self-clocks to the control
channel's round trip (milliseconds locally), which would forward nearly every
oscillation frame and reinstate the storm. The oscillation has no terminating
event to gate on.
