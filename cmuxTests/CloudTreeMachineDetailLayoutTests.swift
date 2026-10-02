import AppKit
import CmuxCloud
import CmuxSurfaceCatalogModel
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite("Cloud machine detail tabs", .serialized)
struct CloudTreeMachineDetailLayoutTests {
    @Test("A machine shows its workspaces, then Displays, then one tab row and a closing gap")
    func machineChildrenAreRegrouped() throws {
        let fixture = CloudSidebarOrderingFixture()
        defer { fixture.close() }
        let machine = try Self.machine(in: CloudTreeMachineDetailLayout().present(fixture.nodes()))
        let tags = machine.children.map(\.structureTag)
        #expect(tags == ["workspace", "workspace", "displaysPool", "machineDetailTabs", "machineEndSpacer"])
        let tabsRow = try #require(machine.children.first { $0.structureTag == "machineDetailTabs" })
        #expect(tabsRow.children.isEmpty, "No tab is open until the person picks one")
        #expect(tabsRow.detailPools.map(\.structureTag) == ["portsGroup", "terminalsPool", "resourcesPool"])
        guard case .machineDetailTabs(let tabs) = tabsRow.kind else { Issue.record("not a tab row"); return }
        #expect(tabs.tabs == [.ports, .terminals, .resources])
        #expect(tabs.selected == nil)
        #expect(tabs.count(for: .terminals) == 2)
        #expect(tabs.count(for: .resources) == nil)
    }

    @Test("Opening Terminals shows New Terminal, then every terminal labelled with its workspace")
    func terminalsTabShowsItsRows() throws {
        let fixture = CloudSidebarOrderingFixture()
        defer { fixture.close() }
        var layout = CloudTreeMachineDetailLayout()
        #expect(layout.toggle(.terminals, machine: fixture.machine) == .terminals)
        let machine = try Self.machine(in: layout.present(fixture.nodes()))
        let tabsRow = try #require(machine.children.first { $0.structureTag == "machineDetailTabs" })
        // The row takes the open group's id, so its rows keep their saved order key.
        #expect(tabsRow.id == CloudTreeNodeBuilder.nodeID(terminalsPool: fixture.machine))
        #expect(tabsRow.children.first?.kind == .createAction(.newTerminal(fixture.machine)))
        #expect(tabsRow.children.map(\.structureTag) == ["createAction", "terminal", "terminal"])
        let labels = tabsRow.children.compactMap { node -> String? in
            if case .terminal(let row) = node.kind { return row.workspaceLabel }
            return nil
        }
        #expect(labels == ["cmux1", "cmux2"])
        #expect(layout.toggle(.terminals, machine: fixture.machine) == nil, "Clicking the open tab closes it")
    }

    @Test("A terminal in no workspace is listed too, with no workspace label")
    func terminalsTabListsLooseTerminals() throws {
        let fixture = CloudSidebarOrderingFixture()
        defer { fixture.close() }
        var snapshot = fixture.snapshot()
        let loose = SurfaceResource(
            id: SurfaceResourceID(machine: fixture.machine, kind: .terminal, key: "term_loose"),
            title: "zsh", detail: "~", lifecycle: .running, agent: nil,
            remoteWorkspace: nil, port: nil, url: nil
        )
        snapshot = SurfaceCatalogSnapshot(machines: snapshot.machines, resources: snapshot.resources + [loose], projections: [])
        var layout = CloudTreeMachineDetailLayout()
        layout.toggle(.terminals, machine: fixture.machine)
        let nodes = layout.present(CloudTreeNodeBuilder.nodes(
            machines: [], snapshot: snapshot, localWorkspaces: [], includeLocalMachine: false
        ))
        let machine = try Self.machine(in: nodes)
        let tabsRow = try #require(machine.children.first { $0.structureTag == "machineDetailTabs" })
        guard case .machineDetailTabs(let tabs) = tabsRow.kind else { Issue.record("not a tab row"); return }
        #expect(tabs.count(for: .terminals) == 3)
        let looseRow = try #require(tabsRow.children.first { $0.id == CloudTreeNodeBuilder.nodeID(resource: loose.id) })
        guard case .terminal(let row) = looseRow.kind else { Issue.record("not a terminal row"); return }
        #expect(row.workspaceLabel == nil)
    }

    @Test("Presenting an already presented tree changes nothing")
    func presentingTwiceIsStable() throws {
        let fixture = CloudSidebarOrderingFixture()
        defer { fixture.close() }
        var layout = CloudTreeMachineDetailLayout()
        layout.toggle(.ports, machine: fixture.machine)
        let once = layout.present(fixture.nodes())
        let ids = CloudTreeNodeBuilder.flattened(once).map(\.id)
        let twice = layout.present(once)
        #expect(CloudTreeNodeBuilder.flattened(twice).map(\.id) == ids)
        layout.toggle(.resources, machine: fixture.machine)
        let switched = try Self.machine(in: layout.present(twice))
        let tabsRow = try #require(switched.children.first { $0.structureTag == "machineDetailTabs" })
        #expect(tabsRow.children.allSatisfy { $0.structureTag == "resource" })
    }

    @Test("A machine's workspaces keep the Workspaces group's order key")
    func workspacesKeepTheirOrganizationKey() throws {
        let fixture = CloudSidebarOrderingFixture()
        defer { fixture.close() }
        let machine = try Self.machine(in: CloudTreeMachineDetailLayout().present(fixture.nodes()))
        #expect(machine.organizationGroupID == CloudTreeNodeBuilder.nodeID(workspacesGroup: fixture.machine))
        let folder = try #require(machine.children.first)
        #expect(CloudSidebarOrganizationTree(nodes: [machine]).parent(of: folder.id)?.id == machine.id)
    }

    @Test("Opening a tab through the coordinator re-presents the outline")
    func coordinatorTogglesTabs() throws {
        let fixture = CloudSidebarOrderingFixture()
        defer { fixture.close() }
        fixture.coordinator.update(inputs: .init(machines: [], snapshot: fixture.snapshot(), source: .cloudWithDevicesSection))
        fixture.coordinator.toggleMachineDetailTab(.terminals, machine: fixture.machine)
        let outline = try #require(fixture.coordinator.outlineView)
        let rows = (0..<outline.numberOfRows).compactMap { outline.item(atRow: $0) as? CloudTreeNode }
        let tabsRow = try #require(rows.first { $0.structureTag == "machineDetailTabs" })
        #expect(outline.isItemExpanded(tabsRow))
        #expect(rows.contains { $0.kind == .createAction(.newTerminal(fixture.machine)) })
        #expect(outline.frameOfOutlineCell(atRow: outline.row(forItem: tabsRow)) == .zero, "The tab row has no disclosure")
        #expect(!tabsRow.kind.isSelectable)
        fixture.coordinator.toggleMachineDetailTab(.terminals, machine: fixture.machine)
        let closed = (0..<outline.numberOfRows).compactMap { outline.item(atRow: $0) as? CloudTreeNode }
        #expect(!closed.contains { $0.kind == .createAction(.newTerminal(fixture.machine)) })
    }

    private static func machine(in nodes: [CloudTreeNode]) throws -> CloudTreeNode {
        try #require(CloudTreeNodeBuilder.flattened(nodes).first { $0.structureTag == "machine" })
    }
}
