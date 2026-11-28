import Foundation

actor RefreshFixtureCompletion {
    private var count = 0
    private var waiter: AsyncStream<Bool>.Continuation?
    func finish() {
        count += 1
        if count == 2 { waiter?.yield(true); waiter?.finish(); waiter = nil }
    }
    func withinDeadline() async -> Bool {
        if count == 2 { return true }
        let stream = AsyncStream<Bool> { continuation in
            waiter = continuation
            let deadline = Task {
                try? await Task.sleep(nanoseconds: 250_000_000)
                if !Task.isCancelled { continuation.yield(false); continuation.finish() }
            }
            continuation.onTermination = { _ in deadline.cancel() }
        }
        for await value in stream { waiter = nil; return value }
        return false
    }
}
