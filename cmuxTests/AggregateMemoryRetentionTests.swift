import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

struct AggregateMemoryRetentionTests {
    private struct Coalition: MemoryPressureCoalitionSampling {
        let bytes: UInt64
        func usage(forProcessID processID: Int) -> MemoryPressureCoalitionUsage? {
            MemoryPressureCoalitionUsage(physicalFootprintBytes: bytes)
        }
    }

    @Test("Coalition pressure survives RAM overflow and descendant reparenting",
          arguments: [UInt64(36) << 30, UInt64(45) << 30, UInt64(72) << 30])
    func retainedDescendantsStayAccounted(coalitionBytes: UInt64) {
        // A small app remains after its large child's parent exits. The child
        // retains coalition membership, but a PPID walk can no longer find it.
        let snapshot = CmuxTopProcessSnapshot(
            processes: [
                process(pid: 42, parentPID: 1, bytes: 2 << 30),
                process(pid: 43, parentPID: 1, bytes: 20 << 30)
            ],
            sampledAt: .distantPast,
            includesProcessDetails: false
        )
        let sampler = DarwinMemoryPressureAggregateSampler(
            processID: 42,
            snapshotProvider: { snapshot },
            coalitionSampler: Coalition(bytes: coalitionBytes),
            physicalMemoryProvider: { 36 << 30 },
            availableMemoryProvider: { 512 << 20 }
        )

        let sample = sampler.sample(at: Date(timeIntervalSince1970: 1))
        #expect(sample.source == .coalition)
        #expect(sample.aggregateBytes == coalitionBytes)
        #expect(sample.isUsable)
        #expect(MemoryPressureAggregatePolicy.default.evaluate(sample: sample).isActionable)
        #expect(MemoryPressureAggregatePolicy.default.severity(for: sample) == .critical)
    }

    private func process(pid: Int, parentPID: Int, bytes: Int64) -> CmuxTopProcessInfo {
        CmuxTopProcessInfo(
            pid: pid, parentPID: parentPID, name: "fixture", path: nil,
            ttyDevice: nil, cmuxWorkspaceID: nil, cmuxSurfaceID: nil,
            cmuxAttributionReason: nil, processGroupID: nil, terminalProcessGroupID: nil,
            cpuPercent: 0, memoryBytes: bytes, memorySource: .physicalFootprint,
            residentBytes: bytes, virtualBytes: bytes, threadCount: 1
        )
    }
}
