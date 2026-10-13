import CmuxConversationCore
import CnxTransport
import CryptoKit
import Foundation

/// The real Chief: the cmux-tui local conversation owner, reached through a
/// link's `daemon` channel (protocol v12 JSON lines, capability
/// `local-conversations-v1`). Finds (or creates) the Chief conversation,
/// subscribes, loads pages with `conversation-snapshot` /
/// `conversation-history`, writes with `conversation-op`, and turns
/// `conversation-changed` / `conversation-typing` events into store events.
/// A `rev` gap means events were missed: the store is told to refetch.
public final class ChiefDaemonBackend: ConversationFileBackend, @unchecked Sendable {
    let core: Core

    public init(client: DaemonClient, identity: ChiefIdentity = .standard, conversationID: String? = nil) {
        core = Core(client: client, identity: identity, conversationID: conversationID)
    }

    /// Opens a `daemon` channel on `link` for Chief.
    public static func open(link: any MacLink, identity: ChiefIdentity = .standard) async throws -> ChiefDaemonBackend {
        let channel = try await link.openChannel(service: "daemon", args: [:])
        return ChiefDaemonBackend(client: DaemonClient(channel: channel), identity: identity)
    }

    public func events() -> AsyncStream<ConversationBackendEvent> {
        let (stream, continuation) = AsyncStream<ConversationBackendEvent>.makeStream(bufferingPolicy: .unbounded)
        Task { await core.run(continuation) }
        return stream
    }

    public func history(beforeSeq: Int?, limit: Int) async throws -> ConversationHistoryPage {
        try await core.history(beforeSeq: beforeSeq, limit: limit)
    }

    public func send(_ draft: ConversationOutgoingDraft) async throws -> ConversationMessage {
        try await core.send(draft)
    }

    public func react(messageID: String, reaction: ConversationReaction?) async throws -> ConversationMessage {
        try await core.react(messageID: messageID, reaction: reaction)
    }

    public func edit(messageID: String, text: String) async throws -> ConversationMessage {
        try await core.op(["kind": "message.edit", "message_id": messageID, "parts": [["type": "text", "text": text]]])
    }

    public func unsend(messageID: String) async throws -> ConversationMessage {
        try await core.op(["kind": "message.retract", "message_id": messageID])
    }

    public func setTyping(_ isTyping: Bool) async {
        await core.typing(isTyping)
    }

    public func markRead(upToSeq: Int) async {
        await core.markRead(upToSeq)
    }

    /// `conversation-attachment-upload` (capability `local-attachments-v1`):
    /// begin by SHA-256, send 2 MiB chunks, commit. The message names the
    /// stored hash in an `attachment` part.
    public func uploadImage(_ data: Data, mimeType: String) async throws -> ConversationAttachment {
        let size = ChiefImageSize(data: data)
        let ext = mimeType == "image/png" ? "png" : mimeType == "image/heic" ? "heic" : "jpg"
        return try await core.upload(data, mimeType: mimeType, name: "IMG_\(Int(Date().timeIntervalSince1970)).\(ext)",
                                     width: size.width, height: size.height, file: nil)
    }

    public func uploadFileAttachment(_ data: Data, info: ConversationFileInfo) async throws -> ConversationAttachment {
        try await core.upload(data, mimeType: info.mimeType, name: info.name, width: nil, height: nil, file: info)
    }

    public func close() {
        Task { await core.close() }
    }

    actor Core {
        let client: DaemonClient
        let identity: ChiefIdentity
        let wire: ChiefWire
        private var conversationID: String?
        private var continuation: AsyncStream<ConversationBackendEvent>.Continuation?
        private var rev: UInt64 = 0
        private var eventSeq = 0
        private var peerReadSeq = 0
        private var lastSeq = 0
        /// Messages seen, by id: my current tapback (to replace it) and receipts.
        private var known: [String: ConversationMessage] = [:]
        private var readTask: Task<Void, Never>?
        /// Uploaded attachments by the id the store holds, as message parts.
        private var uploadedParts: [String: [String: Any]] = [:]
        /// Attachment bytes by hash: uploaded here or read once with `conversation-attachment-read`.
        private var attachmentBytes: [String: Data] = [:]
        /// 2 MiB: base64 keeps each line under the link's 4 MiB line cap.
        static let chunkBytes = 2 * 1024 * 1024

        init(client: DaemonClient, identity: ChiefIdentity, conversationID: String?) {
            self.client = client
            self.identity = identity
            self.conversationID = conversationID
            wire = ChiefWire(identity: identity)
        }

        // MARK: Requests

        /// Sends one command and returns its `data` object, or throws the
        /// daemon's refusal (`error_code` / reason) as a backend error.
        func call(_ cmd: String, _ params: sending [String: Any] = [:]) async throws -> [String: Any] {
            let line = try await client.request(cmd, params: params)
            guard let reply = try JSONSerialization.jsonObject(with: line) as? [String: Any] else {
                throw ConversationBackendError(code: -32700, message: "bad reply to \(cmd)")
            }
            if reply["ok"] as? Bool == false {
                let error = reply["error"]
                let text = (error as? [String: Any])?["message"] as? String ?? error as? String ?? "\(cmd) failed"
                let code = (error as? [String: Any])?["error_code"] as? String ?? reply["error_code"] as? String
                throw ConversationBackendError(code: -32000, message: code.map { "\($0): \(text)" } ?? text)
            }
            return reply["data"] as? [String: Any] ?? [:]
        }

        /// The Chief conversation: the given id, the existing one, or a new one.
        func resolve() async throws -> String {
            if let conversationID { return conversationID }
            let list = try await call("conversation-list")
            let summaries = list["conversations"] as? [[String: Any]] ?? []
            if let found = summaries.first(where: { wire.isChief($0) && ($0["title"] as? String) == identity.title }),
               let id = found["id"] as? String {
                conversationID = id
                return id
            }
            let created = try await call("conversation-create", [
                "idempotency_key": "cnx-ios-chief-\(identity.meID)",
                "title": identity.title,
                "participants": wire.participants(),
            ])
            guard let id = (created["conversation"] as? [String: Any])?["id"] as? String else {
                throw ConversationBackendError(code: -4, message: "conversation-create returned no conversation")
            }
            conversationID = id
            return id
        }

        func send(_ draft: ConversationOutgoingDraft) async throws -> ConversationMessage {
            var parts: [[String: Any]] = draft.attachmentIDs.compactMap { uploadedParts[$0] }
            if !draft.text.isEmpty || parts.isEmpty { parts.append(["type": "text", "text": draft.text]) }
            var op: [String: Any] = ["kind": "message.send", "client_msg_id": draft.clientMessageID, "parts": parts]
            if let reply = draft.replyToID { op["reply_to"] = ["message_id": reply, "part_index": 0] }
            return try await self.op(op, idempotencyKey: draft.clientMessageID)
        }

        func upload(_ data: Data, mimeType: String, name: String, width: Int?, height: Int?, file: ConversationFileInfo?) async throws -> ConversationAttachment {
            let id = try await resolve()
            let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            var begin: [String: Any] = [
                "op": "begin", "conversation": id, "sha256": hash, "byte_count": data.count,
                "mime_type": mimeType, "name": name,
            ]
            if let width, width > 0 { begin["width"] = width }
            if let height, height > 0 { begin["height"] = height }
            let started = try await call("conversation-attachment-upload", begin)
            if let upload = started["upload"] as? String {
                var offset = 0
                repeat {
                    let piece = data.subdata(in: offset..<min(data.count, offset + Self.chunkBytes))
                    _ = try await call("conversation-attachment-upload", [
                        "op": "chunk", "upload": upload, "piece": "original", "offset": offset,
                        "data": piece.base64EncodedString(),
                    ])
                    offset += piece.count
                } while offset < data.count
                _ = try await call("conversation-attachment-upload", ["op": "commit", "upload": upload])
            }
            attachmentBytes[hash] = data
            var part: [String: Any] = [
                "type": "attachment", "hash": hash, "name": name, "mime_type": mimeType, "byte_count": data.count,
            ]
            if let width, width > 0 { part["width"] = width }
            if let height, height > 0 { part["height"] = height }
            let attachment = wire.attachment(part, bytes: data) ?? ConversationAttachment(
                id: "att:\(hash)", kind: .file, width: 0, height: 0, url: nil, localData: data, file: file
            )
            uploadedParts[attachment.id] = part
            return attachment
        }

        /// Reads the bytes of every attachment part not seen yet, so the
        /// message renders from them (the owner serves no URL).
        private func hydrate(_ object: [String: Any]) async {
            guard let id = conversationID else { return }
            for part in object["parts"] as? [[String: Any]] ?? [] where part["type"] as? String == "attachment" {
                guard let hash = part["hash"] as? String, attachmentBytes[hash] == nil else { continue }
                var data = Data()
                while true {
                    guard let chunk = try? await call("conversation-attachment-read", [
                        "conversation": id, "hash": hash, "offset": data.count, "length": Self.chunkBytes,
                    ]), let text = chunk["data"] as? String, let bytes = Data(base64Encoded: text) else { break }
                    data.append(bytes)
                    if chunk["eof"] as? Bool ?? true || bytes.isEmpty { break }
                }
                if !data.isEmpty { attachmentBytes[hash] = data }
            }
        }

        /// A wire message, its attachments' bytes read first.
        private func decode(_ object: [String: Any]) async -> ConversationMessage? {
            await hydrate(object)
            return wire.message(object, peerReadSeq: peerReadSeq, bytes: attachmentBytes)
        }

        func op(_ op: sending [String: Any], idempotencyKey: String = UUID().uuidString) async throws -> ConversationMessage {
            let id = try await resolve()
            let result = try await call("conversation-op", ["conversation": id, "idempotency_key": idempotencyKey, "op": op])
            guard let change = result["change"] as? [String: Any], let object = change["message"] as? [String: Any],
                  let message = await decode(object) else {
                throw ConversationBackendError(code: -4, message: "conversation-op returned no message")
            }
            remember(message)
            return message
        }

        func react(messageID: String, reaction: ConversationReaction?) async throws -> ConversationMessage {
            var latest: ConversationMessage?
            if let current = known[messageID]?.reactions.first(where: { $0.participantID == identity.meID })?.reaction, current != reaction {
                latest = try await op(["kind": "reaction.remove", "message_id": messageID, "part_index": 0, "reaction": wire.wireKind(current)])
            }
            if let reaction, known[messageID]?.reactions.contains(where: { $0.participantID == identity.meID && $0.reaction == reaction }) != true {
                latest = try await op(["kind": "reaction.add", "message_id": messageID, "part_index": 0, "reaction": wire.wireKind(reaction)])
            }
            guard let message = latest ?? known[messageID] else {
                throw ConversationBackendError(code: 404, message: "unknown message")
            }
            return message
        }

        func typing(_ on: Bool) async {
            guard let id = try? await resolve() else { return }
            _ = try? await call("conversation-typing", ["conversation": id, "on": on])
        }

        func markRead(_ seq: Int) async {
            guard let id = try? await resolve() else { return }
            _ = try? await call("conversation-op", [
                "conversation": id, "idempotency_key": UUID().uuidString, "op": ["kind": "read_cursor.set", "seq": seq],
            ])
            yieldReadState(lastRead: seq)
        }

        func history(beforeSeq: Int?, limit: Int) async throws -> ConversationHistoryPage {
            let id = try await resolve()
            let objects: [[String: Any]]
            if let beforeSeq {
                let page = try await call("conversation-history", ["conversation": id, "before_seq": beforeSeq, "limit": min(500, max(1, limit))])
                objects = page["messages"] as? [[String: Any]] ?? []
            } else {
                let snapshot = try await call("conversation-snapshot", ["conversation": id, "tail": min(500, max(1, limit))])
                if let summary = snapshot["conversation"] as? [String: Any] { absorb(summary) }
                objects = snapshot["messages"] as? [[String: Any]] ?? []
            }
            var messages: [ConversationMessage] = []
            for object in objects {
                if let message = await decode(object) { messages.append(message) }
            }
            messages.forEach(remember)
            return ConversationHistoryPage(messages: messages, hasMore: (messages.first?.seq ?? 1) > 1)
        }

        // MARK: Session

        func run(_ continuation: AsyncStream<ConversationBackendEvent>.Continuation) async {
            self.continuation = continuation
            do {
                let id = try await resolve()
                _ = try await call("subscribe")
                try await connect(id: id, lagged: false)
            } catch {
                continuation.yield(.disconnected(reason: "\(error)"))
                return
            }
            for await line in client.events {
                await route(line)
            }
            continuation.yield(.disconnected(reason: "daemon channel closed"))
        }

        private func connect(id: String, lagged: Bool) async throws {
            let snapshot = try await call("conversation-snapshot", ["conversation": id, "tail": 1])
            guard let summary = snapshot["conversation"] as? [String: Any], let info = wire.info(summary) else {
                throw ConversationBackendError(code: -4, message: "conversation-snapshot returned no conversation")
            }
            absorb(summary)
            continuation?.yield(.connected(info: info, meID: identity.meID, lagged: lagged))
            yieldReadState(lastRead: wire.readCursor(summary, of: identity.meID))
        }

        private func absorb(_ summary: [String: Any]) {
            rev = max(rev, (summary["rev"] as? NSNumber)?.uint64Value ?? 0)
            lastSeq = max(lastSeq, (summary["last_seq"] as? NSNumber)?.intValue ?? 0)
            peerReadSeq = max(peerReadSeq, wire.readCursor(summary, of: identity.chiefID))
        }

        private func yieldReadState(lastRead: Int) {
            let unread = known.values.filter { ($0.seq ?? 0) > lastRead && $0.senderID != identity.meID }.count
            continuation?.yield(.readState(ConversationReadState(lastReadSeq: lastRead, unreadCount: unread, headSeq: lastSeq)))
        }

        private func remember(_ message: ConversationMessage) {
            known[message.id] = message
            lastSeq = max(lastSeq, message.seq ?? 0)
        }

        private func yieldMessage(_ message: ConversationMessage) {
            remember(message)
            eventSeq += 1
            continuation?.yield(.message(message, eventSeq: eventSeq))
        }

        func route(_ line: Data) async {
            guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let event = object["event"] as? String, object["conversation"] as? String == conversationID else { return }
            switch event {
            case "conversation-typing":
                guard let who = object["participant"] as? String, who != identity.meID else { return }
                continuation?.yield(.typing(participantID: who, isTyping: object["on"] as? Bool ?? false))
            case "conversation-changed":
                let incoming = (object["rev"] as? NSNumber)?.uint64Value ?? 0
                guard incoming > rev else { return }
                if incoming > rev + 1, let id = conversationID {
                    // Missed ops: resync, and the store refetches the newest page.
                    rev = incoming
                    try? await connect(id: id, lagged: true)
                    return
                }
                rev = incoming
                await apply(object["change"] as? [String: Any] ?? [:])
            default:
                break
            }
        }

        private func apply(_ change: [String: Any]) async {
            switch change["kind"] as? String {
            case "message", "message-updated":
                if let object = change["message"] as? [String: Any], let message = await decode(object) {
                    yieldMessage(message)
                }
            case "read-cursor":
                let seq = (change["seq"] as? NSNumber)?.intValue ?? 0
                guard let who = change["participant"] as? String else { return }
                if who == identity.meID {
                    yieldReadState(lastRead: seq)
                } else if who == identity.chiefID, seq > peerReadSeq {
                    let previous = peerReadSeq
                    peerReadSeq = seq
                    // Receipts: my messages Chief just read.
                    for var message in known.values.sorted(by: { ($0.seq ?? 0) < ($1.seq ?? 0) })
                    where message.senderID == identity.meID && (message.seq ?? 0) > previous && (message.seq ?? 0) <= seq {
                        message.delivery = .read(Date())
                        yieldMessage(message)
                    }
                }
            case "conversation":
                if let summary = change["conversation"] as? [String: Any], let info = wire.info(summary) {
                    absorb(summary)
                    continuation?.yield(.conversationChanged(info))
                }
            default:
                break
            }
        }

        func close() async {
            continuation?.finish()
            continuation = nil
        }
    }
}
