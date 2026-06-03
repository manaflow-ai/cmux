import XCTest
@testable import cmux_DEV

final class TerminalRemoteDaemonSessionTransportTests: XCTestCase {
    func testConnectEmitsConnectedAndPollsTerminalOutput() async throws {
        let client = StubDaemonSessionClient(
            hello: .init(
                name: "cmuxd-remote",
                version: "dev",
                instanceID: nil,
                capabilities: ["terminal.stream"]
            ),
            openResult: .init(
                sessionID: "sess-1",
                attachmentID: "att-1",
                attachments: [],
                effectiveCols: 120,
                effectiveRows: 40,
                lastKnownCols: 120,
                lastKnownRows: 40,
                offset: 0,
                gridGeneration: nil
            ),
            readResults: [
                Result<TerminalRemoteDaemonTerminalReadResult, Error>.success(
                    .init(
                        sessionID: "sess-1",
                        offset: 5,
                        baseOffset: 0,
                        truncated: false,
                        eof: false,
                        data: Data("READY".utf8)
                    )
                )
            ]
        )
        let transport = TerminalRemoteDaemonSessionTransport(
            client: client,
            command: "tmux new-session -A -s demo"
        )

        let connectedExpectation = expectation(description: "connected")
        let outputExpectation = expectation(description: "output")
        transport.eventHandler = { (event: TerminalTransportEvent) in
            switch event {
            case .connected:
                connectedExpectation.fulfill()
            case .output(let data) where data == Data("READY".utf8):
                outputExpectation.fulfill()
            default:
                break
            }
        }

        try await transport.connect(initialSize: TerminalGridSize.fixture(columns: 120, rows: 40))

        await fulfillment(of: [connectedExpectation, outputExpectation], timeout: 1.0)
        await transport.disconnect()

        let openedCommands = await client.openedCommands()
        XCTAssertEqual(openedCommands, ["tmux new-session -A -s demo"])
    }

    func testSendResizeAndDisconnectForwardToDaemonClient() async throws {
        let client = StubDaemonSessionClient(
            hello: .init(
                name: "cmuxd-remote",
                version: "dev",
                instanceID: nil,
                capabilities: ["terminal.stream"]
            ),
            attachResult: nil,
            openResult: .init(
                sessionID: "sess-9",
                attachmentID: "att-9",
                attachments: [],
                effectiveCols: 80,
                effectiveRows: 24,
                lastKnownCols: 80,
                lastKnownRows: 24,
                offset: 0,
                gridGeneration: nil
            ),
            readResults: []
        )
        let transport = TerminalRemoteDaemonSessionTransport(
            client: client,
            command: "tmux new-session -A -s demo"
        )

        try await transport.connect(initialSize: TerminalGridSize.fixture(columns: 80, rows: 24))
        try await transport.send(Data("ls\n".utf8))
        await transport.resize(TerminalGridSize.fixture(columns: 100, rows: 30))
        await transport.disconnect()

        let writes = await client.recordedWrites()
        XCTAssertEqual(writes, [Data("ls\n".utf8)])

        let resizeCalls = await client.recordedResizes()
        XCTAssertEqual(resizeCalls.count, 1)
        XCTAssertEqual(resizeCalls.first?.sessionID, "sess-9")
        XCTAssertEqual(resizeCalls.first?.attachmentID, "att-9")
        XCTAssertEqual(resizeCalls.first?.cols, 100)
        XCTAssertEqual(resizeCalls.first?.rows, 30)

        let closedSessions = await client.closedSessions()
        XCTAssertEqual(closedSessions, ["sess-9"])
    }

    func testSuspendPreservingSessionDetachesInsteadOfClosingSession() async throws {
        let client = StubDaemonSessionClient(
            hello: .init(
                name: "cmuxd-remote",
                version: "dev",
                instanceID: nil,
                capabilities: ["terminal.stream"]
            ),
            attachResult: nil,
            openResult: .init(
                sessionID: "sess-park",
                attachmentID: "att-park",
                attachments: [],
                effectiveCols: 90,
                effectiveRows: 20,
                lastKnownCols: 90,
                lastKnownRows: 20,
                offset: 0,
                gridGeneration: nil
            ),
            readResults: []
        )
        let transport = TerminalRemoteDaemonSessionTransport(
            client: client,
            command: "tmux new-session -A -s demo"
        )

        try await transport.connect(initialSize: TerminalGridSize.fixture(columns: 90, rows: 20))
        await transport.suspendPreservingSession()

        let detachCalls = await client.recordedDetaches()
        let closedSessions = await client.closedSessions()
        XCTAssertEqual(detachCalls.count, 1)
        XCTAssertEqual(detachCalls.first?.sessionID, "sess-park")
        XCTAssertEqual(detachCalls.first?.attachmentID, "att-park")
        XCTAssertEqual(closedSessions, [String]())
    }

    func testDefaultTransportFactoryUsesInjectedRemoteDaemonBuilder() {
        let expectedTransport = StubTerminalTransport()
        let factory = DefaultTerminalTransportFactory(
            remoteDaemonBuilder: { _, _, _, _ in expectedTransport }
        )
        let host = TerminalHost(
            name: "Mac Mini",
            hostname: "cmux-macmini",
            username: "cmux",
            symbolName: "desktopcomputer",
            palette: .mint,
            transportPreference: .remoteDaemon
        )

        let transport = factory.makeTransport(
            host: host,
            credentials: TerminalSSHCredentials(password: "secret", privateKey: nil),
            sessionName: "demo",
            resumeState: nil
        )

        XCTAssertTrue(transport === expectedTransport)
    }

    func testConnectAttachesExistingSessionAndTracksReadOffset() async throws {
        let client = StubDaemonSessionClient(
            hello: .init(
                name: "cmuxd-remote",
                version: "dev",
                instanceID: nil,
                capabilities: ["terminal.stream"]
            ),
            attachResult: .success(
                .init(
                    sessionID: "sess-existing",
                    attachments: [],
                    effectiveCols: 100,
                    effectiveRows: 30,
                    lastKnownCols: 100,
                    lastKnownRows: 30,
                    gridGeneration: nil
                )
            ),
            openResult: .init(
                sessionID: "sess-opened",
                attachmentID: "att-opened",
                attachments: [],
                effectiveCols: 100,
                effectiveRows: 30,
                lastKnownCols: 100,
                lastKnownRows: 30,
                offset: 0,
                gridGeneration: nil
            ),
            readResults: [
                .success(
                    .init(
                        sessionID: "sess-existing",
                        offset: 9,
                        baseOffset: 0,
                        truncated: false,
                        eof: false,
                        data: Data("resume".utf8)
                    )
                )
            ]
        )
        let transport = TerminalRemoteDaemonSessionTransport(
            client: client,
            command: "tmux new-session -A -s demo",
            resumeState: .init(sessionID: "sess-existing", attachmentID: "att-existing", readOffset: 3)
        )

        let connectedExpectation = expectation(description: "connected")
        let outputExpectation = expectation(description: "output")
        transport.eventHandler = { (event: TerminalTransportEvent) in
            switch event {
            case .connected:
                connectedExpectation.fulfill()
            case .output(let data) where data == Data("resume".utf8):
                outputExpectation.fulfill()
            default:
                break
            }
        }

        try await transport.connect(initialSize: TerminalGridSize.fixture(columns: 100, rows: 30))
        await fulfillment(of: [connectedExpectation, outputExpectation], timeout: 1.0)

        let attachCalls = await client.recordedAttaches()
        let openedCommands = await client.openedCommands()
        XCTAssertEqual(attachCalls.count, 1)
        XCTAssertEqual(attachCalls.first?.sessionID, "sess-existing")
        XCTAssertEqual(attachCalls.first?.attachmentID, "att-existing")
        XCTAssertEqual(openedCommands, [String]())
        XCTAssertEqual(
            transport.remoteDaemonResumeStateSnapshot(),
            TerminalRemoteDaemonResumeState(
                sessionID: "sess-existing",
                attachmentID: "att-existing",
                readOffset: 9
            )
        )

        await transport.disconnect()
        XCTAssertNil(transport.remoteDaemonResumeStateSnapshot())
    }

    func testFreshSharedAttachBootstrapsVTHistoryAndSubscribesFromSnapshotOffset() async throws {
        let client = StubDaemonSessionClient(
            hello: .init(
                name: "cmuxd-remote",
                version: "dev",
                instanceID: nil,
                capabilities: ["terminal.stream", "terminal.subscribe"]
            ),
            attachResult: .success(
                .init(
                    sessionID: "sess-shared",
                    attachments: [],
                    effectiveCols: 100,
                    effectiveRows: 30,
                    lastKnownCols: 100,
                    lastKnownRows: 30,
                    gridGeneration: nil
                )
            ),
            openResult: .init(
                sessionID: "sess-opened",
                attachmentID: "att-opened",
                attachments: [],
                effectiveCols: 100,
                effectiveRows: 30,
                lastKnownCols: 100,
                lastKnownRows: 30,
                offset: 0,
                gridGeneration: nil
            ),
            readResults: [],
            historyResult: .init(
                sessionID: "sess-shared",
                history: "\u{001B}[?25lcmux welcome\r\nlawrence in / λ ",
                nextOffset: 42
            ),
            subscribeResult: .success(
                .init(
                    sessionID: "sess-shared",
                    offset: 42,
                    baseOffset: 0,
                    truncated: false,
                    eof: false,
                    data: Data()
                )
            )
        )
        let transport = TerminalRemoteDaemonSessionTransport(
            client: client,
            command: "tmux new-session -A -s demo",
            sharedSessionID: "sess-shared"
        )

        let connectedExpectation = expectation(description: "connected")
        let historyExpectation = expectation(description: "history")
        transport.eventHandler = { (event: TerminalTransportEvent) in
            switch event {
            case .connected:
                connectedExpectation.fulfill()
            case .output(let data) where data == Data("\u{001B}[?25lcmux welcome\r\nlawrence in / λ ".utf8):
                historyExpectation.fulfill()
            default:
                break
            }
        }

        try await transport.connect(initialSize: TerminalGridSize.fixture(columns: 100, rows: 30))

        await fulfillment(of: [connectedExpectation, historyExpectation], timeout: 1.0)

        let historyRequests = await client.recordedHistoryRequests()
        XCTAssertEqual(historyRequests.count, 1)
        XCTAssertEqual(historyRequests.first?.sessionID, "sess-shared")
        XCTAssertEqual(historyRequests.first?.format, "vt")

        let subscribeCalls = await client.recordedSubscriptions()
        XCTAssertEqual(subscribeCalls.count, 1)
        XCTAssertEqual(subscribeCalls.first?.sessionID, "sess-shared")
        let subscribeOffset = subscribeCalls.first?.offset ?? nil
        XCTAssertEqual(subscribeOffset, 42)

        let openedCommands = await client.openedCommands()
        XCTAssertEqual(openedCommands, [String]())

        await transport.disconnect()
    }

    func testFreshSharedAttachCombinesSubscribeSnapshotWithInitialHistory() async throws {
        let historyData = Data("cmux welcome\r\nRun cmux shortcuts to edit shortcuts.\r\n".utf8)
        let gapData = Data("Run cmux feedback to report a bug.\r\n\r\nlawrence in / λ ".utf8)
        let historyOffset: UInt64 = 10
        let gapEndOffset = historyOffset + UInt64(gapData.count)
        let client = StubDaemonSessionClient(
            hello: .init(
                name: "cmuxd-remote",
                version: "dev",
                instanceID: nil,
                capabilities: ["terminal.stream", "terminal.subscribe"]
            ),
            attachResult: .success(
                .init(
                    sessionID: "sess-shared",
                    attachments: [],
                    effectiveCols: 49,
                    effectiveRows: 34,
                    lastKnownCols: 49,
                    lastKnownRows: 34,
                    gridGeneration: nil
                )
            ),
            openResult: .init(
                sessionID: "sess-opened",
                attachmentID: "att-opened",
                attachments: [],
                effectiveCols: 49,
                effectiveRows: 34,
                lastKnownCols: 49,
                lastKnownRows: 34,
                offset: 0,
                gridGeneration: nil
            ),
            readResults: [],
            historyResult: .init(
                sessionID: "sess-shared",
                history: String(decoding: historyData, as: UTF8.self),
                nextOffset: historyOffset
            ),
            subscribeResult: .success(
                .init(
                    sessionID: "sess-shared",
                    offset: gapEndOffset,
                    baseOffset: 0,
                    truncated: false,
                    eof: false,
                    data: gapData
                )
            )
        )
        let transport = TerminalRemoteDaemonSessionTransport(
            client: client,
            command: "tmux new-session -A -s demo",
            sharedSessionID: "sess-shared"
        )
        let outputs = LockedOutputs()

        transport.eventHandler = { event in
            if case .output(let data) = event {
                outputs.append(data)
            }
        }

        try await transport.connect(initialSize: TerminalGridSize.fixture(columns: 49, rows: 34))

        var expectedReplay = historyData
        expectedReplay.append(gapData)
        XCTAssertEqual(outputs.values(), [expectedReplay])

        let readCalls = await client.recordedReads()
        XCTAssertEqual(readCalls.count, 0)

        let subscribeCalls = await client.recordedSubscriptions()
        XCTAssertEqual(subscribeCalls.count, 1)
        XCTAssertEqual(subscribeCalls.first?.sessionID, "sess-shared")
        XCTAssertEqual(subscribeCalls.first?.offset, historyOffset)

        await transport.disconnect()
    }

    func testSharedSessionNotFoundDoesNotOpenOrphanTerminal() async throws {
        let client = StubDaemonSessionClient(
            hello: .init(
                name: "cmuxd-remote",
                version: "dev",
                instanceID: nil,
                capabilities: ["terminal.stream"]
            ),
            attachResult: .failure(
                TerminalRemoteDaemonClientError.rpc(code: "not_found", message: "session not found")
            ),
            openResult: .init(
                sessionID: "sess-orphan",
                attachmentID: "att-orphan",
                attachments: [],
                effectiveCols: 100,
                effectiveRows: 30,
                lastKnownCols: 100,
                lastKnownRows: 30,
                offset: 0,
                gridGeneration: nil
            ),
            readResults: []
        )
        let transport = TerminalRemoteDaemonSessionTransport(
            client: client,
            command: "tmux new-session -A -s demo",
            sharedSessionID: "sess-restored"
        )

        do {
            try await transport.connect(initialSize: TerminalGridSize.fixture(columns: 100, rows: 30))
            XCTFail("Expected missing shared session to wait for the daemon-owned session")
        } catch TerminalRemoteDaemonSessionTransportError.sharedSessionUnavailable(let sessionID) {
            XCTAssertEqual(sessionID, "sess-restored")
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let attachCalls = await client.recordedAttaches()
        let openedCommands = await client.openedCommands()
        let openedSessionIDs = await client.recordedOpenedSessionIDs()
        XCTAssertEqual(attachCalls.count, 1)
        XCTAssertEqual(attachCalls.first?.sessionID, "sess-restored")
        XCTAssertEqual(openedCommands, [String]())
        XCTAssertEqual(openedSessionIDs, [String?]())
    }

    func testDuplicateAndOverlappingPushPayloadsOnlyEmitNewBytes() async throws {
        let client = StubDaemonSessionClient(
            hello: .init(
                name: "cmuxd-remote",
                version: "dev",
                instanceID: nil,
                capabilities: ["terminal.stream", "terminal.subscribe"]
            ),
            attachResult: .success(
                .init(
                    sessionID: "sess-shared",
                    attachments: [],
                    effectiveCols: 100,
                    effectiveRows: 30,
                    lastKnownCols: 100,
                    lastKnownRows: 30,
                    gridGeneration: nil
                )
            ),
            openResult: .init(
                sessionID: "sess-opened",
                attachmentID: "att-opened",
                attachments: [],
                effectiveCols: 100,
                effectiveRows: 30,
                lastKnownCols: 100,
                lastKnownRows: 30,
                offset: 0,
                gridGeneration: nil
            ),
            readResults: [],
            historyResult: .init(
                sessionID: "sess-shared",
                history: "prompt ",
                nextOffset: 10
            ),
            subscribeResult: .success(
                .init(
                    sessionID: "sess-shared",
                    offset: 10,
                    baseOffset: 0,
                    truncated: false,
                    eof: false,
                    data: Data()
                )
            )
        )
        let transport = TerminalRemoteDaemonSessionTransport(
            client: client,
            command: "tmux new-session -A -s demo",
            sharedSessionID: "sess-shared"
        )
        let outputs = LockedOutputs()

        transport.eventHandler = { event in
            if case .output(let data) = event {
                outputs.append(data)
            }
        }

        try await transport.connect(initialSize: TerminalGridSize.fixture(columns: 100, rows: 30))

        await client.emitPush(
            sessionID: "sess-shared",
            data: Data("abc".utf8),
            offset: 13
        )
        await client.emitPush(
            sessionID: "sess-shared",
            data: Data("abc".utf8),
            offset: 13
        )
        await client.emitPush(
            sessionID: "sess-shared",
            data: Data("bcd".utf8),
            offset: 14
        )

        XCTAssertEqual(outputs.values(), [
            Data("prompt ".utf8),
            Data("abc".utf8),
            Data("d".utf8),
        ])

        await transport.disconnect()
    }

    func testConnectOpensFreshTerminalWhenStoredSessionIsGone() async throws {
        let client = StubDaemonSessionClient(
            hello: .init(
                name: "cmuxd-remote",
                version: "dev",
                instanceID: nil,
                capabilities: ["terminal.stream"]
            ),
            attachResult: .failure(
                TerminalRemoteDaemonClientError.rpc(code: "not_found", message: "session not found")
            ),
            openResult: .init(
                sessionID: "sess-new",
                attachmentID: "att-new",
                attachments: [],
                effectiveCols: 100,
                effectiveRows: 30,
                lastKnownCols: 100,
                lastKnownRows: 30,
                offset: 0,
                gridGeneration: nil
            ),
            readResults: []
        )
        let transport = TerminalRemoteDaemonSessionTransport(
            client: client,
            command: "tmux new-session -A -s demo",
            resumeState: .init(sessionID: "sess-stale", attachmentID: "att-stale", readOffset: 4)
        )

        try await transport.connect(initialSize: TerminalGridSize.fixture(columns: 100, rows: 30))

        let attachCalls = await client.recordedAttaches()
        let openedCommands = await client.openedCommands()
        XCTAssertEqual(attachCalls.count, 1)
        XCTAssertEqual(attachCalls.first?.sessionID, "sess-stale")
        XCTAssertEqual(openedCommands, ["tmux new-session -A -s demo"])
        XCTAssertEqual(
            transport.remoteDaemonResumeStateSnapshot(),
            TerminalRemoteDaemonResumeState(
                sessionID: "sess-new",
                attachmentID: "att-new",
                readOffset: 0
            )
        )

        await transport.disconnect()
    }
}

private actor StubDaemonSessionClient: TerminalRemoteDaemonSessionClient, TerminalRemoteDaemonPushSubscribing {
    private let hello: TerminalRemoteDaemonHello
    private let attachResult: Result<TerminalRemoteDaemonSessionStatus, Error>?
    private let openResult: TerminalRemoteDaemonTerminalOpenResult
    private let historyResult: TerminalRemoteDaemonSessionHistoryResult
    private let subscribeResult: Result<TerminalRemoteDaemonTerminalReadResult, Error>?
    private var readResults: [Result<TerminalRemoteDaemonTerminalReadResult, Error>]
    private var openedCommandValues: [String] = []
    private var openedSessionIDs: [String?] = []
    private var attachValues: [(sessionID: String, attachmentID: String, cols: Int, rows: Int)] = []
    private var detachValues: [(sessionID: String, attachmentID: String)] = []
    private var writeValues: [Data] = []
    private var resizeValues: [(sessionID: String, attachmentID: String, cols: Int, rows: Int)] = []
    private var readValues: [(sessionID: String, offset: UInt64, maxBytes: Int, timeoutMilliseconds: Int)] = []
    private var closedSessionValues: [String] = []
    private var historyValues: [(sessionID: String, format: String)] = []
    private var subscribeValues: [(sessionID: String, offset: UInt64?)] = []
    private var pushHandlers: [String: @Sendable (TerminalPushEvent) -> Void] = [:]

    init(
        hello: TerminalRemoteDaemonHello,
        attachResult: Result<TerminalRemoteDaemonSessionStatus, Error>? = nil,
        openResult: TerminalRemoteDaemonTerminalOpenResult,
        readResults: [Result<TerminalRemoteDaemonTerminalReadResult, Error>],
        historyResult: TerminalRemoteDaemonSessionHistoryResult = .init(sessionID: "sess", history: ""),
        subscribeResult: Result<TerminalRemoteDaemonTerminalReadResult, Error>? = nil
    ) {
        self.hello = hello
        self.attachResult = attachResult
        self.openResult = openResult
        self.readResults = readResults
        self.historyResult = historyResult
        self.subscribeResult = subscribeResult
    }

    func sendHello() async throws -> TerminalRemoteDaemonHello {
        hello
    }

    func sessionAttach(
        sessionID: String,
        attachmentID: String,
        cols: Int,
        rows: Int
    ) async throws -> TerminalRemoteDaemonSessionStatus {
        attachValues.append((sessionID, attachmentID, cols, rows))
        guard let attachResult else {
            throw TerminalRemoteDaemonClientError.rpc(code: "not_found", message: "session not found")
        }
        return try attachResult.get()
    }

    func terminalOpen(
        command: String,
        cols: Int,
        rows: Int,
        sessionID: String?
    ) async throws -> TerminalRemoteDaemonTerminalOpenResult {
        openedCommandValues.append(command)
        openedSessionIDs.append(sessionID)
        return openResult
    }

    func terminalWrite(sessionID: String, data: Data) async throws {
        writeValues.append(data)
    }

    func terminalRead(
        sessionID: String,
        offset: UInt64,
        maxBytes: Int,
        timeoutMilliseconds: Int
    ) async throws -> TerminalRemoteDaemonTerminalReadResult {
        readValues.append((sessionID, offset, maxBytes, timeoutMilliseconds))
        guard !readResults.isEmpty else {
            throw TerminalRemoteDaemonClientError.rpc(
                code: "deadline_exceeded",
                message: "terminal read timed out"
            )
        }
        return try readResults.removeFirst().get()
    }

    func sessionResize(
        sessionID: String,
        attachmentID: String,
        cols: Int,
        rows: Int
    ) async throws -> TerminalRemoteDaemonSessionStatus {
        resizeValues.append((sessionID, attachmentID, cols, rows))
        return .init(
            sessionID: sessionID,
            attachments: [],
            effectiveCols: cols,
            effectiveRows: rows,
            lastKnownCols: cols,
            lastKnownRows: rows,
            gridGeneration: nil
        )
    }

    func sessionDetach(sessionID: String, attachmentID: String) async throws -> TerminalRemoteDaemonSessionStatus {
        detachValues.append((sessionID, attachmentID))
        return .init(
            sessionID: sessionID,
            attachments: [],
            effectiveCols: 0,
            effectiveRows: 0,
            lastKnownCols: 0,
            lastKnownRows: 0,
            gridGeneration: nil
        )
    }

    func sessionClose(sessionID: String) async throws {
        closedSessionValues.append(sessionID)
    }

    func sessionHistory(sessionID: String, format: String) async throws -> TerminalRemoteDaemonSessionHistoryResult {
        historyValues.append((sessionID, format))
        return historyResult
    }

    func workspaceList() async throws -> TerminalRemoteDaemonWorkspaceListResult {
        TerminalRemoteDaemonWorkspaceListResult(
            workspaces: [],
            selectedWorkspaceID: nil,
            changeSeq: 0
        )
    }

    func openedCommands() -> [String] {
        openedCommandValues
    }

    func recordedOpenedSessionIDs() -> [String?] {
        openedSessionIDs
    }

    func recordedAttaches() -> [(sessionID: String, attachmentID: String, cols: Int, rows: Int)] {
        attachValues
    }

    func recordedWrites() -> [Data] {
        writeValues
    }

    func recordedResizes() -> [(sessionID: String, attachmentID: String, cols: Int, rows: Int)] {
        resizeValues
    }

    func recordedReads() -> [(sessionID: String, offset: UInt64, maxBytes: Int, timeoutMilliseconds: Int)] {
        readValues
    }

    func recordedDetaches() -> [(sessionID: String, attachmentID: String)] {
        detachValues
    }

    func closedSessions() -> [String] {
        closedSessionValues
    }

    func recordedHistoryRequests() -> [(sessionID: String, format: String)] {
        historyValues
    }

    func setPushHandler(sessionID: String, handler: @escaping @Sendable (TerminalPushEvent) -> Void) async {
        pushHandlers[sessionID] = handler
    }

    func removePushHandler(sessionID: String) async {
        pushHandlers.removeValue(forKey: sessionID)
    }

    func terminalSubscribe(sessionID: String, offset: UInt64?) async throws -> TerminalRemoteDaemonTerminalReadResult {
        subscribeValues.append((sessionID, offset))
        guard let subscribeResult else {
            throw TerminalRemoteDaemonClientError.rpc(
                code: "missing_subscribe_result",
                message: "terminal subscribe was not stubbed"
            )
        }
        return try subscribeResult.get()
    }

    func recordedSubscriptions() -> [(sessionID: String, offset: UInt64?)] {
        subscribeValues
    }

    func emitPush(sessionID: String, data: Data, offset: UInt64) {
        pushHandlers[sessionID]?(
            .output(
                data: data,
                offset: offset,
                baseOffset: 0,
                truncated: false,
                eof: false,
                seq: offset,
                notifications: nil
            )
        )
    }
}

private final class StubTerminalTransport: TerminalTransport {
    var eventHandler: (@Sendable (TerminalTransportEvent) -> Void)?

    func connect(initialSize: TerminalGridSize) async throws {}
    func send(_ data: Data) async throws {}
    func resize(_ size: TerminalGridSize) async {}
    func disconnect() async {}
}

private extension TerminalGridSize {
    static func fixture(columns: Int, rows: Int) -> Self {
        .init(columns: columns, rows: rows, pixelWidth: columns * 10, pixelHeight: rows * 20)
    }
}

private final class LockedOutputs: @unchecked Sendable {
    private let lock = NSLock()
    private var data: [Data] = []

    func append(_ value: Data) {
        lock.lock()
        data.append(value)
        lock.unlock()
    }

    func values() -> [Data] {
        lock.lock()
        defer { lock.unlock() }
        return data
    }
}
