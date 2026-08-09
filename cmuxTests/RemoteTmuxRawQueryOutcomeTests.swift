import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// A raw-line query can end three ways, and the reconcile treats them differently.
///
/// It used to see two: lines, or nil. A `%error` and a timeout both produced the nil, so the
/// reconcile's bounded retry re-sent a command the server had already rejected, and that retry
/// asks to reconnect when it times out — which drops a control stream that was answering fine.
@MainActor
@Suite struct RemoteTmuxRawQueryOutcomeTests {

    private func makeConnection() -> RemoteTmuxControlConnection {
        RemoteTmuxControlConnection(host: RemoteTmuxHost(destination: "user@host"), sessionName: "work")
    }

    /// Registers a raw query on the correlation FIFO and returns what the connection reports for it.
    /// The recorder is an array rather than a single value so a double-resume would be visible.
    private func outcomes(
        of resolve: (RemoteTmuxControlConnection) -> Void
    ) -> [RemoteTmuxRawQueryOutcome] {
        let connection = makeConnection()
        var recorded: [RemoteTmuxRawQueryOutcome] = []
        let token = UUID()
        connection.rawQueryCompletions[token] = { recorded.append($0) }
        connection.pendingCommands.append(.rawQuery(token))
        resolve(connection)
        #expect(connection.rawQueryCompletions[token] == nil, "the completion outlived its query")
        return recorded
    }

    @Test func anAnsweredQueryReportsItsLines() {
        let recorded = outcomes { $0.handleCommandResult(lines: ["cmux-view-1", "work"], isError: false) }
        #expect(recorded.count == 1)
        #expect(recorded.first?.lines == ["cmux-view-1", "work"])
    }

    @Test func aRejectedQueryCarriesTheErrorRatherThanReadingAsSilence() throws {
        let recorded = outcomes { $0.handleCommandResult(lines: ["can't find session: work"], isError: true) }
        #expect(recorded.count == 1)
        let outcome = try #require(recorded.first)
        var errorLines: [String]?
        if case let .error(lines) = outcome { errorLines = lines }
        #expect(errorLines == ["can't find session: work"], "got \(outcome)")
        // The rejection must not be readable as a reply: `lines` is what callers switch on.
        #expect(outcome.lines == nil)
    }

    @Test func aStreamResetLeavesTheQueryUnanswered() throws {
        let recorded = outcomes { $0.failPendingActivityQueries() }
        #expect(recorded.count == 1)
        let outcome = try #require(recorded.first)
        var isUnanswered = false
        if case .unanswered = outcome { isUnanswered = true }
        #expect(isUnanswered, "got \(outcome)")
    }

    /// The distinction has to reach the decision it was made for, or the three cases above are
    /// bookkeeping the product ignores.
    @Test func onlySilenceIsWorthAskingAgain() {
        #expect(RemoteTmuxViewConnection.shouldRetryReconcileQuery(after: .unanswered))
        #expect(!RemoteTmuxViewConnection.shouldRetryReconcileQuery(after: .error(["can't find session: work"])))
        #expect(!RemoteTmuxViewConnection.shouldRetryReconcileQuery(after: .lines([])))
    }
}
