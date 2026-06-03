import Foundation

enum TerminalAsyncTimeout {
    static func run<T: Sendable>(
        seconds: TimeInterval,
        timeoutError: @escaping @Sendable () -> any Error,
        onTimeout: @escaping @Sendable () async -> Void = {},
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let state = TerminalAsyncTimeoutState()

        return try await withThrowingTaskGroup(of: TerminalAsyncTimeoutOutcome<T>.self) { group in
            group.addTask {
                do {
                    let value = try await operation()
                    guard state.tryWin() else { return .discarded }
                    return .value(value)
                } catch {
                    guard state.tryWin() else { return .discarded }
                    return .failure(TerminalAsyncTimeoutError(error))
                }
            }

            group.addTask {
                do {
                    try await TerminalAsyncDelay.wait(seconds: seconds)
                } catch {
                    return .discarded
                }

                guard state.tryWin() else { return .discarded }
                await onTimeout()
                return .failure(TerminalAsyncTimeoutError(timeoutError()))
            }

            defer {
                group.cancelAll()
            }

            while let outcome = try await group.next() {
                switch outcome {
                case .value(let value):
                    return value
                case .failure(let error):
                    throw error.value
                case .discarded:
                    continue
                }
            }

            throw timeoutError()
        }
    }
}

enum TerminalAsyncDelay {
    static func wait(seconds: TimeInterval) async throws {
        let seconds = max(seconds, 0)
        guard seconds > 0 else { return }

        let timer = TerminalAsyncDelayTimer()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                timer.schedule(seconds: seconds, continuation: continuation)
            }
        } onCancel: {
            timer.cancel()
        }
    }
}

private enum TerminalAsyncTimeoutOutcome<T: Sendable>: Sendable {
    case value(T)
    case failure(TerminalAsyncTimeoutError)
    case discarded
}

private struct TerminalAsyncTimeoutError: @unchecked Sendable {
    let value: any Error

    init(_ value: any Error) {
        self.value = value
    }
}

private final class TerminalAsyncTimeoutState: @unchecked Sendable {
    private let lock = NSLock()
    private var didComplete = false

    func tryWin() -> Bool {
        lock.lock()
        defer { lock.unlock() }

        guard !didComplete else { return false }
        didComplete = true
        return true
    }
}

private final class TerminalAsyncDelayTimer: @unchecked Sendable {
    private let lock = NSLock()
    private var timer: DispatchSourceTimer?
    private var continuation: CheckedContinuation<Void, Error>?
    private var cancelled = false
    private var completed = false

    func schedule(seconds: TimeInterval, continuation: CheckedContinuation<Void, Error>) {
        lock.lock()
        if cancelled {
            lock.unlock()
            continuation.resume(throwing: CancellationError())
            return
        }

        self.continuation = continuation
        let source = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        timer = source
        source.setEventHandler { [weak self] in
            self?.succeed()
        }
        let milliseconds = Int(min(seconds * 1_000, Double(Int.max)))
        source.schedule(deadline: .now() + .milliseconds(milliseconds))
        lock.unlock()

        source.resume()
    }

    func cancel() {
        complete(.failure(CancellationError()))
    }

    private func succeed() {
        complete(.success(()))
    }

    private func complete(_ result: Result<Void, Error>) {
        let continuation: CheckedContinuation<Void, Error>?
        let timer: DispatchSourceTimer?

        lock.lock()
        guard !completed else {
            lock.unlock()
            return
        }
        completed = true
        cancelled = true
        continuation = self.continuation
        self.continuation = nil
        timer = self.timer
        self.timer = nil
        lock.unlock()

        timer?.cancel()
        switch result {
        case .success:
            continuation?.resume()
        case .failure(let error):
            continuation?.resume(throwing: error)
        }
    }
}
