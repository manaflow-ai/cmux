import Foundation

@MainActor
enum ConversationReadOverrides {
    private static var manualUnreadConversationIds: Set<String> = []

    static func markManualUnread(_ conversationId: String) {
        manualUnreadConversationIds.insert(conversationId)
    }

    static func clearManualUnread(_ conversationId: String) {
        manualUnreadConversationIds.remove(conversationId)
    }

    static func isManualUnread(_ conversationId: String) -> Bool {
        manualUnreadConversationIds.contains(conversationId)
    }
}
