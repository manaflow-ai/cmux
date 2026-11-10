# The main thread never blocks

Read this before you write anything in `Packages/macOS/CmuxNext` that may block: a file read or write, a pipe,
a socket, a process launch or wait, a semaphore, a sleep, a synchronous system call. It's the short, agent-facing
version; [plans/cmux-next/threading-model.md](../../../plans/cmux-next/threading-model.md) is the full, enforced
spec (every thread and queue, its bound, the reviewed allowances).

The design is borrowed from Chrome's threading model. Chrome's UI thread never blocks: blocking code says so with
`base::ScopedBlockingCall`, `base::ThreadRestrictions` asserts on the threads that may not block, the few
reviewed exceptions are a `ScopedAllowBlocking` friend list, and work posts to the thread pool with task traits
(`TaskPriority`, `MayBlock`). cmux has the same pieces under Swift names.

## The pieces

| Chrome | cmux | Where |
| --- | --- | --- |
| `ScopedBlockingCall` + `ThreadRestrictions` | The checked seams: `FileHandle.blocking*`, `blockingRead/Write/Recv/Send`, `Process.blockingRun` / `blockingWaitUntilExit`, `DispatchSemaphore.blockingWait`, `DispatchQueue.blockingSync`, `Data(blockingContentsOf:)`, `FileManager.checked`. Each calls `assertBlockingAllowed(kind)` first | `CmuxNextCompat/Threading` |
| `ScopedAllowBlocking` | `allowBlocking(.reason) { ... }`, one `static let` per reviewed `BlockingAllowance` (today `terminate`) | `BlockingAllowance.swift`, the spec's "Reviewed blocking allowances" table |
| `PostTask` with `MayBlock` | `work.run(priority, mayBlock: lane) { ... }` (await the result) and `work.post(...)` (fire and forget) on `BackgroundWork` | `CmuxNextWakeups/BackgroundWork.swift` |
| `TaskPriority` | `WorkPriority`: `.userBlocking`, `.userVisible`, `.bestEffort`, `.idle` | `CmuxNextWakeups` |
| The IO thread and worker pool | `BlockingLane`: `.files` (disk, serial per priority), `.system` (`getaddrinfo`, Security, Launch Services, AX; 6 at once), `.cpu` (long CPU work; P-cores minus 1); plus the named reader and writer threads the spec lists | `CmuxNextWakeups/BlockingLane.swift` |
| Hang watchdog | `MainThreadWatchdog`: 50 ms stalls, 2 s hangs reported to `~/Library/Logs/<bundle id>/hangs/` and Sentry | `CmuxNextControl/Diagnostics` |

What a seam does on the main thread, outside `allowBlocking`:

- **Debug and test builds**: records the call site once (`#fileID:#line`), one unified-log line
  (`log stream --predicate 'category == "blocking"'`), the Debug menu's "Main-Thread Blocking (N)" and the
  `debug.blocking` socket command. Launch with `CMUX_BLOCKING_TRAP=1` to stop at the call.
- **Nightly** (built with `-DCMUX_BLOCKING_CHECKS`): records each new site once and logs one public line with
  the kind and image UUID + offset frames. Never traps.
- **Release**: compiled out.

Heavy or long-lived work doesn't belong in the app process at all: it goes to the Rust `cmux-tui` daemon, and the
app sends it a request. New app logic is Rust or shared web, never new Swift.

## The trap: `nonisolated async` is not off the main thread

Every CmuxNext target enables `NonisolatedNonsendingByDefault`. Under it, an `async` function that isn't an
actor's, isn't on a global actor and isn't `@concurrent` runs on its **caller's** actor. Awaited from main-actor
code, everything it does between suspension points runs on the main thread. In a UI target
(`uiSwiftSettings`, main-actor by default) an unannotated `async` function is main-actor outright.

So `public static func run(...) async` in a plain struct is not "background work". Say where it runs:

- `@concurrent func ...` runs on the global executor whoever awaits it. Use it for a function whose
  synchronous stretches may block. It still sits on Swift's cooperative pool (one thread per core), so keep a
  long wait off it too:
- `try await work.run(.userVisible, mayBlock: .files) { ... }` moves the blocking part to a lane thread.

A `// concurrency-allow: never on the main thread` comment does not make that true. Check who awaits the function.

## Converting a violation: the 391 s stdin write

On 2026-11-09 a NIGHTLY main thread sat 391 s in `NSFileHandle.write(contentsOf:)`. Cloud's spare warm
(`CloudSpareWarm.start`, main actor) awaited `ProcessRunner.run`, which wrote a child's stdin into a fresh pipe
before launch. `run` was `public static func ... async` in a struct, so it ran on the main actor. A pipe write
can wait however few the bytes are: a child that never reads, or a fresh pipe when the kernel's pipe memory is
used up.

Before (`CmuxNextDaemon/Launch/ProcessRunner.swift`):

```swift
public static func run(executable: URL, arguments: [String], stdin: Data? = nil, ...) async throws -> ProcessResult {
    let input = stdin.map { _ in Pipe() }
    if let input, let stdin {
        try input.fileHandleForWriting.write(contentsOf: stdin)   // on the caller's thread: main
        try input.fileHandleForWriting.close()
        process.standardInput = input
    }
```

After (the fix PR for this hang): the function leaves the caller's actor, and the bytes go through
`PipeFeed` (`CmuxNextCompat/Process`), which writes and closes on a serial queue of its own after launch:

```swift
@concurrent public static func run(executable: URL, arguments: [String], stdin: Data? = nil, ...) async throws -> ProcessResult {
    let input = stdin.map { _ in Pipe() }
    let feed = input.map { PipeFeed($0.fileHandleForWriting) }
    defer { feed?.close() }
    // ... after process.run() succeeds:
    feed.write(stdin)
    feed.close()
```

The general recipe:

1. Find who awaits the function. If any caller is main-actor, its synchronous stretches run on main.
2. Blocking for a moment (a launch, a short read): mark the function `@concurrent`.
3. Blocking for an unknown time (a pipe, a socket, a wait, a disk on a network volume): put the call on a lane
   (`work.run(_, mayBlock:)`) or a queue of its own (`PipeFeed`), and await the result.
4. Use the seam (`blockingWrite`, `blockingRun`, ...) rather than the raw call, so the runtime check sees it if
   it ever lands on main again.
5. Never wait synchronously for that work from main (no semaphore, no `blockingSync`): await it.

## The detectors

| When | What | Escape |
| --- | --- | --- |
| CI | `scripts/cmux-next/check-concurrency.sh`: the everywhere rules (waits, sleeps, `DispatchQueue.main.sync`, blocking FileHandle reads, `dlopen`, ...), the main-actor rules (descriptor IO, `Data(contentsOf:)`) | `// concurrency-allow: <reason>` |
| CI | Its caller-isolated rule (`caller_isolation.py`): a blocking call or seam in an `async` function that is not `@concurrent` and not an actor's. Old hits are counted in `caller-isolated-blocking-pending.json` (shrink only) | `// caller-isolation-allow: <reason>` |
| Pre-push | `scripts/cmux-next/guardrails.py`: `main-blocking` (a blocking call in main-actor code), `raw-blocking` (a raw primitive where a seam exists), `thread-doc` (a new queue the spec doesn't list) | `// blocking-allow: <why>` |
| Runtime | The seams: Debug records and `CMUX_BLOCKING_TRAP=1` traps, Nightly logs, Release compiled out | `allowBlocking(.reason)` |
| Runtime | `MainThreadWatchdog`: stall and hang reports in `~/Library/Logs/<bundle id>/hangs/`, `debug.hangs`, Sentry | none: it's the backstop |

A hang report with a blocking frame on the main thread is a bug in one of the rows above. Fix the call, then
the detector that missed it.
