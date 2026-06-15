import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
private func withHiddenWebViewDiscardPolicyEnabled(_ body: () throws -> Void) rethrows {
    let defaults = UserDefaults.standard
    let previousEnabled = defaults.object(forKey: BrowserHiddenWebViewDiscardPolicy.enabledKey)
    defaults.set(true, forKey: BrowserHiddenWebViewDiscardPolicy.enabledKey)
    defer {
        if let previousEnabled {
            defaults.set(previousEnabled, forKey: BrowserHiddenWebViewDiscardPolicy.enabledKey)
        } else {
            defaults.removeObject(forKey: BrowserHiddenWebViewDiscardPolicy.enabledKey)
        }
    }
    try body()
}

@MainActor
@Suite(.serialized)
struct BrowserWorkspaceVisibleDiscardTests {
    @Test func workspaceVisibleBrowserPanelBlocksHiddenWebViewDiscard() throws {
        try withHiddenWebViewDiscardPolicyEnabled {
            let workspace = Workspace()
            let paneId = try #require(workspace.bonsplitController.focusedPaneId)
            let panel = try #require(
                workspace.newBrowserSurface(
                    inPane: paneId,
                    url: URL(string: "about:blank"),
                    focus: true
                )
            )

            panel.noteWebViewVisibility(
                false,
                reason: "test.transientSwiftUIHide",
                now: Date(timeIntervalSinceNow: -7200)
            )
            workspace.setWorkspacePresentationVisible(true)

            let lifecyclePayload = panel.webViewLifecycleTopPayload()
            let blockers = try #require(lifecyclePayload["discard_blockers"] as? [String])
            #expect(blockers.contains("workspace_visible"))
            #expect(!panel.discardHiddenWebViewForMemory(reason: "test.discard"))

            workspace.setPortalRenderingEnabled(false, reason: "test.workspaceRetire")

            let retiredLifecyclePayload = panel.webViewLifecycleTopPayload()
            let retiredBlockers = try #require(retiredLifecyclePayload["discard_blockers"] as? [String])
            #expect(!retiredBlockers.contains("workspace_visible"))
        }
    }

    @Test func clearingWorkspaceVisibleProtectionRestartsHiddenDiscardClock() throws {
        try withHiddenWebViewDiscardPolicyEnabled {
            let workspace = Workspace()
            let paneId = try #require(workspace.bonsplitController.focusedPaneId)
            let panel = try #require(
                workspace.newBrowserSurface(
                    inPane: paneId,
                    url: URL(string: "about:blank"),
                    focus: true
                )
            )
            let staleHiddenAt = Date(timeIntervalSince1970: 1_000)
            let handoffAt = Date(timeIntervalSince1970: 10_000)

            panel.noteWebViewVisibility(
                false,
                reason: "test.transientSwiftUIHide",
                now: staleHiddenAt
            )
            _ = panel.setWorkspaceVisibilityProtectsHiddenWebViewDiscard(
                true,
                reason: "test.visible",
                now: staleHiddenAt
            )

            _ = panel.setWorkspaceVisibilityProtectsHiddenWebViewDiscard(
                false,
                reason: "test.realHide",
                now: handoffAt
            )

            #expect(panel.hiddenWebViewDiscardHiddenAt == handoffAt)
        }
    }

    @Test func canvasInlineBrowserPanelDoesNotGetWorkspaceVisibleDiscardBlocker() throws {
        try withHiddenWebViewDiscardPolicyEnabled {
            let workspace = Workspace()
            let paneId = try #require(workspace.bonsplitController.focusedPaneId)
            let panel = try #require(
                workspace.newBrowserSurface(
                    inPane: paneId,
                    url: URL(string: "about:blank"),
                    focus: true
                )
            )

            workspace.setWorkspacePresentationVisible(true)
            let visibleLifecyclePayload = panel.webViewLifecycleTopPayload()
            let visibleBlockers = try #require(visibleLifecyclePayload["discard_blockers"] as? [String])
            #expect(visibleBlockers.contains("workspace_visible"))

            panel.canvasInlineHostingActive = true
            panel.noteWebViewVisibility(
                false,
                reason: "test.canvasOcclude",
                now: Date(timeIntervalSinceNow: -7200)
            )
            _ = workspace.reconcileBrowserPortalVisibilityForCurrentRenderedLayout(reason: "test.reconcile")

            let lifecyclePayload = panel.webViewLifecycleTopPayload()
            let blockers = try #require(lifecyclePayload["discard_blockers"] as? [String])
            #expect(!blockers.contains("workspace_visible"))
        }
    }

    @Test func hiddenMountedWorkspaceDoesNotGetWorkspaceVisibleDiscardBlocker() throws {
        try withHiddenWebViewDiscardPolicyEnabled {
            let workspace = Workspace()
            let paneId = try #require(workspace.bonsplitController.focusedPaneId)
            let panel = try #require(
                workspace.newBrowserSurface(
                    inPane: paneId,
                    url: URL(string: "about:blank"),
                    focus: true
                )
            )

            panel.noteWebViewVisibility(
                false,
                reason: "test.backgroundMount",
                now: Date(timeIntervalSinceNow: -7200)
            )
            workspace.setWorkspacePresentationVisible(false)
            _ = workspace.reconcileBrowserPortalVisibilityForCurrentRenderedLayout(reason: "test.backgroundReconcile")

            let lifecyclePayload = panel.webViewLifecycleTopPayload()
            let blockers = try #require(lifecyclePayload["discard_blockers"] as? [String])
            #expect(!blockers.contains("workspace_visible"))
            #expect(!workspace.debugBrowserPortalVisibilityNeedsFollowUpForTesting())
        }
    }
}
