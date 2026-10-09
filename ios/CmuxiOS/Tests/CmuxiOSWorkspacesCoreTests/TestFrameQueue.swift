import Foundation

/// A one-reader queue of text frames (the fake control-plane socket's wire).
final class TestFrameQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer: [String] = []
    private var waiter: CheckedContinuation<String, any Error>?
    private var end: (any Error)?

    func push(_ text: String) {
        lock.lock()
        if let w = waiter {
            waiter = nil
            lock.unlock()
            w.resume(returning: text)
            return
        }
        buffer.append(text)
        lock.unlock()
    }

    func finish(_ error: any Error) {
        lock.lock()
        end = error
        let w = waiter
        waiter = nil
        lock.unlock()
        w?.resume(throwing: error)
    }

    func pop() async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if !buffer.isEmpty {
                let text = buffer.removeFirst()
                lock.unlock()
                continuation.resume(returning: text)
            } else if let end {
                lock.unlock()
                continuation.resume(throwing: end)
            } else {
                waiter = continuation
                lock.unlock()
            }
        }
    }
}
