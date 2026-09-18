import Foundation
import Testing

#if canImport(cmux_DEV)
    @testable import cmux_DEV
#elseif canImport(cmux)
    @testable import cmux
#endif

@Suite(.serialized)
@MainActor
struct AgentSessionRuntimeTests {
    @Test
    func childEnvironmentPinsCmuxCliToTheTaggedSocket() {
        let environment = AgentSessionLaunchPlan.withCmuxRuntimeEnvironment([
            "CMUX_SOCKET": "/tmp/stale-cmux.sock",
            "CMUX_SOCKET_PATH": "/tmp/cmux-debug-gui.sock",
            "PATH": "/usr/bin:/bin"
        ], resourceURL: nil)
        #expect(environment["CMUX_SOCKET_PATH"] == "/tmp/cmux-debug-gui.sock")
        #expect(environment["CMUX_SOCKET"] == nil)
        #expect(environment["CMUX_SOCKET_ENABLE"] == "1")
        #expect(environment["PATH"] == "/usr/bin:/bin")
    }

    @Test
    func discoversAllModelPagesWithProviderReasoningOptions() async throws {
        let (requests, continuation) = AsyncStream<String>.makeStream()
        var models: [[String: Any]] = []
        let session = CodexAppServerSession(
            workingDirectory: nil,
            writeData: { continuation.yield(String(decoding: $0, as: UTF8.self)) },
            outputSink: { _, _ in },
            modelsSink: { models = $0 }
        )
        defer { continuation.finish() }
        var iterator = requests.makeAsyncIterator()
        try await session.start()
        _ = await iterator.next() // initialize
        session.consumeStdout(#"{"id":1,"result":{}}"# + "\n")
        _ = await iterator.next() // initialized
        _ = await iterator.next() // thread/start
        let firstPage = try #require(await iterator.next())
        let request = try #require(JSONSerialization.jsonObject(with: Data(firstPage.utf8)) as? [String: Any])
        #expect(request["method"] as? String == "model/list")
        let requestID = try #require(request["id"] as? Int)
        session.consumeStdout("""
        {"id":\(requestID),"result":{"data":[{"id":"model-one","model":"provider-model-one","displayName":"Model One","supportedReasoningEfforts":[{"reasoningEffort":"high"}],"defaultReasoningEffort":"high"}],"nextCursor":"second"}}

        """)
        let secondPage = try #require(await iterator.next())
        let nextRequest = try #require(JSONSerialization.jsonObject(with: Data(secondPage.utf8)) as? [String: Any])
        #expect((nextRequest["params"] as? [String: Any])?["cursor"] as? String == "second")
        let nextID = try #require(nextRequest["id"] as? Int)
        session.consumeStdout("""
        {"id":\(nextID),"result":{"data":[{"id":"model-two","displayName":"Model Two","supportedReasoningEfforts":[{"reasoningEffort":"low"}],"defaultReasoningEffort":"low","isDefault":true}],"nextCursor":null}}

        """)
        #expect(models.compactMap { $0["id"] as? String } == ["provider-model-one", "model-two"])
        #expect(models.last?["reasoningEfforts"] as? [String] == ["low"])
        #expect(models.last?["isDefault"] as? Bool == true)
    }

    @Test
    func processStoreDeliversSmallResponsesBeforeTheProviderExits() async throws {
        // The peer keeps stdout open between requests. Buffering a fixed-size
        // read deadlocks the handshake even though every JSONL frame is flushed.
        let peer = #"""
        import json, os, select, sys
        buffer = b""
        def receive():
            global buffer
            while b"\n" not in buffer:
                if not select.select([0], [], [], 3)[0]:
                    sys.exit(42)
                chunk = os.read(0, 65536)
                if not chunk:
                    sys.exit(0)
                buffer += chunk
            line, buffer = buffer.split(b"\n", 1)
            return json.loads(line)
        def send(message):
            print(json.dumps(message), flush=True)
        while True:
            message = receive()
            method = message.get("method")
            if method == "initialize":
                send({"id": message["id"], "result": {}})
            elif method == "thread/start":
                send({"id": message["id"], "result": {"thread": {"id": "test-thread"}}})
            elif method == "model/list":
                send({"id": message["id"], "result": {"data": [], "nextCursor": None}})
            elif method == "turn/start":
                send({"id": message["id"], "result": {"turn": {"id": "test-turn"}}})
                send({"method": "item/agentMessage/delta", "params": {"delta": "2"}})
                send({"method": "turn/completed", "params": {"turn": {"id": "test-turn", "status": "completed"}}})
        """#
        let store = AgentSessionProcessStore()
        let (events, continuation) = AsyncStream<(String, String)>.makeStream()
        store.eventSink = { event in
            let type = event["type"] as? String ?? ""
            continuation.yield((type, event["text"] as? String ?? ""))
            if type == "provider.exit" { continuation.finish() }
        }
        defer { store.closeAll(); continuation.finish() }
        let session = try await store.start(
            plan: AgentSessionLaunchPlan(
                provider: .codex,
                executableURL: URL(fileURLWithPath: "/usr/bin/python3"),
                arguments: ["-u", "-c", peer],
                environment: ProcessInfo.processInfo.environment
            ),
            workingDirectory: nil
        )
        let submission = Task { @MainActor in
            try await store.writeLine(sessionId: session.sessionId, text: "1+1")
        }
        var answer = ""
        var completedWhileRunning = false
        for await (type, text) in events {
            if type == "provider.output" { answer += text }
            if type == "provider.turnComplete" {
                completedWhileRunning = store.hasActiveProviderSession
                store.closeAll()
            }
        }
        let submitted: Void? = try? await submission.value
        #expect(submitted != nil)
        #expect(answer == "2")
        #expect(completedWhileRunning)
    }

    @Test
    func testCodexApprovalRequestsOnlyAutoApproveForFullAccessMode() async throws {
        let (writes, continuation) = AsyncStream<String>.makeStream()
        defer { continuation.finish() }
        let session = CodexAppServerSession(
            workingDirectory: nil,
            writeData: { data in
                continuation.yield(String(decoding: data, as: UTF8.self))
            },
            outputSink: { _, _ in }
        )

        try await session.start()
        session.consumeStdout(
            #"{"id":1,"result":{"userAgent":"codex","codexHome":"/tmp","platformFamily":"unix","platformOs":"macos"}}"#
                + "\n")
        var iterator = writes.makeAsyncIterator()
        for _ in 0..<3 { _ = await iterator.next() }
        session.consumeStdout(#"{"id":2,"result":{"thread":{"id":"thread-1"}}}"# + "\n")
        try await session.submit("default prompt", permissionMode: .standard)
        session.consumeStdout(
            #"{"id":"cmd-1","method":"item/commandExecution/requestApproval","params":{"threadId":"thread-1"}}"# + "\n")
        session.consumeStdout(
            #"{"id":"perm-1","method":"item/permissions/requestApproval","params":{"permissions":{"network":{"enabled":true}}}}"# + "\n")
        do {
            try await session.submit("blocked full access prompt", permissionMode: .fullAccess)
            Issue.record("An active turn must reject a second turn")
        } catch {}
        session.consumeStdout(#"{"method":"turn/completed","params":{"threadId":"thread-1"}}"# + "\n")
        try await session.submit("full access prompt", permissionMode: .fullAccess)
        session.consumeStdout(
            #"{"id":"cmd-2","method":"item/commandExecution/requestApproval","params":{"threadId":"thread-1"}}"# + "\n")
        session.consumeStdout(
            #"{"id":"perm-2","method":"item/permissions/requestApproval","params":{"permissions":{"network":{"enabled":true}}}}"# + "\n")

        var responses: [String: [String: Any]] = [:]
        while responses.count < 4, let line = await iterator.next() {
            let message = try #require(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
            if let id = message["id"] as? String, let result = message["result"] as? [String: Any] {
                responses[id] = result
            }
        }
        #expect(responses["cmd-1"]?["decision"] as? String == "decline")
        #expect((responses["perm-1"]?["permissions"] as? [String: Any])?.isEmpty == true)
        #expect(responses["cmd-2"]?["decision"] as? String == "acceptForSession")
        let permissions = try #require(responses["perm-2"]?["permissions"] as? [String: Any])
        #expect((permissions["network"] as? [String: Any])?["enabled"] as? Bool == true)
    }
}
