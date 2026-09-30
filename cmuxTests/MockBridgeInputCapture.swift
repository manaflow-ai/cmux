import Darwin
import Foundation

// Protects test capture bytes written from a bridge thread and read by assertions.
final class MockBridgeInputCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var input = Data()

    func append(_ data: Data) {
        lock.lock()
        input.append(data)
        lock.unlock()
    }

    func snapshot() -> Data {
        lock.lock()
        let value = input
        lock.unlock()
        return value
    }
}

extension CLINotifyProcessIntegrationRegressionTests {
    func startBridgeReadyCapturingInputUntilEOF(
        listenerFD: Int32,
        capture: MockBridgeInputCapture
    ) -> DispatchGroup {
        let handled = DispatchGroup()
        handled.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            defer { handled.leave() }

            var clientAddr = sockaddr_in()
            var clientAddrLen = socklen_t(MemoryLayout<sockaddr_in>.size)
            let clientFD = withUnsafeMutablePointer(to: &clientAddr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                    Darwin.accept(listenerFD, sockaddrPtr, &clientAddrLen)
                }
            }
            guard clientFD >= 0 else { return }
            defer { Darwin.close(clientFD) }

            var pending = Data()
            var buffer = [UInt8](repeating: 0, count: 1024)
            while !pending.contains(0x0A) {
                let count = Darwin.read(clientFD, &buffer, buffer.count)
                if count < 0 {
                    if errno == EINTR { continue }
                    return
                }
                if count == 0 { return }
                pending.append(buffer, count: count)
            }

            let payload: [String: Any] = ["type": "ready", "attachment_token": "attach-token"]
            guard var data = try? JSONSerialization.data(withJSONObject: payload, options: []) else { return }
            data.append(0x0A)
            data.withUnsafeBytes { rawBuffer in
                guard let base = rawBuffer.bindMemory(to: UInt8.self).baseAddress else { return }
                var remaining = rawBuffer.count
                var cursor = base
                while remaining > 0 {
                    let written = Darwin.write(clientFD, cursor, remaining)
                    if written > 0 {
                        remaining -= written
                        cursor = cursor.advanced(by: written)
                    } else if written < 0 && errno == EINTR {
                        continue
                    } else {
                        return
                    }
                }
            }

            while true {
                let count = Darwin.read(clientFD, &buffer, buffer.count)
                if count > 0 {
                    capture.append(Data(buffer.prefix(count)))
                    continue
                }
                if count == 0 {
                    return
                }
                if errno == EINTR {
                    continue
                }
                return
            }
        }
        return handled
    }
}
