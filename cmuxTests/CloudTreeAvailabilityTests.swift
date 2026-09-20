import CmuxSurfaceCatalogModel
import Foundation
import Testing
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite("Cloud tree availability and expansion")
struct CloudTreeAvailabilityTests {
    @Test
    func testCloudTreeSleepingAndBrokenMachinesShowOnePlaceholder() {
        let asleep = CloudTreeNodeBuilder.nodes(
            machines: [machineSnapshot(id: "quiet-owl", image: "cmuxd-ws:tooling-20260509f")],
            snapshot: SurfaceCatalogSnapshot(machines: [machineInfo(.cloud("quiet-owl"), linkState: .asleep, hasDesktop: false)], resources: [], projections: []),
            localWorkspaces: []
        )
        // The link placeholder leads; Ports stays reachable, and Resources is
        // always the final machine section.
        #expect(CloudTreeNodeBuilder.flattened(asleep).map(\.id) == ["machine:quiet-owl", "machine:quiet-owl/placeholder", "machine:quiet-owl/ports", "machine:quiet-owl/ports/status", "machine:quiet-owl/resources", "machine:quiet-owl/resources/cpu", "machine:quiet-owl/resources/memory", "machine:quiet-owl/resources/disk", "machine:quiet-owl/resources/usage"])
        if case .placeholder(_, let placeholder) = asleep[0].children[0].kind { #expect(placeholder.style == .dimmed) } else { Issue.record("Unexpected node kind") }
        if case .placeholder(_, let ports) = asleep[0].children[1].children[0].kind { #expect(ports.style == .dimmed) } else { Issue.record("Unexpected node kind") }

        let broken = CloudTreeNodeBuilder.nodes(
            machines: [machineSnapshot(id: "broken-elk")],
            snapshot: SurfaceCatalogSnapshot(machines: [machineInfo(.cloud("broken-elk"), linkState: .error, linkError: "timed out", hasDesktop: false)], resources: [], projections: []),
            localWorkspaces: []
        )
        if case .placeholder(_, let placeholder) = broken[0].children[0].kind {
            #expect(placeholder.style == .error)
            #expect(placeholder.text == "timed out")
        } else { Issue.record("Unexpected node kind") }
        // A machine the catalog has not registered yet still gets its final
        // Resources section while the surface connection is connecting.
        let unregistered = CloudTreeNodeBuilder.nodes(machines: [machineSnapshot(id: "new")], snapshot: .empty, localWorkspaces: [])
        #expect(CloudTreeNodeBuilder.flattened(unregistered[0].children).map(\.id) == ["machine:new/placeholder", "machine:new/resources", "machine:new/resources/cpu", "machine:new/resources/memory", "machine:new/resources/disk", "machine:new/resources/usage"])
        if case .placeholder(_, let placeholder) = unregistered[0].children[0].kind { #expect(placeholder.style == .connecting) } else { Issue.record("Unexpected node kind") }
        // A machine only the catalog knows still gets a row.
        let catalogOnly = CloudTreeNodeBuilder.nodes(
            machines: [],
            snapshot: SurfaceCatalogSnapshot(machines: [machineInfo(.cloud("ghost"))], resources: [], projections: []),
            localWorkspaces: []
        )
        #expect(catalogOnly.map(\.id) == ["machine:ghost"])
    }


    @Test
    func testCloudTreeExpansionStoreDefaultsToExpandedAndPersistsMachineCollapse() {
        let suite = "CloudTreeExpansionStoreTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = CloudTreeExpansionStore(defaults: defaults)
        let nodes = CloudTreeNodeBuilder.nodes(
            machines: [machineSnapshot(id: "vivid-newt")],
            snapshot: SurfaceCatalogSnapshot(machines: [machineInfo(.local), machineInfo(.cloud("vivid-newt"))], resources: [terminal(.cloud("vivid-newt"), "term_1")], projections: []),
            localWorkspaces: [],
            includeLocalMachine: true
        )
        let localNode = nodes[0], machineNode = nodes[1], group = machineNode.children[0]
        #expect(store.isExpanded(localNode))
        #expect(store.isExpanded(machineNode))
        #expect(store.isExpanded(group))
        store.setExpanded(false, node: machineNode)
        store.setExpanded(false, node: localNode)
        store.setExpanded(false, node: group)
        let reloaded = CloudTreeExpansionStore(defaults: defaults)
        #expect(!(reloaded.isExpanded(machineNode)), "machine collapse persists")
        #expect(!(reloaded.isExpanded(localNode)), "This Mac's collapse persists too")
        #expect(!(reloaded.isExpanded(group)), "nested collapses persist across panel reloads")
    }

    private func machineSnapshot(id: String, image: String = "cmux-xfce-vnc:latest") -> MachineSnapshot {
        MachineSnapshotBuilder.snapshot(from: VMSummary(
            id: id, provider: "freestyle", status: "running", image: image, createdAt: 0, base: nil
        ))
    }

    private func machineInfo(
        _ id: SurfaceMachineID,
        name: String? = nil,
        linkState: SurfaceLinkState = .connected,
        linkError: String? = nil,
        hasDesktop: Bool = true,
        remoteWorkspaces: [SurfaceRemoteWorkspace]? = nil
    ) -> SurfaceMachineInfo {
        SurfaceMachineInfo(
            id: id, name: name ?? id.rawValue, status: "running", image: hasDesktop ? "cmux-xfce-vnc:latest" : "cmuxd-ws:tooling-20260509f",
            hasDesktop: hasDesktop, memoryMb: nil, diskMb: nil, linkState: linkState, linkError: linkError,
            cpuPercent: nil, memoryUsedMb: nil, diskUsedMb: nil, remoteWorkspaces: remoteWorkspaces
        )
    }

    private func terminal(
        _ machine: SurfaceMachineID, _ key: String, title: String = "shell", cwd: String? = "/root",
        lifecycle: SurfaceLifecycle = .running, workspace: SurfaceRemoteWorkspace? = nil, agent: SurfaceAgentBadge? = nil
    ) -> SurfaceResource {
        SurfaceResource(
            id: SurfaceResourceID(machine: machine, kind: .terminal, key: key), title: title, detail: cwd,
            lifecycle: lifecycle, agent: agent, remoteWorkspace: workspace, port: nil, url: nil
        )
    }

}
