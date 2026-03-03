import Foundation
import Combine
import ConvexMobile

/// ViewModel for loading and displaying chat messages from Convex
@MainActor
class ChatViewModel: ObservableObject {
    @Published var messages: [ConvexMessage] = []
    @Published var isLoading = true
    @Published var isSending = false
    @Published var error: String?

    private var cancellables = Set<AnyCancellable>()
    private let convex = ConvexClientManager.shared
    let conversationId: String
    private var teamId: String?
    private var lastMarkedAt: Double?
    private var isMarkingRead = false
    private var isViewVisible = false
    private var isAppActive = true

    init(conversationId: String) {
        self.conversationId = conversationId
        #if DEBUG
        let env = ProcessInfo.processInfo.environment
        if env["XCTestConfigurationFilePath"] != nil {
            let mockFlag = env["CMUX_UITEST_MOCK_DATA"] ?? "nil"
            let chatFlag = env["CMUX_UITEST_CHAT_VIEW"] ?? "nil"
            DebugLog.add(
                "ChatViewModel init conversationId=\(conversationId) mockData=\(UITestConfig.mockDataEnabled) envMock=\(mockFlag) envChat=\(chatFlag)"
            )
        }
        #endif
        if UITestConfig.mockDataEnabled {
            messages = UITestMockData.messages(for: conversationId)
            isLoading = false
            error = nil
            #if DEBUG
            if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
                DebugLog.add("ChatViewModel mock messages loaded count=\(messages.count)")
            }
            #endif
        } else {
            Task {
                await loadMessages()
            }
        }
    }

    /// Send a text message to the conversation
    func sendMessage(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        if !UITestConfig.mockDataEnabled {
            await NotificationManager.shared.requestAuthorizationIfNeeded(trigger: .sendMessage)
        }

        isSending = true
        defer { isSending = false }

        print("📱 ChatViewModel: Sending message to \(conversationId)")

        let contentItem = AcpSendMessageArgsContentItem(
            name: nil,
            text: trimmed,
            mimeType: nil,
            data: nil,
            uri: nil,
            type: .text
        )

        do {
            // Call acp:sendMessage action
            let sendArgs = AcpSendMessageArgs(
                clientMessageId: nil,
                content: [contentItem],
                conversationId: ConvexId(rawValue: conversationId)
            )
            let _: AcpSendMessageReturn = try await convex.client.action(
                "acp:sendMessage",
                with: sendArgs.asDictionary()
            )
            print("📱 ChatViewModel: Message sent successfully")
        } catch {
            print("📱 ChatViewModel: Failed to send message: \(error)")
            self.error = "Failed to send: \(error.localizedDescription)"
        }
    }

    func loadMessages() async {
        if UITestConfig.mockDataEnabled {
            messages = UITestMockData.messages(for: conversationId)
            isLoading = false
            error = nil
            return
        }
        // Wait for auth with retry loop (up to 30 seconds)
        var attempts = 0
        while !convex.isAuthenticated && attempts < 30 {
            print("📱 ChatViewModel: Not authenticated, waiting... (attempt \(attempts + 1))")
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            attempts += 1
        }

        guard convex.isAuthenticated else {
            print("📱 ChatViewModel: Auth timeout")
            error = "Authentication timeout"
            isLoading = false
            return
        }

        // Get team ID first
        guard let teamId = await getFirstTeamId() else {
            print("📱 ChatViewModel: Failed to get team ID")
            error = "Failed to get team"
            isLoading = false
            return
        }

        self.teamId = teamId
        print("📱 ChatViewModel: Loading messages for conversation \(conversationId)")

        // Subscribe to messages (paginated response)
        let listArgs = ConversationMessagesListByConversationArgs(
            limit: nil,
            cursor: nil,
            conversationId: ConvexId(rawValue: conversationId),
            teamSlugOrId: teamId
        )
        convex.client
            .subscribe(
                to: "conversationMessages:listByConversation",
                with: listArgs.asDictionary(),
                yielding: MessagesPage.self
            )
            .receive(on: DispatchQueue.main)
            .sink(
                receiveCompletion: { [weak self] completion in
                    if case .failure(let err) = completion {
                        print("📱 ChatViewModel: Subscription error: \(err)")
                        self?.error = err.localizedDescription
                        self?.isLoading = false
                    }
                },
                receiveValue: { [weak self] page in
                    print("📱 ChatViewModel: Received \(page.messages.count) messages")
                    self?.messages = page.messages
                    self?.isLoading = false
                    self?.markReadIfNeeded()
                }
            )
            .store(in: &cancellables)
    }

    func setViewVisible(_ visible: Bool) {
        isViewVisible = visible
        if visible {
            markReadIfNeeded()
        }
    }

    func setAppActive(_ active: Bool) {
        isAppActive = active
        if active {
            markReadIfNeeded()
        }
    }

    private func getFirstTeamId() async -> String? {
        return await withCheckedContinuation { continuation in
            var cancellable: AnyCancellable?
            cancellable = convex.client
                .subscribe(to: "teams:listTeamMemberships", yielding: TeamsListTeamMembershipsReturn.self)
                .first()
                .receive(on: DispatchQueue.main)
                .sink(
                    receiveCompletion: { completion in
                        if case .failure = completion {
                            continuation.resume(returning: nil)
                        }
                        cancellable?.cancel()
                    },
                    receiveValue: { memberships in
                        // Use Stack Auth UUID (teamId) for queries
                        if let first = memberships.first {
                            print("📱 ChatViewModel: Team '\(first.team.displayName ?? "?")' teamId: \(first.teamId)")
                        }
                        continuation.resume(returning: memberships.first?.teamId)
                    }
                )
        }
    }

    private func latestUnreadCandidateAt() -> Double? {
        for message in messages.reversed() {
            if message.isUnreadCandidate {
                return message.createdAt
            }
        }
        return nil
    }

    private func markReadIfNeeded() {
        guard isViewVisible, isAppActive else { return }
        guard let teamId else { return }
        guard let latest = latestUnreadCandidateAt() else { return }
        if let lastMarkedAt, latest <= lastMarkedAt {
            return
        }
        if isMarkingRead {
            return
        }

        Task { @MainActor in
            if isMarkingRead {
                return
            }
            isMarkingRead = true
            defer { isMarkingRead = false }
            if ConversationReadOverrides.isManualUnread(conversationId) {
                return
            }
            if let lastMarkedAt, latest <= lastMarkedAt {
                return
            }
            do {
                let args = ConversationReadsMarkReadArgs(
                    lastReadAt: latest,
                    conversationId: ConvexId(rawValue: conversationId),
                    teamSlugOrId: teamId
                )
                let _: ConversationReadsMarkReadReturn = try await convex.client.mutation(
                    "conversationReads:markRead",
                    with: args.asDictionary()
                )
                lastMarkedAt = latest
                NSLog("📱 ChatViewModel: Marked read at \(latest)")
            } catch {
                NSLog("📱 ChatViewModel: Failed to mark read: \(error)")
            }
        }
    }
}
