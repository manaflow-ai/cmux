import CmuxTerminalAccess
import Foundation
import Network
import Testing
@testable import cmux

/// Behavioral coverage for ``SSEResponder``.
///
/// Each test boots a tiny loopback ``NWListener``, connects a fresh
/// ``NWConnection`` to it, captures bytes on the accepting side, and
/// asserts on the wire bytes the responder produced. This sidesteps
/// the temptation to test against the implementation's `String` build
/// site (which would be a forbidden source-text test per the project
/// test-quality policy) and exercises the same byte path the server
/// uses in production.
@Suite struct SSEResponderTests {
    /// Captures bytes streamed onto a single accepted connection.
    private final class WireCapture: @unchecked Sendable {
        private let lock = NSLock()
        private var bytes = Data()
        private let queue = DispatchQueue(label: "cmux.ssetests.capture")
        let listener: NWListener
        let port: UInt16

        init() throws {
            let params = NWParameters.tcp
            params.acceptLocalOnly = true
            params.requiredInterfaceType = .loopback
            let listener = try NWListener(using: params, on: .any)
            self.listener = listener
            let ready = DispatchSemaphore(value: 0)
            listener.stateUpdateHandler = { state in
                if case .ready = state { ready.signal() }
            }
            listener.start(queue: queue)
            _ = ready.wait(timeout: .now() + 2)
            self.port = listener.port?.rawValue ?? 0
            listener.newConnectionHandler = { [weak self] conn in
                guard let self else { return }
                conn.start(queue: self.queue)
                self.receive(conn)
            }
        }

        private func receive(_ conn: NWConnection) {
            conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
                [weak self] data, _, isEnd, _ in
                if let data, !data.isEmpty {
                    self?.append(data)
                }
                if !isEnd {
                    self?.receive(conn)
                }
            }
        }

        private func append(_ d: Data) {
            lock.lock(); bytes.append(d); lock.unlock()
        }

        func snapshot() -> Data {
            lock.lock(); defer { lock.unlock() }
            return bytes
        }

        func text() -> String {
            String(decoding: snapshot(), as: UTF8.self)
        }

        /// Polls the capture buffer for `predicate` to become true,
        /// up to `timeout` seconds. Returns the final snapshot text.
        func waitForText(
            _ predicate: (String) -> Bool,
            timeout: TimeInterval = 2.0
        ) -> String {
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                let t = text()
                if predicate(t) { return t }
                Thread.sleep(forTimeInterval: 0.01)
            }
            return text()
        }

        func stop() {
            listener.cancel()
        }
    }

    /// Boots a capture + a sender ``NWConnection`` and runs `body`
    /// with the sender; the connection is cancelled in defer.
    private func withCapture(
        _ body: (NWConnection, WireCapture) async throws -> Void
    ) async throws {
        let capture = try WireCapture()
        defer { capture.stop() }
        let sender = NWConnection(
            host: .ipv4(.loopback),
            port: NWEndpoint.Port(rawValue: capture.port)!,
            using: .tcp
        )
        let ready = DispatchSemaphore(value: 0)
        sender.stateUpdateHandler = { state in
            if case .ready = state { ready.signal() }
        }
        sender.start(queue: .global())
        _ = ready.wait(timeout: .now() + 2)
        defer { sender.cancel() }
        try await body(sender, capture)
    }

    @Test func writeHeadersEmitsSSEResponseHead() async throws {
        try await withCapture { conn, capture in
            let r = SSEResponder(connection: conn)
            try await r.writeHeaders()
            let final = capture.waitForText({ $0.contains("\r\n\r\n") })
            #expect(final.hasPrefix("HTTP/1.1 200 OK\r\n"))
            #expect(final.contains("Content-Type: text/event-stream\r\n"))
            #expect(final.contains("Cache-Control: no-cache\r\n"))
            #expect(final.contains("X-Accel-Buffering: no\r\n"))
            #expect(final.hasSuffix("\r\n\r\n"))
        }
    }

    @Test func emitRawBytesFramesOutputEventWithIdAndPayload() async throws {
        try await withCapture { conn, capture in
            let r = SSEResponder(connection: conn)
            try await r.writeHeaders()
            try await r.emit(.rawBytes(Data("hi".utf8), seq: 42))
            let frame = "id: 42\nevent: output\ndata: {\"bytes_base64\":\"aGk=\"}\n\n"
            let final = capture.waitForText({ $0.contains(frame) })
            #expect(final.contains(frame))
        }
    }

    @Test func emitCellsSnapshotUsesScreenEventName() async throws {
        try await withCapture { conn, capture in
            let r = SSEResponder(connection: conn)
            try await r.writeHeaders()
            let grid = CellGrid(
                cols: 1, rows: 1, altScreen: false, title: nil,
                cursor: CursorState(row: 0, col: 0, visible: true, style: .block),
                semanticAvailable: false,
                rowsData: [
                    CellRow(
                        wrap: false,
                        wrapContinuation: false,
                        cells: [Cell(
                            t: "x",
                            wide: .narrow,
                            fg: .default,
                            bg: .default,
                            attrs: [],
                            underlineKind: nil,
                            underlineColor: nil,
                            hyperlink: nil,
                            semantic: nil
                        )]
                    )
                ]
            )
            try await r.emit(.cellsSnapshot(grid, seq: 7))
            let final = capture.waitForText({ $0.contains("id: 7\nevent: screen\n") })
            #expect(final.contains("id: 7\nevent: screen\n"))
            #expect(final.contains("\"format\":\"cells\""))
        }
    }

    @Test func emitGapCommentIsAnSSEComment() async throws {
        try await withCapture { conn, capture in
            let r = SSEResponder(connection: conn)
            try await r.writeHeaders()
            try await r.emitGapComment(from: 100, to: 256)
            let final = capture.waitForText({ $0.contains(": gap from=100 to=256\n\n") })
            #expect(final.contains(": gap from=100 to=256\n\n"))
        }
    }

    @Test func emitHeartbeatIsAPingComment() async throws {
        try await withCapture { conn, capture in
            let r = SSEResponder(connection: conn)
            try await r.writeHeaders()
            try await r.emitHeartbeat()
            let final = capture.waitForText({ $0.contains(": ping\n\n") })
            #expect(final.contains(": ping\n\n"))
        }
    }

    @Test func emitEndWritesTerminalEvent() async throws {
        try await withCapture { conn, capture in
            let r = SSEResponder(connection: conn)
            try await r.writeHeaders()
            try await r.emitEnd()
            let final = capture.waitForText({ $0.contains("event: end\ndata: {}\n\n") })
            #expect(final.contains("event: end\ndata: {}\n\n"))
        }
    }

    @Test func writeHeadersIsIdempotent() async throws {
        try await withCapture { conn, capture in
            let r = SSEResponder(connection: conn)
            try await r.writeHeaders()
            try await r.writeHeaders()
            // Wait until the second writeHeaders has had a chance to
            // not double-write by checking the buffer never contains
            // two occurrences of the response line.
            let final = capture.waitForText({ $0.contains("\r\n\r\n") })
            let occurrences = final.components(separatedBy: "HTTP/1.1 200 OK\r\n").count - 1
            #expect(occurrences == 1)
        }
    }

    @Test func lastWriteAtAdvancesAfterEmit() async throws {
        try await withCapture { conn, _ in
            let clock = ManualClock(start: 100.0)
            let r = SSEResponder(connection: conn, clock: clock)
            let before = r.lastWriteAt
            clock.advance(by: 5.0)
            try await r.writeHeaders()
            let after = r.lastWriteAt
            #expect(after > before)
            #expect(after >= 105.0)
        }
    }
}
