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
