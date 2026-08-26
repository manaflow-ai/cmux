import Foundation
import Testing
@testable import CmuxTerminal

/// Thread-safe test probe that can hold the first synchronous delivery while a
/// second caller queues on the main actor.
///
/// Safety: the terminal surface is main-actor isolated and every nonisolated
/// mutable field is accessed while `condition` is locked.
nonisolated final class AgentPromptTransactionProbe: @unchecked Sendable {
    enum SurfaceTarget: Sendable {
        case first
        case second
    }

    @MainActor private let firstSurface: TerminalSurface
    @MainActor private let secondSurface: TerminalSurface
    private let condition = NSCondition()
    private var firstStarted = false
    private var firstReleased = false
    private var activeDeliveries = 0
    private var maximumActiveDeliveries = 0
    private var started: [String] = []
    private var completed: [String] = []

    @MainActor
    init(firstSurface: TerminalSurface, secondSurface: TerminalSurface) {
        self.firstSurface = firstSurface
        self.secondSurface = secondSurface
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
    func pendingPromptMessages(for target: SurfaceTarget) -> [String] {
        let surface = surface(for: target)
        return surface.pendingSocketInputQueue.compactMap { item -> String? in
            guard case .promptSubmission(_, let text, _, _, _) = item else {
                return nil
            }
            return String(bytes: text, encoding: .utf8)
        }
    }

    @MainActor
    func releaseSurfacesForTesting() {
        firstSurface.releaseSurfaceForTesting()
        secondSurface.releaseSurfaceForTesting()
    }

    func waitUntilFirstStarted() -> Bool {
        condition.lock()
        defer { condition.unlock() }
        let deadline = Date.now.addingTimeInterval(5)
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

    func waitUntilCompletedMessages(_ count: Int) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        let deadline = Date.now.addingTimeInterval(5)
        while completed.count < count {
            guard condition.wait(until: deadline) else {
                return completed.count >= count
            }
        }
        return true
    }

    @MainActor
    func deliver(
        _ message: String,
        to target: SurfaceTarget,
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
            let deadline = Date.now.addingTimeInterval(5)
            while !firstReleased {
                let signaled = condition.wait(until: deadline)
                #expect(signaled)
                guard signaled else { break }
            }
        }
        condition.unlock()

        let result = surface(for: target).sendPromptSubmission(
            message,
            submitKey: "return",
            hookRecordingSource: "workspace.agent_submit"
        )

        condition.withLock {
            completed.append(message)
            activeDeliveries -= 1
            condition.broadcast()
        }
        return result
    }

    @MainActor
    private func surface(for target: SurfaceTarget) -> TerminalSurface {
        switch target {
        case .first:
            firstSurface
        case .second:
            secondSurface
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

@MainActor
extension TerminalSurface {
    var pendingPromptPreparationKeyLabelsForTests: [[String]] {
        pendingSocketInputQueue.compactMap { item -> [String]? in
            guard case .promptSubmission(
                let preparationKeys,
                _,
                _,
                _,
                _
            ) = item else {
                return nil
            }
            return preparationKeys.map(\.label)
        }
    }

    var pendingSocketInputSnapshotForTests: (
        items: Int,
        bytes: Int,
        keyEvents: Int,
        pasteTextItems: Int,
        promptSubmissionItems: Int,
        inputTextItems: Int,
        processOutputItems: Int
    ) {
        let counts = pendingSocketInputQueue.reduce(
            into: (
                keyEvents: 0,
                pasteTextItems: 0,
                promptSubmissionItems: 0,
                inputTextItems: 0,
                processOutputItems: 0
            )
        ) { counts, item in
            switch item {
            case .key, .keyText:
                counts.keyEvents += 1
            case .pasteText:
                counts.pasteTextItems += 1
            case .promptSubmission:
                counts.promptSubmissionItems += 1
            case .inputText:
                counts.inputTextItems += 1
            case .processOutput:
                counts.processOutputItems += 1
            }
        }
        return (
            pendingSocketInputQueue.count,
            pendingSocketInputBytes,
            counts.keyEvents,
            counts.pasteTextItems,
            counts.promptSubmissionItems,
            counts.inputTextItems,
            counts.processOutputItems
        )
    }
}
