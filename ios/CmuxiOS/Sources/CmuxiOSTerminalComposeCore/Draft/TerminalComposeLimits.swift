/// Bounds of the device's composer state (e4-compose.md section 4).
public struct TerminalComposeLimits: Hashable, Sendable {
    /// Drafts kept; the oldest edit is evicted first.
    public var maxDrafts: Int
    /// UTF-8 bytes per draft; a longer draft keeps its prefix.
    public var maxDraftBytes: Int
    /// Sent prompts kept for history.
    public var maxHistory: Int

    public init(maxDrafts: Int = 100, maxDraftBytes: Int = 32 * 1024, maxHistory: Int = 50) {
        self.maxDrafts = max(1, maxDrafts)
        self.maxDraftBytes = max(1, maxDraftBytes)
        self.maxHistory = max(1, maxHistory)
    }

    /// `text` cut to at most `maxDraftBytes` of UTF-8, on a character boundary.
    public func clamped(_ text: String) -> String {
        guard text.utf8.count > maxDraftBytes else { return text }
        var bytes = 0
        var end = text.startIndex
        for index in text.indices {
            let next = text.index(after: index)
            let size = text[index..<next].utf8.count
            if bytes + size > maxDraftBytes { break }
            bytes += size
            end = next
        }
        return String(text[..<end])
    }
}
