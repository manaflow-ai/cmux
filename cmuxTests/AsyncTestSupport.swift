import Foundation

enum AsyncTestSupport {
    struct Timeout: Error, Sendable {}

    /// Waits for the first value from a test signal, with a bounded failure.
    static func awaitFirst<T: Sendable>(
        _ stream: AsyncStream<T>,
        timeout: Duration = .seconds(1)
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                var iterator = stream.makeAsyncIterator()
                guard let value = await iterator.next() else {
                    throw Timeout()
                }
                return value
            }
            group.addTask {
                try await ContinuousClock().sleep(for: timeout)
                throw Timeout()
            }
            defer { group.cancelAll() }
            guard let value = try await group.next() else {
                throw Timeout()
            }
            return value
        }
    }
}
