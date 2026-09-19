import Foundation
import os
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite(.serialized)
struct CmuxTopProcessSnapshotCaptureCoordinatorTests {
    @Test("A many-process fixture shares one census and enrichment pass")
    func concurrentRequestsCoalesce() async throws {
        let baselineFixture = SyntheticProcessSnapshotFixture(processCount: 4_096)
        baselineFixture.release()
        for _ in 0..<8 {
            _ = baselineFixture.capture(includeDetails: true, includeScope: true)
        }
        let baseline = baselineFixture.counts.withLock { $0 }
        let fixture = SyntheticProcessSnapshotFixture(processCount: 4_096)
        let coordinator = CmuxTopProcessSnapshotCaptureCoordinator(
            captureProvider: { details, scope in
                fixture.capture(includeDetails: details, includeScope: scope)
            }
        )
        let requestsStarted = OSAllocatedUnfairLock(initialState: 0)
        let requestsReady = OSAllocatedUnfairLock(initialState: false)
        let tasks = (0..<8).map { _ in
            Task {
                requestsStarted.withLock { $0 += 1 }
                return coordinator.captureCached(
                    includeProcessDetails: true,
                    includeCMUXScope: true,
                    maximumAge: 2
                )
            }
        }
        for _ in 0..<10_000 {
            if requestsStarted.withLock({ $0 }) == 8 {
                requestsReady.withLock { $0 = true }
                break
            }
            await Task.yield()
        }
        #expect(requestsReady.withLock { $0 })
        fixture.release()
        let snapshots = try await tasks.asyncMap { try await $0.value }
        #expect(snapshots.dropFirst().allSatisfy { $0 === snapshots[0] })

        let counts = fixture.counts.withLock { $0 }
        print(
            "PROCESS_SNAPSHOT_FIXTURE processes=4096 consumers=8 " +
                "baseline_full_enumerations=\(baseline.enumerations) " +
                "full_enumerations=\(counts.enumerations) " +
                "proc_pidinfo_reads=\(counts.bsdReads) " +
                "resource_reads=\(counts.resourceReads) " +
                "scope_lookups=\(counts.scopeLookups)"
        )
        #expect(baseline.enumerations == 8)
        #expect(counts.enumerations == 1)
        #expect(counts.bsdReads == 4_096)
        #expect(counts.resourceReads == 8_192)
        #expect(counts.scopeLookups == 4_096)
    }

    @Test("Fresh requests do not reuse a completed census")
    func freshBoundary() {
        let fixture = SyntheticProcessSnapshotFixture(processCount: 512)
        let coordinator = CmuxTopProcessSnapshotCaptureCoordinator(
            captureProvider: { details, scope in
                fixture.capture(includeDetails: details, includeScope: scope)
            }
        )
        fixture.release()
        _ = coordinator.captureCoordinatedFresh(includeProcessDetails: false, includeCMUXScope: false)
        _ = coordinator.captureCoordinatedFresh(includeProcessDetails: false, includeCMUXScope: false)
        #expect(fixture.counts.withLock { $0.enumerations } == 2)
    }

    @Test("A cached request does not join an in-flight generation past its age bound")
    func inFlightFreshnessBound() async throws {
        let clock = SyntheticSnapshotClock()
        let fixture = SyntheticProcessSnapshotFixture(
            processCount: 1_024,
            timestampProvider: { clock.read() }
        )
        let coordinator = CmuxTopProcessSnapshotCaptureCoordinator(
            captureProvider: { details, scope in
                fixture.capture(includeDetails: details, includeScope: scope)
            },
            nowProvider: { clock.read() }
        )
        let first = Task {
            coordinator.captureCached(
                includeProcessDetails: true,
                includeCMUXScope: true,
                maximumAge: 2
            )
        }
        fixture.waitForFirstCapture()
        clock.advance(by: 3)
        let second = Task {
            coordinator.captureCached(
                includeProcessDetails: true,
                includeCMUXScope: true,
                maximumAge: 2
            )
        }
        clock.waitForReadCount(3)
        fixture.release()
        _ = await first.value
        _ = await second.value
        #expect(fixture.counts.withLock { $0.enumerations } == 2)
    }
}

private final class SyntheticProcessSnapshotFixture: @unchecked Sendable {
    struct Counts {
        var enumerations = 0
        var bsdReads = 0
        var resourceReads = 0
        var scopeLookups = 0
    }

    let processCount: Int
    let counts = OSAllocatedUnfairLock(initialState: Counts())
    private let condition = NSCondition()
    private var released = false
    private var shouldBlockFirstCapture = true
    private var firstCaptureStarted = false
    private let timestampProvider: @Sendable () -> Date

    init(
        processCount: Int,
        timestampProvider: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.processCount = processCount
        self.timestampProvider = timestampProvider
    }

    func release() {
        condition.lock()
        released = true
        condition.broadcast()
        condition.unlock()
    }

    func waitForFirstCapture() {
        condition.lock()
        while !firstCaptureStarted { condition.wait() }
        condition.unlock()
    }

    func capture(includeDetails: Bool, includeScope: Bool) -> CmuxTopProcessSnapshot {
        let sampledAt = timestampProvider()
        condition.lock()
        if shouldBlockFirstCapture {
            shouldBlockFirstCapture = false
            firstCaptureStarted = true
            condition.broadcast()
            while !released { condition.wait() }
        }
        condition.unlock()

        counts.withLock { $0.enumerations += 1 }
        var processes: [CmuxTopProcessInfo] = []
        processes.reserveCapacity(processCount)
        for pid in 1...processCount {
            counts.withLock {
                $0.bsdReads += 1
                $0.resourceReads += 2
                if includeScope { $0.scopeLookups += 1 }
            }
            processes.append(CmuxTopProcessInfo(
                pid: pid, parentPID: pid == 1 ? 0 : 1,
                name: includeDetails ? "fixture-\(pid)" : "fixture",
                path: includeDetails ? "/fixture/\(pid)" : nil,
                ttyDevice: nil, cmuxWorkspaceID: nil, cmuxSurfaceID: nil,
                cmuxAttributionReason: nil, processGroupID: nil,
                terminalProcessGroupID: nil, cpuPercent: 0,
                residentBytes: 1, virtualBytes: 1, threadCount: 1
            ))
        }
        return CmuxTopProcessSnapshot(
            processes: processes, sampledAt: sampledAt,
            includesProcessDetails: includeDetails,
            includesCMUXScope: includeScope
        )
    }
}

private final class SyntheticSnapshotClock: @unchecked Sendable {
    private let condition = NSCondition()
    private var value = Date(timeIntervalSince1970: 100)
    private var readCount = 0

    func read() -> Date {
        condition.lock()
        readCount += 1
        condition.broadcast()
        let result = value
        condition.unlock()
        return result
    }

    func waitForReadCount(_ expected: Int) {
        condition.lock()
        while readCount < expected {
            condition.wait()
        }
        condition.unlock()
    }

    func advance(by seconds: TimeInterval) {
        condition.lock()
        value.addTimeInterval(seconds)
        condition.unlock()
    }
}

private extension Array where Element == Task<CmuxTopProcessSnapshot, Never> {
    func asyncMap<T>(_ transform: @escaping (Element) async throws -> T) async rethrows -> [T] {
        var values: [T] = []
        values.reserveCapacity(count)
        for element in self { values.append(try await transform(element)) }
        return values
    }
}
