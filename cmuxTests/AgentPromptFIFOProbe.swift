import Darwin
import Foundation

/// Thread-safe test probe that can hold the first synchronous delivery while a
/// second caller queues on the main actor.
nonisolated final class AgentPromptFIFOProbe: @unchecked Sendable {
    private let workspaceID: UUID
    private let surfaceID: UUID
    private let condition = NSCondition()
    private var firstStarted = false
    private var firstReleased = false
    private var activeDeliveries = 0
    private var maximumActiveDeliveries = 0
    private var started: [String] = []
    private var completed: [String] = []
    private var wireBytes = Data()

    init(workspaceID: UUID, surfaceID: UUID) {
        self.workspaceID = workspaceID
        self.surfaceID = surfaceID
    }

    var startedMessages: [String] {
        condition.withLock { started }
    }

    var completedMessages: [String] {
        condition.withLock { completed }
    }

    var submittedWireMessages: [String] {
        condition.withLock {
            wireBytes.split(separator: 0x0D).compactMap {
                String(data: Data($0), encoding: .utf8)
            }
        }
    }

    var maximumConcurrentDeliveries: Int {
        condition.withLock { maximumActiveDeliveries }
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

    func deliver(
        _ message: String,
        waitsForRelease: Bool
    ) -> AgentPromptSubmissionResult {
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

        for byte in message.utf8 {
            condition.withLock {
                wireBytes.append(byte)
            }
            sched_yield()
        }

        condition.withLock {
            wireBytes.append(0x0D)
            completed.append(message)
            activeDeliveries -= 1
        }
        return .submitted(
            workspaceID: workspaceID,
            surfaceID: surfaceID,
            queued: false
        )
    }
}

nonisolated private extension NSCondition {
    func withLock<Result>(_ body: () -> Result) -> Result {
        lock()
        defer { unlock() }
        return body()
    }
}
