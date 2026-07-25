@MainActor
final class PastePreparationFailureProbe {
    private let stream: AsyncStream<TerminalPastePreparationFailure>
    private let continuation: AsyncStream<
        TerminalPastePreparationFailure
    >.Continuation

    init() {
        let events = AsyncStream<TerminalPastePreparationFailure>.makeStream()
        stream = events.stream
        continuation = events.continuation
    }

    func events() -> AsyncStream<TerminalPastePreparationFailure> {
        stream
    }

    func record(_ failure: TerminalPastePreparationFailure) {
        continuation.yield(failure)
    }
}
