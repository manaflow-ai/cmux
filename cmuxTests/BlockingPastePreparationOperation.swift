import Foundation

// SAFETY: `condition` guards every mutable field; AsyncStream continuations
// are thread-safe and only publish immutable request names.
final class BlockingPastePreparationOperation: @unchecked Sendable {
    struct Snapshot {
        let maximumActiveCount: Int
        let startedNames: [String]
    }

    private let condition = NSCondition()
    private let startedStream: AsyncStream<String>
    private let startedContinuation: AsyncStream<String>.Continuation
    private var releasedNames: Set<String> = []
    private var activeCount = 0
    private var maximumActiveCount = 0
    private var startedNames: [String] = []

    init() {
        let events = AsyncStream<String>.makeStream()
        startedStream = events.stream
        startedContinuation = events.continuation
    }

    func startedEvents() -> AsyncStream<String> {
        startedStream
    }

    func run(
        _ request: TerminalPastePreparationRequest
    ) -> TerminalPastePreparationResult {
        let name = request.pasteboard.pasteboardName
        condition.lock()
        activeCount += 1
        maximumActiveCount = max(maximumActiveCount, activeCount)
        startedNames.append(name)
        startedContinuation.yield(name)
        while !releasedNames.contains(name) {
            condition.wait()
        }
        activeCount -= 1
        condition.unlock()
        return .terminal(.insertText(name))
    }

    func release(_ name: String) {
        condition.lock()
        releasedNames.insert(name)
        condition.broadcast()
        condition.unlock()
    }

    func snapshot() -> Snapshot {
        condition.lock()
        defer { condition.unlock() }
        return Snapshot(
            maximumActiveCount: maximumActiveCount,
            startedNames: startedNames
        )
    }
}
