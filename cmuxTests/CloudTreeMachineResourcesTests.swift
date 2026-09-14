import AppKit
import CmuxCloudMachines
import CmuxFoundation
import Foundation
import SwiftUI
import Testing
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Cloud machine resource presentation")
struct CloudTreeMachineResourcesTests {
    private static let sampleTime = Date(timeIntervalSince1970: 1_780_000_000)
    private func machine(
        state: VMStats.State = .awake,
        cpu: Double? = 9.4,
        memoryUsed: Int? = 2048,
        memoryTotal: Int? = 4096,
        diskUsed: Int? = 3072,
        diskTotal: Int? = 4096,
        resourceSampledAt: Date? = CloudTreeMachineResourcesTests.sampleTime
    ) -> MachineSnapshot {
        var result = MachineSnapshotBuilder.snapshot(from: VMSummary(
            id: "resource-test", provider: "freestyle", status: "running",
            image: "cmux-devbox:test", createdAt: 0, base: nil
        ))
        result.capabilities.stats = true
        result.stats = VMStats(
            state: state, sampledAt: Self.sampleTime, resourceSampledAt: resourceSampledAt,
            cpus: 4, cpuPercent: cpu, loadAverage1m: nil,
            memoryTotalMb: memoryTotal, memoryUsedMb: memoryUsed,
            diskTotalMb: diskTotal, diskUsedMb: diskUsed
        )
        return result
    }

    @Test func awakeReadingsUseUtilizationRatherThanProvisionedCapacity() {
        let resources = CloudMachineResourcePresentation(machine: machine(), now: Self.sampleTime)
        #expect(resources.cpu.percent == 9.4)
        #expect(resources.memory.percent == 50)
        #expect(resources.disk.percent == 75)
        #expect(resources.cpu.value == (0.094).formatted(.percent.precision(.fractionLength(0))))
        #expect(resources.memory.detail.contains("2/4"))
        #expect(resources.disk.detail.contains("3/4"))
    }

    @Test(arguments: [VMStats.State.asleep, .unknown])
    func inactiveSamplesNeverPresentOldValuesAsLive(state: VMStats.State) {
        let resources = CloudMachineResourcePresentation(machine: machine(state: state), now: Self.sampleTime)
        #expect(resources.cpu.percent == nil)
        #expect(resources.memory.percent == nil)
        #expect(resources.disk.percent == nil)
    }

    @Test func missingAndUnsupportedStatsDoNotInventZeroUsage() {
        var snapshot = machine()
        snapshot.stats = nil
        let missing = CloudMachineResourcePresentation(machine: snapshot, now: Self.sampleTime)
        #expect(missing.cpu.percent == nil)
        #expect(missing.memory.percent == nil)
        #expect(missing.disk.percent == nil)
        snapshot = machine()
        snapshot.capabilities.stats = false
        let unsupported = CloudMachineResourcePresentation(machine: snapshot, now: Self.sampleTime)
        #expect(unsupported.cpu.percent == nil)
        #expect(unsupported.memory.percent == nil)
        #expect(unsupported.disk.percent == nil)
        snapshot = machine(resourceSampledAt: nil)
        let missingTimestamp = CloudMachineResourcePresentation(machine: snapshot, now: Self.sampleTime)
        #expect(missingTimestamp.availability == .unavailable)
        #expect(missingTimestamp.cpu.percent == nil)
    }

    @Test func machineSnapshotsDistinguishLoadingAndStaleTelemetry() {
        var snapshot = machine()
        snapshot.stats = nil
        #expect(CloudMachineResourcePresentation(machine: snapshot, now: Self.sampleTime).availability == .loading)
        snapshot.stats = VMStats(
            state: .awake,
            sampledAt: Self.sampleTime,
            resourceSampledAt: Self.sampleTime,
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
            now: Self.sampleTime.addingTimeInterval(CloudMachineResourcePresentation.staleSampleAge + 1)
        )
        #expect(stale.availability == .stale)
        #expect(stale.cpu.percent == nil)

        let future = CloudMachineResourcePresentation(
            machine: machine(resourceSampledAt: Self.sampleTime.addingTimeInterval(1)),
            now: Self.sampleTime
        )
        #expect(future.availability == .unavailable)
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
        #expect(CloudMachineResourcePresentation(machine: snapshot, now: Self.sampleTime).cpu.percent == 83)
        #expect(CloudTreeMachineRowContent(machine: snapshot, now: Self.sampleTime).accessibilityLabel.contains("83"))
        #expect(CloudTreeMachineRowContent(machine: snapshot, now: Self.sampleTime).toolTip.contains("83"))
    }

    /// The hosted view fits its single-line height even for maximum readings.
    @Test @MainActor func resourceSummaryUsesOneCompactLine() {
        let resources = CloudMachineResourcePresentation(
            availability: .awake, cpuPercent: 100,
            memoryUsedMb: 4096, memoryTotalMb: 4096, diskUsedMb: 4096, diskTotalMb: 4096
        )
        for style in CloudTreeStyle.presets {
            let host = NSHostingView(rootView: CloudTreeMachineResourceView(metrics: resources, style: style)
                .environment(\.cmuxGlobalFontMagnificationPercent, 100).frame(width: 160))
            #expect(host.fittingSize.height <= style.machineResourceHeight)
            #expect(style.machineRowHeight(hasStats: true) > style.machineRowHeight(hasStats: false))
            let lines = style.machineNameLineHeight + 1 + style.machineResourceHeight
                + (style.machineRowLayout == .twoLine ? 1 + style.machineSubtitleLineHeight : 0)
            #expect(style.machineRowHeight(hasStats: true) == lines + style.machineVerticalPadding * 2 + (style.machineBand ? 8 : 0))
        }
    }
}
