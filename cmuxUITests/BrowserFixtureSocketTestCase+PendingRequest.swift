import Darwin
import Foundation

extension BrowserFixtureSocketTestCase {
    func beginPendingSocketRequest(
        method: String,
        params: [String: Any],
        responseTimeout: TimeInterval = 15
    ) throws -> Int32 {
        let request: [String: Any] = [
            "id": UUID().uuidString,
            "method": method,
            "params": params,
        ]
        guard JSONSerialization.isValidJSONObject(request) else {
            throw POSIXError(.EINVAL)
        }
        let requestData = try JSONSerialization.data(withJSONObject: request) + Data([0x0A])
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw POSIXError(.EIO) }

        do {
            try configurePendingSocket(descriptor, responseTimeout: responseTimeout)
            try connectPendingSocket(descriptor)
            try writePendingSocketRequest(requestData, to: descriptor)
            return descriptor
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }

    func pendingSocketResponseIsReady(_ descriptor: Int32) -> Bool {
        var readiness = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
        return Darwin.poll(&readiness, 1, 0) > 0
    }

    func finishPendingSocketRequest(_ descriptor: Int32) -> [String: Any]? {
        var bytes = [UInt8](repeating: 0, count: 4096)
        var response = Data()
        while true {
            let count = Darwin.read(descriptor, &bytes, bytes.count)
            guard count > 0 else { return nil }
            response.append(contentsOf: bytes[..<count])
            guard let newline = response.firstIndex(of: 0x0A) else { continue }
            let line = response[..<newline]
            return (try? JSONSerialization.jsonObject(with: line)) as? [String: Any]
        }
    }

    func closePendingSocketRequest(_ descriptor: Int32) {
        Darwin.close(descriptor)
    }

    private func configurePendingSocket(
        _ descriptor: Int32,
        responseTimeout: TimeInterval
    ) throws {
        var timeout = timeval(
            tv_sec: Int(responseTimeout),
            tv_usec: Int32((responseTimeout - floor(responseTimeout)) * 1_000_000)
        )
        let result = withUnsafePointer(to: &timeout) { pointer in
            setsockopt(
                descriptor,
                SOL_SOCKET,
                SO_RCVTIMEO,
                pointer,
                socklen_t(MemoryLayout<timeval>.size)
            )
        }
        guard result == 0 else { throw posixError() }
    }

    private func connectPendingSocket(_ descriptor: Int32) throws {
        var address = sockaddr_un()
        memset(&address, 0, MemoryLayout<sockaddr_un>.size)
        address.sun_family = sa_family_t(AF_UNIX)

        let pathBytes = Array(socketPath.utf8CString)
        guard pathBytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            throw POSIXError(.ENAMETOOLONG)
        }
        withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            let raw = UnsafeMutableRawPointer(pointer).assumingMemoryBound(to: CChar.self)
            for index in pathBytes.indices {
                raw[index] = pathBytes[index]
            }
        }

        let pathOffset = MemoryLayout<sockaddr_un>.offset(of: \.sun_path) ?? 0
        let addressLength = socklen_t(pathOffset + pathBytes.count)
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                Darwin.connect(descriptor, socketAddress, addressLength)
            }
        }
        guard result == 0 else { throw posixError() }
    }

    private func writePendingSocketRequest(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            var written = 0
            while written < rawBuffer.count {
                let count = Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: written),
                    rawBuffer.count - written
                )
                guard count > 0 else { throw posixError() }
                written += count
            }
        }
    }

    private func posixError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}
