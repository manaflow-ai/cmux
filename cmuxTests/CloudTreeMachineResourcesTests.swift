import AppKit
import CmuxCloudMachines
import CmuxFoundation
import CmuxSurfaceCatalogModel
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

    @Test func resourceRowValuesDoNotRepeatTheirLabels() {
        let rows = CloudTreeMachineResourceSection(machine: machine(), now: Self.sampleTime).rows
        #expect(rows[0].detail == (0.094).formatted(.percent.precision(.fractionLength(0))))
        #expect(rows[1].detail == "2/4 GB (50%)")
        #expect(rows[2].detail == "3/4 GB (75%)")
        let asleep = CloudTreeMachineResourceSection(machine: machine(state: .asleep), now: Self.sampleTime).rows
        #expect(asleep[0].detail == "Asleep")
    }

    @Test("Resource readings cannot be selected and keyboard navigation skips them")
    @MainActor func resourceReadingsAreDisplayOnly() throws {
        let fixture = CloudSidebarOrderingFixture()
        defer { fixture.close() }
        let resources = CloudTreeMachineResourceNodeBuilder().groupNode(
            machine: fixture.machine, snapshot: machine(), now: Self.sampleTime
        )
        let next = CloudTreeNode(id: "after-resources", kind: .portsGroup(machine: fixture.machine))
        fixture.coordinator.apply(nodes: [resources, next])
        let outline = try #require(fixture.coordinator.outlineView)
        outline.expandItem(resources)
        let headerRow = outline.row(forItem: resources)
        let nextRow = outline.row(forItem: next)
        outline.selectRowIndexes(IndexSet(integer: headerRow), byExtendingSelection: false)

        for reading in resources.children {
            #expect(!fixture.coordinator.outlineView(outline, shouldSelectItem: reading))
            outline.selectRowIndexes(IndexSet(integer: outline.row(forItem: reading)), byExtendingSelection: false)
            #expect(outline.selectedRow == headerRow)
            fixture.coordinator.selectQuickSearchMatch(query: reading.searchableTitle)
            #expect(outline.selectedRow == headerRow)
        }

        fixture.coordinator.moveSelection(by: 1)
        #expect(outline.selectedRow == nextRow)
        fixture.coordinator.moveSelection(by: -1)
        #expect(outline.selectedRow == headerRow)
        fixture.coordinator.open(resources)
        #expect(!outline.isItemExpanded(resources), "The Resources header still toggles expansion")
    }

    @Test("Cloud sections and resource values fit narrow and wide sidebars", arguments: [280.0, 420.0])
    @MainActor func resourceTreeLayout(width: Double) throws {
        let fixture = CloudSidebarOrderingFixture()
        defer { fixture.close() }
        let snapshot = machine()
        let template = try #require(fixture.nodes().first)
        let resources = CloudTreeMachineResourceNodeBuilder().groupNode(
            machine: fixture.machine, snapshot: snapshot, now: Self.sampleTime
        )
        let root = CloudTreeNode(
            id: template.id, kind: .machine(snapshot, nil),
            children: template.children.filter { $0.structureTag != "resourcesPool" } + [resources]
        )
        fixture.window.setContentSize(NSSize(width: width, height: 520))
        fixture.container.appearance = NSAppearance(named: .darkAqua)
        fixture.coordinator.apply(nodes: [root])
        let outline = try #require(fixture.coordinator.outlineView)
        outline.expandItem(nil, expandChildren: true)
        fixture.container.layoutSubtreeIfNeeded()
        for row in 0..<outline.numberOfRows {
            #expect(outline.frameOfCell(atColumn: 0, row: row).width > 0)
            #expect(outline.frameOfCell(atColumn: 0, row: row).maxX <= outline.bounds.maxX + 1)
        }
        try fixture.attachScreenshot(named: "cloud-resources-spacing-\(Int(width))")
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

    @Test @MainActor func machineHeaderLeavesResourceAndUsageDetailsToTheResourcesSection() throws {
        var snapshot = machine()
        snapshot.usage = MachineUsageSnapshot(
            vmID: snapshot.id, providerVmID: nil, displayName: nil, periodDays: 30, asOf: Self.sampleTime,
            totals: MachineUsageTotals(inputTokens: 31000, cachedInputTokens: 0, outputTokens: 10000,
                                       totalTokens: 41000, apiEquivalentUsd: 1.23)
        )
        for style in CloudTreeStyle.presets {
            let row = CloudTreeMachineRowContent(machine: snapshot, style: style, now: Self.sampleTime)
            let section = CloudTreeMachineResourceSection(machine: snapshot, now: Self.sampleTime)
            #expect(section.rows.map(\.metric) == [.cpu, .memory, .disk, .usage])
            #expect(section.rows[0].detail.contains("9%"))
            #expect(section.rows[1].detail.contains("2/4"))
            #expect(section.rows[2].detail.contains("3/4"))
            #expect(section.rows[3].detail.contains("41K"))
            for width in [CGFloat(240), 800] {
                for scale in [100, 150] {
                    let host = NSHostingView(rootView: row
                        .environment(\.cmuxGlobalFontMagnificationPercent, scale).frame(width: width))
                    #expect(host.fittingSize.width <= width + 1)
                    #expect(host.fittingSize.height <= GlobalFontMagnification.scaledSize(
                        style.machineRowHeight(hasStats: false, hasUsage: false), percent: scale
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

    @Test @MainActor func everyCloudMachineGetsResourcesAfterSurfaceSections() throws {
        let first = machine()
        var second = machine()
        second = MachineSnapshotBuilder.snapshot(from: VMSummary(
            id: "empty-machine", provider: "freestyle", status: "running", image: "test", createdAt: 0, base: nil
        ))
        let info = SurfaceMachineInfo(
            id: .cloud(first.id), name: first.displayName, status: "running", image: first.image,
            hasDesktop: first.isDesktop, memoryMb: nil, diskMb: nil, linkState: .connected,
            linkError: nil, cpuPercent: nil, memoryUsedMb: nil, diskUsedMb: nil
        )
        let emptyInfo = SurfaceMachineInfo(
            id: .cloud(second.id), name: second.displayName, status: "running", image: second.image,
            hasDesktop: second.isDesktop, memoryMb: nil, diskMb: nil, linkState: .connected,
            linkError: nil, cpuPercent: nil, memoryUsedMb: nil, diskUsedMb: nil
        )
        let snapshot = SurfaceCatalogSnapshot(machines: [info, emptyInfo], resources: [], projections: [])
        let nodes = CloudTreeNodeBuilder.nodes(
            machines: [first, second], snapshot: snapshot, localWorkspaces: [], includeLocalMachine: false, now: Self.sampleTime
        )
        #expect(nodes.count == 2)
        for node in nodes {
            let children = node.children
            #expect(children.last?.structureTag == "resourcesPool")
            #expect(children.dropLast().map(\.structureTag) == ["workspacesGroup", "portsGroup", "displaysPool", "terminalsPool"])
            #expect(children.last?.children.count == 4)
        }
    }

    @Test @MainActor func resourcesRemainVisibleWhenCatalogEntryIsMissing() throws {
        let snapshot = machine()
        let nodes = CloudTreeNodeBuilder.nodes(
            machines: [snapshot], snapshot: .empty, localWorkspaces: [], includeLocalMachine: false, now: Self.sampleTime
        )
        let children = try #require(nodes.first?.children)
        #expect(children.map(\.structureTag) == ["placeholder", "resourcesPool"])
    }

    @Test("Fresh VM telemetry survives missing or disconnected terminal links",
          arguments: [nil, .connecting, .error, .unavailable, .asleep, .connected] as [SurfaceLinkState?])
    @MainActor func freshReadingsDoNotDependOnTerminalLink(linkState: SurfaceLinkState?) throws {
        let snapshot = machine()
        let info = linkState.map { state in
            SurfaceMachineInfo(
                id: .cloud(snapshot.id), name: snapshot.displayName, status: "running", image: snapshot.image,
                hasDesktop: snapshot.isDesktop, memoryMb: nil, diskMb: nil, linkState: state,
                linkError: nil, cpuPercent: nil, memoryUsedMb: nil, diskUsedMb: nil
            )
        }
        let nodes = CloudTreeNodeBuilder.nodes(
            machines: [snapshot],
            snapshot: SurfaceCatalogSnapshot(machines: info.map { [$0] } ?? [], resources: [], projections: []),
            localWorkspaces: [], includeLocalMachine: false, now: Self.sampleTime
        )
        let resources = try #require(nodes.first?.children.last)
        let expected = CloudTreeMachineResourceSection(machine: snapshot, now: Self.sampleTime).rows
        #expect(resources.children.count == expected.count)
        for (node, reading) in zip(resources.children, expected) {
            guard case .resource(_, let actual) = node.kind else {
                Issue.record("Expected a resource reading")
                continue
            }
            #expect(actual == reading)
        }
    }

    @Test @MainActor func terminalAndResourceDefaultsAreCollapsedButExplicitChoicesWin() throws {
        let snapshot = machine()
        let info = SurfaceMachineInfo(
            id: .cloud(snapshot.id), name: snapshot.displayName, status: "running", image: snapshot.image,
            hasDesktop: snapshot.isDesktop, memoryMb: nil, diskMb: nil, linkState: .connected,
            linkError: nil, cpuPercent: nil, memoryUsedMb: nil, diskUsedMb: nil
        )
        let nodes = CloudTreeNodeBuilder.nodes(
            machines: [snapshot], snapshot: SurfaceCatalogSnapshot(machines: [info], resources: [], projections: []),
            localWorkspaces: [], includeLocalMachine: false, now: Self.sampleTime
        )
        let machineNode = try #require(nodes.first)
        let workspaces = try #require(machineNode.children.first)
        let terminals = try #require(machineNode.children.dropFirst(3).first)
        let resources = try #require(machineNode.children.last)
        let defaults = UserDefaults(suiteName: "CloudTreeResources-\(UUID().uuidString)")!
        let store = CloudTreeExpansionStore(defaults: defaults)
        #expect(store.isExpanded(workspaces))
        #expect(store.isExpanded(machineNode.children[1]))
        #expect(!store.isExpanded(terminals))
        #expect(!store.isExpanded(resources))
        store.setExpanded(true, node: resources)
        store.setExpanded(false, node: workspaces)
        #expect(store.isExpanded(resources))
        #expect(!store.isExpanded(workspaces))
        for _ in 0..<3 { store.reconcile(nodes: []) }
        let reloaded = CloudTreeExpansionStore(defaults: defaults)
        #expect(reloaded.isExpanded(workspaces), "removed dynamic rows do not leave stale collapsed state")
    }

    @Test func resourceRowsKeepTelemetryStatesDistinctAndPreserveZero() {
        var loading = machine()
        loading.stats = nil
        let loadingRows = CloudTreeMachineResourceSection(machine: loading, now: Self.sampleTime).rows
        #expect(loadingRows[0].detail.contains("Loading"))

        let stale = CloudTreeMachineResourceSection(
            machine: machine(resourceSampledAt: Self.sampleTime),
            now: Self.sampleTime.addingTimeInterval(CloudMachineResourcePresentation.staleSampleAge + 1)
        )
        #expect(stale.rows[0].detail.contains("Stale"))

        let zero = CloudTreeMachineResourceSection(
            machine: machine(cpu: 0, memoryUsed: 0, memoryTotal: 4096, diskUsed: 0, diskTotal: 4096),
            now: Self.sampleTime
        )
        #expect(zero.rows[0].detail.contains("0%"))
        #expect(zero.rows[1].detail.contains("0/4"))
        #expect(zero.rows[2].detail.contains("0/4"))
    }
}
