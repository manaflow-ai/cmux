#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

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

    deinit {
        continuation.finish()
    }
}
