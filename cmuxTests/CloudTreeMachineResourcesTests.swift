import Foundation
import Testing
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Cloud machine resource presentation")
struct CloudTreeMachineResourcesTests {
    private func machine(
        state: VMStats.State = .awake,
        cpu: Double? = 9.4,
        memoryUsed: Int? = 2048,
        memoryTotal: Int? = 4096,
        diskUsed: Int? = 3072,
        diskTotal: Int? = 4096
    ) -> MachineSnapshot {
        var result = MachineSnapshotBuilder.snapshot(from: VMSummary(
            id: "resource-test", provider: "freestyle", status: "running",
            image: "cmux-devbox:test", createdAt: 0, base: nil
        ))
        result.capabilities.stats = true
        result.stats = VMStats(
            state: state, sampledAt: Date(timeIntervalSince1970: 1_780_000_000),
            cpus: 4, cpuPercent: cpu, loadAverage1m: nil,
            memoryTotalMb: memoryTotal, memoryUsedMb: memoryUsed,
            diskTotalMb: diskTotal, diskUsedMb: diskUsed
        )
        return result
    }

    @Test func awakeReadingsUseUtilizationRatherThanProvisionedCapacity() {
        let resources = CloudTreeMachineResources(machine: machine())
        #expect(resources.cpu.percent == 9.4)
        #expect(resources.memory.percent == 50)
        #expect(resources.disk.percent == 75)
        #expect(resources.cpu.value == (0.094).formatted(.percent.precision(.fractionLength(0))))
        #expect(resources.memory.detail.contains("2/4"))
        #expect(resources.disk.detail.contains("3/4"))
    }

    @Test func zeroIsARealReadingAndPartialSamplesKeepAllThreeColumns() {
        let resources = CloudTreeMachineResources(machine: machine(cpu: 0, memoryUsed: nil, diskUsed: 0))
        #expect(resources.cpu.percent == 0)
        #expect(resources.memory.percent == nil)
        #expect(resources.disk.percent == 0)
        #expect(resources.cpu.value != resources.memory.value)
        #expect(!resources.memory.label.isEmpty)
        #expect(!resources.memory.detail.isEmpty)
    }

    @Test(arguments: [VMStats.State.asleep, .unknown])
    func inactiveSamplesNeverPresentOldValuesAsLive(state: VMStats.State) {
        let resources = CloudTreeMachineResources(machine: machine(state: state))
        #expect(resources.cpu.percent == nil)
        #expect(resources.memory.percent == nil)
        #expect(resources.disk.percent == nil)
    }

    @Test func missingAndUnsupportedStatsDoNotInventZeroUsage() {
        var snapshot = machine()
        snapshot.stats = nil
        let missing = CloudTreeMachineResources(machine: snapshot)
        #expect(missing.cpu.percent == nil)
        #expect(missing.memory.percent == nil)
        #expect(missing.disk.percent == nil)
        snapshot = machine()
        snapshot.capabilities.stats = false
        let unsupported = CloudTreeMachineResources(machine: snapshot)
        #expect(unsupported.cpu.percent == nil)
        #expect(unsupported.memory.percent == nil)
        #expect(unsupported.disk.percent == nil)
    }

    @Test(arguments: [Double.nan, .infinity, -.infinity, -1, 101, .greatestFiniteMagnitude])
    func malformedCPUIsUnavailableWithoutTrapping(cpu: Double) {
        let resources = CloudTreeMachineResources(machine: machine(cpu: cpu))
        #expect(resources.cpu.percent == nil)
        #expect(!resources.cpu.value.isEmpty)
        #expect(resources.memory.percent == 50)
    }

    @Test(arguments: [(0, 0), (2, -1), (-1, 1024)])
    func invalidCapacityIsUnavailable(counts: (Int, Int)) {
        let resources = CloudTreeMachineResources(machine: machine(
            memoryUsed: counts.0, memoryTotal: counts.1, diskUsed: counts.0, diskTotal: counts.1
        ))
        #expect(resources.memory.percent == nil)
        #expect(resources.disk.percent == nil)
    }

    @Test func capacityCounterRacesStayBounded() {
        let resources = CloudTreeMachineResources(machine: machine(memoryUsed: 4097, diskUsed: .max))
        #expect(resources.memory.percent == 100)
        #expect(resources.disk.percent == 100)
    }

    @Test @MainActor func refreshedSnapshotsUpdateReadingsWithoutReplacingRows() throws {
        var first = machine()
        first.stats = nil
        let original = CloudTreeNodeBuilder.nodes(machines: [first], snapshot: .empty, localWorkspaces: [], includeLocalMachine: false)
        let refreshed = CloudTreeNodeBuilder.nodes(machines: [machine(cpu: 83)], snapshot: .empty, localWorkspaces: [], includeLocalMachine: false)
        let row = try #require(original.first)
        let replacement = try #require(refreshed.first)
        #expect(row.id == replacement.id)
        #expect(row.structureTag == replacement.structureTag)
        #expect(CloudTreeNodeBuilder.contentSignature(original) != CloudTreeNodeBuilder.contentSignature(refreshed))
        row.adopt(from: replacement)
        guard case .machine(let snapshot, _) = row.kind else {
            Issue.record("The refresh must retain the machine row")
            return
        }
        #expect(CloudTreeMachineResources(machine: snapshot).cpu.percent == 83)
        #expect(CloudTreeMachineRowContent.accessibilityLabel(snapshot).contains("83"))
        #expect(CloudTreeMachineRowContent.toolTip(snapshot).contains("83"))
    }

    @Test @MainActor func everyPresetReservesResourceSpaceAndKeepsNameClear() {
        for style in CloudTreeStyle.presets {
            #expect(style.showsMachineStats)
            #expect(style.machineRowHeight(hasStats: true) >= style.machineNameLineHeight + style.machineResourceHeight)
            #expect(CloudTreeMachineRowContent.inlineFact(machine(), style: style) == nil)
        }
    }
}
