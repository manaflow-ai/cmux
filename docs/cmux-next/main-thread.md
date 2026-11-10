# The main thread: borrowing Chrome's model

cmux NEXT keeps its main thread free the way Chrome keeps its browser UI thread free. A hang, the
"Application Not Responding" label in the Dock, or a row that stutters as it opens almost always has
one cause: something ran on the main thread that had to wait. This page states the rule we follow,
where work goes instead, and how the app catches code that breaks it. Contributors read it before
writing code that does I/O, waits, or runs for long.

> Leo, 2026-11-10: "lawrence was talkin bout how we wanted to fix the root cause of a lot of this
> main thread stuff which was to borrow chrome's model"
>
> Leo, 2026-11-10: "let's write some of that stuff down... maybe even in the docs? getting inspired by
> chrome or whatever"

## What Chrome does

- **The UI thread never blocks.** Chrome's browser UI thread handles input and paints. Disk, network,
  waits for other processes and long computation run elsewhere, because a busy UI thread is latency
  the person sees ([Threading and Tasks in Chrome][tt]).
- **Work is posted to sequences, and the answer comes back as a task.** A `SequencedTaskRunner` runs
  its tasks one at a time, in order, on whichever pool thread is free. `PostTaskAndReply` runs the work
  there, then posts the reply back to the thread that asked ([Threading and Tasks in Chrome][tt],
  [FAQ][faq]). Messages between sequences take the place of shared memory and locks.
- **The rule is enforced in code.** `base::ScopedBlockingCall` marks every call that may block, and
  `base::ThreadRestrictions` asserts in debug builds when one runs on a thread that disallows
  blocking ([scoped_blocking_call.h][sbc], [thread_restrictions.h][tr]). `HangWatcher` watches threads
  for hangs and reports them with stacks ([hang_watcher.h][hw]).
- **Process isolation.** A renderer, GPU or utility process that slows down can't freeze the browser
  process, because the browser never waits on it synchronously.

## The same rule in cmux NEXT

**The main thread does three things:**
- dispatching the person's input;
- the smallest change to visible state;
- the Core Animation commit.

Anything else that has to touch the screen runs as a task under a per-frame budget, about 4 ms of
each frame in all (`MainWorkClass`, `MainFrameBudget`).

**The main thread never waits on:**
- disk, network or a socket;
- spawning a process, or waiting for one;
- a synchronous call into another process;
- a DNS lookup;
- a semaphore, group or condition;
- a lock held across work;
- a nested run loop;
- long CPU work (large JSON decodes, image decodes).

**Where that work goes instead:**

| Work | Where it runs |
|---|---|
| Daemon I/O | A reader thread and a write queue per connection. Events coalesce off main, and one batch per frame applies them. |
| Disk | `BackgroundWork`'s `.files` lane, or a store's own serial queue |
| Synchronous system calls | The `.system` lane, at most 6 at once (Chrome's limit for system DNS lookups) |
| CPU-heavy work | The `.cpu` lane: performance cores minus one, never blocking |
| Processes | `AsyncProcess`, where no thread waits |
| Cloud and network | Async calls on actors on the cooperative pool, which never blocks |
| WebKit views | Script messages arrive on main. The handler checks the sender, hands the work off and answers through `replyHandler` when it is done. |
| Chromium (CEF) views | Chromium's UI thread is our main thread, pumped in 2 ms slices. Its IO thread and its renderer, GPU and utility processes are Chromium's own. |
| Separate processes | The terminal daemon, the agent daemon, WebContent and Chromium renderers. A slow one delays only its own reply. |

**The reply pattern** (Chrome's `PostTaskAndReply`):

```swift
let text = try await work.run(.userVisible, mayBlock: .files) { try String(blockingContentsOf: url) }
guard generation == current else { return }  // drop a stale reply
model.apply(text)
```

Work started from another thread reaches the screen through the frame scheduler
(`FrameBatchQueue`, `MainDelivery`, `AfterFrameCommit`), never through a bare hop onto the main actor.

## How it is enforced

| Chrome | cmux NEXT |
|---|---|
| `ScopedBlockingCall` | Every blocking primitive goes through a checked seam (`FileManager.checked`, `Data(blockingContentsOf:)`, `blockingWait`, `blockingWaitUntilExit` and others). Each seam runs its call inside `blockingCall(kind)`, which records the call site (`#fileID:#line`). |
| `ThreadRestrictions` | In Debug, bench and Nightly builds, a seam call on the main thread is recorded once per call site (Debug menu, `debug.blocking`, the unified log). `CMUX_BLOCKING_TRAP=1` stops at the call. |
| `HangWatcher` | `MainThreadWatchdog` samples the main thread's stack for any stall over 50 ms, and reports a hang of 2 s or more while it is still running. When the main thread is inside a checked call, the record and the hang file name it: `blocking call: file-io at Module/File.swift:42`. A nested run loop that sits with no input taken also counts as a hang. |
| Presubmit checks | The pre-push guardrails refuse new blocking calls in main-actor code, raw primitives that skip a seam, new hops onto the main actor that skip the scheduler, and unlisted threads. |

The full design, with every thread's owner, QoS and bound, is
[plans/cmux-next/threading-model.md](../../plans/cmux-next/threading-model.md).

[tt]: https://chromium.googlesource.com/chromium/src/+/main/docs/threading_and_tasks.md
[faq]: https://chromium.googlesource.com/chromium/src/+/main/docs/threading_and_tasks_faq.md
[sbc]: https://chromium.googlesource.com/chromium/src/+/main/base/threading/scoped_blocking_call.h
[tr]: https://chromium.googlesource.com/chromium/src/+/main/base/threading/thread_restrictions.h
[hw]: https://chromium.googlesource.com/chromium/src/+/main/base/threading/hang_watcher.h
