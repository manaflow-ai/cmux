import Darwin
import Foundation

/// Native line-framed transport shared by browser UI test fixtures.
final class ControlSocketUITestClient {
    private let path: String
    private let responseTimeout: TimeInterval
    private(set) var lastFailure: String?

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
        lastFailure = nil
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return failed("socket", code: errno) }
        defer { close(fd) }

        var timeout = timeval(
            tv_sec: Int(responseTimeout),
            tv_usec: Int32((responseTimeout - floor(responseTimeout)) * 1_000_000)
        )
        withUnsafePointer(to: &timeout) { ptr in
            _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, ptr, socklen_t(MemoryLayout<timeval>.size))
            _ = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, ptr, socklen_t(MemoryLayout<timeval>.size))
        }

        #if os(macOS)
        var noSigPipe: Int32 = 1
        _ = withUnsafePointer(to: &noSigPipe) { ptr in
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, ptr, socklen_t(MemoryLayout<Int32>.size))
        }
        #endif

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
        addr.sun_len = UInt8(addrLen)
        let connected = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                Darwin.connect(fd, sockaddrPtr, addrLen)
            }
        }
        guard connected == 0 else { return failed("connect", code: errno) }

        let payload = Array((line + "\n").utf8)
        var written = 0
        while written < payload.count {
            let result = payload.withUnsafeBytes { rawBuffer -> Int in
                guard let baseAddress = rawBuffer.baseAddress else { return 0 }
                return Darwin.write(fd, baseAddress.advanced(by: written), payload.count - written)
            }
            if result > 0 {
                written += result
                continue
            }
            if result < 0 && errno == EINTR { continue }
            return failed("write", code: errno)
        }

        var buffer = [UInt8](repeating: 0, count: 4096)
        var responseData = Data()
        let deadline = Date().addingTimeInterval(responseTimeout)
        while Date() < deadline {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count < 0 {
                if errno == EINTR { continue }
                return failed("read", code: errno)
            }
            guard count > 0 else {
                lastFailure = "EOF before a complete reply"
                break
            }
            responseData.append(contentsOf: buffer[0..<count])
            if let newline = responseData.firstIndex(of: 0x0A) {
                guard let response = String(data: responseData[..<newline], encoding: .utf8) else {
                    return failed("decode", code: EILSEQ)
                }
                return response
            }
        }
        guard let response = String(data: responseData, encoding: .utf8) else {
            return failed("decode", code: EILSEQ)
        }
        return response.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func failed(_ operation: String, code: Int32) -> String? {
        lastFailure = "\(operation): \(String(cString: strerror(code))) (\(code))"
        return nil
    }

}
