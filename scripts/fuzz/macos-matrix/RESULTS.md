# macOS matrix fuzz results

One line per run. Steps include the 16-step feature tour. "Dead" counts app deaths (each one restarts the app).
Faults are unified-log faults of the cmux processes. Host: cmux15 (macOS 27.0.1, Tart 2.41.1, Cirrus Labs vanilla
images). Nightly = cmux NEXT nightly 3934457894701 (commit ba43ccd). The DEV builds are fleet builds of
the two commits before their rebase (70a778e94d7 = 13a59eca442, 5babe8fcde1 = a9c91e7d417 on feat-cmux-next).

| Date (UTC) | Build                  | macOS  | Seed / input                    | Steps | Crashes | Hangs > 1 s | Dead | Faults | Note |
|------------|------------------------|--------|---------------------------------|-------|---------|-------------|------|--------|------|
| 2026-10-20 | nightly                | 14.8.7 | 2                               | 516   | 0       | 0           | 0    | 0      |      |
| 2026-10-20 | nightly                | 15.7.7 | 2                               | 516   | 0       | 0           | 0    | 0      |      |
| 2026-10-20 | nightly                | 14.8.7 | 3                               | 816   | 1       | 0           | 1    | 0      | crash A at step 113 (Close Window) |
| 2026-10-20 | nightly                | 14.8.7 | replay seed 3, steps 0-113      | 114   | 1       | 0           | 1    | 0      | crash A, every replay |
| 2026-10-20 | nightly                | 14.8.7 | `--minimize`                    | 3     | 1       | 0           | 1    | 0      | minimal: New Incognito Window, Close Window |
| 2026-10-20 | nightly                | 14.8.7 | `repros/incognito-close-14.jsonl` | 2   | 1       | 0           | 1    | 0      | crash A in 6 of 7 replays |
| 2026-10-20 | nightly                | 15.7.7 | `repros/incognito-close-14.jsonl` | 2   | 0       | 0           | 0    | 0      | no crash on 15 |
| 2026-10-20 | nightly                | 15.7.7 | 4                               | 1016  | 0       | 0           | 0    | 0      | see "Action stall" |
| 2026-10-20 | nightly                | 26.6.2 | 5                               | 616   | 0       | 0           | 0    | 0      |      |
| 2026-10-20 | nightly                | 27.0   | 7                               | 616   | 0       | 0           | 0    | 0      |      |
| 2026-10-20 | 70a778e94d7 (repro only, DEV) | 14.8.7 | `repros/incognito-close-14.jsonl` | 2 | 1   | 0           | 1    | 0      | crash A before the fix |
| 2026-10-20 | 5babe8fcde1 (fix, DEV) | 14.8.7 | `repros/incognito-close-14.jsonl` | 2   | 0       | 0           | 0    | 0      | fixed |
| 2026-10-20 | 5babe8fcde1 (fix, DEV) | 14.8.7 | replay seed 3, steps 0-113      | 114   | 0       | 0           | 0    | 0      | fixed |
| 2026-10-20 | 5babe8fcde1 (fix, DEV) | 14.8.7 | 6                               | 816   | 0       | 0           | 0    | 0      | 1 disk-write report (see below) |
| 2026-10-20 | nightly                | 15.7.7 | 8 (default browser skipped)     | 616   | 0       | 0           | 0    | 0      |      |

## Crash A: macOS 14, swift_task_dealloc abort on Close Window

- OS: macOS 14.8.7 only (15.7.7, 26.6.2 and 27.0 do not crash on the same steps).
- Stack (main thread): `abort` < `swift_Concurrency_fatalError` < `swift_task_dealloc` < cmux +0x5414 (a folded
  async partial-apply resume) < `completeTaskWithClosure`. Stderr: "freed pointer was not the last allocation".
- Steps: New Incognito Window (⌥⇧⌘N), then Close Window (⌃⌘W).
- Cause: `TaskLocal.withValueInTask` (CmuxNextActions) bound the action's task local inside a task started
  with the runtime's `Task.startOnMainActor` below macOS 26 (57d5c1d5fa2). `performClose` spins a nested run
  loop that runs other main-actor jobs (here the incognito close confirmation task). After them the macOS 14
  runtime has no current task, so the task-local pop and the task's frame free go to the no-task allocator.
  Found with an interposer trace of `swift_task_alloc`/`swift_task_dealloc` and the task-local push/pop
  (`FUZZ_DYLIB`).
- Fix: a9c91e7d417. Use the `startOnMainActor` task only from macOS 15.4 (where the stop-lookup marker it
  guards against exists); below 15.4 bind the task local directly.

## Action stall (macOS 15, not a crash)

`palette.makeDefaultBrowser` opens the system's "change your default web browser" dialog. No app input answers
it, and the action stays `in_progress`. From step 793 on (after Rename Space opened), every socket
`action.run` timed out `not_run` while the main thread still answered pings. The fuzzer now skips the
default-browser action. The `not_run` stall itself has no root cause yet.

## Disk writes of the bundled cmux-tui (macOS 14, resource report, not a crash)

During the macOS 14 seed 6 run, macOS wrote a disk-writes resource report (`.diag`) for the bundled daemon
(`Contents/Resources/bin/cmux`): 2.15 GB of writes in 465 s (4.6 MB/s), footprint 45 MB to 179 MB. Heaviest stack:
`cmux_tui_core::journal_ingress::run` > `Mux::commit_session_journal_events` >
`RegistryConnection::append_journal_ingress_events_with_deadline` > `rusqlite::Connection::execute_batch` >
SQLite WAL `pwrite`. The fuzzer typed terminal commands with large output (`yes | head -2000`, 300-character
lines) into a few terminals. The fuzzer first counted this report as a crash; it now records `.diag` files as
`resource-report`.
