import AppKit
import Bonsplit
import Foundation
import Testing
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite("CodeRouter setup terminal admission", .serialized, .exclusiveAppContext)
struct CoderouterSetupTerminalTests {
    @Test("A missing setup destination leaves no terminal in another workspace")
    func missingDestinationDoesNotLaunchElsewhere() throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let before = Set(fixture.app.workspace.panels.keys)
        let coordinator = CoderouterSetupWorkspaceCoordinator(
            managerSource: { fixture.app.manager },
            provider: .codex,
            initialTerminalCommand: "printf 'setup'"
        )

        #expect(throws: SurfacePaneFactory.FactoryError.self) {
            try coordinator.launchAccountTerminal(in: UUID())
        }

        #expect(Set(fixture.app.workspace.panels.keys) == before)
        #expect(fixture.app.manager.tabs.count == 1)
    }

    @Test("A setup split with no room leaves every workspace unchanged")
    func fullDestinationDoesNotLaunchElsewhere() throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let destination = fixture.app.manager.addWorkspace(select: false, autoWelcomeIfNeeded: false)
        destination.bonsplitController.setContainerFrame(CGRect(x: 0, y: 0, width: 400, height: 700))
        let first = try #require(destination.focusedPanelId)
        try #require(destination.newTerminalSplitOutcome(from: first, orientation: .horizontal).panel != nil)
        fixture.app.manager.selectWorkspace(fixture.app.workspace)
        let sourcePanels = Set(fixture.app.workspace.panels.keys)
        let targetPanels = Set(destination.panels.keys)
        let coordinator = CoderouterSetupWorkspaceCoordinator(
            managerSource: { fixture.app.manager }, provider: .codex,
            initialTerminalCommand: "printf 'setup'"
        )

        do {
            try coordinator.launchAccountTerminal(in: destination.id)
            Issue.record("A full setup destination accepted another split")
        } catch SurfacePaneFactory.FactoryError.noSpace {
            // Admission refuses the destination before a terminal is created.
        }

        #expect(Set(fixture.app.workspace.panels.keys) == sourcePanels)
        #expect(Set(destination.panels.keys) == targetPanels)
        #expect(fixture.app.manager.selectedTabId == fixture.app.workspace.id)
    }

    @Test("Setup launches exactly one focused local pane with its command and name")
    func setupTerminalKeepsLaunchContract() throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let workspace = fixture.app.workspace
        let before = Set(workspace.panels.keys)
        let command = "printf 'setup with spaces'"
        let coordinator = CoderouterSetupWorkspaceCoordinator(
            managerSource: { fixture.app.manager }, provider: .codex,
            initialTerminalCommand: command
        )

        try coordinator.launchAccountTerminal(in: workspace.id)

        let added = Set(workspace.panels.keys).subtracting(before)
        try #require(added.count == 1)
        let panelID = try #require(added.first)
        let terminal = try #require(workspace.terminalPanel(for: panelID))
        #expect(workspace.focusedPanelId == panelID)
        #expect(terminal.surface.debugInitialCommand() == #"sh -lc 'printf '\''setup with spaces'\'''"#)
        let resourceID = LocalSurfaceProvider.resourceID(forTerminalPanel: panelID)
        #expect(SurfaceCatalog.shared.resources[resourceID]?.title == "CodeRouter")
        #expect(SurfaceCatalog.shared.projection(forPanel: panelID)?.workspaceID == workspace.id)
    }

    @MainActor
    private struct Fixture {
        let app: VaultPaneAppFixture
        let window: NSWindow
        let previousProvider: (any SurfaceProvider)?
        let previousManager: TabManager?

        init() throws {
            previousProvider = SurfaceCatalog.shared.provider(for: .local)
            previousManager = TerminalController.shared.activeTabManagerForCallerNotification()
            app = try VaultPaneAppFixture()
            window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 1_000, height: 700),
                styleMask: [.titled], backing: .buffered, defer: false
            )
            window.isReleasedWhenClosed = false
            window.identifier = NSUserInterfaceItemIdentifier("cmux.main.\(app.windowID.uuidString)")
            let context = try #require(app.appDelegate.mainWindowContexts.values.first { $0.windowId == app.windowID })
            context.window = window
            app.manager.window = window
            app.workspace.bonsplitController.setContainerFrame(window.contentLayoutRect)
            SurfaceCatalog.shared.register(LocalSurfaceProvider.shared)
            TerminalController.shared.setActiveTabManager(app.manager)
        }

        func close() {
            app.manager.tabs.forEach { $0.teardownAllPanels() }
            app.tearDown()
            if let previousProvider {
                SurfaceCatalog.shared.register(previousProvider)
            } else {
                SurfaceCatalog.shared.unregister(machine: .local)
            }
            TerminalController.shared.setActiveTabManager(previousManager)
            window.close()
        }
    }
}
