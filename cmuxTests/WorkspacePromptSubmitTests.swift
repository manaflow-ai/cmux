import XCTest
import CMUXWorkstream

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
final class WorkspacePromptSubmitTests: XCTestCase {
    func testPromptSubmitRecordsMessageAndMovesWorkspaceToTopWhenIMessageModeEnabled() throws {
        let manager = TabManager()
        let first = manager.tabs[0]
        let second = manager.addWorkspace(select: false, placementOverride: .end)
        let third = manager.addWorkspace(select: false, placementOverride: .end)
        manager.selectWorkspace(second)

        let outcome = try XCTUnwrap(
            manager.handlePromptSubmit(
                workspaceId: third.id,
                message: "  implement this\n\nnow  ",
                iMessageModeEnabled: true
            )
        )

        XCTAssertTrue(outcome.messageRecorded)
        XCTAssertTrue(outcome.reordered)
        XCTAssertEqual(outcome.index, 0)
        XCTAssertEqual(manager.tabs.map(\.id), [third.id, first.id, second.id])
        XCTAssertEqual(manager.selectedTabId, second.id)
        XCTAssertEqual(third.latestConversationMessage, "implement this now")
        XCTAssertNotNil(third.latestSubmittedAt)
    }

    func testPromptSubmitReorderPublishesWorkspaceOrderEvent() throws {
        CmuxEventBus.shared.resetForTesting()
        defer { CmuxEventBus.shared.resetForTesting() }

        let manager = TabManager()
        let first = manager.tabs[0]
        let second = manager.addWorkspace(select: false, placementOverride: .end)
        let third = manager.addWorkspace(select: false, placementOverride: .end)
        CmuxEventBus.shared.resetForTesting()

        let outcome = try XCTUnwrap(
            manager.handlePromptSubmit(
                workspaceId: third.id,
                message: "ship it",
                iMessageModeEnabled: true
            )
        )

        XCTAssertTrue(outcome.reordered)
        let events = CmuxEventBus.shared.retainedSnapshot()
        XCTAssertEqual(
            events.compactMap { $0["name"] as? String },
            ["workspace.prompt.submitted", "workspace.reordered"]
        )
        let reorder = try XCTUnwrap(events.last)
        XCTAssertEqual(reorder["workspace_id"] as? String, third.id.uuidString)
        let payload = try XCTUnwrap(reorder["payload"] as? [String: Any])
        XCTAssertEqual(
            payload["workspace_ids"] as? [String],
            [third.id.uuidString, first.id.uuidString, second.id.uuidString]
        )
        XCTAssertEqual(payload["moved_workspace_ids"] as? [String], [third.id.uuidString])
    }

    func testPromptSubmitRecordsMessageWithoutReorderingWhenIMessageModeDisabled() throws {
        let manager = TabManager()
        let first = manager.tabs[0]
        let second = manager.addWorkspace(select: false, placementOverride: .end)
        let third = manager.addWorkspace(select: false, placementOverride: .end)

        let outcome = try XCTUnwrap(
            manager.handlePromptSubmit(
                workspaceId: third.id,
                message: "do not show",
                iMessageModeEnabled: false
            )
        )

        XCTAssertTrue(outcome.messageRecorded)
        XCTAssertFalse(outcome.reordered)
        XCTAssertEqual(outcome.index, 2)
        XCTAssertEqual(manager.tabs.map(\.id), [first.id, second.id, third.id])
        XCTAssertEqual(third.latestConversationMessage, "do not show")
        XCTAssertNotNil(third.latestSubmittedAt)
    }

    func testAssistantFinalMessageRecordsMessageAndMovesWorkspaceToTopWhenIMessageModeEnabled() throws {
        let manager = TabManager()
        let pinned = manager.tabs[0]
        manager.setPinned(pinned, pinned: true)
        let second = manager.addWorkspace(select: false, placementOverride: .end)
        let third = manager.addWorkspace(select: false, placementOverride: .end)
        manager.selectWorkspace(second)

        let outcome = try XCTUnwrap(
            manager.handleAssistantFinalMessage(
                workspaceId: third.id,
                message: "  final\n\nresponse  ",
                iMessageModeEnabled: true
            )
        )

        XCTAssertTrue(outcome.messageRecorded)
        XCTAssertTrue(outcome.reordered)
        XCTAssertEqual(outcome.index, 1)
        XCTAssertEqual(manager.tabs.map(\.id), [pinned.id, third.id, second.id])
        XCTAssertEqual(manager.selectedTabId, second.id)
        XCTAssertEqual(third.latestConversationMessage, "final response")
    }

    func testAssistantFinalMessageMovesWorkspaceWhenPreviewMatchesExistingMessage() throws {
        let manager = TabManager()
        let pinned = manager.tabs[0]
        manager.setPinned(pinned, pinned: true)
        let second = manager.addWorkspace(select: false, placementOverride: .end)
        let third = manager.addWorkspace(select: false, placementOverride: .end)
        XCTAssertTrue(third.recordConversationMessage("Done."))

        let outcome = try XCTUnwrap(
            manager.handleAssistantFinalMessage(
                workspaceId: third.id,
                message: "Done.",
                iMessageModeEnabled: true
            )
        )

        XCTAssertFalse(outcome.messageRecorded)
        XCTAssertTrue(outcome.reordered)
        XCTAssertEqual(outcome.index, 1)
        XCTAssertEqual(manager.tabs.map(\.id), [pinned.id, third.id, second.id])
        XCTAssertEqual(third.latestConversationMessage, "Done.")
    }

    func testBlankAssistantFinalMessageDoesNotMoveWorkspace() throws {
        let manager = TabManager()
        let first = manager.tabs[0]
        let second = manager.addWorkspace(select: false, placementOverride: .end)

        let outcome = try XCTUnwrap(
            manager.handleAssistantFinalMessage(
                workspaceId: second.id,
                message: " \n ",
                iMessageModeEnabled: true
            )
        )

        XCTAssertFalse(outcome.messageRecorded)
        XCTAssertFalse(outcome.reordered)
        XCTAssertEqual(outcome.index, 1)
        XCTAssertEqual(manager.tabs.map(\.id), [first.id, second.id])
        XCTAssertNil(second.latestConversationMessage)
    }

    func testBlankPromptSubmitDoesNotRecordTimestampOrPublishEvent() throws {
        let manager = TabManager()
        let second = manager.addWorkspace(select: false, placementOverride: .end)
        let sequenceBeforeSubmit = CmuxEventBus.shared.latestSequence

        let outcome = try XCTUnwrap(
            manager.handlePromptSubmit(
                workspaceId: second.id,
                message: " \n ",
                iMessageModeEnabled: false
            )
        )

        XCTAssertFalse(outcome.messageRecorded)
        XCTAssertFalse(outcome.reordered)
        XCTAssertNil(second.latestConversationMessage)
        XCTAssertNil(second.latestSubmittedAt)
        XCTAssertEqual(CmuxEventBus.shared.latestSequence, sequenceBeforeSubmit)
    }

    func testPromptSubmitOpenAnchorIsAppliedToNextSurfaceNotification() throws {
        let store = TerminalNotificationStore.shared
        store.replaceNotificationsForTesting([])
        store.configureNotificationDeliveryHandlerForTesting { _, _, _ in }
        store.configureSuppressedNotificationFeedbackHandlerForTesting { _, _, _ in }
        defer {
            store.replaceNotificationsForTesting([])
            store.resetNotificationDeliveryHandlerForTesting()
            store.resetSuppressedNotificationFeedbackHandlerForTesting()
        }

        let workspaceId = UUID()
        let surfaceId = UUID()
        let anchor = TerminalNotificationOpenAnchor(scrollbarOffset: 42)
        store.recordPromptSubmitOpenAnchor(anchor, forTabId: workspaceId, surfaceId: surfaceId)

        store.addNotification(
            tabId: workspaceId,
            surfaceId: surfaceId,
            title: "Agent finished",
            subtitle: "codex",
            body: "Done"
        )

        let notification = try XCTUnwrap(store.notifications.first)
        XCTAssertEqual(notification.openAnchor, anchor)
    }

    /// Verifies delivered system notifications carry anchors even when store recording is disabled.
    func testNotificationUserInfoPreservesOpenAnchorForUnrecordedDesktopDelivery() throws {
        let workspaceId = UUID()
        let surfaceId = UUID()
        let anchor = TerminalNotificationOpenAnchor(scrollbarOffset: 128)
        let notification = TerminalNotification(
            id: UUID(),
            tabId: workspaceId,
            surfaceId: surfaceId,
            title: "Agent finished",
            subtitle: "codex",
            body: "Done",
            createdAt: Date(),
            isRead: false,
            openAnchor: anchor
        )

        let userInfo = TerminalNotificationStore.userInfo(for: notification)

        XCTAssertEqual(userInfo["tabId"] as? String, workspaceId.uuidString)
        XCTAssertEqual(userInfo["surfaceId"] as? String, surfaceId.uuidString)
        XCTAssertEqual(userInfo["notificationId"] as? String, notification.id.uuidString)
        XCTAssertEqual(TerminalNotificationOpenAnchor(userInfo: userInfo), anchor)
    }

    /// Verifies workspace notification clearing also removes prompt-submit anchors.
    func testClearNotificationsForTabIdRemovesPromptSubmitOpenAnchorsWithoutNotifications() {
        let store = TerminalNotificationStore.shared
        store.replaceNotificationsForTesting([])
        defer { store.replaceNotificationsForTesting([]) }

        let workspaceId = UUID()
        let surfaceId = UUID()
        let otherWorkspaceId = UUID()
        store.recordPromptSubmitOpenAnchor(
            TerminalNotificationOpenAnchor(scrollbarOffset: 42),
            forTabId: workspaceId,
            surfaceId: surfaceId
        )
        store.recordPromptSubmitOpenAnchor(
            TerminalNotificationOpenAnchor(scrollbarOffset: 64),
            forTabId: workspaceId,
            surfaceId: nil
        )
        store.recordPromptSubmitOpenAnchor(
            TerminalNotificationOpenAnchor(scrollbarOffset: 99),
            forTabId: otherWorkspaceId,
            surfaceId: nil
        )

        store.clearNotifications(forTabId: workspaceId, discardQueuedNotifications: false)

        XCTAssertNil(store.promptSubmitOpenAnchor(forTabId: workspaceId, surfaceId: surfaceId))
        XCTAssertNil(store.promptSubmitOpenAnchor(forTabId: workspaceId, surfaceId: nil))
        XCTAssertEqual(
            store.promptSubmitOpenAnchor(forTabId: otherWorkspaceId, surfaceId: nil)?.scrollbarOffset,
            99
        )
    }

    /// Verifies global notification clearing also removes prompt-submit anchors.
    func testClearAllRemovesPromptSubmitOpenAnchorsWithoutNotifications() {
        let store = TerminalNotificationStore.shared
        store.replaceNotificationsForTesting([])
        defer { store.replaceNotificationsForTesting([]) }

        let workspaceId = UUID()
        let surfaceId = UUID()
        store.recordPromptSubmitOpenAnchor(
            TerminalNotificationOpenAnchor(scrollbarOffset: 42),
            forTabId: workspaceId,
            surfaceId: surfaceId
        )

        store.clearAll(discardQueuedNotifications: false)

        XCTAssertNil(store.promptSubmitOpenAnchor(forTabId: workspaceId, surfaceId: surfaceId))
    }

    /// Verifies surface notification clearing removes only the matching prompt-submit anchor.
    func testClearNotificationsForSurfaceRemovesOnlyMatchingPromptSubmitOpenAnchor() {
        let store = TerminalNotificationStore.shared
        store.replaceNotificationsForTesting([])
        defer { store.replaceNotificationsForTesting([]) }

        let workspaceId = UUID()
        let firstSurfaceId = UUID()
        let secondSurfaceId = UUID()
        store.recordPromptSubmitOpenAnchor(
            TerminalNotificationOpenAnchor(scrollbarOffset: 42),
            forTabId: workspaceId,
            surfaceId: firstSurfaceId
        )
        store.recordPromptSubmitOpenAnchor(
            TerminalNotificationOpenAnchor(scrollbarOffset: 64),
            forTabId: workspaceId,
            surfaceId: secondSurfaceId
        )

        store.clearNotifications(
            forTabId: workspaceId,
            surfaceId: firstSurfaceId,
            discardQueuedNotifications: false
        )

        XCTAssertNil(store.promptSubmitOpenAnchor(forTabId: workspaceId, surfaceId: firstSurfaceId))
        XCTAssertEqual(
            store.promptSubmitOpenAnchor(forTabId: workspaceId, surfaceId: secondSurfaceId)?.scrollbarOffset,
            64
        )
    }

    /// Verifies session restore clears runtime anchors from the previous tab lifetime.
    func testRestoreSessionNotificationsRemovesPromptSubmitOpenAnchorsForTab() {
        let store = TerminalNotificationStore.shared
        store.replaceNotificationsForTesting([])
        defer { store.replaceNotificationsForTesting([]) }

        let workspaceId = UUID()
        let surfaceId = UUID()
        store.recordPromptSubmitOpenAnchor(
            TerminalNotificationOpenAnchor(scrollbarOffset: 42),
            forTabId: workspaceId,
            surfaceId: surfaceId
        )

        store.restoreSessionNotifications([], forTabId: workspaceId)

        XCTAssertNil(store.promptSubmitOpenAnchor(forTabId: workspaceId, surfaceId: surfaceId))
    }

    /// Verifies surface rebinds move prompt-submit anchors to the destination workspace.
    func testRebindSurfaceNotificationsMovesPromptSubmitOpenAnchor() {
        let store = TerminalNotificationStore.shared
        store.replaceNotificationsForTesting([])
        defer { store.replaceNotificationsForTesting([]) }

        let sourceWorkspaceId = UUID()
        let destinationWorkspaceId = UUID()
        let surfaceId = UUID()
        let anchor = TerminalNotificationOpenAnchor(scrollbarOffset: 42)
        store.recordPromptSubmitOpenAnchor(anchor, forTabId: sourceWorkspaceId, surfaceId: surfaceId)

        store.rebindSurfaceNotifications(
            fromTabId: sourceWorkspaceId,
            toTabId: destinationWorkspaceId,
            surfaceId: surfaceId
        )

        XCTAssertNil(store.promptSubmitOpenAnchor(forTabId: sourceWorkspaceId, surfaceId: surfaceId))
        XCTAssertEqual(
            store.promptSubmitOpenAnchor(forTabId: destinationWorkspaceId, surfaceId: surfaceId),
            anchor
        )
    }

    /// Verifies surface notification clearing removes panel, surface alias, and nil-fallback anchors.
    func testClearNotificationsForSurfaceRemovesPromptSubmitOpenAnchorAliases() {
        let store = TerminalNotificationStore.shared
        store.replaceNotificationsForTesting([])
        defer { store.replaceNotificationsForTesting([]) }

        let workspaceId = UUID()
        let panelId = UUID()
        let bonsplitSurfaceId = UUID()
        let otherSurfaceId = UUID()
        store.replaceNotificationsForTesting([
            TerminalNotification(
                id: UUID(),
                tabId: workspaceId,
                surfaceId: bonsplitSurfaceId,
                panelId: panelId,
                title: "Agent finished",
                subtitle: "codex",
                body: "Done",
                createdAt: Date(),
                isRead: false
            )
        ])
        store.recordPromptSubmitOpenAnchor(
            TerminalNotificationOpenAnchor(scrollbarOffset: 42),
            forTabId: workspaceId,
            surfaceId: panelId
        )
        store.recordPromptSubmitOpenAnchor(
            TerminalNotificationOpenAnchor(scrollbarOffset: 43),
            forTabId: workspaceId,
            surfaceId: bonsplitSurfaceId
        )
        store.recordPromptSubmitOpenAnchor(
            TerminalNotificationOpenAnchor(scrollbarOffset: 44),
            forTabId: workspaceId,
            surfaceId: nil
        )
        store.recordPromptSubmitOpenAnchor(
            TerminalNotificationOpenAnchor(scrollbarOffset: 64),
            forTabId: workspaceId,
            surfaceId: otherSurfaceId
        )

        store.clearNotifications(
            forTabId: workspaceId,
            surfaceId: panelId,
            discardQueuedNotifications: false
        )

        XCTAssertNil(store.promptSubmitOpenAnchor(forTabId: workspaceId, surfaceId: panelId))
        XCTAssertNil(store.promptSubmitOpenAnchor(forTabId: workspaceId, surfaceId: bonsplitSurfaceId))
        XCTAssertNil(store.promptSubmitOpenAnchor(forTabId: workspaceId, surfaceId: nil))
        XCTAssertEqual(
            store.promptSubmitOpenAnchor(forTabId: workspaceId, surfaceId: otherSurfaceId)?.scrollbarOffset,
            64
        )
    }

    func testFeedPromptSubmitEventExtractsToolInputMessage() throws {
        let manager = TabManager()
        let first = manager.tabs[0]
        let second = manager.addWorkspace(select: false, placementOverride: .end)

        let event = WorkstreamEvent(
            sessionId: "opencode-session",
            hookEventName: .userPromptSubmit,
            source: "opencode",
            workspaceId: second.id.uuidString,
            toolInputJSON: #"{"prompt":"  shipped from feed\npath  "}"#,
            context: WorkstreamContext(lastUserMessage: "fallback message")
        )

        let outcome = try XCTUnwrap(
            manager.handlePromptSubmit(
                workspaceId: second.id,
                message: event.submittedPromptMessage,
                iMessageModeEnabled: true
            )
        )

        XCTAssertTrue(outcome.messageRecorded)
        XCTAssertTrue(outcome.reordered)
        XCTAssertEqual(manager.tabs.map(\.id), [second.id, first.id])
        XCTAssertEqual(second.latestConversationMessage, "shipped from feed path")
    }

    func testFeedPromptSubmitEventFallsBackToContextMessage() {
        let event = WorkstreamEvent(
            sessionId: "agent-session",
            hookEventName: .userPromptSubmit,
            source: "codex",
            workspaceId: UUID().uuidString,
            context: WorkstreamContext(lastUserMessage: "from context")
        )

        XCTAssertEqual(event.submittedPromptMessage, "from context")
    }

    func testFeedPromptSubmitSkipsBlankContextBeforeExtraFields() {
        let event = WorkstreamEvent(
            sessionId: "agent-session",
            hookEventName: .userPromptSubmit,
            source: "codex",
            workspaceId: UUID().uuidString,
            context: WorkstreamContext(lastUserMessage: " \n "),
            extraFieldsJSON: #"{"message":"from extra fields"}"#
        )

        XCTAssertEqual(event.submittedPromptMessage, "from extra fields")
    }

    func testFeedStopEventExtractsAssistantFinalMessageFromContext() {
        let event = WorkstreamEvent(
            sessionId: "agent-session",
            hookEventName: .stop,
            source: "codex",
            workspaceId: UUID().uuidString,
            context: WorkstreamContext(assistantPreamble: "  finished\n\nthis  ")
        )

        XCTAssertEqual(event.assistantFinalMessage, "finished this")
    }

    func testFeedStopEventExtractsAssistantFinalMessageFromExtraFields() {
        let event = WorkstreamEvent(
            sessionId: "agent-session",
            hookEventName: .stop,
            source: "codex",
            workspaceId: UUID().uuidString,
            extraFieldsJSON: #"{"last_assistant_message":"  done\nfrom extra fields  "}"#
        )

        XCTAssertEqual(event.assistantFinalMessage, "done from extra fields")
    }

    func testBlankSubmittedMessageDoesNotClearRecordedPreview() {
        let workspace = Workspace()

        XCTAssertTrue(workspace.recordSubmittedMessage("keep this preview"))
        XCTAssertFalse(workspace.recordSubmittedMessage(" \n "))
        XCTAssertEqual(workspace.latestConversationMessage, "keep this preview")
        XCTAssertNotNil(workspace.latestSubmittedAt)
    }

    func testIMessageModeUsesManagedSettingsKey() throws {
        let suiteName = "cmux.iMessageMode.test.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertEqual(IMessageModeSettings.key, "app.iMessageMode")
        XCTAssertFalse(IMessageModeSettings.isEnabled(defaults: defaults))
        defaults.set(true, forKey: IMessageModeSettings.key)
        XCTAssertTrue(IMessageModeSettings.isEnabled(defaults: defaults))
    }
}
