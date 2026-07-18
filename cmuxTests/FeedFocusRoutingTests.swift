import AppKit
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite struct FeedFocusRoutingTests {
    private final class ScopedFeedResponder: NSView, FeedScopedKeyboardFocusResponder {
        let feedFocusScopeID: UUID

        init(scopeID: UUID) {
            self.feedFocusScopeID = scopeID
            super.init(frame: NSRect(x: 0, y: 0, width: 24, height: 24))
        }

        required init?(coder: NSCoder) {
            nil
        }

        override var acceptsFirstResponder: Bool { true }
    }

    @Test func feedPaneResponderDoesNotClaimRightSidebarFocus() {
        let controller = MainWindowFocusController(
            windowId: UUID(),
            window: nil,
            tabManager: TabManager(),
            fileExplorerState: FileExplorerState()
        )

        #expect(!controller.ownsRightSidebarFocus(ScopedFeedResponder(scopeID: UUID())))
    }

    @Test func rightSidebarFeedHostOwnsOnlyItsFocusScope() {
        let controller = MainWindowFocusController(
            windowId: UUID(),
            window: nil,
            tabManager: TabManager(),
            fileExplorerState: FileExplorerState()
        )
        let host = FeedKeyboardFocusView(frame: NSRect(x: 0, y: 0, width: 1, height: 1))
        let matchingResponder = ScopedFeedResponder(scopeID: host.feedFocusScopeID)
        let paneResponder = ScopedFeedResponder(scopeID: UUID())
        controller.registerFeedHost(host)

        #expect(controller.ownsRightSidebarFocus(matchingResponder))
        #expect(!controller.ownsRightSidebarFocus(paneResponder))
    }

    @Test func onlySidebarFeedPlacementUsesSidebarFocusCoordinator() {
        #expect(FeedPlacement.rightSidebar.usesRightSidebarFocusCoordinator)
        #expect(!FeedPlacement.pane.usesRightSidebarFocusCoordinator)
    }

    @Test func editorBlurTracksFeedFocusScope() {
        let scopeID = UUID()
        var blurCount = 0
        let field = FeedInlineTextField(
            text: .constant(""),
            focusRequest: nil,
            placeholder: "",
            isEnabled: true,
            font: .systemFont(ofSize: 12),
            placement: .pane,
            focusScopeID: scopeID,
            onFocus: {},
            onBlur: { blurCount += 1 },
            onSubmit: nil
        )
        let coordinator = FeedInlineTextFieldCoordinator(parent: field)
        let editor = FeedInlineTextEditorView(frame: NSRect(x: 0, y: 0, width: 80, height: 24))
        coordinator.view = editor
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let content = NSView(frame: window.contentView?.bounds ?? .zero)
        window.contentView = content
        content.addSubview(editor)

        let sameScope = ScopedFeedResponder(scopeID: scopeID)
        content.addSubview(sameScope)
        #expect(window.makeFirstResponder(sameScope))
        coordinator.textDidEndEditing(
            Notification(name: NSText.didEndEditingNotification, object: editor.textView)
        )
        #expect(blurCount == 0)

        let otherScope = ScopedFeedResponder(scopeID: UUID())
        content.addSubview(otherScope)
        #expect(window.makeFirstResponder(otherScope))
        coordinator.textDidEndEditing(
            Notification(name: NSText.didEndEditingNotification, object: editor.textView)
        )
        #expect(blurCount == 1)
    }

    @Test func editorMetricRefreshDefersLayout() {
        let editor = FeedInlineTextEditorView(
            frame: NSRect(x: 0, y: 0, width: 160, height: 24)
        )
        editor.layoutSubtreeIfNeeded()

        editor.refreshMetrics()

        #expect(editor.needsLayout)
    }

    @Test func feedTextRoutingReportsRejectedSurface() {
        let appDelegate = AppDelegate()

        #expect(!appDelegate.routeFeedText(surfaceId: "not-a-surface-id", text: "retry this"))
    }

    @Test func feedFocusUsesStableSurfaceWhenWorkspaceIdentityIsStale() throws {
        let appDelegate = AppDelegate()
        let manager = TabManager()
        let origin = try #require(manager.selectedWorkspace)
        let panel = try #require(origin.focusedTerminalPanel)
        let surfaceID = try #require(origin.surfaceIdFromPanelId(panel.id)?.uuid)
        let other = manager.addWorkspace()
        let windowID = appDelegate.registerMainWindowContextForTesting(tabManager: manager)
        defer { appDelegate.unregisterMainWindowContextForTesting(windowId: windowID) }
        GhosttySurfaceScrollView.resetFlashCounts()

        #expect(manager.selectedTabId == other.id)
        #expect(appDelegate.routeFeedFocus(
            workspaceId: other.id.uuidString,
            surfaceId: surfaceID.uuidString
        ))
        #expect(manager.selectedTabId == origin.id)
        #expect(origin.focusedPanelId == panel.id)
        #expect(GhosttySurfaceScrollView.flashCount(for: panel.id) == 1)
    }

    @Test func feedFocusSelectsAndFlashesTheOriginatingTerminal() throws {
        let appDelegate = AppDelegate()
        let manager = TabManager()
        let targetWorkspace = try #require(manager.selectedWorkspace)
        let targetPanel = try #require(targetWorkspace.focusedTerminalPanel)
        let targetSurfaceID = try #require(
            targetWorkspace.surfaceIdFromPanelId(targetPanel.id)?.uuid
        )
        let feedWorkspace = manager.addWorkspace()
        let windowID = appDelegate.registerMainWindowContextForTesting(tabManager: manager)
        defer { appDelegate.unregisterMainWindowContextForTesting(windowId: windowID) }
        GhosttySurfaceScrollView.resetFlashCounts()

        #expect(manager.selectedTabId == feedWorkspace.id)
        #expect(appDelegate.routeFeedFocus(
            workspaceId: targetWorkspace.id.uuidString,
            surfaceId: targetSurfaceID.uuidString
        ))
        #expect(manager.selectedTabId == targetWorkspace.id)
        #expect(targetWorkspace.focusedPanelId == targetPanel.id)
        #expect(GhosttySurfaceScrollView.flashCount(for: targetPanel.id) == 1)
    }

    @Test func feedFocusUsesLiveWorkspaceWhenPersistedWorkspaceNoLongerExists() throws {
        let appDelegate = AppDelegate()
        let manager = TabManager()
        let targetWorkspace = try #require(manager.selectedWorkspace)
        let targetPanel = try #require(targetWorkspace.focusedTerminalPanel)
        let targetSurfaceID = try #require(
            targetWorkspace.surfaceIdFromPanelId(targetPanel.id)?.uuid
        )
        let feedWorkspace = manager.addWorkspace()
        let windowID = appDelegate.registerMainWindowContextForTesting(tabManager: manager)
        defer { appDelegate.unregisterMainWindowContextForTesting(windowId: windowID) }
        GhosttySurfaceScrollView.resetFlashCounts()

        #expect(manager.selectedTabId == feedWorkspace.id)
        #expect(appDelegate.routeFeedFocus(
            workspaceId: UUID().uuidString,
            surfaceId: targetSurfaceID.uuidString
        ))
        #expect(manager.selectedTabId == targetWorkspace.id)
        #expect(targetWorkspace.focusedPanelId == targetPanel.id)
        #expect(GhosttySurfaceScrollView.flashCount(for: targetPanel.id) == 1)
    }

    @Test func feedFocusUsesLiveSurfaceOwnerWhenPersistedWorkspaceRemainsDormant() throws {
        let appDelegate = AppDelegate()
        let liveManager = TabManager()
        let targetWorkspace = try #require(liveManager.selectedWorkspace)
        let targetPanel = try #require(targetWorkspace.focusedTerminalPanel)
        let targetSurfaceID = try #require(
            targetWorkspace.surfaceIdFromPanelId(targetPanel.id)?.uuid
        )
        let feedWorkspace = liveManager.addWorkspace()
        let dormantManager = TabManager()
        let persistedWorkspace = try #require(dormantManager.selectedWorkspace)
        let liveWindowID = appDelegate.registerMainWindowContextForTesting(
            tabManager: liveManager
        )
        let dormantWindowID = appDelegate.registerMainWindowContextForTesting(
            tabManager: dormantManager
        )
        defer {
            appDelegate.unregisterMainWindowContextForTesting(windowId: dormantWindowID)
            appDelegate.unregisterMainWindowContextForTesting(windowId: liveWindowID)
        }
        GhosttySurfaceScrollView.resetFlashCounts()

        #expect(liveManager.selectedTabId == feedWorkspace.id)
        #expect(appDelegate.routeFeedFocus(
            workspaceId: persistedWorkspace.id.uuidString,
            surfaceId: targetSurfaceID.uuidString
        ))
        #expect(liveManager.selectedTabId == targetWorkspace.id)
        #expect(targetWorkspace.focusedPanelId == targetPanel.id)
        #expect(GhosttySurfaceScrollView.flashCount(for: targetPanel.id) == 1)
    }

    @Test func feedOnlyWorkspaceJumpKeepsLiveTerminalSelectedAfterFocusSettles() async throws {
        let appDelegate = AppDelegate()
        let manager = TabManager()
        let targetWorkspace = try #require(manager.selectedWorkspace)
        let targetPanel = try #require(targetWorkspace.focusedTerminalPanel)
        let targetSurfaceID = try #require(
            targetWorkspace.surfaceIdFromPanelId(targetPanel.id)?.uuid
        )
        let feedWorkspace = manager.addWorkspace(
            title: "Feed",
            initialSurface: .feed,
            inheritWorkingDirectory: false,
            select: true,
            autoWelcomeIfNeeded: false,
            allowTextBoxFocusDefault: false
        )
        let windowID = appDelegate.registerMainWindowContextForTesting(tabManager: manager)
        defer { appDelegate.unregisterMainWindowContextForTesting(windowId: windowID) }

        #expect(feedWorkspace.panels.values.contains {
            ($0 as? RightSidebarToolPanel)?.mode == .feed
        })
        #expect(appDelegate.routeFeedFocus(
            workspaceId: targetWorkspace.id.uuidString,
            surfaceId: targetSurfaceID.uuidString
        ))

        await Task.yield()

        #expect(manager.selectedTabId == targetWorkspace.id)
        #expect(targetWorkspace.focusedPanelId == targetPanel.id)
    }

    @Test func resolvedQuestionSelectionsRemainAvailableForPresentation() {
        let status = WorkstreamStatus.resolved(
            .question(selections: ["Answering a question"]),
            at: Date(timeIntervalSince1970: 1)
        )

        #expect(
            QuestionActionArea.resolvedSelections(in: status)
                == ["Answering a question"]
        )
    }

    @Test func stopDraftClearsOnlyAfterMatchingSuccessfulDelivery() {
        var failed = FeedStopDraft(reply: "retry this")
        failed.finishSend(submittedReply: "retry this", succeeded: false)
        #expect(failed.reply == "retry this")

        var edited = FeedStopDraft(reply: "newer text")
        edited.finishSend(submittedReply: "older text", succeeded: true)
        #expect(edited.reply == "newer text")

        var sent = FeedStopDraft(reply: "  delivered  ")
        sent.finishSend(submittedReply: "delivered", succeeded: true)
        #expect(sent.reply.isEmpty)
    }
}
