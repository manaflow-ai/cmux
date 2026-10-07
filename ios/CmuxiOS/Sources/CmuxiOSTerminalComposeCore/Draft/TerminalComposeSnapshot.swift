import Foundation

/// The stored composer state: drafts by terminal and the sent history.
/// Decoding is tolerant: a missing field reads as empty.
struct TerminalComposeSnapshot: Codable, Sendable, Equatable {
    struct Draft: Codable, Sendable, Equatable {
        var text: String
        /// Seconds since 1970 of the last edit (eviction order).
        var editedAt: Double
    }

    var version: Int = 1
    var drafts: [String: Draft] = [:]
    /// Oldest first.
    var history: [String] = []

    init(drafts: [String: Draft] = [:], history: [String] = []) {
        self.drafts = drafts
        self.history = history
    }

    private enum CodingKeys: String, CodingKey { case version, drafts, history }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = (try? container.decodeIfPresent(Int.self, forKey: .version)) ?? 1
        drafts = (try? container.decodeIfPresent([String: Draft].self, forKey: .drafts)) ?? [:]
        history = (try? container.decodeIfPresent([String].self, forKey: .history)) ?? []
    }
}
