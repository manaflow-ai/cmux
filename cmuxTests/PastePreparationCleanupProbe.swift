final class PastePreparationCleanupProbe: Sendable {
    private let stream: AsyncStream<TerminalPastePreparationResult>
    private let continuation: AsyncStream<
        TerminalPastePreparationResult
    >.Continuation

    init() {
        let events = AsyncStream<TerminalPastePreparationResult>.makeStream()
        stream = events.stream
        continuation = events.continuation
    }

    func events() -> AsyncStream<TerminalPastePreparationResult> {
        stream
    }

    func record(_ result: TerminalPastePreparationResult) {
        continuation.yield(result)
    }
}
