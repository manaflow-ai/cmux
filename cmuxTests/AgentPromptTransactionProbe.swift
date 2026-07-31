import CmuxTerminal
import Foundation

/// Thread-safe test probe that can hold the first synchronous delivery while a
/// second caller queues on the main actor.
///
/// Safety: the terminal surface is main-actor isolated and every nonisolated
/// mutable field is accessed while `condition` is locked.
nonisolated final class AgentPromptTransactionProbe: @unchecked Sendable {
    @MainActor private let surface: TerminalSurface
    private let condition = NSCondition()
    private var firstStarted = false
    private var firstReleased = false
    private var secondCallerReady = false
    private var activeDeliveries = 0
    private var maximumActiveDeliveries = 0
    private var started: [String] = []
    private var completed: [String] = []

    @MainActor
    init(surface: TerminalSurface) {
        self.surface = surface
    }

    var startedMessages: [String] {
        condition.withLock { started }
    }

    var completedMessages: [String] {
        condition.withLock { completed }
    }

    var maximumConcurrentDeliveries: Int {
        condition.withLock { maximumActiveDeliveries }
    }

    @MainActor
    var pendingPromptMessages: [String] {
        surface.debugPendingPromptSubmissionTextsForTesting()
    }

    func waitUntilFirstStarted() {
        condition.lock()
        while !firstStarted {
            condition.wait()
        }
        condition.unlock()
    }

    func releaseFirst() {
        condition.withLock {
            firstReleased = true
            condition.broadcast()
        }
    }

    func noteSecondCallerReady() {
        condition.withLock {
            secondCallerReady = true
            condition.broadcast()
        }
    }

    func waitUntilSecondCallerReady() {
        condition.lock()
        while !secondCallerReady {
            condition.wait()
        }
        condition.unlock()
    }

    @MainActor
    func deliver(
        _ message: String,
        waitsForRelease: Bool
    ) -> TerminalSurface.PromptSubmissionSendResult {
        condition.lock()
        activeDeliveries += 1
        maximumActiveDeliveries = max(
            maximumActiveDeliveries,
            activeDeliveries
        )
        started.append(message)
        if waitsForRelease {
            firstStarted = true
            condition.broadcast()
            while !firstReleased {
                condition.wait()
            }
        }
        condition.unlock()

        let result = surface.sendPromptSubmission(
            message,
            submitKey: "return",
            hookRecordingSource: "workspace.agent_submit"
        )

        condition.withLock {
            completed.append(message)
            activeDeliveries -= 1
        }
        return result
    }
}

nonisolated private extension NSCondition {
    func withLock<Result>(_ body: () -> Result) -> Result {
        lock()
        defer { unlock() }
        return body()
    }
}
