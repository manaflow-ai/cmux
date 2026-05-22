import XCTest
import Darwin
import Foundation

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
final class TerminalControllerSocketWriteTests: XCTestCase {
    func testSocketWriteAllWritesCompletePayload() throws {
        let sockets = try makeSocketPair()
        defer {
            Darwin.close(sockets.reader)
            Darwin.close(sockets.writer)
        }

        let payload = Data("PONG\n".utf8)
        XCTAssertTrue(TerminalController.writeAllToSocket(payload, to: sockets.writer))

        var buffer = [UInt8](repeating: 0, count: payload.count)
        let count = Darwin.read(sockets.reader, &buffer, buffer.count)
        XCTAssertEqual(count, payload.count)
        XCTAssertEqual(count > 0 ? Data(buffer.prefix(count)) : Data(), payload)
    }

    func testSocketWriteAllReturnsWhenPeerDoesNotRead() throws {
        let sockets = try makeSocketPair()
        defer {
            Darwin.close(sockets.reader)
            Darwin.close(sockets.writer)
        }
        try configureSendTimeout(sockets.writer, timeout: 0.05)

        let payload = Data(repeating: 0x78, count: 8 * 1024 * 1024)
        let startedAt = Date()
        XCTAssertFalse(TerminalController.writeAllToSocket(payload, to: sockets.writer))
        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 2.0)
    }

    private nonisolated func makeSocketPair() throws -> (reader: Int32, writer: Int32) {
        var fds = [Int32](repeating: -1, count: 2)
        let result = fds.withUnsafeMutableBufferPointer { buffer in
            Darwin.socketpair(AF_UNIX, SOCK_STREAM, 0, buffer.baseAddress)
        }
        guard result == 0 else {
            throw posixError("socketpair(AF_UNIX)")
        }
        return (reader: fds[0], writer: fds[1])
    }

    private nonisolated func configureSendTimeout(_ fd: Int32, timeout: TimeInterval) throws {
        let seconds = floor(max(timeout, 0))
        let microseconds = (max(timeout, 0) - seconds) * 1_000_000
        var socketTimeout = timeval(tv_sec: Int(seconds), tv_usec: Int32(microseconds.rounded()))
        let result = withUnsafePointer(to: &socketTimeout) { ptr in
            Darwin.setsockopt(
                fd,
                SOL_SOCKET,
                SO_SNDTIMEO,
                ptr,
                socklen_t(MemoryLayout<timeval>.size)
            )
        }
        guard result == 0 else {
            throw posixError("setsockopt(SO_SNDTIMEO)")
        }
    }

    private nonisolated func posixError(_ operation: String) -> NSError {
        NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(errno),
            userInfo: [NSLocalizedDescriptionKey: "\(operation) failed: \(String(cString: strerror(errno)))"]
        )
    }
}

@MainActor
final class CodexTranscriptMonitorSessionTests: XCTestCase {
    func testTaskStartedWithoutTurnDoesNotClearAssistantMessageForMonitoredTurn() throws {
        let transcriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-monitor-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: transcriptURL) }

        let turnId = "turn-target"
        try writeTranscript(
            [
                Self.eventLine(type: "task_started", payload: ["turn_id": turnId]),
                [
                    "type": "response_item",
                    "payload": [
                        "type": "message",
                        "role": "assistant",
                        "content": [["text": "done"]]
                    ]
                ],
                Self.eventLine(type: "task_started", payload: [:]),
                Self.eventLine(type: "task_complete", payload: ["turn_id": turnId])
            ],
            to: transcriptURL
        )

        let sessionId = "session-1"
        var events: [CodexTranscriptMonitorEvent] = []
        var finishedSessionIds: [String] = []
        let session = CodexTranscriptMonitorSession(
            request: CodexTranscriptMonitorRequest(
                workspaceId: UUID(),
                surfaceId: nil,
                sessionId: sessionId,
                turnId: turnId,
                transcriptPath: transcriptURL.path,
                codexHome: nil
            ),
            queue: DispatchQueue(label: "com.cmux.tests.codex-transcript-monitor"),
            onEvent: { events.append($0) },
            onFinish: { finishedSessionId, _ in finishedSessionIds.append(finishedSessionId) }
        )
        defer { session.cancel() }

        session.start()

        XCTAssertEqual(finishedSessionIds, [sessionId])
        XCTAssertTrue(events.contains { event in
            if case .completion = event {
                return true
            }
            return false
        })
        XCTAssertFalse(events.contains { event in
            if case .failure = event {
                return true
            }
            return false
        })
    }

    func testTruncationRecoveryOnlyReadsBoundedTail() throws {
        let transcriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-monitor-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: transcriptURL) }

        try Data(repeating: 0x70, count: 1_200_000).write(to: transcriptURL)

        let events = LockedUserInputBodies()
        let session = makeMonitorSession(transcriptURL: transcriptURL, onEvent: events.record)
        defer { session.cancel() }

        session.start()
        XCTAssertEqual(events.snapshot(), [])

        let outsideTailLine = try transcriptLine(Self.userInputEvent(callId: "call-outside-tail", question: "outside tail"))
        var replacement = Data()
        replacement.append(Data(outsideTailLine.utf8))
        replacement.append(0x0A)
        replacement.append(Data(repeating: 0x78, count: 700 * 1024))
        try replacement.write(to: transcriptURL)

        session.debugReadIncrementalForTests(path: transcriptURL.path)

        XCTAssertEqual(events.snapshot(), [])
    }

    func testTruncationRecoveryClearsUserInputDedupeForReplacementTranscript() throws {
        let transcriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-monitor-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: transcriptURL) }

        let duplicateInputLine = try transcriptLine(Self.userInputEvent(callId: "call-duplicate", question: "continue?"))
        var initial = Data()
        initial.append(Data(String(repeating: "padding\n", count: 90_000).utf8))
        initial.append(Data(duplicateInputLine.utf8))
        initial.append(0x0A)
        try initial.write(to: transcriptURL)

        let events = LockedUserInputBodies()
        let session = makeMonitorSession(transcriptURL: transcriptURL, onEvent: events.record)
        defer { session.cancel() }

        session.start()
        XCTAssertEqual(events.snapshot(), ["continue?"])

        try (duplicateInputLine + "\n").write(to: transcriptURL, atomically: true, encoding: .utf8)

        session.debugReadIncrementalForTests(path: transcriptURL.path)

        XCTAssertEqual(events.snapshot(), ["continue?", "continue?"])
    }

    func testFailureSummaryBodyDoesNotExposeRawUpstreamDetails() {
        let summary = CodexTranscriptMonitorParser.summarizeFailure(
            CodexTranscriptFailureCandidate(
                message: "authentication failed: invalid API key sk-test-secret",
                codexErrorInfo: "provider=gpt-example quota=private",
                additionalDetails: nil,
                isStreamError: false
            )
        )

        XCTAssertEqual(
            summary.body,
            String(
                localized: "agent.codex.error.body.auth",
                defaultValue: "Check Codex authentication and try again."
            )
        )
        XCTAssertFalse(summary.body.contains("sk-test-secret"))
        XCTAssertFalse(summary.body.contains("provider="))
    }

    private static func eventLine(type: String, payload: [String: Any]) -> [String: Any] {
        var eventPayload = payload
        eventPayload["type"] = type
        return ["type": "event_msg", "payload": eventPayload]
    }

    private static func userInputEvent(callId: String, question: String) -> [String: Any] {
        eventLine(
            type: "request_user_input",
            payload: [
                "call_id": callId,
                "questions": [
                    ["question": question]
                ]
            ]
        )
    }

    private func makeMonitorSession(
        transcriptURL: URL,
        onEvent: @escaping (CodexTranscriptMonitorEvent) -> Void
    ) -> CodexTranscriptMonitorSession {
        CodexTranscriptMonitorSession(
            request: CodexTranscriptMonitorRequest(
                workspaceId: UUID(),
                surfaceId: nil,
                sessionId: "session-\(UUID().uuidString)",
                turnId: nil,
                transcriptPath: transcriptURL.path,
                codexHome: nil
            ),
            queue: DispatchQueue(label: "com.cmux.tests.codex-transcript-monitor"),
            onEvent: onEvent,
            onFinish: { _, _ in }
        )
    }

    private func writeTranscript(_ objects: [[String: Any]], to url: URL) throws {
        let lines = try objects.map(transcriptLine)
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    private func transcriptLine(_ object: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return try XCTUnwrap(String(data: data, encoding: .utf8))
    }
}

private final class LockedUserInputBodies: @unchecked Sendable {
    private let lock = NSLock()
    private var bodies: [String] = []

    func record(_ event: CodexTranscriptMonitorEvent) {
        guard case let .userInput(_, body) = event else { return }
        lock.lock()
        bodies.append(body)
        lock.unlock()
    }

    func snapshot() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return bodies
    }
}
