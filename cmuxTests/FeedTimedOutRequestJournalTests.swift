import CMUXAgentLaunch
import CmuxAgentJournal
import CmuxFoundation
import Foundation
import Testing
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

extension AgentNotificationRegressionTests {
    /// A request the Feed timed out on goes to the terminal. When the agent's
    /// next hook shows it was answered there, the journal must hear that the
    /// request is resolved, or the workspace stays needs-attention until Stop.
    /// https://github.com/manaflow-ai/cmux/issues/41980
    @Test(arguments: [
        (WorkstreamEvent.HookEventName.askUserQuestion, "AskUserQuestion",
         #"{"questions":[{"question":"Continue?","options":[{"label":"Yes"},{"label":"No"}]}]}"#),
        (.permissionRequest, "Bash", #"{"command":"ls"}"#),
    ])
    func aTimedOutRequestIsResolvedByTheAgentsNextHook(
        hook: WorkstreamEvent.HookEventName, toolName: String, toolInput: String
    ) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let databaseURL = root.appendingPathComponent("journal.sqlite")
        let journal = AgentJournalLifecycleCenter(databaseURL: databaseURL)
        let previousStore = FeedCoordinator.shared.store
        let previousJournal = FeedCoordinator.shared.notificationJournal
        let previousCenter = FeedCoordinator.shared.notificationCenterForTesting
        defer {
            FeedCoordinator.shared.restoreInstallationForTesting(store: previousStore,
                journal: previousJournal, center: previousCenter)
        }
        FeedCoordinator.shared.install(store: WorkstreamStore(ringCapacity: 10), notificationJournal: journal)

        let workspace = UUID().uuidString
        let surface = UUID().uuidString
        let session = try #require(FeedWorkstreamIdentifier(agentID: "claude", sessionID: "feed-session")).rawValue
        let otherSession = try #require(FeedWorkstreamIdentifier(agentID: "claude", sessionID: "other-session")).rawValue
        let requestID = UUID().uuidString
        let request = WorkstreamEvent(sessionId: session, hookEventName: hook, source: "claude",
            workspaceId: workspace, surfaceId: surface, toolName: toolName, toolInputJSON: toolInput,
            requestId: requestID, extraFieldsJSON: #"{"_hook_sent_at_ms":1000}"#)
        let result = await Task.detached {
            FeedCoordinator.shared.ingestBlocking(event: request, waitTimeout: 1)
        }.value
        guard case .timedOut = result else {
            Issue.record("expected the Feed wait to time out: \(result)")
            return
        }

        func tool(session: String, sentAt: Int) -> WorkstreamEvent {
            WorkstreamEvent(sessionId: session, hookEventName: .preToolUse, source: "claude",
                workspaceId: workspace, surfaceId: surface, toolName: "Bash", toolInputJSON: #"{"command":"pwd"}"#,
                extraFieldsJSON: #"{"_hook_sent_at_ms":\#(sentAt)}"#)
        }
        // Another session's tool, and a hook sent before the request, prove nothing.
        _ = FeedCoordinator.shared.ingestRevalidatedOnMainActor(tool(session: otherSession, sentAt: 2_000))
        _ = FeedCoordinator.shared.ingestRevalidatedOnMainActor(tool(session: session, sentAt: 900))
        // The answer was given in the terminal; the agent's next tool follows it.
        _ = FeedCoordinator.shared.ingestRevalidatedOnMainActor(tool(session: session, sentAt: 3_000))
        _ = FeedCoordinator.shared.ingestRevalidatedOnMainActor(tool(session: session, sentAt: 4_000))

        // Journal operations run in order, so once this marker is stored every
        // observation above has been handled.
        let marker = "marker-\(UUID().uuidString)"
        journal.observe(AgentJournalEventDraft(eventId: marker, kind: .sessionStarted, occurredAtMs: 1,
            source: "claude", agentKey: "claude_code", sessionId: "marker",
            workspaceId: workspace, surfaceId: surface))
        let events = try await Self.journaledEvents(at: databaseURL, through: marker)
        let resolutions = events.filter {
            $0.draft.kind == .attentionResolved && $0.draft.attention?.requestIdentity == requestID
        }
        #expect(resolutions.count == 1, "the timed-out request should be resolved once")
        #expect(resolutions.first?.draft.sessionId == "feed-session")
    }

    /// A Stop journals no resolution, but it can leave background work
    /// running with the request's attention still held, so the next tool
    /// still resolves it. A SessionEnd drops the request for good.
    @Test(arguments: [(WorkstreamEvent.HookEventName.stop, 1), (.sessionEnd, 0)])
    func aTimedOutRequestAcrossAStopOrSessionEnd(
        endHook: WorkstreamEvent.HookEventName, resolvedByTheNextTool: Int
    ) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let databaseURL = root.appendingPathComponent("journal.sqlite")
        let journal = AgentJournalLifecycleCenter(databaseURL: databaseURL)
        let previousStore = FeedCoordinator.shared.store
        let previousJournal = FeedCoordinator.shared.notificationJournal
        let previousCenter = FeedCoordinator.shared.notificationCenterForTesting
        defer {
            FeedCoordinator.shared.restoreInstallationForTesting(store: previousStore,
                journal: previousJournal, center: previousCenter)
        }
        FeedCoordinator.shared.install(store: WorkstreamStore(ringCapacity: 10), notificationJournal: journal)

        let workspace = UUID().uuidString
        let surface = UUID().uuidString
        let session = try #require(FeedWorkstreamIdentifier(agentID: "claude", sessionID: "feed-session")).rawValue
        let requestID = UUID().uuidString
        let request = WorkstreamEvent(sessionId: session, hookEventName: .permissionRequest, source: "claude",
            workspaceId: workspace, surfaceId: surface, toolName: "Bash", toolInputJSON: #"{"command":"ls"}"#,
            requestId: requestID, extraFieldsJSON: #"{"_hook_sent_at_ms":1000}"#)
        let result = await Task.detached {
            FeedCoordinator.shared.ingestBlocking(event: request, waitTimeout: 1)
        }.value
        guard case .timedOut = result else {
            Issue.record("expected the Feed wait to time out: \(result)")
            return
        }
        func hook(_ name: WorkstreamEvent.HookEventName, sentAt: Int) -> WorkstreamEvent {
            WorkstreamEvent(sessionId: session, hookEventName: name, source: "claude",
                workspaceId: workspace, surfaceId: surface, toolName: name == .preToolUse ? "Bash" : nil,
                toolInputJSON: name == .preToolUse ? #"{"command":"pwd"}"# : nil,
                extraFieldsJSON: #"{"_hook_sent_at_ms":\#(sentAt)}"#)
        }
        func resolutions(through marker: String) async throws -> Int {
            journal.observe(AgentJournalEventDraft(eventId: marker, kind: .sessionStarted, occurredAtMs: 1,
                source: "claude", agentKey: "claude_code", sessionId: "marker",
                workspaceId: workspace, surfaceId: surface))
            return try await Self.journaledEvents(at: databaseURL, through: marker).filter {
                $0.draft.kind == .attentionResolved && $0.draft.attention?.requestIdentity == requestID
            }.count
        }
        _ = FeedCoordinator.shared.ingestRevalidatedOnMainActor(hook(endHook, sentAt: 2_000))
        #expect(try await resolutions(through: "marker-end-\(UUID().uuidString)") == 0)
        _ = FeedCoordinator.shared.ingestRevalidatedOnMainActor(hook(.preToolUse, sentAt: 3_000))
        #expect(try await resolutions(through: "marker-tool-\(UUID().uuidString)") == resolvedByTheNextTool)
    }

    /// Reads the journal once `marker` is stored. The reader opens inside the
    /// loop because the center may still be opening the database.
    private static func journaledEvents(at databaseURL: URL, through marker: String) async throws -> [AgentJournalEvent] {
        var store: AgentJournalStore?
        defer { store?.close() }
        var events: [AgentJournalEvent] = []
        let deadline = ContinuousClock.now + .seconds(10)
        while !events.contains(where: { $0.draft.eventId == marker }), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
            if store == nil { store = try? AgentJournalStore(databaseURL: databaseURL) }
            events = (try? store?.events(afterSequence: 0, limit: 200)) ?? events
        }
        #expect(events.contains { $0.draft.eventId == marker })
        return events
    }
}
