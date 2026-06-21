import XCTest
import CMUXAgentLaunch

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
