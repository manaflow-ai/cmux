import Foundation
@preconcurrency import Network

/// An accepted (or test-dialed) TCP connection on the phone's loopback
/// behind async calls.
final class LoopbackConnectionStream: @unchecked Sendable {
    let connection: NWConnection

    init(connection: NWConnection) {
        self.connection = connection
    }

    /// Next bytes; nil once the peer finished.
    func read(maximum: Int = 64 * 1024) async throws -> Data? {
        while true {
            let chunk: Data? = try await withCheckedThrowingContinuation { continuation in
                connection.receive(minimumIncompleteLength: 1, maximumLength: maximum) { data, _, isComplete, error in
                    if let data, !data.isEmpty {
                        continuation.resume(returning: data)
                    } else if let error {
                        continuation.resume(throwing: error)
                    } else if isComplete {
                        continuation.resume(returning: nil)
                    } else {
                        continuation.resume(returning: Data())
                    }
                }
            }
            if chunk?.isEmpty != true { return chunk }
        }
    }

    func write(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            })
        }
    }

    func finishWriting() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            connection.send(content: nil, contentContext: .finalMessage, isComplete: true,
                            completion: .contentProcessed { _ in continuation.resume() })
        }
    }

    func close() {
        connection.cancel()
    }
}
