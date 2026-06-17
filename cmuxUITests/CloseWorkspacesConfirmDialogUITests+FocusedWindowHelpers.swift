import Darwin
import Foundation
import XCTest

extension CloseWorkspacesConfirmDialogUITests {
    func requireUUID(
        from response: String?,
        context: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> String {
        guard let response,
              let uuid = response
                  .split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" })
                  .map(String.init)
                  .first(where: { UUID(uuidString: $0) != nil }) else {
            XCTFail("Expected UUID in \(context) response. response=\(response ?? "<nil>")", file: file, line: line)
            return ""
        }
        return uuid
    }

    func waitForKeyWindow(_ windowId: String, timeout: TimeInterval) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                self.keyWindowId() == windowId
            },
            object: NSObject()
        )
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }

    private func keyWindowId() -> String? {
        guard let response = socketCommand("list_windows") else { return nil }
        for line in response.split(separator: "\n") {
            let parts = line
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .split(separator: " ")
                .map(String.init)
            guard parts.first == "*", parts.count >= 3 else { continue }
            return parts[2]
        }
        return nil
    }
}

final class CloseWorkspacesControlSocketClient {
    private let path: String
    private let responseTimeout: TimeInterval

    init(path: String, responseTimeout: TimeInterval = 2.0) {
        self.path = path
        self.responseTimeout = responseTimeout
    }

    func sendLine(_ line: String) -> String? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }

        var socketTimeout = timeval(
            tv_sec: Int(responseTimeout.rounded(.down)),
            tv_usec: Int32(((responseTimeout - floor(responseTimeout)) * 1_000_000).rounded())
        )

        var noSigPipe: Int32 = 1
        _ = withUnsafePointer(to: &noSigPipe) { ptr in
            setsockopt(
                fd,
                SOL_SOCKET,
                SO_NOSIGPIPE,
                ptr,
                socklen_t(MemoryLayout<Int32>.size)
            )
        }
        _ = withUnsafePointer(to: &socketTimeout) { ptr in
            setsockopt(
                fd,
                SOL_SOCKET,
                SO_RCVTIMEO,
                ptr,
                socklen_t(MemoryLayout<timeval>.size)
            )
        }
        _ = withUnsafePointer(to: &socketTimeout) { ptr in
            setsockopt(
                fd,
                SOL_SOCKET,
                SO_SNDTIMEO,
                ptr,
                socklen_t(MemoryLayout<timeval>.size)
            )
        }

        var addr = sockaddr_un()
        memset(&addr, 0, MemoryLayout<sockaddr_un>.size)
        addr.sun_family = sa_family_t(AF_UNIX)

        let maxLen = MemoryLayout.size(ofValue: addr.sun_path)
        let bytes = Array(path.utf8CString)
        guard bytes.count <= maxLen else { return nil }
        withUnsafeMutablePointer(to: &addr.sun_path) { p in
            let raw = UnsafeMutableRawPointer(p).assumingMemoryBound(to: CChar.self)
            memset(raw, 0, maxLen)
            for i in 0..<bytes.count {
                raw[i] = bytes[i]
            }
        }

        let pathOffset = MemoryLayout<sockaddr_un>.offset(of: \.sun_path) ?? 0
        let addrLen = socklen_t(pathOffset + bytes.count)
        addr.sun_len = UInt8(min(Int(addrLen), 255))

        let connected = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                connect(fd, sa, addrLen)
            }
        }
        guard connected == 0 else { return nil }

        let payload = line + "\n"
        let wrote: Bool = payload.withCString { cstr in
            var remaining = strlen(cstr)
            var p = UnsafeRawPointer(cstr)
            while remaining > 0 {
                let n = write(fd, p, remaining)
                if n <= 0 { return false }
                remaining -= n
                p = p.advanced(by: n)
            }
            return true
        }
        guard wrote else { return nil }
        _ = shutdown(fd, SHUT_WR)

        var buf = [UInt8](repeating: 0, count: 4096)
        var accum = ""
        while true {
            let n = read(fd, &buf, buf.count)
            if n < 0 {
                let code = errno
                if code == EAGAIN || code == EWOULDBLOCK {
                    break
                }
                return nil
            }
            if n <= 0 { break }
            if let chunk = String(bytes: buf[0..<n], encoding: .utf8) {
                accum.append(chunk)
            }
        }
        let trimmed = accum.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
