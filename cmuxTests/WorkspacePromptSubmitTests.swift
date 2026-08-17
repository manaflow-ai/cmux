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
    @Test func promptLauncherTemplateRendersConfiguredCommandVariants() {
        let config = CmuxPromptLauncherDefinition(
            command: "workspace-launch {{provider.args}} {{target.args}} {{prompt}}",
            targets: [
                CmuxPromptLauncherChoice(id: "auto", args: []),
                CmuxPromptLauncherChoice(id: "local", args: ["local"]),
                CmuxPromptLauncherChoice(id: "remote-1", args: ["remote-1"]),
            ],
            providers: [
                CmuxPromptLauncherChoice(id: "claude", args: []),
                CmuxPromptLauncherChoice(id: "cursor", args: ["cursor"]),
                CmuxPromptLauncherChoice(id: "codex", args: ["codex"]),
            ]
        )

        #expect(
            SidebarPromptLauncherTemplateRenderer.renderCommand(
                config: config,
                targetID: "auto",
                providerID: "claude",
                prompt: "Default provider"
            ) == "workspace-launch   'Default provider'"
        )
        #expect(
            SidebarPromptLauncherTemplateRenderer.renderCommand(
                config: config,
                targetID: "local",
                providerID: "cursor",
                prompt: "Use Cursor"
            ) == "workspace-launch 'cursor' 'local' 'Use Cursor'"
        )
        #expect(
            SidebarPromptLauncherTemplateRenderer.renderCommand(
                config: config,
                targetID: "remote-1",
                providerID: "codex",
                prompt: "Add Codex's mode"
            ) == "workspace-launch 'codex' 'remote-1' 'Add Codex'\\''s mode'"
        )
    }

    @Test func promptLauncherRendersConfiguredRepositoryAndFiltersTargets() {
        let config = CmuxPromptLauncherDefinition(
            command: "workspace-launch --repo {{repository.args}} {{target.args}} {{prompt}}",
            targets: [
                CmuxPromptLauncherChoice(id: "auto"),
                CmuxPromptLauncherChoice(id: "local", args: ["local"]),
                CmuxPromptLauncherChoice(id: "devbox", args: ["devbox"]),
            ],
            providers: [CmuxPromptLauncherChoice(id: "claude")],
            repositories: [
                CmuxPromptLauncherChoice(
                    id: "service",
                    args: ["projects/service"],
                    allowedTargets: ["auto", "local", "devbox"],
                    defaultTarget: "auto"
                ),
                CmuxPromptLauncherChoice(
                    id: "docs",
                    title: "Documentation",
                    args: ["projects/docs"],
                    allowedTargets: ["local", "devbox"],
                    defaultTarget: "devbox"
                ),
            ],
            defaultTarget: "auto",
            defaultRepository: "service"
        )

        #expect(config.selectedDefaultRepositoryID == "service")
        #expect(config.targets(forRepositoryID: "service").map(\.id) == ["auto", "local", "devbox"])
        #expect(config.targets(forRepositoryID: "docs").map(\.id) == ["local", "devbox"])
        #expect(config.selectedDefaultTargetID(forRepositoryID: "service") == "auto")
        #expect(config.selectedDefaultTargetID(forRepositoryID: "docs") == "devbox")
        #expect(
            SidebarPromptLauncherTemplateRenderer.renderCommand(
                config: config,
                targetID: "devbox",
                providerID: "claude",
                repositoryID: "docs",
                prompt: "Update the guide"
            ) == "workspace-launch --repo 'projects/docs' 'devbox' 'Update the guide'"
        )
    }

    @Test func promptLauncherWithoutRepositoriesKeepsExistingTemplateBehavior() {
        let config = CmuxPromptLauncherDefinition(
            command: "workspace-launch {{target.args}} {{prompt}}",
            targets: [CmuxPromptLauncherChoice(id: "auto")],
            providers: [CmuxPromptLauncherChoice(id: "claude")]
        )

        #expect(config.repositories.isEmpty)
        #expect(
            SidebarPromptLauncherTemplateRenderer.renderCommand(
                config: config,
                targetID: "auto",
                providerID: "claude",
                prompt: "Existing config"
            ) == "workspace-launch  'Existing config'"
        )
    }

    @Test func promptLauncherParsesWorkspaceMetadataLine() throws {
        let metadata = try #require(SidebarPromptLauncherTemplateRenderer.metadata(
            from: ##"CMUX_WORKSPACE_JSON:{"workspace":"workspace:3","title":"[wk3] Search","color":"#3b82f6","slot":"wk3"}"##,
            prefix: "CMUX_WORKSPACE_JSON:"
        ))

        #expect(metadata.workspace == "workspace:3")
        #expect(metadata.title == "[wk3] Search")
        #expect(metadata.color == "#3b82f6")
        #expect(metadata.slot == "wk3")
    }

    @Test func promptLauncherCloseHookUsesMetadataOrTitleSlot() {
        let config = CmuxPromptLauncherDefinition(
            command: "workspace-launch {{prompt}}",
            targets: [CmuxPromptLauncherChoice(id: "auto")],
            providers: [CmuxPromptLauncherChoice(id: "claude")],
            closeHook: "workspace-reset {{workspace.slot}}"
        )
        let workspace = Workspace(title: "[wk7] Cleanup")
        #expect(
            SidebarPromptLauncherTemplateRenderer.renderCloseHook(config: config, workspace: workspace)
                == "workspace-reset 'wk7'"
        )

        workspace.promptLauncherSlot = "wk9"
        #expect(
            SidebarPromptLauncherTemplateRenderer.renderCloseHook(config: config, workspace: workspace)
                == "workspace-reset 'wk9'"
        )
    }

    @MainActor
    @Test func promptLauncherRestartHookUsesStableWorkspaceIdentity() throws {
        let config = CmuxPromptLauncherDefinition(
            command: "workspace-launch {{prompt}}",
            targets: [CmuxPromptLauncherChoice(id: "auto")],
            providers: [CmuxPromptLauncherChoice(id: "claude")],
            restartHook: "workspace-restart --workspace {{workspace.id}}"
        )
        let workspace = Workspace()

        #expect(
            SidebarPromptLauncherTemplateRenderer.renderRestartHook(config: config, workspace: workspace)
                == "workspace-restart --workspace '\(workspace.id.uuidString)'"
        )
    }

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
