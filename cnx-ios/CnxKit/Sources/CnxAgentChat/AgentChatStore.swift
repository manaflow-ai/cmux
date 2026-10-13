import CmuxAgentQuestion
import CnxDiff
import CnxMarkdown
import Foundation
import Observation

/// One prompt and everything the agent did for it.
public struct AgentTurn: Identifiable, Hashable, Sendable {
    public enum Status: String, Hashable, Sendable { case running, completed, cancelled, failed }

    public var id: String
    public var prompt: String
    public var attachments: [AgentAttachment]
    public var promptAt: Date
    public var items: [TurnItem] = []
    public var status: Status = .running
    public var startedAt: Date?
    public var endedAt: Date?
    public var errorText: String?

    public init(id: String, prompt: String, attachments: [AgentAttachment] = [], promptAt: Date) {
        self.id = id
        self.prompt = prompt
        self.attachments = attachments
        self.promptAt = promptAt
    }

    public var duration: TimeInterval? {
        guard let startedAt else { return nil }
        return (endedAt ?? Date()).timeIntervalSince(startedAt)
    }

    /// The edits in this turn, newest content per path (the edited-files card and Changes).
    public var changeSet: DiffChangeSet? {
        var order: [String] = []
        var byPath: [String: (old: String?, new: String)] = [:]
        for case .tool(let call) in items {
            for diff in call.diffs {
                if let existing = byPath[diff.path] {
                    byPath[diff.path] = (existing.old, diff.newText)
                } else {
                    order.append(diff.path)
                    byPath[diff.path] = (diff.oldText, diff.newText)
                }
            }
        }
        guard !order.isEmpty else { return nil }
        let files = order.map { DiffFile(path: $0, oldText: byPath[$0]?.old, newText: byPath[$0]?.new) }
        return DiffChangeSet(id: "turn-\(id)", title: "Changes", subtitle: "This turn", files: files)
    }

    public func question(_ id: String) -> AgentQuestion? {
        for case .question(let question) in items where question.id == id { return question }
        return nil
    }

    /// The final answer text (copy, share).
    public var answerMarkdown: String {
        items.compactMap {
            if case .message(_, let text) = $0 { return text }
            return nil
        }.joined(separator: "\n\n")
    }
}

public enum TurnItem: Hashable, Sendable, Identifiable {
    case message(id: String, markdown: String)
    case thought(id: String, text: String)
    case tool(ACPToolCall)
    case plan(id: String, entries: [ACPPlanEntry])
    case permission(PermissionRecord)
    case question(AgentQuestion)

    public var id: String {
        switch self {
        case .message(let id, _): "m-\(id)"
        case .thought(let id, _): "t-\(id)"
        case .tool(let call): "c-\(call.id)"
        case .plan(let id, _): "p-\(id)"
        case .permission(let record): "r-\(record.request.id)"
        case .question(let question): "q-\(question.id)"
        }
    }
}

public struct PermissionRecord: Hashable, Sendable {
    public var request: ACPPermissionRequest
    /// The chosen option once resolved (nil option = cancelled).
    public var resolution: Resolution?

    public enum Resolution: Hashable, Sendable {
        case chose(ACPPermissionOption)
        case cancelled
    }

    public init(request: ACPPermissionRequest, resolution: Resolution? = nil) {
        self.request = request
        self.resolution = resolution
    }
}

public struct QueuedPrompt: Hashable, Sendable, Identifiable {
    public var id: String
    public var text: String
}

/// The chat's state, built from the source's event stream. Views read it; intents go back to the source.
@MainActor
@Observable
public final class AgentChatStore {
    public let source: any AgentSessionSource
    public private(set) var summary: AgentSessionSummary
    public private(set) var turns: [AgentTurn] = []
    public private(set) var queue: [QueuedPrompt] = []
    public private(set) var availableCommands: [ACPAvailableCommand] = []
    public private(set) var configOptions: [ACPConfigOption] = []
    public private(set) var models: [ACPModelInfo] = []
    public private(set) var currentModelID: String?
    public private(set) var modes: [ACPMode] = []
    public private(set) var currentModeID: String?
    public private(set) var usage: (used: Int, size: Int)?
    /// Bumps on every streamed change (follow-mode scroll keys off it).
    public private(set) var revision = 0
    private var currentMessageID: String?
    private var task: Task<Void, Never>?

    public init(source: any AgentSessionSource) {
        self.source = source
        self.summary = source.summary
        let stream = source.events()
        task = Task { [weak self] in
            for await event in stream {
                guard let self else { return }
                self.apply(event)
            }
        }
    }

    isolated deinit {
        task?.cancel()
    }

    public var isRunning: Bool { turns.last?.status == .running }

    public var pendingPermission: PermissionRecord? {
        guard let turn = turns.last else { return nil }
        for case .permission(let record) in turn.items.reversed() where record.resolution == nil {
            return record
        }
        return nil
    }

    public var pendingQuestion: AgentQuestion? {
        guard let turn = turns.last else { return nil }
        for case .question(let question) in turn.items.reversed() where question.isPending {
            return question
        }
        return nil
    }

    public var currentModelName: String? {
        models.first { $0.id == currentModelID }?.name
    }

    public var effortOption: ACPConfigOption? { configOptions.first(where: \.isEffort) }

    // MARK: Intents

    public func send(prompt: String, attachments: [AgentAttachment] = [], steer: Bool = false) {
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !attachments.isEmpty else { return }
        source.send(.prompt(text: text, attachments: attachments, steer: steer))
    }

    public func cancel() { source.send(.cancel) }

    public func respond(to request: ACPPermissionRequest, option: ACPPermissionOption?) {
        source.send(.respondPermission(permissionId: request.id, optionId: option?.id))
    }

    public func answer(_ question: AgentQuestion, with answer: AgentQuestionAnswer) {
        source.send(.answerQuestion(questionId: question.id, answer: answer))
    }

    public func setModel(_ id: String) { source.send(.setModel(id)) }
    public func setMode(_ id: String) { source.send(.setMode(id)) }
    public func setConfig(_ id: String, value: String) { source.send(.setConfigOption(id: id, value: value)) }
    public func removeQueued(_ id: String) { source.send(.removeQueued(promptId: id)) }

    // MARK: Reducer

    func apply(_ event: AgentSessionEvent) {
        revision &+= 1
        switch event {
        case .userMessage(let text, _, let turnId, let attachments, let at):
            currentMessageID = nil
            if !turns.contains(where: { $0.id == turnId }) {
                turns.append(AgentTurn(id: turnId, prompt: text, attachments: attachments, promptAt: at))
            }
        case .queued(let text, let promptId, _):
            queue.append(QueuedPrompt(id: promptId, text: text))
        case .dequeued(let promptId):
            queue.removeAll { $0.id == promptId }
        case .turnStarted(let turnId, let at):
            mutateTurn(turnId) {
                $0.startedAt = at
                $0.status = .running
            }
            summary.status = .running
        case .turnResult(let turnId, let status, let errorText, let at):
            mutateTurn(turnId) { turn in
                turn.status = status
                turn.endedAt = at
                turn.errorText = errorText
                for index in turn.items.indices {
                    if case .tool(var call) = turn.items[index], call.isRunning {
                        call.status = status == .completed ? .completed : .failed
                        turn.items[index] = .tool(call)
                    }
                }
            }
            currentMessageID = nil
            summary.status = .idle
        case .update(let update):
            applyUpdate(update)
        case .permissionRequest(let request):
            appendItem(.permission(PermissionRecord(request: request)))
            summary.status = .waiting
        case .question(let question):
            appendItem(.question(question))
            summary.status = .waiting
        case .permissionDecision(let permissionId, let optionId):
            updateItems { item in
                guard case .permission(var record) = item, record.request.id == permissionId else { return nil }
                if let optionId, let option = record.request.options.first(where: { $0.id == optionId }) {
                    record.resolution = .chose(option)
                } else {
                    record.resolution = .cancelled
                }
                return .permission(record)
            }
            summary.status = isRunning ? .running : .idle
        case .questionAnswered(let questionId, let answer):
            updateItems { item in
                guard case .question(var question) = item, question.id == questionId else { return nil }
                question.state = .answered(answer)
                return .question(question)
            }
            summary.status = isRunning ? .running : .idle
        case .modelsAvailable(let models, let current):
            self.models = models
            currentModelID = current
        case .modesAvailable(let modes, let current):
            self.modes = modes
            currentModeID = current
        case .status(let status):
            summary.status = status
        }
    }

    private func applyUpdate(_ update: ACPSessionUpdate) {
        switch update {
        case .agentMessageChunk(let text, let messageId):
            guard var turn = turns.last else { return }
            if case .message(let id, let existing)? = turn.items.last, messageId == nil || messageId == currentMessageID || currentMessageID == nil {
                turn.items[turn.items.count - 1] = .message(id: id, markdown: existing + text)
            } else {
                turn.items.append(.message(id: messageId ?? UUID().uuidString, markdown: text))
            }
            currentMessageID = messageId
            turns[turns.count - 1] = turn
        case .agentThoughtChunk(let text):
            guard var turn = turns.last else { return }
            if case .thought(let id, let existing)? = turn.items.last {
                turn.items[turn.items.count - 1] = .thought(id: id, text: existing + text)
            } else {
                turn.items.append(.thought(id: UUID().uuidString, text: text))
            }
            turns[turns.count - 1] = turn
        case .toolCall(var call):
            call.startedAt = call.startedAt ?? Date()
            if call.status == .completed || call.status == .failed { call.endedAt = Date() }
            if !replaceTool(call.id, with: { _ in call }) {
                appendItem(.tool(call))
            }
        case .toolCallUpdate(let update):
            _ = replaceTool(update.toolCallId) { existing in
                var call = existing
                call.apply(update)
                if !call.isRunning, call.endedAt == nil { call.endedAt = Date() }
                return call
            }
        case .plan(let entries):
            guard var turn = turns.last else { return }
            if let index = turn.items.firstIndex(where: { if case .plan = $0 { return true }; return false }) {
                if entries.isEmpty {
                    turn.items.remove(at: index)
                } else if case .plan(let id, _) = turn.items[index] {
                    turn.items[index] = .plan(id: id, entries: entries)
                }
            } else if !entries.isEmpty {
                turn.items.append(.plan(id: UUID().uuidString, entries: entries))
            }
            turns[turns.count - 1] = turn
        case .availableCommands(let commands):
            availableCommands = commands
        case .currentMode(let mode):
            currentModeID = mode
        case .configOptions(let options):
            configOptions = options
        case .usage(let used, let size):
            usage = (used, size)
        }
    }

    private func appendItem(_ item: TurnItem) {
        guard !turns.isEmpty else { return }
        turns[turns.count - 1].items.append(item)
    }

    private func mutateTurn(_ id: String, _ body: (inout AgentTurn) -> Void) {
        guard let index = turns.lastIndex(where: { $0.id == id }) else { return }
        body(&turns[index])
    }

    @discardableResult
    private func replaceTool(_ id: String, with transform: (ACPToolCall) -> ACPToolCall) -> Bool {
        for turnIndex in turns.indices.reversed() {
            for itemIndex in turns[turnIndex].items.indices.reversed() {
                if case .tool(let call) = turns[turnIndex].items[itemIndex], call.id == id {
                    turns[turnIndex].items[itemIndex] = .tool(transform(call))
                    return true
                }
            }
        }
        return false
    }

    private func updateItems(_ transform: (TurnItem) -> TurnItem?) {
        for turnIndex in turns.indices.reversed() {
            for itemIndex in turns[turnIndex].items.indices {
                if let replaced = transform(turns[turnIndex].items[itemIndex]) {
                    turns[turnIndex].items[itemIndex] = replaced
                    return
                }
            }
        }
    }
}
