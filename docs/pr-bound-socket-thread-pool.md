## Summary

Replace unbounded `Thread.detachNewThread` for socket client handlers with a
bounded concurrent `DispatchQueue` and semaphore, preventing runaway thread
accumulation when the main thread is temporarily unresponsive.

## Problem

Each incoming socket connection (e.g. `cmux claude-hook` calls from Claude Code
hooks) spawns a new `NSThread` via `Thread.detachNewThread`. When the main
thread stalls — for example during a heavy SwiftUI render pass — handler threads
that call `@MainActor`-isolated methods block on `DispatchQueue.main.sync`.
Because thread creation is unbounded, these blocked threads pile up indefinitely.

In a real incident this produced **150+ blocked threads** and a **10.93 GB**
memory footprint, making the app permanently unresponsive and unrecoverable
without a force kill.

## Fix

- Add a private concurrent `DispatchQueue` (`com.cmuxterm.socket-clients`) for
  client handler dispatch.
- Gate handler execution behind a `DispatchSemaphore(value: 64)` to cap
  concurrent handlers.
- Handlers that cannot acquire a slot within 30 seconds return `ERROR: Server busy`
  and close the connection, applying backpressure to callers instead of
  accumulating memory.
- The accept loop's own `Thread.detachNewThread` (single long-lived thread) is
  unchanged.

## Test plan

- [ ] Verify normal `cmux` CLI commands still work (ping, report_*, etc.)
- [ ] Simulate main thread stall with a debug sleep and confirm thread count
      stays bounded
- [ ] Confirm "Server busy" response when all slots are exhausted
- [ ] Run existing socket tests (`tests_v2/`) against a tagged debug build
