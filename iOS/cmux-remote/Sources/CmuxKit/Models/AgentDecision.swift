public import Foundation

/// A decision the user must make on behalf of an agent, derived from
/// `agent.hook.*` events emitted by cmux (Claude Code's `PermissionRequest`,
/// Codex's `tool_use_request`, OpenCode's permission gating, etc.).
///
/// The macOS app aggregates these and exposes them on the events stream;
/// the iOS client maps them onto rich notifications and Live Activities so
/// the user can resolve a decision without unlocking and entering the full
/// UI.
public struct AgentDecision: Hashable, Codable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable {
        case toolCall = "tool_call"
        case diff
        case choice
        case exitPlan = "exit_plan"
        case freeform
    }

    public struct QuestionSelection: Hashable, Codable, Sendable {
        public let questionID: String
        public let optionIDs: [String]

        public init(questionID: String, optionIDs: [String]) {
            self.questionID = questionID
            self.optionIDs = optionIDs
        }
    }

    public struct Choice: Hashable, Codable, Sendable, Identifiable {
        public enum Style: String, Codable, Sendable {
            case `default`
            case affirmative
            case destructive
        }

        public let id: String
        public let label: String
        public let style: Style
        public let requiresAuth: Bool
        public let questionSelections: [QuestionSelection]?

        public init(
            id: String,
            label: String,
            style: Style,
            requiresAuth: Bool,
            questionSelections: [QuestionSelection]? = nil
        ) {
            self.id = id
            self.label = label
            self.style = style
            self.requiresAuth = requiresAuth
            self.questionSelections = questionSelections
        }
    }

    public let id: String
    public let hostID: UUID?
    public let itemID: String?
    public let workspaceID: WorkspaceID?
    public let surfaceID: SurfaceID?
    public let agentName: String
    public let kind: Kind
    public let summary: String
    public let detail: String?
    public let toolName: String?
    public let command: String?
    public let isReadOnly: Bool
    public let choices: [Choice]
    public let expiresAt: Date?

    public init(
        id: String,
        hostID: UUID? = nil,
        itemID: String? = nil,
        workspaceID: WorkspaceID?,
        surfaceID: SurfaceID?,
        agentName: String,
        kind: Kind,
        summary: String,
        detail: String?,
        toolName: String? = nil,
        command: String? = nil,
        isReadOnly: Bool = false,
        choices: [Choice],
        expiresAt: Date?
    ) {
        self.id = id
        self.hostID = hostID
        self.itemID = itemID
        self.workspaceID = workspaceID
        self.surfaceID = surfaceID
        self.agentName = agentName
        self.kind = kind
        self.summary = summary
        self.detail = detail
        self.toolName = toolName
        self.command = command
        self.isReadOnly = isReadOnly
        self.choices = choices
        self.expiresAt = expiresAt
    }

    public var hasDestructiveChoice: Bool {
        choices.contains(where: { $0.style == .destructive })
    }

    public var hasBoundFeedItem: Bool {
        guard let itemID else { return false }
        return !itemID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public func scoped(to hostID: UUID) -> AgentDecision {
        AgentDecision(
            id: id,
            hostID: hostID,
            itemID: itemID,
            workspaceID: workspaceID,
            surfaceID: surfaceID,
            agentName: agentName,
            kind: kind,
            summary: summary,
            detail: detail,
            toolName: toolName,
            command: command,
            isReadOnly: isReadOnly,
            choices: choices,
            expiresAt: expiresAt
        )
    }

    public var scopeKey: String {
        Self.scopeKey(decisionID: id, hostID: hostID?.uuidString)
    }

    public static func scopeKey(decisionID: String, hostID: String?) -> String {
        let scope = hostID?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedScope = scope?.isEmpty == false ? scope ?? "unscoped" : "unscoped"
        return "\(resolvedScope):\(decisionID)"
    }
}

/// Decoder that maps cmux `agent.hook.<HookEventName>` payloads to a
/// canonical `AgentDecision`. Forward-compat: unknown hook events return
/// `nil` so callers ignore them silently.
public enum AgentDecisionMapper {

    public static func decode(from event: CmuxEventFrame.Event) -> AgentDecision? {
        guard event.category == "agent" || event.name.hasPrefix("agent.hook.") else {
            return nil
        }
        guard
            let payload = try? JSONSerialization.jsonObject(with: event.payload) as? [String: Any]
        else { return nil }

        let rawHookName = (payload["hook_event_name"] as? String) ?? event.name
        let hookName = rawHookName.hasPrefix("agent.hook.")
            ? String(rawHookName.dropFirst("agent.hook.".count))
            : rawHookName
        let source = (payload["_source"] as? String) ?? event.source
        guard let id = FeedDecisionIdentifier.extract(from: payload) else {
            return nil
        }

        let summary: String
        let detail: String?
        let choices: [AgentDecision.Choice]
        let kind: AgentDecision.Kind

        let toolName: String? = payload["tool_name"] as? String
        let command: String? = (payload["command"] as? String) ?? (payload["tool_input"] as? String)
        let isReadOnly: Bool = (payload["read_only"] as? Bool) ?? false

        switch hookName {
        case "PermissionRequest", "tool_use_request":
            let tool = safeDisplayName(toolName)
                ?? String(localized: "decision.tool.default_name", defaultValue: "tool")
            summary = String(
                format: String(
                    localized: "decision.summary.tool_call",
                    defaultValue: "%@ wants to run %@"
                ),
                locale: Locale.current,
                source,
                tool
            )
            detail = command
            kind = .toolCall
            choices = [
                AgentDecision.Choice(id: "allow", label: String(localized: "decision.choice.allow_once", defaultValue: "Allow once"), style: .affirmative, requiresAuth: true),
                AgentDecision.Choice(id: "allow_session", label: String(localized: "decision.choice.allow_session", defaultValue: "Allow this session"), style: .default, requiresAuth: true),
                AgentDecision.Choice(id: "allow_all", label: String(localized: "decision.choice.allow_all_tools", defaultValue: "Allow all tools"), style: .default, requiresAuth: true),
                AgentDecision.Choice(id: "allow_bypass", label: String(localized: "decision.choice.bypass", defaultValue: "Bypass"), style: .affirmative, requiresAuth: true),
                AgentDecision.Choice(id: "deny", label: String(localized: "decision.choice.deny", defaultValue: "Deny"), style: .destructive, requiresAuth: false)
            ]
        case "DiffApprovalRequest":
            summary = String(
                format: String(
                    localized: "decision.summary.diff",
                    defaultValue: "%@ wants to apply a diff"
                ),
                locale: Locale.current,
                source
            )
            detail = payload["diff_summary"] as? String
            kind = .diff
            choices = [
                AgentDecision.Choice(id: "apply", label: String(localized: "decision.choice.apply", defaultValue: "Apply"), style: .affirmative, requiresAuth: true),
                AgentDecision.Choice(id: "reject", label: String(localized: "decision.choice.reject", defaultValue: "Reject"), style: .destructive, requiresAuth: false)
            ]
        case "ExitPlanMode":
            let input = payload["tool_input"] as? [String: Any]
            let context = payload["context"] as? [String: Any]
            summary = (payload["summary"] as? String)
                ?? (input?["summary"] as? String)
                ?? String(
                    localized: "decision.summary.exit_plan",
                    defaultValue: "Agent is ready to exit plan mode"
                )
            detail = (payload["plan"] as? String)
                ?? (input?["plan"] as? String)
                ?? (context?["assistantPreamble"] as? String)
            kind = .exitPlan
            choices = [
                AgentDecision.Choice(id: "manual", label: String(localized: "decision.choice.manual", defaultValue: "Manual"), style: .affirmative, requiresAuth: true),
                AgentDecision.Choice(id: "auto_accept", label: String(localized: "decision.choice.auto", defaultValue: "Auto"), style: .affirmative, requiresAuth: true),
                AgentDecision.Choice(id: "ultraplan", label: String(localized: "decision.choice.ultraplan", defaultValue: "Ultraplan"), style: .default, requiresAuth: true),
                AgentDecision.Choice(id: "allow_bypass", label: String(localized: "decision.choice.bypass", defaultValue: "Bypass"), style: .affirmative, requiresAuth: true),
                AgentDecision.Choice(id: "deny", label: String(localized: "decision.choice.deny", defaultValue: "Deny"), style: .destructive, requiresAuth: false)
            ]
        case "AskUserQuestion", "QuestionAsked":
            let questionPayload = Self.questionPayload(from: payload)
            summary = questionPayload.question
                ?? String(localized: "decision.summary.agent_waiting", defaultValue: "Agent is waiting")
            detail = questionPayload.context
            kind = .choice
            choices = questionPayload.options.enumerated().compactMap { idx, opt -> AgentDecision.Choice? in
                guard let label = Self.optionLabel(opt) else { return nil }
                let id = (opt["id"] as? String) ?? "opt_\(idx)"
                let styleRaw = (opt["style"] as? String) ?? "default"
                let style = AgentDecision.Choice.Style(rawValue: styleRaw) ?? .default
                let auth = (opt["requires_auth"] as? Bool) ?? true
                return AgentDecision.Choice(
                    id: id,
                    label: label,
                    style: style,
                    requiresAuth: auth,
                    questionSelections: [
                        AgentDecision.QuestionSelection(
                            questionID: questionPayload.questionID,
                            optionIDs: [id]
                        )
                    ]
                )
            }
        default:
            return nil
        }

        let expiresAt: Date? = {
            if let t = payload["expires_at"] as? String {
                return CmuxEventDecoder.parseTimestamp(t)
            }
            return nil
        }()

        return AgentDecision(
            id: id,
            itemID: payload["item_id"] as? String,
            workspaceID: event.workspaceID,
            surfaceID: event.surfaceID,
            agentName: source,
            kind: kind,
            summary: summary,
            detail: detail,
            toolName: toolName,
            command: command,
            isReadOnly: isReadOnly,
            choices: choices,
            expiresAt: expiresAt
        )
    }

    private static func safeDisplayName(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let firstToken = trimmed.split(whereSeparator: { $0.isWhitespace }).first.map(String.init) ?? trimmed
        let basename = firstToken.split(separator: "/").last.map(String.init) ?? firstToken
        guard !basename.isEmpty else { return nil }
        if basename.count <= 32 { return basename }
        return String(basename.prefix(32)) + "..."
    }

    private struct QuestionPayload {
        var questionID: String
        var question: String?
        var context: String?
        var options: [[String: Any]]
    }

    private static func questionPayload(from payload: [String: Any]) -> QuestionPayload {
        let input = payload["tool_input"] as? [String: Any]
        let contextObject = payload["context"] as? [String: Any]
        let questions = (input?["questions"] as? [[String: Any]])
            ?? (payload["questions"] as? [[String: Any]])
        let firstQuestion = questions?.first
        let questionID = (payload["question_id"] as? String)
            ?? (input?["question_id"] as? String)
            ?? (firstQuestion?["id"] as? String)
            ?? "q0"
        let question = (payload["question"] as? String)
            ?? (input?["question"] as? String)
            ?? (firstQuestion?["question"] as? String)
            ?? (firstQuestion?["prompt"] as? String)
        let context = (payload["context"] as? String)
            ?? (input?["context"] as? String)
            ?? (contextObject?["questionContext"] as? String)
        let options = (payload["options"] as? [[String: Any]])
            ?? (payload["choices"] as? [[String: Any]])
            ?? (input?["options"] as? [[String: Any]])
            ?? (input?["choices"] as? [[String: Any]])
            ?? (firstQuestion?["options"] as? [[String: Any]])
            ?? []
        return QuestionPayload(questionID: questionID, question: question, context: context, options: options)
    }

    private static func optionLabel(_ option: [String: Any]) -> String? {
        (option["label"] as? String)
            ?? (option["text"] as? String)
            ?? (option["value"] as? String)
            ?? (option["description"] as? String)
    }
}
