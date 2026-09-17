import Darwin
import Foundation

/// Native line-framed transport shared by browser UI test fixtures.
final class ControlSocketUITestClient {
    private let path: String
    private let responseTimeout: TimeInterval

    init(path: String, responseTimeout: TimeInterval) {
        self.path = path
        self.responseTimeout = responseTimeout
    }

    func sendJSON(_ object: [String: Any]) -> [String: Any]? {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object),
              let line = String(data: data, encoding: .utf8),
              let response = sendLine(line),
              let responseData = response.data(using: .utf8) else {
            return nil
        }
        return (try? JSONSerialization.jsonObject(with: responseData)) as? [String: Any]
    }

    func sendLine(_ line: String) -> String? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }

        var timeout = timeval(
            tv_sec: Int(responseTimeout),
            tv_usec: Int32((responseTimeout - floor(responseTimeout)) * 1_000_000)
        )
        withUnsafePointer(to: &timeout) { ptr in
            _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, ptr, socklen_t(MemoryLayout<timeval>.size))
            _ = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, ptr, socklen_t(MemoryLayout<timeval>.size))
        }

        var addr = sockaddr_un()
        memset(&addr, 0, MemoryLayout<sockaddr_un>.size)
        addr.sun_family = sa_family_t(AF_UNIX)

        let pathBytes = Array(path.utf8CString)
        let maxLen = MemoryLayout.size(ofValue: addr.sun_path)
        guard pathBytes.count <= maxLen else { return nil }
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            let raw = UnsafeMutableRawPointer(ptr).assumingMemoryBound(to: CChar.self)
            for index in 0..<pathBytes.count {
                raw[index] = pathBytes[index]
            }
        }

        let pathOffset = MemoryLayout<sockaddr_un>.offset(of: \.sun_path) ?? 0
        let addrLen = socklen_t(pathOffset + pathBytes.count)
        let connected = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                Darwin.connect(fd, sockaddrPtr, addrLen)
            }
        }
        guard connected == 0 else { return nil }

        let payload = Array((line + "\n").utf8)
        let wrote = payload.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return true }
            return Darwin.write(fd, baseAddress, rawBuffer.count) == rawBuffer.count
        }
        guard wrote else { return nil }

        var buffer = [UInt8](repeating: 0, count: 4096)
        var accumulator = ""
        let deadline = Date().addingTimeInterval(responseTimeout)
        while Date() < deadline {
            let count = Darwin.read(fd, &buffer, buffer.count)
            guard count > 0 else { break }
            if let chunk = String(bytes: buffer[0..<count], encoding: .utf8) {
                accumulator.append(chunk)
                if let newline = accumulator.firstIndex(of: "\n") {
                    return String(accumulator[..<newline])
                }
            }
        }
        return accumulator.isEmpty ? nil : accumulator.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
