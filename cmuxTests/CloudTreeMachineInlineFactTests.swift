import CmuxCloud
import CmuxSurfaceCatalogModel
import Foundation
import Testing
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Compact rows retain the original inline resources and token summary.
@Suite("Cloud tree machine inline fact")
struct CloudTreeMachineInlineFactTests {
    private func snapshot(stats: VMStats?) -> MachineSnapshot {
        var machine = MachineSnapshotBuilder.snapshot(from: VMSummary(
            id: "troll", provider: "freestyle", status: "running", image: "cmux-devbox:devbox-20260828b", createdAt: 0, base: nil
        ))
        machine.stats = stats
        return machine
    }

    @Test("Resource readings share the compact machine header")
    func awakeReadingHasDedicatedSpace() {
        let stats = VMStats(
            state: .awake, sampledAt: Date(timeIntervalSince1970: 0), cpus: 2, cpuPercent: 9.4,
            loadAverage1m: nil, memoryTotalMb: 3891, memoryUsedMb: 3481, diskTotalMb: 3174, diskUsedMb: 2867
        )
        let fact = CloudTreeMachineRowContent(machine: snapshot(stats: stats), style: .compact,
                                             now: stats.sampledAt).inlineFact
        #expect(fact?.contains("CPU") == true)
        #expect(CloudTreeStyle.compact.machineRowHeight(hasStats: true) == CloudTreeStyle.compact.machineRowHeight(hasStats: false))
    }

    @Test("No reading yet keeps missing-data state inline")
    func missingStatsShowsNothing() {
        #expect(CloudTreeMachineRowContent(machine: snapshot(stats: nil), style: .compact).inlineFact?.contains("Token usage unavailable") == true)
    }

    @Test("A nearly full disk warns on the row before the machine stops answering")
    func nearlyFullDiskWarnsOnTheRow() throws {
        let sampledAt = Date(timeIntervalSince1970: 1_000)
        func row(diskUsedMb: Int) -> CloudTreeMachineRowContent {
            var machine = snapshot(stats: VMStats(
                state: .awake, sampledAt: sampledAt, resourceSampledAt: sampledAt,
                diskTotalMb: 16_384, diskUsedMb: diskUsedMb
            ))
            machine.capabilities = .all
            return CloudTreeMachineRowContent(machine: machine, now: sampledAt)
        }

        let full = row(diskUsedMb: 15_872)
        #expect(full.statusSymbol == CloudTreeMachineRowContent.lowDiskSymbol)
        let warning = try #require(full.lowDiskWarning)
        #expect(warning.contains("troll"))
        #expect(full.toolTip.contains(warning))
        #expect(full.accessibilityLabel.contains(warning))

        let roomy = row(diskUsedMb: 8_192)
        #expect(roomy.statusSymbol == nil)
        #expect(roomy.lowDiskWarning == nil)
    }
}
