import Foundation
import Testing
import CMUXAgentLaunch
import CmuxAgentJournal

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Claude shows its own permission prompt while the `PermissionRequest` hook
/// waits for a Feed decision, and it does not stop that hook when the user
/// answers in the terminal. The Feed wait, its card, and its "Needs input"
/// sidebar overlay must end when Claude's next hook shows it moved on, not at
/// the hook's two-minute deadline while the sidebar also says "Running".
@MainActor
@Suite("Feed decisions answered in the agent's terminal", .serialized)
struct FeedDecisionAnsweredInTerminalTests {
    private static let attentionKey = FeedCoordinator.attentionStatusKey(forSource: "claude")

    @Test func claudeResumingWorkRetiresPendingPermissionAndNeedsInput() async throws {
        let scenario = try await PendingClaudePermission.start(
            sessionId: "answered-in-terminal",
            requestId: "answered-in-terminal-request"
        )
        defer { scenario.tearDown() }

        #expect(scenario.workspace.statusEntries[Self.attentionKey]?.value == FeedCoordinator.needsInputStatusValue)

        await scenario.deliverTelemetry(WorkstreamEvent(
            sessionId: scenario.sessionId,
            hookEventName: .preToolUse,
            source: "claude",
            cwd: "/tmp",
            toolName: "Read",
            toolInputJSON: #"{"file_path":"/tmp/next.txt"}"#
        ))

        #expect(
            scenario.workspace.statusEntries[Self.attentionKey] == nil,
            "Claude's next tool call shows the prompt was answered; Needs input must not stay beside Running"
        )
        #expect(scenario.workspace.agentLifecycleStatesByPanelId[scenario.panelId]?[Self.attentionKey] == nil)
        #expect(!FeedCoordinator.shared.isAwaitingDecision(requestId: scenario.requestId))
        guard case .expired = FeedCoordinator.shared.store.items.first(where: {
            $0.payload.requestID == scenario.requestId
        })?.status else {
            Issue.record("the Feed card for a prompt answered in the terminal must stop offering a decision")
            return
        }
        let hookReturned = await scenario.awaitHookResult()
        #expect(hookReturned, "the blocked hook must return once its prompt is answered")
    }

    @Test func subagentWorkDoesNotRetireTheMainAgentsPendingPermission() async throws {
        let scenario = try await PendingClaudePermission.start(
            sessionId: "background-subagent-keeps-wait",
            requestId: "background-subagent-keeps-wait-request"
        )
        defer { scenario.tearDown() }

        await scenario.deliverTelemetry(WorkstreamEvent(
            sessionId: scenario.sessionId,
            hookEventName: .preToolUse,
            source: "claude",
            cwd: "/tmp",
            toolName: "Grep",
            toolInputJSON: #"{"pattern":"needle"}"#,
            extraFieldsJSON: #"{"agent_id":"background-subagent"}"#
        ))

        #expect(scenario.workspace.statusEntries[Self.attentionKey]?.value == FeedCoordinator.needsInputStatusValue)
        #expect(FeedCoordinator.shared.isAwaitingDecision(requestId: scenario.requestId))
    }

    @Test func siblingToolCallDoesNotRetireAConcurrencySafeToolsPrompt() async throws {
        // Claude runs concurrency-safe tools side by side, so a Read outside the
        // project can wait on its prompt while a sibling Read starts.
        let scenario = try await PendingClaudePermission.start(
            sessionId: "parallel-read-keeps-wait",
            requestId: "parallel-read-keeps-wait-request",
            toolName: "Read",
            toolInputJSON: #"{"file_path":"/etc/hosts"}"#
        )
        defer { scenario.tearDown() }

        await scenario.deliverTelemetry(WorkstreamEvent(
            sessionId: scenario.sessionId,
            hookEventName: .preToolUse,
            source: "claude",
            cwd: "/tmp",
            toolName: "Read",
            toolInputJSON: #"{"file_path":"/tmp/inside.txt"}"#
        ))

        #expect(scenario.workspace.statusEntries[Self.attentionKey]?.value == FeedCoordinator.needsInputStatusValue)
        #expect(FeedCoordinator.shared.isAwaitingDecision(requestId: scenario.requestId))
    }

    @Test func lateTelemetryFromTheCallThatRaisedThePromptDoesNotRetireIt() async throws {
        let scenario = try await PendingClaudePermission.start(
            sessionId: "raising-call-keeps-wait",
            requestId: "raising-call-keeps-wait-request",
            toolInputJSON: #"{"command":"touch   /tmp/created.txt","description":"Create a file","timeout":5000}"#
        )
        defer { scenario.tearDown() }

        // Tool telemetry keeps a compacted, whitespace-collapsed copy of the input.
        await scenario.deliverTelemetry(WorkstreamEvent(
            sessionId: scenario.sessionId,
            hookEventName: .preToolUse,
            source: "claude",
            cwd: "/tmp",
            toolName: "Bash",
            toolInputJSON: #"{"command":"touch /tmp/created.txt","description":"Create a file"}"#
        ))

        #expect(FeedCoordinator.shared.isAwaitingDecision(requestId: scenario.requestId))

        // The raising call is consumed once; running the same command again is new work.
        await scenario.deliverTelemetry(WorkstreamEvent(
            sessionId: scenario.sessionId,
            hookEventName: .preToolUse,
            source: "claude",
            cwd: "/tmp",
            toolName: "Bash",
            toolInputJSON: #"{"command":"touch /tmp/created.txt","description":"Create a file"}"#
        ))

        #expect(!FeedCoordinator.shared.isAwaitingDecision(requestId: scenario.requestId))
    }

    @Test func nextEditOfTheSameFileRetiresAnAnsweredEditPrompt() async throws {
        // Edit telemetry keeps only the path, so the follow-up edit looks like the one that asked.
        let scenario = try await PendingClaudePermission.start(
            sessionId: "same-file-edit-retires",
            requestId: "same-file-edit-retires-request",
            toolName: "Edit",
            toolInputJSON: #"{"file_path":"/tmp/app.swift","old_string":"a","new_string":"b"}"#,
            raisingToolCallInputJSON: #"{"file_path":"/tmp/app.swift"}"#
        )
        defer { scenario.tearDown() }

        await scenario.deliverTelemetry(WorkstreamEvent(
            sessionId: scenario.sessionId,
            hookEventName: .preToolUse,
            source: "claude",
            cwd: "/tmp",
            toolName: "Edit",
            toolInputJSON: #"{"file_path":"/tmp/app.swift"}"#
        ))

        #expect(scenario.workspace.statusEntries[Self.attentionKey] == nil)
        #expect(!FeedCoordinator.shared.isAwaitingDecision(requestId: scenario.requestId))
    }

    @Test func serialToolCallRetiresAConcurrencySafeToolsPrompt() async throws {
        // An Edit never starts while another tool waits, so the Read prompt was answered.
        let scenario = try await PendingClaudePermission.start(
            sessionId: "edit-after-read-retires",
            requestId: "edit-after-read-retires-request",
            toolName: "Read",
            toolInputJSON: #"{"file_path":"/etc/hosts"}"#,
            raisingToolCallInputJSON: #"{"file_path":"/etc/hosts"}"#
        )
        defer { scenario.tearDown() }

        await scenario.deliverTelemetry(WorkstreamEvent(
            sessionId: scenario.sessionId,
            hookEventName: .preToolUse,
            source: "claude",
            cwd: "/tmp",
            toolName: "Edit",
            toolInputJSON: #"{"file_path":"/tmp/app.swift"}"#
        ))

        #expect(!FeedCoordinator.shared.isAwaitingDecision(requestId: scenario.requestId))
    }

    @Test func sessionEndRetiresASubagentsPrompt() async throws {
        let scenario = try await PendingClaudePermission.start(
            sessionId: "session-end-retires-subagent",
            requestId: "session-end-retires-subagent-request",
            requestExtraFieldsJSON: #"{"agent_id":"subagent-1"}"#
        )
        defer { scenario.tearDown() }

        await scenario.deliverTelemetry(WorkstreamEvent(
            sessionId: scenario.sessionId,
            hookEventName: .stop,
            source: "claude",
            cwd: "/tmp"
        ))
        #expect(
            FeedCoordinator.shared.isAwaitingDecision(requestId: scenario.requestId),
            "the main agent's turn ending does not answer a subagent's prompt"
        )

        await scenario.deliverTelemetry(WorkstreamEvent(
            sessionId: scenario.sessionId,
            hookEventName: .sessionEnd,
            source: "claude",
            cwd: "/tmp"
        ))
        #expect(!FeedCoordinator.shared.isAwaitingDecision(requestId: scenario.requestId))
    }

    @Test func subagentPromptResolutionUsesItsOwnRequestIdentity() throws {
        // Every prompt from one subagent carries the same agent_id; resolving one
        // must not mark the subagent's later prompts as already resolved.
        let event = WorkstreamEvent(
            sessionId: "subagent-identity",
            hookEventName: .permissionRequest,
            source: "claude",
            workspaceId: UUID().uuidString,
            surfaceId: UUID().uuidString,
            toolName: "Bash",
            requestId: "subagent-identity-request",
            extraFieldsJSON: #"{"agent_id":"subagent-1"}"#
        )
        let draft = try #require(AgentFeedSemanticInput(
            event: event, agentKey: "claude_code",
            requestID: "subagent-identity-request", resolvesRequest: true
        ).draft())
        #expect(draft.attention?.requestIdentity == "subagent-identity-request")
    }

    @Test func turnEndRetiresAConcurrencySafeToolsPrompt() async throws {
        let scenario = try await PendingClaudePermission.start(
            sessionId: "turn-end-retires-wait",
            requestId: "turn-end-retires-wait-request",
            toolName: "WebFetch",
            toolInputJSON: #"{"url":"https://example.com"}"#
        )
        defer { scenario.tearDown() }

        await scenario.deliverTelemetry(WorkstreamEvent(
            sessionId: scenario.sessionId,
            hookEventName: .stop,
            source: "claude",
            cwd: "/tmp"
        ))

        #expect(scenario.workspace.statusEntries[Self.attentionKey] == nil)
        #expect(!FeedCoordinator.shared.isAwaitingDecision(requestId: scenario.requestId))
    }
}

/// A Claude `PermissionRequest` parked in the blocking Feed wait with its
/// sidebar overlay surfaced on a live panel, as the socket path leaves it.
@MainActor
private final class PendingClaudePermission {
    let sessionId: String
    let requestId: String
    let tabManager: TabManager
    let workspace: Workspace
    let panelId: UUID
    private let hookReturned = DispatchSemaphore(value: 0)

    private init(sessionId: String, requestId: String, tabManager: TabManager, workspace: Workspace, panelId: UUID) {
        self.sessionId = sessionId
        self.requestId = requestId
        self.tabManager = tabManager
        self.workspace = workspace
        self.panelId = panelId
    }

    static func start(
        sessionId: String,
        requestId: String,
        toolName: String = "Bash",
        toolInputJSON: String = #"{"command":"touch /tmp/created.txt","description":"Create a file"}"#,
        requestExtraFieldsJSON: String? = nil,
        raisingToolCallInputJSON: String? = nil
    ) async throws -> PendingClaudePermission {
        FeedCoordinator.shared.install(store: WorkstreamStore(ringCapacity: 20))
        if let raisingToolCallInputJSON {
            // Claude's PreToolUse for the call normally reaches the Feed first.
            await deliver(WorkstreamEvent(
                sessionId: sessionId, hookEventName: .preToolUse, source: "claude", cwd: "/tmp",
                toolName: toolName, toolInputJSON: raisingToolCallInputJSON,
                extraFieldsJSON: requestExtraFieldsJSON
            ))
        }
        let tabManager = TabManager(autoWelcomeIfNeeded: false)
        let workspace = tabManager.addWorkspace(select: true)
        let panelId = try #require(workspace.focusedPanelId)
        let scenario = PendingClaudePermission(
            sessionId: sessionId, requestId: requestId,
            tabManager: tabManager, workspace: workspace, panelId: panelId
        )
        let request = WorkstreamEvent(
            sessionId: sessionId,
            hookEventName: .permissionRequest,
            source: "claude",
            cwd: "/tmp",
            toolName: toolName,
            toolInputJSON: toolInputJSON,
            requestId: requestId,
            extraFieldsJSON: requestExtraFieldsJSON
        )
        // Surface the overlay the way the socket path does for a live owner,
        // then hand the target to the waiter that concludes it.
        let surfaced = DispatchSemaphore(value: 0)
        FeedCoordinatorTestHooks.afterBlockingEventIngested = { event, ingestedRequestId in
            guard ingestedRequestId == requestId else { return }
            MainActor.assumeIsolated {
                if let target = FeedCoordinator.shared.surfaceBlockingDecisionAttention(
                    event: event,
                    resolved: (ownerId: scenario.workspace.id, surfaceId: scenario.panelId),
                    tabManager: scenario.tabManager
                ) {
                    _ = FeedCoordinator.shared.waiterRegistry.setAttention(target, requestID: requestId)
                }
            }
            surfaced.signal()
        }
        let hookReturned = scenario.hookReturned
        DispatchQueue.global(qos: .userInitiated).async {
            _ = FeedCoordinator.shared.ingestBlocking(event: request, waitTimeout: 60)
            hookReturned.signal()
        }
        let didSurface = await Self.wait(for: surfaced)
        try #require(didSurface, "the permission request never reached the Feed")
        return scenario
    }

    /// Delivers one-way hook telemetry and returns after the Feed accepted it.
    func deliverTelemetry(_ event: WorkstreamEvent) async {
        await Self.deliver(event)
    }

    private static func deliver(_ event: WorkstreamEvent) async {
        let accepted = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            _ = FeedCoordinator.shared.ingestBlocking(
                event: event,
                waitTimeout: 0,
                onAcceptedOnMainActor: { _ in accepted.signal() }
            )
        }
        let didAccept = await wait(for: accepted)
        #expect(didAccept, "the telemetry event never reached the Feed")
    }

    func awaitHookResult() async -> Bool {
        await Self.wait(for: hookReturned)
    }

    func tearDown() {
        FeedCoordinatorTestHooks.afterBlockingEventIngested = nil
        FeedCoordinator.shared.deliverReply(requestId: requestId, decision: .permission(.once))
        if tabManager.tabs.contains(where: { $0.id == workspace.id }) {
            tabManager.closeWorkspace(workspace)
        }
    }

    /// Waits for a real completion signal without blocking the main actor.
    private static func wait(for semaphore: DispatchSemaphore) async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: semaphore.wait(timeout: .now() + 10) == .success)
            }
        }
    }
}
