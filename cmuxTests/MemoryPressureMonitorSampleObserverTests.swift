import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

private struct FixedFootprintSampler: MemoryPressureFootprintSampling {
    let bytes: UInt64?

    func physicalFootprintBytes() -> UInt64? {
        bytes
    }
}

private struct FixedAggregateSampler: MemoryPressureAggregateSampling {
    let sample: MemoryPressureAggregateSample

    func sample(at sampledAt: Date) async -> MemoryPressureAggregateSample {
        sample.withSampledAt(sampledAt)
    }
}

/// `onSampleApplied` drives the hidden browser memory budget
/// (https://github.com/manaflow-ai/cmux/issues/15069).
@MainActor
@Suite(.serialized)
struct MemoryPressureMonitorSampleObserverTests {
    @Test func everyAppliedSampleNotifiesItsTime() async {
        let sample = MemoryPressureAggregateSample.unavailable(
            sampledAt: Date(timeIntervalSince1970: 0)
        )
        let monitor = MemoryPressureMonitor(
            footprintSampler: FixedFootprintSampler(bytes: 100),
            aggregateSampler: FixedAggregateSampler(sample: sample),
            sampleInterval: 60
        )
        var sampledTimes: [Date] = []
        monitor.onSampleApplied = { sampledTimes.append($0) }

        await monitor.samplePhysicalFootprint(at: Date(timeIntervalSince1970: 32))
        await monitor.samplePhysicalFootprint(at: Date(timeIntervalSince1970: 10))

        // A stale sample that arrives late is not applied.
        #expect(sampledTimes == [Date(timeIntervalSince1970: 32)])
    }
}
