import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

private final class RecordingMemoryPressureResponder: MemoryPressureResponder {
    let memoryPressureResponderID: String
    let memoryPressureMinimumSeverity: MemoryPressureSeverity
    let memoryPressurePriority: Int
    let result: MemoryPressureShedResult
    var calls: [MemoryPressureSnapshot] = []

    init(
        id: String,
        minimumSeverity: MemoryPressureSeverity,
        priority: Int,
        result: MemoryPressureShedResult = .init(reclaimedItemCount: 1)
    ) {
        memoryPressureResponderID = id
        memoryPressureMinimumSeverity = minimumSeverity
        memoryPressurePriority = priority
        self.result = result
    }

    func shedMemory(for snapshot: MemoryPressureSnapshot) -> MemoryPressureShedResult {
        calls.append(snapshot)
        return result
    }
}

private struct FixedMemoryPressureFootprintSampler: MemoryPressureFootprintSampling {
    let bytes: UInt64?

    func physicalFootprintBytes() -> UInt64? {
        bytes
    }
}

@Suite
struct MemoryPressureFootprintThresholdsScalingTests {
    @Test func floorClampsSmallRAM() {
        let thresholds = MemoryPressureFootprintThresholds.scaled(
            forPhysicalMemoryBytes: Self.gib(8)
        )

        #expect(thresholds.warningBytes == Self.gib(2))
        #expect(thresholds.criticalBytes == Self.gib(4))
    }

    @Test func usesRatioInsideClampRange() {
        let thresholds = MemoryPressureFootprintThresholds.scaled(
            forPhysicalMemoryBytes: Self.gib(36)
        )

        #expect(thresholds.warningBytes == Self.gib(3))
        #expect(thresholds.criticalBytes == Self.gib(6))
    }

    @Test(arguments: [UInt64(128), UInt64(256)])
    func ceilingClampsLargeRAM(physicalMemoryGiB: UInt64) {
        let thresholds = MemoryPressureFootprintThresholds.scaled(
            forPhysicalMemoryBytes: Self.gib(physicalMemoryGiB)
        )

        #expect(thresholds.warningBytes == Self.gib(6))
        #expect(thresholds.criticalBytes == Self.gib(12))
    }

    @Test func degenerateAndSweptRAMValuesKeepValidOrdering() {
        let zero = MemoryPressureFootprintThresholds.scaled(forPhysicalMemoryBytes: 0)

        #expect(zero.warningBytes == Self.gib(2))
        #expect(zero.criticalBytes == Self.gib(4))

        var physicalMemoryGiB: UInt64 = 4
        while physicalMemoryGiB <= 256 {
            let thresholds = MemoryPressureFootprintThresholds.scaled(
                forPhysicalMemoryBytes: Self.gib(physicalMemoryGiB)
            )

            #expect(thresholds.criticalBytes >= thresholds.warningBytes)
            #expect(thresholds.warningBytes > 0)

            physicalMemoryGiB += 4
        }
    }

    @Test func defaultUsesPhysicalMemoryScaledFactory() {
        #expect(
            MemoryPressureFootprintThresholds.default ==
                .scaled(forPhysicalMemoryBytes: ProcessInfo.processInfo.physicalMemory)
        )
    }

    private static func gib(_ value: UInt64) -> UInt64 {
        value * 1024 * 1024 * 1024
    }
}

struct MemoryPressureStateTrackerTests {
    @Test func footprintThresholdsMapToSeverity() {
        let thresholds = MemoryPressureFootprintThresholds(
            warningBytes: 1_000,
            criticalBytes: 2_000
        )

        #expect(thresholds.severity(forPhysicalFootprintBytes: nil) == .normal)
        #expect(thresholds.severity(forPhysicalFootprintBytes: 999) == .normal)
        #expect(thresholds.severity(forPhysicalFootprintBytes: 1_000) == .warning)
        #expect(thresholds.severity(forPhysicalFootprintBytes: 1_999) == .warning)
        #expect(thresholds.severity(forPhysicalFootprintBytes: 2_000) == .critical)
    }

    @Test func systemEventsAndFootprintSamplesDriveSeverityTransitions() {
        let thresholds = MemoryPressureFootprintThresholds(
            warningBytes: 1_000,
            criticalBytes: 2_000
        )
        var tracker = MemoryPressureStateTracker(
            thresholds: thresholds,
            criticalPersistenceDuration: 10
        )
        let start = Date(timeIntervalSince1970: 100)

        let warning = tracker.ingest(
            systemSeverity: .warning,
            physicalFootprintBytes: 500,
            sampledAt: start
        )
        #expect(warning.previousSeverity == .normal)
        #expect(warning.snapshot.severity == .warning)
        #expect(warning.didTransition)

        let critical = tracker.ingest(
            systemSeverity: nil,
            physicalFootprintBytes: 2_500,
            sampledAt: start.addingTimeInterval(1)
        )
        #expect(critical.previousSeverity == .warning)
        #expect(critical.snapshot.severity == .critical)
        #expect(critical.didTransition)

        let cleared = tracker.ingest(
            systemSeverity: nil,
            physicalFootprintBytes: 100,
            sampledAt: start.addingTimeInterval(2)
        )
        #expect(cleared.previousSeverity == .critical)
        #expect(cleared.snapshot.severity == .normal)
        #expect(cleared.didTransition)
    }

    @Test func persistentCriticalPressureFiresOncePerCriticalEpisode() {
        let thresholds = MemoryPressureFootprintThresholds(
            warningBytes: 1_000,
            criticalBytes: 2_000
        )
        var tracker = MemoryPressureStateTracker(
            thresholds: thresholds,
            criticalPersistenceDuration: 10
        )
        let start = Date(timeIntervalSince1970: 1_000)

        let initialCritical = tracker.ingest(
            systemSeverity: .critical,
            physicalFootprintBytes: nil,
            sampledAt: start
        )
        #expect(!initialCritical.didBecomePersistentCritical)

        let beforePersistence = tracker.ingest(
            systemSeverity: nil,
            physicalFootprintBytes: 2_500,
            sampledAt: start.addingTimeInterval(9)
        )
        #expect(!beforePersistence.didBecomePersistentCritical)

        let persistent = tracker.ingest(
            systemSeverity: nil,
            physicalFootprintBytes: 2_500,
            sampledAt: start.addingTimeInterval(10)
        )
        #expect(persistent.didBecomePersistentCritical)

        let stillCritical = tracker.ingest(
            systemSeverity: .critical,
            physicalFootprintBytes: 2_500,
            sampledAt: start.addingTimeInterval(20)
        )
        #expect(!stillCritical.didBecomePersistentCritical)

        _ = tracker.ingest(
            systemSeverity: nil,
            physicalFootprintBytes: 100,
            sampledAt: start.addingTimeInterval(21)
        )
        _ = tracker.ingest(
            systemSeverity: .critical,
            physicalFootprintBytes: nil,
            sampledAt: start.addingTimeInterval(30)
        )
        let secondEpisode = tracker.ingest(
            systemSeverity: .critical,
            physicalFootprintBytes: nil,
            sampledAt: start.addingTimeInterval(40)
        )
        #expect(secondEpisode.didBecomePersistentCritical)
    }
}

@MainActor
@Suite(.serialized)
struct MemoryPressureResponderRegistryTests {
    @Test func dispatchesEligibleRespondersInPriorityOrder() {
        let registry = MemoryPressureResponderRegistry()
        let low = RecordingMemoryPressureResponder(
            id: "renderer",
            minimumSeverity: .warning,
            priority: 10,
            result: .init(reclaimedItemCount: 2, estimatedBytes: 20)
        )
        let high = RecordingMemoryPressureResponder(
            id: "browser",
            minimumSeverity: .warning,
            priority: 20,
            result: .init(reclaimedItemCount: 3, estimatedBytes: 30)
        )
        let criticalOnly = RecordingMemoryPressureResponder(
            id: "critical-only",
            minimumSeverity: .critical,
            priority: 100
        )
        registry.register(low)
        registry.register(high)
        registry.register(criticalOnly)

        let snapshot = MemoryPressureSnapshot(
            severity: .warning,
            physicalFootprintBytes: 1_500,
            sampledAt: Date(timeIntervalSince1970: 1)
        )
        let actions = registry.dispatch(snapshot)

        #expect(actions.map(\.responderID) == ["browser", "renderer"])
        #expect(actions.map(\.reclaimedItemCount) == [3, 2])
        #expect(high.calls.count == 1)
        #expect(low.calls.count == 1)
        #expect(criticalOnly.calls.isEmpty)
    }

    @Test func criticalDispatchRunsWarningAndCriticalResponders() {
        let registry = MemoryPressureResponderRegistry()
        let warning = RecordingMemoryPressureResponder(
            id: "warning",
            minimumSeverity: .warning,
            priority: 1
        )
        let critical = RecordingMemoryPressureResponder(
            id: "critical",
            minimumSeverity: .critical,
            priority: 2
        )
        registry.register(warning)
        registry.register(critical)

        let snapshot = MemoryPressureSnapshot(
            severity: .critical,
            physicalFootprintBytes: 2_500,
            sampledAt: Date(timeIntervalSince1970: 2)
        )
        let actions = registry.dispatch(snapshot)

        #expect(actions.map(\.responderID) == ["critical", "warning"])
        #expect(warning.calls.count == 1)
        #expect(critical.calls.count == 1)
    }

    @Test func registeringSameResponderDoesNotDuplicateDispatch() {
        let registry = MemoryPressureResponderRegistry()
        let responder = RecordingMemoryPressureResponder(
            id: "renderer",
            minimumSeverity: .warning,
            priority: 1
        )
        registry.register(responder)
        registry.register(responder)

        let snapshot = MemoryPressureSnapshot(
            severity: .critical,
            physicalFootprintBytes: 3_000,
            sampledAt: Date(timeIntervalSince1970: 3)
        )
        let actions = registry.dispatch(snapshot)

        #expect(actions.map(\.responderID) == ["renderer"])
        #expect(responder.calls.count == 1)
    }
}

@MainActor
@Suite(.serialized)
struct MemoryPressureMonitorTests {
    @Test func dispatchSourceEventMappingIgnoresEmptyEvents() {
        #expect(MemoryPressureMonitor.severity(forDispatchSourceEvent: []) == nil)
        #expect(MemoryPressureMonitor.severity(forDispatchSourceEvent: [.warning]) == .warning)
        #expect(MemoryPressureMonitor.severity(forDispatchSourceEvent: [.critical]) == .critical)
        #expect(MemoryPressureMonitor.severity(forDispatchSourceEvent: [.warning, .critical]) == .critical)
    }

    @Test func samplingInjectedFootprintDispatchesThroughRegistry() {
        let registry = MemoryPressureResponderRegistry()
        let responder = RecordingMemoryPressureResponder(
            id: "renderer",
            minimumSeverity: .warning,
            priority: 1
        )
        registry.register(responder)
        let monitor = MemoryPressureMonitor(
            registry: registry,
            footprintSampler: FixedMemoryPressureFootprintSampler(bytes: 1_500),
            thresholds: .init(warningBytes: 1_000, criticalBytes: 2_000),
            criticalPersistenceDuration: 10,
            sampleInterval: 60
        )

        monitor.samplePhysicalFootprint(at: Date(timeIntervalSince1970: 4))

        #expect(monitor.currentSeverity == .warning)
        #expect(monitor.physicalFootprintBytes == 1_500)
        #expect(responder.calls.map(\.severity) == [.warning])
    }

    @Test func samplingPreservesRecentSystemPressureEvent() {
        let registry = MemoryPressureResponderRegistry()
        let responder = RecordingMemoryPressureResponder(
            id: "renderer",
            minimumSeverity: .warning,
            priority: 1
        )
        registry.register(responder)
        let monitor = MemoryPressureMonitor(
            registry: registry,
            footprintSampler: FixedMemoryPressureFootprintSampler(bytes: 100),
            thresholds: .init(warningBytes: 1_000, criticalBytes: 2_000),
            criticalPersistenceDuration: 10,
            sampleInterval: 60,
            systemPressureHoldDuration: 30
        )
        let start = Date(timeIntervalSince1970: 5)

        monitor.recordSystemPressure(.critical, at: start)
        monitor.samplePhysicalFootprint(at: start.addingTimeInterval(1))

        #expect(monitor.currentSeverity == .critical)
        #expect(responder.calls.map(\.severity) == [.critical, .critical])
    }

    @Test func lowerSystemPressureEventDoesNotDowngradeHeldCriticalEvent() {
        let registry = MemoryPressureResponderRegistry()
        let responder = RecordingMemoryPressureResponder(
            id: "renderer",
            minimumSeverity: .warning,
            priority: 1
        )
        registry.register(responder)
        let monitor = MemoryPressureMonitor(
            registry: registry,
            footprintSampler: FixedMemoryPressureFootprintSampler(bytes: 100),
            thresholds: .init(warningBytes: 1_000, criticalBytes: 2_000),
            criticalPersistenceDuration: 10,
            sampleInterval: 60,
            systemPressureHoldDuration: 30
        )
        let start = Date(timeIntervalSince1970: 6)

        monitor.recordSystemPressure(.critical, at: start)
        monitor.recordSystemPressure(.warning, at: start.addingTimeInterval(1))

        #expect(monitor.currentSeverity == .critical)
        #expect(responder.calls.map(\.severity) == [.critical, .critical])
    }

    @Test func heldSystemPressureExpiresWithoutNewEvents() {
        let registry = MemoryPressureResponderRegistry()
        let responder = RecordingMemoryPressureResponder(
            id: "renderer",
            minimumSeverity: .warning,
            priority: 1
        )
        registry.register(responder)
        let monitor = MemoryPressureMonitor(
            registry: registry,
            footprintSampler: FixedMemoryPressureFootprintSampler(bytes: 100),
            thresholds: .init(warningBytes: 1_000, criticalBytes: 2_000),
            criticalPersistenceDuration: 10,
            sampleInterval: 60,
            systemPressureHoldDuration: 30
        )
        let start = Date(timeIntervalSince1970: 7)

        monitor.recordSystemPressure(.warning, at: start)
        monitor.samplePhysicalFootprint(at: start.addingTimeInterval(31))

        #expect(monitor.currentSeverity == .normal)
        #expect(responder.calls.map(\.severity) == [.warning])
    }
}
