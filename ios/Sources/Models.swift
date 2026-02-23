import Foundation

struct Conversation: Identifiable {
    let id = UUID()
    let name: String
    let avatar: String // SF Symbol or initials
    let lastMessage: String
    let timestamp: Date
    let unreadCount: Int
    let isOnline: Bool
    var messages: [Message]
}

struct Message: Identifiable, Equatable {
    let id: String
    let content: String
    let timestamp: Date
    let isFromMe: Bool
    let status: MessageStatus
    let toolCalls: [MessageToolCall]
    let assistantItems: [AssistantMessageItem]

    init(
        id: String = UUID().uuidString,
        content: String,
        timestamp: Date,
        isFromMe: Bool,
        status: MessageStatus,
        toolCalls: [MessageToolCall] = [],
        assistantItems: [AssistantMessageItem] = []
    ) {
        self.id = id
        self.content = content
        self.timestamp = timestamp
        self.isFromMe = isFromMe
        self.status = status
        self.toolCalls = toolCalls
        self.assistantItems = assistantItems
    }

    static func == (lhs: Message, rhs: Message) -> Bool {
        lhs.id == rhs.id &&
        lhs.content == rhs.content &&
        lhs.timestamp == rhs.timestamp &&
        lhs.isFromMe == rhs.isFromMe &&
        lhs.status == rhs.status &&
        lhs.toolCalls == rhs.toolCalls &&
        lhs.assistantItems == rhs.assistantItems
    }
}

enum MessageStatus: Equatable {
    case sending
    case sent
    case delivered
    case read
}

// MARK: - Fake Data

extension Date {
    static func minutesAgo(_ minutes: Int) -> Date {
        Calendar.current.date(byAdding: .minute, value: -minutes, to: .now)!
    }
    static func hoursAgo(_ hours: Int) -> Date {
        Calendar.current.date(byAdding: .hour, value: -hours, to: .now)!
    }
    static func daysAgo(_ days: Int) -> Date {
        Calendar.current.date(byAdding: .day, value: -days, to: .now)!
    }
}

let fakeConversations: [Conversation] = [
    Conversation(
        name: "Claude",
        avatar: "brain.head.profile",
        lastMessage: "I've finished implementing the authentication system. Ready for review!",
        timestamp: .minutesAgo(2),
        unreadCount: 3,
        isOnline: true,
        messages: [
            Message(content: "Hey Claude, I need help building a new feature", timestamp: .hoursAgo(4), isFromMe: true, status: .read),
            Message(content: "Of course! What feature are you working on?", timestamp: .hoursAgo(4), isFromMe: false, status: .read),
            Message(content: "A real-time chat system with typing indicators", timestamp: .hoursAgo(4), isFromMe: true, status: .read),
            Message(content: "Great choice! We'll need WebSockets for real-time communication. Should I start with the backend or frontend?", timestamp: .hoursAgo(4), isFromMe: false, status: .read),
            Message(content: "Backend first please", timestamp: .hoursAgo(3), isFromMe: true, status: .read),
            Message(content: "I'll set up a WebSocket server with connection handling, message broadcasting, and typing events.", timestamp: .hoursAgo(3), isFromMe: false, status: .read),
            Message(content: "Perfect. What about message persistence?", timestamp: .hoursAgo(3), isFromMe: true, status: .read),
            Message(content: "I recommend using PostgreSQL for messages with Redis for real-time pub/sub. This gives you durability and speed.", timestamp: .hoursAgo(3), isFromMe: false, status: .read),
            Message(content: "Makes sense. How about the schema?", timestamp: .hoursAgo(2), isFromMe: true, status: .read),
            Message(content: "I'll create tables for users, conversations, messages, and participants. Each message will have sender_id, conversation_id, content, and timestamps.", timestamp: .hoursAgo(2), isFromMe: false, status: .read),
            Message(content: "What about read receipts?", timestamp: .hoursAgo(2), isFromMe: true, status: .read),
            Message(content: "We can add a message_reads junction table tracking which users have read which messages, with read_at timestamps.", timestamp: .hoursAgo(2), isFromMe: false, status: .read),
            Message(content: "Nice! Let's also add the auth system", timestamp: .hoursAgo(1), isFromMe: true, status: .read),
            Message(content: "Sure! What authentication method would you prefer - JWT or session-based?", timestamp: .hoursAgo(1), isFromMe: false, status: .read),
            Message(content: "JWT please, with refresh tokens", timestamp: .minutesAgo(55), isFromMe: true, status: .read),
            Message(content: "Got it. I'll implement JWT with refresh token rotation for security. Access tokens will expire in 15 minutes, refresh tokens in 7 days.", timestamp: .minutesAgo(50), isFromMe: false, status: .read),
            Message(content: "Should we store refresh tokens in the database?", timestamp: .minutesAgo(45), isFromMe: true, status: .read),
            Message(content: "Yes, in a token_families table. This allows us to detect token theft and invalidate entire families if needed.", timestamp: .minutesAgo(40), isFromMe: false, status: .read),
            Message(content: "Smart. What about the frontend?", timestamp: .minutesAgo(35), isFromMe: true, status: .read),
            Message(content: "For the iOS app, I'll use URLSession with async/await for HTTP requests, and URLSessionWebSocketTask for WebSocket connections.", timestamp: .minutesAgo(30), isFromMe: false, status: .read),
            Message(content: "How will we handle reconnection?", timestamp: .minutesAgo(25), isFromMe: true, status: .read),
            Message(content: "Exponential backoff with jitter. Start at 1s, max 30s, with random jitter to prevent thundering herd.", timestamp: .minutesAgo(20), isFromMe: false, status: .read),
            Message(content: "Great. And message syncing when coming back online?", timestamp: .minutesAgo(15), isFromMe: true, status: .read),
            Message(content: "We'll track the last message ID locally and fetch missed messages on reconnect. The server will return messages since that ID.", timestamp: .minutesAgo(10), isFromMe: false, status: .read),
            Message(content: "This is exactly what I needed. Thanks!", timestamp: .minutesAgo(5), isFromMe: true, status: .read),
            Message(content: "I've finished implementing the authentication system. Ready for review!", timestamp: .minutesAgo(2), isFromMe: false, status: .delivered),
        ]
    ),
    Conversation(
        name: "Sarah Chen",
        avatar: "person.circle.fill",
        lastMessage: "The deploy looks good 🚀",
        timestamp: .minutesAgo(15),
        unreadCount: 0,
        isOnline: true,
        messages: [
            Message(content: "Hey, did you push the changes?", timestamp: .minutesAgo(45), isFromMe: false, status: .read),
            Message(content: "Yes, just deployed to staging", timestamp: .minutesAgo(30), isFromMe: true, status: .read),
            Message(content: "The deploy looks good 🚀", timestamp: .minutesAgo(15), isFromMe: false, status: .read),
        ]
    ),
    Conversation(
        name: "Dev Team",
        avatar: "person.3.fill",
        lastMessage: "Mike: standup in 5",
        timestamp: .hoursAgo(1),
        unreadCount: 12,
        isOnline: false,
        messages: [
            Message(content: "Good morning everyone!", timestamp: .hoursAgo(3), isFromMe: false, status: .read),
            Message(content: "Morning! Ready for the sprint review?", timestamp: .hoursAgo(2), isFromMe: true, status: .read),
            Message(content: "Mike: standup in 5", timestamp: .hoursAgo(1), isFromMe: false, status: .read),
        ]
    ),
    Conversation(
        name: "Alex Rivera",
        avatar: "person.circle.fill",
        lastMessage: "Thanks for the code review!",
        timestamp: .hoursAgo(3),
        unreadCount: 0,
        isOnline: false,
        messages: [
            Message(content: "Can you review my PR when you get a chance?", timestamp: .hoursAgo(5), isFromMe: false, status: .read),
            Message(content: "Sure, looking now", timestamp: .hoursAgo(4), isFromMe: true, status: .read),
            Message(content: "Left some comments, mostly minor stuff", timestamp: .hoursAgo(3), isFromMe: true, status: .read),
            Message(content: "Thanks for the code review!", timestamp: .hoursAgo(3), isFromMe: false, status: .read),
        ]
    ),
    Conversation(
        name: "Mom",
        avatar: "heart.circle.fill",
        lastMessage: "Don't forget dinner Sunday! 🍝",
        timestamp: .daysAgo(1),
        unreadCount: 1,
        isOnline: false,
        messages: [
            Message(content: "Hi sweetie, how's work?", timestamp: .daysAgo(2), isFromMe: false, status: .read),
            Message(content: "Good! Busy with the new project", timestamp: .daysAgo(2), isFromMe: true, status: .read),
            Message(content: "Don't forget dinner Sunday! 🍝", timestamp: .daysAgo(1), isFromMe: false, status: .delivered),
        ]
    ),
]
