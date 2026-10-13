import CmuxConversationCore
import Foundation
import Observation

/// Owns the Chief `ConversationStore` for the app's lifetime (the list row
/// and the open conversation share it) and mirrors what the list shows:
/// last message, unread count, typing.
@MainActor
@Observable
public final class ChiefSession {
    public static let shared = ChiefSession(backend: defaultBackend())

    /// The mock Chief, or in DEBUG builds the package's conversation
    /// simulator (`services/conversation-sim`) when `CNX_CHIEF_SIM` names its
    /// WebSocket (`ws://127.0.0.1:4870/ws?conversation=direct`), so Chief can
    /// be compared with the package's own lab host on the same data
    /// (verify/imsg-parity.md).
    static func defaultBackend() -> any ConversationBackend {
        #if DEBUG
        if let raw = ProcessInfo.processInfo.environment["CNX_CHIEF_SIM"], let url = URL(string: raw) {
            return ConversationSimBackend(endpoint: url)
        }
        #endif
        return ChiefMockBackend()
    }

    public private(set) var store: ConversationStore
    public private(set) var lastMessage: ConversationMessage?
    public private(set) var unreadCount = 0
    public private(set) var isTyping = false
    public private(set) var isConnected = false
    public let identity: ChiefIdentity

    public init(backend: any ConversationBackend, identity: ChiefIdentity = .standard) {
        self.identity = identity
        store = ConversationStore(backend: backend)
        attach()
    }

    /// Swaps the backend (mock to `ChiefDaemonBackend` once a Mac link is up).
    public func use(_ backend: any ConversationBackend) {
        store.stop()
        store = ConversationStore(backend: backend)
        attach()
    }

    private func attach() {
        let store = store
        store.addObserver { [weak self, weak store] _ in
            guard let self, let store, store === self.store else { return }
            self.refresh()
        }
        store.start()
        refresh()
    }

    private func refresh() {
        let newest = store.messages.last { $0.seq != nil && !$0.isScheduled }
        if newest != lastMessage { lastMessage = newest }
        if unreadCount != store.unreadCount { unreadCount = store.unreadCount }
        let typing = store.typingParticipantIDs.contains(identity.chiefID)
        if isTyping != typing { isTyping = typing }
        let connected = store.connection == .connected
        if isConnected != connected { isConnected = connected }
    }

    /// The list's preview line for the newest message.
    public var preview: String {
        guard let message = lastMessage else { return "Ask Chief to run agents on your Macs." }
        if message.isUnsent { return "Message unsent" }
        if message.text.isEmpty, !message.attachments.isEmpty { return "Attachment" }
        return message.text
    }
}
