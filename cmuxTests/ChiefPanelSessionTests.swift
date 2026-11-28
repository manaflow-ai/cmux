import AppKit
import Bonsplit
import CmuxHomeCore
import CmuxWorkspaces
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Chief as a workspace pane: session round trip, canonical Home protection, and wire tokens.
@MainActor
@Suite struct ChiefPanelSessionTests {
    @Test func aHomeDragResolvesToItsConversationAndRetiresAfterDrop() throws {
        let registry = TabDragTransferRegistry()
        let conversation = ConversationID("conv_drag_test")
        let payload = ChiefPaneDragPayload(conversationID: conversation)
        let registration = try #require(payload.register(with: registry))
        let pasteboard = NSPasteboard(name: NSPasteboard.Name(
            "ChiefPanelSessionTests.\(UUID().uuidString)"
        ))
        pasteboard.clearContents()
        defer {
            registry.end(registration)
            pasteboard.clearContents()
        }
        #expect(registration.write(to: pasteboard))

        let resolver = PaneTransferSourceResolver(
            vaultSessionRegistry: { nil },
            tabTransferRegistry: { registry },
            filePreview: { _ in nil },
            surfaceResource: { _ in nil },
            surfaceIsLive: { _ in false },
            workspaceMerge: { _ in nil }
        )
        let transfer = try #require(resolver.transfer(from: pasteboard))
        #expect(resolver.source(for: transfer) == .chiefConversation(conversation))
        resolver.finish(.chiefConversation(conversation), id: transfer.tabId)
        #expect(resolver.source(for: transfer) == nil)
    }

    @Test func droppingAChiefConversationCreatesOnePaneAndReusesIt() throws {
        let workspace = Workspace()
        defer { for panel in workspace.panels.values { panel.close() } }
        let pane = try #require(workspace.bonsplitController.focusedPaneId)
        let conversation = ConversationID("conv_drop_test")
        #expect(workspace.performChiefConversationDrop(
            conversation,
            destination: .insert(targetPane: pane, targetIndex: nil)
        ))
        let first = try #require(workspace.panels.values.compactMap { $0 as? ChiefPanel }.first)
        #expect(first.conversationID == conversation)
        #expect(workspace.performChiefConversationDrop(
            conversation,
            destination: .split(targetPane: pane, orientation: .horizontal, insertFirst: false)
        ))
        #expect(workspace.panels.values.compactMap { $0 as? ChiefPanel }.count == 1)
    }

    @Test func chiefPaneRestoresItsConversation() throws {
        let workspace = Workspace()
        defer { for panel in workspace.panels.values { panel.close() } }
        let paneId = try #require(workspace.bonsplitController.focusedPaneId)
        let chief = try #require(
            workspace.newChiefSurface(inPane: paneId, conversationID: ConversationID("conv_chief_test"), focus: false)
        )

        let saved = try JSONDecoder().decode(
            SessionWorkspaceSnapshot.self,
            from: JSONEncoder().encode(workspace.sessionSnapshot(includeScrollback: false))
        )
        let restored = Workspace()
        defer { for panel in restored.panels.values { panel.close() } }
        let restoredIds = restored.restoreSessionSnapshot(saved)

        let restoredId = try #require(restoredIds[chief.id])
        let restoredPanel = try #require(restored.panels[restoredId] as? ChiefPanel)
        #expect(restoredPanel.conversationID == ConversationID("conv_chief_test"))
        #expect(!restoredPanel.isHome)
        let restoredSurfaceId = try #require(restored.surfaceIdFromPanelId(restoredId))
        #expect(restored.bonsplitController.tab(restoredSurfaceId)?.kind == SurfaceKind.chief.rawValue)
    }

    @Test func canonicalHomeIsPinnedAndRestoresAsTheWorkspaceAnchor() throws {
        let workspace = Workspace()
        defer { for panel in workspace.panels.values { panel.close() } }
        let paneId = try #require(workspace.bonsplitController.focusedPaneId)
        let home = try #require(workspace.newChiefSurface(inPane: paneId, isHome: true, focus: false))
        let tabId = try #require(workspace.surfaceIdFromPanelId(home.id))
        #expect(home.isHome)
        #expect(workspace.isChiefHome)
        #expect(workspace.bonsplitController.tab(tabId)?.isPinned == true)
        #expect(!workspace.closePanel(home.id, force: true))

        let saved = try JSONDecoder().decode(
            SessionWorkspaceSnapshot.self,
            from: JSONEncoder().encode(workspace.sessionSnapshot(includeScrollback: false))
        )
        let restored = Workspace()
        defer { for panel in restored.panels.values { panel.close() } }
        let restoredIDs = restored.restoreSessionSnapshot(saved)
        let restoredID = try #require(restoredIDs[home.id])
        let restoredHome = try #require(restored.panels[restoredID] as? ChiefPanel)
        #expect(restoredHome.isHome)
        #expect(restored.isChiefHome)
        let restoredTab = try #require(restored.surfaceIdFromPanelId(restoredID))
        #expect(restored.bonsplitController.tab(restoredTab)?.isPinned == true)
    }

    @Test func movingCanonicalHomeWithinAWorkspaceCreatesAnOrdinaryCopy() throws {
        let workspace = Workspace()
        defer { for panel in workspace.panels.values { panel.close() } }
        let paneId = try #require(workspace.bonsplitController.focusedPaneId)
        let home = try #require(workspace.newChiefSurface(inPane: paneId, isHome: true, focus: false))
        #expect(workspace.moveSurface(panelId: home.id, toPane: paneId, focus: false))
        let chiefs = workspace.panels.values.compactMap { $0 as? ChiefPanel }
        #expect(chiefs.count == 2)
        #expect(chiefs.contains { $0.isHome })
        #expect(chiefs.contains { !$0.isHome && $0.conversationID == home.conversationID })
    }

    @Test func openOrFocusReusesTheChiefPaneForTheSameConversation() throws {
        let workspace = Workspace()
        defer { for panel in workspace.panels.values { panel.close() } }
        let paneId = try #require(workspace.bonsplitController.focusedPaneId)
        let first = try #require(workspace.openOrFocusChiefSurface(inPane: paneId, focus: false))
        let second = try #require(workspace.openOrFocusChiefSurface(inPane: paneId, focus: false))
        #expect(first === second)
        let other = try #require(
            workspace.openOrFocusChiefSurface(inPane: paneId, conversationID: ConversationID("conv_other"), focus: false)
        )
        #expect(other !== first)
    }

    @Test func socketTypeTokenResolvesToChief() throws {
        #expect(TerminalController.shared.v2PanelType(rawToken: "chief") == .chief)
        #expect(TerminalController.shared.v2PanelType(rawToken: "Chief") == .chief)
        let decoded = try JSONDecoder().decode(PanelType.self, from: Data("\"CHIEF\"".utf8))
        #expect(decoded == .chief)
    }

    @Test func homeSelectionPersistsAsTabs() {
        // Builds without `.home` must still decode the snapshot.
        #expect(SessionSidebarSelection(selection: .home) == .tabs)
    }
}
