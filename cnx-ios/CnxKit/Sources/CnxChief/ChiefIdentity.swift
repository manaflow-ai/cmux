import CmuxConversationCore
import Foundation

/// Who is in the Chief conversation. Ids follow the cmux-tui local
/// conversation owner: `user_local` for the person on a trusted connection,
/// `agent_chief` for Chief (spec/commands.md, conversation-list).
public struct ChiefIdentity: Sendable, Hashable {
    public var meID: String
    public var chiefID: String
    public var title: String

    public init(meID: String = "user_local", chiefID: String = "agent_chief", title: String = "Chief") {
        self.meID = meID
        self.chiefID = chiefID
        self.title = title
    }

    public static let standard = ChiefIdentity()

    public var me: ConversationParticipant {
        ConversationParticipant(id: meID, name: "You", initials: "", colorHex: "#8E8E93", isMe: true)
    }

    public var chief: ConversationParticipant {
        ConversationParticipant(id: chiefID, name: title, initials: "C", colorHex: "#636366", isMe: false)
    }

    public func info(id: String) -> ConversationInfo {
        ConversationInfo(id: id, title: title, kind: .direct, participants: [me, chief],
                         listState: ConversationListState(pinned: true, pinOrder: 0))
    }
}
