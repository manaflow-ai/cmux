import Foundation
import Testing
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// The footer Cloud Workspaces switcher lists every sidebar workspace under
/// This Mac, terminal or not, ahead of the Cloud machines. The Machines panel
/// keeps its terminal-only listing.
@Suite("Sidebar Cloud Workspaces switcher")
struct SidebarCloudWorkspacesSwitcherTests {
    private let localInfo = SurfaceMachineInfo(
        id: .local, name: "This Mac", status: "running", image: nil, hasDesktop: false,
        memoryMb: nil, diskMb: nil, linkState: .notApplicable, linkError: nil,
        cpuPercent: nil, memoryUsedMb: nil, diskUsedMb: nil
    )
    private let emptyWorkspace = UUID()
    private let terminalWorkspace = UUID()

    private func snapshot() -> SurfaceCatalogSnapshot {
        let terminal = SurfaceResource(
            id: LocalSurfaceProvider.resourceID(forTerminalPanel: UUID()),
            kind: .terminal, title: "zsh", lifecycle: .running
        )
        let projection = SurfaceProjection(resource: terminal.id, workspaceID: terminalWorkspace, panelID: UUID())
        return SurfaceCatalogSnapshot(machines: [localInfo], resources: [terminal], projections: [projection])
    }

    private var localWorkspaces: [CloudTreeLocalWorkspace] {
        [
            CloudTreeLocalWorkspace(id: emptyWorkspace, title: "Browser only", isSelected: true),
            CloudTreeLocalWorkspace(id: terminalWorkspace, title: "Shell", isSelected: false),
        ]
    }

    private func localWorkspaceRows(includeEmpty: Bool) -> [CloudTreeLocalWorkspaceRow] {
        let nodes = CloudTreeNodeBuilder.nodes(
            machines: [], snapshot: snapshot(), localWorkspaces: localWorkspaces,
            includeLocalMachine: true, includeEmptyLocalWorkspaces: includeEmpty
        )
        return CloudTreeNodeBuilder.flattened(nodes).compactMap {
            if case .localWorkspace(let row) = $0.kind { return row }
            return nil
        }
    }

    @Test("The switcher lists every sidebar workspace, in sidebar order, with selection")
    func switcherListsEveryWorkspace() {
        let rows = localWorkspaceRows(includeEmpty: true)
        #expect(rows.map(\.workspaceID) == [emptyWorkspace, terminalWorkspace])
        #expect(rows.map(\.terminalCount) == [0, 1])
        #expect(rows.map(\.isSelected) == [true, false])
    }

    @Test("The Machines panel keeps listing only workspaces with a terminal")
    func machinesPanelKeepsTerminalOnlyListing() {
        #expect(localWorkspaceRows(includeEmpty: false).map(\.workspaceID) == [terminalWorkspace])
    }

    @Test("This Mac leads the tree ahead of Cloud machines")
    func thisMacLeadsTheTree() {
        let machine = MachineSnapshot(
            id: "vm-1", provider: "freestyle", image: "base", isDesktop: false,
            activity: .ready, createdAt: nil, label: nil
        )
        let nodes = CloudTreeNodeBuilder.nodes(
            machines: [machine], snapshot: snapshot(), localWorkspaces: localWorkspaces,
            includeLocalMachine: true, includeEmptyLocalWorkspaces: true
        )
        #expect(nodes.count == 2)
        guard case .localMachine = nodes[0].kind else {
            Issue.record("This Mac must be the first row")
            return
        }
        guard case .machine(let row, _) = nodes[1].kind else {
            Issue.record("The Cloud machine must follow This Mac")
            return
        }
        #expect(row.id == "vm-1")
    }

    @Test("The footer hides the Cloud button in minimal presentation, like the account button")
    func footerHidesCloudInMinimalMode() {
        #expect(SidebarFooterPresentationPolicy.isVisible(.cloud, presentationMode: .minimal) == false)
        #expect(SidebarFooterPresentationPolicy.isVisible(.cloud, presentationMode: .standard))
    }
}
