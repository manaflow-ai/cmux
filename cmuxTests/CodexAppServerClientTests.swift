import AppKit
import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

private final class FakeCodexAppServerClient: CodexAppServerClienting {
    struct TurnStartCall: Equatable {
        var threadId: String
        var text: String
    }

    struct SteerCall: Equatable {
        var threadId: String
        var turnId: String
        var text: String
    }

    var onEvent: ((CodexAppServerEvent) -> Void)?
    var holdStartAndInitialize = false
    var holdStartThread = false
    var startAndInitializeCallCount = 0
    var startThreadCallCount = 0
    var resumeThreadCallCount = 0
    var stopCallCount = 0
    var resumeThreadError: Error?
    var resumeThreadResponse: [String: Any]?
    var startTurnCalls: [TurnStartCall] = []
    var steerTurnCalls: [SteerCall] = []
    var steerTurnCallCount = 0
    var holdListModels = false
    var listModelsCallCount = 0
    var pendingListModelsCallCount: Int { listModelsContinuations.count }

    private var startAndInitializeContinuation: CheckedContinuation<Void, Error>?
    private var startThreadContinuation: CheckedContinuation<String, Error>?
    private var listModelsContinuations: [CheckedContinuation<[[String: Any]], Error>] = []

    static func generatedThreadId(_ index: Int) -> String {
        String(format: "019d6637-e5cc-7cc0-a321-2c43b799%04x", index)
    }

    func stop() {
        stopCallCount += 1
    }

    func startAndInitialize() async throws {
        startAndInitializeCallCount += 1
        guard holdStartAndInitialize else { return }
        try await withCheckedThrowingContinuation { continuation in
            startAndInitializeContinuation = continuation
        }
    }

    func finishStartAndInitialize() {
        let continuation = startAndInitializeContinuation
        startAndInitializeContinuation = nil
        continuation?.resume()
    }

    func startThread(cwd: String?, model: String?, serviceTier: String?) async throws -> String {
        startThreadCallCount += 1
        guard holdStartThread else {
            return Self.generatedThreadId(startThreadCallCount)
        }
        return try await withCheckedThrowingContinuation { continuation in
            startThreadContinuation = continuation
        }
    }

    func finishStartThread(with threadId: String) {
        let continuation = startThreadContinuation
        startThreadContinuation = nil
        continuation?.resume(returning: threadId)
    }

    func resumeThread(threadId: String, cwd: String?) async throws -> [String: Any] {
        resumeThreadCallCount += 1
        if let resumeThreadError {
            throw resumeThreadError
        }
        if let resumeThreadResponse {
            return resumeThreadResponse
        }
        return ["thread": ["id": threadId]]
    }

    func startTurn(
        threadId: String,
        text: String,
        cwd: String?,
        model: String?,
        serviceTier: String?,
        reasoningSummary: String?
    ) async throws -> String {
        startTurnCalls.append(TurnStartCall(threadId: threadId, text: text))
        return "turn-\(startTurnCalls.count)"
    }

    func listModels(includeHidden: Bool) async throws -> [[String: Any]] {
        listModelsCallCount += 1
        guard holdListModels else {
            return []
        }
        return try await withCheckedThrowingContinuation { continuation in
            listModelsContinuations.append(continuation)
        }
    }

    func finishNextListModels(with models: [[String: Any]] = []) {
        guard !listModelsContinuations.isEmpty else { return }
        let continuation = listModelsContinuations.removeFirst()
        continuation.resume(returning: models)
    }

    func finishAllListModels(with models: [[String: Any]] = []) {
        let continuations = listModelsContinuations
        listModelsContinuations.removeAll()
        for continuation in continuations {
            continuation.resume(returning: models)
        }
    }

    deinit {
        finishAllListModels()
    }

    func readRateLimits() async throws -> [String: Any] {
        [:]
    }

    func steerTurn(threadId: String, turnId: String, text: String) async throws -> String {
        steerTurnCallCount += 1
        steerTurnCalls.append(SteerCall(threadId: threadId, turnId: turnId, text: text))
        return turnId
    }

    func interruptTurn(threadId: String, turnId: String) async throws {}

    func respondToServerRequest(id: CodexAppServerRequestID, result: [String: Any]) throws {}

    func rejectServerRequest(id: CodexAppServerRequestID, message: String) throws {}
}

final class CodexAppServerRequestFactoryTests: XCTestCase {
    func testInitializeRequestUsesCodexAppServerHandshakeShape() throws {
        let request = CodexAppServerRequestFactory.initializeRequest(id: 42)

        XCTAssertEqual(request["jsonrpc"] as? String, "2.0")
        XCTAssertEqual(request["id"] as? Int, 42)
        XCTAssertEqual(request["method"] as? String, "initialize")

        let params = try XCTUnwrap(request["params"] as? [String: Any])
        let clientInfo = try XCTUnwrap(params["clientInfo"] as? [String: Any])
        XCTAssertEqual(clientInfo["name"] as? String, "cmux")
        XCTAssertEqual(clientInfo["title"] as? String, "cmux")
        XCTAssertNotNil(clientInfo["version"] as? String)

        let capabilities = try XCTUnwrap(params["capabilities"] as? [String: Any])
        XCTAssertEqual(capabilities["experimentalApi"] as? Bool, true)
    }

    func testInitializedNotificationHasNoRequestId() {
        let notification = CodexAppServerRequestFactory.initializedNotification()

        XCTAssertEqual(notification["jsonrpc"] as? String, "2.0")
        XCTAssertNil(notification["id"])
        XCTAssertEqual(notification["method"] as? String, "initialized")
    }

    func testThreadStartRequestCarriesCwdAndPersistentSession() throws {
        let request = CodexAppServerRequestFactory.threadStartRequest(
            id: 7,
            cwd: "/Users/cmux/project"
        )

        XCTAssertEqual(request["jsonrpc"] as? String, "2.0")
        XCTAssertEqual(request["id"] as? Int, 7)
        XCTAssertEqual(request["method"] as? String, "thread/start")

        let params = try XCTUnwrap(request["params"] as? [String: Any])
        XCTAssertEqual(params["cwd"] as? String, "/Users/cmux/project")
        XCTAssertEqual(params["serviceName"] as? String, "cmux")
        XCTAssertEqual(params["ephemeral"] as? Bool, false)
    }

    func testThreadResumeRequestCarriesThreadIdAndCwd() throws {
        let request = CodexAppServerRequestFactory.threadResumeRequest(
            id: 8,
            threadId: "00000000-0000-0000-0000-000000000000",
            cwd: "/Users/cmux/project"
        )

        XCTAssertEqual(request["jsonrpc"] as? String, "2.0")
        XCTAssertEqual(request["id"] as? Int, 8)
        XCTAssertEqual(request["method"] as? String, "thread/resume")

        let params = try XCTUnwrap(request["params"] as? [String: Any])
        XCTAssertEqual(params["threadId"] as? String, "00000000-0000-0000-0000-000000000000")
        XCTAssertEqual(params["cwd"] as? String, "/Users/cmux/project")
    }

    func testTurnStartRequestUsesTextInputItemShape() throws {
        let request = CodexAppServerRequestFactory.turnStartRequest(
            id: 9,
            threadId: "thr_123",
            text: "Summarize this repo",
            cwd: "/Users/cmux/project"
        )

        XCTAssertEqual(request["jsonrpc"] as? String, "2.0")
        XCTAssertEqual(request["id"] as? Int, 9)
        XCTAssertEqual(request["method"] as? String, "turn/start")

        let params = try XCTUnwrap(request["params"] as? [String: Any])
        XCTAssertEqual(params["threadId"] as? String, "thr_123")
        XCTAssertEqual(params["cwd"] as? String, "/Users/cmux/project")

        let input = try XCTUnwrap(params["input"] as? [[String: Any]])
        XCTAssertEqual(input.count, 1)
        XCTAssertEqual(input[0]["type"] as? String, "text")
        XCTAssertEqual(input[0]["text"] as? String, "Summarize this repo")
        XCTAssertNotNil(input[0]["text_elements"] as? [Any])
        XCTAssertNil(input[0]["textElements"])
    }

    func testTurnStartRequestCanRequestReasoningSummary() throws {
        let request = CodexAppServerRequestFactory.turnStartRequest(
            id: 12,
            threadId: "thr_123",
            text: "Think through this",
            cwd: "/Users/cmux/project",
            reasoningSummary: "detailed"
        )

        let params = try XCTUnwrap(request["params"] as? [String: Any])
        XCTAssertEqual(params["summary"] as? String, "detailed")
    }

    func testThreadAndTurnStartRequestsCarryModelOverrides() throws {
        let threadRequest = CodexAppServerRequestFactory.threadStartRequest(
            id: 19,
            cwd: "/Users/cmux/project",
            model: "gpt-5.5-codex",
            serviceTier: "fast"
        )
        let threadParams = try XCTUnwrap(threadRequest["params"] as? [String: Any])
        XCTAssertEqual(threadParams["model"] as? String, "gpt-5.5-codex")
        XCTAssertEqual(threadParams["serviceTier"] as? String, "fast")

        let turnRequest = CodexAppServerRequestFactory.turnStartRequest(
            id: 20,
            threadId: "thr_123",
            text: "Use the selected model",
            cwd: "/Users/cmux/project",
            model: "gpt-5.5-codex",
            serviceTier: "fast"
        )
        let turnParams = try XCTUnwrap(turnRequest["params"] as? [String: Any])
        XCTAssertEqual(turnParams["model"] as? String, "gpt-5.5-codex")
        XCTAssertEqual(turnParams["serviceTier"] as? String, "fast")
    }

    func testModelListAndRateLimitRequestsUseCodexMethods() throws {
        let modelRequest = CodexAppServerRequestFactory.modelListRequest(id: 21, includeHidden: true)
        XCTAssertEqual(modelRequest["jsonrpc"] as? String, "2.0")
        XCTAssertEqual(modelRequest["id"] as? Int, 21)
        XCTAssertEqual(modelRequest["method"] as? String, "model/list")
        let modelParams = try XCTUnwrap(modelRequest["params"] as? [String: Any])
        XCTAssertEqual(modelParams["includeHidden"] as? Bool, true)

        let rateLimitRequest = CodexAppServerRequestFactory.accountRateLimitsReadRequest(id: 22)
        XCTAssertEqual(rateLimitRequest["jsonrpc"] as? String, "2.0")
        XCTAssertEqual(rateLimitRequest["id"] as? Int, 22)
        XCTAssertEqual(rateLimitRequest["method"] as? String, "account/rateLimits/read")
        XCTAssertNil(rateLimitRequest["params"])
    }

    func testModelInfoPrefersFullCodexModelNameOverShortDisplayName() throws {
        let model = try XCTUnwrap(
            CodexAppServerModelInfo(object: [
                "id": "gpt-5.5-codex-spark",
                "model": "gpt-5.5-codex-spark",
                "displayName": "5.5",
            ])
        )

        XCTAssertEqual(model.pickerTitle, "GPT-5.5 Codex Spark")
    }

    func testTurnSteerRequestUsesExpectedTurnPrecondition() throws {
        let request = CodexAppServerRequestFactory.turnSteerRequest(
            id: 10,
            threadId: "thr_123",
            turnId: "turn_456",
            text: "Adjust the current plan"
        )

        XCTAssertEqual(request["jsonrpc"] as? String, "2.0")
        XCTAssertEqual(request["id"] as? Int, 10)
        XCTAssertEqual(request["method"] as? String, "turn/steer")

        let params = try XCTUnwrap(request["params"] as? [String: Any])
        XCTAssertEqual(params["threadId"] as? String, "thr_123")
        XCTAssertEqual(params["expectedTurnId"] as? String, "turn_456")

        let input = try XCTUnwrap(params["input"] as? [[String: Any]])
        XCTAssertEqual(input.count, 1)
        XCTAssertEqual(input[0]["type"] as? String, "text")
        XCTAssertEqual(input[0]["text"] as? String, "Adjust the current plan")
        XCTAssertNotNil(input[0]["text_elements"] as? [Any])
        XCTAssertNil(input[0]["textElements"])
    }

    func testTurnInterruptRequestTargetsThreadAndTurn() throws {
        let request = CodexAppServerRequestFactory.turnInterruptRequest(
            id: 11,
            threadId: "thr_123",
            turnId: "turn_456"
        )

        XCTAssertEqual(request["jsonrpc"] as? String, "2.0")
        XCTAssertEqual(request["id"] as? Int, 11)
        XCTAssertEqual(request["method"] as? String, "turn/interrupt")

        let params = try XCTUnwrap(request["params"] as? [String: Any])
        XCTAssertEqual(params["threadId"] as? String, "thr_123")
        XCTAssertEqual(params["turnId"] as? String, "turn_456")
    }

    func testCodexThreadIdNormalizationRejectsInvalidResumeIds() {
        XCTAssertEqual(
            CodexAppServerPanel.normalizedCodexThreadId("019d6637-e5cc-7cc0-a321-2c43b799036b"),
            "019d6637-e5cc-7cc0-a321-2c43b799036b"
        )
        XCTAssertEqual(
            CodexAppServerPanel.normalizedCodexThreadId("urn:uuid:019D6637-E5CC-7CC0-A321-2C43B799036B"),
            "019d6637-e5cc-7cc0-a321-2c43b799036b"
        )
        XCTAssertNil(CodexAppServerPanel.normalizedCodexThreadId("codex"))
        XCTAssertNil(CodexAppServerPanel.normalizedCodexThreadId("0"))
    }

    @MainActor
    func testCodexPanelAutoStartIsExplicitLifecycleState() {
        let workspaceId = UUID()
        let freshPanel = CodexAppServerPanel(
            workspaceId: workspaceId,
            cwd: "/tmp"
        )
        let resumingPanel = CodexAppServerPanel(
            workspaceId: workspaceId,
            cwd: "/tmp",
            resumeThreadId: "019d6637-e5cc-7cc0-a321-2c43b799036b"
        )
        let restoredPanel = CodexAppServerPanel(
            workspaceId: workspaceId,
            cwd: "/tmp",
            resumeThreadId: "019d6637-e5cc-7cc0-a321-2c43b799036b",
            autoStartOnAppear: false
        )

        XCTAssertTrue(freshPanel.shouldAutoStart)
        XCTAssertTrue(resumingPanel.shouldAutoStart)
        XCTAssertFalse(restoredPanel.shouldAutoStart)
    }

    @MainActor
    func testResumeMissingRolloutFallsBackToFreshReadyPanel() async throws {
        let client = FakeCodexAppServerClient()
        client.resumeThreadError = CodexAppServerClientError.requestFailed(
            "no rollout found for thread id 019d6637-e5cc-7cc0-a321-2c43b799036b"
        )
        let panel = CodexAppServerPanel(
            workspaceId: UUID(),
            cwd: "/tmp",
            resumeThreadId: "019d6637-e5cc-7cc0-a321-2c43b799036b",
            client: client
        )

        await panel.start()

        XCTAssertEqual(client.resumeThreadCallCount, 1)
        XCTAssertEqual(panel.status, .ready)
        XCTAssertFalse(panel.isDirty)
        XCTAssertNil(panel.resumableThreadId)

        panel.promptText = "start over"
        await panel.sendPrompt()

        let freshThreadId = FakeCodexAppServerClient.generatedThreadId(1)
        XCTAssertEqual(client.startThreadCallCount, 1)
        XCTAssertEqual(client.startTurnCalls, [
            FakeCodexAppServerClient.TurnStartCall(threadId: freshThreadId, text: "start over"),
        ])
        XCTAssertEqual(panel.resumableThreadId, freshThreadId)
    }

    @MainActor
    func testResumeMissingRolloutDoesNotRetryUnavailableThreadAfterRestart() async throws {
        let client = FakeCodexAppServerClient()
        client.resumeThreadError = CodexAppServerClientError.requestFailed(
            "no rollout found for thread id 019d6637-e5cc-7cc0-a321-2c43b799036b"
        )
        let panel = CodexAppServerPanel(
            workspaceId: UUID(),
            cwd: "/tmp",
            resumeThreadId: "019d6637-e5cc-7cc0-a321-2c43b799036b",
            client: client
        )

        await panel.start()
        panel.stop()
        await panel.start()

        XCTAssertEqual(client.startAndInitializeCallCount, 2)
        XCTAssertEqual(client.resumeThreadCallCount, 1)
        XCTAssertEqual(panel.status, .ready)
        XCTAssertNil(panel.resumableThreadId)
    }

    @MainActor
    func testSendingPromptFromStoppedMissingRolloutResumeStartsFreshThreadAndKeepsUserMessage() async throws {
        let client = FakeCodexAppServerClient()
        client.resumeThreadError = CodexAppServerClientError.requestFailed(
            "no rollout found for thread id 019d6637-e5cc-7cc0-a321-2c43b799036b"
        )
        let panel = CodexAppServerPanel(
            workspaceId: UUID(),
            cwd: "/tmp",
            resumeThreadId: "019d6637-e5cc-7cc0-a321-2c43b799036b",
            client: client
        )
        panel.promptText = "start over"

        await panel.sendPrompt()

        let freshThreadId = FakeCodexAppServerClient.generatedThreadId(1)
        XCTAssertEqual(client.startAndInitializeCallCount, 1)
        XCTAssertEqual(client.resumeThreadCallCount, 1)
        XCTAssertEqual(client.startThreadCallCount, 1)
        XCTAssertEqual(client.startTurnCalls, [
            FakeCodexAppServerClient.TurnStartCall(threadId: freshThreadId, text: "start over"),
        ])
        XCTAssertEqual(panel.status, .running)
        XCTAssertEqual(panel.resumableThreadId, freshThreadId)
        XCTAssertEqual(panel.transcriptItems.filter { $0.role == .user }.map(\.body), ["start over"])
    }

    @MainActor
    func testSendingPromptFromStoppedSuccessfulResumePreservesCurrentUserMessage() async throws {
        let threadId = "019d6637-e5cc-7cc0-a321-2c43b799036b"
        let client = FakeCodexAppServerClient()
        client.resumeThreadResponse = [
            "thread": [
                "id": threadId,
                "turns": [
                    [
                        "items": [
                            [
                                "type": "userMessage",
                                "content": [
                                    [
                                        "type": "text",
                                        "text": "previous prompt",
                                    ],
                                ],
                            ],
                            [
                                "type": "agentMessage",
                                "text": "previous answer",
                            ],
                        ],
                    ],
                ],
            ],
        ]
        let panel = CodexAppServerPanel(
            workspaceId: UUID(),
            cwd: "/tmp",
            resumeThreadId: threadId,
            client: client
        )
        panel.promptText = "current prompt"

        await panel.sendPrompt()

        XCTAssertEqual(client.resumeThreadCallCount, 1)
        XCTAssertEqual(client.startThreadCallCount, 0)
        XCTAssertEqual(client.startTurnCalls, [
            FakeCodexAppServerClient.TurnStartCall(threadId: threadId, text: "current prompt"),
        ])
        XCTAssertEqual(
            panel.transcriptItems.filter { $0.role == .user }.map(\.body),
            ["previous prompt", "current prompt"]
        )
    }

    @MainActor
    func testStartupFailureAfterInitializeStopsClientBeforeFailedState() async throws {
        let client = FakeCodexAppServerClient()
        client.resumeThreadError = CodexAppServerClientError.requestFailed("permission denied")
        let panel = CodexAppServerPanel(
            workspaceId: UUID(),
            cwd: "/tmp",
            resumeThreadId: "019d6637-e5cc-7cc0-a321-2c43b799036b",
            client: client
        )

        await panel.start()

        XCTAssertEqual(client.startAndInitializeCallCount, 1)
        XCTAssertEqual(client.resumeThreadCallCount, 1)
        XCTAssertEqual(client.stopCallCount, 1)
        XCTAssertTrue(panel.status.isFailed)
    }

    func testMissingRolloutResumeErrorMatcher() {
        XCTAssertTrue(CodexAppServerPanel.isMissingRolloutResumeError(
            CodexAppServerClientError.requestFailed("no rollout found for thread id abc")
        ))
        XCTAssertFalse(CodexAppServerPanel.isMissingRolloutResumeError(
            CodexAppServerClientError.requestFailed("permission denied")
        ))
    }

    @MainActor
    func testLateClientEventsFromStoppedLifecycleAreIgnored() async throws {
        let client = FakeCodexAppServerClient()
        let panel = CodexAppServerPanel(
            workspaceId: UUID(),
            cwd: "/tmp",
            client: client
        )
        await panel.start()
        let stoppedLifecycleHandler = client.onEvent

        panel.stop()
        stoppedLifecycleHandler?(.terminated(42))
        await Task.yield()

        XCTAssertEqual(panel.status, .stopped)
        XCTAssertTrue(panel.transcriptItems.isEmpty)
    }

    @MainActor
    func testTerminatedAppServerPreservesStartedThreadForRestore() async throws {
        let client = FakeCodexAppServerClient()
        let panel = CodexAppServerPanel(
            workspaceId: UUID(),
            cwd: "/tmp",
            client: client
        )
        await panel.start()

        let threadId = FakeCodexAppServerClient.generatedThreadId(7)
        client.onEvent?(
            .notification(CodexAppServerServerNotification(
                method: "thread/started",
                params: ["thread": ["id": threadId]]
            ))
        )
        let didCaptureThread = await waitForMainActorCondition {
            panel.resumableThreadId == threadId
        }
        XCTAssertTrue(didCaptureThread)

        client.onEvent?(.terminated(42))
        let didFail = await waitForMainActorCondition {
            panel.status.isFailed
        }

        XCTAssertTrue(didFail)
        XCTAssertEqual(panel.resumableThreadId, threadId)
    }

    @MainActor
    func testCleanAppServerExitLeavesPanelReusable() async throws {
        let client = FakeCodexAppServerClient()
        let panel = CodexAppServerPanel(
            workspaceId: UUID(),
            cwd: "/tmp",
            client: client
        )
        await panel.start()

        let threadId = FakeCodexAppServerClient.generatedThreadId(8)
        client.onEvent?(
            .notification(CodexAppServerServerNotification(
                method: "thread/started",
                params: ["thread": ["id": threadId]]
            ))
        )
        client.onEvent?(.terminated(0))

        let didStop = await waitForMainActorCondition {
            panel.status == .stopped
        }
        XCTAssertTrue(didStop)
        XCTAssertFalse(panel.isDirty)
        XCTAssertEqual(panel.displayTitle, "Codex")
        XCTAssertEqual(panel.resumableThreadId, threadId)
        XCTAssertTrue(panel.transcriptItems.isEmpty)

        panel.promptText = "continue"
        XCTAssertTrue(panel.canSendPrompt)
    }

    @MainActor
    func testSendingPromptAfterCleanExitResumesExistingThreadBeforeTurnStart() async throws {
        let client = FakeCodexAppServerClient()
        let panel = CodexAppServerPanel(
            workspaceId: UUID(),
            cwd: "/tmp",
            client: client
        )
        await panel.start()

        let threadId = FakeCodexAppServerClient.generatedThreadId(9)
        client.onEvent?(
            .notification(CodexAppServerServerNotification(
                method: "thread/started",
                params: ["thread": ["id": threadId]]
            ))
        )
        client.onEvent?(.terminated(0))
        let didStop = await waitForMainActorCondition {
            panel.status == .stopped
        }
        XCTAssertTrue(didStop)

        panel.promptText = "continue"
        await panel.sendPrompt()

        XCTAssertEqual(client.startAndInitializeCallCount, 2)
        XCTAssertEqual(client.resumeThreadCallCount, 1)
        XCTAssertEqual(client.startThreadCallCount, 0)
        XCTAssertEqual(client.startTurnCalls, [
            FakeCodexAppServerClient.TurnStartCall(threadId: threadId, text: "continue"),
        ])
    }

    @MainActor
    func testSendingPromptAfterCleanExitFromResumedThreadResumesAgainBeforeTurnStart() async throws {
        let threadId = "019d6637-e5cc-7cc0-a321-2c43b799036b"
        let client = FakeCodexAppServerClient()
        let panel = CodexAppServerPanel(
            workspaceId: UUID(),
            cwd: "/tmp",
            resumeThreadId: threadId,
            client: client
        )
        await panel.start()
        client.onEvent?(.terminated(0))
        let didStop = await waitForMainActorCondition {
            panel.status == .stopped
        }
        XCTAssertTrue(didStop)

        panel.promptText = "continue resumed"
        await panel.sendPrompt()

        XCTAssertEqual(client.startAndInitializeCallCount, 2)
        XCTAssertEqual(client.resumeThreadCallCount, 2)
        XCTAssertEqual(client.startThreadCallCount, 0)
        XCTAssertEqual(client.startTurnCalls, [
            FakeCodexAppServerClient.TurnStartCall(threadId: threadId, text: "continue resumed"),
        ])
    }

    @MainActor
    func testQuietCodexNotificationsDoNotAppendTranscriptRows() async throws {
        let client = FakeCodexAppServerClient()
        let panel = CodexAppServerPanel(
            workspaceId: UUID(),
            cwd: "/tmp",
            client: client
        )
        await panel.start()

        for method in ["skills/changed", "app/list/updated", "fs/changed", "thread/goal/cleared"] {
            client.onEvent?(
                .notification(CodexAppServerServerNotification(method: method, params: [:]))
            )
        }
        await Task.yield()

        XCTAssertTrue(panel.transcriptItems.isEmpty)
    }

    @MainActor
    func testStaleModelRefreshDoesNotClearCurrentLoadingState() async throws {
        let client = FakeCodexAppServerClient()
        client.holdListModels = true
        let panel = CodexAppServerPanel(
            workspaceId: UUID(),
            cwd: "/tmp",
            client: client
        )

        await panel.start()
        let didStartFirstRefresh = await waitForMainActorCondition {
            client.listModelsCallCount == 1 && panel.isModelListLoading
        }
        XCTAssertTrue(didStartFirstRefresh)

        panel.stop()
        await panel.start()
        let didStartSecondRefresh = await waitForMainActorCondition {
            client.listModelsCallCount == 2 && panel.isModelListLoading
        }
        XCTAssertTrue(didStartSecondRefresh)

        client.finishNextListModels()
        let didFinishStaleRefresh = await waitForMainActorCondition {
            client.pendingListModelsCallCount == 1
        }
        XCTAssertTrue(didFinishStaleRefresh)
        XCTAssertTrue(panel.isModelListLoading)

        client.finishNextListModels()
        let didFinishCurrentRefresh = await waitForMainActorCondition {
            client.pendingListModelsCallCount == 0 && !panel.isModelListLoading
        }
        XCTAssertTrue(didFinishCurrentRefresh)
    }

    @MainActor
    func testInitialCommandOutputDeltaIsTruncated() async throws {
        let client = FakeCodexAppServerClient()
        let panel = CodexAppServerPanel(
            workspaceId: UUID(),
            cwd: "/tmp",
            client: client
        )
        await panel.start()

        let oversizedOutput = String(repeating: "x", count: CodexAppServerTranscriptPolicy.maxItemCharacters + 1_000)
        client.onEvent?(
            .notification(
                CodexAppServerServerNotification(
                    method: "item/commandExecution/outputDelta",
                    params: [
                        "itemId": "command-1",
                        "delta": oversizedOutput,
                    ]
                )
            )
        )
        let didAppendOutput = await waitForMainActorCondition {
            panel.transcriptItems.count == 1
        }
        XCTAssertTrue(didAppendOutput, "Expected command output event to append a transcript item")

        let item = try XCTUnwrap(panel.transcriptItems.first)
        XCTAssertEqual(item.presentation, .commandOutput)
        XCTAssertNotEqual(item.body, oversizedOutput)
        XCTAssertTrue(item.body.contains("Earlier output omitted"))
        XCTAssertTrue(item.body.hasSuffix(String(repeating: "x", count: 1_000)))
    }

    @MainActor
    func testBusyPromptQueuesUntilFirstTurnIdExists() async throws {
        let client = FakeCodexAppServerClient()
        let panel = CodexAppServerPanel(
            workspaceId: UUID(),
            cwd: "/tmp",
            client: client
        )
        await panel.start()
        XCTAssertEqual(panel.status, .ready)

        client.holdStartThread = true
        panel.promptText = "first prompt"
        let firstSend = Task { @MainActor in
            await panel.sendPrompt()
        }
        let didEnterThreadCreation = await waitForMainActorCondition {
            client.startThreadCallCount == 1
        }
        XCTAssertTrue(didEnterThreadCreation, "Expected the first prompt to enter thread creation")
        XCTAssertEqual(panel.status, .running)

        panel.promptText = "second prompt"
        await panel.sendPrompt()

        XCTAssertEqual(client.startThreadCallCount, 1)
        XCTAssertEqual(client.startTurnCalls, [])
        XCTAssertEqual(client.steerTurnCallCount, 0)
        XCTAssertEqual(panel.queuedPrompts.map(\.text), ["second prompt"])

        let firstThreadId = FakeCodexAppServerClient.generatedThreadId(1)
        client.finishStartThread(with: firstThreadId)
        await firstSend.value

        XCTAssertEqual(client.startTurnCalls, [
            FakeCodexAppServerClient.TurnStartCall(threadId: firstThreadId, text: "first prompt"),
        ])
        XCTAssertEqual(panel.queuedPrompts.map(\.text), ["second prompt"])
    }

    @MainActor
    func testQueuedFollowUpDoesNotDrainDuringInitialStartup() async throws {
        let client = FakeCodexAppServerClient()
        client.holdStartAndInitialize = true
        let panel = CodexAppServerPanel(
            workspaceId: UUID(),
            cwd: "/tmp",
            client: client
        )

        panel.promptText = "first prompt"
        let firstSend = Task { @MainActor in
            await panel.sendPrompt()
        }
        let didEnterStartup = await waitForMainActorCondition {
            client.startAndInitializeCallCount == 1
        }
        XCTAssertTrue(didEnterStartup, "Expected first prompt to start Codex app-server initialization")

        panel.promptText = "second prompt"
        await panel.sendPrompt()

        XCTAssertEqual(client.startTurnCalls, [])
        XCTAssertEqual(panel.queuedPrompts.map(\.text), ["second prompt"])

        client.finishStartAndInitialize()
        await firstSend.value

        let firstThreadId = FakeCodexAppServerClient.generatedThreadId(1)
        XCTAssertEqual(client.startTurnCalls, [
            FakeCodexAppServerClient.TurnStartCall(threadId: firstThreadId, text: "first prompt"),
        ])
        XCTAssertEqual(panel.queuedPrompts.map(\.text), ["second prompt"])

        client.onEvent?(
            .notification(CodexAppServerServerNotification(method: "turn/completed", params: [:]))
        )
        let didDrainAfterTurnCompleted = await waitForMainActorCondition {
            client.startTurnCalls.count == 2
        }

        XCTAssertTrue(didDrainAfterTurnCompleted, "Expected queued follow-up to drain after the first turn completed")
        XCTAssertEqual(client.startTurnCalls.last, FakeCodexAppServerClient.TurnStartCall(
            threadId: firstThreadId,
            text: "second prompt"
        ))
    }

    @MainActor
    func testQueuedFollowUpDrainIgnoresDuplicateCompletionUntilSubmittedTurnFinishes() async throws {
        let client = FakeCodexAppServerClient()
        let panel = CodexAppServerPanel(
            workspaceId: UUID(),
            cwd: "/tmp",
            client: client
        )
        await panel.start()

        panel.promptText = "first prompt"
        await panel.sendPrompt()
        panel.promptText = "second prompt"
        panel.queuePromptForNextTurn()
        panel.promptText = "third prompt"
        panel.queuePromptForNextTurn()

        client.onEvent?(
            .notification(CodexAppServerServerNotification(method: "turn/completed", params: [:]))
        )
        client.onEvent?(
            .notification(CodexAppServerServerNotification(method: "turn/completed", params: [:]))
        )

        let didDrainOneFollowUp = await waitForMainActorCondition {
            client.startTurnCalls.count == 2
        }

        XCTAssertTrue(didDrainOneFollowUp, "Expected one queued follow-up to drain after turn completion")
        XCTAssertEqual(client.startTurnCalls.map(\.text), ["first prompt", "second prompt"])
        XCTAssertEqual(panel.queuedPrompts.map(\.text), ["third prompt"])
    }

    @MainActor
    func testChangingQueuedFollowUpToSteerSendsActiveTurnSteer() async throws {
        let client = FakeCodexAppServerClient()
        let panel = CodexAppServerPanel(
            workspaceId: UUID(),
            cwd: "/tmp",
            client: client
        )
        await panel.start()

        panel.promptText = "first prompt"
        await panel.sendPrompt()
        let threadId = FakeCodexAppServerClient.generatedThreadId(1)
        XCTAssertEqual(panel.status, .running)

        panel.promptText = "adjust current turn"
        panel.queuePromptForNextTurn()
        let queuedPrompt = try XCTUnwrap(panel.queuedPrompts.first)

        panel.setQueuedPromptKind(id: queuedPrompt.id, kind: .steer)
        let didSendSteer = await waitForMainActorCondition {
            client.steerTurnCalls.count == 1
        }

        XCTAssertTrue(didSendSteer, "Expected queued follow-up converted to Steer to send turn/steer")
        XCTAssertEqual(client.steerTurnCalls, [
            FakeCodexAppServerClient.SteerCall(
                threadId: threadId,
                turnId: "turn-1",
                text: "adjust current turn"
            ),
        ])
        XCTAssertEqual(panel.queuedPrompts.map(\.kind), [.steer])

        panel.setQueuedPromptKind(id: queuedPrompt.id, kind: .followUp)
        await Task.yield()

        XCTAssertEqual(client.startTurnCalls.count, 1)
        XCTAssertEqual(client.steerTurnCallCount, 1)
        XCTAssertEqual(panel.queuedPrompts.map(\.kind), [.steer])
    }

    @MainActor
    func testPendingSteersCannotBeReorderedAfterSend() async throws {
        let client = FakeCodexAppServerClient()
        let panel = CodexAppServerPanel(
            workspaceId: UUID(),
            cwd: "/tmp",
            client: client
        )
        await panel.start()

        panel.promptText = "first prompt"
        await panel.sendPrompt()
        panel.promptText = "first steer"
        await panel.sendPrompt()
        panel.promptText = "second steer"
        await panel.sendPrompt()

        let didSendSteers = await waitForMainActorCondition {
            client.steerTurnCalls.count == 2
        }
        XCTAssertTrue(didSendSteers, "Expected both steers to be sent")

        let queuedPrompts = panel.queuedPrompts
        XCTAssertEqual(queuedPrompts.map(\.text), ["first steer", "second steer"])
        panel.moveQueuedPrompt(id: queuedPrompts[1].id, before: queuedPrompts[0].id)

        XCTAssertEqual(panel.queuedPrompts.map(\.text), ["first steer", "second steer"])
    }

    @MainActor
    func testPendingSteerEchoRemovesMatchingPromptRegardlessOfPosition() async throws {
        let client = FakeCodexAppServerClient()
        let panel = CodexAppServerPanel(
            workspaceId: UUID(),
            cwd: "/tmp",
            client: client
        )
        await panel.start()

        panel.promptText = "first prompt"
        await panel.sendPrompt()
        panel.promptText = "first steer"
        await panel.sendPrompt()
        panel.promptText = "second steer"
        await panel.sendPrompt()

        let didSendSteers = await waitForMainActorCondition {
            client.steerTurnCalls.count == 2
        }
        XCTAssertTrue(didSendSteers, "Expected both steers to be sent")

        client.onEvent?(
            .notification(CodexAppServerServerNotification(
                method: "userMessage",
                params: [
                    "type": "userMessage",
                    "content": [
                        [
                            "type": "input_text",
                            "text": "second steer",
                        ],
                    ],
                ]
            ))
        )

        let didRemoveMatchingPendingSteer = await waitForMainActorCondition {
            panel.queuedPrompts.map(\.text) == ["first steer"]
        }
        XCTAssertTrue(didRemoveMatchingPendingSteer, "Expected server echo to remove the matching pending steer")
        XCTAssertEqual(panel.queuedPrompts.map(\.text), ["first steer"])
    }

    @MainActor
    func testCodexPromptPrintableRedirectSkipsFocusedControls() {
        XCTAssertFalse(
            CodexPromptPrintableKeyRedirectorView.shouldRedirectPrintableKey(
                firstResponder: NSTextView(frame: .zero)
            )
        )
        XCTAssertFalse(
            CodexPromptPrintableKeyRedirectorView.shouldRedirectPrintableKey(
                firstResponder: NSTextField(frame: .zero)
            )
        )
        XCTAssertFalse(
            CodexPromptPrintableKeyRedirectorView.shouldRedirectPrintableKey(
                firstResponder: NSButton(frame: .zero)
            )
        )

        let button = NSButton(frame: .zero)
        let childView = NSView(frame: .zero)
        button.addSubview(childView)

        XCTAssertFalse(
            CodexPromptPrintableKeyRedirectorView.shouldRedirectPrintableKey(
                firstResponder: childView
            )
        )
        XCTAssertTrue(
            CodexPromptPrintableKeyRedirectorView.shouldRedirectPrintableKey(
                firstResponder: NSView(frame: .zero)
            )
        )
    }

    @MainActor
    private func waitForMainActorCondition(
        timeout: TimeInterval = 1,
        _ condition: @MainActor () -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() {
                return true
            }
            await Task.yield()
        }
        return condition()
    }

    func testResponseObjectUsesJsonRpcResponseShapeWithoutMethod() throws {
        let response = CodexAppServerRequestFactory.response(
            id: 12,
            result: ["decision": "accept"]
        )

        XCTAssertEqual(response["jsonrpc"] as? String, "2.0")
        XCTAssertEqual(response["id"] as? Int, 12)
        XCTAssertNil(response["method"])
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        XCTAssertEqual(result["decision"] as? String, "accept")
    }

    func testErrorResponseCarriesMessage() throws {
        let response = CodexAppServerRequestFactory.errorResponse(
            id: 13,
            message: "unsupported"
        )

        XCTAssertEqual(response["jsonrpc"] as? String, "2.0")
        XCTAssertEqual(response["id"] as? Int, 13)
        let error = try XCTUnwrap(response["error"] as? [String: Any])
        XCTAssertEqual(error["message"] as? String, "unsupported")
        XCTAssertNotNil(error["code"] as? Int)
    }

    func testResponseObjectPreservesStringRequestId() throws {
        let response = CodexAppServerRequestFactory.response(
            id: .string("request-abc"),
            result: ["decision": "accept"]
        )

        XCTAssertEqual(response["jsonrpc"] as? String, "2.0")
        XCTAssertEqual(response["id"] as? String, "request-abc")
    }

    func testRequestIDParserPreservesNumericStringsAsStrings() throws {
        XCTAssertEqual(CodexAppServerClient.requestID(from: "42"), .string("42"))
        XCTAssertEqual(CodexAppServerClient.requestID(from: " request-abc "), .string("request-abc"))
        XCTAssertEqual(CodexAppServerClient.requestID(from: 42), .int(42))
        XCTAssertNil(CodexAppServerClient.requestID(from: " "))
        XCTAssertNil(CodexAppServerClient.requestID(from: NSNumber(value: true)))
    }

    func testPanelResolvedRequestIDParserPreservesNumericStringsAsStrings() {
        XCTAssertEqual(
            CodexAppServerPanel.requestIDValue(named: "id", in: ["id": "01"]),
            .string("01")
        )
        XCTAssertEqual(
            CodexAppServerPanel.requestIDValue(named: "id", in: ["id": 1]),
            .int(1)
        )
        XCTAssertNil(CodexAppServerPanel.requestIDValue(named: "id", in: ["id": true]))
    }

    func testAppServerEnvironmentIncludesNodeVersionManagerPaths() throws {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-codex-app-server-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let nvmNodeBin = tempDirectory
            .appendingPathComponent(".nvm/versions/node/v25.8.1/bin", isDirectory: true)
        try FileManager.default.createDirectory(at: nvmNodeBin, withIntermediateDirectories: true)

        let environment = CodexAppServerClient.appServerEnvironment(
            baseEnvironment: [
                "HOME": tempDirectory.path,
                "PATH": "/usr/bin:/bin",
            ]
        )

        let pathComponents = try XCTUnwrap(environment["PATH"]).split(separator: ":").map(String.init)
        XCTAssertTrue(pathComponents.contains(nvmNodeBin.path))
    }

    func testLaunchConfigurationUsesResolvedProviderExecutableWithoutChangingArguments() throws {
        let fileManager = FileManager.default
        let tempDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-codex-launch-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: tempDirectory) }

        let codexBin = tempDirectory.appendingPathComponent("codex-bin", isDirectory: true)
        let nodeBin = tempDirectory.appendingPathComponent(".nvm/versions/node/v25.8.1/bin", isDirectory: true)
        try fileManager.createDirectory(at: codexBin, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: nodeBin, withIntermediateDirectories: true)

        let codexPath = codexBin.appendingPathComponent("codex")
        let nodePath = nodeBin.appendingPathComponent("node")
        try "#!/usr/bin/env node\n".write(to: codexPath, atomically: true, encoding: .utf8)
        try "#!/bin/sh\n".write(to: nodePath, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: codexPath.path)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: nodePath.path)

        let configuration = try CodexAppServerClient.appServerLaunchConfiguration(
            baseEnvironment: [
                "HOME": tempDirectory.path,
                "PATH": codexBin.path,
            ]
        )

        XCTAssertEqual(configuration.executablePath, codexPath.path)
        XCTAssertEqual(configuration.arguments, AgentSessionProvider.provider(.codex).launchPlan.arguments)
        let pathComponents = try XCTUnwrap(configuration.environment["PATH"]).split(separator: ":").map(String.init)
        XCTAssertTrue(pathComponents.contains(nodeBin.path))
    }

    func testClientStartThrowsMissingProviderErrorBeforeProcessSpawn() throws {
        let fileManager = FileManager.default
        let tempDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-missing-provider-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: tempDirectory) }

        let binDirectory = tempDirectory.appendingPathComponent("bin", isDirectory: true)
        try fileManager.createDirectory(at: binDirectory, withIntermediateDirectories: true)
        let missingName = "cmux-missing-codex-\(UUID().uuidString)"
        let provider = AgentSessionProvider(
            id: .codex,
            displayName: "Codex",
            transport: .stdioJSONRPC,
            unixSocketSupport: .notApplicable,
            launchPlan: AgentSessionLaunchPlan(
                executableName: missingName,
                arguments: ["app-server", "--listen", "stdio://"]
            )
        )
        let client = CodexAppServerClient(
            provider: provider,
            executableResolver: AgentExecutableResolver(baseEnvironment: [
                "HOME": tempDirectory.path,
                "PATH": binDirectory.path,
            ])
        )

        XCTAssertThrowsError(try client.start()) { error in
            guard case let AgentExecutableResolverError.missingExecutable(
                providerID,
                providerName,
                executableName,
                _
            ) = error else {
                return XCTFail("Expected structured missing executable error, got \(error)")
            }

            XCTAssertEqual(providerID, .codex)
            XCTAssertEqual(providerName, "Codex")
            XCTAssertEqual(executableName, missingName)
        }
    }

    func testStopThenReleaseDoesNotCrashWhenLastReferenceDropsOnStateQueue() throws {
        weak var weakClient: CodexAppServerClient?

        do {
            var client: CodexAppServerClient? = CodexAppServerClient()
            weakClient = client
            client?.stop()
            client = nil
        }

        let deadline = Date().addingTimeInterval(2)
        while weakClient != nil, Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        XCTAssertNil(weakClient)
    }

    func testLineBufferFramesLinesAcrossLargeChunks() throws {
        var buffer = CodexAppServerLineBuffer()

        XCTAssertTrue(buffer.append(Data(repeating: 65, count: 32_768)).isEmpty)
        XCTAssertEqual(buffer.bufferedByteCount, 32_768)

        let lines = buffer.append(Data([0x0A, 66, 0x0A]))

        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(lines[0].count, 32_768)
        XCTAssertEqual(String(data: lines[1], encoding: .utf8), "B")
        XCTAssertEqual(buffer.bufferedByteCount, 0)
    }

    func testLineBufferReturnsFinalLineWithoutTrailingNewline() throws {
        var buffer = CodexAppServerLineBuffer()

        XCTAssertTrue(buffer.append(Data("partial".utf8)).isEmpty)

        let finalLine = try XCTUnwrap(buffer.finish())
        XCTAssertEqual(String(data: finalLine, encoding: .utf8), "partial")
        XCTAssertNil(buffer.finish())
    }

    func testJSONWarningStderrLinesRenderAsWarningTranscriptItems() throws {
        let text = """
        {"level":"WARN","fields":{"message":"Warning: ignoring interface.defaultPrompt because it is not supported"},"target":"codex_core_plugins::manifest"}
        {"level":"WARNING","fields":{"message":"using fallback model"},"target":"codex_core::config"}
        """

        let items = CodexAppServerTranscriptPolicy.transcriptItems(
            fromStderr: text,
            date: Date(timeIntervalSince1970: 1)
        )

        XCTAssertEqual(items.count, 2)
        XCTAssertTrue(items.allSatisfy { $0.role == .event })
        XCTAssertTrue(items.allSatisfy { $0.presentation == .warning })
        XCTAssertEqual(items.map(\.title), ["Warning", "Warning"])
        XCTAssertEqual(
            items.map(\.body),
            [
                "ignoring interface.defaultPrompt because it is not supported",
                "using fallback model",
            ]
        )
        XCTAssertFalse(items.contains { $0.body.contains(#""level""#) })
    }

    func testMixedWarningStderrKeepsNonWarningTextAsStderr() throws {
        let text = """
        booting app-server
        {"level":"INFO","fields":{"message":"ready"},"target":"codex_core"}
        {"level":"WARN","fields":{"message":"ignoring interface.defaultPrompt"},"target":"codex_core_plugins::manifest"}
        """

        let items = CodexAppServerTranscriptPolicy.transcriptItems(
            fromStderr: text,
            date: Date(timeIntervalSince1970: 1)
        )

        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items[0].role, .stderr)
        XCTAssertEqual(
            items[0].body,
            "booting app-server\n{\"level\":\"INFO\",\"fields\":{\"message\":\"ready\"},\"target\":\"codex_core\"}\n"
        )
        XCTAssertEqual(items[1].role, .event)
        XCTAssertEqual(items[1].presentation, .warning)
        XCTAssertEqual(items[1].body, "ignoring interface.defaultPrompt")
    }

    func testWarningStderrBufferHandlesSplitJSONLine() throws {
        var buffer = CodexAppServerStderrTranscriptBuffer()

        XCTAssertTrue(buffer.append(#"{"level":"WARN","fields":{"message":"Warning: ignored"#).isEmpty)
        let items = buffer.append(#" interface.defaultPrompt"},"target":"codex_core_plugins::manifest"}"# + "\n")

        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].role, .event)
        XCTAssertEqual(items[0].presentation, .warning)
        XCTAssertEqual(items[0].body, "ignored interface.defaultPrompt")
    }

    func testWarningStderrBufferFlushesPartialNonWarningText() throws {
        var buffer = CodexAppServerStderrTranscriptBuffer()

        XCTAssertTrue(buffer.append("partial stderr").isEmpty)
        let items = buffer.flush(date: Date(timeIntervalSince1970: 1))

        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].role, .stderr)
        XCTAssertEqual(items[0].body, "partial stderr")
    }

    func testWarningStderrBufferDoesNotEmitBlankItemForSplitCRLF() throws {
        var buffer = CodexAppServerStderrTranscriptBuffer()

        XCTAssertTrue(buffer.append(#"{"level":"WARN","fields":{"message":"split crlf"}}"# + "\r").isEmpty)
        let items = buffer.append("\n")

        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].role, .event)
        XCTAssertEqual(items[0].presentation, .warning)
        XCTAssertEqual(items[0].body, "split crlf")
    }

    func testCodexStateDBReadRepairWarningsAreSuppressed() throws {
        let text = """
        {"timestamp":"2026-05-08T20:33:51.525981Z","level":"WARN","fields":{"message":"state db discrepancy during find_thread_path_by_id_str_in_subdir: falling_back"},"target":"codex_rollout::list"}
        {"timestamp":"2026-05-08T20:33:51.526485Z","level":"WARN","fields":{"message":"state db discrepancy during read_repair_rollout_path: upsert_needed (slow path)"},"target":"codex_rollout::state_db"}
        """

        let items = CodexAppServerTranscriptPolicy.transcriptItems(
            fromStderr: text,
            date: Date(timeIntervalSince1970: 1)
        )

        XCTAssertTrue(items.isEmpty)
    }

    @MainActor
    func testReasoningSummaryPreservesInlineBoldMarkdown() async throws {
        let client = FakeCodexAppServerClient()
        let panel = CodexAppServerPanel(
            workspaceId: UUID(),
            cwd: "/tmp",
            client: client
        )
        await panel.start()

        client.onEvent?(
            .notification(CodexAppServerServerNotification(
                method: "item/completed",
                params: [
                    "item": [
                        "id": "reasoning-1",
                        "type": "reasoning",
                        "summary": "We considered **two options** and chose A",
                    ],
                ]
            ))
        )

        let didAppendReasoning = await waitForMainActorCondition {
            panel.transcriptItems.count == 1
        }

        XCTAssertTrue(didAppendReasoning, "Expected completed reasoning item to append")
        XCTAssertEqual(panel.transcriptItems.first?.body, "We considered **two options** and chose A")
    }

    @MainActor
    func testReasoningSummaryPreservesLeadingBoldProse() async throws {
        let client = FakeCodexAppServerClient()
        let panel = CodexAppServerPanel(
            workspaceId: UUID(),
            cwd: "/tmp",
            client: client
        )
        await panel.start()

        client.onEvent?(
            .notification(CodexAppServerServerNotification(
                method: "item/completed",
                params: [
                    "item": [
                        "id": "reasoning-1",
                        "type": "reasoning",
                        "summary": "**Option A** is best",
                    ],
                ]
            ))
        )

        let didAppendReasoning = await waitForMainActorCondition {
            panel.transcriptItems.count == 1
        }

        XCTAssertTrue(didAppendReasoning, "Expected completed reasoning item to append")
        XCTAssertEqual(panel.transcriptItems.first?.body, "**Option A** is best")
    }

    func testLocalCodexHistoryLoaderPreservesInlineBoldInReasoningSummary() throws {
        let fileManager = FileManager.default
        let threadId = "019d6637-e5cc-7cc0-a321-2c43b7990371"
        let tempDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-codex-history-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: tempDirectory) }

        let sessionDirectory = tempDirectory
            .appendingPathComponent("2026/04/06", isDirectory: true)
        try fileManager.createDirectory(at: sessionDirectory, withIntermediateDirectories: true)
        let fileURL = sessionDirectory
            .appendingPathComponent("rollout-2026-04-06T21-33-52-\(threadId).jsonl")

        let records: [[String: Any]] = [
            [
                "timestamp": "2026-04-06T21:33:52.000Z",
                "type": "session_meta",
                "payload": ["id": threadId],
            ],
            [
                "timestamp": "2026-04-06T21:34:00.000Z",
                "type": "response_item",
                "payload": [
                    "type": "reasoning",
                    "summary": "We considered **two options** and chose A",
                ],
            ],
        ]
        let jsonl = try records.map(Self.jsonLine).joined(separator: "\n")
        try jsonl.write(to: fileURL, atomically: true, encoding: .utf8)

        let snapshot = CodexSessionHistoryLoader.loadHistorySync(
            threadId: threadId,
            limit: 10,
            searchRoots: [tempDirectory]
        )

        XCTAssertEqual(snapshot.transcriptItems.map(\.presentation), [.reasoning])
        XCTAssertEqual(snapshot.transcriptItems.map(\.body), ["We considered **two options** and chose A"])
    }

    func testLocalCodexHistoryLoaderPreservesLeadingBoldReasoningProse() throws {
        let fileManager = FileManager.default
        let threadId = "019d6637-e5cc-7cc0-a321-2c43b7990371"
        let tempDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-codex-history-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: tempDirectory) }

        let sessionDirectory = tempDirectory
            .appendingPathComponent("2026/04/06", isDirectory: true)
        try fileManager.createDirectory(at: sessionDirectory, withIntermediateDirectories: true)
        let fileURL = sessionDirectory
            .appendingPathComponent("rollout-2026-04-06T21-33-52-\(threadId).jsonl")

        let records: [[String: Any]] = [
            [
                "timestamp": "2026-04-06T21:33:52.000Z",
                "type": "session_meta",
                "payload": ["id": threadId],
            ],
            [
                "timestamp": "2026-04-06T21:34:00.000Z",
                "type": "response_item",
                "payload": [
                    "type": "reasoning",
                    "summary": "**Option A** is best",
                ],
            ],
        ]
        let jsonl = try records.map(Self.jsonLine).joined(separator: "\n")
        try jsonl.write(to: fileURL, atomically: true, encoding: .utf8)

        let snapshot = CodexSessionHistoryLoader.loadHistorySync(
            threadId: threadId,
            limit: 10,
            searchRoots: [tempDirectory]
        )

        XCTAssertEqual(snapshot.transcriptItems.map(\.presentation), [.reasoning])
        XCTAssertEqual(snapshot.transcriptItems.map(\.body), ["**Option A** is best"])
    }

    func testStreamingFadeStateDoesNotRestartWhileStreamRemainsActive() {
        var state = CodexStreamingFadeState()
        let streamID = "assistant-stream"
        let duration = 0.18

        state.updateActiveStreamingIDs(Set([streamID]), now: 0)
        XCTAssertLessThan(state.alpha(for: streamID, now: 0, duration: duration), 1)

        state.pruneExpired(now: 0.2, duration: duration)
        XCTAssertEqual(state.alpha(for: streamID, now: 0.2, duration: duration), 1)

        state.updateActiveStreamingIDs(Set([streamID]), now: 0.21)
        XCTAssertEqual(state.alpha(for: streamID, now: 0.21, duration: duration), 1)

        state.updateActiveStreamingIDs([], now: 0.22)
        state.updateActiveStreamingIDs(Set([streamID]), now: 0.23)
        XCTAssertLessThan(state.alpha(for: streamID, now: 0.23, duration: duration), 1)
    }

    func testLocalCodexHistoryLoaderRestoresTailFromJsonl() throws {
        let fileManager = FileManager.default
        let threadId = "019d6637-e5cc-7cc0-a321-2c43b799036b"
        let tempDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-codex-history-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: tempDirectory) }

        let sessionDirectory = tempDirectory
            .appendingPathComponent("2026/04/06", isDirectory: true)
        try fileManager.createDirectory(at: sessionDirectory, withIntermediateDirectories: true)
        let fileURL = sessionDirectory
            .appendingPathComponent("rollout-2026-04-06T21-33-52-\(threadId).jsonl")

        let records: [[String: Any]] = [
            [
                "timestamp": "2026-04-06T21:33:52.000Z",
                "type": "session_meta",
                "payload": ["id": threadId],
            ],
            [
                "timestamp": "2026-04-06T21:33:53.000Z",
                "type": "event_msg",
                "payload": [
                    "type": "user_message",
                    "message": "user 1",
                ],
            ],
            Self.responseItem(role: "developer", text: "skip developer instructions"),
            Self.responseItem(
                role: "user",
                text: "Warning: The maximum number of unified exec processes you can keep open is 60 and you currently have 61 processes open. Reuse older processes or close them to prevent automatic pruning of old processes"
            ),
            Self.responseItem(role: "assistant", text: "agent 1"),
            [
                "timestamp": "2026-04-06T21:34:03.000Z",
                "type": "response_item",
                "payload": [
                    "type": "function_call",
                    "name": "exec_command",
                    "arguments": "{\"cmd\":\"ls -la\"}",
                ],
            ],
            [
                "timestamp": "2026-04-06T21:34:04.000Z",
                "type": "response_item",
                "payload": [
                    "type": "function_call_output",
                    "call_id": "call_1",
                    "output": "output text",
                ],
            ],
            Self.responseItem(role: "assistant", text: "agent 2"),
        ]
        let jsonl = try records.map(Self.jsonLine).joined(separator: "\n")
        try jsonl.write(to: fileURL, atomically: true, encoding: .utf8)

        let snapshot = CodexSessionHistoryLoader.loadHistorySync(
            threadId: threadId,
            limit: 3,
            searchRoots: [tempDirectory]
        )

        XCTAssertEqual(snapshot.fileURL?.resolvingSymlinksInPath(), fileURL.resolvingSymlinksInPath())
        XCTAssertEqual(snapshot.totalDisplayableItemCount, 5)
        XCTAssertTrue(snapshot.didTruncate)
        XCTAssertEqual(snapshot.transcriptItems.map(\.role), [.event, .event, .assistant])
        XCTAssertEqual(snapshot.transcriptItems.map(\.body), ["ls -la", "output text", "agent 2"])
        XCTAssertEqual(snapshot.transcriptItems.map(\.presentation), [
            .toolCall(name: "exec_command"),
            .toolOutput,
            .plain,
        ])
    }

    func testLocalCodexHistoryLoaderTailParsesLargeJsonlWithoutExactTotal() throws {
        let fileManager = FileManager.default
        let threadId = "019d6637-e5cc-7cc0-a321-2c43b799036d"
        let tempDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-codex-history-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: tempDirectory) }

        let sessionDirectory = tempDirectory
            .appendingPathComponent("2026/04/06", isDirectory: true)
        try fileManager.createDirectory(at: sessionDirectory, withIntermediateDirectories: true)
        let fileURL = sessionDirectory
            .appendingPathComponent("rollout-2026-04-06T21-33-52-\(threadId).jsonl")

        var records: [[String: Any]] = [
            [
                "timestamp": "2026-04-06T21:33:52.000Z",
                "type": "session_meta",
                "payload": ["id": threadId],
            ],
        ]
        for index in 0..<80 {
            records.append(Self.responseItem(role: "assistant", text: "old \(index) " + String(repeating: "x", count: 80)))
        }
        records.append(Self.responseItem(role: "assistant", text: "new 1"))
        records.append(Self.responseItem(role: "assistant", text: "new 2"))
        records.append(Self.responseItem(role: "assistant", text: "new 3"))

        let jsonl = try records.map(Self.jsonLine).joined(separator: "\n")
        try jsonl.write(to: fileURL, atomically: true, encoding: .utf8)

        let snapshot = CodexSessionHistoryLoader.loadHistorySync(
            threadId: threadId,
            limit: 2,
            searchRoots: [tempDirectory],
            tailParsingThreshold: 1,
            tailInitialReadLimit: 768,
            tailMaxReadLimit: 768
        )

        XCTAssertEqual(snapshot.transcriptItems.map(\.body), ["new 2", "new 3"])
        XCTAssertTrue(snapshot.didTruncate)
        XCTAssertFalse(snapshot.totalDisplayableItemCountIsExact)
        XCTAssertGreaterThan(snapshot.totalDisplayableItemCount, snapshot.transcriptItems.count)
    }

    func testLocalCodexHistoryLoaderTailReportsExactTotalAtLimitWhenFullFileWasRead() throws {
        let fileManager = FileManager.default
        let threadId = "019d6637-e5cc-7cc0-a321-2c43b799036f"
        let tempDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-codex-history-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: tempDirectory) }

        let sessionDirectory = tempDirectory
            .appendingPathComponent("2026/04/06", isDirectory: true)
        try fileManager.createDirectory(at: sessionDirectory, withIntermediateDirectories: true)
        let fileURL = sessionDirectory
            .appendingPathComponent("rollout-2026-04-06T21-33-52-\(threadId).jsonl")

        let records: [[String: Any]] = [
            [
                "timestamp": "2026-04-06T21:33:52.000Z",
                "type": "session_meta",
                "payload": ["id": threadId],
            ],
            Self.responseItem(role: "assistant", text: "first"),
            Self.responseItem(role: "assistant", text: "second"),
        ]

        let jsonl = try records.map(Self.jsonLine).joined(separator: "\n")
        try jsonl.write(to: fileURL, atomically: true, encoding: .utf8)

        let snapshot = CodexSessionHistoryLoader.loadHistorySync(
            threadId: threadId,
            limit: 2,
            searchRoots: [tempDirectory],
            tailParsingThreshold: 1,
            tailInitialReadLimit: 16 * 1024,
            tailMaxReadLimit: 16 * 1024
        )

        XCTAssertEqual(snapshot.transcriptItems.map(\.body), ["first", "second"])
        XCTAssertEqual(snapshot.totalDisplayableItemCount, 2)
        XCTAssertTrue(snapshot.totalDisplayableItemCountIsExact)
        XCTAssertFalse(snapshot.didTruncate)
    }

    func testLocalCodexHistoryLoaderPreservesISO8601Timestamps() throws {
        let fileManager = FileManager.default
        let threadId = "019d6637-e5cc-7cc0-a321-2c43b7990370"
        let tempDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-codex-history-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: tempDirectory) }

        let sessionDirectory = tempDirectory
            .appendingPathComponent("2026/04/06", isDirectory: true)
        try fileManager.createDirectory(at: sessionDirectory, withIntermediateDirectories: true)
        let fileURL = sessionDirectory
            .appendingPathComponent("rollout-2026-04-06T21-33-52-\(threadId).jsonl")

        let expectedTimestamp = "2026-04-06T03:02:30.747Z"
        let records: [[String: Any]] = [
            [
                "timestamp": "2026-04-06T03:02:29.000Z",
                "type": "session_meta",
                "payload": ["id": threadId],
            ],
            [
                "timestamp": expectedTimestamp,
                "type": "response_item",
                "payload": [
                    "type": "message",
                    "role": "assistant",
                    "content": [
                        [
                            "type": "output_text",
                            "text": "timestamped reply",
                        ],
                    ],
                ],
            ],
        ]

        let jsonl = try records.map(Self.jsonLine).joined(separator: "\n")
        try jsonl.write(to: fileURL, atomically: true, encoding: .utf8)

        let snapshot = CodexSessionHistoryLoader.loadHistorySync(
            threadId: threadId,
            limit: 10,
            searchRoots: [tempDirectory]
        )

        let expectedFormatter = ISO8601DateFormatter()
        expectedFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let expectedDate = try XCTUnwrap(expectedFormatter.date(from: expectedTimestamp))
        let restoredDate = try XCTUnwrap(snapshot.transcriptItems.first?.date)
        XCTAssertEqual(snapshot.transcriptItems.map(\.body), ["timestamped reply"])
        XCTAssertEqual(restoredDate.timeIntervalSince1970, expectedDate.timeIntervalSince1970, accuracy: 0.001)
    }

    func testLocalCodexHistoryLoaderIgnoresPlainUserResponseWarnings() throws {
        let fileManager = FileManager.default
        let threadId = "019d6637-e5cc-7cc0-a321-2c43b799036e"
        let tempDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-codex-history-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: tempDirectory) }

        let sessionDirectory = tempDirectory
            .appendingPathComponent("2026/04/06", isDirectory: true)
        try fileManager.createDirectory(at: sessionDirectory, withIntermediateDirectories: true)
        let fileURL = sessionDirectory
            .appendingPathComponent("rollout-2026-04-06T21-33-52-\(threadId).jsonl")

        let records: [[String: Any]] = [
            [
                "timestamp": "2026-04-06T21:33:52.000Z",
                "type": "session_meta",
                "payload": ["id": threadId],
            ],
            [
                "timestamp": "2026-04-06T21:34:00.000Z",
                "type": "event_msg",
                "payload": [
                    "type": "user_message",
                    "message": "actual user prompt",
                ],
            ],
            Self.responseItem(
                role: "user",
                text: "Warning: apply_patch was requested via exec_command. Use the apply_patch tool instead of exec_command."
            ),
            Self.responseItem(role: "assistant", text: "agent reply"),
        ]
        let jsonl = try records.map(Self.jsonLine).joined(separator: "\n")
        try jsonl.write(to: fileURL, atomically: true, encoding: .utf8)

        let snapshot = CodexSessionHistoryLoader.loadHistorySync(
            threadId: threadId,
            limit: 10,
            searchRoots: [tempDirectory]
        )

        XCTAssertEqual(snapshot.totalDisplayableItemCount, 2)
        XCTAssertEqual(snapshot.transcriptItems.map(\.role), [.user, .assistant])
        XCTAssertEqual(snapshot.transcriptItems.map(\.body), ["actual user prompt", "agent reply"])
    }

    func testLocalCodexHistoryLoaderRestoresCodexErrorEventsFromJsonl() throws {
        let fileManager = FileManager.default
        let threadId = "019d6637-e5cc-7cc0-a321-2c43b799036f"
        let tempDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-codex-history-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: tempDirectory) }

        let sessionDirectory = tempDirectory
            .appendingPathComponent("2026/04/06", isDirectory: true)
        try fileManager.createDirectory(at: sessionDirectory, withIntermediateDirectories: true)
        let fileURL = sessionDirectory
            .appendingPathComponent("rollout-2026-04-06T21-33-52-\(threadId).jsonl")

        let records: [[String: Any]] = [
            [
                "timestamp": "2026-04-06T21:33:52.000Z",
                "type": "session_meta",
                "payload": ["id": threadId],
            ],
            [
                "timestamp": "2026-04-06T21:34:00.000Z",
                "type": "event_msg",
                "payload": [
                    "type": "error",
                    "message": "You've hit your usage limit.",
                    "codex_error_info": "usage_limit_exceeded",
                ],
            ],
        ]
        let jsonl = try records.map(Self.jsonLine).joined(separator: "\n")
        try jsonl.write(to: fileURL, atomically: true, encoding: .utf8)

        let snapshot = CodexSessionHistoryLoader.loadHistorySync(
            threadId: threadId,
            limit: 10,
            searchRoots: [tempDirectory]
        )
        let item = try XCTUnwrap(snapshot.transcriptItems.first)

        XCTAssertEqual(snapshot.totalDisplayableItemCount, 1)
        XCTAssertEqual(item.role, .error)
        XCTAssertEqual(item.title, "Usage limit reached")
        XCTAssertEqual(item.body, "You've hit your usage limit.")
    }

    func testLocalCodexHistoryLoaderRestoresCustomToolsAndCompactionsFromJsonl() throws {
        let fileManager = FileManager.default
        let threadId = "019d6637-e5cc-7cc0-a321-2c43b799036c"
        let tempDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-codex-history-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: tempDirectory) }

        let sessionDirectory = tempDirectory
            .appendingPathComponent("2026/04/06", isDirectory: true)
        try fileManager.createDirectory(at: sessionDirectory, withIntermediateDirectories: true)
        let fileURL = sessionDirectory
            .appendingPathComponent("rollout-2026-04-06T21-33-52-\(threadId).jsonl")

        let patch = """
        *** Begin Patch
        *** Update File: ci.yml
        @@
        -old
        +new
        *** End Patch
        """
        let records: [[String: Any]] = [
            [
                "timestamp": "2026-04-06T21:33:52.000Z",
                "type": "session_meta",
                "payload": ["id": threadId],
            ],
            [
                "timestamp": "2026-04-06T21:34:00.000Z",
                "type": "event_msg",
                "payload": ["type": "context_compacted"],
            ],
            [
                "timestamp": "2026-04-06T21:34:01.000Z",
                "type": "response_item",
                "payload": [
                    "type": "custom_tool_call",
                    "name": "apply_patch",
                    "input": patch,
                ],
            ],
            [
                "timestamp": "2026-04-06T21:34:02.000Z",
                "type": "response_item",
                "payload": [
                    "type": "function_call",
                    "name": "web.run",
                    "arguments": """
                    {"search_query":[{"q":"actions/checkout v5 Node 24 GitHub Actions 2026"},{"q":"Swatinem rust-cache GitHub action Node 24 v3 2026"}]}
                    """,
                ],
            ],
        ]
        let jsonl = try records.map(Self.jsonLine).joined(separator: "\n")
        try jsonl.write(to: fileURL, atomically: true, encoding: .utf8)

        let snapshot = CodexSessionHistoryLoader.loadHistorySync(
            threadId: threadId,
            limit: 10,
            searchRoots: [tempDirectory]
        )

        XCTAssertEqual(snapshot.totalDisplayableItemCount, 3)
        XCTAssertEqual(snapshot.transcriptItems.map(\.presentation), [
            .compaction,
            .toolCall(name: "apply_patch"),
            .toolCall(name: "web.run"),
        ])
        XCTAssertEqual(snapshot.transcriptItems[0].title, "Context automatically compacted")
        XCTAssertTrue(snapshot.transcriptItems[1].body.contains("*** Update File: ci.yml"))
        XCTAssertTrue(snapshot.transcriptItems[2].body.contains("Node 24 GitHub Actions 2026"))
    }

    func testTrajectoryTranscriptEntriesSummarizeEditedCommandsAndWebSearches() {
        let patch = """
        *** Begin Patch
        *** Update File: ci.yml
        @@
        -a
        -b
        +c
        +d
        *** End Patch
        """
        let entries = CodexTrajectoryTranscriptDisplayEntry.entries(from: [
            Self.transcriptToolCall(name: "apply_patch", body: patch),
            Self.transcriptToolCall(name: "exec_command", body: "git diff -- .github/workflows/ci.yml"),
            Self.transcriptToolCall(name: "exec_command", body: "git status --short --branch"),
            Self.transcriptToolCall(
                name: "web.run",
                body: #"{"search_query":[{"q":"actions/checkout v5 Node 24 GitHub Actions 2026"},{"q":"Swatinem rust-cache GitHub action Node 24 v3 2026"}]}"#
            ),
        ])

        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].kind, .toolGroup)
        XCTAssertEqual(entries[0].title, "Edited 1 file, ran 2 commands, searched web 2 times")
        XCTAssertTrue(entries[0].block.text.contains("Edited ci.yml +2 -2"))
        XCTAssertTrue(entries[0].block.text.contains("Ran git diff -- .github/workflows/ci.yml"))
        XCTAssertTrue(entries[0].block.text.contains("actions/checkout v5 Node 24 GitHub Actions 2026"))
    }

    func testTrajectoryTranscriptEntriesSummarizeExplorationAndWebSearches() {
        let entries = CodexTrajectoryTranscriptDisplayEntry.entries(from: [
            Self.transcriptToolCall(name: "exec_command", body: "sed -n '1,20p' ci.yml"),
            Self.transcriptToolCall(name: "exec_command", body: #"rg "zig|ZIG|cargo-zigbuild|setup-zig|cclib|ghostty" ."#),
            Self.transcriptToolCall(name: "exec_command", body: "rg --files"),
            Self.transcriptToolCall(name: "exec_command", body: "gh run view 24777233613 --repo manaflow-ai/cmux-cli --log-failed"),
            Self.transcriptToolCall(name: "exec_command", body: "git status --short --branch"),
            Self.transcriptToolCall(name: "exec_command", body: "cargo metadata --no-deps --format-version 1"),
            Self.transcriptToolCall(name: "exec_command", body: "gh run watch --repo manaflow-ai/cmux-cli 24777233613 --interval 5"),
            Self.transcriptToolCall(name: "exec_command", body: "gh run view 24777233613 --repo manaflow-ai/cmux-cli --log-failed"),
            Self.transcriptToolCall(
                name: "web.run",
                body: #"{"search_query":[{"q":"actions/checkout v5 Node 24 GitHub Actions 2026"},{"q":"Swatinem rust-cache GitHub action Node 24 v3 2026"}]}"#
            ),
        ])

        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].title, "Explored 1 file, 1 search, 1 list, ran 5 commands, searched web 2 times")
        XCTAssertTrue(entries[0].block.text.contains("Read ci.yml"))
        XCTAssertTrue(entries[0].block.text.contains("Searched for zig|ZIG|cargo-zigbuild|setup-zig|cclib|ghostty in ."))
        XCTAssertTrue(entries[0].block.text.contains("Listed files"))
    }

    func testTrajectoryTranscriptEntriesRenderWebOnlyAndCompactionRows() {
        let webEntries = CodexTrajectoryTranscriptDisplayEntry.entries(from: [
            Self.transcriptToolCall(
                name: "web.run",
                body: #"{"search_query":[{"q":"actions/checkout v5 Node 24 GitHub Actions 2026"},{"q":"Swatinem rust-cache GitHub action Node 24 v3 2026"}]}"#
            ),
        ])
        XCTAssertEqual(webEntries.count, 1)
        XCTAssertEqual(webEntries[0].title, "Searched web 2 times")
        XCTAssertTrue(webEntries[0].block.text.contains("actions/checkout v5 Node 24 GitHub Actions 2026"))

        let compactionEntries = CodexTrajectoryTranscriptDisplayEntry.entries(from: [
            CodexAppServerTranscriptItem(
                role: .event,
                title: "Context automatically compacted",
                body: "",
                presentation: .compaction
            ),
        ])
        XCTAssertEqual(compactionEntries.count, 1)
        XCTAssertEqual(compactionEntries[0].kind, .compaction)
        XCTAssertEqual(compactionEntries[0].title, "Context automatically compacted")
    }

    func testTrajectoryTranscriptEntriesSummarizeHookEvents() {
        let started = """
        {
          "run": {
            "command": "/Users/lawrence/.codex/hooks.json",
            "displayOrder": 8,
            "eventName": "stop",
            "sourcePath": "/Users/lawrence/.codex/hooks.json",
            "status": "running"
          },
          "threadId": "019d6637-e5cc-7cc0-a321-2c43b799036b"
        }
        """
        let completed = """
        {
          "run": {
            "durationMs": 42,
            "eventName": "stop",
            "status": "completed"
          },
          "threadId": "019d6637-e5cc-7cc0-a321-2c43b799036b"
        }
        """

        let entries = CodexTrajectoryTranscriptDisplayEntry.entries(from: [
            Self.transcriptHook(method: "hook/started", body: started),
            Self.transcriptHook(method: "hook/completed", body: completed),
        ])

        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].kind, .toolGroup)
        XCTAssertEqual(entries[0].title, "2 hook events")
        XCTAssertTrue(entries[0].block.text.contains("Started hook stop"))
        XCTAssertTrue(entries[0].block.text.contains("Completed hook stop"))
    }

    func testRateLimitSummaryParsesPrimaryAndSecondaryWindows() throws {
        let summary = try XCTUnwrap(
            CodexAppServerRateLimitSummary(params: [
                "rateLimits": [
                    "primary": [
                        "usedPercent": 11,
                        "resetsAt": 1_777_354_261,
                        "windowDurationMins": 300,
                    ],
                    "secondary": [
                        "usedPercent": 2,
                        "resetsAt": 1_777_941_061,
                        "windowDurationMins": 10_080,
                    ],
                ],
            ])
        )

        let primary = try XCTUnwrap(summary.primary)
        let secondary = try XCTUnwrap(summary.secondary)
        XCTAssertEqual(primary.displayPercent, "11%")
        XCTAssertEqual(secondary.displayPercent, "2%")
        XCTAssertEqual(primary.windowDurationMins, 300)
        XCTAssertEqual(secondary.clampedUsedFraction, 0.02, accuracy: 0.001)
    }

    @MainActor
    func testResumeSnapshotCapsRestoredTranscriptToTailItems() throws {
        let turns: [[String: Any]] = (0..<3).map { index in
            [
                "startedAt": index,
                "items": [
                    [
                        "type": "userMessage",
                        "content": [
                            [
                                "type": "text",
                                "text": "user \(index)",
                            ],
                        ],
                    ],
                    [
                        "type": "agentMessage",
                        "text": "agent \(index)",
                    ],
                ],
            ]
        }
        let response: [String: Any] = [
            "cwd": "/Users/cmux/project",
            "thread": [
                "id": "thread-123",
                "turns": turns,
            ],
        ]

        let snapshot = CodexAppServerPanel.resumeSnapshot(
            from: response,
            fallbackThreadId: "fallback-thread",
            restoredItemLimit: 3
        )

        XCTAssertEqual(snapshot.threadId, "thread-123")
        XCTAssertEqual(snapshot.cwd, "/Users/cmux/project")
        XCTAssertEqual(snapshot.totalRestoredItemCount, 6)
        XCTAssertTrue(snapshot.didTruncate)
        XCTAssertFalse(snapshot.responseWasTruncated)
        XCTAssertEqual(snapshot.transcriptItems.map(\.body), ["agent 1", "user 2", "agent 2"])
    }

    @MainActor
    func testResumeSnapshotHandlesOversizedResponseFallback() throws {
        let response: [String: Any] = [
            "_cmuxResponseTruncated": true,
            "thread": ["id": "thread-large"],
        ]

        let snapshot = CodexAppServerPanel.resumeSnapshot(
            from: response,
            fallbackThreadId: "fallback-thread",
            restoredItemLimit: 3
        )

        XCTAssertEqual(snapshot.threadId, "thread-large")
        XCTAssertTrue(snapshot.responseWasTruncated)
        XCTAssertTrue(snapshot.transcriptItems.isEmpty)
    }

    @MainActor
    func testResumeSnapshotRendersCodexErrorsWithoutRawJSON() throws {
        let response: [String: Any] = [
            "thread": [
                "id": "thread-errors",
                "turns": [
                    [
                        "startedAt": 1_777_354_261,
                        "items": [
                            [
                                "type": "error",
                                "error": [
                                    "codexErrorInfo": "usageLimitExceeded",
                                    "message": "You've hit your usage limit for GPT-5.5 Codex.",
                                    "threadId": "thread-errors",
                                ],
                            ],
                        ],
                    ],
                ],
            ],
        ]

        let snapshot = CodexAppServerPanel.resumeSnapshot(
            from: response,
            fallbackThreadId: "fallback-thread",
            restoredItemLimit: 20
        )
        let item = try XCTUnwrap(snapshot.transcriptItems.first)

        XCTAssertEqual(item.role, .error)
        XCTAssertEqual(item.title, "Usage limit reached")
        XCTAssertEqual(item.body, "You've hit your usage limit for GPT-5.5 Codex.")
        XCTAssertFalse(item.body.contains("\"error\""))
    }

    func testGeneratedSchemasCoverCodexAppServerProtocolUnions() {
        XCTAssertEqual(CodexAppServerProtocolSchemas.sourceRemote, "https://github.com/openai/codex.git")
        XCTAssertEqual(
            CodexAppServerProtocolSchemas.sourceRevision,
            "b04ffeee4c806834bc9173455729cf47f874e836"
        )
        XCTAssertEqual(CodexAppServerServerNotificationMethod.allCases.count, 56)
        XCTAssertEqual(CodexAppServerServerRequestMethod.allCases.count, 9)
        XCTAssertEqual(CodexAppServerClientRequestMethod.allCases.count, 69)
        XCTAssertEqual(CodexAppServerClientNotificationMethod.allCases.count, 1)
    }

    func testGeneratedSchemaLookupIncludesKnownEventPayloadSchemas() throws {
        let agentDelta = try XCTUnwrap(
            CodexAppServerProtocolSchemas.serverNotificationSchema(for: "item/agentMessage/delta")
        )
        XCTAssertEqual(agentDelta.paramsSchemaName, "AgentMessageDeltaNotification")

        let permissionsApproval = try XCTUnwrap(
            CodexAppServerProtocolSchemas.serverRequestSchema(for: "item/permissions/requestApproval")
        )
        XCTAssertEqual(permissionsApproval.paramsSchemaName, "PermissionsRequestApprovalParams")

        let turnStart = try XCTUnwrap(
            CodexAppServerProtocolSchemas.clientRequestSchema(for: "turn/start")
        )
        XCTAssertEqual(turnStart.paramsSchemaName, "TurnStartParams")
    }

    func testGeneratedRootSchemaJSONRoundTrips() throws {
        let json = try XCTUnwrap(CodexAppServerProtocolSchemas.rootSchemaJSON(named: "ServerNotification"))
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        )
        XCTAssertEqual((object["oneOf"] as? [Any])?.count, 56)

        let requestJSON = try XCTUnwrap(CodexAppServerProtocolSchemas.rootSchemaJSON(named: "ClientRequest"))
        let requestObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(requestJSON.utf8)) as? [String: Any]
        )
        XCTAssertEqual((requestObject["oneOf"] as? [Any])?.count, 69)
    }

    func testProtocolEventWrappersPreserveTypedMethodsAndParams() {
        let notification = CodexAppServerServerNotification(
            method: "item/agentMessage/delta",
            params: ["delta": "hello", "index": 2]
        )

        XCTAssertEqual(notification.method, .itemAgentMessageDelta)
        XCTAssertEqual(notification.schema?.paramsSchemaName, "AgentMessageDeltaNotification")
        XCTAssertEqual(notification.paramsObject?["delta"] as? String, "hello")
        XCTAssertEqual(notification.paramsObject?["index"] as? Double, 2)

        let request = CodexAppServerServerRequest(
            id: 88,
            method: "item/permissions/requestApproval",
            params: ["reason": "test"]
        )
        XCTAssertEqual(request.id, .int(88))
        XCTAssertEqual(request.method, .itemPermissionsRequestApproval)
        XCTAssertEqual(request.paramsObject?["reason"] as? String, "test")
    }

    func testProtocolJSONValuePreservesNumericZeroOneValues() {
        let object = CodexAppServerJSONValue.fromAny([
            "zero": NSNumber(value: 0),
            "one": NSNumber(value: 1),
            "flag": NSNumber(value: true),
        ])
        let values = object.objectValue

        XCTAssertEqual(values?["zero"] as? Double, 0)
        XCTAssertEqual(values?["one"] as? Double, 1)
        XCTAssertEqual(values?["flag"] as? Bool, true)
    }

    func testApprovalResponsePayloadsMatchRequestMethodContracts() throws {
        let commandRequest = CodexAppServerPendingRequest(
            id: .int(1),
            method: "item/commandExecution/requestApproval",
            params: nil,
            summary: ""
        )
        XCTAssertEqual(commandRequest.approvalResponseResult(for: .accept)?["decision"] as? String, "accept")

        let fileChangeRequest = CodexAppServerPendingRequest(
            id: .int(2),
            method: "item/fileChange/requestApproval",
            params: nil,
            summary: ""
        )
        XCTAssertEqual(fileChangeRequest.approvalResponseResult(for: .cancel)?["decision"] as? String, "cancel")

        let permissionsRequest = CodexAppServerPendingRequest(
            id: .int(3),
            method: "item/permissions/requestApproval",
            params: [
                "permissions": [
                    "network": [
                        "enabled": true,
                    ],
                ],
            ],
            summary: ""
        )
        let grantedPermissions = try XCTUnwrap(permissionsRequest.approvalResponseResult(for: .accept))
        let permissions = try XCTUnwrap(grantedPermissions["permissions"] as? [String: Any])
        let network = try XCTUnwrap(permissions["network"] as? [String: Any])
        XCTAssertEqual(network["enabled"] as? Bool, true)
        XCTAssertEqual(grantedPermissions["scope"] as? String, "turn")

        let deniedPermissions = try XCTUnwrap(permissionsRequest.approvalResponseResult(for: .decline))
        XCTAssertTrue((deniedPermissions["permissions"] as? [String: Any])?.isEmpty == true)
        XCTAssertEqual(deniedPermissions["scope"] as? String, "turn")

        let applyPatchRequest = CodexAppServerPendingRequest(
            id: .int(4),
            method: "applyPatchApproval",
            params: nil,
            summary: ""
        )
        XCTAssertEqual(applyPatchRequest.approvalResponseResult(for: .accept)?["decision"] as? String, "approved")

        let execRequest = CodexAppServerPendingRequest(
            id: .int(5),
            method: "execCommandApproval",
            params: nil,
            summary: ""
        )
        XCTAssertEqual(execRequest.approvalResponseResult(for: .decline)?["decision"] as? String, "denied")
        XCTAssertEqual(execRequest.approvalResponseResult(for: .cancel)?["decision"] as? String, "abort")
    }

    func testTranscriptDisplayCollapsesOnlyCurrentTurnProgress() {
        let items: [CodexAppServerTranscriptItem] = [
            CodexAppServerTranscriptItem(role: .user, title: "You", body: "old prompt"),
            CodexAppServerTranscriptItem(role: .assistant, title: "Codex", body: "old answer"),
            CodexAppServerTranscriptItem(role: .user, title: "You", body: "latest prompt"),
            Self.transcriptToolCall(name: "exec_command", body: "git status"),
            CodexAppServerTranscriptItem(role: .event, title: "Tool output", body: "clean", presentation: .toolOutput),
            CodexAppServerTranscriptItem(role: .assistant, title: "Codex", body: "progress update"),
            Self.transcriptToolCall(name: "exec_command", body: "ls"),
            CodexAppServerTranscriptItem(role: .event, title: "Tool output", body: "file", presentation: .toolOutput),
            CodexAppServerTranscriptItem(role: .assistant, title: "Codex", body: "final answer"),
        ]

        let entries = CodexTrajectoryTranscriptDisplayEntry.entries(from: items)

        XCTAssertEqual(entries.map(\.kind), [.plain, .plain, .plain, .previousMessages, .plain])
        XCTAssertEqual(entries[0].block.text, "old prompt")
        XCTAssertEqual(entries[1].block.text, "old answer")
        XCTAssertEqual(entries[2].block.text, "latest prompt")
        XCTAssertEqual(entries[3].title, "3 previous messages")
        XCTAssertEqual(entries[4].block.text, "final answer")
    }

    func testTranscriptDisplayKeepsHookOnlyProgressAtTopLevel() {
        let started = """
        {
          "run": {
            "eventName": "sessionStart",
            "status": "running"
          },
          "threadId": "019d6637-e5cc-7cc0-a321-2c43b799036b"
        }
        """
        let completed = """
        {
          "run": {
            "durationMs": 42,
            "eventName": "sessionStart",
            "status": "completed"
          },
          "threadId": "019d6637-e5cc-7cc0-a321-2c43b799036b"
        }
        """
        let entries = CodexTrajectoryTranscriptDisplayEntry.entries(from: [
            CodexAppServerTranscriptItem(role: .user, title: "You", body: "how are you doing"),
            Self.transcriptHook(method: "hook/started", body: started),
            Self.transcriptHook(method: "hook/completed", body: completed),
            CodexAppServerTranscriptItem(role: .assistant, title: "Codex", body: "Doing fine."),
        ])

        XCTAssertEqual(entries.map(\.kind), [.plain, .toolGroup, .plain])
        XCTAssertEqual(entries[1].title, "2 hook events")
        XCTAssertTrue(entries[1].block.text.contains("Started hook sessionStart"))
        XCTAssertTrue(entries[1].block.text.contains("Completed hook sessionStart"))
    }

    func testTranscriptDisplaySuppressesChatRoleTitles() {
        let entries = CodexTrajectoryTranscriptDisplayEntry.entries(from: [
            CodexAppServerTranscriptItem(role: .user, title: "You", body: "Use **literal** markdown"),
            CodexAppServerTranscriptItem(role: .assistant, title: "Codex", body: "Rendered answer"),
            CodexAppServerTranscriptItem(role: .event, title: "Event", body: "Diagnostic"),
        ])

        XCTAssertEqual(entries.map(\.block.title), ["", "", "Event"])
        XCTAssertEqual(entries.map(\.block.displayText), ["Use **literal** markdown", "Rendered answer", "Event\nDiagnostic"])
    }

    func testTranscriptDisplayPreservesStreamingAssistantMarkdownBlocks() {
        let assistantID = UUID()
        let entries = CodexTrajectoryTranscriptDisplayEntry.entries(from: [
            CodexAppServerTranscriptItem(
                id: assistantID,
                role: .assistant,
                title: "Codex",
                body: "Streaming **markdown**",
                isStreaming: true
            ),
        ])

        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].block.kind, .assistantText)
        XCTAssertEqual(entries[0].block.text, "Streaming **markdown**")
        XCTAssertTrue(entries[0].block.isStreaming)
        XCTAssertEqual(entries[0].streamingAssistantBlockIDs, [assistantID.uuidString])
    }

    func testTranscriptDisplaySuppressesLifecycleNoise() {
        let entries = CodexTrajectoryTranscriptDisplayEntry.entries(from: [
            CodexAppServerTranscriptItem(
                role: .event,
                title: "Thread resumed",
                body: "thread-id",
                presentation: .lifecycleEvent
            ),
            CodexAppServerTranscriptItem(role: .event, title: "mcpServer/startupStatus/updated", body: "{}"),
            CodexAppServerTranscriptItem(role: .event, title: "thread/status/changed", body: "idle"),
            CodexAppServerTranscriptItem(role: .event, title: "skills/changed", body: "{}"),
            CodexAppServerTranscriptItem(role: .event, title: "thread/goal/cleared", body: "{}"),
            CodexAppServerTranscriptItem(role: .event, title: "Warning", body: "needs attention"),
            CodexAppServerTranscriptItem(role: .assistant, title: "Codex", body: "visible"),
        ])

        XCTAssertEqual(entries.map(\.block.displayText), ["Warning\nneeds attention", "visible"])
    }

    func testTranscriptContentStateShowsLoadingInsteadOfEmptyWhileStarting() {
        XCTAssertEqual(
            CodexAppServerTranscriptContentState.resolve(
                hasTranscriptItems: false,
                hasPendingRequests: false,
                status: .starting,
                loadingPhase: .idle
            ),
            .loading(.startingServer)
        )

        XCTAssertEqual(
            CodexAppServerTranscriptContentState.resolve(
                hasTranscriptItems: false,
                hasPendingRequests: false,
                status: .ready,
                loadingPhase: .restoringHistory
            ),
            .loading(.restoringHistory)
        )
    }

    func testTranscriptContentStatePrefersContentOverLoading() {
        XCTAssertEqual(
            CodexAppServerTranscriptContentState.resolve(
                hasTranscriptItems: true,
                hasPendingRequests: false,
                status: .starting,
                loadingPhase: .resumingThread
            ),
            .content
        )

        XCTAssertEqual(
            CodexAppServerTranscriptContentState.resolve(
                hasTranscriptItems: false,
                hasPendingRequests: true,
                status: .starting,
                loadingPhase: .resumingThread
            ),
            .content
        )
    }

    func testCodexPromptReturnKeyConvention() {
        XCTAssertEqual(
            CodexPromptTextViewKeyAction.action(
                keyCode: 36,
                modifierFlags: [],
                hasMarkedText: false
            ),
            .submit
        )
        XCTAssertEqual(
            CodexPromptTextViewKeyAction.action(
                keyCode: 36,
                modifierFlags: [.shift],
                hasMarkedText: false
            ),
            .insertNewline
        )
        XCTAssertEqual(
            CodexPromptTextViewKeyAction.action(
                keyCode: 76,
                modifierFlags: [],
                hasMarkedText: false
            ),
            .submit
        )
    }

    func testCodexPromptQueueAndInterruptKeyConvention() {
        XCTAssertEqual(
            CodexPromptTextViewKeyAction.action(
                keyCode: 48,
                modifierFlags: [],
                hasMarkedText: false
            ),
            .queueFollowUp
        )
        XCTAssertEqual(
            CodexPromptTextViewKeyAction.action(
                keyCode: 53,
                modifierFlags: [],
                hasMarkedText: false
            ),
            .interrupt
        )
        XCTAssertEqual(
            CodexPromptTextViewKeyAction.action(
                keyCode: 48,
                modifierFlags: [.shift],
                hasMarkedText: false
            ),
            .passThrough
        )
    }

    func testCodexPromptReturnKeyDoesNotInterruptCompositionOrModifiedShortcuts() {
        XCTAssertEqual(
            CodexPromptTextViewKeyAction.action(
                keyCode: 36,
                modifierFlags: [],
                hasMarkedText: true
            ),
            .passThrough
        )
        XCTAssertEqual(
            CodexPromptTextViewKeyAction.action(
                keyCode: 36,
                modifierFlags: [.command],
                hasMarkedText: false
            ),
            .passThrough
        )
    }

    func testCodexPromptSelectionRangesClampToPromptLength() {
        let ranges = CodexPromptSelectionRange.normalized(
            [
                CodexPromptSelectionRange(location: 3, length: 20),
                CodexPromptSelectionRange(location: 40, length: 4),
            ],
            textLength: 7
        )

        XCTAssertEqual(ranges, [
            CodexPromptSelectionRange(location: 3, length: 4),
            CodexPromptSelectionRange(location: 7, length: 0),
        ])
    }

    func testCodexPromptSelectionRangesDefaultToTextEnd() {
        XCTAssertEqual(
            CodexPromptSelectionRange.normalized([], textLength: 6),
            [CodexPromptSelectionRange(location: 6, length: 0)]
        )
        XCTAssertEqual(
            CodexPromptSelectionRange.normalized([], textLength: 6, fallbackToEnd: false),
            [CodexPromptSelectionRange(location: 0, length: 0)]
        )
    }

    func testTranscriptDisplayDoesNotCollapseWaitingTurn() {
        let items: [CodexAppServerTranscriptItem] = [
            CodexAppServerTranscriptItem(role: .user, title: "You", body: "old prompt"),
            CodexAppServerTranscriptItem(role: .assistant, title: "Codex", body: "old answer"),
            CodexAppServerTranscriptItem(role: .user, title: "You", body: "latest prompt"),
            Self.transcriptToolCall(name: "exec_command", body: "git status"),
            CodexAppServerTranscriptItem(role: .event, title: "Tool output", body: "clean", presentation: .toolOutput),
        ]

        let entries = CodexTrajectoryTranscriptDisplayEntry.entries(from: items)

        XCTAssertEqual(entries.map(\.kind), [.plain, .plain, .plain, .toolGroup])
    }

    private static func responseItem(role: String, text: String) -> [String: Any] {
        [
            "timestamp": "2026-04-06T21:34:00.000Z",
            "type": "response_item",
            "payload": [
                "type": "message",
                "role": role,
                "content": [
                    [
                        "type": role == "assistant" ? "output_text" : "input_text",
                        "text": text,
                    ],
                ],
            ],
        ]
    }

    private static func transcriptToolCall(name: String, body: String) -> CodexAppServerTranscriptItem {
        CodexAppServerTranscriptItem(
            role: .event,
            title: name,
            body: body,
            presentation: .toolCall(name: name)
        )
    }

    private static func transcriptHook(method: String, body: String) -> CodexAppServerTranscriptItem {
        CodexAppServerTranscriptItem(
            role: .event,
            title: method,
            body: body,
            presentation: .hookEvent(method: method)
        )
    }

    private static func jsonLine(_ object: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return try XCTUnwrap(String(data: data, encoding: .utf8))
    }
}
