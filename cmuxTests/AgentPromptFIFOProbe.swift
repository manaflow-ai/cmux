import Foundation

actor AgentPromptFIFOProbe {
    private let workspaceID: UUID
    private let surfaceID: UUID
    private let firstStartedStream: AsyncStream<Void>
    private let firstStartedContinuation: AsyncStream<Void>.Continuation
    private let firstReleaseStream: AsyncStream<Void>
    private let firstReleaseContinuation: AsyncStream<Void>.Continuation
    private var activeDeliveries = 0
    private var maximumActiveDeliveries = 0
    private var started: [String] = []
    private var completed: [String] = []
    private var wireBytes = Data()

    init(workspaceID: UUID, surfaceID: UUID) {
        self.workspaceID = workspaceID
        self.surfaceID = surfaceID
        let firstStarted = AsyncStream<Void>.makeStream()
        firstStartedStream = firstStarted.stream
        firstStartedContinuation = firstStarted.continuation
        let firstRelease = AsyncStream<Void>.makeStream()
        firstReleaseStream = firstRelease.stream
        firstReleaseContinuation = firstRelease.continuation
    }

    var startedMessages: [String] {
        started
    }

    var completedMessages: [String] {
        completed
    }

    var submittedWireMessages: [String] {
        wireBytes.split(separator: 0x0D).compactMap {
            String(data: Data($0), encoding: .utf8)
        }
    }

    var maximumConcurrentDeliveries: Int {
        maximumActiveDeliveries
    }

    func waitUntilFirstStarted() async {
        for await _ in firstStartedStream.prefix(1) {
            return
        }
    }

    func releaseFirst() {
        firstReleaseContinuation.yield()
        firstReleaseContinuation.finish()
    }

    func deliver(
        _ message: String,
        waitsForRelease: Bool
    ) async -> AgentPromptSubmissionResult {
        activeDeliveries += 1
        maximumActiveDeliveries = max(
            maximumActiveDeliveries,
            activeDeliveries
        )
        started.append(message)
        if waitsForRelease {
            firstStartedContinuation.yield()
            firstStartedContinuation.finish()
            for await _ in firstReleaseStream.prefix(1) {
                break
            }
        }
        for byte in message.utf8 {
            wireBytes.append(byte)
            await Task.yield()
        }
        wireBytes.append(0x0D)
        completed.append(message)
        activeDeliveries -= 1
        return .submitted(
            workspaceID: workspaceID,
            surfaceID: surfaceID,
            queued: false
        )
    }
}
