import XCTest
@testable import cmux_DEV

final class TerminalDirectDaemonTransportTests: XCTestCase {
    func testConnectUsesTicketServiceAndDirectTransportBeforeFallback() async throws {
        let ticketService = StubTerminalDaemonTicketService(
            result: .success(
                TerminalDaemonTicket(
                    ticket: "ticket-123",
                    directURL: try XCTUnwrap(URL(string: "tls://cmux.dev:9443")),
                    directTLSPins: [" sha256:ticket-pin ", "", "sha256:ticket-pin"],
                    sessionID: "sess-1",
                    attachmentID: "att-1",
                    expiresAt: Date(timeIntervalSince1970: 1_800_000_000)
                )
            )
        )
        let directClient = StubTerminalDirectDaemonConnector(
            result: .success(StubLineDaemonTransport())
        )
        let directSessionTransport = StubTerminalTransport()
        let fallbackTransport = StubTerminalTransport()
        let transport = TerminalDirectDaemonTransport(
            host: TerminalHost(
                stableID: "cmux-macmini",
                name: "Mac mini",
                hostname: "cmux-macmini",
                username: "cmux",
                symbolName: "desktopcomputer",
                palette: .mint,
                source: .discovered,
                transportPreference: .remoteDaemon,
                teamID: "team-1",
                serverID: "cmux-macmini",
                directTLSPins: ["sha256:host-pin"]
            ),
            credentials: TerminalSSHCredentials(password: "secret", privateKey: nil),
            sessionName: "cmux-dev",
            ticketService: ticketService,
            directClient: directClient,
            sessionTransportFactory: { _, _, _, _ in directSessionTransport },
            fallbackTransportFactory: { _, _, _, _ in fallbackTransport }
        )

        try await transport.connect(
            initialSize: TerminalGridSize(columns: 120, rows: 40, pixelWidth: 1200, pixelHeight: 800)
        )

        let firstRequest = ticketService.firstRequest()
        let connectCallCount = directClient.connectCallCount()
        let certificatePins = directClient.firstCertificatePins()
        XCTAssertEqual(firstRequest?.teamID, "team-1")
        XCTAssertEqual(firstRequest?.serverID, "cmux-macmini")
        XCTAssertEqual(firstRequest?.capabilities, ["session.open"])
        XCTAssertEqual(connectCallCount, 1)
        XCTAssertEqual(certificatePins, ["sha256:ticket-pin"])
        XCTAssertEqual(directSessionTransport.connectCallCount, 1)
        XCTAssertEqual(fallbackTransport.connectCallCount, 0)
    }

    func testConnectFallsBackOnConnectionFailure() async throws {
        let ticketService = StubTerminalDaemonTicketService(
            result: .success(
                TerminalDaemonTicket(
                    ticket: "ticket-123",
                    directURL: URL(string: "tls://cmux.dev:9443")!,
                    sessionID: "sess-1",
                    attachmentID: "att-1",
                    expiresAt: Date(timeIntervalSince1970: 1_800_000_000)
                )
            )
        )
        let directClient = StubTerminalDirectDaemonConnector(
            result: .failure(.connectionFailed("dns failed"))
        )
        let fallbackTransport = StubTerminalTransport()
        let recorder = NoticeRecorder()
        let transport = TerminalDirectDaemonTransport(
            host: TerminalHost(
                stableID: "cmux-macmini",
                name: "Mac mini",
                hostname: "cmux-macmini",
                username: "cmux",
                symbolName: "desktopcomputer",
                palette: .mint,
                source: .discovered,
                transportPreference: .remoteDaemon,
                teamID: "team-1",
                serverID: "cmux-macmini",
                directTLSPins: ["sha256:pin-a"]
            ),
            credentials: TerminalSSHCredentials(password: "secret", privateKey: nil),
            sessionName: "cmux-dev",
            ticketService: ticketService,
            directClient: directClient,
            sessionTransportFactory: { _, _, _, _ in StubTerminalTransport() },
            fallbackTransportFactory: { _, _, _, _ in fallbackTransport }
        )
        transport.eventHandler = { event in
            if case .notice(let message) = event {
                recorder.append(message)
            }
        }

        try await transport.connect(
            initialSize: TerminalGridSize(columns: 120, rows: 40, pixelWidth: 1200, pixelHeight: 800)
        )

        XCTAssertEqual(fallbackTransport.connectCallCount, 1)
        let notices = recorder.messages()
        XCTAssertEqual(
            notices,
            [
                String(
                    localized: "terminal.workspace.notice.fallback_ssh",
                    defaultValue: "Direct daemon unavailable, using SSH."
                )
            ]
        )
    }

    func testConnectDoesNotFallbackWithoutSSHCredential() async {
        let ticketService = StubTerminalDaemonTicketService(
            result: .success(
                TerminalDaemonTicket(
                    ticket: "ticket-123",
                    directURL: URL(string: "tls://cmux.dev:9443")!,
                    sessionID: "sess-1",
                    attachmentID: "att-1",
                    expiresAt: Date(timeIntervalSince1970: 1_800_000_000)
                )
            )
        )
        let directClient = StubTerminalDirectDaemonConnector(
            result: .failure(.connectionFailed("dns failed"))
        )
        let fallbackTransport = StubTerminalTransport()
        let transport = TerminalDirectDaemonTransport(
            host: TerminalHost(
                stableID: "cmux-macmini",
                name: "Mac mini",
                hostname: "cmux-macmini",
                username: "cmux",
                symbolName: "desktopcomputer",
                palette: .mint,
                source: .discovered,
                transportPreference: .remoteDaemon,
                teamID: "team-1",
                serverID: "cmux-macmini"
            ),
            credentials: TerminalSSHCredentials(password: "", privateKey: nil),
            sessionName: "cmux-dev",
            ticketService: ticketService,
            directClient: directClient,
            sessionTransportFactory: { _, _, _, _ in StubTerminalTransport() },
            fallbackTransportFactory: { _, _, _, _ in fallbackTransport }
        )

        do {
            try await transport.connect(
                initialSize: TerminalGridSize(columns: 120, rows: 40, pixelWidth: 1200, pixelHeight: 800)
            )
            XCTFail("expected connect to fail")
        } catch let error as TerminalDirectDaemonClientError {
            XCTAssertEqual(error, .connectionFailed("dns failed"))
            XCTAssertEqual(fallbackTransport.connectCallCount, 0)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testConnectUsesBootstrapTransportDirectlyForManualCmuxdHostWithoutTeamScope() async throws {
        let ticketService = StubTerminalDaemonTicketService(
            result: .success(
                TerminalDaemonTicket(
                    ticket: "ticket-123",
                    directURL: URL(string: "tls://cmux.dev:9443")!,
                    sessionID: "sess-1",
                    attachmentID: "att-1",
                    expiresAt: Date(timeIntervalSince1970: 1_800_000_000)
                )
            )
        )
        let directClient = StubTerminalDirectDaemonConnector(
            result: .success(StubLineDaemonTransport())
        )
        let bootstrapTransport = StubTerminalTransport()
        let recorder = NoticeRecorder()
        let transport = TerminalDirectDaemonTransport(
            host: TerminalHost(
                name: "Mac mini",
                hostname: "cmux-macmini",
                username: "cmux",
                symbolName: "desktopcomputer",
                palette: .mint,
                source: .custom,
                transportPreference: .remoteDaemon,
                allowsSSHFallback: true
            ),
            credentials: TerminalSSHCredentials(password: "secret", privateKey: nil),
            sessionName: "cmux-dev",
            ticketService: ticketService,
            directClient: directClient,
            sessionTransportFactory: { _, _, _, _ in StubTerminalTransport() },
            fallbackTransportFactory: { _, _, _, _ in bootstrapTransport }
        )
        transport.eventHandler = { event in
            if case .notice(let message) = event {
                recorder.append(message)
            }
        }

        try await transport.connect(
            initialSize: TerminalGridSize(columns: 120, rows: 40, pixelWidth: 1200, pixelHeight: 800)
        )

        XCTAssertEqual(ticketService.requestCount(), 0)
        XCTAssertEqual(directClient.connectCallCount(), 0)
        XCTAssertEqual(bootstrapTransport.connectCallCount, 1)
        XCTAssertEqual(recorder.messages(), [])
    }

    func testConnectDoesNotFallbackOnUnauthorizedTicket() async {
        let ticketService = StubTerminalDaemonTicketService(
            result: .success(
                TerminalDaemonTicket(
                    ticket: "ticket-123",
                    directURL: URL(string: "tls://cmux.dev:9443")!,
                    sessionID: "sess-1",
                    attachmentID: "att-1",
                    expiresAt: Date(timeIntervalSince1970: 1_800_000_000)
                )
            )
        )
        let directClient = StubTerminalDirectDaemonConnector(
            result: .failure(.handshakeRejected(code: "unauthorized", message: "ticket rejected"))
        )
        let fallbackTransport = StubTerminalTransport()
        let transport = TerminalDirectDaemonTransport(
            host: TerminalHost(
                stableID: "cmux-macmini",
                name: "Mac mini",
                hostname: "cmux-macmini",
                username: "cmux",
                symbolName: "desktopcomputer",
                palette: .mint,
                source: .discovered,
                transportPreference: .remoteDaemon,
                teamID: "team-1",
                serverID: "cmux-macmini"
            ),
            credentials: TerminalSSHCredentials(password: "secret", privateKey: nil),
            sessionName: "cmux-dev",
            ticketService: ticketService,
            directClient: directClient,
            sessionTransportFactory: { _, _, _, _ in StubTerminalTransport() },
            fallbackTransportFactory: { _, _, _, _ in fallbackTransport }
        )

        do {
            try await transport.connect(
                initialSize: TerminalGridSize(columns: 120, rows: 40, pixelWidth: 1200, pixelHeight: 800)
            )
            XCTFail("expected connect to fail")
        } catch let error as TerminalDirectDaemonClientError {
            XCTAssertEqual(
                error,
                .handshakeRejected(code: "unauthorized", message: "ticket rejected")
            )
            XCTAssertEqual(fallbackTransport.connectCallCount, 0)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testConnectInvalidatesRejectedCachedTicketAndRetriesDirectConnect() async throws {
        let ticketService = StubTerminalDaemonTicketService(
            results: [
                .success(
                    TerminalDaemonTicket(
                        ticket: "ticket-stale",
                        directURL: URL(string: "tls://cmux.dev:9443")!,
                        sessionID: "sess-1",
                        attachmentID: "att-1",
                        expiresAt: Date(timeIntervalSince1970: 1_800_000_000)
                    )
                ),
                .success(
                    TerminalDaemonTicket(
                        ticket: "ticket-fresh",
                        directURL: URL(string: "tls://cmux.dev:9443")!,
                        sessionID: "sess-1",
                        attachmentID: "att-1",
                        expiresAt: Date(timeIntervalSince1970: 1_800_000_100)
                    )
                ),
            ]
        )
        let directClient = StubTerminalDirectDaemonConnector(
            results: [
                .failure(.handshakeRejected(code: "unauthorized", message: "ticket rejected")),
                .success(StubLineDaemonTransport()),
            ]
        )
        let directSessionTransport = StubTerminalTransport()
        let fallbackTransport = StubTerminalTransport()
        let transport = TerminalDirectDaemonTransport(
            host: TerminalHost(
                stableID: "cmux-macmini",
                name: "Mac mini",
                hostname: "cmux-macmini",
                username: "cmux",
                symbolName: "desktopcomputer",
                palette: .mint,
                source: .discovered,
                transportPreference: .remoteDaemon,
                teamID: "team-1",
                serverID: "cmux-macmini"
            ),
            credentials: TerminalSSHCredentials(password: "secret", privateKey: nil),
            sessionName: "cmux-dev",
            ticketService: ticketService,
            directClient: directClient,
            sessionTransportFactory: { _, _, _, _ in directSessionTransport },
            fallbackTransportFactory: { _, _, _, _ in fallbackTransport }
        )

        try await transport.connect(
            initialSize: TerminalGridSize(columns: 120, rows: 40, pixelWidth: 1200, pixelHeight: 800)
        )

        XCTAssertEqual(ticketService.requestCount(), 2)
        XCTAssertEqual(ticketService.invalidatedRequests().count, 1)
        XCTAssertEqual(directClient.recordedTickets(), ["ticket-stale", "ticket-fresh"])
        XCTAssertEqual(directSessionTransport.connectCallCount, 1)
        XCTAssertEqual(fallbackTransport.connectCallCount, 0)
    }

    func testConnectDoesNotFallbackOnTLSRejection() async {
        let ticketService = StubTerminalDaemonTicketService(
            result: .success(
                TerminalDaemonTicket(
                    ticket: "ticket-123",
                    directURL: URL(string: "tls://cmux.dev:9443")!,
                    sessionID: "sess-1",
                    attachmentID: "att-1",
                    expiresAt: Date(timeIntervalSince1970: 1_800_000_000)
                )
            )
        )
        let directClient = StubTerminalDirectDaemonConnector(
            result: .failure(.tlsRejected("certificate pin mismatch"))
        )
        let fallbackTransport = StubTerminalTransport()
        let transport = TerminalDirectDaemonTransport(
            host: TerminalHost(
                stableID: "cmux-macmini",
                name: "Mac mini",
                hostname: "cmux-macmini",
                username: "cmux",
                symbolName: "desktopcomputer",
                palette: .mint,
                source: .discovered,
                transportPreference: .remoteDaemon,
                teamID: "team-1",
                serverID: "cmux-macmini",
                directTLSPins: ["sha256:pin-a"]
            ),
            credentials: TerminalSSHCredentials(password: "secret", privateKey: nil),
            sessionName: "cmux-dev",
            ticketService: ticketService,
            directClient: directClient,
            sessionTransportFactory: { _, _, _, _ in StubTerminalTransport() },
            fallbackTransportFactory: { _, _, _, _ in fallbackTransport }
        )

        do {
            try await transport.connect(
                initialSize: TerminalGridSize(columns: 120, rows: 40, pixelWidth: 1200, pixelHeight: 800)
            )
            XCTFail("expected connect to fail")
        } catch let error as TerminalDirectDaemonClientError {
            XCTAssertEqual(error, .tlsRejected("certificate pin mismatch"))
            XCTAssertEqual(fallbackTransport.connectCallCount, 0)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testConnectDoesNotFallbackOnInvalidTicketServiceResponse() async {
        let ticketService = StubTerminalDaemonTicketService(
            result: .failure(TerminalDaemonTicketServiceError.invalidResponse)
        )
        let directClient = StubTerminalDirectDaemonConnector(
            result: .success(StubLineDaemonTransport())
        )
        let fallbackTransport = StubTerminalTransport()
        let transport = TerminalDirectDaemonTransport(
            host: TerminalHost(
                stableID: "cmux-macmini",
                name: "Mac mini",
                hostname: "cmux-macmini",
                username: "cmux",
                symbolName: "desktopcomputer",
                palette: .mint,
                source: .discovered,
                transportPreference: .remoteDaemon,
                teamID: "team-1",
                serverID: "cmux-macmini"
            ),
            credentials: TerminalSSHCredentials(password: "secret", privateKey: nil),
            sessionName: "cmux-dev",
            ticketService: ticketService,
            directClient: directClient,
            sessionTransportFactory: { _, _, _, _ in StubTerminalTransport() },
            fallbackTransportFactory: { _, _, _, _ in fallbackTransport }
        )

        do {
            try await transport.connect(
                initialSize: TerminalGridSize(columns: 120, rows: 40, pixelWidth: 1200, pixelHeight: 800)
            )
            XCTFail("expected connect to fail")
        } catch let error as TerminalDaemonTicketServiceError {
            if case .invalidResponse = error {
                XCTAssertTrue(true)
            } else {
                XCTFail("unexpected ticket service error: \(error)")
            }
            XCTAssertEqual(directClient.connectCallCount(), 0)
            XCTAssertEqual(fallbackTransport.connectCallCount, 0)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testConnectRequestsExistingResumeStateAndPassesNormalizedResumeStateToSessionTransport() async throws {
        let ticketService = StubTerminalDaemonTicketService(
            result: .success(
                TerminalDaemonTicket(
                    ticket: "ticket-123",
                    directURL: try XCTUnwrap(URL(string: "tls://cmux.dev:9443")),
                    sessionID: "sess-ticket",
                    attachmentID: "att-ticket",
                    expiresAt: Date(timeIntervalSince1970: 1_800_000_000)
                )
            )
        )
        let directClient = StubTerminalDirectDaemonConnector(
            result: .success(StubLineDaemonTransport())
        )
        let directSessionTransport = StubTerminalTransport()
        let initialResumeState = TerminalRemoteDaemonResumeState(
            sessionID: "sess-existing",
            attachmentID: "att-existing",
            readOffset: 17
        )
        let resumeStateRecorder = ResumeStateRecorder()
        let transport = TerminalDirectDaemonTransport(
            host: TerminalHost(
                stableID: "cmux-macmini",
                name: "Mac mini",
                hostname: "cmux-macmini",
                username: "cmux",
                symbolName: "desktopcomputer",
                palette: .mint,
                source: .discovered,
                transportPreference: .remoteDaemon,
                teamID: "team-1",
                serverID: "cmux-macmini"
            ),
            credentials: TerminalSSHCredentials(password: "secret", privateKey: nil),
            sessionName: "cmux-dev",
            resumeState: initialResumeState,
            ticketService: ticketService,
            directClient: directClient,
            sessionTransportFactory: { _, _, _, resumeState in
                resumeStateRecorder.set(resumeState)
                return directSessionTransport
            },
            fallbackTransportFactory: { _, _, _, _ in StubTerminalTransport() }
        )

        try await transport.connect(
            initialSize: TerminalGridSize(columns: 120, rows: 40, pixelWidth: 1200, pixelHeight: 800)
        )

        let request = ticketService.firstRequest()
        XCTAssertEqual(request?.sessionID, "sess-existing")
        XCTAssertEqual(request?.attachmentID, "att-existing")
        XCTAssertEqual(Set(request?.capabilities ?? []), Set(["session.open", "session.attach"]))
        XCTAssertEqual(
            resumeStateRecorder.value(),
            TerminalRemoteDaemonResumeState(
                sessionID: "sess-ticket",
                attachmentID: "att-ticket",
                readOffset: 0
            )
        )
    }

    func testSuspendPreservingSessionDelegatesToActiveTransportParker() async throws {
        let ticketService = StubTerminalDaemonTicketService(
            result: .success(
                TerminalDaemonTicket(
                    ticket: "ticket-123",
                    directURL: try XCTUnwrap(URL(string: "tls://cmux.dev:9443")),
                    sessionID: "sess-ticket",
                    attachmentID: "att-ticket",
                    expiresAt: Date(timeIntervalSince1970: 1_800_000_000)
                )
            )
        )
        let directClient = StubTerminalDirectDaemonConnector(
            result: .success(StubLineDaemonTransport())
        )
        let directSessionTransport = ParkingSnapshotStubTerminalTransport(
            resumeState: .init(sessionID: "sess-ticket", attachmentID: "att-ticket", readOffset: 17)
        )
        let transport = TerminalDirectDaemonTransport(
            host: TerminalHost(
                stableID: "cmux-macmini",
                name: "Mac mini",
                hostname: "cmux-macmini",
                username: "cmux",
                symbolName: "desktopcomputer",
                palette: .mint,
                source: .discovered,
                transportPreference: .remoteDaemon,
                teamID: "team-1",
                serverID: "cmux-macmini"
            ),
            credentials: TerminalSSHCredentials(password: "secret", privateKey: nil),
            sessionName: "cmux-dev",
            ticketService: ticketService,
            directClient: directClient,
            sessionTransportFactory: { _, _, _, _ in directSessionTransport },
            fallbackTransportFactory: { _, _, _, _ in StubTerminalTransport() }
        )

        try await transport.connect(
            initialSize: TerminalGridSize(columns: 120, rows: 40, pixelWidth: 1200, pixelHeight: 800)
        )
        XCTAssertEqual(
            transport.remoteDaemonResumeStateSnapshot(),
            .init(sessionID: "sess-ticket", attachmentID: "att-ticket", readOffset: 17)
        )

        await transport.suspendPreservingSession()

        XCTAssertEqual(directSessionTransport.parkCallCount, 1)
        XCTAssertEqual(directSessionTransport.disconnectCallCount, 0)
        XCTAssertEqual(
            transport.remoteDaemonResumeStateSnapshot(),
            .init(sessionID: "sess-ticket", attachmentID: "att-ticket", readOffset: 17)
        )
    }
}

private final class StubTerminalDaemonTicketService: TerminalDaemonTicketProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [TerminalDaemonTicketRequest] = []
    private var invalidations: [TerminalDaemonTicketRequest] = []
    private let results: [Result<TerminalDaemonTicket, Error>]
    private var nextResultIndex = 0

    init(result: Result<TerminalDaemonTicket, Error>) {
        self.results = [result]
    }

    init(results: [Result<TerminalDaemonTicket, Error>]) {
        self.results = results
    }

    func fetchTicket(request: TerminalDaemonTicketRequest) async throws -> TerminalDaemonTicket {
        lock.lock()
        requests.append(request)
        let resultIndex = min(nextResultIndex, results.count - 1)
        nextResultIndex += 1
        lock.unlock()
        return try results[resultIndex].get()
    }

    func invalidateTicket(request: TerminalDaemonTicketRequest) {
        lock.lock()
        invalidations.append(request)
        lock.unlock()
    }

    func firstRequest() -> TerminalDaemonTicketRequest? {
        lock.lock()
        let snapshot = requests.first
        lock.unlock()
        return snapshot
    }

    func requestCount() -> Int {
        lock.lock()
        let snapshot = requests.count
        lock.unlock()
        return snapshot
    }

    func invalidatedRequests() -> [TerminalDaemonTicketRequest] {
        lock.lock()
        let snapshot = invalidations
        lock.unlock()
        return snapshot
    }
}

private final class StubTerminalDirectDaemonConnector: TerminalDirectDaemonConnecting, @unchecked Sendable {
    private let lock = NSLock()
    private var connectCalls: [(url: URL, ticket: String, certificatePins: [String])] = []
    private let results: [Result<any TerminalRemoteDaemonTransport, TerminalDirectDaemonClientError>]
    private var nextResultIndex = 0

    init(result: Result<any TerminalRemoteDaemonTransport, TerminalDirectDaemonClientError>) {
        self.results = [result]
    }

    init(results: [Result<any TerminalRemoteDaemonTransport, TerminalDirectDaemonClientError>]) {
        self.results = results
    }

    func connect(url: URL, ticket: String, certificatePins: [String]) async throws -> any TerminalRemoteDaemonTransport {
        lock.lock()
        connectCalls.append((url, ticket, certificatePins))
        let resultIndex = min(nextResultIndex, results.count - 1)
        nextResultIndex += 1
        lock.unlock()
        return try results[resultIndex].get()
    }

    func connectCallCount() -> Int {
        lock.lock()
        let snapshot = connectCalls.count
        lock.unlock()
        return snapshot
    }

    func firstCertificatePins() -> [String]? {
        lock.lock()
        let snapshot = connectCalls.first?.certificatePins
        lock.unlock()
        return snapshot
    }

    func recordedTickets() -> [String] {
        lock.lock()
        let snapshot = connectCalls.map(\.ticket)
        lock.unlock()
        return snapshot
    }
}

private actor StubLineDaemonTransport: TerminalRemoteDaemonTransport {
    func writeLine(_ line: String) async throws {}
    func readLine() async throws -> String { "" }
}

private final class NoticeRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []

    func append(_ value: String) {
        lock.lock()
        values.append(value)
        lock.unlock()
    }

    func messages() -> [String] {
        lock.lock()
        let snapshot = values
        lock.unlock()
        return snapshot
    }
}

private final class ResumeStateRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue: TerminalRemoteDaemonResumeState?

    func set(_ value: TerminalRemoteDaemonResumeState?) {
        lock.lock()
        storedValue = value
        lock.unlock()
    }

    func value() -> TerminalRemoteDaemonResumeState? {
        lock.lock()
        let snapshot = storedValue
        lock.unlock()
        return snapshot
    }
}

private final class StubTerminalTransport: TerminalTransport, @unchecked Sendable {
    var eventHandler: (@Sendable (TerminalTransportEvent) -> Void)?
    private(set) var connectCallCount = 0
    private(set) var sendPayloads: [Data] = []
    private(set) var resizePayloads: [TerminalGridSize] = []
    private(set) var disconnectCallCount = 0

    func connect(initialSize: TerminalGridSize) async throws {
        connectCallCount += 1
    }

    func send(_ data: Data) async throws {
        sendPayloads.append(data)
    }

    func resize(_ size: TerminalGridSize) async {
        resizePayloads.append(size)
    }

    func disconnect() async {
        disconnectCallCount += 1
    }
}

private final class ParkingSnapshotStubTerminalTransport:
    TerminalTransport,
    TerminalRemoteDaemonResumeStateSnapshotting,
    TerminalSessionParking,
    @unchecked Sendable
{
    var eventHandler: (@Sendable (TerminalTransportEvent) -> Void)?

    private let resumeState: TerminalRemoteDaemonResumeState
    private(set) var connectCallCount = 0
    private(set) var disconnectCallCount = 0
    private(set) var parkCallCount = 0

    init(resumeState: TerminalRemoteDaemonResumeState) {
        self.resumeState = resumeState
    }

    func connect(initialSize: TerminalGridSize) async throws {
        connectCallCount += 1
        eventHandler?(.connected)
    }

    func send(_ data: Data) async throws {}

    func resize(_ size: TerminalGridSize) async {}

    func disconnect() async {
        disconnectCallCount += 1
    }

    func suspendPreservingSession() async {
        parkCallCount += 1
    }

    func remoteDaemonResumeStateSnapshot() -> TerminalRemoteDaemonResumeState? {
        resumeState
    }
}
