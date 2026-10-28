# Chrome-parity priorities (2026-10-28)

Sources: Lawrence's platform strategy (2026-10-28) and the lead's decisions from cmux-ad
(perf-faster, fundamentals-perf). This file sets the order of work; the merge pipeline
reads the same order from felt.txt (first) and deferred.txt (last).

## Platform strategy

- The Swift app stays the Mac product now. The Chromium fork is the product on Linux
  and Windows, and later on the Mac as well.
- Ghostty is the terminal on every platform. A ghostty-next change made for the Mac must
  keep the embedded API working for the fork: Linux OpenGL with dmabuf, Windows, and
  macOS Metal, because the fork embeds the same pin.

## Order of work

1. Felt latency on the Mac: the key path, a new terminal or tab, a split, a workspace
   switch and launch. Rank by the milliseconds a task removes on the first-5s-typing
   and key-to-frame benches, measured on an optimized build. This includes the
   optimized dogfood build and the landing slices into feat-cmux-next.
2. Work that carries over to the Chromium fork: the daemon (cmux-tui, p05 IPC, p02
   daemon threads, p07 daemon memory), ghostty-next (rendering, input latency, wakeups),
   WebUI pages (p13), the perf lab and benches (p12), the oracle and journeys (p15), and
   the Rust parts of observability (p09).
3. Lower priority: long AppKit-only programs whose payoff comes after the move,
   chiefly p11-codebase (the CmuxNextApp decomposition), and large AppKit refactors that
   do not cut felt latency. No new p11 waves start; finished branches still merge when
   the train has spare slots.

## Integration before writing

No new write wave starts while more than 100 written branches wait to merge. Running
agents finish their current task. Freed fleet time goes to the felt queue and the train.

## Speed claims

Every speed claim names the bench and compares an optimized build with trunk and with
classic cmux, on the same host.
