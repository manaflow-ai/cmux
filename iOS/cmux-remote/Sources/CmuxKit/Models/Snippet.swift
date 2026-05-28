public import Foundation

/// A reusable text snippet the user can fire into any surface with a single
/// tap. Mirrors the Blink "Snips" / Termius "Snippets" idiom from the in-
/// repo terminal-UX research.
///
/// Snippets are stored in the App Group container so the iOS app and watch
/// app share the same library. We never sync snippets through cmux — they
/// are an iOS-side affordance.
public struct CmuxSnippet: Hashable, Codable, Sendable, Identifiable {
    public let id: UUID
    public var title: String
    public var body: String
    public var tags: [String]
    public var appendNewline: Bool
    public var lastUsed: Date?

    public init(
        id: UUID = UUID(),
        title: String,
        body: String,
        tags: [String] = [],
        appendNewline: Bool = true,
        lastUsed: Date? = nil
    ) {
        self.id = id
        self.title = title
        self.body = body
        self.tags = tags
        self.appendNewline = appendNewline
        self.lastUsed = lastUsed
    }

    public var renderedPayload: String {
        appendNewline ? body + "\n" : body
    }
}

/// File-backed snippet library. Reads from the App Group container so the
/// widget extension and watch companion can use the same data without an
/// SSH round-trip.
public actor CmuxSnippetStore {
    private let url: URL
    private var cache: [CmuxSnippet] = []
    private var loaded = false

    public init(appGroupURL: URL) {
        self.url = appGroupURL.appendingPathComponent("snippets.json", isDirectory: false)
    }

    public func all() async -> [CmuxSnippet] {
        await load()
        return cache.sorted { ($0.lastUsed ?? .distantPast) > ($1.lastUsed ?? .distantPast) }
    }

    public func upsert(_ snippet: CmuxSnippet) async {
        await load()
        if let idx = cache.firstIndex(where: { $0.id == snippet.id }) {
            cache[idx] = snippet
        } else {
            cache.append(snippet)
        }
        save()
    }

    public func remove(id: UUID) async {
        await load()
        cache.removeAll(where: { $0.id == id })
        save()
    }

    public func markUsed(id: UUID) async {
        await load()
        if let idx = cache.firstIndex(where: { $0.id == id }) {
            cache[idx].lastUsed = Date()
            save()
        }
    }

    public func seedDefaultsIfEmpty() async {
        await load()
        if !cache.isEmpty { return }
        cache = CmuxSnippet.recommendedStarters
        save()
    }

    private func load() async {
        if loaded { return }
        loaded = true
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([CmuxSnippet].self, from: data) else {
            return
        }
        cache = decoded
    }

    private func save() {
        do {
            let data = try JSONEncoder().encode(cache)
            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: url, options: .atomic)
        } catch {
            // Snippets are best-effort; an unwritable container is a known
            // simulator quirk, not a user-visible failure.
        }
    }
}

extension CmuxSnippet {
    /// The Moshi-inspired starter set targeted at Claude Code / Codex
    /// users — easy to delete or replace from Settings.
    public static var recommendedStarters: [CmuxSnippet] {
        [
            CmuxSnippet(
                title: String(localized: "snippet.continue.title", defaultValue: "Continue"),
                body: String(localized: "snippet.continue.body", defaultValue: "Continue from where you left off."),
                tags: ["agent"]
            ),
            CmuxSnippet(
                title: String(localized: "snippet.approve_diff.title", defaultValue: "Approve diff"),
                body: String(localized: "snippet.approve_diff.body", defaultValue: "Looks good, please apply."),
                tags: ["agent"]
            ),
            CmuxSnippet(
                title: String(localized: "snippet.reject_diff.title", defaultValue: "Reject diff"),
                body: String(localized: "snippet.reject_diff.body", defaultValue: "Please revise - see comments above."),
                tags: ["agent"]
            ),
            CmuxSnippet(
                title: String(localized: "snippet.compact_session.title", defaultValue: "Compact session"),
                body: "/compact",
                tags: ["claude"],
                appendNewline: true
            ),
            CmuxSnippet(
                title: String(localized: "snippet.clear_session.title", defaultValue: "Clear session"),
                body: "/clear",
                tags: ["claude"],
                appendNewline: true
            ),
            CmuxSnippet(
                title: String(localized: "snippet.resume_session.title", defaultValue: "Resume session"),
                body: "/resume",
                tags: ["claude"],
                appendNewline: true
            ),
            CmuxSnippet(
                title: String(localized: "snippet.run_tests.title", defaultValue: "Run tests"),
                body: String(localized: "snippet.run_tests.body", defaultValue: "Please run the tests and report which pass/fail."),
                tags: ["agent"]
            ),
            CmuxSnippet(
                title: String(localized: "snippet.smaller_diff.title", defaultValue: "Smaller diff please"),
                body: String(localized: "snippet.smaller_diff.body", defaultValue: "Please split this change into smaller commits."),
                tags: ["agent"]
            )
        ]
    }
}
