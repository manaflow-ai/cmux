import CmuxCloud
import CmuxCloudMachines
import CmuxSurfaceCatalogModel
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite("Cloud tree input and resource cache")
struct CloudTreeNodeCacheTests {
    private let now = Date(timeIntervalSince1970: 1_780_000_000)

    @Test func identicalInputsSkipBuildAndEqualReadingsSharePresentation() throws {
        var presentations = 0
        let cache = CloudTreeNodeCache(resources: CloudTreeMachineResourceCache { machine, time in
            presentations += 1
            return CloudTreeMachineResourceSection(machine: machine, now: time)
        })
        var inputs = CloudTreeBuildInputs(machines: (0..<1_000).map { machine(id: "\($0)") }, snapshot: .empty)
        let first = try #require(cache.nodes(ifChanged: inputs, now: now))
        #expect(presentations == 1, "Machine identity is not a resource-formatting input")
        let section = try #require(first.first?.resourceSection)
        #expect(first.allSatisfy { $0.resourceSection === section })
        #expect(cache.nodes(ifChanged: inputs, now: now.addingTimeInterval(1)) == nil)
        #expect(presentations == 1)

        inputs.unreadTerminalIDs = ["0": ["terminal"]]
        let unreadUpdate = try #require(cache.nodes(ifChanged: inputs, now: now))
        #expect(unreadUpdate.first?.resourceSection === section)
        #expect(presentations == 1, "Unrelated catalog changes do not reformat resource values")
        inputs.machines[0].stats = stats(cpu: 83)
        let refreshed = try #require(cache.nodes(ifChanged: inputs, now: now))
        #expect(presentations == 2)
        let changed = try #require(refreshed.first?.resourceSection)
        #expect(changed.metrics.cpu.percent == 83)
        let machineRow = CloudTreeMachineRowContent(machine: inputs.machines[0], now: now, resources: changed)
        #expect(machineRow.toolTip.contains(changed.metrics.cpu.detail))
        #expect(machineRow.accessibilityLabel.contains(changed.metrics.cpu.detail))
        #expect(refreshed[1].resourceSection === section)
        print("Cloud resource benchmark machines=1000 initialPresentations=1 unchangedPresentations=0 changedPresentations=1 kindBytes=\(MemoryLayout<CloudTreeNode.Kind>.size)")
    }

    @Test func freshnessChangesOnceAtTheActualBoundary() throws {
        var presentations = 0
        let cache = CloudTreeNodeCache(resources: CloudTreeMachineResourceCache { machine, time in
            presentations += 1
            return CloudTreeMachineResourceSection(machine: machine, now: time)
        })
        let inputs = CloudTreeBuildInputs(machines: [machine()], snapshot: .empty)
        let first = try #require(cache.nodes(ifChanged: inputs, now: now))
        #expect(first[0].resourceSection?.metrics.availability == .awake)
        #expect(cache.nodes(ifChanged: inputs, now: now.addingTimeInterval(90)) == nil)
        let stale = try #require(cache.nodes(ifChanged: inputs, now: now.addingTimeInterval(91)))
        #expect(stale[0].resourceSection?.metrics.availability == .stale)
        #expect(presentations == 2)
        #expect(cache.nodes(ifChanged: inputs, now: now.addingTimeInterval(120)) == nil)
        #expect(presentations == 2)
        #expect(CloudTreeNodeBuilder.contentSignature(first) != CloudTreeNodeBuilder.contentSignature(stale))
    }

    @Test func futureSamplesAndClockRollbackInvalidateReadings() throws {
        let cache = CloudTreeNodeCache()
        let inputs = CloudTreeBuildInputs(machines: [machine()], snapshot: .empty)
        let future = try #require(cache.nodes(ifChanged: inputs, now: now.addingTimeInterval(-1)))
        #expect(future[0].resourceSection?.metrics.availability == .unavailable)
        let current = try #require(cache.nodes(ifChanged: inputs, now: now))
        #expect(current[0].resourceSection?.metrics.availability == .awake)
        let rollback = try #require(cache.nodes(ifChanged: inputs, now: now.addingTimeInterval(-1)))
        #expect(rollback[0].resourceSection?.metrics.availability == .unavailable)
    }

    @Test func everyTreeInputParticipatesInInvalidation() {
        let initial = CloudTreeBuildInputs(machines: [machine()], snapshot: .empty)
        let mutations: [(inout CloudTreeBuildInputs) -> Void] = [
            { $0.machines[0].isPinned.toggle() },
            { $0.pendingCreates = [.init(
                id: UUID(), request: .init(mode: .newMachine, kind: .base, name: nil, arguments: []),
                startedAt: .distantPast
            )] },
            { $0.adoptedOperationIDs = ["resource-test": UUID()] },
            { $0.snapshot.staleMachineIDs.insert(.cloud("resource-test")) },
            { $0.localWorkspaces = [.init(id: UUID(), title: "Local", isSelected: true)] },
            { $0.unreadTerminalIDs = ["resource-test": ["terminal"]] },
            { $0.pinnedMachineIDs = ["resource-test"] },
            { $0.includeLocalMachine.toggle() },
            { $0.source = .devices },
            { $0.devicesSection.incomingAccessEnabled.toggle() },
            { $0.canCreateCloudMachine.toggle() },
            { $0.localeIdentifier = "ja_JP" },
        ]
        for mutate in mutations {
            var builds = 0
            let cache = CloudTreeNodeCache(buildNodes: { _ in builds += 1; return [] })
            #expect(cache.nodes(ifChanged: initial, now: now) != nil)
            var changed = initial
            mutate(&changed)
            #expect(cache.nodes(ifChanged: changed, now: now) != nil)
            #expect(cache.nodes(ifChanged: changed, now: now) == nil)
            #expect(builds == 2)
        }
    }

    @Test func usageAndLocaleChangesReplaceTheSharedSection() throws {
        var presentations = 0
        let cache = CloudTreeNodeCache(resources: CloudTreeMachineResourceCache { machine, time in
            presentations += 1
            return CloudTreeMachineResourceSection(machine: machine, now: time)
        })
        var inputs = CloudTreeBuildInputs(machines: [machine()], snapshot: .empty)
        _ = cache.nodes(ifChanged: inputs, now: now)
        inputs.machines[0].usage = MachineUsageSnapshot(
            vmID: "resource-test", periodDays: 30,
            totals: .init(inputTokens: 1, cachedInputTokens: 0, outputTokens: 1, totalTokens: 2, apiEquivalentUsd: 1.23)
        )
        let billed = try #require(cache.nodes(ifChanged: inputs, now: now))
        #expect(billed[0].resourceSection?.usageSummary.contains("1.23") == true)
        #expect(presentations == 2)
        inputs.localeIdentifier = "ja_JP"
        #expect(cache.nodes(ifChanged: inputs, now: now) != nil)
        #expect(presentations == 3)
    }

    @Test func cloudCreationCapabilityUpdatesTheExistingHeader() throws {
        let cache = CloudTreeNodeCache()
        var inputs = CloudTreeBuildInputs(machines: [], snapshot: .empty, source: .cloudWithDevicesSection)
        let disabled = try #require(cache.nodes(ifChanged: inputs, now: now)?.first)
        #expect(disabled.kind == .cloudMachinesSection(canCreateMachine: false))
        inputs.canCreateCloudMachine = true
        let enabled = try #require(cache.nodes(ifChanged: inputs, now: now)?.first)
        #expect(enabled.id == disabled.id)
        #expect(enabled.kind == .cloudMachinesSection(canCreateMachine: true))
    }

    @Test func evictsReadingsForRemovedMachines() {
        var presentations = 0
        let cache = CloudTreeNodeCache(resources: CloudTreeMachineResourceCache { machine, time in
            presentations += 1
            return CloudTreeMachineResourceSection(machine: machine, now: time)
        })
        let inputs = CloudTreeBuildInputs(machines: [machine()], snapshot: .empty)
        _ = cache.nodes(ifChanged: inputs, now: now)
        _ = cache.nodes(ifChanged: .init(machines: [], snapshot: .empty), now: now)
        _ = cache.nodes(ifChanged: inputs, now: now)
        #expect(presentations == 2)
    }

    private func machine(id: String = "resource-test") -> MachineSnapshot {
        MachineSnapshot(id: id, provider: "freestyle", image: "test", isDesktop: false,
                        activity: .ready, stats: stats())
    }

    private func stats(cpu: Double = 9.4) -> VMStats {
        VMStats(state: .awake, sampledAt: now, resourceSampledAt: now,
                cpus: 4, cpuPercent: cpu, loadAverage1m: nil,
                memoryTotalMb: 4096, memoryUsedMb: 2048, diskTotalMb: 4096, diskUsedMb: 3072)
    }
}
