import XCTest
@testable import cmux_DEV

final class TerminalRemoteDaemonBootstrapTransportTests: XCTestCase {
    func testConnectBootstrapsDaemonAndForwardsSessionEvents() async throws {
        let sshSession = StubBootstrapSSHSession(capturedHostKey: "ssh-ed25519 AAAATEST")
        let sessionClient = StubBootstrapSessionClient(
            hello: .init(
                name: "cmuxd-remote",
                version: "dev",
                instanceID: nil,
                capabilities: ["terminal.stream"]
            ),
            attachResult: nil,
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
                .success(
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
        let transport = TerminalRemoteDaemonBootstrapTransport(
            host: TerminalHost(
                name: "Mac Mini",
                hostname: "cmux-macmini",
                username: "cmux",
                symbolName: "desktopcomputer",
                palette: .mint,
                bootstrapCommand: "tmux new-session -A -s {{session}}",
                transportPreference: .remoteDaemon
            ),
            credentials: TerminalSSHCredentials(password: "secret", privateKey: nil),
            sessionName: "demo",
            sshSessionFactory: { _, _ in sshSession },
            bootstrapSessionFactory: { _ in
                StubBootstrapPreparer(
                    launchConfig: .init(
                        remoteBinaryPath: "~/.cmux/bin/cmuxd-remote/dev/linux-amd64/cmuxd-remote",
                        launchCommand: "~/.cmux/bin/cmuxd-remote/dev/linux-amd64/cmuxd-remote serve --stdio",
                        platform: .init(goOS: "linux", goArch: "amd64")
                    )
                )
            },
            sessionClientFactory: { _ in sessionClient }
        )

        let connectedExpectation = expectation(description: "connected")
        let outputExpectation = expectation(description: "output")
        var events: [TerminalTransportEvent] = []

        transport.eventHandler = { (event: TerminalTransportEvent) in
            events.append(event)
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

        XCTAssertFalse(
            events.contains {
                if case .trustedHostKey = $0 {
                    return true
                }
                return false
            }
        )

        let launchCommands = await sshSession.openedLaunchCommands()
        XCTAssertEqual(
            launchCommands,
            ["~/.cmux/bin/cmuxd-remote/dev/linux-amd64/cmuxd-remote serve --stdio"]
        )

        let openedCommands = await sessionClient.openedCommands()
        XCTAssertEqual(openedCommands, ["tmux new-session -A -s demo"])
    }

    func testSendResizeAndDisconnectDelegateToSessionTransportAndCloseSSHSession() async throws {
        let sshSession = StubBootstrapSSHSession(capturedHostKey: nil)
        let sessionClient = StubBootstrapSessionClient(
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
        let transport = TerminalRemoteDaemonBootstrapTransport(
            host: TerminalHost(
                name: "Mac Mini",
                hostname: "cmux-macmini",
                username: "cmux",
                symbolName: "desktopcomputer",
                palette: .mint,
                bootstrapCommand: "tmux new-session -A -s {{session}}",
                transportPreference: .remoteDaemon
            ),
            credentials: TerminalSSHCredentials(password: "secret", privateKey: nil),
            sessionName: "demo",
            sshSessionFactory: { _, _ in sshSession },
            bootstrapSessionFactory: { _ in
                StubBootstrapPreparer(
                    launchConfig: .init(
                        remoteBinaryPath: "~/.cmux/bin/cmuxd-remote/dev/linux-amd64/cmuxd-remote",
                        launchCommand: "~/.cmux/bin/cmuxd-remote/dev/linux-amd64/cmuxd-remote serve --stdio",
                        platform: .init(goOS: "linux", goArch: "amd64")
                    )
                )
            },
            sessionClientFactory: { _ in sessionClient }
        )

        try await transport.connect(initialSize: TerminalGridSize.fixture(columns: 80, rows: 24))
        try await transport.send(Data("ls\n".utf8))
        await transport.resize(TerminalGridSize.fixture(columns: 100, rows: 30))
        await transport.disconnect()

        let writes = await sessionClient.recordedWrites()
        XCTAssertEqual(writes, [Data("ls\n".utf8)])

        let resizeCalls = await sessionClient.recordedResizes()
        XCTAssertEqual(resizeCalls.count, 1)
        XCTAssertEqual(resizeCalls.first?.sessionID, "sess-9")
        XCTAssertEqual(resizeCalls.first?.attachmentID, "att-9")
        XCTAssertEqual(resizeCalls.first?.cols, 100)
        XCTAssertEqual(resizeCalls.first?.rows, 30)

        let didDisconnectSSH = await sshSession.didDisconnect()
        XCTAssertTrue(didDisconnectSSH)
    }

    func testConnectUsesResumeStateWhenProvided() async throws {
        let sshSession = StubBootstrapSSHSession(capturedHostKey: nil)
        let sessionClient = StubBootstrapSessionClient(
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
                    effectiveCols: 90,
                    effectiveRows: 20,
                    lastKnownCols: 90,
                    lastKnownRows: 20,
                    gridGeneration: nil
                )
            ),
            openResult: .init(
                sessionID: "sess-new",
                attachmentID: "att-new",
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
        let transport = TerminalRemoteDaemonBootstrapTransport(
            host: TerminalHost(
                name: "Mac Mini",
                hostname: "cmux-macmini",
                username: "cmux",
                symbolName: "desktopcomputer",
                palette: .mint,
                bootstrapCommand: "tmux new-session -A -s {{session}}",
                transportPreference: .remoteDaemon
            ),
            credentials: TerminalSSHCredentials(password: "secret", privateKey: nil),
            sessionName: "demo",
            resumeState: .init(sessionID: "sess-existing", attachmentID: "att-existing", readOffset: 11),
            sshSessionFactory: { _, _ in sshSession },
            bootstrapSessionFactory: { _ in
                StubBootstrapPreparer(
                    launchConfig: .init(
                        remoteBinaryPath: "~/.cmux/bin/cmuxd-remote/dev/linux-amd64/cmuxd-remote",
                        launchCommand: "~/.cmux/bin/cmuxd-remote/dev/linux-amd64/cmuxd-remote serve --stdio",
                        platform: .init(goOS: "linux", goArch: "amd64")
                    )
                )
            },
            sessionClientFactory: { _ in sessionClient }
        )

        let connectedExpectation = expectation(description: "connected")
        transport.eventHandler = { (event: TerminalTransportEvent) in
            if case .connected = event {
                connectedExpectation.fulfill()
            }
        }

        try await transport.connect(initialSize: TerminalGridSize.fixture(columns: 90, rows: 20))
        await fulfillment(of: [connectedExpectation], timeout: 1.0)

        let attachCalls = await sessionClient.recordedAttaches()
        let openedCommands = await sessionClient.openedCommands()
        XCTAssertEqual(attachCalls.count, 1)
        XCTAssertEqual(attachCalls.first?.sessionID, "sess-existing")
        XCTAssertEqual(attachCalls.first?.attachmentID, "att-existing")
        XCTAssertEqual(openedCommands, [String]())
        XCTAssertEqual(
            transport.remoteDaemonResumeStateSnapshot(),
            TerminalRemoteDaemonResumeState(
                sessionID: "sess-existing",
                attachmentID: "att-existing",
                readOffset: 11
            )
        )

        await transport.disconnect()
    }

    func testSuspendPreservingSessionDetachesSessionAndClosesSSHConnection() async throws {
        let sshSession = StubBootstrapSSHSession(capturedHostKey: nil)
        let sessionClient = StubBootstrapSessionClient(
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
                effectiveCols: 80,
                effectiveRows: 24,
                lastKnownCols: 80,
                lastKnownRows: 24,
                offset: 0,
                gridGeneration: nil
            ),
            readResults: []
        )
        let transport = TerminalRemoteDaemonBootstrapTransport(
            host: TerminalHost(
                name: "Mac Mini",
                hostname: "cmux-macmini",
                username: "cmux",
                symbolName: "desktopcomputer",
                palette: .mint,
                bootstrapCommand: "tmux new-session -A -s {{session}}",
                transportPreference: .remoteDaemon
            ),
            credentials: TerminalSSHCredentials(password: "secret", privateKey: nil),
            sessionName: "demo",
            sshSessionFactory: { _, _ in sshSession },
            bootstrapSessionFactory: { _ in
                StubBootstrapPreparer(
                    launchConfig: .init(
                        remoteBinaryPath: "~/.cmux/bin/cmuxd-remote/dev/linux-amd64/cmuxd-remote",
                        launchCommand: "~/.cmux/bin/cmuxd-remote/dev/linux-amd64/cmuxd-remote serve --stdio",
                        platform: .init(goOS: "linux", goArch: "amd64")
                    )
                )
            },
            sessionClientFactory: { _ in sessionClient }
        )

        try await transport.connect(initialSize: TerminalGridSize.fixture(columns: 80, rows: 24))
        XCTAssertEqual(
            transport.remoteDaemonResumeStateSnapshot(),
            TerminalRemoteDaemonResumeState(
                sessionID: "sess-park",
                attachmentID: "att-park",
                readOffset: 0
            )
        )

        await transport.suspendPreservingSession()

        let detachCalls = await sessionClient.recordedDetaches()
        let closedSessions = await sessionClient.closedSessions()
        XCTAssertEqual(detachCalls.count, 1)
        XCTAssertEqual(detachCalls.first?.sessionID, "sess-park")
        XCTAssertEqual(detachCalls.first?.attachmentID, "att-park")
        XCTAssertEqual(closedSessions, [String]())
        let didDisconnectSSH = await sshSession.didDisconnect()
        XCTAssertTrue(didDisconnectSSH)
        XCTAssertEqual(
            transport.remoteDaemonResumeStateSnapshot(),
            TerminalRemoteDaemonResumeState(
                sessionID: "sess-park",
                attachmentID: "att-park",
                readOffset: 0
            )
        )
    }

    func testConnectFailsWhenBootstrapPreparationTimesOut() async throws {
        let sshSession = StubBootstrapSSHSession(capturedHostKey: nil)
        let transport = TerminalRemoteDaemonBootstrapTransport(
            host: TerminalHost(
                name: "Mac Mini",
                hostname: "cmux-macmini",
                username: "cmux",
                symbolName: "desktopcomputer",
                palette: .mint,
                bootstrapCommand: "tmux new-session -A -s {{session}}",
                transportPreference: .remoteDaemon
            ),
            credentials: TerminalSSHCredentials(password: "secret", privateKey: nil),
            sessionName: "demo",
            bootstrapTimeout: 0.05,
            sshSessionFactory: { _, _ in sshSession },
            bootstrapSessionFactory: { _ in
                BlockingBootstrapPreparer()
            },
            sessionClientFactory: { _ in
                StubBootstrapSessionClient(
                    hello: .init(
                        name: "cmuxd-remote",
                        version: "dev",
                        instanceID: nil,
                        capabilities: ["terminal.stream"]
                    ),
                    attachResult: nil,
                    openResult: .init(
                        sessionID: "sess-unused",
                        attachmentID: "att-unused",
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
            }
        )

        do {
            try await transport.connect(initialSize: TerminalGridSize.fixture(columns: 80, rows: 24))
            XCTFail("Expected bootstrap timeout")
        } catch let error as TerminalRemoteDaemonBootstrapTransportError {
            switch error {
            case .bootstrapTimedOut:
                break
            default:
                XCTFail("Unexpected bootstrap transport error: \(error)")
            }
        }

        let didDisconnectSSH = await sshSession.didDisconnect()
        XCTAssertTrue(didDisconnectSSH)
    }
}

private struct StubBootstrapPreparer: TerminalRemoteDaemonBootstrapPreparing {
    let launchConfig: TerminalRemoteDaemonLaunchConfig

    func prepareDaemon() async throws -> TerminalRemoteDaemonLaunchConfig {
        launchConfig
    }
}

private struct BlockingBootstrapPreparer: TerminalRemoteDaemonBootstrapPreparing {
    func prepareDaemon() async throws -> TerminalRemoteDaemonLaunchConfig {
        try await Task.sleep(for: .seconds(5))
        return .init(
            remoteBinaryPath: "~/.cmux/bin/cmuxd-remote/dev/linux-amd64/cmuxd-remote",
            launchCommand: "~/.cmux/bin/cmuxd-remote/dev/linux-amd64/cmuxd-remote serve --stdio",
            platform: .init(goOS: "linux", goArch: "amd64")
        )
    }
}

private actor StubBootstrapSSHSession: TerminalRemoteDaemonBootstrapSSHSession {
    let capturedHostKey: String?

    private var launchCommands: [String] = []
    private var disconnected = false

    init(capturedHostKey: String?) {
        self.capturedHostKey = capturedHostKey
    }

    func run(_ command: String) async throws -> String {
        ""
    }

    func openDaemonTransport(launchCommand: String) async throws -> any TerminalRemoteDaemonTransport {
        launchCommands.append(launchCommand)
        return StubBootstrapLineTransport()
    }

    func disconnect() async {
        disconnected = true
    }

    func openedLaunchCommands() -> [String] {
        launchCommands
    }

    func didDisconnect() -> Bool {
        disconnected
    }
}

private actor StubBootstrapSessionClient: TerminalRemoteDaemonSessionClient {
    private let hello: TerminalRemoteDaemonHello
    private let attachResult: Result<TerminalRemoteDaemonSessionStatus, Error>?
    private let openResult: TerminalRemoteDaemonTerminalOpenResult
    private var readResults: [Result<TerminalRemoteDaemonTerminalReadResult, Error>]
    private var openedCommandValues: [String] = []
    private var openedSessionIDs: [String?] = []
    private var attachValues: [(sessionID: String, attachmentID: String, cols: Int, rows: Int)] = []
    private var detachValues: [(sessionID: String, attachmentID: String)] = []
    private var writeValues: [Data] = []
    private var resizeValues: [(sessionID: String, attachmentID: String, cols: Int, rows: Int)] = []
    private var closedSessionValues: [String] = []

    init(
        hello: TerminalRemoteDaemonHello,
        attachResult: Result<TerminalRemoteDaemonSessionStatus, Error>? = nil,
        openResult: TerminalRemoteDaemonTerminalOpenResult,
        readResults: [Result<TerminalRemoteDaemonTerminalReadResult, Error>]
    ) {
        self.hello = hello
        self.attachResult = attachResult
        self.openResult = openResult
        self.readResults = readResults
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
        TerminalRemoteDaemonSessionHistoryResult(sessionID: sessionID, history: "")
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

    func recordedAttaches() -> [(sessionID: String, attachmentID: String, cols: Int, rows: Int)] {
        attachValues
    }

    func recordedWrites() -> [Data] {
        writeValues
    }

    func recordedResizes() -> [(sessionID: String, attachmentID: String, cols: Int, rows: Int)] {
        resizeValues
    }

    func recordedDetaches() -> [(sessionID: String, attachmentID: String)] {
        detachValues
    }

    func closedSessions() -> [String] {
        closedSessionValues
    }
}

private struct StubBootstrapLineTransport: TerminalRemoteDaemonTransport {
    func writeLine(_ line: String) async throws {}
    func readLine() async throws -> String { "" }
}

private extension TerminalGridSize {
    static func fixture(columns: Int, rows: Int) -> Self {
        .init(columns: columns, rows: rows, pixelWidth: columns * 10, pixelHeight: rows * 20)
    }
}
