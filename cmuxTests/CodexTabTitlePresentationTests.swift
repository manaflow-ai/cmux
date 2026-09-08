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
    @Test(
        "binding the initial terminal preserves the workspace title before OSC output",
        arguments: ["Terminal 2", "project-name", "host.example"]
    )
    func initialTabPreservesWorkspaceTitle(initialTitle: String) throws {
        let workspace = Workspace(title: initialTitle)
        let panelId = try #require(workspace.focusedPanelId)
        let tabId = try #require(workspace.surfaceIdFromPanelId(panelId))

        let initialTab = try #require(workspace.bonsplitController.tab(tabId))
        #expect(initialTab.title == initialTitle)
        #expect(!initialTab.hasCustomTitle)
        #expect(!initialTab.isLoading)
        #expect(workspace.panelTitles[panelId] == initialTitle)
        #expect(workspace.panelCustomTitles[panelId] == nil)

        workspace.setAgentLifecycle(key: "codex", panelId: panelId, lifecycle: .running)
        workspace.bindSurface(tabId, toPanelId: panelId)
        #expect(workspace.bonsplitController.tab(tabId)?.title == "◐ \(initialTitle)")
        #expect(workspace.bonsplitController.tab(tabId)?.isLoading == true)
        #expect(workspace.panelTitles[panelId] == initialTitle)

        #expect(workspace.updatePanelTitle(panelId: panelId, title: "thread-name"))
        #expect(workspace.bonsplitController.tab(tabId)?.title == "◐ thread-name")
        #expect(workspace.panelTitles[panelId] == "thread-name")

        workspace.clearAgentLifecycle(key: "codex", panelId: panelId)
        #expect(workspace.bonsplitController.tab(tabId)?.title == "thread-name")
        #expect(workspace.bonsplitController.tab(tabId)?.isLoading == false)
    }

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

    @Test(
        "a remote title acknowledgment preserves custom-title protection",
        arguments: [Workspace.CustomTitleSource.user, .auto]
    )
    func remoteTitleAcknowledgmentPreservesOwnership(initialSource: Workspace.CustomTitleSource) throws {
        let workspace = Workspace()
        let panelId = try #require(workspace.focusedPanelId)
        let tabId = try #require(workspace.surfaceIdFromPanelId(panelId))

        #expect(workspace.updatePanelTitle(panelId: panelId, title: "some-name"))
        #expect(workspace.setPanelCustomTitle(panelId: panelId, title: "Cloud lane", source: initialSource))
        workspace.setAgentLifecycle(key: "codex", panelId: panelId, lifecycle: .running)

        #expect(workspace.setPanelCustomTitle(panelId: panelId, title: "Cloud lane", source: .remote))
        #expect(workspace.panelCustomTitleSources[panelId] == .remote)
        #expect(workspace.bonsplitController.tab(tabId)?.title == "Cloud lane")
        #expect(workspace.bonsplitController.tab(tabId)?.isLoading == true)

        workspace.setAgentLifecycle(key: "codex", panelId: panelId, lifecycle: .running)
        #expect(workspace.bonsplitController.tab(tabId)?.title == "Cloud lane")
        #expect(workspace.bonsplitController.tab(tabId)?.isLoading == true)

        workspace.setAgentLifecycle(key: "codex", panelId: panelId, lifecycle: .idle)
        #expect(workspace.bonsplitController.tab(tabId)?.title == "Cloud lane")
        #expect(workspace.bonsplitController.tab(tabId)?.isLoading == false)
        #expect(workspace.panelTitles[panelId] == "some-name")

        #expect(workspace.updatePanelTitle(panelId: panelId, title: "renamed-thread"))
        #expect(workspace.bonsplitController.tab(tabId)?.title == "Cloud lane")
        #expect(workspace.setPanelCustomTitle(panelId: panelId, title: nil, source: .remote))
        #expect(workspace.bonsplitController.tab(tabId)?.title == "✳ renamed-thread")
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

        workspace.setAgentLifecycle(key: "codex", panelId: panelId, lifecycle: .idle)
        #expect(workspace.bonsplitController.tab(tabId)?.title == "✳ Generated lane")
        #expect(workspace.bonsplitController.tab(tabId)?.isLoading == false)
    }

    @Test("same-text auto-to-user ownership removes the marker but keeps activity")
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
        #expect(tab.isLoading)
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
