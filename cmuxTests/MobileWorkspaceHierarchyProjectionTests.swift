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
        #expect(browserProjection.focus.selectedTerminalID == nil)
        #expect(browserProjection.focus.eventPayload["selected_terminal_id"] is NSNull)
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
