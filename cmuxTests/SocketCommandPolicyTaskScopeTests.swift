import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Runs every job on one dedicated thread, so a test can pin exactly which
/// thread a socket command task resumes on.
@available(macOS 15.0, *)
private final class DedicatedThreadExecutor: TaskExecutor, @unchecked Sendable {
    private let condition = NSCondition()
    private var jobs: [UnownedJob] = []
    private var stopped = false

    init(name: String) {
        let thread = Thread { [self] in drain() }
        thread.name = name
        thread.start()
    }

    func enqueue(_ job: consuming ExecutorJob) {
        let job = UnownedJob(job)
        condition.lock()
        jobs.append(job)
        condition.signal()
        condition.unlock()
    }

    func stop() {
        condition.lock()
        stopped = true
        condition.broadcast()
        condition.unlock()
    }

    private func drain() {
        while true {
            condition.lock()
            while jobs.isEmpty, !stopped { condition.wait() }
            guard !jobs.isEmpty else {
                condition.unlock()
                return
            }
            let job = jobs.removeFirst()
            condition.unlock()
            job.runSynchronously(on: asUnownedTaskExecutor())
        }
    }
}

/// Task executors need the macOS 15 Swift runtime.
private let hasTaskExecutors = ProcessInfo.processInfo.isOperatingSystemAtLeast(
    OperatingSystemVersion(majorVersion: 15, minorVersion: 0, patchVersion: 0)
)

/// The focus decision of a socket command belongs to the command's task. A
/// command may resume on a different thread after any suspension, so a
/// decision kept only in thread-local storage is lost before the lane hop
/// that needs it (#13397 review).
@Suite("Socket command policy task scope", .serialized)
struct SocketCommandPolicyTaskScopeTests {
    /// A focus-mutating v2 command whose policy is a fixed `true`.
    private static let focusCommand = "browser.focus_mode.set"

    @Test("The main-actor lane sees the policy after the command changes threads", .enabled(if: hasTaskExecutors))
    func mainActorLaneSeesThePolicyAfterAThreadChange() async throws {
        guard #available(macOS 15.0, *) else { return }
        let entry = DedicatedThreadExecutor(name: "cmux.tests.policy-entry")
        let resumed = DedicatedThreadExecutor(name: "cmux.tests.policy-resumed")
        defer {
            entry.stop()
            resumed.stop()
        }
        let controller = TerminalController.shared

        let allowed = try await withTaskExecutorPreference(entry) {
            try await controller.withSocketCommandPolicyAsync(commandKey: Self.focusCommand, isV2: true) {
                // The command resumes on another thread before it hops.
                try await withTaskExecutorPreference(resumed) {
                    try await controller.v2MainAsync {
                        TerminalController.socketCommandAllowsInAppFocusMutations()
                    }
                }
            }
        }
        #expect(allowed)

        let leftBehind = await withTaskExecutorPreference(entry) {
            TerminalController.currentSocketCommandFocusAllowanceStack()
        }
        #expect(leftBehind.isEmpty)
    }

    @Test("The blocking worker lane sees the policy after the command changes threads", .enabled(if: hasTaskExecutors))
    func workerLaneSeesThePolicyAfterAThreadChange() async throws {
        guard #available(macOS 15.0, *) else { return }
        let entry = DedicatedThreadExecutor(name: "cmux.tests.policy-entry")
        let resumed = DedicatedThreadExecutor(name: "cmux.tests.policy-resumed")
        defer {
            entry.stop()
            resumed.stop()
        }
        let controller = TerminalController.shared

        let allowed = try await withTaskExecutorPreference(entry) {
            try await controller.withSocketCommandPolicyAsync(commandKey: Self.focusCommand, isV2: true) {
                await withTaskExecutorPreference(resumed) {
                    await controller.runSocketWorkerBlockingBody {
                        TerminalController.socketCommandAllowsInAppFocusMutations()
                    }
                }
            }
        }
        #expect(allowed)
    }

    @Test("Nested command scopes stack on the task, and the outer scope survives the inner one")
    func nestedScopesStackOnTheTask() async throws {
        let controller = TerminalController.shared
        let seen = try await controller.withSocketCommandPolicyAsync(commandKey: Self.focusCommand, isV2: true) {
            let inner = try await controller.withSocketCommandPolicyAsync(commandKey: "browser.reload", isV2: true) {
                try await controller.v2MainAsync {
                    TerminalController.socketCommandAllowsInAppFocusMutations()
                }
            }
            let outer = try await controller.v2MainAsync {
                TerminalController.socketCommandAllowsInAppFocusMutations()
            }
            return (inner: inner, outer: outer)
        }
        #expect(!seen.inner)
        #expect(seen.outer)
    }
}
