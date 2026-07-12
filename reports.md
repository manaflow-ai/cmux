# Flaky-test audit — cmux `feat-fix-flaky-tests`

Consolidated discovery from the in-session dynamic workflow (`.flaky-audit/verify-sweep.mjs`): 20 parallel agents triaged the **419** test files carrying a flakiness signal (of 2080 total), hunting residual flakiness on the already-de-flaked branch plus any regression the first de-flake pass introduced.

**101 candidate findings across 86 files.** Severity: high 27, medium 54, low 20. Confidence: high 56, medium 38, low 7.

Categories: `wall-clock-timing-assert` 36, `sleep-as-sync` 20, `async-race` 17, `shared-global-state` 11, `logic-bug` 6, `network-or-port` 6, `order-dependence` 2, `resource-leak` 2, `other` 1.

> Every entry is a *candidate*. The fix phase adversarially verifies each one against the current code and repo rules (deterministic test sleeps are allowed). Only genuinely-flaky candidates with a safe, behavior-preserving fix are changed; refuted candidates are left as-is and noted in the PR.


---

## Packages/Shared/CmuxAuthRuntime  (2)

### `Packages/Shared/CmuxAuthRuntime/Tests/CmuxAuthRuntimeTests/AuthCoordinatorTests.swift` :: `signOutJoinsAndCancelsSlowTeardownAtDeadline`
- **wall-clock-timing-assert** · severity medium · confidence medium
- **Evidence:** Line 252: `teardownTimeout: .milliseconds(50)`. The coordinator is created via `makeCoordinator(client: client)` with no explicit clock, so it defaults to `ContinuousClock()` (real wall time). The 50ms deadline sleeps on the real clock while the hook's `markStarted()` must run first.
- **Why flaky:** On a loaded CI runner, the cooperative task that calls `outcome.markStarted()` inside the onSignedOut hook may not be scheduled before the 50ms real-time teardown deadline fires and cancels the group. The assertion `#expect(await outcome.started)` would then fail because the hook was cancelled before it reached `markStarted()`.
- **Suggested fix:** Pass the `ManualTestClock` (already used in the sibling `AuthCoordinatorTimeoutTests`) to this test's coordinator, then use `clock.waitUntilSleepers()` + `clock.advance(by: .milliseconds(50))` to drive the deadline deterministically. This removes the real-time dependency entirely.

### `Packages/Shared/CmuxAuthRuntime/Tests/CmuxAuthRuntimeTests/HostBrowserSignInFlowTests.swift` :: `slowSignInSurfacesBrowserFallback`
- **sleep-as-sync** · severity medium · confidence high
- **Evidence:** Lines 232-256: harness created with `slowSignInThreshold: 0.05` (50 ms real wall-clock), then the test polls `harness.flow.signInIsSlow` up to 200 * 10 ms = 2 s using `Task.sleep(for: .milliseconds(10))` against `ContinuousClock`. The same pattern repeats at lines 249-256 waiting for the flag to clear.
- **Why flaky:** Under CI VM load the 50 ms real-timer fires late and the 2-second poll window can expire before the flag flips, producing a false failure. All other timeout tests in this file correctly use ManualTestClock; this is the sole remaining real-timer path.
- **Suggested fix:** Pass a ManualTestClock to makeHarness and drive the slowSignInThreshold off the virtual clock (the same pattern as abandonedBrowserAttemptTimesOut), replacing the two polling loops with clock.advance + Task.yield until the property changes.


## Packages/Shared/CmuxSyncStore  (1)

### `Packages/Shared/CmuxSyncStore/Tests/CmuxSyncStoreTests/SyncFrameAndProtocolTests.swift` :: `FlagTests.envOverrideWins`
- **shared-global-state** · severity low · confidence medium
- **Evidence:** Lines 385-386: `UserDefaults(suiteName: "flag-1")` and `UserDefaults(suiteName: "flag-2")` are accessed without calling `removePersistentDomain` first. The sibling test `debugDefaultsOnReleaseDefaultsOff` (line 390-391) correctly calls `removePersistentDomain` for `flag-3`.
- **Why flaky:** If a prior test run left values in the flag-1 or flag-2 suites, subsequent runs read stale defaults. While the environment-key override is tested here (the env key wins regardless of defaults), any future expansion of these tests that reads the defaults layer could produce a silent false-pass from leftover state.
- **Suggested fix:** Add `UserDefaults(suiteName: "flag-1")!.removePersistentDomain(forName: "flag-1")` and the same for flag-2 at the start of envOverrideWins, mirroring the hygiene already applied to flag-3.


## Packages/iOS/CmuxMobileRPC  (1)

### `Packages/iOS/CmuxMobileRPC/Tests/CmuxMobileRPCTests/MobileCoreRPCClientTests.swift` :: `cancelledQueuedRPCIsNotWrittenAfterEarlierSendCompletes`
- **async-race** · severity high · confidence high
- **Evidence:** Lines 105-108: after enqueuing `queuedTask`, the test spins exactly 100 `Task.yield()` calls then immediately cancels, assuming the task has advanced into the sendRequest queue. Lines 116-121 similarly poll with bounded yields+sleep to assert absence of a second send.
- **Why flaky:** If the cooperative scheduler does not schedule queuedTask within 100 yields (plausible under load), cancellation fires before the task reaches the queue gate. The test then asserts the cancellation succeeded (trivially true -- before queuing) and the real invariant (cancelled-while-queued is never written) is never exercised, turning the test into a false-pass. The absence check at lines 116-121 has a symmetric race: if the system is slow, the loop exits before the write path could have completed, also silently passing.
- **Suggested fix:** Expose an awaitQueuedRequestCount signal on QueuedCancellationProbeTransport (a CheckedContinuation that parks until N senders have entered the blocked send), analogous to the existing waitForSentRequestCount, and cancel only after that signal resolves.


## Packages/iOS/CmuxMobileTransport  (1)

### `Packages/iOS/CmuxMobileTransport/Tests/CmuxMobileTransportTests/TailscaleStatusTests.swift` :: `staleEvaluationCannotOverwriteFresherRefresh`
- **wall-clock-timing-assert** · severity medium · confidence medium
- **Evidence:** Lines 165-176: `staleInstant = ContinuousClock.now` is captured immediately before `monitor.refresh()`. The refresh call internally stamps its own evaluation with ContinuousClock.now. On a coarse-grained clock both reads can return the same value.
- **Why flaky:** If staleInstant equals the refresh stamp (same ContinuousClock tick), the stale-guard comparison fails to reject the stale apply, monitor.apply(.active, evaluatedAt: staleInstant) at line 172 overwrites the expected .inactiveOrNotInstalled status, and the test incorrectly passes the wrong assertion silently.
- **Suggested fix:** Capture staleInstant before creating the monitor (guaranteeing it predates all internal stamps), or inject a monotonic sequence counter into TailscaleStatusMonitor for test use, eliminating the reliance on ContinuousClock tick granularity.


## Packages/macOS/CmuxBrowser  (1)

### `Packages/macOS/CmuxBrowser/Tests/CmuxBrowserTests/Omnibar/BrowserOmnibarPageFocusRepositoryTests.swift` :: `invalidateAbortsPendingRetry`
- **wall-clock-timing-assert** · severity medium · confidence medium
- **Evidence:** Lines 98-114: `drainUntil(deadlineSeconds: 2.0)` polls `outcome != nil` by comparing `Date()` to a wall-clock deadline while calling `Task.yield()` repeatedly. The production code schedules via `DispatchQueue.main.asyncAfter(deadline: .now() + 0.0)`.
- **Why flaky:** In a Swift Testing async context, `Task.yield()` drains the cooperative Swift runtime pool but does not guarantee that a `DispatchQueue.main.asyncAfter` block fires, because the GCD main queue and the Swift concurrency main executor are distinct. If the asyncAfter block has not fired by the time the 2s wall-clock deadline expires, `outcome` stays nil, the loop exits silently, and `#expect(outcome == false)` asserts `nil == false`, which is a false failure rather than a false pass -- but under sustained CI load the 2s window may not be sufficient.
- **Suggested fix:** Inject the scheduling function used for retries so tests can call it synchronously (e.g. a `(_ delay: TimeInterval, _ work: @escaping () -> Void) -> Void` closure), eliminating reliance on asyncAfter and the wall-clock drain loop.


## Packages/macOS/CmuxCommandPalette  (5)

### `Packages/macOS/CmuxCommandPalette/Tests/CmuxCommandPaletteTests/CommandPaletteSearchEngineTests.swift` :: `largeWorkspaceSwitcherSearchBenchmarkAvoidsPerQueryPreparationCost`
- **wall-clock-timing-assert** · severity high · confidence high
- **Evidence:** Lines 1113-1129: asserts #expect(optimizedMs < referenceMs * 0.80), requiring the optimized path to be at least 20% faster. This is the tightest threshold of the three benchmark tests (only 800 large entries, 3 repetitions each). On a loaded CI runner the gap between reference and optimized shrinks or can briefly invert.
- **Why flaky:** A 20% relative speedup is well within OS scheduling noise on shared CI VMs. Even a single GC pause or background process burst during one of the two measurement windows can violate the assertion.
- **Suggested fix:** Either remove the #expect and keep the print as informational, or convert to an absolute deadline (e.g. < 500ms total) that catches catastrophic O(n^2) regressions but not scheduling noise.

### `Packages/macOS/CmuxCommandPalette/Tests/CmuxCommandPaletteTests/CommandPaletteSearchEngineTests.swift` :: `commandSearchBenchmarkBeatsLegacyPipeline`
- **wall-clock-timing-assert** · severity medium · confidence high
- **Evidence:** Lines 1024-1039: benchmarkElapsedMs uses DispatchTime.now().uptimeNanoseconds to measure both reference and optimized pipelines, then asserts #expect(optimizedMs < referenceMs * 1.25). Under CI/VM load the two sequential measurements compete for CPU, and thermal/scheduling jitter can cause the optimized path to appear slower than the 1.25x threshold.
- **Why flaky:** Both timing measurements run on the same thread in sequence; CPU contention, thermal throttling, or OS scheduling between the two blocks can invert or compress the ratio, causing a spurious failure even when the optimized path is genuinely faster on average.
- **Suggested fix:** Either skip this as a test (benchmark-only, no #expect) or use a fixed absolute ceiling (e.g. #expect(optimizedMs < 200)) that can only fail for a genuine regression, not a scheduling artifact. Alternatively wrap in a retry with a tolerance band wider than CI jitter.

### `Packages/macOS/CmuxCommandPalette/Tests/CmuxCommandPaletteTests/CommandPaletteSearchEngineTests.swift` :: `switcherSearchBenchmarkBeatsLegacyPipeline`
- **wall-clock-timing-assert** · severity medium · confidence high
- **Evidence:** Lines 1064-1079: same benchmarkElapsedMs pattern, asserts #expect(optimizedMs < referenceMs * 1.25) for the switcher corpus (400 entries, 96 queries).
- **Why flaky:** Same root cause as commandSearchBenchmarkBeatsLegacyPipeline: sequential wall-clock measurements on a shared CPU are sensitive to scheduling, yielding a non-deterministic ratio.
- **Suggested fix:** Remove the hard #expect ratio assertion from the test body or widen the threshold to 2x (to detect only real O(n^2) regressions), keeping the print statement for diagnostic purposes only.

### `Packages/macOS/CmuxCommandPalette/Tests/CmuxCommandPaletteTests/CommandPaletteSearchEngineTests.swift` :: `fastTypingPreviewSearchBenchmarkReportsEstimatedDroppedFrames`
- **wall-clock-timing-assert** · severity medium · confidence high
- **Evidence:** Lines 1212-1226: four #expect assertions compare cumulative wall-clock durations: cappedFullMs < fullMs, cappedFullDroppedFrames <= fullDroppedFrames, previewMs < cappedFullMs, previewDroppedFrames <= cappedFullDroppedFrames. All four are derived from benchmarkElapsedMs measurements taken in independent loops.
- **Why flaky:** With 800 entries and short per-query runtimes, the absolute difference between cappedFull and full (or preview and cappedFull) is small; CPU contention during any one loop can make the 'faster' variant appear slower on a given run.
- **Suggested fix:** Convert relative comparisons to print-only diagnostics and replace #expect with an absolute ceiling (e.g. no single query exceeds 8ms) that distinguishes algorithmic regressions from scheduling noise.

### `Packages/macOS/CmuxCommandPalette/Tests/CmuxCommandPaletteTests/CommandPaletteSearchEngineTests.swift` :: `nucleoExactPartialResultsDoNotRunSwiftSingleEditFallback`
- **logic-bug** · severity low · confidence medium
- **Evidence:** Line 781: #expect(cancellationChecks == 2) pins the exact number of times the shouldCancel closure is invoked. This count is an internal implementation detail of resolvedSearchMatches, not a public API contract.
- **Why flaky:** Not timing-flaky, but fragile: any refactor that changes the number of shouldCancel probe calls (e.g. adding an early-exit check, changing loop structure) will fail this assertion even when the observable behavior is correct. It silently tests internal call count rather than the stated contract (that Swift fallback is not run when nucleo results fill the page).
- **Suggested fix:** Replace #expect(cancellationChecks == 2) with #expect(cancellationChecks >= 1) or remove the count assertion entirely, keeping only the #expect(matches.first?.commandID == ...) check which tests the actual behavioral contract.


## Packages/macOS/CmuxLiveEval  (1)

### `Packages/macOS/CmuxLiveEval/Tests/CmuxLiveEvalTests/HostingInvalidationTests.swift` :: `countMutationReEvaluatesOnlyCounterTextStub, textMutationReEvaluatesOnlyTextReadingStubs, typedNSEventsRoundTripThroughRealTextField`
- **async-race** · severity medium · confidence medium
- **Evidence:** Lines 16-21: the `pump(until:)` helper drives `RunLoop.main.run(until: Date().addingTimeInterval(0.02))` in a 3-second deadline loop, relying on SwiftUI invalidating an offscreen `NSHostingView` within that window. In headless CI environments (no display server, no display link ticks), an offscreen `NSHostingView` may never call its SwiftUI body because `CADisplayLink` / the render server are not present, causing `pump` to spin the full 3 seconds and exit silently with an empty `recorder.labels`. The subsequent `#expect(recorder.labels.contains(...))` then soft-fails instead of crashing, so the test can produce false failures in headless CI.
- **Why flaky:** An offscreen NSHostingView in a headless macOS CI process may not receive render-server callbacks that drive SwiftUI state invalidation. The 3-second deadline is wall-clock only, so on a slow or display-less host the pump exits vacuously without the condition ever being met, and downstream assertions fail non-deterministically.
- **Suggested fix:** Use a `@testable` hook or observer on `LiveEvalEngine`/`EvalRecorder` to drive evaluation imperatively in tests rather than relying on the SwiftUI render loop. Alternatively, call `hosting.layoutSubtreeIfNeeded()` after each `store.box(...).value = ...` mutation and assert synchronously, bypassing the RunLoop timer entirely.


## Packages/macOS/CmuxRemoteWorkspace  (2)

### `Packages/macOS/CmuxRemoteWorkspace/Tests/CmuxRemoteWorkspaceTests/RemoteProxyBrokerTests.swift` :: `releaseTearsDownAndAbsorbsStaleWakeup`
- **wall-clock-timing-assert** · severity medium · confidence high
- **Evidence:** Lines 354-357: after `clock.fireOldestSleep()` the test spins for exactly 300ms wall-clock time (`let deadline = Date().addingTimeInterval(0.3); while Date() < deadline { usleep(10_000) }`) and then immediately asserts `provider.tunnels.count == 1`. This is a negative assertion ("the stale restart must NOT have happened") backed solely by elapsed wall time. Under CI load the broker's async Task may not have had a chance to run, so the assertion passes vacuously on a busy machine (the restart is queued but hasn't executed yet), giving a false green.
- **Why flaky:** A negative-presence assertion that relies on 300ms wall-clock to drain async side-effects is inherently racy. On a slow or loaded CI host the broker restart Task may not have scheduled within that window, causing a false pass; on an unusually fast host it may execute before the assertion, causing a false fail.
- **Suggested fix:** Add an observable signal that confirms the broker's teardown path ran fully (e.g. a `didAbortStaleRestart` callback on the broker, or check that the stale tunnel's `stopCount > 0` which is a positive observable fact). Assert on that positive signal with a bounded wait rather than assuming absence after a fixed sleep.

### `Packages/macOS/CmuxRemoteWorkspace/Tests/CmuxRemoteWorkspaceTests/RemoteCLIRelayServerTests.swift` :: `authAndForwardRoundTrip, wrongMACRejected`
- **network-or-port** · severity low · confidence low
- **Evidence:** Lines 48-66: `FakeUnixSocketServer.init` calls `socket(AF_UNIX, ...)`, `bind(...)`, and `listen(...)` on a temp-dir path; bind failure triggers `precondition(bound == 0, "bind failed errno=\(errno)")` which crashes the test runner. The relay server itself binds an ephemeral TCP port via `try server.start()`. Both operations succeed in practice but have no retry on EADDRINUSE or EMFILE. The client poll loop at line 126-136 uses `usleep(20_000)` (20ms) with a 5-second wall-clock deadline - benign but noted.
- **Why flaky:** A `precondition` in test setup (not a graceful `Issue.record`) crashes the entire test-runner process if the Unix socket path collides (e.g. `/tmp` full or path already exists from a killed test run). The TCP port binding failure would surface as a thrown error through `server.start()` which is correctly propagated, so that path is safe.
- **Suggested fix:** Replace the `precondition` calls in `FakeUnixSocketServer.init` with `throw`-able errors so a socket collision records a test failure rather than crashing the test process.


## Packages/macOS/CmuxSettings  (1)

### `Packages/macOS/CmuxSettings/Tests/CmuxSettingsTests/JSONConfigStoreTests.swift` :: `withTimeout (shared helper, used by observesExternalEdit)`
- **logic-bug** · severity medium · confidence medium
- **Evidence:** Lines 180-194: `withTimeout` uses `for await result in group { if let result { ... } }` with a `fatalError` fallthrough. If the timeout task fires first and returns `nil`, the loop skips the `if let`, then waits for the work task. If the work task is cancelled by external group cancellation before it can return its value (e.g. CI kills the test process partway), the group exhausts without ever entering the `if let` branch, and `fatalError` is reached -- crashing the test process rather than recording a clean failure. Additionally the writer loop in `observesExternalEdit` (line 97-107) re-writes the file every 50ms in a `while !Task.isCancelled` loop and relies on `withTimeout` calling `group.cancelAll()` to stop it; if `group.cancelAll()` is delayed past the outer 8-second timeout, the file is re-touched after the assertion window, producing a non-deterministic second delivery to the observer.
- **Why flaky:** The `fatalError` path is hit when the work task is cancelled or never resumes (e.g. a stuck async actor under CI load), crashing the process instead of recording a test failure. The 50ms polling writer loop extends past the observation window if group cancellation is slow, potentially causing the observer to collect extra values and fail the `collected.last == 'injected'` assertion.
- **Suggested fix:** Replace `fatalError` with `Issue.record(...)` and a safe default return, or restructure to return an `Optional` and `#require` at the call site. Cancel the writer Task unconditionally in a `defer` block rather than relying on TaskGroup cancellation propagation timing.


## Packages/macOS/CmuxSidebarInterpreterService  (1)

### `Packages/macOS/CmuxSidebarInterpreterService/Tests/CmuxSidebarInterpreterClientTests/RenderWorkerClientTests.swift` :: `survivesAWorkerCrashAndReannouncesContext (lines 58-83) and discardsAHungWorkerAndRecovers (lines 89-127)`
- **async-race** · severity medium · confidence medium
- **Evidence:** Lines 72-75: `for _ in 0..<20 where all.count < 2 { await client.updateScene(...); all = await collector.waitForEvents(count: 2, deadline: .milliseconds(500)) }`. The recovery loop sends at most 20 scene ticks, each with a 500 ms deadline, giving a total budget of ~10 s, but both the crash detection and process relaunch must complete within this budget. In `discardsAHungWorkerAndRecovers`, `waitForContextReset` (lines 129-144) similarly polls with `Task.sleep(for: .milliseconds(50))` up to a 5 s wall-clock budget.
- **Why flaky:** On a heavily loaded CI runner, spawning the fixture executable, reading its stdout pipe, and propagating the new context announcement through the AsyncStream can exceed the per-iteration 500 ms budget. If 20 iterations are exhausted before re-announcement, `all.count < 2` is never satisfied and the test silently passes with `all.count == 1`, then the `guard case` at line 78 triggers `Issue.record` with no explicit test failure (Swift Testing `Issue.record` does not stop the test). `discardsAHungWorkerAndRecovers` has the same issue: `recoveryContext == nil` after 20 × 500 ms will call `Issue.record("expected recovery context after hang")` but the test function does not return early, so the final `#expect` on line 127 evaluates `nil != nil` and passes silently.
- **Suggested fix:** After the recovery loop, add an explicit `#require(all.count >= 2)` / `#require(recoveryContext != nil)` before the structural guard so the test fails hard rather than recording a soft issue. Consider increasing `deadline` per iteration to 1 s on slower machines.


## cmuxTests  (24)

### `cmuxTests/CMUXCLIErrorOutputRegressionTests.swift` :: `testThemesSetTargetsResolvedTaggedSocketWhenBundleEnvironmentIsStale`
- **network-or-port** · severity high · confidence high
- **Evidence:** Line 660: `let socketPath = "/tmp/cmux-debug-active-theme.sock"` is hardcoded with no UUID suffix. It is set as `CMUX_SOCKET_PATH` in the subprocess environment. Any concurrent test run or leftover bound socket from a previous run on the same machine will cause EADDRINUSE or the wrong responder answering the CLI, making the test assert against bad data or time out.
- **Why flaky:** Two parallel CI workers running the same test suite bind or probe the same socket path simultaneously; one gets EADDRINUSE or connects to the other worker's mock, producing a wrong assertion. A crashed prior run that did not unlink the socket file has the same effect.
- **Suggested fix:** Replace the hardcoded path with a UUID-suffixed temp path, e.g. `let socketPath = "/tmp/cmux-debug-theme-\(UUID().uuidString).sock"`, and pass that to both the CLI subprocess and any listener.

### `cmuxTests/CmuxEventBusTests.swift` :: `testWorkspaceReorderSocketMapperDoesNotDuplicateLifecycleEvent, testPublishV2ReadTextResponseDoesNotAccumulateOnLongLivedThread, testBulkNotificationClearPublishesClearedWithoutRemovedDuplicates, testV1NotifySurfacePublishesSurfaceIdWithoutWorkspaceId, testV1MapperIgnoresNonSuccessResponses`
- **shared-global-state** · severity high · confidence high
- **Evidence:** Multiple tests call `CmuxEventBus.shared.resetForTesting()` at the start and in a `defer` block. `TerminalNotificationStore.shared` is also mutated. If XCTest runs test *classes* in parallel (the default for distinct XCTestCase subclasses), another class that also touches these singletons will race against the reset, observing events it was not expecting or missing events it needs.
- **Why flaky:** The `defer { resetForTesting() }` guard only protects within one test method's call stack; it does not prevent a concurrently running test in a different class from seeing stale or mid-reset singleton state. Even within the file, if the tests somehow run in parallel the reset at the beginning of test B can fire while test A is mid-assertion.
- **Suggested fix:** Instantiate a private `CmuxEventBus` and `TerminalNotificationStore` per test instead of using `.shared`, and pass those instances to the code under test. If production code only accepts the shared instance, add a thread-safe per-test override mechanism and hold an exclusive lock for the duration of each test body.

### `cmuxTests/FeedCoordinatorTests.swift` :: `blockingIngestExpiresItemWhenHookTimesOut, blockingIngestSkipsNotificationWhenPermissionResolvesBeforeDisplay, blockingIngestSurfacesNeedsInputAttentionForPermissionRequest`
- **shared-global-state** · severity high · confidence high
- **Evidence:** Each test calls `FeedCoordinator.shared.install(store:)` and sets test hooks on `FeedCoordinatorTestHooks` (also global). Cleanup is via `resetFeedCoordinatorTestHooks()` in `defer`. If another test class runs concurrently, it can install a different store or observe hook callbacks intended for this test, producing spurious assertion failures or missed signals.
- **Why flaky:** XCTest parallel execution across classes has no ordering guarantee. The global `FeedCoordinator.shared` store gets replaced mid-test by a concurrent installer, leaving the first test reading from or writing to the wrong store.
- **Suggested fix:** Add a per-test `FeedCoordinator` instance injected via a parameter or override; avoid mutating `.shared` in tests. At minimum, serialize all FeedCoordinator tests with `@Suite(.serialized)` or wrap the shared mutation in an exclusive lock held for the entire test body.

### `cmuxTests/ShellStartupMatrixTests.swift` :: `generatedSshBootstrapStartupStaysUnderPerformanceBudget`
- **wall-clock-timing-assert** · severity high · confidence high
- **Evidence:** Line 186: `result.process.duration < 1.0` where `duration` is `Date().timeIntervalSince(start)` measured around a real subprocess execution. The test runs for 8 shells (zsh/bash/fish/sh/dash/ksh/tcsh/csh) each asserting the same 1.0s budget. On a loaded CI VM spawning 8 subprocesses in sequence, each inherits the runner's scheduler pressure and can easily exceed 1s.
- **Why flaky:** Wall-clock budget assertion (`< 1.0s`) around subprocess launch and shell startup. A busy CI runner, a slow home directory scan, or a cold filesystem cache can push any shell's startup time past 1s, causing a false failure with no relation to the correctness of the behavior under test.
- **Suggested fix:** Remove the wall-clock budget assertion entirely or relax the budget to 5s. The real regression signal is whether the bootstrap produces correct output (`result.capture`), not whether it completes in under a second. If performance regression detection is needed, use a dedicated nightly benchmark rather than a correctness CI gate.

### `cmuxTests/ShellStartupMatrixTests.swift` :: `generatedSshBootstrapDoesNotBlockOnRelayCliWarmup`
- **wall-clock-timing-assert** · severity high · confidence high
- **Evidence:** Line 204: `result.process.duration < 1.0` where the test injects a `fakeCmuxDelay: 2` (2-second fake CLI delay) and asserts the bootstrap completes in under 1s by not waiting for that path. Same `Date()`-based wall-clock measurement. On a loaded runner, even the non-blocking path can easily exceed 1s.
- **Why flaky:** Same pattern as above: wall-clock budget on subprocess execution. Even with the 2s delay bypassed, shell startup on a cold, loaded runner can exceed 1s budget.
- **Suggested fix:** Replace the `duration < 1.0` assertion with a behavioral check: verify that the bootstrap subprocess does not `wait` on the fake CLI (e.g., check that the fake CLI was never exec'd or that the output marker appears without the delay). Use a process-level signal rather than a timing budget.

### `cmuxTests/TerminalAndGhosttyTests.swift` :: `testLargePlainTextPasteStaysFastWhenRichTextTypesAreAlsoPresent`
- **wall-clock-timing-assert** · severity high · confidence high
- **Evidence:** The test measures `elapsed = ProcessInfo.processInfo.systemUptime - startedAt` around a synchronous paste plan execution and asserts `XCTAssertLessThan(elapsed, 0.5, ...)`. The 0.5s budget is tight relative to scheduler jitter on a heavily loaded CI runner, GC pauses, and first-run JIT cost.
- **Why flaky:** Any scheduler pause (GC, competing test work, OS background activity) that stalls the main thread for >500ms causes a false failure. The test verifies optimization correctness (avoiding expensive RTF/HTML decoding), not raw speed, so the wall-clock assertion adds no safety net beyond what the behavioral assertion already provides.
- **Suggested fix:** Replace the timing assertion with a structural check: verify that the returned paste plan does NOT contain any step that decoded HTML or RTF (e.g., assert the plan's steps only contain plain-text operations). This tests the actual optimization without relying on wall-clock time.

### `cmuxTests/AppDelegateShortcutRoutingTests.swift` :: `keyWindowFocusIsReliable (static lazy probe, lines 177-194)`
- **wall-clock-timing-assert** · severity medium · confidence high
- **Evidence:** Lines 186-188: `let deadline = Date(timeIntervalSinceNow: 0.75)` / `while Date() < deadline, NSApp.keyWindow !== probe { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02)) }`. The probe uses a 750ms wall-clock budget to determine whether the window server is reliable, then caches the result in a `static let`.
- **Why flaky:** On a heavily loaded CI machine the 0.75 s budget may not be enough for the window server to promote the probe window to key, so `keyWindowFocusIsReliable` evaluates to `false` and every focus-routing test is wrongly skipped (false pass / silent suppression). Because the result is `static let`, a race in the first test that initialises it poisons every subsequent test in the suite.
- **Suggested fix:** Replace the hard wall-clock budget with a deterministic environment probe (e.g. check `GITHUB_ACTIONS` / `CI` env vars, or use `XCTestCase.testEnvironment`) so the skip decision is stable regardless of machine load. If the current wall-clock approach is kept, increase the budget to at least 2 s to reduce false negatives.

### `cmuxTests/BrowserPanelTests.swift` :: `testRestoredDiscardedHiddenWebViewGetsRestoreHostBeforeOffscreenCapture (lines 316-319)`
- **wall-clock-timing-assert** · severity medium · confidence high
- **Evidence:** Lines 316-319: `let deadline = Date().addingTimeInterval(1.0)` / `while panel.webView.isLoading, RunLoop.main.run(mode: .default, before: deadline), Date() < deadline {}` / `XCTAssertFalse(panel.webView.isLoading, "Timed out waiting for about:blank to finish loading")`. If `about:blank` does not finish loading within 1 s the test asserts false and continues, leaving `webView.isLoading == true` when the subsequent `discardHiddenWebViewForMemory` is called.
- **Why flaky:** On a slow or sandboxed CI runner `about:blank` load completion may exceed 1 s, causing either a spurious assertion failure or incorrect state for all assertions that follow. The test does not bail out after the timeout assertion.
- **Suggested fix:** Use an `XCTestExpectation` fulfilled by the WKNavigationDelegate `didFinish` callback (a delegate helper already exists in this file: `BrowserPanelTestNavigationDelegate`) instead of a busy-wait loop.

### `cmuxTests/CLICodexHookTimeoutRegressionTests.swift` :: `codexInstalledHookReturnsBeforeSlowCmuxCommandFinishes (lines 117-120)`
- **async-race** · severity medium · confidence medium
- **Evidence:** Lines 117-120: `waitForFile(capturedStdin, containing: payload, timeout: 1)` / `waitForFile(capturedArgs, ..., timeout: 1)` / `waitForFile(capturedPID, ..., timeout: 1)` / `waitForFile(doneFile, ..., timeout: 3)`. The `waitForFile` helper (lines 716-725) polls with `Thread.sleep(forTimeInterval: 0.02)`. The nohup background child process writes these files asynchronously after the parent hook script has already returned.
- **Why flaky:** The 1 s and 3 s polling windows are wall-clock-relative and can fail under CI load if the nohup subprocess is delayed by the OS scheduler. The 20 ms poll interval means up to ~50 misses before declaring failure, providing no signal on partial write or fsync delay.
- **Suggested fix:** These timeouts are intentionally generous and the 20 ms polling increment is appropriate for this category of async process test. The risk is low to medium; no change strictly required. If failures are observed, increase the `timeout` for `doneFile` to 5 s.

### `cmuxTests/CMUXOpenCommandTests.swift` :: `testDiffCommandUsesTaggedSocketAppAssetsAndServer`
- **shared-global-state** · severity medium · confidence medium
- **Evidence:** The test reads and writes a `.server-state` file under `/tmp/cmux-diff-viewer-<getuid()>/`. The path is keyed by the OS user ID, not a UUID, so concurrent runs by the same user (parallel CI workers on the same host, or a re-run before the previous run's cleanup) share the directory and can corrupt each other's state file.
- **Why flaky:** On a CI host running multiple jobs as the same user, two jobs write conflicting state to the same file, causing one test to read stale or wrong server state and fail the assertion.
- **Suggested fix:** Append a `UUID().uuidString` component to the temp directory path so each test invocation gets an isolated directory. Clean it up with a `defer`.

### `cmuxTests/CmuxTopProcessCPUTests.swift` :: `testBusyChildProcessReportsNonZeroCPUPercent`
- **wall-clock-timing-assert** · severity medium · confidence medium
- **Evidence:** The test spawns a shell busy-loop (`while :; do :; done`) and expects `CmuxTopProcessSnapshot.capture` to return a CPU percent > 0.1 for that PID within a 5-second polling window. On heavily throttled macOS CI runners (shared vCPU, nested virtualisation, or energy-saving governors), a shell process may not accumulate enough CPU time in 5 seconds to exceed the threshold, or the sampling interval may not align with the process's active window.
- **Why flaky:** The assertion is `cpuPercent > 0.1`, and the 5-second deadline is a hard wall-clock budget. Any CI runner where the guest vCPU is significantly throttled or preempted during the sampling window can return 0.0 CPU for the child, failing the assertion non-deterministically.
- **Suggested fix:** Use a tighter busy-loop in a compiled language (or a tight Swift/ObjC loop) rather than a shell process, and increase the assertion timeout or lower the threshold. Alternatively, use `XCTSkip` if the runner cannot reliably measure CPU above the threshold, similar to how other snapshot tests use `XCTSkip` on proc_pid_rusage failures.

### `cmuxTests/CmuxWebViewContextMenuLinkCaptureTests.swift` :: `openLinkInDefaultBrowserOpensTheLinkUnderTheRightClick, staleCaptureFromPreviousClickIsNotReusedForALaterMenu, syntheticContextMenuEventCannotPlantDecoyLink`
- **async-race** · severity medium · confidence medium
- **Evidence:** Each test fires a JS `dispatchEvent` then calls `try await Task.sleep(nanoseconds: 200_000_000)` (200 ms) before invoking `willOpenMenu`. The comment says the sleep lets the capture report arrive; if the WKWebView JS bridge round-trip takes longer than 200 ms on a slow or heavily-loaded runner, the capture has not arrived yet and the test uses the wrong code path (falls back to hit-test), producing a wrong assertion without failing loudly.
- **Why flaky:** WKWebView JS evaluation is asynchronous and its completion timing depends on the WebContent process. On throttled CI the round-trip can exceed 200 ms, causing the capture to arrive after the menu is opened. The test then uses the coordinate fallback and returns `example.test/decoy` instead of `example.test/clicked`, which is a silent wrong result, not an explicit timeout failure.
- **Suggested fix:** Instead of sleeping a fixed 200 ms, poll (with a deadline) for the capture to arrive, or expose a test hook that resolves a continuation when the capture is stored. This eliminates the timing dependency entirely.

### `cmuxTests/CommandPaletteShortcutCustomizationTests.swift` :: `testRemappedCommandPalettePreviousShortcutDoesNotConsumeControlP, testUnboundCommandPalettePreviousShortcutLetsControlPPassThrough, testChordedCommandPaletteNextShortcutMovesSelection`
- **shared-global-state** · severity medium · confidence medium
- **Evidence:** `setUp` saves then removes `UserDefaults.standard` keys for `commandPaletteNext` and `commandPalettePrevious`, and `KeyboardShortcutSettings.settingsFileStore` is swapped to a per-test directory. If XCTest runs this class in parallel with another class that reads `KeyboardShortcutSettings`, the default-store removal and the per-test file store swap leave the global shortcuts in an undefined state for the concurrent reader. The `withTemporaryCommandPaletteShortcut` helper also mutates and restores `KeyboardShortcutSettings` synchronously, with no protection if another thread reads between the mutation and the restore.
- **Why flaky:** Parallel test classes that read `KeyboardShortcutSettings.shortcut(for:)` mid-setUp or mid-withTemporaryCommandPaletteShortcut see an inconsistent default, causing shortcut lookups to return nil or a stale value.
- **Suggested fix:** Guard the entire setUp/tearDown and shortcut mutation blocks with a process-wide mutex, or serialize all shortcut-dependent tests with `@Suite(.serialized)` on a shared suite.

### `cmuxTests/GhosttyNotificationDispatcherTests.swift` :: `testSignalAcrossSeparateBurstsPostsMultipleNotifications`
- **async-race** · severity medium · confidence high
- **Evidence:** Lines 77-78: `DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { self.signal(dispatcher, ...) }`. The test asserts two signals arrive in separate debounce bursts by scheduling the second signal 50ms after the first. The debounce interval is 10ms (0.01s). If the main queue is saturated under CI load, the first dispatch block (carrying signal #1) may not execute until after the 50ms window expires, so both signals land in the same burst and the debounce fires only once — but the test asserts 2 notifications.
- **Why flaky:** The correctness invariant is that 50ms > 10ms debounce, but the margin collapses under a loaded main queue where both asyncAfter blocks can execute back-to-back within a single debounce window.
- **Suggested fix:** Replace the wall-clock asyncAfter separation with an injected `Scheduler` seam on the dispatcher, so the test can control when each burst ends. Alternatively, increase the inter-signal delay significantly (e.g., 0.5s) and use an XCTestExpectation waited with a longer timeout instead of relying on asyncAfter scheduling precision.

### `cmuxTests/MobileHostAuthorizationTests.swift` :: `testIdleTimeoutStartsAfterUnauthorizedFrameResponse (and related idle-timeout tests)`
- **sleep-as-sync** · severity medium · confidence medium
- **Evidence:** Line 997: `try await Task.sleep(nanoseconds: 25_000_000)` (25ms). This sleep is used to wait for the unauthorized frame's response to be processed before calling `debugStartIdleTimeoutAfterFrameForTesting()`. The comment says 'give the response time to be processed', confirming this is synchronization-by-sleep rather than signaling.
- **Why flaky:** Under a slow CI VM, the 25ms may expire before the async response processing completes, causing `debugStartIdleTimeoutAfterFrameForTesting()` to be called before the system is in the expected state, resulting in a test timeout or spurious failure.
- **Suggested fix:** Replace the sleep with a polling loop or an `AsyncTestSignal`/continuation that fires when the unauthorized-frame response handler actually completes, analogous to the `AsyncTestSignal` pattern already used elsewhere in the same file.

### `cmuxTests/WorkspacePullRequestSidebarTests.swift` :: `testPullRequestRefreshRepositoryDiscoveryDoesNotBlockMainRunLoop`
- **wall-clock-timing-assert** · severity medium · confidence medium
- **Evidence:** Line 629-633: `XCTAssertLessThan(maxTickGap, allowedMainThreadGap, ...)` where `allowedMainThreadGap = 2.0` seconds. `maxTickGap` is the largest interval between two consecutive 10ms timer ticks on the main run loop. A loaded CI runner can suppress the main thread for >2s (GC, disk I/O, swap, competing jobs). The comment acknowledges this: 'Generous bound far above macOS CI scheduling noise... A 2.0s bound still fails under extreme CI contention.'
- **Why flaky:** While the comment sets `allowedMainThreadGap` to 2.0s as a 'generous' bound, macOS CI shared runners can stall the main thread for several seconds during GC or disk pressure. The deterministic signal (git ran off-main) is fine; the wall-clock gap check is the flaky part.
- **Suggested fix:** Drop the `maxTickGap < allowedMainThreadGap` assertion entirely. The test already has a deterministic regression signal: `XCTAssertFalse(gitThreadObservation.observedOnMainThread, ...)` which catches the actual regression without any timing dependency. The timing check provides no additional safety.

### `cmuxTests/WorkspacePullRequestSidebarTests.swift` :: `testNoIndexLockTouchDuringSidebarGitMetadataRefreshWindow`
- **wall-clock-timing-assert** · severity medium · confidence medium
- **Evidence:** Line 670-675: `DispatchQueue.main.asyncAfter(deadline: .now() + 90.5)` schedules the test completion. `XCTWaiter().wait(for: [completedRefreshWindow], timeout: 92)`. The test runs for ~90 seconds and relies on wall-clock scheduling to fire the refresh window timer at consistent intervals. On a loaded CI runner, `asyncAfter` can fire significantly late, extending the test beyond 92s and causing a timeout.
- **Why flaky:** 90-second wall-clock test using `asyncAfter` for timing control. `asyncAfter` on the main queue is not cancellable and can fire late under load. If the 90.5s fire is delayed by runner scheduling, `XCTWaiter().wait(for:, timeout: 92)` expires before the expectation fulfills.
- **Suggested fix:** Replace the 90s wall-clock window with a cycle-count approach: run N refresh cycles synchronously (e.g., 100 calls to `refreshTrackedWorkspaceGitMetadataForTesting()` in a loop) and assert the invariant holds for all cycles. This makes the test fast, deterministic, and free of wall-clock dependencies.

### `cmuxTests/WorkspacePullRequestSidebarTests.swift` :: `testUnrelatedDefaultsChangeDoesNotRestartGitMetadataRefreshes`
- **wall-clock-timing-assert** · severity medium · confidence medium
- **Evidence:** Line 1070: `waitForCondition(timeout: 12.0)` waits up to 12 seconds for `activeWorkspaceGitProbePanelIdsForTesting` to become empty. 12s is 4x the normal 3s default, strongly suggesting this waits for async background work to settle. On an extremely loaded CI runner, background work may not complete within 12 seconds.
- **Why flaky:** 12-second wall-clock wait for async state to settle. The condition checks that background git probes have finished, but under heavy CI load those probes could be delayed beyond the 12s window. Additionally, `waitForCondition` uses `DispatchQueue.main.asyncAfter` polling which accumulates non-cancellable dispatches.
- **Suggested fix:** Provide an explicit synchronization point: add a testing API that drains or cancels pending git probes synchronously before asserting, instead of polling with a wall-clock timeout.

### `cmuxTests/AgentHibernationTests.swift` :: `testSocketLifecycleRejectsUnsupportedStatusKey (line 27-31)`
- **shared-global-state** · severity low · confidence medium
- **Evidence:** Line 28: `TerminalController.shared.handleSocketLine("set_agent_lifecycle fake-agent idle")`. This calls directly into the process-global `TerminalController.shared` singleton without any isolation or teardown of the shared state it may modify.
- **Why flaky:** If another test in the suite concurrently modifies `TerminalController.shared` state (e.g. `testSocketLifecycleAcceptsRegisteredCustomAgentKey` at line 34 which calls `setActiveTabManager`), the response string assertion at line 30 could be affected. The risk is low when tests run serially on `@MainActor`, but the lack of explicit serialization guarantees makes this fragile under test-parallelism changes.
- **Suggested fix:** Add `@MainActor` annotation to this test to ensure it serializes with the rest of the `@MainActor` tests in the class, or wrap the shared singleton call in a setUp/tearDown that saves and restores the active tab manager.

### `cmuxTests/BrowserWindowPortalRegistryNotificationTests.swift` :: `registryDoesNotNotifyForUnchangedPortalVisibility / unchangedPortalVisibilityDoesNotDriveWorkspaceLayoutFollowUp (lines 27-33)`
- **wall-clock-timing-assert** · severity low · confidence medium
- **Evidence:** Lines 27-28 (`realizeWindowLayout`) and line 32 (`advanceAnimations`): both helper methods call `RunLoop.current.run(until: Date().addingTimeInterval(0.05))` to let animations settle. Test correctness depends on 50 ms being enough for the AppKit layout/animation cycle.
- **Why flaky:** Under VM or CI load, 50 ms may be insufficient for the window layout pass to complete, causing assertions on `notificationCount` or `layoutPassCount` to read stale values. The failure mode is a false negative (count is 0 when 1 is expected) rather than a hang.
- **Suggested fix:** Drive the layout deterministically by calling `contentView.layoutSubtreeIfNeeded()` and `CATransaction.flush()` after mutations instead of relying on a fixed time budget.

### `cmuxTests/FileSearchRipgrepParserTests.swift` :: `waitForSearchRequestCount (helper used by multiple tests)`
- **wall-clock-timing-assert** · severity low · confidence low
- **Evidence:** The `waitForSearchRequestCount` helper uses a `Date().addingTimeInterval(1)` deadline (1 second) with 10ms `Task.sleep` polling. Under a heavily loaded CI worker, an actor hop or thread-pool stall can delay the async search dispatch past the 1-second window, causing the expectation to timeout and the test to fail spuriously.
- **Why flaky:** 1-second deadline is tight for an integration helper that may cross actor isolation boundaries. Confirmed by the repo memory noting this file as part of a flakiness sweep.
- **Suggested fix:** Increase the timeout to 5 seconds, matching the broader test suite convention, or add a dedicated notification/callback when the search request count is incremented.

### `cmuxTests/GhosttyDECCKMArrowKeyTests.swift` :: `testArrowKeysSendEscapeSequencesWhenDECCKMEnabled (and sibling tests)`
- **sleep-as-sync** · severity low · confidence low
- **Evidence:** Line approximately 120-130 (GhosttyDECCKMArrowKeyTests): `RunLoop.current.run(until: Date().addingTimeInterval(0.2))` used as a 200ms unconditional sleep after detecting the terminal-ready marker, before sending arrow key sequences. This is a fixed delay to let the terminal settle before input is sent.
- **Why flaky:** If the test runs on a slow CI host where the terminal process is not yet ready to process input after 200ms, the arrow key sequences may be consumed before the DECCKM mode flag is active. Confidence is low because the marker detection mitigates most of the race; this is a belt-and-suspenders sleep that could still fail under extreme load.
- **Suggested fix:** After the ready marker is detected, poll for a terminal-state signal (e.g., a sentinel response to a DECCKM status query via `DECRQM`) rather than sleeping 200ms. If that is too invasive, document the 200ms as a minimum and increase it to 500ms to reduce CI sensitivity.

### `cmuxTests/MarkdownPanelTests.swift` :: `testMarkdownRemoteImageCopyURLButtonShowsCopiedFeedback (or similar clipboard-feedback test)`
- **sleep-as-sync** · severity low · confidence medium
- **Evidence:** Line 998 (approximate): `try await Task.sleep(nanoseconds: 100_000_000)` (100ms) used after programmatically clicking a clipboard copy button, waiting for the WKWebView JS to update the button label to 'Copied'. The `waitForRemoteImageButtonRevert` helper (lines 1440-1481) polls the DOM to detect the revert, but the initial 100ms sleep before the first check is an unconditional delay.
- **Why flaky:** If the WKWebView JS executes the label change faster than 100ms (common on a fast machine) the sleep is wasteful but harmless; if it takes longer than 100ms on a slow CI machine the subsequent assertion can fire before the state updates. Low severity because the `waitForRemoteImageButtonRevert` helper correctly polls — the main risk is only for the intermediate 'Copied' assertion immediately after the sleep.
- **Suggested fix:** Replace the 100ms sleep with a poll loop (similar to `waitForRemoteImageButtonRevert`) that checks for the 'Copied' button label directly.

### `cmuxTests/TabManagerUnitTests.swift` :: `multiple tests using waitForCondition`
- **async-race** · severity low · confidence medium
- **Evidence:** Lines 33-68: `waitForCondition` uses `DispatchQueue.main.asyncAfter(deadline: .now() + pollInterval)` in a recursive chain. When the condition does not become true before `deadline`, the chain stops scheduling but previously scheduled callbacks continue to fire after the deadline (they check `Date() < deadline` before re-scheduling, but the last-fired callback executes its `condition()` call unconditionally). These stale callbacks can run into the next test's setup on the main queue. `testRemoteSplitSkipsInitialGitMetadataProbe` uses `waitForCondition(timeout: 12.0)` which can leave up to ~12s worth of queued callbacks after test completion.
- **Why flaky:** Non-cancellable `asyncAfter` cascades from one test's `waitForCondition` call can execute `condition()` during the next test's body, potentially observing partially-constructed state from the next test and causing spurious `XCTFail` calls attributed to a wrong test.
- **Suggested fix:** Replace the `asyncAfter`-based polling with `XCTNSPredicateExpectation` which has proper cancellation semantics, or use `await fulfillment(of:)` with a `Task`-based polling loop that can be properly cancelled on timeout.


## cmuxUITests  (10)

### `cmuxUITests/BrowserFixtureInteractionUITests.swift` :: `BrowserFixtureSocketTestCase.waitForSocketPong (used by all BrowserFixtureInteractionUITests and BrowserReliabilityRegressionUITests subclasses)`
- **async-race** · severity high · confidence high
- **Evidence:** Lines 274-297: `waitForSocketPong` creates an `XCTNSPredicateExpectation` whose predicate opens a Darwin socket connection and calls `ControlSocketClient(path:responseTimeout:1.0).sendLine("ping")` — blocking I/O inside a non-KVO closure. `XCTNSPredicateExpectation` evaluates the predicate once, then re-evaluates on a run-loop timer; that timer can be starved under `XCTWaiter.wait`, so a single early `false` (listener bound but accept loop not yet answering, a sub-second window) causes the waiter to sit idle on the stale result for the full timeout. `ControlSocketReadinessUITestSupport.swift` documents this exact failure mode at lines 33-47 and explicitly states 'This deliberately does *not* use XCTNSPredicateExpectation' — yet `waitForSocketPong` still does.
- **Why flaky:** The run-loop starvation documented in ControlSocketReadinessUITestSupport.swift for issue #5414 applies here identically. The predicate blocks for up to 1s per evaluation on a Darwin socket; after the first false the timer never fires again under XCTWaiter.wait, so the full timeout elapses even though the socket becomes responsive milliseconds later. This was the confirmed CI flake mechanism in BrowserPaneNavigationKeybindUITests before the prior de-flake pass; BrowserFixtureSocketTestCase still carries the same bug.
- **Suggested fix:** Replace the `XCTNSPredicateExpectation` in `waitForSocketPong` with `waitForControlSocketReady(socketPath:pingTimeout:pingReturnsPong:)` from `ControlSocketReadinessUITestSupport`, exactly as `BrowserPaneNavigationKeybindUITests.waitForSocketPong` was fixed (line 1358-1362 of that file). Phase 1 waits for the socket file; phase 2 polls ping in a deadline loop.

### `cmuxUITests/MultiWindowNotificationsUITests.swift` :: `testNotifyCLIDoesNotStealFocusAcrossWindows`
- **wall-clock-timing-assert** · severity high · confidence high
- **Evidence:** Lines 382-386: `RunLoop.current.run(until: Date().addingTimeInterval(0.5))` is the entire observation window before `XCTAssertFalse(app.state == .runningForeground, ...)`. If cmux steals focus more than 0.5s after the notify CLI completes, the test passes silently.
- **Why flaky:** App activation on macOS under a loaded VM is not guaranteed to complete within 500ms. A late NSRunningApplication state transition or a deferred `[NSApp activateIgnoringOtherApps:]` call can arrive after the window has already closed. The test is checking a negative safety property (no focus theft) but gives only a 500ms window to observe it.
- **Suggested fix:** Replace with a polling negative-assertion loop that samples `app.state` every ~50ms for at least 2 seconds after the notify command, failing immediately if it ever transitions to `.runningForeground`. A helper like `XCTAssertNever(timeout: 2.0) { app.state == .runningForeground }` captures the intent.

### `cmuxUITests/BrowserPaneNavigationKeybindUITests.swift` :: `waitForCondition (all callers via waitForDataMatch: e.g. testCmdFFindsInTerminalAndBrowserPanesWithSeparateQueries, testFindOwnerRestoredAfterWorkspaceRoundTrip, testCmdCtrlHMovesLeftWhenWebViewFocused, etc.)`
- **async-race** · severity medium · confidence high
- **Evidence:** Lines 1563-1569: `waitForCondition` wraps arbitrary file-I/O predicates (JSON reads from `dataPath`) in `XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in predicate() }, object: nil)`. The `object: nil` form is not KVO-observable; `XCTNSPredicateExpectation` evaluates once then schedules a polling timer on the run loop. Under `XCTWaiter.wait` that timer can be starved by UI test framework activity, preventing re-evaluation for the full timeout even after the file appears. Called by `waitForDataMatch` (line 1504) and `selectWorkspace` (line 1402) throughout the test.
- **Why flaky:** Identical starvation mechanism to the documented socket-ping flake. The predicates are non-KVO closures that read a JSON file on disk; a first false (file not yet written) can freeze the waiter for the full timeout on a loaded CI runner. The test has 6s timeouts for focus and data checks — enough for correct behavior but too short if the waiter stalls due to run-loop starvation.
- **Suggested fix:** Replace `waitForCondition` with a deadline poll loop using `RunLoop.current.run(until:)` between iterations, matching the pattern in `pollControlSocketCondition` in ControlSocketReadinessUITestSupport.swift. For the `waitForNonExistence` helper at line 1543 (KVO-bound to an XCUIElement), `XCTNSPredicateExpectation` is fine and does not need changing.

### `cmuxUITests/FindSelectionShortcutUITests.swift` :: `waitForCondition (all callers via waitForDataMatch: testRepeatedCmdFPreservesOpenTerminalAndBrowserFindCaretAndSelection, testEscapeClosesTerminalAndBrowserFindAfterQuery)`
- **async-race** · severity medium · confidence high
- **Evidence:** Lines 311-317: `waitForCondition` wraps file-I/O predicates in `XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in predicate() }, object: nil)`. `waitForDataMatch` (called with 6s timeouts at lines 29, 53, 103, 116, 124, 130, 161, 173, etc.) delegates to this helper. Same non-KVO, non-retried closure pattern as BrowserPaneNavigationKeybindUITests.
- **Why flaky:** Same run-loop starvation mechanism. The predicate reads a JSON file on each evaluation; under XCTWaiter.wait with a nil object, a single false result can strand the waiter idle for the full 6s timeout even when the file is updated a moment later. Tests that chain multiple `waitForDataMatch` calls (both test methods) accumulate this risk across each step.
- **Suggested fix:** Replace `waitForCondition` with a deadline poll loop: `let deadline = Date().addingTimeInterval(timeout); repeat { if predicate() { return true }; RunLoop.current.run(until: Date().addingTimeInterval(0.1)) } while Date() < deadline; return predicate()`. This matches `pollControlSocketCondition` in ControlSocketReadinessUITestSupport.swift.

### `cmuxUITests/MenuKeyEquivalentRoutingUITests.swift` :: `testBrowserFirstFindShortcutDoesNotReplayUnclaimedCmdEIntoWebContentTwice`
- **wall-clock-timing-assert** · severity medium · confidence high
- **Evidence:** Line 166: `RunLoop.current.run(until: Date().addingTimeInterval(0.5))` immediately followed by XCTAssertEqual asserting that the page title did NOT change to 'cmde-2'. The 0.5s window is the entire negative observation period.
- **Why flaky:** If the second Cmd+E replay is delayed past 0.5s by VM load (context switching, process scheduling, WKWebView navigation callback latency), the assertion fires before the replay occurs and the test passes silently even when the bug is present.
- **Suggested fix:** Replace with a repeated-sampling negative check: poll the page title 3+ times over the 0.5s window and fail immediately on any sample that shows 'cmde-2'. This turns a fail-open timeout into a fail-fast sentinel.

### `cmuxUITests/SidebarPullRequestInteractivityUITests.swift` :: `testSidebarPullRequestClickFallsThroughByDefault / testSidebarPullRequestClickFallsThroughWhenClickabilityDisabled`
- **wall-clock-timing-assert** · severity medium · confidence medium
- **Evidence:** Lines 114-121: `waitForSurfaceCountToStay(initialSurfaceCount, workspaceId:, timeout: 1.5)` asserts that no new browser surface opens within 1.5s. The `pollUntil` helper in this file uses `Date().addingTimeInterval` rather than monotonic `systemUptime`, compounding the issue.
- **Why flaky:** If a browser surface opens after 1.5s due to app startup latency or scheduling delays under VM load, the function returns `true` (no change observed) and the test silently passes even when the click-through bug is present. The 1.5s window is also the deadline for the wait, not a minimum observation time.
- **Suggested fix:** Increase the timeout to at least 3s. Additionally, fix the `pollUntil` helper to use `ProcessInfo.processInfo.systemUptime` instead of `Date()` for monotonic timing. Consider adding a subsequent positive assertion (e.g., workspace was navigated correctly) to ensure the test is checking the right preconditions.

### `cmuxUITests/TerminalCmdClickUITests.swift` :: `testCmdClickPngOpensInCmuxFilePreviewWhenEnabled, testCmdClickMarketingSkillMarkdownPathWithTrailingPeriodOpensMarkdownViewer, testCmdClickQuotedAbsoluteMarkdownPathWithTrailingPeriodOpensMarkdownViewer, and invalid-offset variants`
- **wall-clock-timing-assert** · severity medium · confidence medium
- **Evidence:** `waitForOpenCountToStay(0, timeout: 0.75)` used as the sole gate for asserting no external opener was called. 750ms is the entire observation window for the negative assertion.
- **Why flaky:** If the external-opener dispatch is delayed past 750ms by VM scheduling (e.g., the Cmd+Click handler is queued behind other work), the test passes silently before the unwanted open fires. Under CI load this is plausible given that the Cmd+Click → file routing path involves multiple async hops.
- **Suggested fix:** Increase the observation window to at least 1.5s, ideally 2s. Additionally introduce a positive synchronization point before the negative check: wait for the file-preview panel to appear (or for a known socket response confirming the click was processed) before starting the `waitForOpenCountToStay` observation window.

### `cmuxUITests/UpdatePillUITests.swift` :: `testUpdatePillShowsForNoUpdateThenDismisses`
- **wall-clock-timing-assert** · severity medium · confidence high
- **Evidence:** Lines 116-118: `XCTAssertGreaterThanOrEqual(hiddenAt - shownAt, 4.8)` where both timestamps are `Date()` values written by app code into a JSON file. The margin over the expected 5s display duration is only 0.2s.
- **Why flaky:** Timer jitter, process scheduling delays, and JSON file write latency on a loaded CI runner can easily consume 200ms or more, causing `hiddenAt - shownAt` to be 4.6-4.9s when the feature is working correctly. This creates spurious CI failures that look like regressions but are pure timing variance.
- **Suggested fix:** Widen the lower bound to account for realistic CI variance: use `>= 3.5` (or drop the lower bound entirely) and keep only the ordering assertion `XCTAssertGreaterThan(hiddenAt, shownAt)`. The auto-dismiss behavior is already verified by the ordering assertion; the timing magnitude is fragile to assert precisely.

### `cmuxUITests/BrowserReliabilityRegressionUITests.swift` :: `testWaitLoadStateOnNeverNavigatedSurfaceReturnsPromptly`
- **wall-clock-timing-assert** · severity low · confidence low
- **Evidence:** Lines 29-53: `let start = Date(); let envelope = socketEnvelope(...); let elapsed = Date().timeIntervalSince(start); XCTAssertLessThan(elapsed, durationBound)` where `durationBound = 1.5 + 12.0 = 13.5s`. The comment acknowledges this is intentionally generous to only catch unbounded hangs.
- **Why flaky:** On an extremely loaded CI runner, a WebKit content process spin-up plus socket round trip could theoretically exceed 13.5s wall-clock. The generous bound makes this unlikely in practice, but it is a true wall-clock assertion rather than a structural check.
- **Suggested fix:** No change required given the 13.5s bound is already very generous. If it ever fires spuriously, increase `responseTimeout` from 12s to something like 20s so the bound scales up automatically.

### `cmuxUITests/MenuKeyEquivalentRoutingUITests.swift` :: `clickBrowserPane (shared helper used by multiple tests)`
- **sleep-as-sync** · severity low · confidence medium
- **Evidence:** Line 480: `RunLoop.current.run(until: Date().addingTimeInterval(0.15))` after a coordinate click, used as the sole guard for focus routing to complete before subsequent keyboard shortcuts are sent.
- **Why flaky:** 150ms is a common heuristic that can fail under CI VM load; if focus routing has not completed when the caller sends keyboard input, the shortcut is delivered to the wrong first responder. The existing `refocusWebView` helper already shows how to wait for `webViewFocused` key — the same pattern could be applied here.
- **Suggested fix:** Replace with a polling wait on a focus-state observable, similar to `refocusWebView`'s `waitForGotoSplitMatch { $0["webViewFocused"] == "true" }` pattern. If the clicked pane is a terminal, poll for `terminalFocused` instead.


## tests  (25)

### `tests/test_browser_goto_split.py` :: `test_goto_split_from_loaded_browser`
- **sleep-as-sync** · severity high · confidence high
- **Evidence:** Line 46: `time.sleep(2.0)  # Wait for page load` immediately after `client.new_pane(..., url="https://example.com")`. No subsequent poll to confirm the page has actually loaded before proceeding to focus_webview.
- **Why flaky:** Network latency to example.com on a slow or distant CI runner easily exceeds 2 seconds, leaving the webview in a loading state; the subsequent focus_webview + wait_for_webview_focus(3.0s) attempts then race against a still-loading page, causing unreliable first-responder acquisition. The sibling file test_browser_custom_keybinds.py was already fixed to use wait_url_contains(timeout_s=15.0) for the same URL/operation.
- **Suggested fix:** Replace the bare `time.sleep(2.0)` with a call to a polling helper like `wait_url_contains(client, browser_id, 'example.com', timeout_s=15.0)` (already defined in test_browser_custom_keybinds.py) before proceeding to focus setup. Apply the same fix to line 117 in test_goto_split_roundtrip_loaded_browser.

### `tests/test_codex_hook_agent_ports.py` :: `_find_free_port / main`
- **network-or-port** · severity high · confidence high
- **Evidence:** Lines 61-73: _find_free_port() binds to port 0, records the ephemeral port, then closes the socket and returns the number. Lines 379-383: that number is passed via env var to a subprocess that later starts `python -m http.server <port>`. The gap between the close (line 70) and the eventual http.server bind can be many seconds (subprocess fork, session-start hook, ready-file poll). Any other process can steal the port in between.
- **Why flaky:** TOCTOU race between releasing the probe socket and the child process binding the same port. Under CI load with parallel jobs on the same machine, the port is frequently stolen, causing the http.server to fail to bind, which means _wait_for_lsof_listen_pid times out and the test fails.
- **Suggested fix:** Hold the socket open until the child process is ready to bind: pass the listening socket fd to the subprocess (SO_REUSEPORT) or use a socketserver approach where the parent creates the server socket and the child inherits the fd. Alternatively, pass `--bind 127.0.0.1 0` to http.server and have the child report back the actual port it chose.

### `tests/test_cpu_notifications.py` :: `test_cpu_after_popover_close`
- **sleep-as-sync** · severity high · confidence high
- **Evidence:** Lines 173-195: `osascript activate`, `time.sleep(0.2)`, then two `osascript keystroke Cmd+Shift+I` calls (lines 181-189) with 0.5s between them. The test then measures CPU and asserts it is below MAX_IDLE_CPU_PERCENT (20%).
- **Why flaky:** Between the `activate` call and the keystroke, another app on a CI machine can steal focus in under 0.2s. If keystrokes land on the wrong app, the popover is never toggled, so the test silently measures idle CPU without ever exercising the popover-close path, producing a false pass. macOS accessibility permission prompts for System Events can also block entirely on headless CI.
- **Suggested fix:** Replace the osascript-based popover toggle with a socket command (e.g., a `toggle_notifications_popover` debug command) so the test does not depend on System Events focus or accessibility. If no socket command exists for this path, skip the test on CI where assistive access is unavailable.

### `tests/test_ghostty_zsh_job_table_saturation_guard.py` :: `_capture_saturated_session`
- **wall-clock-timing-assert** · severity high · confidence high
- **Evidence:** Line 87-92: `_send(master, f'for i in {{1..1100}}; do sleep {BACKGROUND_SLEEP_SECONDS} & done\n')` followed by `_read_available(master, output, time.time() + 8.0)`. After the 8s window, `_send(master, 'print __CMUX_AFTER_FILL__\n')` is sent and `_read_available(master, output, time.time() + 1.0)` reads for only 1 more second. Line 178: `if b'__CMUX_AFTER_FILL__' not in output: ... FAIL`.
- **Why flaky:** On a loaded CI machine, spawning 1100 background processes inside zsh can take longer than 8 seconds. If the for loop completes at 9-10 seconds, the echo runs after the 1-second follow-up read window closes, so `__CMUX_AFTER_FILL__` is never captured, causing a spurious FAIL.
- **Suggested fix:** Increase the for-loop wait window from 8.0 to at least 20 seconds, or drive the transition off the actual `__CMUX_AFTER_FILL__` marker appearing in output rather than a fixed elapsed time, mirroring the marker-driven approach in `test_ghostty_zsh_prompt_redraw_uses_prompt_start.py`.

### `tests/test_omp_extension_install.py` :: `main (log verification block, lines 442-445)`
- **sleep-as-sync** · severity high · confidence high
- **Evidence:** Line 362: fake_cmux script has `sleep 3` before writing logs. Lines 443-445: `wait_for_text(fake_args_log, 3)`, `wait_for_text(fake_stdin_log, 6)`, `wait_for_text(fake_env_log, 12)` all default to `timeout=5.0`. If the JS extension fires the three hook invocations serially, each fake_cmux process takes 3s, giving 9s total before all three logs are written -- the 5s window expires first and `wait_for_text` returns incomplete content.
- **Why flaky:** The `wait_for_text` 5-second timeout is shorter than the worst-case serial execution time of three 3-second fake_cmux processes (9s). Whether hooks fire in parallel or serially depends on the extension's internal awaiting strategy; if serially, the log assertions silently succeed on incomplete data or incorrectly fail.
- **Suggested fix:** Increase `wait_for_text` timeout to at least 15s when `expected_count > 1` with a `sleep`-heavy fake binary, or remove the `sleep 3` from fake_cmux (it is not needed to prove asynchrony since the extension fires-and-forgets the cmux call).

### `tests/test_session_relaunch_resumes_agent_sessions.py` :: `main (post-relaunch workspace checks, lines 354-399)`
- **order-dependence** · severity high · confidence high
- **Evidence:** Lines 369/377/385/393: `workspace_contains(0, codex_expected)`, `workspace_line_contains(1, claude_expected_tokens)`, `workspace_contains(2, opencode_expected)`, `workspace_contains(3, pi_expected)` assume Codex restored to index 0, Claude to 1, OpenCode to 2, Pi to 3. The order of workspace restoration from the JSON snapshot is not guaranteed to be the same as creation order.
- **Why flaky:** If the session snapshot restores workspaces in a different order (e.g. sorted by ID or timestamp), the polled workspace at index 0 will not contain Codex output, causing all four _wait_for_condition checks to fail or false-pass on unrelated content. This is silently order-dependent on snapshot serialization behavior.
- **Suggested fix:** After relaunch, scan all workspaces for each expected token instead of assuming a fixed index. Use `_collect_all_scrollbacks` (already in the stress test) or iterate `list_workspaces()` and check each workspace individually.

### `tests/test_socket_access.py` :: `test_internal_process_allowed`
- **shared-global-state** · severity high · confidence high
- **Evidence:** Lines 380-427: the test writes a hook into `~/.zprofile` (the real user shell profile), relies on cleanup in `finally`. If the test process is killed hard (SIGKILL from CI timeout), or two instances run concurrently, the hook line persists permanently in the real user's `.zprofile`.
- **Why flaky:** A leftover hook referencing a deleted `hook_file` path is a no-op but is still noise in the user's shell startup. More critically, concurrent test runs append the hook twice; `content.replace(hook_line, '')` at line 422 replaces only the first occurrence when `str.replace` removes all occurrences — both are gone — but if one run crashes after the first append and before cleanup, the next run appends again and leaves a stale entry.
- **Suggested fix:** Use a temporary zprofile in a per-test tempdir passed via `ZDOTDIR` env override to the launched cmux process, instead of mutating the real `~/.zprofile`.

### `tests/test_browser_custom_keybinds.py` :: `test_cmd_ctrl_h_goto_split_left_from_webview / test_cmd_opt_left_arrow_goto_split_left_from_webview`
- **sleep-as-sync** · severity medium · confidence high
- **Evidence:** Lines 77, 123: `client.simulate_shortcut(...)` followed by `time.sleep(0.4)` then immediate `focused_pane_id(client)` assertion without any retry loop. Same pattern as the goto_split file.
- **Why flaky:** The 0.4 s sleep is not a guaranteed lower bound for focus propagation after a socket-injected shortcut; under CI load the main-thread dispatch may take longer, causing the post-shortcut focus read to return the stale browser pane and a false FAIL.
- **Suggested fix:** Replace `simulate_shortcut + sleep(0.4)` with a polling wait: spin until `focused_pane_id(client) == terminal_pane_id` or a 3 s timeout, then assert the final value.

### `tests/test_browser_goto_split.py` :: `test_goto_split_from_loaded_browser / test_goto_split_roundtrip_loaded_browser`
- **sleep-as-sync** · severity medium · confidence high
- **Evidence:** Lines 86, 139, 160: `client.simulate_shortcut(...)` followed immediately by `time.sleep(0.5)` and then a direct read of `focused_pane_id(client)` with no polling loop. If the app takes longer than 0.5 s to process the shortcut under CI load, the focus read returns the pre-shortcut value and the test fails.
- **Why flaky:** simulate_shortcut is an async socket injection; the UI focus update is a separate async dispatch on the main thread. On a loaded CI runner the 0.5 s window is not guaranteed to be sufficient, and there is no retry/poll to wait for the expected state.
- **Suggested fix:** Replace `simulate_shortcut + sleep(0.5)` with a poll: after sending the shortcut, spin until `focused_pane_id(client) == expected_pane_id` or a timeout (e.g. 3 s) expires, then assert.

### `tests/test_cli_socket_operation_deadline.py` :: `main (no-reply socket elapsed check)`
- **wall-clock-timing-assert** · severity medium · confidence medium
- **Evidence:** Line 155: CMUXTERM_CLI_RESPONSE_TIMEOUT_SEC is set to '0.2', meaning the CLI times out after 200ms. Line 209: `if result.elapsed > 1.5:` fails the test if the total wall-clock time for the subprocess exceeds 1.5s. On a loaded macOS CI runner a Swift binary cold start is 0.3-0.8s; adding the 0.2s CLI wait gives a realistic maximum of about 1.0-1.2s, which is only 25-50% below the 1.5s threshold.
- **Why flaky:** On heavily loaded CI runners (memory pressure, concurrent jobs), Swift binary launch time and OS scheduling jitter can push the elapsed past 1.5s even though the CLI itself is functioning correctly and respecting the 200ms deadline.
- **Suggested fix:** Either raise the elapsed ceiling to 3.0s (the response timeout is already constrained to 0.2s so the important deadline is still enforced), or switch from a wall-clock assertion to checking only that the CLI exited with a timeout error, dropping the elapsed check entirely.

### `tests/test_cli_version_memory_guard.py` :: `main (RSS limit check)`
- **wall-clock-timing-assert** · severity medium · confidence low
- **Evidence:** Line 20: RSS_LIMIT_KB = 64 * 1024 (64 MB). Lines 126-132: peak RSS is parsed from `time -l` output (bytes on macOS) and compared against that limit. The fixture CLI is linked with Sentry.framework (lines 60-62). A Swift binary cold-started on macOS loads dyld-shared-cache regions that can spike peak RSS; with Sentry the baseline is typically 35-60 MB, leaving only 4-29 MB of headroom on a memory-pressured CI VM.
- **Why flaky:** Peak RSS is non-deterministic under system memory pressure: the OS may not yet have reclaimed memory from previous test processes, or the dyld cache may have been flushed, forcing more pages to be faulted in during startup, pushing the measured RSS above 64 MB.
- **Suggested fix:** Raise the limit to 128 MB (still catches runaway scans of 40000 .app files, which would add hundreds of MB) or make the limit configurable via an env var so CI can override it on known-slow machines.

### `tests/test_cpu_notifications.py` :: `test_cpu_after_notification_burst / test_cpu_idle_with_notifications`
- **wall-clock-timing-assert** · severity medium · confidence medium
- **Evidence:** Lines 135-148 and 229-241: `monitor_cpu(pid, MONITOR_DURATION)` samples CPU via `ps` at 0.5s intervals over 3 seconds, then asserts `avg_cpu` is below 30% or 20%. Each `get_cpu_usage` call invokes `subprocess.run(['ps', ...])` (lines 99-109), which itself consumes CPU on a shared CI machine.
- **Why flaky:** Under CI load, competing Xcode builds or VM hypervisor overhead can transiently drive any process above 20-30%. The `ps`-snapshot approach is a point-in-time reading that is highly sensitive to scheduler jitter, causing spurious FAILs unrelated to the notification feature.
- **Suggested fix:** Replace `ps`-based polling with a single `sample` invocation averaged over the window, raise thresholds to at least 50% with an explicit note that lower thresholds are only reliable in isolation, or add a load-average guard that SKIPs the test when the host is too busy.

### `tests/test_cpu_usage.py` :: `main (idle CPU measurement)`
- **wall-clock-timing-assert** · severity medium · confidence medium
- **Evidence:** Lines 162-176: monitors CPU for MONITOR_DURATION=3s, asserts `avg_cpu <= MAX_IDLE_CPU_PERCENT=15%`. CPU is sampled by repeated `subprocess.run(['ps', '-p', str(pid), '-o', '%cpu='])` calls (lines 99-109) every SAMPLE_INTERVAL=0.5s. The settle time is only 2.0s (line 158).
- **Why flaky:** A 15% threshold measured with `ps` snapshots is fragile on CI VMs where background tasks (Xcode, Spotlight, hypervisor) can momentarily inflate any process's reported CPU above 15%. On a cold CI runner, the app may also still be initializing during the 2s settle window.
- **Suggested fix:** Use the `sample` tool for a single aggregated CPU reading, raise MAX_IDLE_CPU_PERCENT to a more tolerant value (e.g., 40%) for CI, or skip the test when `sysctl -n vm.loadavg` indicates heavy system load.

### `tests/test_ctrl_socket.py` :: `run_tests (socket path check)`
- **shared-global-state** · severity medium · confidence high
- **Evidence:** Line 280: `socket_path = cmux.DEFAULT_SOCKET_PATH`. `DEFAULT_SOCKET_PATH` is a class-level attribute frozen at module import time (cmux.py line 236: `DEFAULT_SOCKET_PATH = _default_socket_path()`). Without `CMUX_TAG` or `CMUX_SOCKET_PATH`, `_default_socket_path()` resolves to `/tmp/cmux-debug.sock` (cmux.py line 157), which is the developer's live running instance.
- **Why flaky:** Without CMUX_TAG, the test sends real `sleep 30`, `cat`, and Python subprocesses to the user's production terminal session. The CLAUDE.md policy explicitly forbids running socket tests against the default socket for this reason. On CI where no cmux instance is running the test exits early (graceful), but a stale socket file can cause it to connect to an unexpected instance.
- **Suggested fix:** Change line 280 to call `cmux.default_socket_path()` (the dynamic method) rather than the import-time class attribute, and add an explicit assertion that `CMUX_TAG` or `CMUX_SOCKET_PATH` is set before proceeding, or gate the test with a CI environment check.

### `tests/test_restore_session_relaunches_codex_resume.py` :: `main (restored() closure, lines 261-266)`
- **order-dependence** · severity medium · confidence high
- **Evidence:** Line 265: `client.select_workspace(0)` inside `restored()`. The test uses `restore-session` CLI which opens a new window; workspace index 0 in the current window may not be the one that received the Codex resume command. The hardcoded index 0 assumes the new workspace appended at index 0 rather than at the end.
- **Why flaky:** After `restore-session` appends workspaces to an existing blank window with 1 workspace, the restored workspace will be at index 1 (or later), not index 0. Polling index 0 will always return the blank workspace's scrollback and `_wait_for_condition` will time out even when restore succeeded.
- **Suggested fix:** Change `restored()` to iterate `list_workspaces()` and check all workspace scrollbacks, or use `select_workspace(len(workspaces)-1)` to target the most recently added workspace.

### `tests/test_session_restore_stress_kill_cycles.py` :: `_collect_all_scrollbacks / _assert_all_sessions_resumed`
- **async-race** · severity medium · confidence medium
- **Evidence:** Lines 244-248: `_collect_all_scrollbacks` iterates workspaces by index, calls `select_workspace(index)` then immediately reads `_read_scrollback`. There is no wait after `select_workspace` for the workspace to become active and its scrollback to be flushed to the socket. This is called from `_wait_for_condition` with step `time.sleep(0.3)` but the race is per-iteration inside the collect.
- **Why flaky:** Under CI load, `select_workspace` is async; the subsequent `_read_scrollback` may return the previous workspace's content before the switch completes, causing `_marker_found` to search in the wrong scrollback and falsely claim a marker is missing when it actually exists.
- **Suggested fix:** Add a small poll-with-retry around the scrollback read after each `select_workspace`, or add a `time.sleep(0.1)` after `select_workspace` inside `_collect_all_scrollbacks` to let the workspace switch settle.

### `tests/test_signals_auto.py` :: `test_sigint_in_pty, test_eof_in_pty`
- **sleep-as-sync** · severity medium · confidence high
- **Evidence:** Lines 70-74 and 86-90: `for _ in range(20): if select.select([master_fd], [], [], 0.1)[0]: ...` — hard cap of 20 iterations * 0.1 s = 2 s maximum wait for subprocess output. Same pattern at lines 142-146 and 157-161 in test_eof_in_pty.
- **Why flaky:** Under CI/VM load, spawning a new Python subprocess and having it print 'WAITING' can easily exceed 2 s, causing the test to report 'Process didn't start properly' even though it did. The response-wait loop (lines 86-90) has the same 2 s ceiling for 'SIGINT_RECEIVED'.
- **Suggested fix:** Replace the fixed-count loops with a deadline-based polling loop (e.g. `deadline = time.time() + 5.0; while time.time() < deadline: ...`) with the same `select` call inside, breaking on the sentinel.

### `tests/test_socket_access.py` :: `_launch_cmux (called from every phase transition)`
- **sleep-as-sync** · severity medium · confidence high
- **Evidence:** Line 239: `time.sleep(8)` after `_wait_for_socket` returns, unconditionally applied every time the app is launched. Also `_kill_cmux` at line 215: `time.sleep(1.5)` after pkill.
- **Why flaky:** 8 s is used as a proxy for 'app fully initialized and ready to accept classified commands'. On a slow CI runner the app may still be initializing responder chain / socket mode at that point, causing the immediately-following `test_external_rejected` to see wrong behavior. On a fast runner the 8 s is just dead time. Neither bound is principled.
- **Suggested fix:** After the socket appears, issue a `ping` command in a retry loop until it returns a response (any response, including 'Access denied'), treating that as the ready signal instead of a wall-clock wait.

### `tests/test_split_cwd_inheritance.py` :: `test1 (split CWD), test2 (new workspace CWD)`
- **sleep-as-sync** · severity medium · confidence medium
- **Evidence:** Line 168: `time.sleep(4)` before asserting the new split pane inherited `test_dir_a`. Line 197: `time.sleep(4)` before asserting the new workspace inherited `test_dir_b`. These are followed by a `_wait_for_focused_cwd(..., timeout=15.0)` call.
- **Why flaky:** The `time.sleep(4)` is meant to wait for bash to start and run PROMPT_COMMAND. On slow CI VMs bash startup can take longer; if the shell has not yet written the first prompt when the poll starts, the 15 s `_wait_for_focused_cwd` does poll correctly, so this is low-severity for the poll. However the 4 s sleep adds non-deterministic extra wait that can push total test duration over CI time limits. More critically, on a very fast machine the sleep is unnecessary; on a very slow one it is insufficient as a 'pre-wait', leading to wasted retries. The test is already correctly structured to poll after the sleep, so the real risk is CI timeout rather than a wrong assertion.
- **Suggested fix:** Remove the fixed `time.sleep(4)` and rely entirely on the existing `_wait_for_focused_cwd(..., timeout=15.0)` polling, which already handles the correct wait.

### `tests/test_terminal_focus_routing.py` :: `_assert_routed_to_surface (module-level shared path)`
- **shared-global-state** · severity medium · confidence high
- **Evidence:** Line 25: `FOCUS_FILE = Path('/tmp/cmux_focus_routing.txt')` — hardcoded path with no PID or random suffix. Lines 93-95 and 100-103 read and write this path during every assertion.
- **Why flaky:** If two parallel CI jobs run this test simultaneously, they share the same file. One run's `echo $CMUX_SURFACE_ID > FOCUS_FILE` can overwrite the other's, causing either a false pass (wrong surface ID accepted) or a false failure (file contains a stale ID from the other run).
- **Suggested fix:** Generate the path with a PID/random suffix: `FOCUS_FILE = Path(f'/tmp/cmux_focus_routing_{os.getpid()}.txt')`, and unlink it at module teardown.

### `tests/test_browser_back_forward.py` :: `test_cmd_bracket_noop_on_terminal`
- **sleep-as-sync** · severity low · confidence medium
- **Evidence:** Lines 131 and 142: `time.sleep(0.3)` is the only synchronization after `simulate_shortcut("cmd+[")` and `simulate_shortcut("cmd+]")` before asserting `current_workspace() == after_ws`. No polling loop or event-based wait.
- **Why flaky:** The test checks that a no-op shortcut did not change the workspace. On a loaded runner, the shortcut handling dispatch may complete after 0.3s, which means the `current_workspace()` call races with the app's internal routing. If the shortcut is processed late but still correctly (i.e., no-op), the test passes; if the routing is slow and the test samples before the app has finished processing, it may also incorrectly pass or fail depending on app state.
- **Suggested fix:** Replace the fixed `time.sleep(0.3)` with a polling check that waits up to 1-2s for `current_workspace()` to stabilize (i.e., remain equal to `current_ws` across multiple samples with no change). Alternatively, add a round-trip socket call after the shortcut to ensure the app has processed the event before sampling workspace state.

### `tests/test_browser_custom_keybinds.py` :: `test_cmd_opt_left_arrow_goto_split_left_from_webview`
- **shared-global-state** · severity low · confidence medium
- **Evidence:** Lines 91-128: creates a workspace with `client.new_workspace()` but never calls `client.close_workspace(ws_id)`. The test runs before test_cmd_ctrl_h_goto_split_left_from_webview (which also creates a workspace), so workspaces accumulate in the live cmux instance across the two tests.
- **Why flaky:** Accumulated open workspaces can affect pane-count assertions in subsequent tests (line 60: `if len(panes) != 2`) if the window context bleeds across workspaces, and increase overall app state complexity. If the first test leaves a broken browser pane, the second test may inherit unexpected focus state.
- **Suggested fix:** Add a `try/finally` block in both test functions to call `client.close_workspace(ws_id)` on exit, mirroring the cleanup pattern used in test_browser_goto_split.py.

### `tests/test_ghostty_zsh_pure_preprompt_redraw.py` :: `_capture_session (phase-0 fallback path)`
- **wall-clock-timing-assert** · severity low · confidence medium
- **Evidence:** Lines 175 and 182: both phase transitions have a `now - phase_started > _PHASE_DEADLINE` (8s) fallback that advances the phase regardless of whether the expected signal appeared. If the phase-0 fallback fires before the first prompt mark is drawn, a newline is sent to a shell that may not be at a prompt, corrupting the session state used for the second-cycle assertion.
- **Why flaky:** On a heavily loaded CI runner where zsh startup exceeds 8s, the phase-0 fallback fires prematurely. The resulting output may contain zero or more PROMPT_START markers from an ambiguous state, making the assertion at line 189 (`fresh_count != 1`) produce an unreliable result.
- **Suggested fix:** Convert the _PHASE_DEADLINE early-exit path to return a SKIP (exit 0 with a warning) rather than proceeding with a potentially corrupted session, or increase _PHASE_DEADLINE to 20s to match the overall session deadline.

### `tests/test_notifications.py` :: `test_kitty_notification_chunked (line 191)`
- **wall-clock-timing-assert** · severity low · confidence medium
- **Evidence:** Line 191: `time.sleep(0.1)` is used as a synchronization guard before asserting `items` is empty (checking that no notification exists before the final chunk is sent). The OSC sequence is sent via `printf` through the shell; under VM/CI load the PTY-to-notification pipeline may be slower than 0.1s.
- **Why flaky:** On a slow host, the first-chunk OSC notification might not yet have been processed by the app within 0.1s, so `list_notifications()` returns [] even if a notification is about to arrive. The check passes but then the second chunk fires into a state where the first chunk has not yet registered, potentially corrupting the chunked-notification assembly and causing the title/body assertion to fail or produce unexpected results.
- **Suggested fix:** Replace the fixed `time.sleep(0.1)` with a short poll checking that the notification count stays at 0 for a brief window (e.g. 0.2s), which both avoids false-positives from delays and stays deterministic.

### `tests/test_sidebar_cwd_git.py` :: `main (_wait_for_git_branch for feature/agent-live, lines 195-201)`
- **wall-clock-timing-assert** · severity low · confidence medium
- **Evidence:** Line 188: `bash -lc 'git checkout -b feature/agent-live >/dev/null 2>&1; sleep 6'` - the test relies on the branch change being detected within 5.5s (line 196, `timeout=5.5`). On a slow or heavily loaded CI host, the git checkout itself may take seconds, and the async HEAD-watch cycle may not pick up the new branch within the 5.5s window. `allow_force_fallback=False` disables the recovery path.
- **Why flaky:** The intentional 5.5s timeout is tight and cannot use the fallback force-inject path. Under CI load, the HEAD-watch scheduling jitter combined with slow git operations can push detection past 5.5s, causing a false FAIL on correct code.
- **Suggested fix:** Increase the `timeout` to 9s (still safely under the 6s `sleep` end from when the command starts, accounting for ~3s for git checkout) or re-enable `allow_force_fallback` after a longer initial wait.


## tests_v2  (23)

### `tests_v2/test_cli_new_workspace_external_git_branch_refresh.py` :: `module-level`
- **logic-bug** · severity high · confidence high
- **Evidence:** Lines 20-29: `SOCKET_PATH = _resolve_socket_path()` is executed at import time and unconditionally raises `cmuxError` if `CMUX_SOCKET_PATH` is unset or does not match `/tmp/cmux-debug-[^/]+\.sock`. All 20 peer files use `os.environ.get("CMUX_SOCKET_PATH", "/tmp/cmux-debug.sock")` and accept the default socket.
- **Why flaky:** Any test runner that imports this file without a correctly-named tagged socket will get a hard import-time error rather than a skip or skip-able runtime check, making the test fail in environments (local dev, default CI) that legitimately use the untagged debug socket.
- **Suggested fix:** Move the socket validation out of module-level code into `main()`, or change the guard to emit a warning/skip rather than raise, matching the pattern used by all peer test files.

### `tests_v2/test_command_palette_rename_enter.py` :: `main`
- **sleep-as-sync** · severity high · confidence high
- **Evidence:** Line 88-91: `client.simulate_type(rename_to)` then `time.sleep(0.1)` then `client.simulate_shortcut('enter')`. The Enter key fires after a fixed 0.1s regardless of whether all characters have settled in the text field.
- **Why flaky:** Under CI/VM load, character delivery to the rename input can take longer than 0.1s, so Enter fires before the full name is in the field. The palette closes with a partial rename, and the title check at line 98 (`new_title != rename_to`) then fails with a truncated value.
- **Suggested fix:** After `simulate_type(rename_to)`, poll the field-editor probe (`_rename_input_selection`) until `text_length` equals `len(rename_to)` with a short timeout before sending Enter, instead of using the fixed sleep.

### `tests_v2/test_command_palette_switcher_surface_precedence.py` :: `main`
- **sleep-as-sync** · severity high · confidence high
- **Evidence:** Lines 104-110: `client.send_surface(right_surface_id, f'mkdir -p {target_dir} && cd {target_dir}\n')` then `time.sleep(0.8)` with no poll for shell completion before opening the switcher and searching for the token.
- **Why flaky:** The switcher finds the surface by its current working directory. On a loaded CI runner or VM the shell may not have executed `mkdir`+`cd` within 0.8s, so the CWD is not yet the token directory when the switcher query runs. The subsequent `_wait_until(_has_surface_match, timeout_s=8.0)` does retry, but only for the surface row presence, not for the CWD being set. If the shell takes more than 0.8s + poll time, the test fails with 'switcher results never produced a matching surface row'.
- **Suggested fix:** Replace the fixed `time.sleep(0.8)` with a poll that reads the surface's terminal text (or CWD via a debug call) until the target directory name is visible, before opening the switcher.

### `tests_v2/test_pane_resize_preserves_ls_scrollback.py` :: `_run_once`
- **logic-bug** · severity high · confidence high
- **Evidence:** Lines 84, 111, 120, 140, 156 call `_must(...)`. The import block pulls `clean_line`, `focused_pane_id`, `pane_extent`, `pick_resize_direction_for_pane`, `scrollback_has_exact_line`, `surface_scrollback_text`, `wait_for`, `wait_for_surface_command_roundtrip`, `workspace_panes` from `pane_resize_test_support` -- but NOT `must as _must`. There is also no local `def _must` in the file. By contrast the sibling `test_pane_resize_preserves_visible_content.py` correctly imports `must as _must`.
- **Why flaky:** Every run raises `NameError: name '_must' is not defined` at line 84 (the first `_must` call), so no assertion is ever evaluated and the test always fails at startup rather than testing the regression.
- **Suggested fix:** Add `must as _must,` to the `from pane_resize_test_support import (...)` block.

### `tests_v2/test_pane_resize_preserves_visible_content.py` :: `_run_once`
- **logic-bug** · severity high · confidence high
- **Evidence:** Line 74: `time.sleep(0.1)` is called after `client.focus_surface(surface_id)`. The file imports only `os`, `secrets`, `sys`, `pathlib.Path`, `cmux`, and members of `pane_resize_test_support`. `import time` is absent. `pane_resize_test_support` does import `time` internally but the selective `from ... import (...)` at lines 13-23 does not re-export it into this module's namespace.
- **Why flaky:** Every run crashes with `NameError: name 'time' is not defined` at line 74, so the test never reaches any assertion. It appears to be an omission introduced during the de-flake refactor when the import list was narrowed.
- **Suggested fix:** Add `import time` to the top-level imports (after `import secrets`).

### `tests_v2/test_ssh_remote_browser_favicon_uses_proxy.py` :: `test_ssh_remote_browser_favicon_uses_proxy`
- **network-or-port** · severity high · confidence high
- **Evidence:** Lines 188-189: `default_web_port = 23000 + (os.getpid() % 4000)` produces ports in the range 23000-26999. The companion test `test_ssh_remote_browser_move_rebinds_proxy.py` uses `default_web_port = 20000 + (os.getpid() % 5000)` which covers 20000-24999. These ranges overlap in the 23000-24999 band.
- **Why flaky:** When both tests run in the same pytest worker process (same PID), they compute the same port. Even across workers, overlapping ranges mean two tests in the same CI run can collide on the same port, causing one to fail with bind error or proxy misdirection.
- **Suggested fix:** Give each test a non-overlapping range. For example: favicon test uses `21000 + (os.getpid() % 2000)` (21000-22999) and move test uses `23000 + (os.getpid() % 2000)` (23000-24999). Or derive port from `os.getpid() * 2 % N` with disjoint offsets.

### `tests_v2/test_ssh_remote_browser_move_rebinds_proxy.py` :: `test_ssh_remote_browser_move_rebinds_proxy`
- **network-or-port** · severity high · confidence high
- **Evidence:** Lines 192-193: `default_web_port = 20000 + (os.getpid() % 5000)` produces ports in 20000-24999, overlapping with `test_ssh_remote_browser_favicon_uses_proxy.py` range of 23000-26999 in the 23000-24999 band.
- **Why flaky:** Same root cause as the favicon test: overlapping PID-derived port ranges cause cross-test port collision when both tests run in the same CI job.
- **Suggested fix:** Use a disjoint range that does not overlap with the favicon test. See suggested fix for the favicon test.

### `tests_v2/test_ssh_remote_docker_reconnect.py` :: `test_ssh_remote_docker_reconnect`
- **network-or-port** · severity high · confidence high
- **Evidence:** Lines 104-107: `_find_free_loopback_port()` binds port 0 to discover a free port, reads the assigned port, then closes the socket. The freed port is then passed to Docker to bind at a later time. Any other process can acquire that port in the window between the socket close and Docker's bind.
- **Why flaky:** TOCTOU race: the port is no longer reserved when it is passed to Docker. Under CI load where many processes are competing for ephemeral ports this causes Docker to fail to bind and the test fails non-deterministically.
- **Suggested fix:** Keep the socket alive as a bound listener and pass it to Docker via SO_REUSEPORT, or use Docker's own ephemeral port allocation (port 0 mapping) and then read the assigned port from `docker port` output. An alternative is to use a fixed port range seeded by os.getpid() and retry on bind failure.

### `tests_v2/test_terminal_focus_routing.py` :: `main (all assertions via _assert_routed_to_surface)`
- **shared-global-state** · severity high · confidence high
- **Evidence:** Line 25: FOCUS_FILE = Path("/tmp/cmux_focus_routing.txt") is a hardcoded module-level constant. Lines 93-103: the file is deleted, a shell command writes the focused surface ID into it, then the test reads it back. No process-unique or run-unique suffix is used.
- **Why flaky:** If two instances of this test run concurrently (parallel CI workers, re-runs, or another test that happens to write the same path), they share and corrupt the same sentinel file. One instance can read the stale value written by the other, causing false pass or false fail. The stress loop (10 iterations of new_split + close) makes concurrent collision more likely.
- **Suggested fix:** Replace the hardcoded path with a per-run unique path: FOCUS_FILE = Path(tempfile.mktemp(prefix='cmux_focus_routing_', suffix='.txt')) inside main(), or at minimum suffix with os.getpid() and a secrets token.

### `tests_v2/test_tmux_compat_matrix.py` :: `main (pipe-pane block, lines 163-166)`
- **async-race** · severity high · confidence high
- **Evidence:** Line 163-165: pipe_file = ... / f'cmux_pipe_pane_{stamp}.log'; _run_cli(cli, ['pipe-pane', ..., f'cat > {pipe_file}']); piped = pipe_file.read_text() if pipe_file.exists() else ''. The read is unconditional immediately after the CLI returns.
- **Why flaky:** pipe-pane starts an asynchronous subprocess (cat > file) in the app. The CLI returning does not mean the subprocess has started, let alone flushed any bytes to disk. Under any load, the file either does not exist yet or is empty, so piped is '' and the _must(capture_token in piped) assertion always fails.
- **Suggested fix:** Poll the file until it contains the capture_token, using the existing _wait_for helper: _wait_for(lambda: pipe_file.exists() and capture_token in pipe_file.read_text(), timeout_s=5.0) before the _must assertion.

### `tests_v2/test_background_workspace_idle_thread_footprint.py` :: `main (entire test)`
- **other** · severity medium · confidence high
- **Evidence:** Line 18: `SOCKET_PATH = os.environ.get('CMUX_SOCKET', '/tmp/cmux-debug.sock')`. The env var name is `CMUX_SOCKET`, but the standard harness sets `CMUX_SOCKET_PATH`. Every other test in both `tests/` and `tests_v2/` reads `CMUX_SOCKET_PATH`.
- **Why flaky:** When run via the standard CI harness that exports `CMUX_SOCKET_PATH=...`, this test silently falls back to `/tmp/cmux-debug.sock` — the main (non-tagged) dev socket. The test then fires `vmmap` and thread-count assertions against the live instance, not the tagged build under test, giving false passes when no tagged socket is active and potentially flaky results depending on what the user's running cmux is doing.
- **Suggested fix:** Change line 18 to `os.environ.get('CMUX_SOCKET_PATH', '/tmp/cmux-debug.sock')` to match the convention used by all other tests.

### `tests_v2/test_browser_custom_keybinds.py` :: `test_cmd_ctrl_h_goto_split_left_from_webview, test_cmd_opt_left_arrow_goto_split_left_from_webview`
- **sleep-as-sync** · severity medium · confidence high
- **Evidence:** Lines 65 and 114: `time.sleep(0.5)` immediately after `client.select_workspace(ws_id)`, used to wait for the workspace switch to complete before creating panes. The actual workspace-ready condition is never polled.
- **Why flaky:** Under CI/VM load a 0.5s sleep after workspace selection is not a reliable signal that the workspace is ready to host new panes. If the workspace switch has not propagated when `new_pane` fires, subsequent `list_panes()` may return stale data from the old workspace.
- **Suggested fix:** Replace the fixed sleep with a short poll that checks `client.list_panes()` returns at least 1 pane in the new workspace, or poll `client.current_workspace()` until it equals `ws_id`.

### `tests_v2/test_browser_goto_split.py` :: `test_goto_split_from_loaded_browser, test_goto_split_roundtrip_loaded_browser`
- **sleep-as-sync** · severity medium · confidence high
- **Evidence:** Lines 123 and 195: `time.sleep(0.5)` immediately after `client.select_workspace(ws_id)` before calling `new_pane`, same pattern as test_browser_custom_keybinds.py.
- **Why flaky:** Same reason as test_browser_custom_keybinds.py: fixed sleep after workspace selection does not guarantee the workspace is ready to host panes under CI/VM load.
- **Suggested fix:** Poll `client.current_workspace()` until it equals `ws_id` before proceeding, instead of the fixed 0.5s sleep.

### `tests_v2/test_browser_panel_stability.py` :: `test_open_browser_then_new_surface_loop`
- **sleep-as-sync** · severity medium · confidence high
- **Evidence:** Line 70: `time.sleep(0.8)` inside a 10-iteration loop, immediately after `client.new_surface(panel_type="browser", url=BROWSER_TEST_URL)` and before `ensure_webview_focused(client, browser_id, timeout_s=2.0)`. The comment at line 123 adds another `time.sleep(1.5)` after `new_pane` in the second test.
- **Why flaky:** On a slow CI runner or under VM load the 0.8s is not enough for the WKWebView to initialize and become focusable; `ensure_webview_focused` then times out in its own 2.0s window, returning a false failure. The second test's `time.sleep(1.5)` has the same problem.
- **Suggested fix:** Remove the fixed `time.sleep(0.8)` / `time.sleep(1.5)` and rely entirely on `ensure_webview_focused`'s polling loop, increasing its timeout to 4.0s. The polling already retries `focus_webview` + checks `is_webview_focused` at 50ms intervals.

### `tests_v2/test_command_palette_focus.py` :: `main`
- **sleep-as-sync** · severity medium · confidence high
- **Evidence:** Lines 71-76: `client.simulate_type(token)` then `time.sleep(0.15)` then `post_text = client.read_terminal_text(panel_id)` then `if token in post_text and token not in pre_text: raise`. The assertion is a negative check gated on a fixed sleep.
- **Why flaky:** If the terminal render pipeline is slower than 0.15s under load, the typed text has not yet appeared in `post_text`, so the assertion never fires even when routing is broken. This is a silent false-pass: the test passes, but it did not actually verify the invariant. On an overloaded CI host or VM this is reproducibly misleading.
- **Suggested fix:** After typing, poll `read_terminal_text(panel_id)` with a short deadline (e.g. 1s) and fail if the token appears before that time rather than checking after a fixed sleep. Alternatively, add a deliberate short wait and then assert text is still absent via polling: `_wait_until(lambda: token not in client.read_terminal_text(panel_id), timeout_s=1.0, message='...')` inverted to a soft deadline check.

### `tests_v2/test_command_palette_rename_enter.py` :: `main`
- **wall-clock-timing-assert** · severity medium · confidence medium
- **Evidence:** Line 76: `rename_to = f'rename-enter-{int(time.time())}'`. Resolution is one second.
- **Why flaky:** Two parallel test runs that start within the same wall-clock second produce the same `rename_to` string. If a prior run left that name on the workspace, the title check `new_title != rename_to` silently false-passes even if the rename action was never applied in the current run.
- **Suggested fix:** Use millisecond resolution as every other switcher test already does: `f'rename-enter-{int(time.time() * 1000)}'`.

### `tests_v2/test_nested_split_no_detach_during_update.py` :: `main`
- **async-race** · severity medium · confidence medium
- **Evidence:** Lines 66-76: the poll loop sleeps 5 ms between `_health_map` calls (which are socket round-trips) over a 1-second window. Each `_health_map` call is itself a socket round-trip; under VM/CI load round-trips can take 15-30 ms, so the effective cadence stretches to 20-35 ms and the window yields 30-50 samples. A legitimate single-frame AppKit reparenting that occupies 25-35 ms would register as 2-3 consecutive `in_window=False` samples. The threshold is `n > 2` (line 76), meaning exactly 3 false samples triggers a failure.
- **Why flaky:** Under heavy CI load, a normal transient reparenting can span 3 consecutive poll samples and falsely trip the failure condition. The test is designed to tolerate 2 false samples but the per-sample duration is not bounded, so a single legitimate reparenting can produce 3+ samples when the VM is slow.
- **Suggested fix:** Switch from sample-count to elapsed-duration: record the start timestamp of the first `in_window=False` for each panel and fail only if any single contiguous detach window exceeds a time threshold (e.g. 50 ms) rather than a sample count.

### `tests_v2/test_new_tab_interactive_after_splits.py` :: `main (via _wait_for_tmp_write)`
- **logic-bug** · severity medium · confidence high
- **Evidence:** Lines 153-182: `_wait_for_tmp_write` tries two timed loops and a direct-send fallback, then at line 181 prints `WARN: Timed out waiting for tmp file write: ...; continuing in v2 VM mode` and `return`s without raising. The caller at line 241 (`_wait_for_tmp_write(c, new_id, tmp, token)`) discards the return value and proceeds to print `PASS: new tab is interactive after many splits`. If the shell never writes the file, all 6 iterations silently pass.
- **Why flaky:** The function is the primary behavioral assertion (the new terminal executed a command), yet it fails open. Under VM load or when the shell is genuinely stuck, the test reports PASS while the regression it is guarding against has actually fired.
- **Suggested fix:** Add a boolean return value to `_wait_for_tmp_write` (True on success, False on timeout) and raise `cmuxError` at the call site if it returns False, or convert the WARN print to a `raise cmuxError(...)` in the final timeout branch so the test result accurately reflects execution failure.

### `tests_v2/test_ssh_remote_last_surface_clears_remote_state.py` :: `test_ssh_remote_last_surface_clears_remote_state`
- **wall-clock-timing-assert** · severity medium · confidence high
- **Evidence:** Line 129: `token = f"__CMUX_{token_prefix}_{int(time.time() * 1000)}__"` uses millisecond wall-clock time as the uniquifier for a probe token. All other tests in this suite use `secrets.token_hex(6)` for the same purpose.
- **Why flaky:** If `_run_surface_probe` is called more than once within the same millisecond (possible under fast CI), both probes produce the same token. The regex match then also hits the prior probe's echo still in the terminal scrollback, causing the test to return stale output and either false-pass or false-fail depending on the terminal state.
- **Suggested fix:** Replace `int(time.time() * 1000)` with `secrets.token_hex(6)` to match the pattern used by all other tests in the suite.

### `tests_v2/test_ssh_remote_shell_integration.py` :: `test_ssh_remote_shell_integration`
- **resource-leak** · severity medium · confidence high
- **Evidence:** Lines 285-294: `_launch_startup_command_pty` calls `pty.openpty()` to get `(master_fd, slave_fd)`, then immediately calls `subprocess.Popen(...)` without a try/except. If `Popen` raises (e.g. binary not found, permission denied), both `master_fd` and `slave_fd` are leaked. Compare with `test_ssh_remote_port_detection.py` lines 227-241 which has the correct guard: `try: proc = subprocess.Popen(...) except Exception: os.close(slave_fd); os.close(master_fd); raise`.
- **Why flaky:** Fd leak on error path: each failed Popen leaves two open fds. Under repeated test reruns or in CI where the binary path is wrong, fds accumulate. The test itself does not flake from this but it can cause test-suite-level fd exhaustion (EMFILE) that makes later unrelated tests fail.
- **Suggested fix:** Wrap the `subprocess.Popen` call in a try/except that closes both fds on exception, matching the pattern already present in `test_ssh_remote_port_detection.py`.

### `tests_v2/test_tab_dragging.py` :: `test_split_ratio_50_50 (lines 439-453)`
- **async-race** · severity medium · confidence medium
- **Evidence:** Lines 439-444: client.focus_surface(0); time.sleep(0.5); client.send_key('ctrl-c'); time.sleep(0.3); client.send(f'echo $(tput cols) > {cols_file_0}\n'). client.send() targets the globally focused surface, not a surface by index. The same pattern repeats for surface 1 at lines 448-453.
- **Why flaky:** focus_surface() is async: the app may not have propagated the focus change before the 0.5 s sleep expires under CI load. client.send() without a surface_idx targets whatever the app considers currently focused, which may still be the previous surface. The result is that both echo commands land in the same terminal, one file is written twice and the other never written, causing either a parse failure or a spurious column-count mismatch.
- **Suggested fix:** Use client.send_surface(0, ...) and client.send_surface(1, ...) with explicit surface indices (or surface IDs) instead of focus_surface() + generic send(), eliminating the focus-race entirely.

### `tests_v2/test_terminal_multi_image_drop.py` :: `main (_run_bracketed_paste_case, paste timing assertion at line 233)`
- **wall-clock-timing-assert** · severity medium · confidence high
- **Evidence:** Lines 116-118 in the embedded Python script: last_data_at = time.time(); while len(end_times) < data.count(b'\x1b[201~'): end_times.append(last_data_at). Line 233: paste_end_times[1] - paste_end_times[0] >= 1.0.
- **Why flaky:** If both end-markers arrive in a single os.read() chunk (common when the app's delay is short or the PTY buffer drains in one read), data.count(b'\x1b[201~') jumps from 0 to 2 and the inner while loop runs twice in the same iteration, appending the same last_data_at timestamp to both entries. The resulting delta is ~0 ms, causing the >= 1.0 assertion to fail even though the app correctly spaced the paste transactions 2 seconds apart.
- **Suggested fix:** Record the timestamp inside the while loop on first observation: instead of appending last_data_at, track a separate per-end-marker timestamp by recording time.time() on the first and second increment separately, e.g. end_times.append(time.time()) inside the while body rather than using last_data_at from the outer block.

### `tests_v2/test_browser_api_extended_families.py` :: `main`
- **resource-leak** · severity low · confidence high
- **Evidence:** Line 339: `state_path = tempfile.NamedTemporaryFile(delete=False, ...).name` is created but never cleaned up on failure or success. Line 251-252: `download_path` is unlinked before use but the file written by the background thread (line 256) is also never cleaned up on failure paths.
- **Why flaky:** Not directly flaky, but on repeated CI runs these orphaned temp files accumulate in `/tmp`. If the filesystem fills up or a stale state file from a prior broken run is picked up by another test, subsequent runs can fail for unrelated reasons.
- **Suggested fix:** Wrap the state file creation in a `try/finally` block that calls `os.unlink(state_path, missing_ok=True)` on exit, matching the pattern used by `test_cli_new_workspace_command_queue.py`.



---

## Fix outcome (team-fix workflow `.flaky-audit/team-fix.mjs`)

Coordinated area-teams adversarially verified the candidates above, then applied only genuinely-flaky, safely-fixable, statically-validated changes. Validation: `py_compile` (Python), `bash -n` (shell), `swift build --build-tests` (package Swift, compiles tests without running them); app-target Swift (`cmuxTests`/`cmuxUITests`) is CI-compiled. No test was executed against a live socket.

**38 findings fixed.** 37 are purely test-only. The 38th (`MobileCoreRPCClientTests` cancelled-while-queued race) genuinely cannot be made deterministic from the test alone — the writer-gate queue state is private to the production `MobileCoreRPCSession` actor — so it is fixed with a `#if DEBUG`, read-only `debugQueuedRequestCount()` accessor on the session and client, added to the file's existing `#if DEBUG` test-support extension (which already exposes `debugWithRequestTimeout`). It is compiled out of Release builds, changes no shipping-build behavior, and the test now waits on that real gate signal instead of spinning a fixed `Task.yield()` count.

### Refuted / skipped by the verification gate

- `test_command_palette_switcher_surface_precedence.py` — The prescribed fix is unsafe and counterproductive. (1) The primary path uses a server method that does not exist: I grepped the registered socket methods in Packages/macOS/CmuxControlSocket/.../Contr
- `test_codex_hook_agent_ports.py` — The fix instruction is self-refuting and concludes "Mark skipped / no code change is needed." Verified against the file: the duplicate-port guard the instruction relies on already exists at lines 325-
- `test_socket_access.py` — No edit needed: the prescribed minimal fallback fix is already present in the file. The instruction's safe minimum was "generate a unique hook_file path using os.getpid()". In test_internal_process_al
- `TailscaleStatusTests.swift` — Finding [1]'s stated mechanism is factually wrong. It claims staleInstant (line 165, call it T1) could equal refresh()'s internal stamp (line 71, T2) and thereby let the stale apply(.active, evaluated
- `SyncFrameAndProtocolTests.swift` — Finding [1] is not genuinely flaky. In FlagTests.envOverrideWins (lines 385-386) both #expect calls pass a non-empty CMUX_MOBILE_DEVICE_LIST_LOCAL_FIRST env value ("1" and "0"). resolved() checks the
- `BrowserOmnibarPageFocusRepositoryTests.swift` — Finding [1] (invalidateAbortsPendingRetry) is not genuinely flaky and the only proposed fix is a risky production change. The test is @MainActor async, so the main actor executor IS the main dispatch
- `JSONConfigStoreTests.swift` — Finding [1] is not a genuine flake. (a) fatalError in withTimeout is unreachable in normal runs: the work child task returns non-optional T wrapped as T? (always non-nil); if the timeout task returns
- `HostingInvalidationTests.swift` — Finding [1] (async-race in the three @Test methods via the pump(until:) helper) is refuted; no safe behavior-preserving fix exists, so I made no edit.

Why it is not genuinely flaky: pump(until:) poll
- `RenderWorkerClientTests.swift` — Finding [1]'s core premise is factually wrong. It claims Swift Testing's `Issue.record(...)` "does not stop the test" so the tests "silently pass" with all.count==1 or recoveryContext==nil. But `Issue
