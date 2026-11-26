import Foundation

/// Owns which conversation transcripts are on screen and the reads that
/// fill them: the view count per conversation (`open` minus `close`), the
/// open epoch, the one running transcript read per conversation, and the
/// older-page reads in flight. HomeStore owns one and runs the reads.
@MainActor
struct HomeTranscriptPager {
    /// Views showing each conversation's transcript now.
    private(set) var viewers: [ConversationID: Int] = [:]
    /// Bumps each time a conversation goes from shown nowhere to shown. A
    /// page read under an older epoch was read before a close: the close
    /// ended what the source kept for it (a cloud subscription), so the
    /// page is dropped and, when the conversation is shown again, read again.
    private var openEpochs: [ConversationID: UInt64] = [:]
    /// The transcript read running per conversation (one at a time).
    private var loads: [ConversationID: Task<Void, Never>] = [:]
    private var olderLoading: Set<ConversationID> = []

    /// One more view shows `id`; the first one starts a new epoch.
    mutating func open(_ id: ConversationID) {
        if viewers[id] == nil { openEpochs[id, default: 0] += 1 }
        viewers[id, default: 0] += 1
    }

    /// One view of `id` went away. True when it was the last one.
    /// A close with no open does nothing and returns false.
    mutating func close(_ id: ConversationID) -> Bool {
        guard let count = viewers[id] else { return false }
        guard count <= 1 else {
            viewers[id] = count - 1
            return false
        }
        viewers[id] = nil
        return true
    }

    func isShown(_ id: ConversationID) -> Bool { viewers[id] != nil }

    func epoch(_ id: ConversationID) -> UInt64? { openEpochs[id] }

    func runningLoad(_ id: ConversationID) -> Task<Void, Never>? { loads[id] }

    mutating func setLoad(_ task: Task<Void, Never>?, for id: ConversationID) { loads[id] = task }

    /// Marks an older-page read of `id` as running; false when one already runs.
    mutating func beginOlder(_ id: ConversationID) -> Bool {
        olderLoading.insert(id).inserted
    }

    mutating func endOlder(_ id: ConversationID) { olderLoading.remove(id) }
}
