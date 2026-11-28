---
name: cmux-debugging
description: "Debug logging, hang diagnostics, profiling, runtime pitfalls, typing-latency-sensitive paths and OS-version repros for cmux. Use when adding debug probes, diagnosing UI/runtime issues or touching terminal rendering."
---

# cmux Debugging

## Logs

App modules in `Packages/macOS/CmuxNext` log through
`Logger(subsystem: "com.cmuxterm.app.next", category: "<area>")`. Reuse an existing
category (`daemon`, `daemon.attach`, `terminal`, `hangs`, `cloud.link`, ...) and
put dynamic details after a stable message prefix so filtering stays practical.

```bash
log stream --level debug --predicate 'subsystem == "com.cmuxterm.app.next"'
```

Most probes belong to a dogfood debug loop and are removed before merge. Never log
secrets or terminal content.

## Hangs

`MainThreadWatchdog` (`CmuxNextControl/Diagnostics`) records every main-thread
stall over 50 ms with a stack sample and logs it under the `hangs` category. The
control socket exposes the ring buffer as `debug.hangs` and the main-actor work
queue as `debug.queue`; `scripts/cmux-next/bench_cli_storm.py` is a client.

## Profiling

Profile a tagged build by attaching to its pid (`xctrace record --attach <pid>`, `sample <pid>`). Never use `xctrace --launch` or Instruments' launch mode on any cmux bundle, and never quit, kill or relaunch the user's running cmux (`com.cmuxterm.app`): it holds their live agent sessions, and on 2026-09-26 a suspected profiler relaunch took five of them down.

## Runtime pitfalls

- The main thread never waits. `scripts/cmux-next/check-concurrency.sh` enforces the banned calls; see [architecture 5a](../../plans/cmux-next/architecture.md).
- Do not add a manual `ghostty_surface_draw` loop; rely on Ghostty wakeups and its renderer to avoid typing lag. Display links run only while an animation or scroll is active and stop themselves.
- Custom drag-and-drop UTTypes must be declared in `Resources/Info.plist` under `UTExportedTypeDeclarations`.
- Foundation, AppKit, SwiftUI, and WebKit semantics change between macOS majors. Test on the reporter's macOS before declaring a user repro disproven.

## Detailed references

- [references/runtime-pitfalls.md](references/runtime-pitfalls.md): read before touching terminal rendering, drag/drop, or OS-version-sensitive code.
