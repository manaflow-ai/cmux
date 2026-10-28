import CmuxChiefVoiceCore
import CmuxHomeCore
import Foundation

/// Delivers a finished voice note to the user's Chief conversation in Home:
/// the M4A as an `audio/mp4` attachment, the transcript as the message text.
///
/// The Chief is the pinned Chief conversation, else the first one in inbox
/// order. No Home store or no Chief conversation throws ``Unreachable``, so the
/// coordinator keeps the note in its outbox. The idempotency key derives from
/// the note id, so a retry after a lost reply does not post the note twice.
@MainActor
final class HomeChiefVoiceDelivery: ChiefVoiceDelivering {
    /// No signed-in Home store, or no Chief conversation in it.
    struct Unreachable: Error {}

    private let store: @MainActor () -> HomeStore?

    /// - Parameter store: The signed-in account's Home store, read at delivery time.
    init(store: @escaping @MainActor () -> HomeStore?) {
        self.store = store
    }

    /// The Chief conversation row the note goes to, if any.
    static func chiefConversation(in rows: [InboxRow]) -> InboxRow? {
        rows.orderedForInbox().first { $0.kind == .chief }
    }

    /// The display name of the Chief the next note goes to.
    var chiefName: String? {
        store().flatMap { Self.chiefConversation(in: $0.rows) }?.title
    }

    func deliver(_ note: VoiceNote, audioURL: URL) async throws {
        guard let home = store(), let chief = Self.chiefConversation(in: home.rows) else { throw Unreachable() }
        let attachment = try await home.prepareAttachment(fileURL: audioURL)
        var seed = NoteSeededGenerator(note.id)
        try await home.send(conversation: chief.id, text: note.transcript ?? "", attachments: [attachment],
                            key: IdempotencyKey.make(using: &seed))
    }
}

/// SplitMix64 seeded from a note id: the same note always makes the same key.
private struct NoteSeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(_ id: UUID) {
        let bytes = withUnsafeBytes(of: id.uuid) { Array($0) }
        state = bytes.prefix(8).reduce(0) { $0 << 8 | UInt64($1) } ^ bytes.suffix(8).reduce(0) { $0 << 8 | UInt64($1) }
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
