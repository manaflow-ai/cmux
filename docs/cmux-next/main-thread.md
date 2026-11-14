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

The main thread does three things:
- dispatching the person's input;
- the smallest change to visible state;
- the Core Animation commit.

Disk, network, processes, waits and long work run on named lanes and queues off the main thread, and their
results come back to it the way `PostTaskAndReply` does:

```swift
let text = try await work.run(.userVisible, mayBlock: .files) { try String(blockingContentsOf: url) }
model.apply(text)
```

The rule is enforced in three places:
- The checked seams record a blocking call on the main thread (Chrome's `ScopedBlockingCall`).
- `MainThreadWatchdog` samples stalls and reports hangs (Chrome's `HangWatcher`).
- The lints refuse new blocking calls in main-actor code.

The contributor guide holds the full rule: where each kind of work goes, how WebKit and Chromium views fit,
and every check. See
[skills/cmux-architecture/references/main-thread-model.md](../../skills/cmux-architecture/references/main-thread-model.md).
Each thread's owner, QoS and bound are listed in
[plans/cmux-next/threading-model.md](../../plans/cmux-next/threading-model.md).

[tt]: https://chromium.googlesource.com/chromium/src/+/main/docs/threading_and_tasks.md
[faq]: https://chromium.googlesource.com/chromium/src/+/main/docs/threading_and_tasks_faq.md
[sbc]: https://chromium.googlesource.com/chromium/src/+/main/base/threading/scoped_blocking_call.h
[tr]: https://chromium.googlesource.com/chromium/src/+/main/base/threading/thread_restrictions.h
[hw]: https://chromium.googlesource.com/chromium/src/+/main/base/threading/hang_watcher.h
