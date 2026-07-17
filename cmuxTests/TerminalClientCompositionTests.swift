import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Terminal client composition", .serialized)
struct TerminalClientCompositionTests {
    @Test @MainActor
    func tabManagerRoutesInitialAndNestedTerminalsThroughOneComposition() throws {
        let recorder = RecordingTerminalPanelFactory()
        let composition = TerminalClientComposition(terminalPanelFactory: recorder)
        let manager = TabManager(
            autoWelcomeIfNeeded: false,
            terminalClientComposition: composition
        )
        defer { manager.tabs.forEach { $0.teardownAllPanels() } }

        let workspace = try #require(manager.tabs.first)
        #expect(manager.terminalClientComposition === composition)
        #expect(workspace.terminalClientComposition === composition)
        #expect(recorder.requests.map(\.origin) == [.workspaceInitial])
        #expect(recorder.requests.first?.workspaceId == workspace.id)

        recorder.removeAllRequests()
        let pane = try #require(workspace.bonsplitController.allPaneIds.first)
        _ = try #require(workspace.newTerminalSurface(inPane: pane, focus: false))

        #expect(recorder.requests.map(\.origin) == [.workspaceTab])
        #expect(recorder.requests.first?.workspaceId == workspace.id)
    }

    @Test @MainActor
    func workspaceDockUsesTheSameCompositionAndDockPlacement() throws {
        let recorder = RecordingTerminalPanelFactory()
        let composition = TerminalClientComposition(terminalPanelFactory: recorder)
        let manager = TabManager(
            autoWelcomeIfNeeded: false,
            terminalClientComposition: composition
        )
        defer { manager.tabs.forEach { $0.teardownAllPanels() } }

        let workspace = try #require(manager.tabs.first)
        let dock = workspace.dockSplit
        #expect(dock.terminalClientComposition === composition)

        recorder.removeAllRequests()
        let pane = try #require(dock.bonsplitController.allPaneIds.first)
        _ = try #require(dock.newSurface(kind: .terminal, inPane: pane, focus: false))

        let request = try #require(recorder.requests.last)
        #expect(request.origin == .dock)
        #expect(request.workspaceId == workspace.id)
        #expect(request.focusPlacement == .rightSidebarDock)
    }

    @Test @MainActor
    func remoteTmuxManualIOUsesTheInjectedFactory() throws {
        let recorder = RecordingTerminalPanelFactory()
        let composition = TerminalClientComposition(terminalPanelFactory: recorder)
        let workspace = Workspace(terminalClientComposition: composition)
        defer { workspace.teardownAllPanels() }

        recorder.removeAllRequests()
        let panel = workspace.makeRemoteTmuxPanePanel(onInput: { _ in })
        defer { panel.close() }

        let request = try #require(recorder.requests.last)
        #expect(request.origin == .remoteTmuxMirror)
        #expect(request.manualIO)
        #expect(request.workspaceId == workspace.id)
    }
}

@MainActor
private final class RecordingTerminalPanelFactory: TerminalPanelCreating {
    private let base = EmbeddedTerminalPanelFactory(
        dependencies: GhosttyApp.terminalSurfaceRuntimeDependencies
    )

    private(set) var requests: [TerminalPanelCreationRequest] = []

    func makeTerminalPanel(_ request: TerminalPanelCreationRequest) -> TerminalPanel {
        requests.append(request)
        return base.makeTerminalPanel(request)
    }

    func removeAllRequests() {
        requests.removeAll()
    }
}
