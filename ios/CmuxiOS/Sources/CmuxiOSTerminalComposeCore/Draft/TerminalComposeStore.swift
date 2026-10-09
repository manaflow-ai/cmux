public import Foundation

/// The one owner of this device's composer state: the unsent draft of each
/// terminal and the prompts sent from any terminal (client view state,
/// never synced; a1-shell.md 2.3). Edits stay in memory; `flush()` writes
/// the file, and screens call it at the end of an edit, on disappear, on
/// backgrounding and after a send, never per keystroke.
@MainActor
public final class TerminalComposeStore {
    public let limits: TerminalComposeLimits
    private let persistence: any TerminalComposePersisting
    private let now: @Sendable () -> Date
    private var snapshot: TerminalComposeSnapshot
    private var dirty = false

    public init(persistence: any TerminalComposePersisting, limits: TerminalComposeLimits = TerminalComposeLimits(),
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.persistence = persistence
        self.limits = limits
        self.now = now
        snapshot = persistence.load().flatMap { try? JSONDecoder().decode(TerminalComposeSnapshot.self, from: $0) }
            ?? TerminalComposeSnapshot()
        trim()
    }

    // MARK: Drafts

    /// The unsent text for `key`, or "" when there is none.
    public func draft(for key: TerminalDraftKey) -> String {
        snapshot.drafts[key.storageKey]?.text ?? ""
    }

    /// Replaces the draft for `key`; whitespace-only text removes it. The
    /// text is cut to the byte limit and the oldest drafts beyond the count
    /// limit are evicted. Returns the text kept.
    @discardableResult
    public func setDraft(_ text: String, for key: TerminalDraftKey) -> String {
        if text.allSatisfy(\.isWhitespace) {
            clearDraft(for: key)
            return ""
        }
        let kept = limits.clamped(text)
        guard snapshot.drafts[key.storageKey]?.text != kept else { return kept }
        snapshot.drafts[key.storageKey] = .init(text: kept, editedAt: now().timeIntervalSince1970)
        trim()
        dirty = true
        return kept
    }

    public func clearDraft(for key: TerminalDraftKey) {
        guard snapshot.drafts.removeValue(forKey: key.storageKey) != nil else { return }
        dirty = true
    }

    public var draftCount: Int { snapshot.drafts.count }

    // MARK: History

    /// Sent prompts, oldest first.
    public var history: [String] { snapshot.history }

    /// Records a sent prompt as the newest entry (a repeat moves to the end).
    public func recordSent(_ text: String) {
        let entry = limits.clamped(text)
        guard !entry.allSatisfy(\.isWhitespace) else { return }
        snapshot.history.removeAll { $0 == entry }
        snapshot.history.append(entry)
        trim()
        dirty = true
    }

    // MARK: Lifecycle

    /// Writes pending changes.
    public func flush() {
        guard dirty else { return }
        dirty = false
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        persistence.save(data)
    }

    /// Sign-out: the next account never sees this one's drafts or prompts.
    public func clearAll() {
        snapshot = TerminalComposeSnapshot()
        dirty = false
        persistence.remove()
    }

    private func trim() {
        if snapshot.drafts.count > limits.maxDrafts {
            let oldest = snapshot.drafts.sorted { $0.value.editedAt < $1.value.editedAt }
                .prefix(snapshot.drafts.count - limits.maxDrafts)
            for (key, _) in oldest { snapshot.drafts.removeValue(forKey: key) }
        }
        if snapshot.history.count > limits.maxHistory {
            snapshot.history.removeFirst(snapshot.history.count - limits.maxHistory)
        }
    }
}
