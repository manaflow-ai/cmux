import CNCore
import Foundation

extension MockEngine {
    func conversationHistory(_ p: ConversationHistoryParams) throws -> ConversationHistory {
        guard conversations[p.conversationId] != nil else { throw notFound("conversation", p.conversationId) }
        var all = messages[p.conversationId] ?? []
        if let before = p.before, let i = all.firstIndex(where: { $0.id == before }) {
            all = Array(all[..<i])
        }
        let limit = max(1, p.limit ?? 50)
        let page = Array(all.suffix(limit))
        return ConversationHistory(messages: page, hasMore: all.count > page.count)
    }

    func mutateConversation(_ id: String, _ change: (inout Conversation) -> Void) throws {
        guard var c = conversations[id] else { throw notFound("conversation", id) }
        change(&c)
        conversations[id] = c
        broadcast(.convUpdated, ConversationResult(conversation: c))
    }

    func markRead(_ id: String) throws {
        try mutateConversation(id) { $0.unread = 0 }
        guard var list = messages[id] else { return }
        var changed: [Message] = []
        for i in list.indices where list[i].sender.isMe && list[i].status == .delivered {
            list[i].status = .read
            changed.append(list[i])
        }
        messages[id] = list
        for m in changed { broadcast(.convMessage, MessageResult(message: m)) }
    }

    func appendMessage(_ message: Message, unread: Bool) {
        messages[message.conversationId, default: []].append(message)
        guard var c = conversations[message.conversationId] else { return }
        c.lastMessage = message
        c.updatedAt = message.sentAt
        if unread { c.unread += 1 }
        conversations[c.id] = c
        broadcast(.convMessage, MessageResult(message: message))
        broadcast(.convUpdated, ConversationResult(conversation: c))
    }

    func updateMessage(_ conversationId: String, _ messageId: String, _ change: (inout Message) -> Void) {
        guard var list = messages[conversationId], let i = list.firstIndex(where: { $0.id == messageId }) else { return }
        change(&list[i])
        messages[conversationId] = list
        broadcast(.convMessage, MessageResult(message: list[i]))
        if var c = conversations[conversationId], c.lastMessage?.id == messageId {
            c.lastMessage = list[i]
            conversations[conversationId] = c
        }
    }

    func sendMessage(_ p: ConversationSendParams) throws -> Message {
        guard let conversation = conversations[p.conversationId] else { throw notFound("conversation", p.conversationId) }
        let text = p.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw RPCError(code: .badRequest, message: "Empty message") }
        let message = Message(id: makeId("m"), conversationId: p.conversationId, clientId: p.clientId,
                              sender: MockFixtures.me, text: text, sentAt: now(), status: .sent)
        appendMessage(message, unread: false)
        conversationTasks[p.conversationId]?.cancel()
        conversationTasks[p.conversationId] = Task { await self.simulateReply(to: message, in: conversation) }
        return message
    }

    /// delivered -> typing -> read -> reply, on the injected clock.
    func simulateReply(to message: Message, in conversation: Conversation) async {
        do {
            try await pause(350)
            updateMessage(conversation.id, message.id) { $0.status = .delivered }
            let responder = fixtures.responder(for: conversation)
            try await pause(500)
            updateMessage(conversation.id, message.id) { $0.status = .read }
            broadcast(.convTyping, TypingEvent(conversationId: conversation.id, senderId: responder.id, typing: true))
            let reply = fixtures.reply(to: message.text, in: conversation)
            try await pause(900 + Double(min(reply.count, 240)) * 6)
            broadcast(.convTyping, TypingEvent(conversationId: conversation.id, senderId: responder.id, typing: false))
            let answer = Message(id: makeId("m"), conversationId: conversation.id, sender: responder, text: reply,
                                 sentAt: now(), status: .delivered, replyTo: nil)
            appendMessage(answer, unread: true)
        } catch {
            broadcast(.convTyping, TypingEvent(conversationId: conversation.id, senderId: fixtures.responder(for: conversation).id, typing: false))
        }
    }
}
