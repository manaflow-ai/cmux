import CNCore
import CNMockHost
import CNTransport
import Foundation
import Testing

let testClient = ClientInfo(name: "tests", version: "1", platform: "macOS")

func connectedClient(_ host: MockHost) async throws -> HostClient {
    let client = HostClient(transport: host.connectLoopback(), defaultTimeout: .seconds(10))
    _ = try await client.hello(testClient)
    return client
}

/// Waits for the first element matching `predicate`, bounded by `timeout`.
func first<T: Sendable>(_ stream: AsyncStream<T>, timeout: Duration = .seconds(10), where predicate: @escaping @Sendable (T) -> Bool) async throws -> T {
    try await withThrowingTaskGroup(of: T?.self) { group in
        group.addTask {
            for await v in stream where predicate(v) { return v }
            return nil
        }
        group.addTask {
            try await Task.sleep(for: timeout)
            return nil
        }
        let result = try await group.next() ?? nil
        group.cancelAll()
        return try #require(result)
    }
}

@Suite struct HostClientTests {
    let host = MockHost(options: MockHost.Options(speed: 40, browserFPS: 30))

    @Test func refusesBeforeHello() async throws {
        let client = HostClient(transport: host.connectLoopback())
        await #expect(throws: RPCError.self) { try await client.listConversations() }
        let info = try await client.hello(testClient)
        #expect(info.hostId == MockHost.defaultHostId && info.supports(.browser))
    }

    @Test func rpcAndErrors() async throws {
        let client = try await connectedClient(host)
        let convs = try await client.listConversations()
        #expect(convs.count == 3 && convs.first?.kind == .chief)
        let history = try await client.conversationHistory(convs[0].id, limit: 4)
        #expect(history.messages.count == 4 && history.hasMore)
        do {
            _ = try await client.agentHistory("nope")
            Issue.record("expected not_found")
        } catch let e as RPCError {
            #expect(e.code == .notFound)
        }
        let ping = try await client.ping()
        #expect(ping.at > 0)
    }

    @Test func sendTriggersTypingThenReply() async throws {
        let client = try await connectedClient(host)
        let pushes = client.pushes()
        let sent = try await client.sendMessage("c_chief", text: "status?", clientId: "local-1")
        #expect(sent.clientId == "local-1" && sent.sender.isMe)
        _ = try await first(pushes) { if case .typing(let t) = $0 { t.typing } else { false } }
        let reply = try await first(pushes) {
            if case .conversationMessage(let m) = $0 { !m.sender.isMe } else { false }
        }
        guard case .conversationMessage(let m) = reply else { return }
        #expect(m.conversationId == "c_chief" && !m.text.isEmpty)
    }

    @Test func agentTranscriptsAndStreaming() async throws {
        let client = try await connectedClient(host)
        let sessions = try await client.listAgentSessions()
        #expect(sessions.count == 3)
        var kinds = Set<String>()
        for s in sessions { kinds.formUnion(try await client.agentHistory(s.id).items.map(\.kind)) }
        #expect(kinds == ["user", "assistant", "thought", "tool", "plan", "permission", "notice", "turnEnd"])

        let items = client.events(topic: HostTopic.agentItem.rawValue).decoded(as: AgentItemEvent.self)
        try await client.prompt("s_resize", text: "add a refresh timestamp")
        let streamingEvent = try await first(items) { $0.sessionId == "s_resize" && $0.item.isStreaming }
        #expect(streamingEvent.item.kind == "thought" || streamingEvent.item.kind == "assistant")
        _ = try await first(items, timeout: .seconds(20)) { $0.item.kind == "turnEnd" }
    }

    @Test func fixturePermissionCanBeAnswered() async throws {
        let client = try await connectedClient(host)
        let history = try await client.agentHistory("s_auth")
        let permission = try #require(history.items.first { $0.kind == "permission" })
        let sessionsStream = client.events(topic: HostTopic.agentSession.rawValue).decoded(as: AgentSessionResult.self)
        try await client.answerPermission("s_auth", itemId: permission.id, optionId: "allow_once")
        _ = try await first(sessionsStream, timeout: .seconds(20)) { $0.session.id == "s_auth" && $0.session.status == .idle }
    }

    @Test func terminalReplayAndEcho() async throws {
        let client = try await connectedClient(host)
        let terms = try await client.listTerminals()
        let shell = try #require(terms.first { $0.title.hasPrefix("zsh") })
        let attach = try await client.attachTerminal(shell.id, cols: 80, rows: 24)
        let output = client.openStream(id: attach.streamId)
        let collected = OutputCollector()
        let reader = Task { for await chunk in output { await collected.append(chunk) } }
        try await collected.waitFor("git log --oneline")
        try client.sendTerminalInput(streamId: attach.streamId, Data("pwd\r".utf8))
        try await collected.waitFor("/Users/aziz/src/cmux")
        try await client.detachTerminal(streamId: attach.streamId)
        reader.cancel()
    }

    @Test func browserFramesArePacedByAcks() async throws {
        let client = try await connectedClient(host)
        let tab = try #require(try await client.listTabs().first)
        let attach = try await client.attachTab(BrowserAttachParams(tabId: tab.id, width: 390, height: 700, scale: 2))
        let frames = client.openBrowserStream(id: attach.streamId)
        var iterator = frames.makeAsyncIterator()
        let f1 = try #require(await iterator.next())
        #expect(f1.seq == 1 && f1.cssWidth == 390 && f1.pixelWidth == 780 && f1.format == .jpeg)
        #expect(f1.image.starts(with: [0xFF, 0xD8]))
        try await client.scroll(BrowserScrollParams(tabId: tab.id, x: 10, y: 10, dx: 0, dy: 300))
        let f2 = try #require(await iterator.next())
        #expect(f2.seq == 2)
        try await client.ackFrame(streamId: attach.streamId, seq: 2)
        let f3 = try #require(await iterator.next())
        #expect(f3.seq == 3)
        let shot = try await client.screenshot(tab.id)
        #expect((shot.data?.count ?? 0) > 1000)
        try await client.detachTab(streamId: attach.streamId)
    }

    @Test func requestTimesOutWhenPeerIsSilent() async throws {
        let (phone, silent) = LoopbackTransport.makePair()
        let client = HostClient(transport: phone, defaultTimeout: .milliseconds(150))
        await #expect(throws: HostClientError.timedOut(method: "host.ping")) { try await client.ping() }
        silent.close()
        await #expect(throws: HostClientError.self) { try await client.ping() }
    }

    @Test func pendingRequestsFailOnDrop() async throws {
        let (phone, server) = LoopbackTransport.makePair()
        let client = HostClient(transport: phone)
        let pending = Task { try await client.ping() }
        server.simulateDrop()
        await #expect(throws: HostClientError.self) { try await pending.value }
        #expect(await client.waitUntilClosed() == "Simulated network drop")
    }
}

actor OutputCollector {
    private var text = ""
    private var waiters: [(String, CheckedContinuation<Void, Never>)] = []

    func append(_ data: Data) {
        text += String(decoding: data, as: UTF8.self)
        let ready = waiters.filter { text.contains($0.0) }
        waiters.removeAll { text.contains($0.0) }
        for w in ready { w.1.resume() }
    }

    func waitFor(_ needle: String, timeout: Duration = .seconds(10)) async throws {
        if text.contains(needle) { return }
        let timer = Task { try await Task.sleep(for: timeout); self.timeOut(needle) }
        defer { timer.cancel() }
        await withCheckedContinuation { waiters.append((needle, $0)) }
        if !text.contains(needle) { Issue.record("Timed out waiting for \(needle)") }
    }

    private func timeOut(_ needle: String) {
        let matching = waiters.filter { $0.0 == needle }
        waiters.removeAll { $0.0 == needle }
        for w in matching { w.1.resume() }
    }
}

@Suite struct HostConnectionTests {
    @MainActor @Test func connectsAndReconnectsAfterDrop() async throws {
        let host = MockHost(options: MockHost.Options(speed: 40))
        let connection = HostConnection(connector: host.makeConnector(), clientInfo: testClient,
                                        backoff: ReconnectBackoff(initial: .milliseconds(20), maxAttempts: 5))
        connection.connect(hostId: MockHost.defaultHostId)
        try await waitUntil { connection.state.isConnected }
        #expect(connection.generation == 1)
        #expect(connection.pathInfo?.localCandidate == .host)
        #expect(connection.pathInfo?.rttMs != nil)
        #expect(connection.hostInfo?.hostName == "Demo MacBook Pro")
        await host.dropAllLinks()
        try await waitUntil { connection.generation == 2 && connection.state.isConnected }
        let convs: ConversationList = try await connection.request(HostMethod.convList.rawValue, EmptyPayload())
        #expect(convs.conversations.count == 3)
        connection.disconnect()
        #expect(connection.state == .idle)
    }

    @MainActor @Test func failsAfterMaxAttempts() async throws {
        let host = MockHost()
        let connection = HostConnection(connector: host.makeConnector(), clientInfo: testClient,
                                        backoff: ReconnectBackoff(initial: .milliseconds(5), maxAttempts: 2))
        connection.connect(hostId: "h_missing")
        try await waitUntil { if case .failed = connection.state { true } else { false } }
    }

    /// Bounded poll of main-actor state (test-only).
    @MainActor func waitUntil(timeout: Duration = .seconds(10), _ condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            guard ContinuousClock.now < deadline else { Issue.record("condition not met in time"); return }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}
