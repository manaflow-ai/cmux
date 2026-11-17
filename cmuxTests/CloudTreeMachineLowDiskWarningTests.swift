import CmuxCloud
import CmuxSurfaceCatalogModel
import Foundation
import Testing
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// A nearly full disk warns on the machine row.
@Suite("Cloud tree machine low disk warning")
struct CloudTreeMachineLowDiskWarningTests {
    private func snapshot(stats: VMStats?) -> MachineSnapshot {
        var machine = MachineSnapshotBuilder.snapshot(from: VMSummary(
            id: "troll", provider: "freestyle", status: "running", image: "cmux-devbox:devbox-20260828b", createdAt: 0, base: nil
        ))
        machine.stats = stats
        return machine
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
