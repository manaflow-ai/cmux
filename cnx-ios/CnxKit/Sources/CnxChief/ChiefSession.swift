import CmuxConversationCore
import CnxModel
import Foundation
import Observation

/// Owns the Chief `ConversationStore` for the app's lifetime (the list row
/// and the open conversation share it) and mirrors what the list shows:
/// last message, unread count, typing.
@MainActor
@Observable
public final class ChiefSession {
    public static let shared = ChiefSession(backend: defaultBackend())

    /// Chief before a Mac link: offline (``ChiefOfflineBackend``). DEBUG
    /// builds use the package's conversation simulator
    /// (`services/conversation-sim`) when `CNX_CHIEF_SIM` names its WebSocket
    /// (`ws://127.0.0.1:4870/ws?conversation=direct`), so Chief can be
    /// compared with the package's own lab host on the same data
    /// (verify/imsg-parity.md), and the scripted mock only with mock content on.
    static func defaultBackend() -> any ConversationBackend {
        #if DEBUG
        if let raw = ProcessInfo.processInfo.environment["CNX_CHIEF_SIM"], let url = URL(string: raw) {
            return ConversationSimBackend(endpoint: url)
        }
        #endif
        return fallbackBackend(mockContentEnabled: DeveloperOptions.mockContentEnabled)
    }

    /// The backend with no Mac link: the mock only with mock content on (DEBUG).
    public static func fallbackBackend(mockContentEnabled: Bool) -> any ConversationBackend {
        #if DEBUG
        if mockContentEnabled { return ChiefMockBackend() }
        #endif
        return ChiefOfflineBackend()
    }

    public private(set) var store: ConversationStore
    public private(set) var lastMessage: ConversationMessage?
    public private(set) var unreadCount = 0
    public private(set) var isTyping = false
    public private(set) var isConnected = false
    /// Why Chief is not reachable (no Mac, Chief not started there), set by
    /// whoever swaps the backend; nil when there is nothing to explain.
    public var status: String?
    /// The backend the store runs on.
    public private(set) var backend: any ConversationBackend
    public let identity: ChiefIdentity
    /// The brain's engine controls, when the backend is the Mac's Chief.
    public private(set) var control: ChiefControl?
    /// The Mac Chief runs on, for the settings page.
    public var macName: String?
    public let preferences: ChiefPreferences
    /// Chief's avatar text (``ChiefIdentity/avatar``): the Mac's, once its
    /// `chief.engine.get` reply carries one, else "C".
    public private(set) var avatar: String
    /// The Mac Chief's newest engine report (``ChiefControl/engine()``).
    public private(set) var engineReport: ChiefEngineReport?
    /// The newest message the user has seen with the conversation open.
    private var seenMessageID: String?
    /// Messages waiting for Chief to connect (``ChiefOutbox``).
    public private(set) var outbox: [ConversationComposeMessage] = []
    private let outboxStore: ChiefOutbox
    /// Newest message seq already seen; newer ones from Chief alert.
    private var alertedSeq: Int?

    public init(backend: any ConversationBackend, identity: ChiefIdentity = .standard,
                preferences: ChiefPreferences = ChiefPreferences(), outbox: ChiefOutbox? = nil) {
        self.identity = identity
        avatar = identity.avatar
        self.preferences = preferences
        outboxStore = outbox ?? .standard
        self.outbox = outboxStore.load()
        self.backend = backend
        store = ConversationStore(backend: backend)
        control = (backend as? ChiefDaemonBackend)?.control
        ChiefAlerts.shared.install()
        attach()
    }

    /// Swaps the backend (offline to `ChiefDaemonBackend` once a Mac link is up).
    public func use(_ backend: any ConversationBackend) {
        store.stop()
        self.backend = backend
        store = ConversationStore(backend: backend)
        control = (backend as? ChiefDaemonBackend)?.control
        engineReport = nil
        alertedSeq = nil
        attach()
    }

    /// Keeps what the Mac Chief's engine report says about Chief (its
    /// avatar) for every place Chief is drawn; the details page calls it
    /// with each report it reads or writes.
    public func adopt(_ report: ChiefEngineReport) {
        engineReport = report
        let text = report.avatar ?? identity.avatar
        if avatar != text { avatar = text }
    }

    /// Reads the engine report once Chief is reachable over the Mac link.
    private func loadEngine() {
        guard let control else { return }
        let store = store
        Task { @MainActor [weak self] in
            guard let report = try? await control.engine(), let self, self.store === store else { return }
            self.adopt(report)
        }
    }

    /// The conversation is on screen: what it shows now has been seen.
    public func markSeen() {
        seenMessageID = lastMessage?.id
    }

    /// Chief is waiting on the user: a message is still in the outbox, or
    /// Chief's newest message asks a question the user has not opened the
    /// chat to see. Home's pin keeps its preview bubble up for it.
    public var isWaitingOnYou: Bool {
        if !outbox.isEmpty { return true }
        guard let message = lastMessage, message.senderID == identity.chiefID, !message.isUnsent else { return false }
        return message.text.contains("?") && message.id != seenMessageID
    }

    /// Home's Needs You filter: something waits in the outbox, or Chief is
    /// idle with its newest message unread.
    public var needsYou: Bool {
        if !outbox.isEmpty { return true }
        guard !isTyping, let message = lastMessage else { return false }
        return message.senderID == identity.chiefID && unreadCount > 0
    }

    /// The conversation the store shows, once connected.
    public var conversationID: String? { store.info?.id }

    /// The conversation's name on the Mac (`title.set` from any device).
    public private(set) var title: String?
    /// Hide Alerts, as the details page and Home's pin show it.
    public private(set) var isMuted = false
    public private(set) var sendsReadReceipts = true

    /// Hide Alerts; `rejected` runs if the change could not be saved.
    public func setMuted(_ muted: Bool, rejected: (@MainActor () -> Void)? = nil) {
        store.updateListState(ConversationListStateChange(muted: muted)) { _ in rejected?() }
        if muted, let id = conversationID { ChiefAlerts.shared.clearDelivered(conversationID: id) }
    }

    public func setSendsReadReceipts(_ on: Bool, rejected: (@MainActor () -> Void)? = nil) {
        store.updateListState(ConversationListStateChange(sendReadReceipts: on)) { _ in rejected?() }
    }

    /// Renames the conversation on the Mac (`title.set`).
    public func rename(_ title: String) async throws {
        guard let backend = backend as? ChiefDaemonBackend else {
            throw ConversationBackendError(code: -1, message: String(localized: "Chief isn't connected to a Mac"))
        }
        try await backend.rename(title)
    }

    private func attach() {
        let store = store
        store.addObserver { [weak self, weak store] _ in
            guard let self, let store, store === self.store else { return }
            self.refresh()
        }
        store.start()
        refresh()
        loadEngine()
    }

    private func refresh() {
        let newest = store.messages.last { $0.seq != nil && !$0.isScheduled }
        if newest != lastMessage { lastMessage = newest }
        if ChiefAlerts.shared.conversationVisible, seenMessageID != newest?.id { seenMessageID = newest?.id }
        if unreadCount != store.unreadCount { unreadCount = store.unreadCount }
        let typing = store.typingParticipantIDs.contains(identity.chiefID)
        if isTyping != typing { isTyping = typing }
        let connected = store.connection == .connected
        if isConnected != connected { isConnected = connected }
        if title != store.info?.title { title = store.info?.title }
        let listState = store.info?.listState
        if isMuted != (listState?.muted ?? false) { isMuted = listState?.muted ?? false }
        if sendsReadReceipts != (listState?.sendReadReceipts ?? true) { sendsReadReceipts = listState?.sendReadReceipts ?? true }
        alertNewMessages()
        flushOutbox()
    }

    /// Sends a message to Chief: now when Chief has connected, else into the
    /// outbox, which goes out when it connects (never dropped silently).
    public func send(_ message: ConversationComposeMessage) {
        guard !message.isEmpty else { return }
        ChiefAlerts.shared.requestPermissionIfUndetermined()
        if store.meID != nil, store.connection == .connected {
            store.sendWhenConnected(message)
            return
        }
        outbox.append(message)
        outboxStore.save(outbox)
    }

    /// Drops what waits in the outbox (the user chose not to send it).
    public func discardOutbox() {
        outbox = []
        outboxStore.save(outbox)
    }

    private func flushOutbox() {
        guard !outbox.isEmpty, store.meID != nil, store.connection == .connected else { return }
        let waiting = outbox
        outbox = []
        outboxStore.save(outbox)
        // Not from inside the store's own change callback.
        let store = store
        Task { @MainActor in
            for message in waiting { store.sendWhenConnected(message) }
        }
    }

    /// Alerts for Chief's messages that arrived live (not the first page).
    private func alertNewMessages() {
        guard store.connection == .connected, let id = conversationID else { return }
        let newest = store.messages.compactMap(\.seq).max() ?? 0
        guard let seen = alertedSeq else {
            // The store says connected before its first page lands: what
            // that page brings is history, not news.
            if newest > 0 { alertedSeq = newest }
            return
        }
        guard newest > seen else { return }
        alertedSeq = newest
        for message in store.messages where (message.seq ?? 0) > seen && message.senderID == identity.chiefID {
            ChiefAlerts.shared.notify(message, title: store.info?.title ?? identity.title, conversationID: id, preferences: preferences)
        }
    }

    /// Why Chief cannot answer now, for the list and the settings page.
    public var unavailableReason: String? {
        if isConnected { return nil }
        return status ?? (backend as? ChiefOfflineBackend)?.reason
    }

    /// The list's preview line for the newest message.
    public var preview: String {
        if let waiting = outbox.last {
            return String(localized: "Waiting to send: \(waiting.text.isEmpty ? String(localized: "Attachment") : waiting.text)")
        }
        guard let message = lastMessage else { return unavailableReason ?? "Ask Chief to run agents on your Macs." }
        if message.isUnsent { return "Message unsent" }
        if message.text.isEmpty, !message.attachments.isEmpty { return "Attachment" }
        return message.text
    }
}

// MARK: - Outbox

/// Messages written to Chief before it connected (New Message to Chief
/// while the link is still coming up, or the Mac has no Chief yet). They
/// are kept on disk, survive a backend swap and a relaunch, and go out in
/// order once Chief connects; after that the transcript shows each one's
/// delivery (and Not Delivered, with retry) as for any message.
public struct ChiefOutbox: Sendable {
    struct Item: Codable, Equatable {
        var text: String
        var images: [Image]

        struct Image: Codable, Equatable {
            var data: Data
            var width: Int
            var height: Int
            var mimeType: String
        }
    }

    let file: URL?

    public init(file: URL?) {
        self.file = file
    }

    public static var standard: ChiefOutbox {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        return ChiefOutbox(file: directory?.appendingPathComponent("cnx-chief-outbox.json"))
    }

    func load() -> [ConversationComposeMessage] {
        guard let file, let data = try? Data(contentsOf: file),
              let items = try? JSONDecoder().decode([Item].self, from: data) else { return [] }
        return items.map { item in
            ConversationComposeMessage(text: item.text, images: item.images.map {
                ConversationComposeImage(data: $0.data, width: $0.width, height: $0.height, mimeType: $0.mimeType)
            })
        }
    }

    func save(_ messages: [ConversationComposeMessage]) {
        guard let file else { return }
        guard !messages.isEmpty else {
            try? FileManager.default.removeItem(at: file)
            return
        }
        let items = messages.map { message in
            Item(text: message.text, images: message.images.map {
                Item.Image(data: $0.data, width: $0.width, height: $0.height, mimeType: $0.mimeType)
            })
        }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Readable after first unlock, so a message written on a locked phone is kept.
        try? JSONEncoder().encode(items).write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}
