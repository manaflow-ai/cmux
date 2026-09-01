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

    @Test("same-text auto-to-user ownership removes the transient marker")
    func sameTextOwnershipChangeReconcilesPresentation() throws {
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
        #expect(workspace.bonsplitController.tab(tabId)?.title == "◐ Generated lane")

        #expect(
            workspace.setPanelCustomTitle(
                panelId: panelId,
                title: "Generated lane",
                source: .user
            )
        )
        let tab = try #require(workspace.bonsplitController.tab(tabId))
        #expect(tab.title == "Generated lane")
        #expect(!tab.isLoading)
    }

    @Test("a remote tmux mirror clears stale Codex tab presentation state")
    func remoteMirrorDoesNotRetainCodexMarkerOrLoading() throws {
        let workspace = Workspace()
        let panelId = try #require(workspace.focusedPanelId)
        let tabId = try #require(workspace.surfaceIdFromPanelId(panelId))

        #expect(workspace.updatePanelTitle(panelId: panelId, title: "some-name"))
        workspace.setAgentLifecycle(key: "codex", panelId: panelId, lifecycle: .running)
        #expect(workspace.bonsplitController.tab(tabId)?.title == "◐ some-name")
        #expect(workspace.bonsplitController.tab(tabId)?.isLoading == true)

        // A mirror transition can leave the old local projection in Bonsplit
        // until the next lifecycle/title event. Reconciliation must clear both
        // transient fields when that event arrives.
        workspace.isRemoteTmuxMirror = true
        workspace.setAgentLifecycle(key: "codex", panelId: panelId, lifecycle: .running)

        let tab = try #require(workspace.bonsplitController.tab(tabId))
        #expect(tab.title == "some-name")
        #expect(!tab.isLoading)
    }

    @Test("a remote tmux title event also reconciles stale Codex presentation state")
    func remoteMirrorTitleEventReconcilesPresentation() throws {
        let workspace = Workspace()
        let panelId = try #require(workspace.focusedPanelId)
        let tabId = try #require(workspace.surfaceIdFromPanelId(panelId))

        #expect(workspace.updatePanelTitle(panelId: panelId, title: "some-name"))
        workspace.setAgentLifecycle(key: "codex", panelId: panelId, lifecycle: .running)
        workspace.isRemoteTmuxMirror = true

        // Mirror title events intentionally do not overwrite the local stable
        // title. They still must clear any transient projection inherited
        // before the workspace became a mirror.
        #expect(!workspace.updatePanelTitle(panelId: panelId, title: "remote-name"))

        let tab = try #require(workspace.bonsplitController.tab(tabId))
        #expect(tab.title == "some-name")
        #expect(!tab.isLoading)
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
