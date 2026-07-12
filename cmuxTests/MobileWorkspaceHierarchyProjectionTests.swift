import AppKit
import Combine
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite(.serialized)
struct MobileWorkspaceHierarchyProjectionTests {
    @Test func closeConfirmationFallbackIsLazyForKnownShellActivity() throws {
        let manager = TabManager()
        let workspace = try #require(manager.selectedWorkspace)
        let panelID = try #require(workspace.focusedPanelId)
        var evaluations = 0
        let fallback = {
            evaluations += 1
            return false
        }

        workspace.updatePanelShellActivityState(panelId: panelID, state: .promptIdle)
        let promptIdleNeedsConfirmation = workspace.panelNeedsConfirmClose(
            panelId: panelID,
            fallbackNeedsConfirmClose: fallback
        )
        #expect(!promptIdleNeedsConfirmation)
        workspace.updatePanelShellActivityState(panelId: panelID, state: .commandRunning)
        let commandRunningNeedsConfirmation = workspace.panelNeedsConfirmClose(
            panelId: panelID,
            fallbackNeedsConfirmClose: fallback
        )
        #expect(commandRunningNeedsConfirmation)
        #expect(evaluations == 0)

        workspace.updatePanelShellActivityState(panelId: panelID, state: .unknown)
        let unknownNeedsConfirmation = workspace.panelNeedsConfirmClose(
            panelId: panelID,
            fallbackNeedsConfirmClose: fallback
        )
        #expect(!unknownNeedsConfirmation)
        #expect(evaluations == 1)
    }

    @Test func observerDigestIgnoresUnpublishedCloseConfirmationFallback() {
        let workspaceID = UUID()
        let terminalID = UUID()
        func digest(requiresCloseConfirmation: Bool) -> Int {
            let list = MobileWorkspaceHierarchyProjection.ListValue(
                schemaVersion: MobileWorkspaceHierarchyProjection.schemaVersion,
                id: workspaceID,
                title: "Workspace",
                isPinned: false,
                groupID: nil,
                previewSignature: nil,
                orderedPanelIDs: [terminalID],
                pinnedPanelIDs: [],
                panes: [],
                terminals: [.init(
                    id: terminalID,
                    title: "Terminal",
                    currentDirectory: nil,
                    paneID: nil,
                    canClose: true,
                    requiresCloseConfirmation: requiresCloseConfirmation,
                    isReady: true
                )],
                surfaces: [],
                currentDirectory: nil,
                panelDirectories: []
            )
            var hasher = Hasher()
            list.hashObserverIdentity(into: &hasher)
            return hasher.finalize()
        }

        #expect(digest(requiresCloseConfirmation: false) == digest(requiresCloseConfirmation: true))
    }

    @Test func observerDigestSkipsUnknownActivityFallbackWhilePayloadSamplesIt() throws {
        let manager = TabManager()
        let workspace = try #require(manager.selectedWorkspace)
        let terminalID = try #require(workspace.focusedPanelId)
        workspace.updatePanelShellActivityState(panelId: terminalID, state: .unknown)

        var digestFallbackEvaluations = 0
        let digestWithoutConfirmation = MobileWorkspaceListProjection.digest(
            tabs: [workspace],
            groups: [],
            selectedTabID: workspace.id,
            previewSignatures: [:],
            fallbackNeedsConfirmClose: { _, sampledID in
                #expect(sampledID == terminalID)
                digestFallbackEvaluations += 1
                return false
            }
        )
        let digestWithConfirmation = MobileWorkspaceListProjection.digest(
            tabs: [workspace],
            groups: [],
            selectedTabID: workspace.id,
            previewSignatures: [:],
            fallbackNeedsConfirmClose: { _, sampledID in
                #expect(sampledID == terminalID)
                digestFallbackEvaluations += 1
                return true
            }
        )

        #expect(digestFallbackEvaluations == 0)
        #expect(digestWithoutConfirmation == digestWithConfirmation)

        var payloadFallbackEvaluations = 0
        let payload = TerminalController.shared.mobileWorkspacePayload(
            workspace: workspace,
            isSelected: true,
            requestedTerminalID: nil,
            fallbackNeedsConfirmClose: { sampledID in
                #expect(sampledID == terminalID)
                payloadFallbackEvaluations += 1
                return true
            }
        )
        let terminals = try #require(payload["terminals"] as? [[String: Any]])
        let terminal = try #require(terminals.first)
        #expect(payloadFallbackEvaluations == 1)
        #expect(terminal["requires_close_confirmation"] as? Bool == true)
    }

    @Test func directTerminalFocusSampleMatchesFullProjection() throws {
        let manager = TabManager()
        let workspace = try #require(manager.selectedWorkspace)

        let directFocus = MobileWorkspaceHierarchyProjection.FocusValue(workspace: workspace)
        let fullFocus = MobileWorkspaceHierarchyProjection(workspace: workspace).focus

        #expect(directFocus == fullFocus)
        #expect(directFocus.selectedTerminalID == workspace.focusedTerminalPanel?.id)
    }

    @Test func pinningTerminalInStableOrderChangesProjectionAndCloseability() throws {
        let manager = TabManager()
        let workspace = try #require(manager.selectedWorkspace)
        let terminalID = try #require(workspace.focusedPanelId)
        _ = try #require(workspace.newTerminalSurfaceInFocusedPane(focus: false))
        let orderBefore = workspace.orderedPanelIds
        let hashBefore = MobileWorkspaceListObserver.summaryHash(
            for: [workspace], groups: [],
            selectedTabID: workspace.id, previewSignatures: [:]
        )
        let projectionBefore = MobileWorkspaceListProjection(
            tabs: [workspace], groups: [],
            selectedTabID: workspace.id, previewSignatures: [:]
        )
        let payloadBefore = TerminalController.shared.mobileWorkspacePayload(
            workspace: workspace,
            isSelected: true,
            requestedTerminalID: terminalID
        )
        let terminalBefore = try #require((payloadBefore["terminals"] as? [[String: Any]])?.first)
        #expect(terminalBefore["can_close"] as? Bool == true)

        var publisherWakeups = 0
        let cancellable = workspace.$pinnedPanelIds.dropFirst().sink { _ in
            publisherWakeups += 1
        }
        workspace.setPanelPinned(panelId: terminalID, pinned: true)
        withExtendedLifetime(cancellable) {}

        #expect(workspace.orderedPanelIds == orderBefore, "pinning the first tab must preserve its order")
        #expect(publisherWakeups == 1, "the pinned-panel source must wake its observer")
        let hashAfter = MobileWorkspaceListObserver.summaryHash(
            for: [workspace], groups: [],
            selectedTabID: workspace.id, previewSignatures: [:]
        )
        let projectionAfter = MobileWorkspaceListProjection(
            tabs: [workspace], groups: [],
            selectedTabID: workspace.id, previewSignatures: [:]
        )
        #expect(projectionAfter != projectionBefore)
        #expect(projectionAfter.schemaVersion == MobileWorkspaceHierarchyProjection.schemaVersion)
        #expect(hashAfter != hashBefore, "pinning changes terminal closeability and must change the projection")
        let payloadAfter = TerminalController.shared.mobileWorkspacePayload(
            workspace: workspace,
            isSelected: true,
            requestedTerminalID: terminalID
        )
        let terminalAfter = try #require((payloadAfter["terminals"] as? [[String: Any]])?.first)
        #expect(terminalAfter["can_close"] as? Bool == false)
    }

    @Test func browserSelectionHasNoProjectedTerminalAndChangesScopedFocusSignature() throws {
        let manager = TabManager()
        let workspace = try #require(manager.selectedWorkspace)
        let paneID = try #require(workspace.bonsplitController.focusedPaneId)
        let terminalID = try #require(workspace.focusedTerminalPanel?.id)
        let terminalSignature = MobileWorkspaceListObserver.focusedHierarchySignature(for: workspace)
        let browser = try #require(workspace.newBrowserSurface(
            inPane: paneID,
            focus: true,
            creationPolicy: .restoration
        ))

        #expect(workspace.focusedPanelId == browser.id)
        #expect(workspace.focusedTerminalPanel == nil)
        let browserProjection = MobileWorkspaceHierarchyProjection(workspace: workspace)
        let directBrowserFocus = MobileWorkspaceHierarchyProjection.FocusValue(workspace: workspace)
        #expect(directBrowserFocus == browserProjection.focus)
        #expect(directBrowserFocus.selectedTerminalID == nil)
        #expect(browserProjection.focus.selectedTerminalID == nil)
        #expect(directBrowserFocus.eventPayload["selected_terminal_id"] is NSNull)
        let browserSignature = MobileWorkspaceListObserver.focusedHierarchySignature(for: workspace)
        #expect(browserSignature != terminalSignature, "browser selection must change the scoped focus value")

        let payload = TerminalController.shared.mobileWorkspacePayload(
            workspace: workspace,
            isSelected: true,
            requestedTerminalID: nil
        )
        #expect(payload["selected_terminal_id"] is NSNull)
        let terminals = try #require(payload["terminals"] as? [[String: Any]])
        let terminal = try #require(terminals.first(where: { $0["id"] as? String == terminalID.uuidString }))
        #expect(terminal["is_focused"] as? Bool == false)
    }
}
