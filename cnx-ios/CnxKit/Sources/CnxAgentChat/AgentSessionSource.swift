import CmuxAgentQuestion
import CnxArtifacts
import Foundation

/// What a session looks like in lists and the toolbar (acpmux `SessionSummary` subset).
public struct AgentSessionSummary: Hashable, Sendable, Identifiable {
    public enum Status: String, Hashable, Sendable { case idle, ready, running, waiting, disconnected, closed }

    public var id: String
    public var name: String
    public var harness: String
    public var agentName: String
    public var cwd: String
    public var workspaceTitle: String
    public var macName: String
    public var branch: String?
    public var status: Status

    public init(
        id: String, name: String, harness: String, agentName: String, cwd: String, workspaceTitle: String,
        macName: String, branch: String? = nil, status: Status = .idle
    ) {
        self.id = id
        self.name = name
        self.harness = harness
        self.agentName = agentName
        self.cwd = cwd
        self.workspaceTitle = workspaceTitle
        self.macName = macName
        self.branch = branch
        self.status = status
    }
}

/// One record from the session's event stream: an agent `session/update`, or an acpmux mux record.
public enum AgentSessionEvent: Hashable, Sendable {
    case update(ACPSessionUpdate)
    /// `user_message` (or the replayed prompt of a historical turn).
    case userMessage(text: String, promptId: String, turnId: String, attachments: [AgentAttachment], at: Date)
    case queued(text: String, promptId: String, position: Int)
    case dequeued(promptId: String)
    case turnStarted(turnId: String, at: Date)
    case turnResult(turnId: String, status: AgentTurn.Status, errorText: String?, at: Date)
    /// `permission_request` / `_acpmux/permission_pending` that is a tool permission.
    case permissionRequest(ACPPermissionRequest)
    /// A permission request that maps to a question (AskUserQuestion, Codex user input).
    case question(AgentQuestion)
    /// `permission_decision`: the prompt was resolved (here or by another client).
    case permissionDecision(permissionId: String, optionId: String?)
    case questionAnswered(questionId: String, answer: AgentQuestionAnswer)
    case modelsAvailable([ACPModelInfo], current: String?)
    case modesAvailable([ACPMode], current: String?)
    case status(AgentSessionSummary.Status)
    /// A call the source made for the person failed (refused allow, trust gate, link down).
    case clientError(String)
    /// `_meta.acpmux.subagents`: a subagent started or changed state.
    case subagent(AgentSubagentChange)
    /// An update from a subagent's own session (`_meta.acpmux.subagent`).
    case subagentUpdate(subagentID: String, ACPSessionUpdate)
}

/// A person's action in the chat, encoded by the source into acpmux calls:
/// `session/prompt`, `session/cancel`, `_acpmux/permission_respond`, `session/set_model`,
/// `session/set_mode`, `session/set_config_option`, `_acpmux/queue_remove`.
public enum AgentClientIntent: Hashable, Sendable {
    case prompt(text: String, attachments: [AgentAttachment], steer: Bool)
    case cancel
    case respondPermission(permissionId: String, optionId: String?)
    case answerQuestion(questionId: String, answer: AgentQuestionAnswer)
    case setModel(String)
    case setMode(String)
    case setConfigOption(id: String, value: String)
    case removeQueued(promptId: String)
}

public struct AgentAttachment: Hashable, Sendable, Identifiable {
    public enum Kind: Hashable, Sendable { case image, file }

    public var id: String
    public var kind: Kind
    public var name: String
    public var data: Data?

    public init(id: String = UUID().uuidString, kind: Kind, name: String, data: Data? = nil) {
        self.id = id
        self.kind = kind
        self.name = name
        self.data = data
    }

    /// The image MIME type from the data's signature (nil: not an image an
    /// agent accepts; the composer re-encodes others as JPEG).
    public var imageMIMEType: String? {
        guard kind == .image, let data, data.count >= 12 else { return nil }
        let bytes = [UInt8](data.prefix(12))
        if bytes.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "image/png" }
        if bytes.starts(with: [0xFF, 0xD8, 0xFF]) { return "image/jpeg" }
        if bytes.starts(with: [0x47, 0x49, 0x46, 0x38]) { return "image/gif" }
        if bytes.starts(with: [0x52, 0x49, 0x46, 0x46]), bytes[8...11] == [0x57, 0x45, 0x42, 0x50] { return "image/webp" }
        return nil
    }
}

/// The data side of an agent chat. The mock streams a scripted session offline;
/// the link-backed source (later) speaks acpmux over the `acpmux` link service.
@MainActor
public protocol AgentSessionSource: AnyObject {
    var summary: AgentSessionSummary { get }
    /// Every record from the start of the session (history replay), then live records.
    func events() -> AsyncStream<AgentSessionEvent>
    func send(_ intent: AgentClientIntent)

    // ACP parity (web UI acpmux/checkpoints and acpmux/handoff). Sources
    // without a feature throw `AgentFeatureUnavailable` with the reason.

    /// Repository checkpoints around this session's turns, newest first.
    func checkpoints() async throws -> [AgentCheckpoint]
    /// Restores the working tree to `checkpoint`; returns a one-line summary.
    func restore(_ checkpoint: AgentCheckpoint) async throws -> String
    /// Harnesses this session can continue in.
    func handoffTargets() async throws -> [AgentHandoffTarget]
    /// Prepares (or returns the existing) continuation to `target`.
    func prepareHandoff(to target: AgentHandoffTarget) async throws -> AgentHandoffDraft
    /// Sends the reviewed capsule and starts the target session.
    func startHandoff(_ draft: AgentHandoffDraft) async throws -> AgentHandoffReceipt
    func discardHandoff(_ draft: AgentHandoffDraft) async
    /// Loads the session's referenced files for the artifacts browser.
    var artifactSource: any ArtifactSource { get }
}

extension AgentSessionSource {
    public func checkpoints() async throws -> [AgentCheckpoint] {
        throw AgentFeatureUnavailable("This session has no checkpoints.")
    }

    public func restore(_ checkpoint: AgentCheckpoint) async throws -> String {
        throw AgentFeatureUnavailable("This session can't restore checkpoints.")
    }

    public func handoffTargets() async throws -> [AgentHandoffTarget] {
        throw AgentFeatureUnavailable("This session can't continue in another agent.")
    }

    public func prepareHandoff(to target: AgentHandoffTarget) async throws -> AgentHandoffDraft {
        throw AgentFeatureUnavailable("This session can't continue in another agent.")
    }

    public func startHandoff(_ draft: AgentHandoffDraft) async throws -> AgentHandoffReceipt {
        throw AgentFeatureUnavailable("This session can't continue in another agent.")
    }

    public func discardHandoff(_ draft: AgentHandoffDraft) async {}

    public var artifactSource: any ArtifactSource { MockArtifactSource() }
}
