import Foundation
import Network

/// Minimal synchronous loopback HTTP client used by HTTPControl tests.
///
/// Sends one raw request through an ``NWConnection`` and concatenates
/// the full response (including the status line and headers) into a
/// single `String`. Tests then `contains(...)` against the response to
/// assert wire-level expectations like the status code or `Allow:`
/// header without committing to a full HTTP-parsing helper.
enum LoopbackHTTPClient {
    static func send(
        port: UInt16,
        raw: String,
        timeout: TimeInterval = 4
    ) throws -> String {
        let conn = NWConnection(
            host: .ipv4(.loopback),
            port: NWEndpoint.Port(rawValue: port)!,
            using: .tcp
        )
        let done = DispatchSemaphore(value: 0)
        let received = ReceivedBuffer()
        conn.stateUpdateHandler = { state in
            if case .ready = state {
                conn.send(
                    content: Data(raw.utf8),
                    completion: .contentProcessed { _ in }
                )
                func loop() {
                    conn.receive(
                        minimumIncompleteLength: 1,
                        maximumLength: 64 * 1024
                    ) { d, _, isEnd, _ in
                        if let d { received.append(d) }
                        if isEnd {
                            done.signal()
                        } else {
                            loop()
                        }
                    }
                }
                loop()
            }
        }
        conn.start(queue: .global())
        _ = done.wait(timeout: .now() + timeout)
        conn.cancel()
        return String(data: received.snapshot(), encoding: .utf8) ?? ""
    }

    private final class ReceivedBuffer: @unchecked Sendable {
        private let lock = NSLock()
        private var bytes = Data()
        func append(_ d: Data) {
            lock.lock(); defer { lock.unlock() }
            bytes.append(d)
        }
        func snapshot() -> Data {
            lock.lock(); defer { lock.unlock() }
            return bytes
        }
    }
}
