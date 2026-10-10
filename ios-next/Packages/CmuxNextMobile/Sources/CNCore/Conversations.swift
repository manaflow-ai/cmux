import Foundation

public enum ConversationKind: String, OpenStringEnum {
    case chief, agent, group, unknown
    public static var unknownFallback: Self { .unknown }
}

public struct Avatar: Codable, Sendable, Hashable {
    public var initials: String
    /// Tint name or hex string chosen by the host (for example `"blue"` or `"#5E5CE6"`).
    public var tint: String

    public init(initials: String, tint: String) { self.initials = initials; self.tint = tint }
}

public struct Participant: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    public init(id: String, name: String) { self.id = id; self.name = name }
}

public struct Conversation: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var kind: ConversationKind
    public var title: String
    public var subtitle: String?
    public var avatar: Avatar
    public var pinned: Bool
    public var muted: Bool
    public var unread: Int
    public var lastMessage: Message?
    public var updatedAt: EpochMillis
    public var participants: [Participant]

    public init(id: String, kind: ConversationKind, title: String, subtitle: String? = nil, avatar: Avatar,
                pinned: Bool = false, muted: Bool = false, unread: Int = 0, lastMessage: Message? = nil,
                updatedAt: EpochMillis, participants: [Participant] = []) {
        self.id = id; self.kind = kind; self.title = title; self.subtitle = subtitle; self.avatar = avatar
        self.pinned = pinned; self.muted = muted; self.unread = unread; self.lastMessage = lastMessage
        self.updatedAt = updatedAt; self.participants = participants
    }

    public var updatedDate: Date { Date(epochMillis: updatedAt) }
}

public enum MessageStatus: String, OpenStringEnum {
    case sending, sent, delivered, read, failed, unknown
    public static var unknownFallback: Self { .unknown }
}

public struct MessageSender: Codable, Sendable, Hashable {
    public var id: String
    public var name: String
    public var isMe: Bool
    public init(id: String, name: String, isMe: Bool) { self.id = id; self.name = name; self.isMe = isMe }
}

public struct Message: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var conversationId: String
    public var clientId: String?
    public var sender: MessageSender
    public var text: String
    public var sentAt: EpochMillis
    public var status: MessageStatus
    /// Id of the message this one replies to.
    public var replyTo: String?

    public init(id: String, conversationId: String, clientId: String? = nil, sender: MessageSender, text: String,
                sentAt: EpochMillis, status: MessageStatus, replyTo: String? = nil) {
        self.id = id; self.conversationId = conversationId; self.clientId = clientId; self.sender = sender
        self.text = text; self.sentAt = sentAt; self.status = status; self.replyTo = replyTo
    }

    public var sentDate: Date { Date(epochMillis: sentAt) }
}

// MARK: RPC payloads

public struct ConversationList: Codable, Sendable, Hashable { public var conversations: [Conversation]; public init(conversations: [Conversation]) { self.conversations = conversations } }

public struct ConversationHistoryParams: Codable, Sendable, Hashable {
    public var conversationId: String
    /// Message id: return messages strictly older than this one.
    public var before: String?
    public var limit: Int?
    public init(conversationId: String, before: String? = nil, limit: Int? = nil) {
        self.conversationId = conversationId; self.before = before; self.limit = limit
    }
}

public struct ConversationHistory: Codable, Sendable, Hashable {
    public var messages: [Message]
    public var hasMore: Bool
    public init(messages: [Message], hasMore: Bool) { self.messages = messages; self.hasMore = hasMore }
}

public struct ConversationSendParams: Codable, Sendable, Hashable {
    public var conversationId: String
    public var text: String
    public var clientId: String
    public init(conversationId: String, text: String, clientId: String) {
        self.conversationId = conversationId; self.text = text; self.clientId = clientId
    }
}

public struct MessageResult: Codable, Sendable, Hashable { public var message: Message; public init(message: Message) { self.message = message } }
public struct ConversationResult: Codable, Sendable, Hashable { public var conversation: Conversation; public init(conversation: Conversation) { self.conversation = conversation } }

public struct ConversationRef: Codable, Sendable, Hashable { public var conversationId: String; public init(conversationId: String) { self.conversationId = conversationId } }

public struct ConversationPinnedParams: Codable, Sendable, Hashable {
    public var conversationId: String; public var pinned: Bool
    public init(conversationId: String, pinned: Bool) { self.conversationId = conversationId; self.pinned = pinned }
}

public struct ConversationMutedParams: Codable, Sendable, Hashable {
    public var conversationId: String; public var muted: Bool
    public init(conversationId: String, muted: Bool) { self.conversationId = conversationId; self.muted = muted }
}

/// `conv.typing` event.
public struct TypingEvent: Codable, Sendable, Hashable {
    public var conversationId: String
    public var senderId: String
    public var typing: Bool
    public init(conversationId: String, senderId: String, typing: Bool) {
        self.conversationId = conversationId; self.senderId = senderId; self.typing = typing
    }
}
