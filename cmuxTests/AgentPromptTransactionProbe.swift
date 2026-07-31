import Foundation
import Testing
@testable import CmuxTerminal

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
        surface.pendingSocketInputQueue.compactMap { item in
            guard case .promptSubmission(let text, _, _, _) = item else {
                return nil
            }
            return String(bytes: text, encoding: .utf8)
        }
    }

    func waitUntilFirstStarted() -> Bool {
        condition.lock()
        defer { condition.unlock() }
        let deadline = Date().addingTimeInterval(5)
        while !firstStarted {
            guard condition.wait(until: deadline) else {
                return firstStarted
            }
        }
        return true
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

    func waitUntilSecondCallerReady() -> Bool {
        condition.lock()
        defer { condition.unlock() }
        let deadline = Date().addingTimeInterval(5)
        while !secondCallerReady {
            guard condition.wait(until: deadline) else {
                return secondCallerReady
            }
        }
        return true
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
            let deadline = Date().addingTimeInterval(5)
            while !firstReleased {
                let signaled = condition.wait(until: deadline)
                #expect(signaled)
                guard signaled else { break }
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

@MainActor
extension TerminalSurface {
    var pendingPromptSubmissionCountForTests: Int {
        pendingSocketInputQueue.reduce(into: 0) { count, item in
            if case .promptSubmission = item {
                count += 1
            }
        }
    }
}

nonisolated private extension NSCondition {
    func withLock<Result>(_ body: () -> Result) -> Result {
        lock()
        defer { unlock() }
        return body()
    }
}
