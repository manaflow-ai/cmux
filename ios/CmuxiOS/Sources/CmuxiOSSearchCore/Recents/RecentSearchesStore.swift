public import Foundation

/// The last committed queries on this device, newest first. Client state:
/// never synced, never sent. A query is recorded when the user opens a
/// result or presses Return, not on every keystroke.
@MainActor
public final class RecentSearchesStore {
    public static let defaultKey = "cmux.search.recent"
    private let defaults: UserDefaults
    private let key: String
    public let limit: Int
    public private(set) var queries: [String]

    public init(defaults: UserDefaults = .standard, key: String = RecentSearchesStore.defaultKey, limit: Int = 8) {
        self.defaults = defaults
        self.key = key
        self.limit = limit
        queries = Array((defaults.stringArray(forKey: key) ?? []).prefix(limit))
    }

    /// Moves `query` to the front; an equal query (ignoring case, diacritics
    /// and width) is replaced, and the oldest beyond `limit` drops.
    public func record(_ query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var next = queries.filter { !Self.same($0, trimmed) }
        next.insert(trimmed, at: 0)
        save(Array(next.prefix(limit)))
    }

    public func remove(_ query: String) {
        save(queries.filter { !Self.same($0, query) })
    }

    public func clear() { save([]) }

    private func save(_ next: [String]) {
        guard next != queries else { return }
        queries = next
        defaults.set(next, forKey: key)
    }

    static func same(_ lhs: String, _ rhs: String) -> Bool {
        lhs.compare(rhs, options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]) == .orderedSame
    }
}
