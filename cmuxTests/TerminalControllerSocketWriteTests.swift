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

    func testSocketWriteAllNonBlockingReturnsWhenPeerDoesNotReadWithoutSendTimeout() throws {
        let sockets = try makeSocketPair()
        defer {
            Darwin.close(sockets.reader)
            Darwin.close(sockets.writer)
        }

        try fillSocketSendBuffer(sockets.writer)

        let startedAt = Date()
        XCTAssertFalse(TerminalController.writeAllToSocketNonBlocking(Data("PONG\n".utf8), to: sockets.writer))
        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 0.5)
    }

    func testEventsStreamReturnsWhenClientSocketIsBackpressured() throws {
        CmuxEventBus.shared.resetForTesting()
        defer { CmuxEventBus.shared.resetForTesting() }

        let sockets = try makeSocketPair()
        defer {
            Darwin.close(sockets.reader)
            Darwin.close(sockets.writer)
        }

        try fillSocketSendBuffer(sockets.writer)
        try configureSendTimeout(sockets.writer, timeout: 1.0)

        let requestLine = try makeEventsStreamRequestLine()
        let controller = TerminalController.shared
        let finished = expectation(description: "events stream handler returned on backpressure")

        Thread.detachNewThread {
            controller.handleEventsStreamRequest(requestLine, socket: sockets.writer)
            finished.fulfill()
        }

        let result = XCTWaiter().wait(for: [finished], timeout: 0.2)
        XCTAssertEqual(result, .completed)
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

    private nonisolated func fillSocketSendBuffer(_ fd: Int32) throws {
        try setSocketNonBlocking(fd, true)
        defer { try? setSocketNonBlocking(fd, false) }

        let chunk = [UInt8](repeating: 0x78, count: 64 * 1024)
        var wroteAnyBytes = false

        while true {
            let written = chunk.withUnsafeBytes { rawBuffer in
                Darwin.write(fd, rawBuffer.baseAddress!, chunk.count)
            }
            if written > 0 {
                wroteAnyBytes = true
                continue
            }
            if written < 0, errno == EINTR {
                continue
            }
            if written < 0, errno == EAGAIN || errno == EWOULDBLOCK {
                XCTAssertTrue(wroteAnyBytes)
                return
            }
            throw posixError("prefill write")
        }
    }

    private nonisolated func setSocketNonBlocking(_ fd: Int32, _ enabled: Bool) throws {
        let flags = fcntl(fd, F_GETFL, 0)
        guard flags >= 0 else {
            throw posixError("fcntl(F_GETFL)")
        }
        let nextFlags = enabled ? flags | O_NONBLOCK : flags & ~O_NONBLOCK
        guard fcntl(fd, F_SETFL, nextFlags) >= 0 else {
            throw posixError("fcntl(F_SETFL)")
        }
    }

    private nonisolated func makeEventsStreamRequestLine() throws -> String {
        let payload: [String: Any] = [
            "id": "events-backpressure",
            "method": "events.stream",
            "params": ["include_heartbeats": false]
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        guard let line = String(data: data, encoding: .utf8) else {
            throw NSError(domain: NSCocoaErrorDomain, code: 0, userInfo: [
                NSLocalizedDescriptionKey: "Failed to encode events.stream request"
            ])
        }
        return line
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
