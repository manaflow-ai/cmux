/// One search screen's live state: subscribes the providers while started,
/// keeps each provider's newest items (a projection, dropped on stop) and
/// re-ranks after a debounce on the injected clock whenever the query or a
/// mirror changes. Ranking runs off the main actor; a stale generation is
/// dropped. No polling, no `asyncAfter`.
@MainActor
public final class SearchSession {
    public private(set) var query = SearchQuery("")
    public private(set) var results = SearchResults.empty
    /// Called on the main actor with each new answer.
    public var onResults: ((SearchResults) -> Void)?

    private let providers: [any SearchProvider]
    private let ranker: SearchRanker
    private let clock: any Clock<Duration>
    private let debounce: Duration
    private var corpus: [[SearchItem]]
    private var subscriptions: [Task<Void, Never>] = []
    private var pending: Task<Void, Never>?
    private var generation = 0

    public init(providers: [any SearchProvider], ranker: SearchRanker = SearchRanker(),
                clock: any Clock<Duration> = ContinuousClock(), debounce: Duration = .milliseconds(80)) {
        self.providers = providers
        self.ranker = ranker
        self.clock = clock
        self.debounce = debounce
        corpus = Array(repeating: [], count: providers.count)
    }

    public var isStarted: Bool { !subscriptions.isEmpty }
    /// Items currently mirrored from every provider.
    public var itemCount: Int { corpus.reduce(0) { $0 + $1.count } }

    /// Subscribes every provider (the screen appeared).
    public func start() {
        guard subscriptions.isEmpty else { return }
        for (index, provider) in providers.enumerated() {
            subscriptions.append(Task { [weak self] in
                let stream = await provider.items()
                for await items in stream {
                    guard let self else { return }
                    self.corpus[index] = items
                    self.schedule()
                }
            })
        }
    }

    /// Ends every subscription and drops the projection (the screen went
    /// away), so hidden search holds no owner stream open.
    public func stop() {
        subscriptions.forEach { $0.cancel() }
        subscriptions = []
        pending?.cancel()
        pending = nil
        generation += 1
        corpus = Array(repeating: [], count: providers.count)
    }

    /// A new query: an empty one answers at once, any other after the debounce.
    public func setQuery(_ text: String) {
        let next = SearchQuery(text)
        guard next != query else { return }
        query = next
        guard !next.isEmpty else {
            pending?.cancel()
            pending = nil
            generation += 1
            publish(SearchResults(query: text))
            return
        }
        schedule()
    }

    private func schedule() {
        generation += 1
        let current = generation
        pending?.cancel()
        let clock = clock
        let debounce = debounce
        pending = Task { [weak self] in
            do { try await clock.sleep(for: debounce) } catch { return }
            await self?.rank(generation: current)
        }
    }

    private func rank(generation current: Int) async {
        guard current == generation, !query.isEmpty else { return }
        let items = corpus.flatMap { $0 }
        let query = query
        let ranker = ranker
        let ranked = await Task.detached(priority: .userInitiated) { ranker.rank(items, query: query) }.value
        guard current == generation else { return }
        publish(ranked)
    }

    private func publish(_ next: SearchResults) {
        guard next != results else { return }
        results = next
        onResults?(next)
    }
}
