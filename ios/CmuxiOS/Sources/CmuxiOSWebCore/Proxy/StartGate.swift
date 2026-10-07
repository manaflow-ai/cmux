import os

/// Resolves a listener start exactly once.
final class StartGate: Sendable {
    private let state = OSAllocatedUnfairLock<(CheckedContinuation<Bool, Never>?, Bool?)>(initialState: (nil, nil))

    func install(_ continuation: CheckedContinuation<Bool, Never>) {
        let settled: Bool? = state.withLock { value in
            if let result = value.1 { return result }
            value.0 = continuation
            return nil
        }
        if let settled { continuation.resume(returning: settled) }
    }

    func finish(_ result: Bool) {
        let waiting: CheckedContinuation<Bool, Never>? = state.withLock { value in
            guard value.1 == nil else { return nil }
            value.1 = result
            let continuation = value.0
            value.0 = nil
            return continuation
        }
        waiting?.resume(returning: result)
    }
}
