import Foundation
import os

/// Runs the production limiter for the CLI fake-socket integration tests.
@main
struct ControlClientRateLimiterProbe {
    static func main() async throws {
        var connections: [Int: ControlClientRateLimiter] = [:]
        // The actor's synchronous injected clock reads this test-only atomic
        // value; the harness advances it only after the advertised backoff.
        var clocks: [Int: OSAllocatedUnfairLock<UInt64>] = [:]
        while let line = readLine() {
            let request = try JSONSerialization.jsonObject(with: Data(line.utf8)) as! [String: Any]
            let connection = request["connection"] as! Int
            let clock = clocks[connection] ?? OSAllocatedUnfairLock(initialState: UInt64(0))
            clocks[connection] = clock
            clock.withLock { $0 = (request["now"] as! NSNumber).uint64Value }
            let limiter: ControlClientRateLimiter
            if let existing = connections[connection] {
                limiter = existing
            } else {
                limiter = ControlClientRateLimiter(now: { clock.withLock { $0 } })
                connections[connection] = limiter
            }
            let decision = await limiter.admit(method: request["method"] as! String)
            let response: [String: Any]
            switch decision {
            case .allowed:
                response = ["allowed": true]
            case .limited(let milliseconds):
                response = ["allowed": false, "retry_after_ms": milliseconds]
            }
            var output = try JSONSerialization.data(withJSONObject: response)
            output.append(0x0A)
            try FileHandle.standardOutput.write(contentsOf: output)
        }
    }
}
