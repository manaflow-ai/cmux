import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite
struct CmuxTopProcessSnapshotStoreTests {
    @Test
    func concurrentEquivalentRequestsShareOneCapture() async {
#if DEBUG
        ProcessPerformanceMetrics.shared.reset()
#endif
        let capturer = ControlledProcessSnapshotCapturer()
        let clock = ProcessSnapshotTestClock(now: Date(timeIntervalSince1970: 100))
        let store = CmuxTopProcessSnapshotStore(
            now: { await clock.read() },
            capture: { requirements in
                await capturer.capture(requirements: requirements)
            }
        )

        let first = Task {
            await store.snapshot(
                requirements: .basic,
                maximumAge: 10,
                consumer: .portScannerPanel
            )
        }
        await capturer.waitForCallCount(1)
        let second = Task {
            await store.snapshot(
                requirements: .basic,
                maximumAge: 10,
                consumer: .portScannerPanel
            )
        }
        await capturer.releaseNext()

        let firstSnapshot = await first.value
        let secondSnapshot = await second.value
        #expect(firstSnapshot === secondSnapshot)
        #expect(await capturer.callCount() == 1)
        #expect(await capturer.maximumConcurrentCaptures() == 1)
#if DEBUG
        let metrics = ProcessPerformanceMetrics.shared.snapshot()
        #expect(metrics.processSnapshots.captureStarted == 1)
        #expect(metrics.processSnapshots.captureCompleted == 1)
        #expect(metrics.processSnapshots.maximumInFlight == 1)
        #expect(metrics.processSnapshots.lastGeneration == 1)
        #expect(
            metrics.consumerGenerationReuse[ProcessSnapshotConsumer.portScannerPanel.rawValue]?[1]?.inFlight == 1
        )
#endif
    }

    @Test
    func strongerRequestWaitsForAndThenUpgradesWeakerCapture() async {
        let capturer = ControlledProcessSnapshotCapturer()
        let clock = ProcessSnapshotTestClock(now: Date(timeIntervalSince1970: 100))
        let store = CmuxTopProcessSnapshotStore(
            now: { await clock.read() },
            capture: { requirements in
                await capturer.capture(requirements: requirements)
            }
        )

        let basic = Task {
            await store.snapshot(requirements: .basic, maximumAge: 0)
        }
        await capturer.waitForCallCount(1)
        let detailed = Task {
            await store.snapshot(requirements: [.processDetails, .cmuxScope], maximumAge: 0)
        }

        await capturer.releaseNext()
        _ = await basic.value
        await capturer.waitForCallCount(2)
        await capturer.releaseNext()
        let detailedSnapshot = await detailed.value

        #expect(detailedSnapshot.hasCMUXScope)
        #expect(await capturer.capturedRequirements() == [
            .basic,
            [.processDetails, .cmuxScope]
        ])
        #expect(await capturer.maximumConcurrentCaptures() == 1)
    }

    @Test
    func cacheRespectsFreshnessAndCapabilityRequirements() async {
#if DEBUG
        ProcessPerformanceMetrics.shared.reset()
#endif
        let capturer = ControlledProcessSnapshotCapturer(autoRelease: true)
        let clock = ProcessSnapshotTestClock(now: Date(timeIntervalSince1970: 100))
        let store = CmuxTopProcessSnapshotStore(
            now: { await clock.read() },
            capture: { requirements in
                await capturer.capture(requirements: requirements)
            }
        )

        let first = await store.snapshot(
            requirements: .basic,
            maximumAge: 3,
            consumer: .processDetectedResume
        )
        await clock.advance(by: 2)
        let cached = await store.snapshot(
            requirements: .basic,
            maximumAge: 3,
            consumer: .processDetectedResume
        )
        let upgraded = await store.snapshot(
            requirements: .processDetails,
            maximumAge: 3,
            consumer: .processDetectedResume
        )
        await clock.advance(by: 4)
        let refreshed = await store.snapshot(
            requirements: .basic,
            maximumAge: 3,
            consumer: .processDetectedResume
        )

        #expect(first === cached)
        #expect(upgraded !== cached)
        #expect(refreshed !== upgraded)
        #expect(await capturer.callCount() == 3)
#if DEBUG
        let metrics = ProcessPerformanceMetrics.shared.snapshot()
        #expect(
            metrics.consumerGenerationReuse[ProcessSnapshotConsumer.processDetectedResume.rawValue]?[1]?.cache == 1
        )
#endif
    }
}

@Suite
struct PortScannerSharedSnapshotTests {
    @Test
    func staleRevisionIsRejectedAndCounted() {
#if DEBUG
        ProcessPerformanceMetrics.shared.reset()
        #expect(!PortScanner.acceptsResult(
            currentRevision: 8,
            expectedRevision: 7,
            staleMetric: .portAgentRevision
        ))
        #expect(PortScanner.acceptsResult(
            currentRevision: 8,
            expectedRevision: 8,
            staleMetric: .portAgentRevision
        ))
        let metrics = ProcessPerformanceMetrics.shared.snapshot()
        #expect(metrics.staleRejections[ProcessStaleRejection.portAgentRevision.rawValue] == 1)
#endif
    }

    @Test
    func processTreeExpansionIncludesForksAndDetachedAgentRoots() {
        let firstWorkspace = UUID()
        let detachedWorkspace = UUID()
        let snapshot = processSnapshot([
            process(pid: 10, parentPID: 1),
            process(pid: 20, parentPID: 10),
            process(pid: 30, parentPID: 20),
            process(pid: 90, parentPID: 1),
            process(pid: 91, parentPID: 90)
        ])

        let expanded = PortScanner.expandAgentProcessTree(
            agentPIDsByWorkspace: [
                firstWorkspace: [10],
                detachedWorkspace: [90]
            ],
            processSnapshot: snapshot
        )

        #expect(expanded[10] == [firstWorkspace])
        #expect(expanded[20] == [firstWorkspace])
        #expect(expanded[30] == [firstWorkspace])
        #expect(expanded[90] == [detachedWorkspace])
        #expect(expanded[91] == [detachedWorkspace])
    }

    @Test
    func lsofParsingReportsCurrentListenersAndDropsClosedPorts() {
        let open = PortScanner.parseLsofOutput(
            """
            p20
            n127.0.0.1:3000
            n*:8080
            p30
            n[::1]:9229
            """
        )
        let closed = PortScanner.parseLsofOutput("")

        #expect(open[20] == [3000, 8080])
        #expect(open[30] == [9229])
        #expect(closed.isEmpty)
    }

    private func processSnapshot(_ processes: [CmuxTopProcessInfo]) -> CmuxTopProcessSnapshot {
        CmuxTopProcessSnapshot(
            processes: processes,
            sampledAt: Date(),
            includesProcessDetails: false,
            includesCMUXScope: false
        )
    }

    private func process(pid: Int, parentPID: Int) -> CmuxTopProcessInfo {
        CmuxTopProcessInfo(
            pid: pid,
            parentPID: parentPID,
            name: "process-\(pid)",
            path: nil,
            ttyDevice: nil,
            cmuxWorkspaceID: nil,
            cmuxSurfaceID: nil,
            cmuxAttributionReason: nil,
            processGroupID: pid,
            terminalProcessGroupID: nil,
            cpuPercent: 0,
            residentBytes: 0,
            virtualBytes: 0,
            threadCount: 1
        )
    }
}

private actor ControlledProcessSnapshotCapturer {
    private let autoRelease: Bool
    private var requirements: [CmuxTopProcessSnapshotRequirements] = []
    private var activeCaptures = 0
    private var maximumActiveCaptures = 0
    private var releases: [CheckedContinuation<Void, Never>] = []
    private var callCountWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    init(autoRelease: Bool = false) {
        self.autoRelease = autoRelease
    }

    func capture(requirements: CmuxTopProcessSnapshotRequirements) async -> CmuxTopProcessSnapshot {
        self.requirements.append(requirements)
        activeCaptures += 1
        maximumActiveCaptures = max(maximumActiveCaptures, activeCaptures)
        resumeSatisfiedCallCountWaiters()
        if !autoRelease {
            await withCheckedContinuation { continuation in
                releases.append(continuation)
            }
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
        guard !releases.isEmpty else { return }
        releases.removeFirst().resume()
    }

    func callCount() -> Int {
        requirements.count
    }

    func capturedRequirements() -> [CmuxTopProcessSnapshotRequirements] {
        requirements
    }

    func maximumConcurrentCaptures() -> Int {
        maximumActiveCaptures
    }

    private func resumeSatisfiedCallCountWaiters() {
        let satisfied = callCountWaiters.filter { requirements.count >= $0.count }
        callCountWaiters.removeAll { requirements.count >= $0.count }
        for waiter in satisfied {
            waiter.continuation.resume()
        }
    }
}

private actor ProcessSnapshotTestClock {
    private var now: Date

    init(now: Date) {
        self.now = now
    }

    func read() -> Date {
        now
    }

    func advance(by interval: TimeInterval) {
        now = now.addingTimeInterval(interval)
    }
}
