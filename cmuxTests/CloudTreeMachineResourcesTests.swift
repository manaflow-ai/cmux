import CmuxCloudMachines
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
        diskTotal: Int? = 4096,
        resourceSampledAt: Date? = Date()
    ) -> MachineSnapshot {
        var result = MachineSnapshotBuilder.snapshot(from: VMSummary(
            id: "resource-test", provider: "freestyle", status: "running",
            image: "cmux-devbox:test", createdAt: 0, base: nil
        ))
        result.capabilities.stats = true
        result.stats = VMStats(
            state: state, sampledAt: Date(), resourceSampledAt: resourceSampledAt,
            cpus: 4, cpuPercent: cpu, loadAverage1m: nil,
            memoryTotalMb: memoryTotal, memoryUsedMb: memoryUsed,
            diskTotalMb: diskTotal, diskUsedMb: diskUsed
        )
        return result
    }

    @Test func awakeReadingsUseUtilizationRatherThanProvisionedCapacity() {
        let resources = CloudMachineResourcePresentation(machine: machine())
        #expect(resources.cpu.percent == 9.4)
        #expect(resources.memory.percent == 50)
        #expect(resources.disk.percent == 75)
        #expect(resources.cpu.value == (0.094).formatted(.percent.precision(.fractionLength(0))))
        #expect(resources.memory.detail.contains("2/4"))
        #expect(resources.disk.detail.contains("3/4"))
    }

    @Test(arguments: [VMStats.State.asleep, .unknown])
    func inactiveSamplesNeverPresentOldValuesAsLive(state: VMStats.State) {
        let resources = CloudMachineResourcePresentation(machine: machine(state: state))
        #expect(resources.cpu.percent == nil)
        #expect(resources.memory.percent == nil)
        #expect(resources.disk.percent == nil)
    }

    @Test func missingAndUnsupportedStatsDoNotInventZeroUsage() {
        var snapshot = machine()
        snapshot.stats = nil
        let missing = CloudMachineResourcePresentation(machine: snapshot)
        #expect(missing.cpu.percent == nil)
        #expect(missing.memory.percent == nil)
        #expect(missing.disk.percent == nil)
        snapshot = machine()
        snapshot.capabilities.stats = false
        let unsupported = CloudMachineResourcePresentation(machine: snapshot)
        #expect(unsupported.cpu.percent == nil)
        #expect(unsupported.memory.percent == nil)
        #expect(unsupported.disk.percent == nil)
        snapshot = machine(resourceSampledAt: nil)
        let missingTimestamp = CloudMachineResourcePresentation(machine: snapshot)
        #expect(missingTimestamp.availability == .unavailable)
        #expect(missingTimestamp.cpu.percent == nil)
    }

    @Test func machineSnapshotsDistinguishLoadingAndStaleTelemetry() {
        var snapshot = machine()
        snapshot.stats = nil
        #expect(CloudMachineResourcePresentation(machine: snapshot).availability == .loading)
        snapshot.stats = VMStats(
            state: .awake,
            sampledAt: Date(timeIntervalSince1970: 1_780_000_000),
            resourceSampledAt: Date(timeIntervalSince1970: 1_780_000_000),
            cpus: 4,
            cpuPercent: nil,
            loadAverage1m: nil,
            memoryTotalMb: 4096,
            memoryUsedMb: nil,
            diskTotalMb: 4096,
            diskUsedMb: nil
        )
        let stale = CloudMachineResourcePresentation(
            machine: snapshot,
            now: Date(timeIntervalSince1970: 1_780_000_000 + CloudMachineResourcePresentation.staleSampleAge + 1)
        )
        #expect(stale.availability == .stale)
        #expect(stale.cpu.percent == nil)
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
        #expect(CloudMachineResourcePresentation(machine: snapshot).cpu.percent == 83)
        #expect(CloudTreeMachineRowContent(machine: snapshot).accessibilityLabel.contains("83"))
        #expect(CloudTreeMachineRowContent(machine: snapshot).toolTip.contains("83"))
    }

    @Test @MainActor func everyPresetKeepsResourceLabelsAndNameClear() {
        for style in CloudTreeStyle.presets {
            #expect(style.showsMachineStats)
            #expect(style.machineRowHeight(hasStats: true) == style.machineRowHeight(hasStats: false))
            #expect(CloudTreeMachineRowContent(machine: machine(), style: style).inlineFact == nil)
        }
    }

    @Test @MainActor func inlineMetricsDoNotAddAStackedMachineRow() {
        for style in CloudTreeStyle.presets {
            #expect(
                style.machineRowHeight(hasStats: true) == style.machineRowHeight(hasStats: false),
                "inline CPU/RAM/Disk readings share the machine row instead of adding a second metrics row"
            )
        }
    }
}
