import CmuxSettings
import Foundation
import Testing
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// The right sidebar's Cloud tab lists every sidebar workspace under This Mac,
/// terminal or not, ahead of the Cloud machines; the terminal-only listing
/// stays available to callers that ask for it. The footer Cloud button follows
/// the footer presentation policy, including the minimal-mode hover reveal.
@Suite("Sidebar Cloud tab and footer button")
@MainActor
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
            id: LocalSurfaceProvider.resourceID(forTerminalPanel: UUID()), title: "zsh", detail: "~",
            lifecycle: .running, agent: nil, remoteWorkspace: nil, port: nil, url: nil
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

    @Test("The Cloud tab lists every sidebar workspace, in sidebar order, with selection")
    func cloudTabListsEveryWorkspace() {
        let rows = localWorkspaceRows(includeEmpty: true)
        #expect(rows.map(\.workspaceID) == [emptyWorkspace, terminalWorkspace])
        #expect(rows.map(\.terminalCount) == [0, 1])
        #expect(rows.map(\.isSelected) == [true, false])
    }

    @Test("Terminal-only listing stays available when not asked for empty workspaces")
    func terminalOnlyListingStaysAvailable() {
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

    @Test("Settings opens as one pane per workspace and refocuses instead of duplicating")
    func settingsOpensAsOnePane() throws {
        let workspace = Workspace()
        let first = try #require(workspace.openOrFocusSettingsSurface(initialSection: nil))
        #expect(first.panelType == .settings)
        #expect(workspace.settingsPanel?.id == first.id)
        let second = try #require(workspace.openOrFocusSettingsSurface(initialSection: nil))
        #expect(second.id == first.id)
        #expect(workspace.panels.values.filter { $0 is SettingsPanel }.count == 1)
        #expect(workspace.focusedPanelId == first.id)
    }

    @Test("Hiding the Cloud button is a real setting: on by default, in cmux.json, and reversible")
    func hideCloudButtonIsASetting() throws {
        let key = SettingCatalog().sidebar.showCloudButton
        let defaults = try #require(UserDefaults(suiteName: "SidebarCloudWorkspacesSwitcherTests.\(UUID().uuidString)"))
        #expect(key.value(in: defaults) == true)
        key.set(false, in: defaults)
        #expect(key.value(in: defaults) == false)
        key.removeValue(in: defaults)
        #expect(key.value(in: defaults) == true)
        let mapping = try #require(SidebarSettingsFileMapping.booleanSettings.first { $0.jsonKey == "showCloudButton" })
        #expect(mapping.defaultsKey == key.userDefaultsKey)
    }

    @Test("The footer hides the Cloud button in minimal presentation until the footer is hovered")
    func footerRevealsCloudOnHoverInMinimalMode() {
        #expect(SidebarFooterPresentationPolicy.isVisible(.cloud, presentationMode: .minimal) == false)
        #expect(SidebarFooterPresentationPolicy.isVisible(.cloud, presentationMode: .minimal, isHovered: true))
        #expect(SidebarFooterPresentationPolicy.isVisible(.help, presentationMode: .minimal, isHovered: true))
        #expect(SidebarFooterPresentationPolicy.isVisible(.upgrade, presentationMode: .minimal))
        #expect(SidebarFooterPresentationPolicy.isVisible(.cloud, presentationMode: .standard))
    }
}
