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

    /// Existing stats and resize replies can carry real gauges with only sampledAt.
    @Test func legacyRepliesPreserveMeasuredValues() {
        let json: [String: Any] = [
            "state": "awake", "sampledAt": Self.sampleTime.timeIntervalSince1970 * 1000,
            "cpuPercent": 9.4, "memoryUsedMb": 2048, "memoryTotalMb": 4096,
            "diskUsedMb": 3072, "diskTotalMb": 4096
        ]
        var snapshot = machine()
        snapshot.stats = VMStats(json: json, now: Self.sampleTime)
        let resources = CloudMachineResourcePresentation(machine: snapshot, now: Self.sampleTime)
        #expect(resources.availability == .awake)
        #expect(resources.cpu.percent == 9.4)
        #expect(resources.memory.percent == 50)
        #expect(resources.disk.percent == 75)
    }

    /// Provider dimensions or an absent sample time never become live usage.
    @Test func decodingRequiresMeasuredGaugesAndTheirTimestamp() {
        let dimensions = VMStats(json: ["state": "awake", "sampledAt": 1_780_000_000_000,
                                       "memoryTotalMb": 4096, "diskTotalMb": 4096], now: Self.sampleTime)
        #expect(dimensions.resourceSampledAt == nil)
        let unstamped = VMStats(json: ["state": "awake", "cpuPercent": 9.4], now: Self.sampleTime)
        #expect(unstamped.resourceSampledAt == nil)
        let stale = VMStats(json: ["state": "awake", "sampledAt": 1_780_000_100_000,
                                  "resourceSampledAt": 1_780_000_000_000], now: Self.sampleTime)
        #expect(stale.resourceSampledAt == Self.sampleTime)
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

    /// Visible usage remains part of the machine's accessible identity.
    @Test @MainActor func machineUsageRemainsAccessible() throws {
        var snapshot = machine()
        snapshot.usage = MachineUsageSnapshot(
            vmID: snapshot.id, providerVmID: nil, displayName: nil, periodDays: 30, asOf: Self.sampleTime,
            totals: MachineUsageTotals(inputTokens: 31000, cachedInputTokens: 0, outputTokens: 10000,
                                       totalTokens: 41000, apiEquivalentUsd: 1.23)
        )
        let row = CloudTreeMachineRowContent(machine: snapshot, now: Self.sampleTime)
        let usage = try #require(row.usageLine)
        #expect(row.accessibilityLabel.contains(usage))
        #expect(row.toolTip.contains(usage))
        #expect(
            CloudTreeStyle.aero.machineRowHeight(hasStats: true, hasUsage: true)
                > CloudTreeStyle.aero.machineRowHeight(hasStats: true, hasUsage: false)
        )
    }

    /// An unavailable ledger must remain distinguishable from an omitted UI feature.
    @Test @MainActor func missingTokenUsageIsVisibleInsteadOfSilentlyOmitted() {
        let row = CloudTreeMachineRowContent(machine: machine(), style: .compact, now: Self.sampleTime)
        #expect(row.accessibilityLabel.contains("Token usage unavailable"))
        #expect(row.toolTip.contains("Token usage unavailable"))
    }

    @Test @MainActor func zeroTokenUsageRemainsARealSummary() throws {
        var snapshot = machine()
        snapshot.usage = MachineUsageSnapshot(
            vmID: snapshot.id, providerVmID: nil, displayName: nil, periodDays: 30, asOf: Self.sampleTime,
            totals: MachineUsageTotals(inputTokens: 0, cachedInputTokens: 0, outputTokens: 0,
                                       totalTokens: 0, apiEquivalentUsd: 0)
        )
        let line = try #require(CloudTreeMachineRowContent(machine: snapshot).usageLine)
        #expect(line.contains("0 tokens"))
        #expect(line.contains("$0.00"))
        #expect(line.contains("30d"))
    }

    @Test @MainActor func compactPresetsKeepResourcesAndUsageOnTheHeaderBaseline() throws {
        var snapshot = machine()
        snapshot.usage = MachineUsageSnapshot(
            vmID: snapshot.id, providerVmID: nil, displayName: nil, periodDays: 30, asOf: Self.sampleTime,
            totals: MachineUsageTotals(inputTokens: 31000, cachedInputTokens: 0, outputTokens: 10000,
                                       totalTokens: 41000, apiEquivalentUsd: 1.23)
        )
        for style in CloudTreeStyle.presets where style.machineRowLayout == .singleLine {
            let row = CloudTreeMachineRowContent(machine: snapshot, style: style, now: Self.sampleTime)
            let fact = try #require(row.inlineFact)
            #expect(fact.contains("CPU"))
            #expect(fact.contains("50%"))
            #expect(fact.contains("75%"))
            #expect(fact.contains("41K"))
            #expect(fact.contains("30d"))
            #expect(style.machineRowHeight(hasStats: true, hasUsage: true)
                == style.machineRowHeight(hasStats: false, hasUsage: false))
            for width in [CGFloat(240), 800] {
                for scale in [100, 150] {
                    let host = NSHostingView(rootView: row
                        .environment(\.cmuxGlobalFontMagnificationPercent, scale).frame(width: width))
                    #expect(host.fittingSize.width <= width + 1)
                    #expect(host.fittingSize.height <= GlobalFontMagnification.scaledSize(
                        style.machineRowHeight(hasStats: true, hasUsage: true), percent: scale
                    ) + 1)
                }
            }
        }
    }

    @Test @MainActor func usageSummaryWrapsWithoutDroppingTokensOrTheWindow() {
        for style in CloudTreeStyle.presets {
            for width in [CGFloat(120), 200, 320] {
                for scale in [100, 150, 200] {
                    let view = CloudTreeMachineDetailView(line: "$123.45 · 41K tokens · 30d", style: style)
                    let host = NSHostingView(rootView: view
                        .environment(\.cmuxGlobalFontMagnificationPercent, scale).frame(width: width))
                    #expect(host.fittingSize.height <= view.height(width: width, magnification: scale) + 1)
                    #expect(host.fittingSize.width <= width + 1)
                }
            }
        }
    }

    /// The outline reserves enough height for normal and wrapped resource text.
    @Test @MainActor func resourceSummaryUsesOneCompactLine() {
        let resources = CloudMachineResourcePresentation(
            availability: .awake, cpuPercent: 100,
            memoryUsedMb: 4096, memoryTotalMb: 4096, diskUsedMb: 4096, diskTotalMb: 4096
        )
        for style in CloudTreeStyle.presets {
            let view = CloudTreeMachineResourceView(metrics: resources, style: style)
            for width in [CGFloat(160), 280] {
                for scale in [100, 150] {
                    let host = NSHostingView(rootView: view
                        .environment(\.cmuxGlobalFontMagnificationPercent, scale).frame(width: width))
                    #expect(host.fittingSize.height <= view.height(width: width, magnification: scale) + 1)
                }
            }
            if style.machineRowLayout == .twoLine {
                #expect(style.machineRowHeight(hasStats: true) > style.machineRowHeight(hasStats: false))
            } else {
                #expect(style.machineRowHeight(hasStats: true) == style.machineRowHeight(hasStats: false))
            }
        }
    }
}
