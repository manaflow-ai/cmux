import CmuxAgentQuestion
import CnxAgentChat
import CnxFeed
import Foundation
import OSLog

private let log = Logger(subsystem: "dev.cmux.cnx", category: "feed")

/// Turns acpmux watch events into Feed items and sends inline answers back
/// through the hub.
@MainActor
public final class LiveFeed: FeedActions {
    /// Where a session lives in the app (workspace and tab), when a tab is bound to it.
    public struct Place: Sendable {
        public var workspaceID: String
        public var tabID: String
        public var workspaceTitle: String

        public init(workspaceID: String, tabID: String, workspaceTitle: String) {
            self.workspaceID = workspaceID
            self.tabID = tabID
            self.workspaceTitle = workspaceTitle
        }
    }

    let store: FeedStore
    weak var hub: AcpmuxHub?
    var place: @MainActor (String) -> Place?
    let now: @MainActor () -> Date
    /// Open asks per session (resolved when the session reports none pending).
    private(set) var openAsks: [String: Set<String>] = [:]
    /// Every ask's session, by Feed item id.
    private var askSessions: [String: String] = [:]

    public init(store: FeedStore, hub: AcpmuxHub?, now: @escaping @MainActor () -> Date = Date.init,
                place: @escaping @MainActor (String) -> Place?) {
        self.store = store
        self.hub = hub
        self.place = place
        self.now = now
    }

    public func handle(_ event: AcpmuxHub.WatchEvent, sessions: [String: AcpmuxSession]) {
        switch event {
        case .permissionPending(let sessionID, let permissionID, let request):
            guard let mapped = AcpmuxRecords(sessionID: sessionID).permission(permissionID, request: request) else { return }
            let session = sessions[sessionID]
            let kind: FeedItem.Kind
            let markdown: String
            switch mapped {
            case .question(let question):
                kind = .question(question)
                markdown = question.summary
            case .permissionRequest(let permission):
                kind = .permission(permission)
                markdown = permission.toolCall.title.isEmpty ? "Permission requested" : "**Permission:** \(permission.toolCall.title)"
            default:
                return
            }
            let id = "ask-\(permissionID)"
            guard store.item(id: id) == nil else { return }
            log.info("feed ask \(id, privacy: .public)")
            openAsks[sessionID, default: []].insert(id)
            askSessions[id] = sessionID
            store.upsert(item(id: id, kind: kind, sessionID: sessionID, session: session, markdown: markdown,
                              quote: session?.lastPrompt.map { FeedItem.Quote($0) }), atTop: true)
        case .sessionChanged(let session, let recordKind, let seq):
            if session.pendingPermissions == 0, let asks = openAsks.removeValue(forKey: session.id) {
                for id in asks { store.resolveElsewhere(id, text: "Answered") }
            }
            guard recordKind == "turn_result" else { return }
            let failed = session.lastTurnStatus == "failed"
            let markdown = session.preview.flatMap { $0.isEmpty ? nil : $0 } ?? (failed ? "The turn failed." : "Finished.")
            store.upsert(item(id: "turn-\(session.id)-\(seq)", kind: failed ? .failed : .response, sessionID: session.id, session: session,
                              markdown: markdown, quote: session.lastPrompt.map { FeedItem.Quote($0) }), atTop: true)
        case .permissionResolved:
            break
        }
    }

    func item(id: String, kind: FeedItem.Kind, sessionID: String, session: AcpmuxSession?, markdown: String, quote: FeedItem.Quote?) -> FeedItem {
        let place = place(sessionID)
        let harness = session?.harness ?? "agent"
        return FeedItem(
            id: id, kind: kind, workspaceID: place?.workspaceID ?? "", tabID: place?.tabID ?? sessionID,
            agentName: session?.name.isEmpty == false ? session!.name : DaemonTree.agentName(harness), harness: harness,
            workspaceTitle: place?.workspaceTitle ?? (session?.cwd).map { ($0 as NSString).lastPathComponent } ?? "",
            markdown: markdown, quote: quote, createdAt: now()
        )
    }

    // MARK: FeedActions

    public func answer(_ item: FeedItem, question: AgentQuestion, with answer: AgentQuestionAnswer) async throws {
        guard let hub else { throw AcpmuxConnection.RPCError(code: 0, message: "Not connected", reason: nil) }
        try await hub.answer(question, with: answer)
    }

    public func respond(_ item: FeedItem, request: ACPPermissionRequest, option: ACPPermissionOption) async throws {
        guard let hub else { throw AcpmuxConnection.RPCError(code: 0, message: "Not connected", reason: nil) }
        try await hub.respond(sessionID: askSessions[item.id] ?? item.tabID, permissionID: request.id, optionID: option.id)
    }

    public func message(for error: any Error) -> String {
        AcpmuxSessionSource.message(error)
    }
}
