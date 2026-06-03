import XCTest
@testable import cmux_DEV

final class TerminalDirectDaemonClientTests: XCTestCase {
    func testConnectWritesTicketHandshakeAndReturnsLineTransport() async throws {
        let connection = StubDirectDaemonConnection(
            receiveChunks: [
                Data(#"{"ok":true,"result":{"authenticated":true}}"#.utf8) + Data([0x0A]),
                Data(#"{"id":1,"ok":true,"result":{"name":"cmuxd-remote","version":"dev","capabilities":["terminal.stream"]}}"#.utf8) + Data([0x0A]),
            ]
        )
        let client = TerminalDirectDaemonClient(
            connectionFactory: { _, _, _ in connection }
        )

        let transport = try await client.connect(
            url: try XCTUnwrap(URL(string: "tls://cmux.dev:9443")),
            ticket: "ticket-123",
            certificatePins: ["sha256:pin-a"]
        )

        let recordedHandshakeLine = await connection.firstWrittenLine()
        let handshakeLine = try XCTUnwrap(recordedHandshakeLine)
        let handshakeData = try XCTUnwrap(handshakeLine.data(using: .utf8))
        let handshake = try JSONSerialization.jsonObject(with: handshakeData) as? [String: Any]
        XCTAssertEqual(handshake?["ticket"] as? String, "ticket-123")

        try await transport.writeLine(#"{"id":1,"method":"hello","params":{}}"#)
        let helloLine = try await transport.readLine()
        let startCallCount = await connection.recordedStartCallCount()
        let cancelCallCount = await connection.recordedCancelCallCount()

        XCTAssertEqual(startCallCount, 1)
        XCTAssertEqual(cancelCallCount, 0)
        XCTAssertEqual(helloLine, #"{"id":1,"ok":true,"result":{"name":"cmuxd-remote","version":"dev","capabilities":["terminal.stream"]}}"#)
    }

    func testConnectRejectsUnauthorizedHandshake() async {
        let connection = StubDirectDaemonConnection(
            receiveChunks: [
                Data(#"{"ok":false,"error":{"code":"unauthorized","message":"ticket rejected"}}"#.utf8) + Data([0x0A])
            ]
        )
        let client = TerminalDirectDaemonClient(
            connectionFactory: { _, _, _ in connection }
        )

        do {
            _ = try await client.connect(
                url: URL(string: "tls://cmux.dev:9443")!,
                ticket: "ticket-123",
                certificatePins: []
            )
            XCTFail("expected handshake to fail")
        } catch let error as TerminalDirectDaemonClientError {
            let cancelCallCount = await connection.recordedCancelCallCount()
            XCTAssertEqual(
                error,
                .handshakeRejected(code: "unauthorized", message: "ticket rejected")
            )
            XCTAssertEqual(cancelCallCount, 1)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testConnectPropagatesTLSRejectionFromConnectionStart() async {
        let connection = StubDirectDaemonConnection(
            receiveChunks: [],
            startError: TerminalDirectDaemonClientError.tlsRejected("certificate pin mismatch")
        )
        let client = TerminalDirectDaemonClient(
            connectionFactory: { _, _, _ in connection }
        )

        do {
            _ = try await client.connect(
                url: URL(string: "tls://cmux.dev:9443")!,
                ticket: "ticket-123",
                certificatePins: ["sha256:pin-a"]
            )
            XCTFail("expected connect to fail")
        } catch let error as TerminalDirectDaemonClientError {
            let cancelCallCount = await connection.recordedCancelCallCount()
            XCTAssertEqual(error, .tlsRejected("certificate pin mismatch"))
            XCTAssertEqual(cancelCallCount, 0)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testConnectTimesOutWhileStartingConnection() async {
        let connection = StubDirectDaemonConnection(
            receiveChunks: [],
            suspendStart: true
        )
        let client = TerminalDirectDaemonClient(
            connectionFactory: { _, _, _ in connection },
            connectionStartTimeout: 0.01,
            handshakeTimeout: 1
        )

        do {
            _ = try await client.connect(
                url: URL(string: "tls://cmux.dev:9443")!,
                ticket: "ticket-123",
                certificatePins: []
            )
            XCTFail("expected connect to time out")
        } catch let error as TerminalDirectDaemonClientError {
            let cancelCallCount = await connection.recordedCancelCallCount()
            XCTAssertEqual(
                error,
                .connectionFailed(
                    String(
                        localized: "terminal.workspace.error.direct_connection_timeout_detail",
                        defaultValue: "connection timed out"
                    )
                )
            )
            XCTAssertEqual(cancelCallCount, 1)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testConnectTimesOutWhileWaitingForHandshake() async {
        let connection = StubDirectDaemonConnection(
            receiveChunks: [],
            suspendReceive: true
        )
        let client = TerminalDirectDaemonClient(
            connectionFactory: { _, _, _ in connection },
            connectionStartTimeout: 1,
            handshakeTimeout: 0.01
        )

        do {
            _ = try await client.connect(
                url: URL(string: "tls://cmux.dev:9443")!,
                ticket: "ticket-123",
                certificatePins: []
            )
            XCTFail("expected handshake to time out")
        } catch let error as TerminalDirectDaemonClientError {
            let cancelCallCount = await connection.recordedCancelCallCount()
            XCTAssertEqual(
                error,
                .connectionFailed(
                    String(
                        localized: "terminal.workspace.error.direct_handshake_timeout_detail",
                        defaultValue: "handshake timed out"
                    )
                )
            )
            XCTAssertEqual(cancelCallCount, 1)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testConnectDoesNotCancelConnectionAfterSuccessfulHandshakeBeatsTimeout() async throws {
        let connection = StubDirectDaemonConnection(
            receiveChunks: [
                Data(#"{"ok":true,"result":{"authenticated":true}}"#.utf8) + Data([0x0A])
            ]
        )
        let client = TerminalDirectDaemonClient(
            connectionFactory: { _, _, _ in connection },
            connectionStartTimeout: 1,
            handshakeTimeout: 1
        )

        _ = try await client.connect(
            url: URL(string: "tls://cmux.dev:9443")!,
            ticket: "ticket-123",
            certificatePins: []
        )

        let cancelCallCount = await connection.recordedCancelCallCount()
        XCTAssertEqual(cancelCallCount, 0)
    }
}

private actor StubDirectDaemonConnection: TerminalDirectDaemonConnection {
    private(set) var startCallCount = 0
    private(set) var cancelCallCount = 0
    private(set) var writtenLines: [String] = []
    private var receiveChunks: [Data]
    private let startError: Error?
    private let suspendStart: Bool
    private let suspendReceive: Bool

    init(
        receiveChunks: [Data],
        startError: Error? = nil,
        suspendStart: Bool = false,
        suspendReceive: Bool = false
    ) {
        self.receiveChunks = receiveChunks
        self.startError = startError
        self.suspendStart = suspendStart
        self.suspendReceive = suspendReceive
    }

    func start() async throws {
        startCallCount += 1
        if suspendStart {
            try await Self.sleepUntilCancelled()
        }
        if let startError {
            throw startError
        }
    }

    func send(_ data: Data) async throws {
        writtenLines.append(String(decoding: data, as: UTF8.self).trimmingCharacters(in: .newlines))
    }

    func firstWrittenLine() -> String? {
        writtenLines.first
    }

    func receive() async throws -> Data {
        if suspendReceive {
            try await Self.sleepUntilCancelled()
        }
        guard !receiveChunks.isEmpty else {
            throw TerminalDirectDaemonClientError.connectionFailed("connection closed")
        }
        return receiveChunks.removeFirst()
    }

    func cancel() async {
        cancelCallCount += 1
    }

    func recordedStartCallCount() -> Int {
        startCallCount
    }

    func recordedCancelCallCount() -> Int {
        cancelCallCount
    }

    nonisolated private static func sleepUntilCancelled() async throws {
        while true {
            try Task.checkCancellation()
            try await Task.sleep(nanoseconds: 1_000_000_000)
        }
    }
}
