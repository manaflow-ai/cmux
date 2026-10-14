import CmuxConversationCore
import CnxAgentChat
import CnxModel
import CnxTransport
import Foundation
import Testing
@testable import CnxChief

@Suite struct MessagesStampTests {
    var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    @Test func todayYesterdayWeekdayDate() {
        let locale = Locale(identifier: "en_US")
        let now = Date(timeIntervalSince1970: 1_791_800_000)
        let stamp = MessagesStamp(now: now, calendar: calendar, locale: locale)
        #expect(stamp.string(for: now.addingTimeInterval(-3600)).contains(":"))
        #expect(stamp.string(for: now.addingTimeInterval(-86_400)) == "Yesterday")
        let threeDaysAgo = now.addingTimeInterval(-3 * 86_400)
        var weekday = Date.FormatStyle().weekday(.wide)
        weekday.calendar = calendar
        weekday.locale = locale
        weekday.timeZone = calendar.timeZone
        #expect(stamp.string(for: threeDaysAgo) == threeDaysAgo.formatted(weekday))
        #expect(!stamp.string(for: threeDaysAgo).contains("/"))
        #expect(stamp.string(for: now.addingTimeInterval(-30 * 86_400)).contains("/"))
    }
}

@Suite struct ChiefWireTests {
    let wire = ChiefWire(identity: .standard)

    @Test func tapbacksRoundTrip() {
        for (name, reaction) in ChiefWire.tapbacks {
            #expect(wire.reaction(kind: ["tapback": name]) == reaction)
            #expect(wire.wireKind(reaction)["tapback"] as? String == name)
        }
        #expect(wire.reaction(kind: ["emoji": "🔥"]) == .emoji("🔥"))
    }

    @Test func messageMapsPartsReceiptsAndReactions() throws {
        let object: [String: Any] = [
            "id": "msg_1", "conversation": "conv_1", "seq": 4, "client_msg_id": "c1", "author": "user_local",
            "parts": [["type": "text", "text": "run the tests"], ["type": "work", "session": "s", "status": "running", "preview": "swift test"]],
            "created_at": "2026-10-12T09:41:07.123Z",
            "reactions": [["author": "agent_chief", "part_index": 0, "kind": ["tapback": "like"], "at": "2026-10-12T09:41:08.000Z"]],
        ]
        let read = try #require(wire.message(object, peerReadSeq: 4))
        #expect(read.text == "run the tests\nswift test (running)")
        #expect(read.delivery == .read(nil))
        #expect(read.reactions == [ConversationReactionMark(participantID: "agent_chief", reaction: .thumbsup)])
        #expect(read.sentAt.timeIntervalSince1970 > 1_791_000_000)
        #expect(wire.message(object, peerReadSeq: 3)?.delivery == .delivered)
    }
}

/// A fake cmux-tui daemon behind `MockMacLink`: the local conversation
/// owner's commands, plus Chief replying (typing, then a message) to each send.
final class FakeDaemon: @unchecked Sendable {
    private let lock = NSLock()
    private var conversations: [[String: Any]] = []
    private var messages: [[String: Any]] = []
    private var rev = 0
    private(set) var commands: [String] = []
    /// `conversation-attachment-upload`: open uploads and stored bytes by hash.
    private var uploads: [String: (hash: String, bytes: Data)] = [:]
    private(set) var stored: [String: Data] = [:]
    private(set) var sentParts: [[[String: Any]]] = []

    func line(_ object: [String: Any]) -> Data {
        var data = try! JSONSerialization.data(withJSONObject: object)
        data.append(0x0A)
        return data
    }

    private func summary() -> [String: Any] {
        var summary = conversations[0]
        summary["rev"] = rev
        summary["last_seq"] = messages.count
        return summary
    }

    private func message(author: String, text: String, client: String, parts: [[String: Any]]? = nil) -> [String: Any] {
        ["id": "msg_\(messages.count + 1)", "conversation": "conv_chief", "seq": messages.count + 1, "client_msg_id": client,
         "author": author, "parts": parts ?? [["type": "text", "text": text]], "created_at": "2026-10-12T09:41:07.000Z", "reactions": []]
    }

    /// A photo Chief sent earlier, stored by the owner (not by this client).
    func seedChiefPhoto(_ bytes: Data) -> String {
        lock.withLock {
            let hash = "chiefphoto"
            stored[hash] = bytes
            messages.append(message(author: "agent_chief", text: "", client: "seed-photo", parts: [[
                "type": "attachment", "hash": hash, "name": "chart.png", "mime_type": "image/png",
                "byte_count": bytes.count, "width": 4, "height": 3,
            ]]))
            return hash
        }
    }

    func respond(_ request: Data) -> [Data] {
        lock.withLock {
            let object = try! JSONSerialization.jsonObject(with: request.dropLast()) as! [String: Any]
            let id = object["id"] as! String
            let cmd = object["cmd"] as! String
            commands.append(cmd)
            func ok(_ data: [String: Any]) -> Data { line(["id": id, "ok": true, "data": data]) }
            switch cmd {
            case "conversation-list":
                return [ok(["conversations": conversations])]
            case "conversation-create":
                conversations = [[
                    "id": "conv_chief", "owner": "local", "title": object["title"]!, "participants": object["participants"]!,
                    "read_cursors": [:], "created_at": "2026-10-12T09:00:00.000Z", "updated_at": "2026-10-12T09:00:00.000Z",
                ]]
                rev = 1
                return [ok(["conversation": summary(), "replayed": false])]
            case "subscribe":
                return [ok([:])]
            case "conversation-snapshot":
                let tail = object["tail"] as! Int
                return [ok(["conversation": summary(), "messages": Array(messages.suffix(tail))])]
            case "conversation-history":
                let before = object["before_seq"] as! Int
                return [ok(["messages": messages.filter { ($0["seq"] as! Int) < before }])]
            case "conversation-typing":
                return [ok([:])]
            case "conversation-attachment-upload":
                switch object["op"] as! String {
                case "begin":
                    let upload = "up_\(uploads.count + 1)"
                    uploads[upload] = (object["sha256"] as! String, Data())
                    return [ok(["upload": upload, "needs": ["original"], "stored": NSNull()])]
                case "chunk":
                    let upload = object["upload"] as! String
                    guard object["offset"] as? Int == uploads[upload]?.bytes.count else {
                        return [line(["id": id, "ok": false, "error": ["error_code": "attachment_rejected", "message": "bad_offset"]])]
                    }
                    uploads[upload]!.bytes.append(Data(base64Encoded: object["data"] as! String)!)
                    return [ok(["received": uploads[upload]!.bytes.count])]
                default:
                    let upload = uploads.removeValue(forKey: object["upload"] as! String)!
                    stored[upload.hash] = upload.bytes
                    return [ok(["stored": ["hash": upload.hash, "mime_type": "image/png", "byte_count": upload.bytes.count]])]
                }
            case "conversation-attachment-read":
                let bytes = stored[object["hash"] as! String] ?? Data()
                let offset = object["offset"] as? Int ?? 0
                let length = object["length"] as? Int ?? bytes.count
                let piece = bytes.subdata(in: min(offset, bytes.count)..<min(bytes.count, offset + length))
                return [ok(["hash": object["hash"]!, "mime_type": "image/png", "byte_count": bytes.count, "offset": offset,
                            "data": piece.base64EncodedString(), "eof": offset + piece.count >= bytes.count])]
            case "conversation-op":
                let op = object["op"] as! [String: Any]
                switch op["kind"] as! String {
                case "message.send":
                    let parts = op["parts"] as! [[String: Any]]
                    sentParts.append(parts)
                    let text = parts.compactMap { $0["text"] as? String }.joined()
                    let mine = message(author: "user_local", text: text, client: op["client_msg_id"] as! String, parts: parts)
                    messages.append(mine)
                    rev += 1
                    let sent = line(["event": "conversation-changed", "conversation": "conv_chief", "rev": rev, "transaction": NSNull(),
                                     "change": ["kind": "message", "message": mine]])
                    let reply = ok(["rev": rev, "seq": mine["seq"]!, "replayed": false, "change": ["kind": "message", "message": mine]])
                    rev += 1
                    let readCursor = line(["event": "conversation-changed", "conversation": "conv_chief", "rev": rev, "transaction": NSNull(),
                                           "change": ["kind": "read-cursor", "participant": "agent_chief", "seq": mine["seq"]!]])
                    let typing = line(["event": "conversation-typing", "conversation": "conv_chief", "participant": "agent_chief", "on": true])
                    let answer = message(author: "agent_chief", text: "On it.", client: "chief-1")
                    messages.append(answer)
                    rev += 1
                    let answered = line(["event": "conversation-changed", "conversation": "conv_chief", "rev": rev, "transaction": NSNull(),
                                         "change": ["kind": "message", "message": answer]])
                    return [reply, sent, readCursor, typing, answered]
                case "reaction.add":
                    let messageID = op["message_id"] as! String
                    guard let index = messages.firstIndex(where: { $0["id"] as? String == messageID }) else { return [] }
                    var reactions = messages[index]["reactions"] as! [[String: Any]]
                    reactions.append(["author": "user_local", "part_index": 0, "kind": op["reaction"]!, "at": "2026-10-12T09:42:00.000Z"])
                    messages[index]["reactions"] = reactions
                    rev += 1
                    return [ok(["rev": rev, "replayed": false, "change": ["kind": "message-updated", "message": messages[index]]])]
                default:
                    rev += 1
                    return [ok(["rev": rev, "replayed": false, "change": ["kind": "read-cursor", "participant": "user_local", "seq": messages.count]])]
                }
            default:
                return [line(["id": id, "ok": false, "error": "unknown command"])]
            }
        }
    }
}

@Suite struct ChiefDaemonBackendTests {
    @Test func createsSubscribesSendsAndReceivesChief() async throws {
        let daemon = FakeDaemon()
        let link = MockMacLink { _, request in daemon.respond(request) }
        let backend = try await ChiefDaemonBackend.open(link: link)
        var events = backend.events().makeAsyncIterator()

        guard case .connected(let info, let me, let lagged)? = await events.next() else {
            Issue.record("expected connected first")
            return
        }
        #expect(info.id == "conv_chief")
        #expect(info.title == "Chief")
        #expect(me == "user_local")
        #expect(!lagged)
        #expect(daemon.commands.prefix(4) == ["conversation-list", "conversation-create", "subscribe", "conversation-snapshot"])

        let sent = try await backend.send(ConversationOutgoingDraft(clientMessageID: "c-1", text: "run the tests", replyToID: nil, attachmentIDs: []))
        #expect(sent.seq == 1)
        #expect(sent.clientMessageID == "c-1")
        #expect(sent.delivery == .delivered)

        var sawTyping = false
        var sawRead = false
        var chiefReply: ConversationMessage?
        while chiefReply == nil, let event = await events.next() {
            switch event {
            case .typing(let who, let on): sawTyping = sawTyping || (who == "agent_chief" && on)
            case .message(let message, _):
                if message.senderID == "agent_chief" { chiefReply = message }
                if message.id == sent.id, case .read = message.delivery { sawRead = true }
            default: break
            }
        }
        #expect(sawTyping)
        #expect(sawRead)
        #expect(chiefReply?.text == "On it.")

        let reacted = try await backend.react(messageID: chiefReply!.id, reaction: .heart)
        #expect(reacted.reactions == [ConversationReactionMark(participantID: "user_local", reaction: .heart)])

        let page = try await backend.history(beforeSeq: nil, limit: 50)
        #expect(page.messages.map(\.seq) == [1, 2])
        #expect(!page.hasMore)
        backend.close()
    }
}

@Suite struct ChiefMockBackendTests {
    @Test func repliesWithTypingAndTapback() async throws {
        let backend = ChiefMockBackend(sleep: { _ in })
        var events = backend.events().makeAsyncIterator()
        guard case .connected(let info, _, _)? = await events.next() else {
            Issue.record("expected connected")
            return
        }
        #expect(info.title == "Chief")
        let history = try await backend.history(beforeSeq: nil, limit: 5)
        #expect(history.messages.count == 5)
        #expect(history.hasMore)

        let sent = try await backend.send(ConversationOutgoingDraft(clientMessageID: "x", text: "thanks, what's the status?", replyToID: nil, attachmentIDs: []))
        var typing = false
        var tapback: ConversationReaction?
        var reply: ConversationMessage?
        while reply == nil, let event = await events.next() {
            switch event {
            case .typing(_, let on): typing = typing || on
            case .message(let message, _):
                if message.id == sent.id { tapback = message.reactions.first?.reaction ?? tapback }
                if message.senderID == ChiefIdentity.standard.chiefID { reply = message }
            default: break
            }
        }
        #expect(typing)
        #expect(tapback == .heart)
        #expect(reply?.text.contains("workspaces") == true)
        // Idempotent on the client id.
        let again = try await backend.send(ConversationOutgoingDraft(clientMessageID: "x", text: "thanks", replyToID: nil, attachmentIDs: []))
        #expect(again.id == sent.id)
    }
}

/// A 4 x 3 PNG.
private let tinyPNG = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAQAAAADCAIAAAA7ljmRAAAAE0lEQVR4nGPkqjjBAANMcBY6BwAvkAFQPo8GTQAAAABJRU5ErkJggg==")!

@Suite struct ChiefAttachmentTests {
    /// User feedback: a photo sent to Chief came back "Not Delivered".
    @Test func mockDeliversPhotosAndRepliesToThem() async throws {
        let backend = ChiefMockBackend(sleep: { _ in })
        var events = backend.events().makeAsyncIterator()
        _ = await events.next()
        let uploaded = try await backend.uploadImage(tinyPNG, mimeType: "image/png")
        #expect(uploaded.kind == .image)
        #expect(uploaded.width == 4 && uploaded.height == 3)
        let sent = try await backend.send(ConversationOutgoingDraft(clientMessageID: "p", text: "", replyToID: nil, attachmentIDs: [uploaded.id]))
        #expect(sent.attachments.map(\.id) == [uploaded.id])
        #expect(sent.attachments.first?.localData == tinyPNG)
        #expect(sent.delivery == .delivered)
        var reply: ConversationMessage?
        while reply == nil, let event = await events.next() {
            if case .message(let message, _) = event, message.senderID == ChiefIdentity.standard.chiefID { reply = message }
        }
        #expect(reply?.text.contains("photo") == true)
    }

    @Test func storeSendsAPhotoWithTextToTheMock() async throws {
        let store = await ConversationStore(backend: ChiefMockBackend(sleep: { _ in }))
        await store.start()
        while await store.meID == nil { await Task.yield() }
        await store.send(text: "look", images: [(data: tinyPNG, width: 4, height: 3, mimeType: "image/png")])
        while await store.messages.contains(where: { $0.seq == nil }) { await Task.yield() }
        let mine = await store.messages.filter { $0.senderID == ChiefIdentity.standard.meID && !$0.attachments.isEmpty }
        #expect(mine.count == 1)
        #expect(mine.first?.delivery?.isFailed == false)
    }

    /// `conversation-attachment-upload` begin, chunk, commit; the send names
    /// the hash in an `attachment` part; a photo from Chief is read by hash.
    @Test func daemonUploadsByHashAndReadsIncomingBytes() async throws {
        let daemon = FakeDaemon()
        let link = MockMacLink { _, request in daemon.respond(request) }
        let backend = try await ChiefDaemonBackend.open(link: link)
        var events = backend.events().makeAsyncIterator()
        _ = await events.next()
        let photo = daemon.seedChiefPhoto(tinyPNG)

        let uploaded = try await backend.uploadImage(tinyPNG, mimeType: "image/png")
        #expect(daemon.commands.filter { $0 == "conversation-attachment-upload" }.count == 3)
        #expect(uploaded.width == 4 && uploaded.height == 3)
        let sent = try await backend.send(ConversationOutgoingDraft(clientMessageID: "a-1", text: "the chart", replyToID: nil, attachmentIDs: [uploaded.id]))
        let parts = try #require(daemon.sentParts.last)
        #expect(parts.map { $0["type"] as? String } == ["attachment", "text"])
        #expect(parts[0]["byte_count"] as? Int == tinyPNG.count)
        #expect(sent.attachments.first?.localData == tinyPNG)
        #expect(sent.text == "the chart")

        let page = try await backend.history(beforeSeq: nil, limit: 50)
        let incoming = try #require(page.messages.first { $0.senderID == "agent_chief" && !$0.attachments.isEmpty })
        #expect(incoming.attachments.first?.id == "att:\(photo)")
        #expect(incoming.attachments.first?.localData == tinyPNG)
        #expect(daemon.commands.contains("conversation-attachment-read"))
        backend.close()
    }
}

#if os(iOS)
@Suite @MainActor struct ChiefDirectoryTests {
    func directory() -> ChiefDirectory {
        let chief = ChiefDirectory.recipients(store: AppStore(teams: [], activeTeamID: "", workspaces: [], feed: []), identity: .standard)
        let agent = ChiefRecipient(
            contact: ConversationContact(id: "tab:t1", name: "Claude · cmux", initials: "CL", colorHex: "#636366",
                                         handles: [ConversationContactHandle(value: "cmux", label: "Claude", service: .iMessage)]),
            route: .agent(AgentChatDestination(workspaceID: "ws", tabID: "t1"))
        )
        return ChiefDirectory(recipients: [chief[0], agent])
    }

    @Test func listsChiefFirstAndSearchesNames() async throws {
        let directory = directory()
        #expect(try await directory.searchContacts("", limit: 10, excluding: []).map(\.id) == ["agent_chief", "tab:t1"])
        #expect(try await directory.searchContacts("clau", limit: 10, excluding: []).map(\.id) == ["tab:t1"])
        #expect(try await directory.lookupHandles(["nobody"]).first?.service == nil)
    }

    @Test func oneAgentOpensItsChatSeveralOpenChief() async throws {
        let directory = directory()
        let agent = try await directory.createConversation([.participant("tab:t1")])
        #expect(agent.info.id == "tab:t1")
        let chief = try await directory.createConversation([.participant("agent_chief")])
        #expect(chief.info.id == ChiefDirectory.chiefContactID)
        let both = try await directory.createConversation([.participant("agent_chief"), .participant("tab:t1")])
        #expect(both.info.id == ChiefDirectory.chiefContactID)
        await #expect(throws: ConversationBackendError.self) { try await directory.createConversation([.handle("nobody")]) }
    }
}
#endif
