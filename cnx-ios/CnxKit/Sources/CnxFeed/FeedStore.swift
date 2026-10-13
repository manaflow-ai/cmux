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
    /// The Mac refused the inline answer (shown under the card; the ask stays open).
    public var error: String?
    /// Bumps with each inline answer, so a late refusal never reverts a newer answer.
    public var attempt = 0

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

/// Where inline answers go (the live acpmux hub). Without one, answers stay local (mock).
@MainActor
public protocol FeedActions: AnyObject {
    func answer(_ item: FeedItem, question: AgentQuestion, with answer: AgentQuestionAnswer) async throws
    func respond(_ item: FeedItem, request: ACPPermissionRequest, option: ACPPermissionOption) async throws
    /// Display copy for a refused answer.
    func message(for error: any Error) -> String
}

/// The Feed's state: newest first. Mock items until `CnxLive` replaces them
/// with events from acpmux `_acpmux/watch`.
@MainActor
@Observable
public final class FeedStore {
    @ObservationIgnored public weak var actions: (any FeedActions)?
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

    /// Replaces every item (live mode starts empty).
    public func replaceAll(_ next: [FeedItem]) {
        items = next.sorted { $0.createdAt > $1.createdAt }
        unseenNewIDs = []
    }

    /// Inserts or replaces an item by id (live events are idempotent).
    public func upsert(_ item: FeedItem, atTop: Bool) {
        if let index = items.firstIndex(where: { $0.id == item.id }) {
            var next = item
            next.isRead = items[index].isRead
            next.resolution = items[index].resolution ?? item.resolution
            next.replies = items[index].replies
            items[index] = next
        } else {
            insert(item, atTop: atTop)
        }
    }

    public func item(id: String) -> FeedItem? { items.first { $0.id == id } }

    /// Marks an open ask resolved elsewhere (another device or the Mac).
    public func resolveElsewhere(_ id: String, text: String) {
        mutate(id) { item in
            guard item.resolution == nil else { return }
            if case .question(var question) = item.kind, question.isPending {
                question.state = .answered(AgentQuestionAnswer(selections: [:]))
                item.kind = .question(question)
            }
            item.resolution = text
        }
    }

    public func answer(_ id: String, answer: AgentQuestionAnswer) {
        if let actions, let item = item(id: id), case .question(let question) = item.kind {
            let attempt = item.attempt + 1
            mutate(id) { $0.error = nil; $0.attempt = attempt }
            applyAnswer(id, answer: answer)
            Task {
                do {
                    try await actions.answer(item, question: question, with: answer)
                } catch {
                    mutate(id) {
                        guard $0.attempt == attempt else { return }
                        $0.kind = .question(question)
                        $0.resolution = nil
                        $0.error = actions.message(for: error)
                    }
                }
            }
            return
        }
        applyAnswer(id, answer: answer)
    }

    private func applyAnswer(_ id: String, answer: AgentQuestionAnswer) {
        mutate(id) { item in
            guard case .question(var question) = item.kind else { return }
            question.state = .answered(answer)
            item.kind = .question(question)
            item.resolution = question.summaryLines(answer).joined(separator: "\n")
            item.isRead = true
        }
    }

    public func respond(_ id: String, option: ACPPermissionOption) {
        if let actions, let item = item(id: id), case .permission(let request) = item.kind {
            let attempt = item.attempt + 1
            mutate(id) { $0.error = nil; $0.attempt = attempt }
            applyRespond(id, option: option)
            Task {
                do {
                    try await actions.respond(item, request: request, option: option)
                } catch {
                    mutate(id) {
                        guard $0.attempt == attempt else { return }
                        $0.resolution = nil
                        $0.error = actions.message(for: error)
                    }
                }
            }
            return
        }
        applyRespond(id, option: option)
    }

    private func applyRespond(_ id: String, option: ACPPermissionOption) {
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
