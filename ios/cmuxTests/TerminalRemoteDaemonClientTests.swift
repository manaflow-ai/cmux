import XCTest
@testable import cmux_DEV

final class TerminalRemoteDaemonClientTests: XCTestCase {
    func testHelloResponseParsesCapabilities() throws {
        let line = #"{"id":1,"ok":true,"result":{"name":"cmuxd-remote","version":"dev","capabilities":["session.basic","session.resize.min","proxy.stream"]}}"#

        let response = try TerminalRemoteDaemonClient.decodeHello(from: line)

        XCTAssertEqual(response.name, "cmuxd-remote")
        XCTAssertEqual(response.version, "dev")
        XCTAssertTrue(response.capabilities.contains("session.basic"))
    }

    func testSessionResizeSendsExpectedRPCAndParsesResponse() async throws {
        let transport = InMemoryDaemonTransport(
            responses: [
                #"{"id":1,"ok":true,"result":{"session_id":"sess-1","attachments":[{"attachment_id":"att-1","cols":80,"rows":24,"updated_at":"2026-03-15T00:00:00Z"}],"effective_cols":80,"effective_rows":24,"last_known_cols":80,"last_known_rows":24}}"#
            ]
        )
        let client = TerminalRemoteDaemonClient(transport: transport)

        let status = try await client.sessionResize(
            sessionID: "sess-1",
            attachmentID: "att-1",
            cols: 80,
            rows: 24
        )

        let writtenLine = await transport.firstWrittenLine()
        let firstLine = try XCTUnwrap(writtenLine)
        XCTAssertTrue(firstLine.contains(#""method":"session.resize""#))
        XCTAssertTrue(firstLine.contains(#""session_id":"sess-1""#))
        XCTAssertTrue(firstLine.contains(#""attachment_id":"att-1""#))
        XCTAssertEqual(status.sessionID, "sess-1")
        XCTAssertEqual(status.attachments.first?.attachmentID, "att-1")
        XCTAssertEqual(status.effectiveCols, 80)
        XCTAssertEqual(status.effectiveRows, 24)
    }

    func testEnsureSessionUsesSessionOpenRPC() async throws {
        let transport = InMemoryDaemonTransport(
            responses: [
                #"{"id":1,"ok":true,"result":{"session_id":"sess-9","attachments":[],"effective_cols":0,"effective_rows":0,"last_known_cols":0,"last_known_rows":0}}"#
            ]
        )
        let client = TerminalRemoteDaemonClient(transport: transport)

        let status = try await client.ensureSession(sessionID: "sess-9")

        let writtenLine = await transport.firstWrittenLine()
        let firstLine = try XCTUnwrap(writtenLine)
        XCTAssertTrue(firstLine.contains(#""method":"session.open""#))
        XCTAssertTrue(firstLine.contains(#""session_id":"sess-9""#))
        XCTAssertEqual(status.sessionID, "sess-9")
    }

    func testTerminalOpenSendsCommandAndParsesAttachmentID() async throws {
        let transport = InMemoryDaemonTransport(
            responses: [
                #"{"id":1,"ok":true,"result":{"session_id":"sess-1","attachment_id":"att-1","attachments":[{"attachment_id":"att-1","cols":120,"rows":40,"updated_at":"2026-03-15T00:00:00Z"}],"effective_cols":120,"effective_rows":40,"last_known_cols":120,"last_known_rows":40,"offset":0}}"#
            ]
        )
        let client = TerminalRemoteDaemonClient(transport: transport)

        let result = try await client.terminalOpen(
            command: "printf READY; stty raw -echo -onlcr; exec cat",
            cols: 120,
            rows: 40
        )

        let writtenLine = await transport.firstWrittenLine()
        let firstLine = try XCTUnwrap(writtenLine)
        XCTAssertTrue(firstLine.contains(#""method":"terminal.open""#))
        XCTAssertTrue(firstLine.contains(#""command":"printf READY; stty raw -echo -onlcr; exec cat""#))
        XCTAssertEqual(result.sessionID, "sess-1")
        XCTAssertEqual(result.attachmentID, "att-1")
        XCTAssertEqual(result.offset, 0)
    }

    func testErrorWithoutPayloadReturnsUnknownRPC() async throws {
        let transport = InMemoryDaemonTransport(
            responses: [
                #"{"id":1,"ok":false}"#
            ]
        )
        let client = TerminalRemoteDaemonClient(transport: transport)

        do {
            _ = try await client.ensureSession(sessionID: nil)
            XCTFail("Expected rpc error")
        } catch let error as TerminalRemoteDaemonClientError {
            XCTAssertEqual(error, .rpc(code: "unknown", message: "Server returned an error without details"))
        }
    }

    func testRPCTimeoutThrows() async throws {
        let transport = HangingDaemonTransport()
        let client = TerminalRemoteDaemonClient(transport: transport, rpcTimeoutSeconds: 0.1)

        do {
            _ = try await client.sendHello()
            XCTFail("Expected rpcTimeout error")
        } catch let error as TerminalRemoteDaemonClientError {
            XCTAssertEqual(error, .rpcTimeout)
        }
    }

    func testTerminalReadAndWriteUseBase64Payloads() async throws {
        let transport = InMemoryDaemonTransport(
            responses: [
                #"{"id":1,"ok":true,"result":{"session_id":"sess-1","written":6}}"#,
                #"{"id":2,"ok":true,"result":{"session_id":"sess-1","offset":5,"base_offset":0,"truncated":false,"eof":false,"data":"UkVBRFk="}}"#
            ]
        )
        let client = TerminalRemoteDaemonClient(transport: transport)

        try await client.terminalWrite(sessionID: "sess-1", data: Data("hello\n".utf8))
        let readResult = try await client.terminalRead(
            sessionID: "sess-1",
            offset: 0,
            maxBytes: 1024,
            timeoutMilliseconds: 500
        )

        let writtenLines = await transport.recordedLines()
        XCTAssertEqual(writtenLines.count, 2)
        XCTAssertTrue(writtenLines[0].contains(#""method":"terminal.write""#))
        XCTAssertTrue(writtenLines[0].contains(#""write_id":"ios-"#))
        XCTAssertTrue(writtenLines[0].contains(#""data":"aGVsbG8K""#))
        XCTAssertTrue(writtenLines[1].contains(#""method":"terminal.read""#))
        XCTAssertTrue(writtenLines[1].contains(#""offset":0"#))
        XCTAssertEqual(readResult.sessionID, "sess-1")
        XCTAssertEqual(readResult.offset, 5)
        XCTAssertEqual(readResult.data, Data("READY".utf8))
    }
}

private actor InMemoryDaemonTransport: TerminalRemoteDaemonTransport {
    private(set) var writtenLines: [String] = []
    private var responses: [String]
    private var deliveredCount = 0
    private var readWaiters: [CheckedContinuation<Void, Never>] = []

    init(responses: [String]) {
        self.responses = responses
    }

    func writeLine(_ line: String) async throws {
        writtenLines.append(line)
        if !readWaiters.isEmpty {
            readWaiters.removeFirst().resume()
        }
    }

    func firstWrittenLine() -> String? {
        writtenLines.first
    }

    func recordedLines() -> [String] {
        writtenLines
    }

    func readLine() async throws -> String {
        // Block until the caller has issued one more writeLine than
        // we've paired to a response. This models the real daemon, which
        // only emits a reply in response to an actual request, and stops
        // the dispatcher from draining queued responses before
        // sendRequest's pendingRequests slot even exists.
        while writtenLines.count <= deliveredCount {
            if responses.isEmpty {
                throw TestTransportError.noResponseQueued
            }
            await withCheckedContinuation { continuation in
                readWaiters.append(continuation)
            }
        }
        guard !responses.isEmpty else {
            throw TestTransportError.noResponseQueued
        }
        deliveredCount += 1
        return responses.removeFirst()
    }
}

private enum TestTransportError: Error {
    case noResponseQueued
}

private actor HangingDaemonTransport: TerminalRemoteDaemonTransport {
    func writeLine(_ line: String) async throws {}

    func readLine() async throws -> String {
        // Sleep long enough that the RPC timeout fires first.
        try await Task.sleep(nanoseconds: 60 * 1_000_000_000)
        return ""
    }
}
