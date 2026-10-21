import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// The find bar's "search full tmux history" action on a mirrored pane.
@MainActor
@Suite struct RemoteTmuxFullHistorySearchTests {
    @Test func aLoadedHistoryRunsTheSearchAgain() async {
        var reruns = 0
        let search = RemoteTmuxFullHistorySearch(
            reseed: { .loaded(historyRows: 48_000, truncated: false) },
            rerunSearch: { reruns += 1 }
        )

        #expect(search.state == .notLoaded)
        let loaded = await search.load()

        #expect(loaded)
        #expect(search.state == .loaded(historyRows: 48_000, truncated: false))
        #expect(reruns == 1)
    }

    @Test func aFailedLoadCanBeRetriedAndDoesNotRerunTheSearch() async {
        var outcomes: [RemoteTmuxFullHistorySeedOutcome] = [.failed, .loaded(historyRows: 10, truncated: true)]
        var reruns = 0
        let search = RemoteTmuxFullHistorySearch(
            reseed: { outcomes.removeFirst() },
            rerunSearch: { reruns += 1 }
        )

        #expect(await search.load() == false)
        #expect(search.state == .failed)
        #expect(reruns == 0)

        #expect(await search.load())
        #expect(search.state == .loaded(historyRows: 10, truncated: true))
        #expect(reruns == 1)
    }

    @Test func anAlternateScreenPaneReportsWhyNothingLoaded() async {
        let search = RemoteTmuxFullHistorySearch(
            reseed: { .alternateScreen },
            rerunSearch: { Issue.record("nothing new to search") }
        )

        #expect(await search.load() == false)
        #expect(search.state == .alternateScreen)
    }

    @Test func aSecondRequestWhileLoadingDoesNotFetchTwice() async {
        var fetches = 0
        var release: CheckedContinuation<Void, Never>?
        let search = RemoteTmuxFullHistorySearch(
            reseed: {
                fetches += 1
                await withCheckedContinuation { release = $0 }
                return .loaded(historyRows: 1, truncated: false)
            },
            rerunSearch: {}
        )

        let first = Task { await search.load() }
        while release == nil { await Task.yield() }
        #expect(search.state == .loading)
        #expect(await search.load() == false)
        release?.resume()

        #expect(await first.value)
        #expect(fetches == 1)
    }
}
