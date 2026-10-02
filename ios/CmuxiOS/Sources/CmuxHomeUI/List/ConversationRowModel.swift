import CmuxHomeCore
import Foundation

/// Everything a conversation row shows, derived from an `InboxRow`. Pure,
/// so the list cell, the pins grid and the accessibility label agree.
struct ConversationRowModel: Hashable, Sendable {
    enum Status: Hashable, Sendable {
        case none
        case typing
        case sending
        case notDelivered
    }

    var id: ConversationID
    var kind: ConversationSummary.Kind
    var title: String
    /// The preview with the author prefix for groups ("Leo: Ship it.").
    var preview: String
    var status: Status
    var unread: Int
    var isMuted: Bool
    var isPinned: Bool
    var hasInvitedParticipant: Bool
    var timestamp: Date
    /// Participants other than me, for the avatar (first two for a group).
    var avatarParticipants: [Participant]

    init(row: InboxRow, me: ParticipantID?) {
        id = row.id
        kind = row.kind
        title = row.title.isEmpty ? HomeText.untitledConversation : row.title
        isMuted = row.summary.muted
        isPinned = row.isPinned
        unread = row.unread
        timestamp = row.timestamp
        hasInvitedParticipant = row.summary.hasInvitedParticipant
        avatarParticipants = row.summary.participants.filter { $0.id != me }
        if row.isTyping {
            status = .typing
        } else if row.hasFailedSend {
            status = .notDelivered
        } else if row.isSending {
            status = .sending
        } else {
            status = .none
        }
        preview = Self.preview(for: row, me: me)
    }

    static func preview(for row: InboxRow, me: ParticipantID?) -> String {
        let text = row.preview.replacingOccurrences(of: "\n", with: " ")
        if text.isEmpty {
            return row.summary.hasInvitedParticipant ? HomeText.invitedNoMessages : HomeText.noMessages
        }
        guard row.kind == .group else { return text }
        let mine = row.isSending || row.hasFailedSend || row.summary.lastMessage?.author == me
        if mine { return HomeText.previewFromMe(text) }
        guard let author = row.previewAuthor, !author.isEmpty else { return text }
        return HomeText.preview(author: author, text: text)
    }

    /// One sentence for VoiceOver: "Chief, 2 unread, The nightly is out, 12 minutes ago".
    func accessibilityLabel(spokenTime: String) -> String {
        var parts: [String] = [title]
        if isPinned { parts.append(HomeText.a11yPinned) }
        if unread > 0 { parts.append(HomeText.unreadCount(unread)) }
        if isMuted { parts.append(HomeText.a11yMuted) }
        switch status {
        case .typing: parts.append(HomeText.typingShort)
        case .sending: parts.append(HomeText.sending)
        case .notDelivered: parts.append(HomeText.notDelivered)
        case .none: break
        }
        parts.append(preview)
        parts.append(spokenTime)
        return parts.joined(separator: ", ")
    }
}
