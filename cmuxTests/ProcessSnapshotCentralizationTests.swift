import CmuxAgentChat
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite
struct ProcessSnapshotCentralizationTests {
    @Test
    func liveRuntimeConsumersShareOneCentralCapture() async throws {
        let capturer = CentralizedProcessSnapshotCapturer()
        let clock = CentralizedProcessSnapshotClock(now: Date(timeIntervalSince1970: 100))
        let store = CmuxTopProcessSnapshotStore(
            now: { await clock.read() },
            capture: { requirements in
                await capturer.capture(requirements: requirements)
            }
        )
        let homeDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-process-centralization-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: homeDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: homeDirectory) }

        let surfaceID = UUID().uuidString
        let liveness = Task {
            await AgentChatSessionRegistry.liveAgentPID(
                surfaceID: surfaceID,
                kind: .claude,
                matchingSessionIDs: ["session"],
                snapshotStore: store
            )
        }
        await capturer.waitForCallCount(1)

        let resumeIndexes = Task {
            await ProcessDetectedResumeIndexes.load(
                homeDirectory: homeDirectory.path,
                fileManager: .default,
                snapshotStore: store
            )
        }
        await clock.waitForReadCount(2)
        await capturer.releaseNext()

        #expect(await liveness.value == nil)
        _ = await resumeIndexes.value
        #expect(await capturer.callCount() == 1)
        #expect(await capturer.maximumConcurrentCaptures() == 1)
        #expect(await capturer.capturedRequirements() == [[.processDetails, .cmuxScope]])
    }

#if DEBUG
    @Test
    func synchronousCompatibilityCaptureIsIncludedInProofMetrics() {
        let metrics = ProcessPerformanceMetrics()

        let snapshot = CmuxTopProcessSnapshot.captureSynchronouslyForCompatibility(
            includeProcessDetails: true,
            includeCMUXScope: true,
            metrics: metrics,
            captureBody: { includeProcessDetails, includeCMUXScope in
                CmuxTopProcessSnapshot(
                    processes: [],
                    sampledAt: Date(timeIntervalSince1970: 101),
                    includesProcessDetails: includeProcessDetails,
                    includesCMUXScope: includeCMUXScope
                )
            }
        )

        let proof = metrics.snapshot().processSnapshots
        #expect(snapshot.hasCMUXScope)
        #expect(proof.captureStarted == 1)
        #expect(proof.captureCompleted == 1)
        #expect(proof.inFlight == 0)
        #expect(proof.maximumInFlight == 1)
    }
#endif
}

private actor CentralizedProcessSnapshotCapturer {
    private var requirements: [CmuxTopProcessSnapshotRequirements] = []
    private var activeCaptures = 0
    private var maximumActiveCaptures = 0
    private var releases: [CheckedContinuation<Void, Never>] = []
    private var callCountWaiters: [(Int, CheckedContinuation<Void, Never>)] = []

    func capture(requirements: CmuxTopProcessSnapshotRequirements) async -> CmuxTopProcessSnapshot {
        self.requirements.append(requirements)
        activeCaptures += 1
        maximumActiveCaptures = max(maximumActiveCaptures, activeCaptures)
        resumeSatisfiedCallCountWaiters()
        await withCheckedContinuation { continuation in
            releases.append(continuation)
        }
        activeCaptures -= 1
        return CmuxTopProcessSnapshot(
            processes: [],
            sampledAt: Date(timeIntervalSince1970: TimeInterval(self.requirements.count)),
            includesProcessDetails: requirements.contains(.processDetails),
            includesCMUXScope: requirements.contains(.cmuxScope)
        )
    }

    func waitForCallCount(_ count: Int) async {
        guard requirements.count < count else { return }
        await withCheckedContinuation { continuation in
            callCountWaiters.append((count, continuation))
        }
    }

    func releaseNext() {
        releases.removeFirst().resume()
    }

    func callCount() -> Int {
        requirements.count
    }

    func maximumConcurrentCaptures() -> Int {
        maximumActiveCaptures
    }

    func capturedRequirements() -> [CmuxTopProcessSnapshotRequirements] {
        requirements
    }

    private func resumeSatisfiedCallCountWaiters() {
        let satisfied = callCountWaiters.filter { requirements.count >= $0.0 }
        callCountWaiters.removeAll { requirements.count >= $0.0 }
        for (_, continuation) in satisfied {
            continuation.resume()
        }
    }
}

private actor CentralizedProcessSnapshotClock {
    private let now: Date
    private var readCount = 0
    private var readCountWaiters: [(Int, CheckedContinuation<Void, Never>)] = []

    init(now: Date) {
        self.now = now
    }

    func read() -> Date {
        readCount += 1
        resumeSatisfiedReadCountWaiters()
        return now
    }

    func waitForReadCount(_ count: Int) async {
        guard readCount < count else { return }
        await withCheckedContinuation { continuation in
            readCountWaiters.append((count, continuation))
        }
    }

    private func resumeSatisfiedReadCountWaiters() {
        let satisfied = readCountWaiters.filter { readCount >= $0.0 }
        readCountWaiters.removeAll { readCount >= $0.0 }
        for (_, continuation) in satisfied {
            continuation.resume()
        }
    }
}
