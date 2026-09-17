import AppKit
import Bonsplit
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite("Whole Cloud tool panes", .serialized)
struct CloudToolPaneTests {
    @Test("Cloud opens as a tool and reuses its pane without creating remote surfaces")
    func cloudToolCreationAndReuse() async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let fixture = try VaultPaneAppFixture()
            defer { fixture.tearDown() }
            let workspace = fixture.workspace
            let pane = try #require(workspace.bonsplitController.allPaneIds.first)
            let originalPanels = Set(workspace.panels.keys)
            let cloud = try #require(workspace.openOrFocusRightSidebarToolSurface(
                inPane: pane, mode: .machines, focus: false
            ))
            let reopened = workspace.openOrFocusRightSidebarToolSurface(
                inPane: pane, mode: .machines, focus: false
            )
            #expect(reopened === cloud)
            #expect(cloud.panelType == .rightSidebarTool)
            #expect(cloud.displayTitle == RightSidebarMode.machines.label)
            #expect(Set(workspace.panels.keys).subtracting(originalPanels) == [cloud.id])
            let snapshot = workspace.sessionSnapshot(includeScrollback: false)
            #expect(snapshot.panels.first { $0.id == cloud.id }?.rightSidebarTool?.mode == .machines)
            let restored = TabManager(autoWelcomeIfNeeded: false)
            defer { restored.tabs.forEach { $0.teardownAllPanels() } }
            restored.restoreSessionSnapshot(fixture.manager.sessionSnapshot(includeScrollback: false))
            #expect(restored.tabs.flatMap { $0.panels.values }.compactMap { $0 as? RightSidebarToolPanel }
                .contains { $0.mode == .machines })
        }
    }

    @Test("The palette offers the whole Cloud tool alongside Files and Vault")
    func cloudToolPaletteContribution() {
        let descriptors = ContentView.commandPaletteRightSidebarToolPaneCommandDescriptors()
        #expect(descriptors.contains { $0.mode == .machines })
        #expect(descriptors.contains { $0.mode == .files })
        #expect(descriptors.contains { $0.mode == .sessions })
    }
}
