import CMUXAgentLaunch
import CmuxAgentChat
@testable import CmuxMobileHost
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite
struct AgentChatPermissionCardsTests {
    @MainActor
    @Test("permission hooks synthesize one live card and freeze it after answer")
    func hookLiveHistoryAnswer() async throws {
        let home = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let transcript = home.appendingPathComponent("session.jsonl")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try "{}\n".write(to: transcript, atomically: true, encoding: .utf8)
        var payloads: [[String: Any]] = []
        let service = AgentChatTranscriptService(
            registry: AgentChatSessionRegistry(),
            resolver: AgentChatTranscriptResolver(homeDirectory: home, environment: [:]),
            hasEventSubscribers: { true },
            emitEventPayload: { payloads.append($0) }
        )
        defer { service.shutdown() }
        let sessionID = UUID().uuidString
        let surfaceID = UUID().uuidString
        let event = WorkstreamEvent(
            sessionId: sessionID,
            hookEventName: .permissionRequest,
            source: "claude",
            surfaceId: surfaceID,
            transcriptPath: transcript.path,
            cwd: home.path,
            toolName: "Bash",
            toolInputJSON: #"{"command":"echo hello"}"#,
            requestId: "request-1",
            receivedAt: Date(timeIntervalSince1970: 100)
        )
        service.noteHookEvent(event)
        service.noteHookEvent(event)

        let page = try #require(await service.history(sessionID: sessionID, beforeSeq: nil, limit: 50))
        #expect(page.messages.count == 1)
        let message = try #require(page.messages.first)
        #expect(message.id.hasPrefix("permission:\(sessionID):"))
        guard case .permissionRequest(let request) = message.kind else {
            Issue.record("Expected synthesized permission card")
            return
        }
        #expect(request.subject == "Bash: echo hello")
        #expect(request.resolution == nil)

        let appended = try decodeFrames(payloads).filter {
            if case .appended = $0.event { return true }
            return false
        }
        #expect(appended.count == 1)
        guard case .appended(let liveMessages) = try #require(appended.first?.event) else {
            Issue.record("Expected appended live event")
            return
        }
        #expect(liveMessages.map(\.id) == [message.id])

        #expect(service.resolvePermission(sessionID: sessionID, requestID: message.id, optionIndex: 0))
        let resolvedPage = try #require(await service.history(sessionID: sessionID, beforeSeq: nil, limit: 50))
        guard case .permissionRequest(let resolved) = try #require(resolvedPage.messages.first?.kind) else {
            Issue.record("Expected resolved permission card")
            return
        }
        #expect(resolved.resolution == .approved)
        let updated = decodeFrames(payloads).filter {
            if case .updated = $0.event { return true }
            return false
        }
        #expect(updated.count == 1)
    }

    @MainActor
    @Test("stopping an unanswered permission freezes it as expired")
    func stopExpiresPendingCard() async throws {
        let home = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        var payloads: [[String: Any]] = []
        let service = AgentChatTranscriptService(
            registry: AgentChatSessionRegistry(),
            resolver: AgentChatTranscriptResolver(homeDirectory: home, environment: [:]),
            hasEventSubscribers: { true },
            emitEventPayload: { payloads.append($0) }
        )
        defer { service.shutdown() }
        let sessionID = UUID().uuidString
        let surfaceID = UUID().uuidString
        service.noteHookEvent(WorkstreamEvent(
            sessionId: sessionID,
            hookEventName: .permissionRequest,
            source: "codex",
            surfaceId: surfaceID,
            toolName: "Write",
            toolInputJSON: #"{"file_path":"/tmp/a"}"#,
            requestId: "request-2",
            receivedAt: Date(timeIntervalSince1970: 100)
        ))
        service.noteHookEvent(WorkstreamEvent(
            sessionId: sessionID,
            hookEventName: .stop,
            source: "codex",
            surfaceId: surfaceID,
            receivedAt: Date(timeIntervalSince1970: 101)
        ))
        let page = try #require(await service.history(sessionID: sessionID, beforeSeq: nil, limit: 50))
        guard case .permissionRequest(let request) = try #require(page.messages.first?.kind) else {
            Issue.record("Expected permission card")
            return
        }
        #expect(request.resolution == .expired)
        let updated = decodeFrames(payloads).filter {
            if case .updated = $0.event { return true }
            return false
        }
        #expect(updated.count == 1)
    }

    @MainActor
    @Test("OpenCode question cards resolve through the blocking feed decision")
    func openCodeQuestionAnswer() async throws {
        let home = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        var payloads: [[String: Any]] = []
        let service = AgentChatTranscriptService(
            registry: AgentChatSessionRegistry(),
            resolver: AgentChatTranscriptResolver(homeDirectory: home, environment: [:]),
            hasEventSubscribers: { true },
            emitEventPayload: { payloads.append($0) }
        )
        defer { service.shutdown() }
        let sessionID = UUID().uuidString
        let questionEvent = WorkstreamEvent(
            sessionId: sessionID,
            hookEventName: .askUserQuestion,
            source: "opencode",
            toolName: "question",
            toolInputJSON: #"{"questions":[{"id":"q1","question":"Which file?","options":[{"id":"a","label":"README"},{"id":"b","label":"Source"}]},{"id":"q2","question":"Which mode?","options":[{"id":"r","label":"Read"},{"id":"w","label":"Write"}]}]}"#,
            requestId: "opencode-question-1",
            receivedAt: Date(timeIntervalSince1970: 200)
        )
        service.noteHookEvent(questionEvent)

        let page = try #require(await service.history(sessionID: sessionID, beforeSeq: nil, limit: 50))
        let message = try #require(page.messages.first)
        let secondMessage = try #require(page.messages.dropFirst().first)
        #expect(page.messages.count == 2)
        guard case .question(let question) = message.kind else {
            Issue.record("Expected an OpenCode question card")
            return
        }
        #expect(question.prompt == "Which file?")
        #expect(question.options.map(\.label) == ["README", "Source"])

        let firstAnswer = try #require(service.feedAnswer(
            sessionID: sessionID,
            messageID: message.id,
            optionIndex: 1
        ))
        #expect(firstAnswer.requestID == "opencode-question-1")
        #expect(firstAnswer.decision == nil)
        let answer = try #require(service.feedAnswer(
            sessionID: sessionID,
            messageID: secondMessage.id,
            optionIndex: 1
        ))
        #expect(answer.requestID == "opencode-question-1")
        guard let decision = answer.decision,
              case .question(let selections) = decision else {
            Issue.record("Expected a question decision")
            return
        }
        #expect(selections == ["Source", "Write"])
        let resolvedPage = try #require(await service.history(sessionID: sessionID, beforeSeq: nil, limit: 50))
        guard case .question(let resolved) = try #require(resolvedPage.messages.first?.kind) else {
            Issue.record("Expected resolved question card")
            return
        }
        #expect(resolved.selectedOptionLabel == "Source")

        // A later request with the same payload gets a fresh group and keeps
        // the completed cards in history instead of overwriting their ids.
        service.noteHookEvent(questionEvent)
        let repeatedPage = try #require(await service.history(sessionID: sessionID, beforeSeq: nil, limit: 50))
        #expect(repeatedPage.messages.count == 4)
        #expect(repeatedPage.messages.dropFirst(2).allSatisfy {
            guard case .question(let question) = $0.kind else { return false }
            return question.selectedOptionLabel == nil
        })
    }

    @MainActor
    @Test("OpenCode plan cards route approve and deny decisions")
    func openCodePlanAnswer() async throws {
        let home = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let service = AgentChatTranscriptService(
            registry: AgentChatSessionRegistry(),
            resolver: AgentChatTranscriptResolver(homeDirectory: home, environment: [:]),
            hasEventSubscribers: { false },
            emitEventPayload: { _ in }
        )
        defer { service.shutdown() }
        let sessionID = UUID().uuidString
        service.noteHookEvent(WorkstreamEvent(
            sessionId: sessionID,
            hookEventName: .exitPlanMode,
            source: "opencode",
            toolName: "plan",
            toolInputJSON: #"{"plan":"Run the focused tests"}"#,
            requestId: "opencode-plan-1"
        ))
        let page = try #require(await service.history(sessionID: sessionID, beforeSeq: nil, limit: 50))
        let message = try #require(page.messages.first)
        let answer = try #require(service.feedAnswer(sessionID: sessionID, messageID: message.id, optionIndex: 0))
        guard case .exitPlan(let mode, let feedback) = answer.decision else {
            Issue.record("Expected an exit-plan decision")
            return
        }
        #expect(mode == .autoAccept)
        #expect(feedback == nil)
    }

    @MainActor
    @Test("Codex hook interaction events do not duplicate transcript cards")
    func codexHookInteractionsAreIgnored() async throws {
        let home = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        var payloads: [[String: Any]] = []
        let service = AgentChatTranscriptService(
            registry: AgentChatSessionRegistry(),
            resolver: AgentChatTranscriptResolver(homeDirectory: home, environment: [:]),
            hasEventSubscribers: { true },
            emitEventPayload: { payloads.append($0) }
        )
        defer { service.shutdown() }
        let sessionID = UUID().uuidString
        let surfaceID = UUID().uuidString
        for hook in [WorkstreamEvent.HookEventName.permissionRequest, .askUserQuestion, .exitPlanMode] {
            service.noteHookEvent(WorkstreamEvent(
                sessionId: sessionID,
                hookEventName: hook,
                source: "codex",
                surfaceId: surfaceID,
                toolName: "question",
                toolInputJSON: #"{"questions":[{"question":"Continue?","options":[{"label":"Yes"}]}]}"#,
                requestId: hook.rawValue,
                receivedAt: Date(timeIntervalSince1970: 300)
            ))
        }

        let interactionFrames = decodeFrames(payloads).filter { frame in
            guard case .appended(let messages) = frame.event else { return false }
            return messages.contains { message in
                switch message.kind {
                case .permissionRequest, .question: return true
                default: return false
                }
            }
        }
        #expect(interactionFrames.isEmpty)
        #expect(service.permissionRecordsBySessionID[sessionID] == nil)
        #expect(service.questionRecordsBySessionID[sessionID] == nil)
    }

    private func decodeFrames(_ payloads: [[String: Any]]) -> [ChatSessionEventFrame] {
        let coding = ChatWireCoding()
        return payloads.compactMap { payload in
            guard JSONSerialization.isValidJSONObject(payload),
                  let data = try? JSONSerialization.data(withJSONObject: payload) else { return nil }
            return try? coding.decode(ChatSessionEventFrame.self, from: data)
        }
    }
}
