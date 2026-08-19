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
        #expect(tab.isLoading)
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
        #expect(!tab.isLoading)
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
        #expect(tab.isLoading)
    }

    @Test("an auto-generated title still receives Codex lifecycle markers")
    func autoTitleIsNotTreatedAsUserOwned() throws {
        let workspace = Workspace()
        let panelId = try #require(workspace.focusedPanelId)
        let tabId = try #require(workspace.surfaceIdFromPanelId(panelId))

        #expect(
            workspace.setPanelCustomTitle(
                panelId: panelId,
                title: "Generated lane",
                source: .auto
            )
        )
        workspace.setAgentLifecycle(key: "codex", panelId: panelId, lifecycle: .running)

        let tab = try #require(workspace.bonsplitController.tab(tabId))
        #expect(tab.title == "◐ Generated lane")
        #expect(tab.isLoading)
    }

    @Test("another agent lifecycle key does not borrow Codex title markers")
    func nonCodexLifecycleIsIgnored() throws {
        let workspace = Workspace()
        let panelId = try #require(workspace.focusedPanelId)
        let tabId = try #require(workspace.surfaceIdFromPanelId(panelId))

        #expect(workspace.updatePanelTitle(panelId: panelId, title: "some-name"))
        workspace.setAgentLifecycle(
            key: "claude_code",
            panelId: panelId,
            lifecycle: .running
        )

        let tab = try #require(workspace.bonsplitController.tab(tabId))
        #expect(tab.title == "some-name")
        #expect(!tab.isLoading)
    }
}
