import CmuxControlPlane
import CmuxHomeCore
import CmuxiOSCloudCore
import CmuxMobileWire
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// The iOS Home owner backed by the cloud UserDO and ConversationDOs.
///
/// Reads use the authenticated HTTP API (which also reaches Worker-derived
/// operations); sockets are kept for the user inbox and opened conversations
/// so the UI receives revisions as soon as an owner commits them.
final actor CloudHomeSource: HomeSource {
    /// Factories are deliberately asynchronous.  The authenticated install is
    /// resolved from `InstallIdentity` only when Home is first used, while the
    /// `AppContainer` can still compose all of its seams synchronously.
    typealias MakeUser = @Sendable () async throws -> (user: String, session: any ControlPlaneSession)
    typealias MakeConversation = @Sendable (ConversationID) async throws -> any ControlPlaneSession

    private let me: Participant
    private let api: any CloudAPIClient
    private let makeUser: MakeUser
    private let makeConversation: MakeConversation?
    private var user: String?
    private var userSession: (any ControlPlaneSession)?
    private var startTask: Task<Void, Never>?
    private var inboxCache = InboxSnapshot(me: Participant(id: ParticipantID(""), kind: .human, displayName: ""), conversations: [], rev: 0)
    private var inboxTask: Task<Void, Never>?
    private var stateTask: Task<Void, Never>?
    private var conversationClients: [ConversationID: any ControlPlaneSession] = [:]
    private var conversationTasks: [ConversationID: Task<Void, Never>] = [:]
    private var continuations: [UUID: AsyncStream<HomeEvent>.Continuation] = [:]
    private var lastConnection: HomeConnection?
    /// Downloaded cloud attachment variants. URLSession writes to a temporary
    /// file first, then moves into this directory atomically.
    private let attachmentCache: URL

    private static let defaultAttachmentCache: URL = {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return caches.appendingPathComponent(Bundle.main.bundleIdentifier ?? "cmux", isDirectory: true)
            .appendingPathComponent("HomeAttachments", isDirectory: true)
    }()
    private static let attachmentCacheLimit = 512_000_000

    init(me: Participant, api: any CloudAPIClient, makeUser: @escaping MakeUser,
         makeConversation: MakeConversation? = nil,
         attachmentCache: URL = CloudHomeSource.defaultAttachmentCache) {
        self.me = me
        self.api = api
        self.makeUser = makeUser
        self.makeConversation = makeConversation
        self.attachmentCache = attachmentCache
        inboxCache = InboxSnapshot(me: me, conversations: [], rev: 0)
    }

    /// Compatibility initializer for callers that already own a client (for
    /// example focused tests). Production composition should use the factory
    /// initializer above so identity resolution remains lazy.
    init(user: String, me: Participant, userClient: any ControlPlaneSession, api: any CloudAPIClient,
         makeConversation: MakeConversation? = nil,
         attachmentCache: URL = CloudHomeSource.defaultAttachmentCache) {
        self.me = me
        self.api = api
        self.makeUser = { (user: user, session: userClient) }
        self.makeConversation = makeConversation
        self.attachmentCache = attachmentCache
        inboxCache = InboxSnapshot(me: me, conversations: [], rev: 0)
    }

    func start() async {
        if let startTask {
            await startTask.value
            return
        }
        let task = Task { [weak self] in
            guard let self else { return }
            await self.resolveAndStart()
        }
        startTask = task
        await task.value
    }

    func events() async -> AsyncStream<HomeEvent> {
        await start()
        let id = UUID()
        let (stream, continuation) = AsyncStream<HomeEvent>.makeStream(bufferingPolicy: .bufferingNewest(128))
        continuations[id] = continuation
        if let lastConnection { continuation.yield(.connection(lastConnection)) }
        continuation.onTermination = { [weak self] _ in Task { await self?.removeContinuation(id) } }
        return stream
    }

    private func resolveAndStart() async {
        guard inboxTask == nil else { return }
        do {
            let resolved = try await makeUser()
            user = resolved.user
            userSession = resolved.session
            await resolved.session.start()
            let stream = await resolved.session.subscribe("inbox:\(resolved.user)")
            lastConnection = .connecting
            publish(.connection(.connecting))
            inboxTask = Task { [weak self] in
                for await update in stream { await self?.applyInbox(update) }
            }
            let states = await resolved.session.stateUpdates()
            stateTask = Task { [weak self] in
                for await state in states { await self?.applyState(state) }
            }
        } catch {
            let offline = HomeConnection.offline(since: Date())
            lastConnection = offline
            publish(.connection(offline))
        }
    }

    func inbox() async throws -> InboxSnapshot {
        let value = try await api.read("inbox.list", params: ["limit": .int(200)])
        let entries = try decodeInboxEntries(value["entries"] ?? .array([]))
        let revision = UInt64(value["revision"]?.stringValue ?? "0") ?? 0
        let snapshot = InboxSnapshot(me: me, conversations: entries.map { summary($0) }, rev: revision)
        inboxCache = snapshot
        publish(.inbox(snapshot))
        return snapshot
    }

    func snapshot(of conversation: ConversationID, tail: Int) async throws -> ConversationPage {
        let value = try await api.read("conversation.snapshot", params: ["conversation": .string(conversation.rawValue), "tail": .int(Int64(max(0, min(tail, 200))))])
        let page = try decodePage(value)
        await ensureConversationSubscription(conversation)
        return page
    }

    func history(of conversation: ConversationID, before beforeSeq: Seq, limit: Int) async throws -> [Message] {
        let value = try await api.read("conversation.history", params: ["conversation": .string(conversation.rawValue), "before_seq": .int(Int64(beforeSeq)), "limit": .int(Int64(max(1, min(limit, 200))))])
        let rows = value["messages"] ?? .array([])
        guard case .array(let values) = rows else { throw CloudAPIError.transport }
        return try values.compactMap { try message($0) }
    }

    func submit(_ intent: HomeIntent) async throws -> HomeOpResult {
        if case .setTyping(let conversation, let on) = intent.op {
            // Typing is ephemeral and intentionally omitted from the ledger.
            // The conversation socket is already the owner-scoped transport,
            // so this sends the raw {t: "typing", on} frame directly rather
            // than manufacturing a durable operation.
            await ensureConversationSubscription(conversation)
            guard let session = conversationClients[conversation] else {
                throw HomeRejection.ownerUnreachable
            }
            do {
                try await session.sendTyping(on: on)
            } catch is ControlPlaneError {
                // A typing update has no retry semantics. Treat a socket that
                // is still connecting, full, or stopped as an unavailable
                // owner so the UI can drop this update and try the next one.
                throw HomeRejection.ownerUnreachable
            } catch {
                throw HomeRejection.ownerUnreachable
            }
            return HomeOpResult(rev: 0, conversation: conversation)
        }
        if case .startConversation(let contacts, let firstMessage) = intent.op {
            return try await startConversation(contacts: contacts, firstMessage: firstMessage, key: intent.key.rawValue)
        }
        var mapped = try map(intent.op)
        if case .sendMessage = intent.op { mapped.params["client_msg_id"] = .string(intent.key.rawValue) }
        let (value, revision) = try await commit(mapped, key: intent.key.rawValue)
        let conversation = value["conversation"]?["id"]?.stringValue ?? value["conversation"]?.stringValue
        // `HomeOp.invite` is represented by the cloud `dm.open` operation.  An
        // address peer is invited as part of that operation and the Worker
        // returns only `{invite: {ok: true}}`, rather than echoing the raw
        // address.  Keep the typed contact from the intent when constructing
        // the Home receipt.
        let invite: InviteReceipt?
        if case .invite(let contact) = intent.op {
            invite = inviteReceipt(for: contact, value: value["invite"])
        } else {
            invite = value["invite"].flatMap(decodeInvite)
        }
        return HomeOpResult(rev: revision, replayed: false, conversation: conversation.map { ConversationID($0) }, invite: invite)
    }

    func search(_ query: String, limit: Int) async throws -> [HomeSearchHit] {
        let value = try await api.read("home.search", params: ["q": .string(query), "limit": .int(Int64(max(1, min(limit, 100))))])
        guard case .array(let hits) = value["hits"] else { return [] }
        return try hits.compactMap { hit in
            guard let conversation = hit["conversation"]?.stringValue,
                  let messageID = hit["message_id"]?.stringValue,
                  let author = hit["author"]?.stringValue,
                  let seq = hit["seq"]?.intValue else { return nil }
            let created = date(hit["created_at"]) ?? .distantPast
            let text = hit["snippet"]?.stringValue ?? ""
            let message = Message(id: MessageID(messageID), conversation: ConversationID(conversation), seq: Seq(seq), clientMessageID: .init(rawValue: "search:\(messageID)"), author: ParticipantID(author), parts: [.text(text)], createdAt: created)
            let ranges: [Range<Int>] = (hit["ranges"]?.arrayValue ?? []).compactMap { item in
                guard let start = item["start"]?.intValue, let length = item["length"]?.intValue else { return nil }
                return Int(start)..<Int(start + length)
            }
            return HomeSearchHit(conversation: ConversationID(conversation), message: message, highlights: ranges)
        }
    }

    func resolve(_ contact: ContactAddress) async throws -> ContactResolution { .invitable(contact) }

    // MARK: Cloud attachments

    /// Requests a single-use owner slot, uploads any declared derived image,
    /// then uploads or commits the original. The owner verifies every hash and
    /// keeps the first record for a hash, making this safe to retry after a
    /// lost response.
    func upload(_ file: AttachmentUpload) async throws -> AttachmentRef {
        var params: [String: JSONValue] = [
            "conversation": .string(file.conversation.rawValue),
            "sha256": .string(file.ref.hash),
            "byte_count": .int(Int64(file.ref.byteCount)),
            "mime_type": .string(file.ref.mimeType),
            "name": .string(file.ref.name),
        ]
        if let width = file.ref.width { params["width"] = .int(Int64(width)) }
        if let height = file.ref.height { params["height"] = .int(Int64(height)) }
        if let duration = file.ref.durationMs { params["duration_ms"] = .int(Int64(duration)) }
        if let poster = file.ref.poster {
            params["poster"] = .object(["sha256": .string(poster.hash),
                                         "byte_count": .int(Int64(poster.byteCount)),
                                         "mime_type": .string(poster.mimeType)])
        }
        if let preview = file.ref.preview {
            params["preview"] = .object(["sha256": .string(preview.hash),
                                          "byte_count": .int(Int64(preview.byteCount)),
                                          "mime_type": .string(preview.mimeType)])
        }

        let intent = try await attachmentCall { try await api.attachmentIntent(params: params) }
        if intent["state"]?.stringValue == "exists" {
            file.progress(1)
            return try storedAttachment(file.ref, from: intent)
        }
        guard intent["state"]?.stringValue == "upload",
              let originalURL = intent["upload_url"]?.stringValue.flatMap(URL.init(string:)),
              let originalHeaders = headers(intent["headers"]),
              (intent["method"]?.stringValue ?? "PUT") == "PUT" else {
            throw HomeRejection.indeterminate
        }
        let mode = intent["mode"]?.stringValue ?? "stream"

        // A declared poster/preview must land before the original; otherwise
        // the owner deliberately answers `attachment.*_missing` and leaves the
        // original slot usable for a retry.
        if let posterURL = file.posterURL, intent["poster_upload"] != nil {
            try await putDerived(posterURL, description: intent["poster_upload"], progress: file.progress)
        }
        if let previewURL = file.previewURL, intent["preview_upload"] != nil {
            try await putDerived(previewURL, description: intent["preview_upload"], progress: file.progress)
        }
        guard file.ref.poster == nil || file.posterURL != nil || intent["poster_upload"] == nil else {
            throw HomeRejection.invalid("poster_missing")
        }
        guard file.ref.preview == nil || file.previewURL != nil || intent["preview_upload"] == nil else {
            throw HomeRejection.invalid("preview_missing")
        }

        file.progress(0.1)
        var streamAnswer: JSONValue = .null
        do {
            streamAnswer = try await api.uploadAttachmentBytes(file: file.fileURL, to: originalURL, headers: originalHeaders,
                                                               progress: { fraction in file.progress(0.1 + fraction * 0.85) })
        } catch let error as CloudAPIError {
            // A presigned PUT is protected by `if-none-match: *`; a retry can
            // legitimately observe 412 after the first PUT already landed.
            if mode != "presigned" || !Self.isPreconditionFailure(error) { throw mapAttachment(error) }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw HomeRejection.indeterminate
        }

        let answer: JSONValue
        if mode == "presigned" {
            guard let slot = intent["slot"]?.stringValue else { throw HomeRejection.indeterminate }
            answer = try await attachmentCall { try await api.commitAttachment(conversation: file.conversation.rawValue, slot: slot) }
        } else {
            // Worker stream PUT answers with the final stored attachment.
            answer = streamAnswer
        }
        file.progress(1)
        return try storedAttachment(file.ref, from: answer)
    }

    func fetch(_ ref: AttachmentRef, at location: AttachmentLocation, variant: AttachmentVariant) async throws -> URL {
        let variantName: String?
        let mimeType: String
        switch variant {
        case .original:
            variantName = nil; mimeType = ref.mimeType
        case .poster:
            guard let poster = ref.poster else { throw HomeRejection.invalid("no_poster") }
            variantName = "poster"; mimeType = poster.mimeType
        case .preview:
            guard let preview = ref.preview else { throw HomeRejection.invalid("no_preview") }
            variantName = "preview"; mimeType = preview.mimeType
        case .thumbnail(let maxPixel):
            let target = attachmentCache.appendingPathComponent("\(ref.hash)-thumb-\(max(1, maxPixel)).jpg")
            if FileManager.default.fileExists(atPath: target.path) { return Self.touch(target) }
            let source: URL
            if ref.mimeType.lowercased().hasPrefix("image/") {
                source = try await fetch(ref, at: location, variant: .original)
            } else if ref.poster != nil {
                source = try await fetch(ref, at: location, variant: .poster)
            } else {
                throw HomeRejection.invalid("no_thumbnail")
            }
            try FileManager.default.createDirectory(at: attachmentCache, withIntermediateDirectories: true)
            guard let sourceImage = CGImageSourceCreateWithURL(source as CFURL, nil),
                  let image = CGImageSourceCreateThumbnailAtIndex(sourceImage, 0, [
                      kCGImageSourceCreateThumbnailFromImageAlways: true,
                      kCGImageSourceCreateThumbnailWithTransform: true,
                      kCGImageSourceThumbnailMaxPixelSize: max(1, maxPixel),
                  ] as CFDictionary) else { throw HomeRejection.invalid("thumbnail_failed") }
            let data = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else {
                throw HomeRejection.invalid("thumbnail_failed")
            }
            CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
            guard CGImageDestinationFinalize(destination) else { throw HomeRejection.invalid("thumbnail_failed") }
            try Task.checkCancellation()
            try data.write(to: target, options: .atomic)
            trimAttachmentCache(keeping: target)
            return target
        }

        let target = attachmentCache.appendingPathComponent("\(ref.hash)-\(variantName ?? "original")\(Self.extensionFor(mimeType))")
        if FileManager.default.fileExists(atPath: target.path) { return Self.touch(target) }
        var params: [String: JSONValue] = [
            "conversation": .string(location.conversation.rawValue),
            "hash": .string(ref.hash),
        ]
        if let message = location.message {
            guard let partIndex = location.partIndex else { throw HomeRejection.invalid("message_id needs a part_index") }
            params["message_id"] = .string(message.rawValue)
            params["part_index"] = .int(Int64(partIndex))
        } else if location.partIndex != nil {
            throw HomeRejection.invalid("message_id needs a part_index")
        }
        if let variantName { params["variant"] = .string(variantName) }
        let signed = try await attachmentCall { try await api.attachmentURL(params: params) }
        try await attachmentCall { try await api.downloadAttachment(from: signed, to: target, progress: { _ in }) }
        trimAttachmentCache(keeping: target)
        return target
    }

    private func putDerived(_ file: URL, description: JSONValue?, progress: @escaping @Sendable (Double) -> Void) async throws {
        guard let description, let url = description["upload_url"]?.stringValue.flatMap(URL.init(string:)),
              let headers = headers(description["headers"]) else { throw HomeRejection.indeterminate }
        do {
            _ = try await api.uploadAttachmentBytes(file: file, to: url, headers: headers, progress: { progress(0.02 + $0 * 0.06) })
        } catch let error as CloudAPIError { throw mapAttachment(error) }
    }

    private func storedAttachment(_ declared: AttachmentRef, from value: JSONValue) throws -> AttachmentRef {
        guard let attachment = value["attachment"] ?? (value["state"] == nil ? value : nil),
              let hash = attachment["hash"]?.stringValue, hash == declared.hash else {
            throw HomeRejection.invalid("attachment_hash_mismatch")
        }
        var result = declared
        result.mimeType = attachment["mime_type"]?.stringValue ?? declared.mimeType
        result.byteCount = Int(attachment["byte_count"]?.intValue ?? Int64(declared.byteCount))
        // The owner's first record wins: an `exists` answer may deliberately
        // have no derived image even when this upload declared one.
        result.poster = attachment["poster"].flatMap(derivedImage)
        result.preview = attachment["preview"].flatMap(derivedImage)
        return result
    }

    private func derivedImage(_ value: JSONValue) -> AttachmentDerivedImage? {
        guard let hash = value["hash"]?.stringValue, let mime = value["mime_type"]?.stringValue,
              let bytes = value["byte_count"]?.intValue else { return nil }
        return AttachmentDerivedImage(hash: hash, mimeType: mime, byteCount: Int(bytes))
    }

    private func headers(_ value: JSONValue?) -> [String: String]? {
        guard case .object(let values)? = value else { return nil }
        return Dictionary(uniqueKeysWithValues: values.compactMap { key, value in value.stringValue.map { (key, $0) } })
    }

    private func attachmentCall<T>(_ body: () async throws -> T) async throws -> T {
        do { return try await body() }
        catch is CancellationError { throw CancellationError() }
        catch let error as CloudAPIError { throw mapAttachment(error) }
        catch { throw HomeRejection.indeterminate }
    }

    private func mapAttachment(_ error: CloudAPIError) -> HomeRejection {
        switch error {
        case .transport: return .indeterminate
        case .unauthenticated: return .notAuthorized
        case .refused(let code):
            if code == "auth.unauthenticated" || code == "auth.forbidden" { return .notAuthorized }
            if code == "owner.unreachable" || code == "rate_limited" { return .ownerUnreachable }
            return .invalid(code)
        }
    }

    private static func isPreconditionFailure(_ error: CloudAPIError) -> Bool {
        if case .refused(let code) = error { return code == "http.412" }
        return false
    }

    private static func extensionFor(_ mimeType: String) -> String {
        UTType(mimeType: mimeType)?.preferredFilenameExtension.map { ".\($0)" } ?? ""
    }

    private static func touch(_ url: URL) -> URL {
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
        return url
    }

    private func trimAttachmentCache(keeping kept: URL) {
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]
        guard let files = try? FileManager.default.contentsOfDirectory(at: attachmentCache,
                                                                         includingPropertiesForKeys: Array(keys),
                                                                         options: [.skipsHiddenFiles]) else { return }
        var entries = files.compactMap { url -> (url: URL, used: Date, size: Int)? in
            guard let values = try? url.resourceValues(forKeys: keys), values.isRegularFile == true else { return nil }
            return (url, values.contentModificationDate ?? .distantPast, values.fileSize ?? 0)
        }
        var total = entries.reduce(0) { $0 + $1.size }
        guard total > Self.attachmentCacheLimit else { return }
        entries.sort { $0.used < $1.used }
        let keptPath = kept.standardizedFileURL.path
        for entry in entries where total > Self.attachmentCacheLimit && entry.url.standardizedFileURL.path != keptPath {
            if (try? FileManager.default.removeItem(at: entry.url)) != nil { total -= entry.size }
        }
    }

    nonisolated func close(_ conversation: ConversationID) {
        Task { await closeConversation(conversation) }
    }

    private func closeConversation(_ conversation: ConversationID) {
        conversationTasks.removeValue(forKey: conversation)?.cancel()
        if let session = conversationClients.removeValue(forKey: conversation) { Task { await session.stop() } }
    }

    private func applyState(_ state: ControlPlaneState) {
        let next: HomeConnection
        switch state {
        case .connected: next = .online
        case .connecting: next = .connecting
        case .disconnected, .failed: next = .offline(since: Date())
        case .idle, .stopped: return
        }
        guard next != lastConnection else { return }
        publish(.connection(next)); lastConnection = next
    }

    private func applyInbox(_ update: StreamUpdate) {
        switch update {
        case .snapshot(let snapshot):
            let entries = snapshot.rows?.objectValue?["rows"]?.arrayValue?.compactMap { $0["row"] }.compactMap { try? inboxEntry($0) } ?? []
            let next = InboxSnapshot(me: me, conversations: entries.map(summary), rev: Revision(snapshot.seq))
            inboxCache = next; publish(.inbox(next))
        case .event(let event):
            guard let effects = event.effects?.objectValue,
                  let writes = effects["writes"]?.arrayValue else { return }
            var current: [ConversationID: ConversationSummary] = Dictionary(
                uniqueKeysWithValues: inboxCache.conversations.map { ($0.id, $0) })
            for write in writes {
                guard write["table"]?.stringValue == "entry", let key = write["key"]?.stringValue else { continue }
                if write["op"]?.stringValue == "delete" { current.removeValue(forKey: ConversationID(key)) }
                else if let row = write["row"], let entry = try? inboxEntry(row) { current[ConversationID(key)] = summary(entry) }
            }
            let next = InboxSnapshot(me: me, conversations: Array(current.values), rev: Revision(event.seq))
            inboxCache = next; publish(.inbox(next))
        }
    }

    private func ensureConversationSubscription(_ id: ConversationID) async {
        guard conversationClients[id] == nil, let makeConversation else { return }
        do {
            let client = try await makeConversation(id)
            conversationClients[id] = client; await client.start()
            let stream = await client.subscribe("conv:\(id.rawValue)")
            conversationTasks[id] = Task { [weak self] in
                for await update in stream { await self?.applyConversation(update, id: id) }
            }
        } catch { }
    }

    private func applyConversation(_ update: StreamUpdate, id: ConversationID) {
        switch update {
        case .snapshot(let snapshot):
            guard let page = try? decodePage(snapshot.state, rows: snapshot.rows) else { return }
            publish(.conversationPage(page))
        case .event(let event):
            // Conversation streams are row-mode streams. Their effects carry
            // the new head plus only the rows changed by this transaction.
            // Forward the head and changed message rows independently so the
            // Home mirror can update an open transcript without a snapshot
            // HTTP round-trip for every message.
            guard let effects = event.effects?.objectValue else { return }
            guard let state = effects["state"] ?? effects["head"],
                  let summary = try? conversationSummary(state) else { return }
            let messages = (effects["writes"]?.arrayValue ?? []).compactMap { write -> Message? in
                guard write["op"]?.stringValue != "delete",
                      let row = write["row"],
                      write["table"]?.stringValue == "message" else { return nil }
                return try? message(row)
            }
            // Keep the head and changed rows in one Home event: both carry the
            // same owner revision, so publishing them separately would cause
            // the mirror to treat the second event as stale.
            publish(.conversationPage(ConversationPage(conversation: summary, messages: messages)))
        }
    }

    private func removeContinuation(_ id: UUID) { continuations.removeValue(forKey: id) }
    private func publish(_ event: HomeEvent) { for continuation in continuations.values { continuation.yield(event) } }
}

private extension CloudHomeSource {
    struct InboxEntry: Sendable {
        let conversation: String; let rev: UInt64; let title: String; let lastSeq: UInt64; let lastAt: Date
        let unread: UInt64; let mentions: UInt64; let pinned: Bool; let pinPosition: Int?; let muted: Bool; let removed: Bool; let dmPeer: String?
    }
    struct MappedOp { let op: String; var params: [String: JSONValue] }

    /// Applies one authenticated Home mutation, translating transport and
    /// owner refusals into the Home source's error vocabulary. The
    /// authenticated session credential is required for every user action;
    /// install credentials are reserved for reads and stream setup.
    func commit(_ mapped: MappedOp, key: String) async throws -> (value: JSONValue, revision: UInt64) {
        let reply: CloudOpReply
        do {
            reply = try await api.mutate(mapped.op, params: mapped.params, key: key, as: .session)
        } catch CloudAPIError.transport {
            throw HomeRejection.indeterminate
        } catch CloudAPIError.unauthenticated {
            throw HomeRejection.notAuthorized
        }
        switch reply {
        case .committed(let value, let revision):
            return (value, revision)
        case .rejected(let code, let retryable):
            throw rejection(code: code, retryable: retryable)
        }
    }

    /// Starts an address DM and, when supplied, posts its first message. The
    /// two owner operations deliberately use separate idempotency keys: a
    /// retry replays `dm.open` under the intent key and then replays the
    /// message under the derived `:message` key, so a lost response cannot
    /// create a duplicate first message.
    func startConversation(contacts: [ContactAddress], firstMessage: [MessagePart], key: String) async throws -> HomeOpResult {
        guard contacts.count == 1, let contact = contacts.first else {
            throw HomeRejection.invalid("one contact at a time")
        }
        let opened = try await commit(
            MappedOp(op: "dm.open", params: ["peer": wireContact(contact)]), key: key)
        guard let conversationID = opened.value["conversation"]?["id"]?.stringValue
                ?? opened.value["conversation"]?.stringValue else {
            throw HomeRejection.indeterminate
        }
        let conversation = ConversationID(conversationID)
        if !firstMessage.isEmpty {
            let messageKey = "\(key):message"
            _ = try await commit(
                MappedOp(op: "message.send", params: [
                    "conversation": .string(conversation.rawValue),
                    "client_msg_id": .string(messageKey),
                    "parts": try wireParts(firstMessage),
                ]), key: messageKey)
        }
        let invite = inviteReceipt(for: contact, value: opened.value["invite"])
        // `startConversation` is an inbox-stream operation. The dm.open
        // revision is therefore the result cursor even when the follow-up
        // message advances the conversation stream independently.
        return HomeOpResult(rev: opened.revision, conversation: conversation, invite: invite)
    }

    func inviteReceipt(for contact: ContactAddress, value: JSONValue?) -> InviteReceipt? {
        guard let value else { return nil }
        if let decoded = decodeInvite(value) { return decoded }
        guard value["ok"]?.boolValue == true else { return nil }
        return InviteReceipt(contact: contact, channel: contact.isEmail ? .email : .sms, alreadyMember: false)
    }

    func decodeInboxEntries(_ value: JSONValue) throws -> [InboxEntry] {
        guard case .array(let values) = value else { throw CloudAPIError.transport }
        return try values.compactMap { try? inboxEntry($0) }
    }
    func inboxEntry(_ value: JSONValue) throws -> InboxEntry {
        guard let conversation = value["conversation"]?.stringValue else { throw CloudAPIError.transport }
        return InboxEntry(conversation: conversation, rev: UInt64(value["rev"]?.intValue ?? 0), title: value["title"]?.stringValue ?? "", lastSeq: UInt64(value["last_seq"]?.intValue ?? 0), lastAt: date(value["last_at"]) ?? .distantPast, unread: UInt64(value["unread"]?.intValue ?? 0), mentions: UInt64(value["mentions"]?.intValue ?? 0), pinned: value["pinned"]?.boolValue ?? false, pinPosition: value["pin_position"]?.intValue.map(Int.init), muted: value["muted"]?.boolValue ?? false, removed: value["removed"]?.boolValue ?? false, dmPeer: value["dm_peer"]?.stringValue)
    }
    func summary(_ entry: InboxEntry) -> ConversationSummary {
        var participants = [me]
        if let peer = entry.dmPeer { participants.append(Participant(id: ParticipantID(peer), kind: peer.hasPrefix("agent_") ? .agent : .human, displayName: "", agentClass: peer.hasPrefix("agent_") ? .chief : nil)) }
        return ConversationSummary(id: ConversationID(entry.conversation), owner: .cloud, title: entry.title, participants: participants, lastSeq: Seq(entry.lastSeq), rev: Revision(entry.rev), createdAt: entry.lastAt, updatedAt: entry.lastAt, readCursors: [me.id: Seq(entry.lastSeq - min(entry.lastSeq, entry.unread))], pinRank: entry.pinned ? (entry.pinPosition ?? 0) : nil, muted: entry.muted, mentionCount: Int(entry.mentions))
    }
    func map(_ op: HomeOp) throws -> MappedOp {
        switch op {
        case .sendMessage(let conversation, let parts): return MappedOp(op: "message.send", params: ["conversation": .string(conversation.rawValue), "client_msg_id": .string("pending"), "parts": try wireParts(parts)])
        case .setReadCursor(let conversation, let seq): return MappedOp(op: "read_cursor.set", params: ["conversation": .string(conversation.rawValue), "seq": .int(Int64(seq))])
        case .setPinned(let conversation, let rank):
            var params: [String: JSONValue] = ["conversation": .string(conversation.rawValue), "pinned": .bool(rank != nil)]
            if let rank { params["position"] = .int(Int64(rank)) }
            return MappedOp(op: "inbox.pin", params: params)
        case .setMuted(let conversation, let muted): return MappedOp(op: "inbox.mute", params: ["conversation": .string(conversation.rawValue), "muted": .bool(muted)])
        case .addReaction(let message, let conversation, let reaction, let partIndex): return MappedOp(op: "reaction.add", params: ["conversation": .string(conversation.rawValue), "message_id": .string(message.rawValue), "part_index": .int(Int64(partIndex)), "reaction": wireReaction(reaction)])
        case .createGroup(let title, let participants): return MappedOp(op: "conversation.create", params: ["title": .string(title), "kind": .string("group"), "participants": .array(participants.map { .object(["id": .string($0.rawValue), "kind": .string($0.rawValue.hasPrefix("agent_") ? "agent" : "human")]) })])
        case .openDirect(let peer): return MappedOp(op: "dm.open", params: ["peer": .string(peer.rawValue)])
        case .startConversation(let contacts, _):
            guard contacts.count == 1, let contact = contacts.first else { throw HomeRejection.invalid("one contact at a time") }
            return MappedOp(op: "dm.open", params: ["peer": wireContact(contact)])
        case .createChief(let name): return MappedOp(op: "chief.create", params: ["display_name": .string(name)])
        // Home's top-level Invite action opens the deterministic DM for the
        // address.  The Worker performs the corresponding `invite.create`
        // as part of `dm.open` and returns its status in `value.invite`.
        case .invite(let contact): return MappedOp(op: "dm.open", params: ["peer": wireContact(contact)])
        case .answerQuestion(let message, let conversation, let partIndex, let answer):
            return MappedOp(op: "question.answer", params: [
                "conversation": .string(conversation.rawValue),
                "message_id": .string(message.rawValue),
                "part_index": .int(Int64(partIndex)),
                "answer": wireAnswer(answer),
            ])
        case .setTyping: fatalError("handled above")
        }
    }
    func wireContact(_ contact: ContactAddress) -> JSONValue { switch contact { case .email(let value): .object(["email": .string(value)]); case .phone(let value): .object(["phone": .string(value)]) } }
    func wireReaction(_ reaction: Reaction.Kind) -> JSONValue { switch reaction { case .tapback(let value): .object(["tapback": .string(value.rawValue)]); case .emoji(let value): .object(["emoji": .string(value)]) } }
    /// The conversation owner only accepts the selections portion of an
    /// answer.  It stamps the respondent and timestamp itself, so those fields
    /// are intentionally never sent by the mobile client.
    func wireAnswer(_ answer: AgentQuestionAnswer) -> JSONValue {
        let selections = answer.selections.reduce(into: [String: JSONValue]()) { result, item in
            var selection: [String: JSONValue] = ["option_ids": .array(item.value.optionIDs.map(JSONValue.string))]
            if let other = item.value.other { selection["other"] = .string(other) }
            result[item.key] = .object(selection)
        }
        return .object(["selections": .object(selections)])
    }
    func wireParts(_ parts: [MessagePart]) throws -> JSONValue {
        .array(try parts.map { part in
            switch part {
            case .text(let text, let mentions):
                var runs = mentions.map { JSONValue.object(["start": .int(Int64($0.start)), "length": .int(Int64($0.length)), "mention": .string($0.participant.rawValue)]) }
                var object: [String: JSONValue] = ["type": .string("text"), "text": .string(text)]
                if !runs.isEmpty { object["runs"] = .array(runs) }; return .object(object)
            case .work(let work): return .object(["type": .string("work"), "session": .string(work.session), "status": .string(work.status.rawValue), "preview": work.preview.map(JSONValue.string) ?? .null] as [String: JSONValue])
            case .attachment(let file): return .object(["type": .string("attachment"), "hash": .string(file.hash), "name": .string(file.name), "mime_type": .string(file.mimeType), "byte_count": .int(Int64(file.byteCount))])
            default: throw HomeRejection.invalid("unsupported message part")
            }
        })
    }
    func decodePage(_ value: JSONValue, rows: JSONValue? = nil) throws -> ConversationPage {
        let state = value["state"] ?? value
        let messageValues = rows?.objectValue?["rows"]?.arrayValue?.compactMap { $0["row"] } ?? value["messages"]?.arrayValue ?? []
        let summary = try conversationSummary(state)
        return ConversationPage(conversation: summary, messages: try messageValues.compactMap { try message($0) })
    }
    func conversationSummary(_ value: JSONValue) throws -> ConversationSummary {
        guard let id = value["id"]?.stringValue else { throw CloudAPIError.transport }
        let participants = (value["participants"]?.arrayValue ?? []).compactMap { participant($0) }
        let cursors = Dictionary(uniqueKeysWithValues: (value["read_cursors"]?.objectValue ?? [:]).compactMap { key, value in value.intValue.map { (ParticipantID(key), Seq($0)) } })
        return ConversationSummary(id: ConversationID(id), owner: .cloud, title: value["title"]?.stringValue ?? "", participants: participants, lastSeq: Seq(value["last_seq"]?.intValue ?? 0), rev: Revision(value["rev"]?.intValue ?? 0), createdAt: date(value["created_at"]) ?? .distantPast, updatedAt: date(value["updated_at"]) ?? .distantPast, readCursors: cursors)
    }
    func participant(_ value: JSONValue) -> Participant? {
        guard let id = value["id"]?.stringValue else { return nil }
        let kind: Participant.Kind = value["kind"]?.stringValue == "agent" ? .agent : .human
        let agentClass: Participant.AgentClass? = value["agent_class"]?.stringValue.map { $0 == "mux" ? .chief : .agent }
        let membership: Participant.Membership = value["kind"]?.stringValue == "address" ? .invited : .active
        return Participant(id: ParticipantID(id), kind: kind, displayName: value["display_name"]?.stringValue ?? "", agentClass: agentClass, ownerUser: value["owner_user"]?.stringValue.map { ParticipantID($0) }, membership: membership, invitedContact: membership == .invited ? value["display_name"]?.stringValue : nil)
    }
    func message(_ value: JSONValue) throws -> Message? {
        guard let id = value["id"]?.stringValue, let conversation = value["conversation"]?.stringValue, let author = value["author"]?.stringValue else { return nil }
        let parts = (value["parts"]?.arrayValue ?? []).compactMap { part($0) }
        let reactions = (value["reactions"]?.arrayValue ?? []).compactMap { reaction($0) }
        return Message(id: MessageID(id), conversation: ConversationID(conversation), seq: Seq(value["seq"]?.intValue ?? 0), clientMessageID: IdempotencyKey(rawValue: value["client_msg_id"]?.stringValue ?? id), author: ParticipantID(author), parts: parts, createdAt: date(value["created_at"]) ?? .distantPast, editedAt: date(value["edited_at"]), retractedAt: date(value["retracted_at"]), reactions: reactions, replyTo: value["reply_to"].flatMap { $0["message_id"]?.stringValue }.map { PartRef(message: MessageID($0), partIndex: Int(value["reply_to"]?["part_index"]?.intValue ?? 0)) })
    }
    func part(_ value: JSONValue) -> MessagePart? {
        guard let type = value["type"]?.stringValue else { return nil }
        switch type {
        case "text": return .text(value["text"]?.stringValue ?? "", mentions: (value["runs"]?.arrayValue ?? []).compactMap { run in guard let start = run["start"]?.intValue, let length = run["length"]?.intValue, let mention = run["mention"]?.stringValue else { return nil }; return Mention(start: Int(start), length: Int(length), participant: ParticipantID(mention)) })
        case "work": return .work(WorkRef(session: value["session"]?.stringValue ?? "", host: value["host"]?.stringValue, title: value["session"]?.stringValue ?? "", status: WorkRef.Status(rawValue: value["status"]?.stringValue ?? "done") ?? .done, preview: value["preview"]?.stringValue))
        case "attachment":
            guard let hash = value["hash"]?.stringValue else { return nil }
            return .attachment(AttachmentRef(hash: hash,
                                              name: value["name"]?.stringValue ?? "",
                                              mimeType: value["mime_type"]?.stringValue ?? "application/octet-stream",
                                              byteCount: Int(value["byte_count"]?.intValue ?? 0),
                                              width: value["width"]?.intValue.map(Int.init),
                                              height: value["height"]?.intValue.map(Int.init),
                                              durationMs: value["duration_ms"]?.intValue.map(Int.init),
                                              poster: value["poster"].flatMap(derivedImage),
                                              preview: value["preview"].flatMap(derivedImage)))
        default: return nil
        }
    }
    func reaction(_ value: JSONValue) -> Reaction? { guard let author = value["author"]?.stringValue, let part = value["part_index"]?.intValue, let kind = value["kind"] else { return nil }; if let tap = kind["tapback"]?.stringValue, let t = Reaction.Tapback(rawValue: tap) { return Reaction(author: ParticipantID(author), partIndex: Int(part), kind: .tapback(t)) }; if let emoji = kind["emoji"]?.stringValue { return Reaction(author: ParticipantID(author), partIndex: Int(part), kind: .emoji(emoji)) }; return nil }
    func decodeInvite(_ value: JSONValue) -> InviteReceipt? { guard let contact = value["contact"]?.stringValue, let parsed = ContactAddress.parse(contact) else { return nil }; return InviteReceipt(contact: parsed, channel: value["channel"]?.stringValue == "sms" ? .sms : .email, alreadyMember: value["already_member"]?.boolValue ?? false) }
    func date(_ value: JSONValue?) -> Date? { guard let string = value?.stringValue else { return nil }; return ISO8601DateFormatter().date(from: string) }
    func rejection(code: String, retryable: Bool) -> HomeRejection { if code == "auth.forbidden" || code == "not_authorized" { return .notAuthorized }; if retryable { return .ownerUnreachable }; return .invalid(code) }
}

private extension JSONValue {
    var intValue: Int64? { if case .int(let value) = self { return value }; if case .double(let value) = self { return Int64(value) }; return nil }
    var boolValue: Bool? { if case .bool(let value) = self { return value }; return nil }
    var arrayValue: [JSONValue]? { if case .array(let value) = self { return value }; return nil }
}

