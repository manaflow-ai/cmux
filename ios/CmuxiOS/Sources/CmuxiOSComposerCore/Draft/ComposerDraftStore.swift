import Foundation

/// Drafts per target and the last target, in `UserDefaults` as JSON. Client
/// view state, never synced. Empty drafts are removed instead of saved.
@MainActor
public final class ComposerDraftStore {
    private let defaults: UserDefaults
    private let key: String
    private var drafts: [String: ComposerDraft]

    public init(defaults: UserDefaults = .standard, key: String = "cmux.composer.drafts.v1") {
        self.defaults = defaults
        self.key = key
        drafts = defaults.data(forKey: key).flatMap { try? JSONDecoder().decode([String: ComposerDraft].self, from: $0) } ?? [:]
    }

    public func draft(for target: ComposerTarget) -> ComposerDraft? { drafts[target.storageKey] }

    /// The most recently edited draft (the composer reopens on it).
    public var latest: ComposerDraft? { drafts.values.max { $0.updatedAt < $1.updatedAt } }

    public var all: [ComposerDraft] { drafts.values.sorted { $0.updatedAt > $1.updatedAt } }

    public func save(_ draft: ComposerDraft) {
        if draft.isEmpty {
            guard drafts.removeValue(forKey: draft.target.storageKey) != nil else { return }
        } else {
            guard drafts[draft.target.storageKey] != draft else { return }
            drafts[draft.target.storageKey] = draft
        }
        persist()
    }

    public func clear(_ target: ComposerTarget) {
        guard drafts.removeValue(forKey: target.storageKey) != nil else { return }
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(drafts) { defaults.set(data, forKey: key) }
    }
}
