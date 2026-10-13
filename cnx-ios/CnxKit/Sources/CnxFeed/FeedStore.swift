import CmuxAgentQuestion
import CnxAgentChat
import CnxModel
import Foundation
import Observation

/// One Feed event: something an agent did or needs, from any workspace and tab.
public struct FeedItem: Identifiable, Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        /// A normal agent reply; Reply sends a new prompt into that tab.
        case response
        case question(AgentQuestion)
        case permission(ACPPermissionRequest)
        case finished
        case failed
    }

    /// The message this event answers, shown as an iMessage-style quote bubble.
    public struct Quote: Hashable, Sendable {
        public enum Author: Hashable, Sendable { case you, agent }
        public var text: String
        public var author: Author

        public init(_ text: String, author: Author = .you) {
            self.text = text
            self.author = author
        }
    }

    public var id: String
    public var kind: Kind
    public var workspaceID: String
    public var tabID: String
    public var agentName: String
    public var harness: String
    public var workspaceTitle: String
    public var markdown: String
    public var quote: Quote?
    public var createdAt: Date
    public var isRead = false
    /// Set once answered inline (question, permission) or replied to.
    public var resolution: String?
    public var replies: [String] = []

    public init(
        id: String, kind: Kind, workspaceID: String, tabID: String, agentName: String, harness: String,
        workspaceTitle: String, markdown: String, quote: Quote?, createdAt: Date
    ) {
        self.id = id
        self.kind = kind
        self.workspaceID = workspaceID
        self.tabID = tabID
        self.agentName = agentName
        self.harness = harness
        self.workspaceTitle = workspaceTitle
        self.markdown = markdown
        self.quote = quote
        self.createdAt = createdAt
    }

    public var needsYou: Bool {
        guard resolution == nil else { return false }
        switch kind {
        case .question(let question): return question.isPending
        case .permission: return true
        default: return false
        }
    }
}

public enum FeedFilter: String, CaseIterable, Hashable, Sendable {
    case all = "All", needsYou = "Needs you", finished = "Finished", errors = "Errors"

    func matches(_ item: FeedItem) -> Bool {
        switch self {
        case .all: true
        case .needsYou: item.needsYou
        case .finished: item.kind == .finished || item.kind == .response
        case .errors: item.kind == .failed
        }
    }
}

/// The Feed's state: newest first. Mock now; acpmux `_acpmux/watch` + `session_changed` later.
@MainActor
@Observable
public final class FeedStore {
    public static let shared = FeedStore(items: FeedStore.mockItems(now: Date()))

    public private(set) var items: [FeedItem]
    public var filter: FeedFilter = .all
    public var mutedWorkspaces: Set<String> = []
    /// Events that arrived while the person was scrolled away from the top.
    public private(set) var unseenNewIDs: [String] = []
    private var liveIndex = 0

    public init(items: [FeedItem]) {
        self.items = items.sorted { $0.createdAt > $1.createdAt }
    }

    public var visibleItems: [FeedItem] {
        items.filter { filter.matches($0) && !mutedWorkspaces.contains($0.workspaceID) }
    }

    public var needsYouCount: Int { items.count(where: \.needsYou) }

    public func count(_ filter: FeedFilter) -> Int { items.count(where: filter.matches) }

    public func insert(_ item: FeedItem, atTop: Bool) {
        items.insert(item, at: 0)
        if !atTop { unseenNewIDs.append(item.id) }
    }

    public func clearUnseen() { unseenNewIDs = [] }

    public func markRead(_ id: String) { mutate(id) { $0.isRead = true } }

    public func answer(_ id: String, answer: AgentQuestionAnswer) {
        mutate(id) { item in
            guard case .question(var question) = item.kind else { return }
            question.state = .answered(answer)
            item.kind = .question(question)
            item.resolution = question.summaryLines(answer).joined(separator: "\n")
            item.isRead = true
        }
    }

    public func respond(_ id: String, option: ACPPermissionOption) {
        mutate(id) {
            $0.resolution = option.isAllow ? "Allowed: \(option.name)" : "Denied"
            $0.isRead = true
        }
    }

    public func reply(_ id: String, text: String) {
        mutate(id) {
            $0.replies.append(text)
            $0.isRead = true
        }
    }

    private func mutate(_ id: String, _ body: (inout FeedItem) -> Void) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        body(&items[index])
    }

    /// Adds the next scripted live event (mock arrivals; demo driver uses it).
    public func injectLiveEvent(atTop: Bool) {
        let samples = FeedStore.liveSamples(now: Date())
        let item = samples[liveIndex % samples.count]
        liveIndex += 1
        var copy = item
        copy.id = "\(item.id)-\(liveIndex)"
        insert(copy, atTop: atTop)
    }
}
