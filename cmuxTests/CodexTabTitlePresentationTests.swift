import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Regression coverage for the Codex lifecycle-to-tab-title presentation path.
@MainActor
@Suite(.serialized)
struct CodexTabTitlePresentationTests {
    @Test("a running Codex turn decorates the tab without changing its stable title")
    func runningTurnShowsAnimatedMarker() throws {
        let workspace = Workspace()
        let panelId = try #require(workspace.focusedPanelId)
        let tabId = try #require(workspace.surfaceIdFromPanelId(panelId))

        #expect(workspace.updatePanelTitle(panelId: panelId, title: "some-name"))
        workspace.setAgentLifecycle(
            key: "codex",
            panelId: panelId,
            lifecycle: .running
        )

        let tab = try #require(workspace.bonsplitController.tab(tabId))
        #expect(tab.title == "◐ some-name")
        #expect(workspace.panelTitles[panelId] == "some-name")
    }

    @Test("an idle Codex turn leaves the completion marker on the tab")
    func idleTurnShowsCompletionMarker() throws {
        let workspace = Workspace()
        let panelId = try #require(workspace.focusedPanelId)
        let tabId = try #require(workspace.surfaceIdFromPanelId(panelId))

        #expect(workspace.updatePanelTitle(panelId: panelId, title: "some-name"))
        workspace.setAgentLifecycle(key: "codex", panelId: panelId, lifecycle: .running)
        workspace.setAgentLifecycle(key: "codex", panelId: panelId, lifecycle: .idle)

        let tab = try #require(workspace.bonsplitController.tab(tabId))
        #expect(tab.title == "✳ some-name")
    }

    @Test("a user-owned tab title is never decorated by Codex lifecycle state")
    func customTitleWins() throws {
        let workspace = Workspace()
        let panelId = try #require(workspace.focusedPanelId)
        let tabId = try #require(workspace.surfaceIdFromPanelId(panelId))

        #expect(workspace.setPanelCustomTitle(panelId: panelId, title: "Pinned lane"))
        workspace.setAgentLifecycle(key: "codex", panelId: panelId, lifecycle: .running)

        let tab = try #require(workspace.bonsplitController.tab(tabId))
        #expect(tab.title == "Pinned lane")
    }
}
