import Darwin
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Records every system effect instead of touching the machine, so these tests
/// can never lock, sleep, or reconfigure the host they run on.
private final class RecordingSleepyRunner: SleepyCommandRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var recordedTools: [String] = []

    var ranTools: [String] {
        lock.withLock { recordedTools }
    }

    func run(_ tool: String, _ args: [String]) async {
        lock.withLock { recordedTools.append(tool) }
    }

    func capture(_ tool: String, _ args: [String]) async -> String? { nil }

    @discardableResult
    func runPrivileged(_ tool: String, _ args: [String]) async -> Bool {
        lock.withLock { recordedTools.append(tool) }
        return false
    }
}

/// Supplies a thread-safe sequence of lock-state observations to the runner
/// seam, allowing confirmation tests to model delayed loginwindow state without
/// touching the host session.
private final class LockStateScript: @unchecked Sendable {
    // Safety: every mutable observation is accessed under `lock`.
    private let lock = NSLock()
    private var observations: [Bool?]

    init(_ observations: [Bool?]) {
        self.observations = observations
    }

    func read() -> Bool? {
        lock.withLock {
            guard !observations.isEmpty else { return nil }
            if observations.count == 1 { return observations[0] }
            return observations.removeFirst()
        }
    }
}

/// Counts invocations of the injected lock mechanism without calling the real
/// loginwindow API.
private final class LockInvocationProbe: @unchecked Sendable {
    // Safety: the invocation count is accessed only under `lock`.
    private let lock = NSLock()
    private var count = 0

    func record() {
        lock.withLock { count += 1 }
    }

    var invocationCount: Int {
        lock.withLock { count }
    }
}

@Suite("Sleepy Mode lock")
struct SleepyPowerControlsLockTests {
    /// Regression for https://github.com/manaflow-ai/cmux/issues/9730: macOS 26
    /// removed `User.menu` (and its `CGSession` binary) from the Menu Extras
    /// directory, so a lock implemented by shelling out to that path silently
    /// does nothing. The lock must not depend on that OS-internal binary.
    @MainActor
    @Test func lockMacDoesNotShellOutToRemovedCGSessionBinary() async throws {
        let runner = RecordingSleepyRunner()
        let suiteName = "SleepyPowerControlsLockTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let controls = SleepyPowerControls(runner: runner, defaults: defaults)

        await controls.lockMacNow()

        #expect(runner.ranTools.isEmpty)
    }

    /// The lock is an in-process system effect behind the runner seam: it must
    /// report the runner's result and never launch a subprocess.
    @MainActor
    @Test func lockMacEngagesTheRunnersInProcessLockWithoutSubprocesses() async throws {
        let runner = LockCapableRecordingRunner()
        let suiteName = "SleepyPowerControlsLockTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let controls = SleepyPowerControls(runner: runner, defaults: defaults)

        let locked = await controls.lockMacNow()

        #expect(locked)
        #expect(runner.lockScreenCalls == 1)
        #expect(runner.ranTools.isEmpty)
    }

    /// A runner without a lock mechanism (the protocol default) reports
    /// failure instead of pretending the Mac locked.
    @MainActor
    @Test func lockMacReportsFailureWhenNoLockMechanismIsAvailable() async throws {
        let runner = RecordingSleepyRunner()
        let suiteName = "SleepyPowerControlsLockTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let controls = SleepyPowerControls(runner: runner, defaults: defaults)

        let locked = await controls.lockMacNow()

        #expect(!locked)
    }

    /// Canary for the OS surface itself: `SACLockScreenImmediate` must resolve
    /// on the macOS this suite runs on. If a future macOS drops it the way
    /// macOS 26 dropped `CGSession`, this goes red instead of the Lock Mac
    /// button silently doing nothing again. Resolving the symbol does not
    /// invoke it, so this cannot lock the host.
    @Test func loginFrameworkLockResolvesOnThisMacOS() throws {
        let handle = try #require(
            dlopen("/System/Library/PrivateFrameworks/login.framework/login", RTLD_LAZY)
        )
        defer { _ = dlclose(handle) }

        #expect(dlsym(handle, "SACLockScreenImmediate") != nil)
    }

    /// The real runner must wait for the authoritative session bit after the
    /// in-process call, rather than treating symbol resolution or invocation as
    /// proof that the Mac is locked.
    @Test func lockScreenWaitsForAuthoritativeStateTransition() async {
        let invocation = LockInvocationProbe()
        let state = LockStateScript([false, true])
        let runner = SystemCommandRunner(
            lockConfirmationTimeout: .seconds(1),
            lockScreenInvoker: { invocation.record() },
            lockStateReader: { state.read() }
        )

        let confirmed = await runner.lockScreen()

        #expect(confirmed)
        #expect(invocation.invocationCount == 1)
    }

    /// A successful private-symbol call is not enough to claim a lock when the
    /// public session state never confirms the transition; the deadline fails
    /// closed and cleans up the notification stream.
    @Test func lockScreenTimesOutWithoutAuthoritativeConfirmation() async {
        let invocation = LockInvocationProbe()
        let runner = SystemCommandRunner(
            lockConfirmationTimeout: .milliseconds(100),
            lockScreenInvoker: { invocation.record() },
            lockStateReader: { false }
        )

        let confirmed = await runner.lockScreen()

        #expect(!confirmed)
        #expect(invocation.invocationCount == 1)
    }

    /// Missing authoritative state fails closed instead of claiming that the
    /// security-sensitive lock succeeded.
    @Test func lockScreenFailsClosedWhenStateIsUnavailable() async {
        let invocation = LockInvocationProbe()
        let runner = SystemCommandRunner(
            lockConfirmationTimeout: .milliseconds(100),
            lockScreenInvoker: { invocation.record() },
            lockStateReader: { nil }
        )

        let confirmed = await runner.lockScreen()

        #expect(!confirmed)
        #expect(invocation.invocationCount == 1)
    }

    /// Lifecycle cancellation is checked before the irreversible invocation,
    /// so a request canceled before the runner starts cannot lock the host.
    @Test func lockScreenHonorsCancellationBeforeInvocation() async {
        let invocation = LockInvocationProbe()
        let runner = SystemCommandRunner(
            lockScreenInvoker: { invocation.record() },
            lockStateReader: { true }
        )
        let gate = SleepyLockInvocationGate()
        gate.cancel()

        let confirmed = await runner.lockScreen(using: gate)

        #expect(!confirmed)
        #expect(invocation.invocationCount == 0)
    }

    /// Once the lock request has been issued, lifecycle task cancellation must
    /// stop the pending notification/poll/deadline race and report no success.
    @Test(.timeLimit(.minutes(1)))
    func lockScreenCancellationStopsPendingConfirmation() async {
        let invocation = LockInvocationProbe()
        let invocationObserved = AsyncStream<Void>.makeStream()
        let runner = SystemCommandRunner(
            lockConfirmationTimeout: .seconds(60),
            lockScreenInvoker: {
                invocation.record()
                invocationObserved.continuation.yield(())
            },
            lockStateReader: { false }
        )

        let task = Task { await runner.lockScreen() }
        var iterator = invocationObserved.stream.makeAsyncIterator()
        _ = await iterator.next()
        task.cancel()

        let confirmed = await task.value

        #expect(!confirmed)
        #expect(invocation.invocationCount == 1)
    }

    /// A completed lock attempt from an exited overlay must not restore its
    /// warning after the user starts a fresh Sleepy Mode session.
    @MainActor
    @Test func newSessionClearsAndRejectsPriorLockFailure() {
        let state = SleepyPowerUIState()
        state.beginSession()
        let exitedRequest = state.beginLockRequest()!
        state.recordLockResult(
            false,
            for: exitedRequest.sessionID,
            requestID: exitedRequest.requestID
        )
        #expect(state.lockFailed)

        state.beginSession()
        #expect(!state.lockFailed)

        state.recordLockResult(
            false,
            for: exitedRequest.sessionID,
            requestID: exitedRequest.requestID
        )
        #expect(!state.lockFailed)
    }

    /// A stale result from an older request must not overwrite a newer request.
    @MainActor
    @Test func lockResultsAreOrderedByRequestIdentity() throws {
        let state = SleepyPowerUIState()
        let first = try #require(state.beginLockRequest())
        state.recordLockResult(true, for: first.sessionID, requestID: first.requestID)
        let second = try #require(state.beginLockRequest())

        state.recordLockResult(false, for: first.sessionID, requestID: first.requestID)
        #expect(state.isLockBusy)
        #expect(!state.lockFailed)

        state.recordLockResult(true, for: second.sessionID, requestID: second.requestID)
        #expect(!state.isLockBusy)
        #expect(!state.lockFailed)
    }

    /// Leaving Sleepy Mode cancels its lifecycle-owned request slot, so a
    /// request that has not completed cannot keep the Lock Mac button busy or
    /// publish a stale failure into a later session.
    @MainActor
    @Test func cancellingLockRequestReleasesTheBusyState() throws {
        let state = SleepyPowerUIState()
        state.beginSession()
        let request = try #require(state.beginLockRequest())

        #expect(state.isLockBusy)
        state.cancelLockRequest()
        #expect(!state.isLockBusy)

        state.recordLockResult(false, for: request.sessionID, requestID: request.requestID)
        #expect(!state.lockFailed)
    }

    /// The UI-owned task is canceled at the lifecycle boundary instead of
    /// leaving a pending lock operation alive after the overlay closes.
    @MainActor
    @Test func lifecycleCancellationStopsPendingLockOperation() async throws {
        let runner = CancellableLockRunner()
        let suiteName = "SleepyPowerControlsLockTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let controls = SleepyPowerControls(runner: runner, defaults: defaults)
        let state = SleepyPowerUIState()
        state.beginSession()
        let request = try #require(state.beginLockRequest())

        state.runLockRequest(request, using: controls)
        await runner.waitUntilStarted()
        #expect(state.isLockBusy)

        state.cancelLockRequest()
        await runner.waitUntilCancelled()
        #expect(!state.isLockBusy)
        #expect(!state.lockFailed)
    }

    /// Cancellation that claims the pending request prevents the irreversible
    /// system effect.
    @Test func cancelledLockInvocationGateDoesNotInvoke() {
        let gate = SleepyLockInvocationGate()
        let cancelled = gate.cancel()
        let invoked = gate.invoke {}
        #expect(cancelled)
        #expect(!invoked)
    }

    /// Invocation and cancellation share one atomic transition, so an invocation
    /// that wins can run exactly once and later cancellation cannot change the
    /// already-committed outcome.
    @Test func lockInvocationGateHasOneAtomicWinner() {
        let invocation = LockInvocationProbe()
        let gate = SleepyLockInvocationGate()

        let invoked = gate.invoke { invocation.record() }
        let cancelled = gate.cancel()
        let invokedAgain = gate.invoke { invocation.record() }

        #expect(invoked)
        #expect(!cancelled)
        #expect(!invokedAgain)
        #expect(invocation.invocationCount == 1)
    }
}

/// Recording runner whose in-process lock succeeds, without touching the host.
private final class LockCapableRecordingRunner: SleepyCommandRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var recordedTools: [String] = []
    private var recordedLockScreenCalls = 0

    var ranTools: [String] {
        lock.withLock { recordedTools }
    }

    var lockScreenCalls: Int {
        lock.withLock { recordedLockScreenCalls }
    }

    func run(_ tool: String, _ args: [String]) async {
        lock.withLock { recordedTools.append(tool) }
    }

    func capture(_ tool: String, _ args: [String]) async -> String? { nil }

    @discardableResult
    func runPrivileged(_ tool: String, _ args: [String]) async -> Bool {
        lock.withLock { recordedTools.append(tool) }
        return false
    }

    @discardableResult
    #if compiler(>=6.2)
    @concurrent
    #else
    @Sendable
    #endif
    nonisolated func lockScreen() async -> Bool {
        lock.withLock { recordedLockScreenCalls += 1 }
        return true
    }
}

/// Holds a cancellable in-process lock request without touching the host.
private final class CancellableLockRunner: SleepyCommandRunning, @unchecked Sendable {
    private let startedStream: AsyncStream<Void>
    private let startedContinuation: AsyncStream<Void>.Continuation
    private let cancelledStream: AsyncStream<Void>
    private let cancelledContinuation: AsyncStream<Void>.Continuation

    init() {
        (startedStream, startedContinuation) = AsyncStream.makeStream()
        (cancelledStream, cancelledContinuation) = AsyncStream.makeStream()
    }

    func waitUntilStarted() async {
        var iterator = startedStream.makeAsyncIterator()
        _ = await iterator.next()
    }

    func waitUntilCancelled() async {
        var iterator = cancelledStream.makeAsyncIterator()
        _ = await iterator.next()
    }

    func run(_ tool: String, _ args: [String]) async {}

    func capture(_ tool: String, _ args: [String]) async -> String? { nil }

    @discardableResult
    func runPrivileged(_ tool: String, _ args: [String]) async -> Bool { false }

    @discardableResult
    #if compiler(>=6.2)
    @concurrent
    #else
    @Sendable
    #endif
    nonisolated func lockScreen() async -> Bool {
        startedContinuation.yield(())
        do {
            try await Task.sleep(for: .seconds(60))
            return true
        } catch {
            cancelledContinuation.yield(())
            return false
        }
    }
}
