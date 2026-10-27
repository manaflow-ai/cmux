import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Reading a pane's whole tmux history as plain text for find-window, in bounded
/// chunks that each wait for the previous reply.
@MainActor
@Suite struct RemoteTmuxPaneTextReaderTests {
    @Test func historyIsReadInJoinedChunksOneReplyAtATimeThenTheScreen() async throws {
        let far = ScriptedTmux(replies: [
            "display-message": .lines(["2500 200 0"]),
            "capture-pane -p -J -S - -E -501": .lines(["old-1", "old-2"]),
            "capture-pane -p -J -S -500 -E -1": .lines(["recent"]),
            "capture-pane -p -J -t": .lines(["$ grep needle", "", "  "]),
        ])
        let reader = RemoteTmuxPaneTextReader(query: far.query)

        let text = try #require(await reader.read(paneId: 7, budget: Self.unbounded))

        #expect(far.commands == [
            "display-message -p -t %7 -F \"#{history_size} #{pane_width} #{alternate_on}\"",
            "capture-pane -p -J -S - -E -501 -t %7",
            "capture-pane -p -J -S -500 -E -1 -t %7",
            "capture-pane -p -J -t %7",
        ])
        #expect(far.mostInFlight == 1)
        // Blank rows under the prompt are dropped so the bottom line is real text.
        #expect(text.lines == ["old-1", "old-2", "recent", "$ grep needle"])
        #expect(!text.isTruncated)
    }

    @Test func aFullScreenAppIsReadFromItsScreenOnly() async throws {
        let far = ScriptedTmux(replies: [
            "display-message": .lines(["0 120 1"]),
            "capture-pane -p -J -t": .lines(["vim buffer"]),
        ])
        let reader = RemoteTmuxPaneTextReader(query: far.query)

        let text = try #require(await reader.read(paneId: 3, budget: Self.unbounded))

        #expect(far.commands.count == 2)
        #expect(text.lines == ["vim buffer"])
    }

    @Test func aFailedChunkGivesUpOnThePane() async {
        let far = ScriptedTmux(replies: [
            "display-message": .lines(["100 80 0"]),
            "capture-pane -p -J -S": .unanswered,
        ])
        let reader = RemoteTmuxPaneTextReader(query: far.query)

        #expect(await reader.read(paneId: 3, budget: Self.unbounded) == nil)
        #expect(far.commands.count == 2)
    }

    @Test func historyPastTheByteBudgetKeepsTheScreenAndNewestRows() async throws {
        // 3,000 rows at 200 columns read as two chunks. The budget holds the screen
        // (8 bytes) and the newest chunk (16 bytes) but not the oldest (10 bytes).
        let far = ScriptedTmux(replies: [
            "display-message": .lines(["3000 200 0"]),
            "capture-pane -p -J -S - -E -1001": .lines(["old-1", "old-2"]),
            "capture-pane -p -J -S -1000 -E -1": .lines(["recent-1", "recent-2"]),
            "capture-pane -p -J -t": .lines(["$ prompt"]),
        ])
        let budget = RemoteTmuxFindWindowTextBudget(bytes: 30)

        let text = try #require(await RemoteTmuxPaneTextReader(query: far.query).read(paneId: 7, budget: budget))

        #expect(text.lines == ["recent-1", "recent-2", "$ prompt"])
        #expect(text.isTruncated)
        #expect(budget.remaining == 6)
    }

    @Test func aScreenOverTheBudgetReadsNothingMore() async throws {
        let far = ScriptedTmux(replies: [
            "display-message": .lines(["3000 200 0"]),
            "capture-pane -p -J -t": .lines(["a screen longer than the budget"]),
            "capture-pane -p -J -S": .lines(["history"]),
        ])
        let budget = RemoteTmuxFindWindowTextBudget(bytes: 4)

        #expect(await RemoteTmuxPaneTextReader(query: far.query).read(paneId: 7, budget: budget) == nil)
        #expect(far.commands.count == 2)
        #expect(budget.remaining == 4)
    }

    @Test func historyPastTheCapIsMarkedTruncated() async throws {
        let far = ScriptedTmux(replies: [
            "display-message": .lines(["900 80 0"]),
            "capture-pane": .lines(["row"]),
        ])
        var reader = RemoteTmuxPaneTextReader(query: far.query)
        reader.maximumRows = 100

        let text = try #require(await reader.read(paneId: 3, budget: Self.unbounded))

        #expect(text.isTruncated)
        #expect(far.commands[1] == "capture-pane -p -J -S -100 -E -1 -t %3")
    }
}

extension RemoteTmuxPaneTextReaderTests {
    static var unbounded: RemoteTmuxFindWindowTextBudget { RemoteTmuxFindWindowTextBudget(bytes: .max) }
}

/// A far end that answers by command prefix and records what it was asked.
@MainActor
final class ScriptedTmux {
    private let replies: [(prefix: String, reply: RemoteTmuxRawQueryOutcome)]
    private(set) var commands: [String] = []
    private(set) var mostInFlight = 0
    private var inFlight = 0

    init(replies: KeyValuePairs<String, RemoteTmuxRawQueryOutcome>) {
        self.replies = replies.map { ($0.key, $0.value) }
    }

    var query: @MainActor (String) async -> RemoteTmuxRawQueryOutcome {
        { [self] command in
            commands.append(command)
            inFlight += 1
            mostInFlight = max(mostInFlight, inFlight)
            await Task.yield()
            inFlight -= 1
            // Longest matching prefix wins, so a specific chunk beats "capture-pane".
            return replies
                .filter { command.hasPrefix($0.prefix) }
                .max { $0.prefix.count < $1.prefix.count }?
                .reply ?? .unanswered
        }
    }
}
