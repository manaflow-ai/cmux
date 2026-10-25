# macOS matrix results

## Smoke (smoke.py)

One line per major. Build perf-1023-2138-v1 = fleet DEV build job 41616be56ffa91bfe6ad62d4 (commit 86d19391a0c, Linux
pool build). Host aws-m4pro-6 (macOS 26.5.2, Tart 2.40.1, the pinned Cirrus Labs base images), run by hand with
vm.sh (the fleet step needs the runner landed). Smoke times are "VM, not comparable".

| Date (UTC) | Build             | macOS           | Result | Failed steps | Crashes | Hang reports | Faults | Note |
|------------|-------------------|-----------------|--------|--------------|---------|--------------|--------|------|
| 2026-10-24 | perf-1023-2138-v1 | 14.8.7 (23J520) | PASS   | -            | 0       | 0            | 0      |      |
| 2026-10-24 | perf-1023-2138-v1 | 15.7.7 (24G720) | PASS   | -            | 0       | 0            | 0      | the image's "Allow sshd-session to find devices on local networks?" prompt is the guest SSH session, not cmux |
| 2026-10-24 | perf-1023-2138-v1 | 26.6.2          | PASS   | -            | 0       | 0            | 0      | reference major; same sshd-session prompt |
| 2026-10-24 | perf-1023-2138-v1 | 14.8.7          | PASS   | -            | 0       | 0            | 0      | second run, hardened smoke (engine check, exit status 0 at quit, required steps) |
| 2026-10-24 | perf-1023-2138-v1 | 15.7.7          | PASS   | -            | 0       | 0            | 0      | second run, hardened smoke |

## Hang C: macOS 15, watchdog trap in a CEF page window's makeKeyAndOrderFront

- Fleet fuzz seed 21 (30 min), macOS 15.7.7, step 536 (`home.muteConversation`), right after a right-click on a
  tab. The main thread was busy for 10 s; the DEV watchdog trapped.
- Main thread: `TabStripView.menu(for:)` > `PaneController.contextMenu` > `PaneController.select` >
  `FocusCoordinator.send` > `FocusEffectApplier.focusPage` > `setPageFocus` > `AgentActivityPageTab.setFocused`
  > `PageWebView.focusPage` > `CEFPageChromiumPage.setFocused` > `CEFTab.grantFocus` > `cmux_shim_set_focus` >
  CEF `SetFocus` > `-[NSWindow makeKeyAndOrderFront:]` > `makeKeyWindow` > `_changeKeyAndMainLimitedOK:` >
  `-[NSView _windowChangedKeyState]` (about 20 levels) > `NSButtonCell bezelConfigurationInView:`.
- Same family as Hang B: a 10 s stall inside an AppKit key-window change that FocusEffectApplier drives.
- Not macOS-15-only: a 30 min run on 14.8.7 trapped the same way (`PaneController.showSelected` >
  `FocusEffectApplier` > `reclaimKeyFromPageWindow` > `makeKeyWindow` > `_windowChangedKeyState`). 26.6.2 did not
  hang in 30 min. Counts: 15 in 3 of 4 runs, 14 in 1 of 1 thirty-minute runs (0 of 3 short ones), 26 in 0 of 1.
  Issue: https://github.com/manaflow-ai/cmux/issues/24913.

## Crash D: stack overflow in ScreenContentView's canvas camera (macOS 26)

- Fleet fuzz seed 21 (30 min), macOS 26.6.2, step 2330: key ⌥⌘= (`canvasZoomIn`); fleet step
  `766a087fc153d567d40a8098`. Exit status 139, `EXC_BAD_ACCESS` "Thread stack size exceeded due to excessive
  recursion".
- Main thread, repeating: `ScreenContentView.viewDidChangeBackingProperties` > `reconcileAndScroll` >
  `reconcile` > `applyCamera` > `-[NSView setBoundsSize:]` > `_NSViewHierarchyDidChangeBackingProperties` >
  `viewDidChangeBackingProperties` again. `applyCamera` sets a bounds size other than the frame size (the canvas
  zoom), AppKit reports that as a backing change, and the override reconciles, which sets the bounds again.
- The code is unchanged at the feat-cmux-next tip (ScreenContentView.swift and ScreenContentView+Canvas.swift).
- The earlier macOS 26 "dead" at step 2952 (a87b5f47) had no report; with the exit diagnostics this rerun shows a
  real crash at another step. The same seed does not give the same steps after the first death and relaunch.

## Exec (OS probes)

| Date (UTC) | Probe           | macOS  | Exit | Output | Note |
|------------|-----------------|--------|------|--------|------|
| 2026-10-24 | url-root-parent | 14.8.7 | 0    | `"/.."` | issue #4529 behavior |
| 2026-10-24 | url-root-parent | 15.7.7 | 0    | `"/.."` | issue #4529 behavior |
| 2026-10-24 | url-root-parent | 26.6.2 | 0    | `"/"`   | fixed by Apple |

| 2026-10-24 | webkit-js-spi | 14.8.7 | 0 | `_evaluateJavaScript:withSourceURL:inFrame:inContentWorld:withUserGesture:completionHandler:` false; `_evaluateJavaScriptWithoutUserGesture:completionHandler:` true; `_callAsyncJavaScript:arguments:inFrame:inContentWorld:withUserGesture:completionHandler:` false; `_evaluateJavaScript:asAsyncFunction:withSourceURL:withArguments:forceUserGesture:inFrame:inWorld:completionHandler:` true | system WebKit |
| 2026-10-24 | webkit-js-spi | 15.7.7 | 0 | true, true, false, true (same order) | |
| 2026-10-24 | webkit-js-spi | 26.6.2 | 0 | true, true, false, true (same order) | |

Verdict paths, checked by hand on 14.8.7 with throwaway probes: exit 1 is FAIL; a `fatalError` (exit 133) and
a compile error are NO-VERDICT; the results upload in every case.

## Fleet steps (cmux-ci, class vm)

| Date (UTC) | Step | Build | macOS | Suite | Result |
|------------|------|-------|-------|-------|--------|
| 2026-10-24 | 1ec9c6df57b9f89652924bef (aws-m4pro-6) | perf-1023-2138-v1 | 14.8.7, 15.7.7 | smoke | PASS, PASS (first end-to-end fleet run) |
| 2026-10-24 | d73d003fafc81a0e4967dfbb (aws-m4pro-6) | perf-1023-2138-v1 | 14.8.7, 15.7.7 | fuzz seed 21 | 14 PASS; 15 FAIL: watchdog trap at step 563 (see "Hang B") |
| 2026-10-24 | e2c9cf16ed1f173dd31bd02d (aws-m4pro-6) | perf-1023-2138-v1 | 14.8.7, 15.7.7 | fuzz seed 22 | 14 PASS; 15 FAIL: one 5 s hang at step 351 (a right-click), no sample (fixed in 52ea1f1890e) |
| 2026-10-24 | 242004ecce1da33452f500c5 (aws-m4pro-6) | perf-1023-2138-v1 | 14.8.7, 15.7.7 | fuzz seed 23 | PASS, PASS |
| 2026-10-24 | 7eb19ffe6c4f94b5ec8122b1 (aws-m4pro-6) | perf-1023-2138-v1 | 15.7.7 | fuzz seed 21, real 30 min (1972 steps) | FAIL: watchdog trap at step 536 (see "Hang C") |
| 2026-10-24 | 766a087fc153d567d40a8098 (aws-m4pro-6) | perf-1023-2138-v1 | 26.6.2 | fuzz seed 21, real 30 min (2490 steps) | FAIL: stack overflow at step 2330, ⌥⌘= canvasZoomIn (see "Crash D") |
| 2026-10-24 | f2ec771b8246d35edf1deb66 (aws-m4pro-6) | osmatrix-f0468dd2-v1 (tip with the launch fix 5e80b800479) | 14.8.7, 15.7.7 | smoke | PASS, PASS (537ab90cf05 broke launch on 14/15 with a missing Swift runtime symbol; fixed) |
| 2026-10-24 | a87b5f477f4d6270f575f6f6 (aws-m4pro-6) | perf-1023-2138-v1 | 14.8.7, 26.6.2 | fuzz seed 21, real 30 min | 14 FAIL (2329 steps): watchdog trap at step 1401, same family; 26: no hang (3045 steps), one exit at step 2952 with no crash report (the windows were gone: a fuzz-caused exit) |

The seed 21-23 runs asked for `--minutes 30` but stopped at the 600-step default (616 with the tour): 5 to 10
min per major. Fixed after them: `--minutes` without `--steps` now walks until the time is up.

## Hang B: macOS 15, main-thread watchdog trap after Import Settings (not reproduced)

- Fleet fuzz seed 21, macOS 15.7.7, step 563 (`browser.link.openInSplit`). Steps 561 (`import.open`) and 562
  (`tab.screenshot`) had already timed out at the 2 s action deadline; the main thread was busy for 10 s and
  `MainThreadWatchdog.checkHang` called `assertionFailure` ("main thread hang: busy over 10.0 seconds"; a DEV
  build traps).
- Main thread at the trap: `ImportSuggestionsCenter.openSettings` > `SettingsWindowService.show` >
  `WindowController.showWorkspace` > `WorkspaceContentController.didShow` > `FocusCoordinator.send` >
  `FocusEffectApplier.focusPage` > `blurChildWindowPage` > `reclaimKeyFromPageWindow` >
  `NSWindow.makeKeyWindow` > `NSApplication._setKeyWindow:` > `NSKeyValueWillChange` (KVO) > `CFEqual`.
  The sample is one moment of a 10 s busy period, so it shows where the thread was, not that this frame looped.
- Replay of steps 0-563 (by hand, aws-m4pro-6): no hang on 15.7.7 or 26.6.2. Not deterministic from the steps;
  not shown to be specific to macOS 15. The .ips, the stderr and the steps are in the step's results
  (`os-matrix-results.tgz` of d73d003f, `15/`).

## Fuzz (fuzz.py)

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
| 2026-10-24 | perf-1023-2138-v1 (DEV, aws-m4pro-6, Tart 2.40.1, base images) | 14.8.7 | 11, `--minutes 15` | 616 | 0 | 0 | 0 | 0 | max ping 34 ms (VM, not comparable) |
| 2026-10-24 | perf-1023-2138-v1 (DEV, aws-m4pro-6, Tart 2.40.1, base images) | 15.7.7 | 11, `--minutes 15` | 616 | 0 | 0 | 0 | 0 | max ping 35 ms (VM, not comparable) |

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
