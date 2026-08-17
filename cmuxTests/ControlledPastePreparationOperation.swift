import Foundation

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

actor ControlledPastePreparationOperation {
    struct Snapshot: Sendable {
        let maximumActiveCount: Int
        let startedNames: [String]
    }

    private let startedStream: AsyncStream<String>
    private let startedContinuation: AsyncStream<String>.Continuation
    private let admittedStream: AsyncStream<String>
    private let admittedContinuation: AsyncStream<String>.Continuation
    private var releasedNames: Set<String> = []
    private var continuations: [
        String: CheckedContinuation<
            TerminalPastePreparationResult,
            Error
        >
    ] = [:]
    private var activeCount = 0
    private var maximumActiveCount = 0
    private var startedNames: [String] = []

    init() {
        let startedEvents = AsyncStream<String>.makeStream()
        startedStream = startedEvents.stream
        startedContinuation = startedEvents.continuation
        let admittedEvents = AsyncStream<String>.makeStream()
        admittedStream = admittedEvents.stream
        admittedContinuation = admittedEvents.continuation
    }

    nonisolated func startedEvents() -> AsyncStream<String> {
        startedStream
    }

    nonisolated func admittedEvents() -> AsyncStream<String> {
        admittedStream
    }

    nonisolated func signalAdmission(
        _ request: TerminalPastePreparationRequest
    ) {
        admittedContinuation.yield(request.pasteboard.pasteboardName)
    }

    func run(
        _ request: TerminalPastePreparationRequest
    ) async throws -> TerminalPastePreparationResult {
        let name = request.pasteboard.pasteboardName
        activeCount += 1
        maximumActiveCount = max(maximumActiveCount, activeCount)
        startedNames.append(name)
        startedContinuation.yield(name)
        if releasedNames.remove(name) != nil {
            activeCount -= 1
            return .terminal(.insertText(name))
        }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                continuations[name] = continuation
            }
        } onCancel: {
            Task {
                await self.cancel(name)
            }
        }
    }

    func release(_ name: String) {
        guard let continuation = continuations.removeValue(
            forKey: name
        ) else {
            releasedNames.insert(name)
            return
        }
        activeCount -= 1
        continuation.resume(returning: .terminal(.insertText(name)))
    }

    func snapshot() -> Snapshot {
        Snapshot(
            maximumActiveCount: maximumActiveCount,
            startedNames: startedNames
        )
    }

    private func cancel(_ name: String) {
        guard let continuation = continuations.removeValue(
            forKey: name
        ) else {
            return
        }
        activeCount -= 1
        continuation.resume(throwing: CancellationError())
    }
}
