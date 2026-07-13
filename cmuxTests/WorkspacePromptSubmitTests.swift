import Foundation
import Testing
import CMUXAgentLaunch

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite(.serialized)
struct WorkspacePromptSubmitTests {
    @Test func testPromptSubmitRecordsMessageAndMovesWorkspaceToTopWhenIMessageModeEnabled() throws {
        let manager = TabManager()
        let first = manager.tabs[0]
        let second = manager.addWorkspace(select: false, placementOverride: .end)
        let third = manager.addWorkspace(select: false, placementOverride: .end)
        manager.selectWorkspace(second)

        let outcome = try #require(
            manager.handlePromptSubmit(
                workspaceId: third.id,
                message: "  implement this\n\nnow  ",
                iMessageModeEnabled: true
            )
        )

        #expect(outcome.messageRecorded)
        #expect(outcome.reordered)
        #expect(outcome.index == 0)
        #expect(manager.tabs.map(\.id) == [third.id, first.id, second.id])
        #expect(manager.selectedTabId == second.id)
        #expect(third.latestConversationMessage == "implement this now")
        #expect(third.latestSubmittedAt != nil)
    }

    @Test func testPromptSubmitReorderPublishesWorkspaceOrderEvent() throws {
        CmuxEventBus.shared.resetForTesting()
        defer { CmuxEventBus.shared.resetForTesting() }

        let manager = TabManager()
        let first = manager.tabs[0]
        let second = manager.addWorkspace(select: false, placementOverride: .end)
        let third = manager.addWorkspace(select: false, placementOverride: .end)
        CmuxEventBus.shared.resetForTesting()

        let outcome = try #require(
            manager.handlePromptSubmit(
                workspaceId: third.id,
                message: "ship it",
                iMessageModeEnabled: true
            )
        )

        #expect(outcome.reordered)
        let events = CmuxEventBus.shared.retainedSnapshot()
        #expect(events.compactMap { $0["name"] as? String } == ["workspace.prompt.submitted", "workspace.reordered"])
        let reorder = try #require(events.last)
        #expect(reorder["workspace_id"] as? String == third.id.uuidString)
        let payload = try #require(reorder["payload"] as? [String: Any])
        #expect(payload["workspace_ids"] as? [String] == [third.id.uuidString, first.id.uuidString, second.id.uuidString])
        #expect(payload["moved_workspace_ids"] as? [String] == [third.id.uuidString])
    }

    @Test func testPromptSubmitRecordsMessageWithoutReorderingWhenIMessageModeDisabled() throws {
        let manager = TabManager()
        let first = manager.tabs[0]
        let second = manager.addWorkspace(select: false, placementOverride: .end)
        let third = manager.addWorkspace(select: false, placementOverride: .end)

        let outcome = try #require(
            manager.handlePromptSubmit(
                workspaceId: third.id,
                message: "do not show",
                iMessageModeEnabled: false
            )
        )

        #expect(outcome.messageRecorded)
        #expect(!outcome.reordered)
        #expect(outcome.index == 2)
        #expect(manager.tabs.map(\.id) == [first.id, second.id, third.id])
        #expect(third.latestConversationMessage == "do not show")
        #expect(third.latestSubmittedAt != nil)
    }

    @Test func testAssistantFinalMessageRecordsMessageAndMovesWorkspaceToTopWhenIMessageModeEnabled() throws {
        let manager = TabManager()
        let pinned = manager.tabs[0]
        manager.setPinned(pinned, pinned: true)
        let second = manager.addWorkspace(select: false, placementOverride: .end)
        let third = manager.addWorkspace(select: false, placementOverride: .end)
        manager.selectWorkspace(second)

        let outcome = try #require(
            manager.handleAssistantFinalMessage(
                workspaceId: third.id,
                message: "  final\n\nresponse  ",
                iMessageModeEnabled: true
            )
        )

        #expect(outcome.messageRecorded)
        #expect(outcome.reordered)
        #expect(outcome.index == 1)
        #expect(manager.tabs.map(\.id) == [pinned.id, third.id, second.id])
        #expect(manager.selectedTabId == second.id)
        #expect(third.latestConversationMessage == "final response")
    }

    @Test func testAssistantFinalMessageMovesWorkspaceWhenPreviewMatchesExistingMessage() throws {
        let manager = TabManager()
        let pinned = manager.tabs[0]
        manager.setPinned(pinned, pinned: true)
        let second = manager.addWorkspace(select: false, placementOverride: .end)
        let third = manager.addWorkspace(select: false, placementOverride: .end)
        #expect(third.recordConversationMessage("Done."))

        let outcome = try #require(
            manager.handleAssistantFinalMessage(
                workspaceId: third.id,
                message: "Done.",
                iMessageModeEnabled: true
            )
        )

        #expect(!outcome.messageRecorded)
        #expect(outcome.reordered)
        #expect(outcome.index == 1)
        #expect(manager.tabs.map(\.id) == [pinned.id, third.id, second.id])
        #expect(third.latestConversationMessage == "Done.")
    }

    @Test func testBlankAssistantFinalMessageDoesNotMoveWorkspace() throws {
        let manager = TabManager()
        let first = manager.tabs[0]
        let second = manager.addWorkspace(select: false, placementOverride: .end)

        let outcome = try #require(
            manager.handleAssistantFinalMessage(
                workspaceId: second.id,
                message: " \n ",
                iMessageModeEnabled: true
            )
        )

        #expect(!outcome.messageRecorded)
        #expect(!outcome.reordered)
        #expect(outcome.index == 1)
        #expect(manager.tabs.map(\.id) == [first.id, second.id])
        #expect(second.latestConversationMessage == nil)
    }

    @Test func testBlankPromptSubmitDoesNotRecordTimestampOrPublishEvent() throws {
        let manager = TabManager()
        let second = manager.addWorkspace(select: false, placementOverride: .end)
        let sequenceBeforeSubmit = CmuxEventBus.shared.latestSequence

        let outcome = try #require(
            manager.handlePromptSubmit(
                workspaceId: second.id,
                message: " \n ",
                iMessageModeEnabled: false
            )
        )

        #expect(!outcome.messageRecorded)
        #expect(!outcome.reordered)
        #expect(second.latestConversationMessage == nil)
        #expect(second.latestSubmittedAt == nil)
        #expect(CmuxEventBus.shared.latestSequence == sequenceBeforeSubmit)
    }

    @Test func testFeedPromptSubmitEventExtractsToolInputMessage() throws {
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

        let outcome = try #require(
            manager.handlePromptSubmit(
                workspaceId: second.id,
                message: event.submittedPromptMessage,
                iMessageModeEnabled: true
            )
        )

        #expect(outcome.messageRecorded)
        #expect(outcome.reordered)
        #expect(manager.tabs.map(\.id) == [second.id, first.id])
        #expect(second.latestConversationMessage == "shipped from feed path")
    }

    @Test func testFeedPromptSubmitEventFallsBackToContextMessage() {
        let event = WorkstreamEvent(
            sessionId: "agent-session",
            hookEventName: .userPromptSubmit,
            source: "codex",
            workspaceId: UUID().uuidString,
            context: WorkstreamContext(lastUserMessage: "from context")
        )

        #expect(event.submittedPromptMessage == "from context")
    }

    @Test func testFeedPromptSubmitSkipsBlankContextBeforeExtraFields() {
        let event = WorkstreamEvent(
            sessionId: "agent-session",
            hookEventName: .userPromptSubmit,
            source: "codex",
            workspaceId: UUID().uuidString,
            context: WorkstreamContext(lastUserMessage: " \n "),
            extraFieldsJSON: #"{"message":"from extra fields"}"#
        )

        #expect(event.submittedPromptMessage == "from extra fields")
    }

    @Test func testFeedStopEventExtractsAssistantFinalMessageFromContext() {
        let event = WorkstreamEvent(
            sessionId: "agent-session",
            hookEventName: .stop,
            source: "codex",
            workspaceId: UUID().uuidString,
            context: WorkstreamContext(assistantPreamble: "  finished\n\nthis  ")
        )

        #expect(event.assistantFinalMessage == "finished this")
    }

    @Test func testFeedStopEventExtractsAssistantFinalMessageFromExtraFields() {
        let event = WorkstreamEvent(
            sessionId: "agent-session",
            hookEventName: .stop,
            source: "codex",
            workspaceId: UUID().uuidString,
            extraFieldsJSON: #"{"last_assistant_message":"  done\nfrom extra fields  "}"#
        )

        #expect(event.assistantFinalMessage == "done from extra fields")
    }

    @Test func testFeedSubagentStopDoesNotExtractParentAssistantFinalMessage() {
        let event = WorkstreamEvent(
            sessionId: "agent-session",
            hookEventName: .subagentStop,
            source: "codex",
            workspaceId: UUID().uuidString,
            context: WorkstreamContext(assistantPreamble: "subagent finished")
        )

        #expect(event.assistantFinalMessage == nil)
    }

    @Test func testBlankSubmittedMessageDoesNotClearRecordedPreview() {
        let workspace = Workspace()

        #expect(workspace.recordSubmittedMessage("keep this preview"))
        #expect(!workspace.recordSubmittedMessage(" \n "))
        #expect(workspace.latestConversationMessage == "keep this preview")
        #expect(workspace.latestSubmittedAt != nil)
    }

    @Test func testIMessageModeUsesManagedSettingsKey() throws {
        let suiteName = "cmux.iMessageMode.test.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        #expect(IMessageModeSettings.key == "app.iMessageMode")
        #expect(!IMessageModeSettings.isEnabled(defaults: defaults))
        defaults.set(true, forKey: IMessageModeSettings.key)
        #expect(IMessageModeSettings.isEnabled(defaults: defaults))
    }
}
