public import Foundation

/// Persisted rules that govern auto-handling of agent decisions while the
/// user is away. The phone evaluates these locally — no remote dependency —
/// so a decision can be resolved even when cmux's hook handler is offline.
public struct AFKPolicy: Hashable, Codable, Sendable {
    public var autoApproveRules: [Rule]
    public var snoozeMinutes: Int
    public var watchdogStuckMinutes: Int
    public var notifyOnStuck: Bool
    public var requireBiometricForDestructive: Bool
    public var perWorkspaceCostBudgetCents: [String: Int]
    public var afkSummaryHour: Int

    public init(
        autoApproveRules: [Rule] = .recommendedDefaults,
        snoozeMinutes: Int = 10,
        watchdogStuckMinutes: Int = 5,
        notifyOnStuck: Bool = true,
        requireBiometricForDestructive: Bool = true,
        perWorkspaceCostBudgetCents: [String: Int] = [:],
        afkSummaryHour: Int = 8
    ) {
        self.autoApproveRules = autoApproveRules
        self.snoozeMinutes = snoozeMinutes
        self.watchdogStuckMinutes = watchdogStuckMinutes
        self.notifyOnStuck = notifyOnStuck
        self.requireBiometricForDestructive = requireBiometricForDestructive
        self.perWorkspaceCostBudgetCents = perWorkspaceCostBudgetCents
        self.afkSummaryHour = afkSummaryHour
    }

    private enum CodingKeys: String, CodingKey {
        case autoApproveRules
        case snoozeMinutes
        case watchdogStuckMinutes
        case notifyOnStuck
        case requireBiometricForDestructive
        case perWorkspaceCostBudgetCents
        case perWorkspaceCostBudgetUSD
        case afkSummaryHour
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        autoApproveRules = try container.decodeIfPresent([Rule].self, forKey: .autoApproveRules)
            ?? .recommendedDefaults
        snoozeMinutes = try container.decodeIfPresent(Int.self, forKey: .snoozeMinutes) ?? 10
        watchdogStuckMinutes = try container.decodeIfPresent(Int.self, forKey: .watchdogStuckMinutes) ?? 5
        notifyOnStuck = try container.decodeIfPresent(Bool.self, forKey: .notifyOnStuck) ?? true
        requireBiometricForDestructive = try container.decodeIfPresent(
            Bool.self,
            forKey: .requireBiometricForDestructive
        ) ?? true
        if let cents = try container.decodeIfPresent(
            [String: Int].self,
            forKey: .perWorkspaceCostBudgetCents
        ) {
            perWorkspaceCostBudgetCents = cents
        } else {
            let usd = try container.decodeIfPresent(
                [String: Double].self,
                forKey: .perWorkspaceCostBudgetUSD
            ) ?? [:]
            perWorkspaceCostBudgetCents = usd.mapValues { Int(($0 * 100).rounded()) }
        }
        afkSummaryHour = try container.decodeIfPresent(Int.self, forKey: .afkSummaryHour) ?? 8
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(autoApproveRules, forKey: .autoApproveRules)
        try container.encode(snoozeMinutes, forKey: .snoozeMinutes)
        try container.encode(watchdogStuckMinutes, forKey: .watchdogStuckMinutes)
        try container.encode(notifyOnStuck, forKey: .notifyOnStuck)
        try container.encode(requireBiometricForDestructive, forKey: .requireBiometricForDestructive)
        try container.encode(perWorkspaceCostBudgetCents, forKey: .perWorkspaceCostBudgetCents)
        try container.encode(afkSummaryHour, forKey: .afkSummaryHour)
    }

    public struct Rule: Hashable, Codable, Sendable, Identifiable {
        public let id: UUID
        public var label: String
        public var match: Match
        public var action: Action
        public var enabled: Bool

        public init(id: UUID = UUID(), label: String, match: Match, action: Action, enabled: Bool = true) {
            self.id = id
            self.label = label
            self.match = match
            self.action = action
            self.enabled = enabled
        }
    }

    public struct Match: Hashable, Codable, Sendable {
        public var toolNameRegex: String?
        public var commandRegex: String?
        public var workspaceID: String?
        public var agentName: String?
        public var maxLines: Int?
        public var onlyReadOnly: Bool

        public init(
            toolNameRegex: String? = nil,
            commandRegex: String? = nil,
            workspaceID: String? = nil,
            agentName: String? = nil,
            maxLines: Int? = nil,
            onlyReadOnly: Bool = false
        ) {
            self.toolNameRegex = toolNameRegex
            self.commandRegex = commandRegex
            self.workspaceID = workspaceID
            self.agentName = agentName
            self.maxLines = maxLines
            self.onlyReadOnly = onlyReadOnly
        }
    }

    public enum Action: String, Codable, Sendable {
        case autoApprove
        case autoDeny
        case alwaysAskNoQuietHours
        case escalateToWatch
    }
}

extension Array where Element == AFKPolicy.Rule {
    /// Conservative defaults that auto-approve only obviously safe
    /// operations and always prompt for writes. Users can edit / replace
    /// the entire list from Settings.
    public static var recommendedDefaults: [AFKPolicy.Rule] {
        // The default rule set is intentionally conservative: only tools
        // that are strictly read-only are listed, and the `onlyReadOnly`
        // guard requires the *agent* to also flag the call as read-only.
        // `sed`, `awk`, `tee`, `jq` are deliberately excluded — they can
        // write to disk with the wrong flags. Users can broaden the rules
        // from Settings if they understand the trade-off.
        [
            AFKPolicy.Rule(
                label: String(
                    localized: "afk.default_rule.read_only_files",
                    defaultValue: "Read-only file inspection (strict)"
                ),
                match: AFKPolicy.Match(
                    toolNameRegex: "^(read|read_file|cat|head|tail|grep|rg|ls|find|stat|file|wc)$",
                    onlyReadOnly: true
                ),
                action: .autoApprove
            ),
            AFKPolicy.Rule(
                // Anchored `$` and explicit "no shell metachars" pattern
                // — without this, `git diff; rm -rf foo` matched the
                // earlier `\b`-terminated regex and auto-approved a
                // chained destructive command (caught by adversarial
                // review).
                label: String(
                    localized: "afk.default_rule.git_read_only",
                    defaultValue: "git status / log / diff (read-only)"
                ),
                match: AFKPolicy.Match(
                    commandRegex: "^git\\s+(status|log|diff|show|blame|branch\\s+--list)(\\s+[^;&|`$()<>]*)?$",
                    onlyReadOnly: true
                ),
                action: .autoApprove
            ),
            AFKPolicy.Rule(
                label: String(
                    localized: "afk.default_rule.block_rm_rf",
                    defaultValue: "Block any rm -rf"
                ),
                match: AFKPolicy.Match(commandRegex: "rm\\s+-rf\\b"),
                action: .alwaysAskNoQuietHours
            )
        ]
    }
}

public struct AFKPolicyEvaluator {
    public let policy: AFKPolicy

    public init(policy: AFKPolicy) { self.policy = policy }

    public enum Outcome: Sendable, Equatable {
        case autoApprove(choiceID: String, ruleLabel: String)
        case autoDeny(choiceID: String, ruleLabel: String)
        case ask
    }

    public func evaluate(_ decision: AgentDecision) -> Outcome {
        for rule in policy.autoApproveRules where rule.enabled {
            if matches(rule.match, decision: decision) {
                switch rule.action {
                case .autoApprove:
                    if let choice = decision.choices.first(where: { $0.style == .affirmative })
                        ?? decision.choices.first(where: { $0.id == "allow" }) {
                        return .autoApprove(choiceID: choice.id, ruleLabel: rule.label)
                    }
                case .autoDeny:
                    if let choice = decision.choices.first(where: { $0.style == .destructive })
                        ?? decision.choices.last {
                        return .autoDeny(choiceID: choice.id, ruleLabel: rule.label)
                    }
                case .alwaysAskNoQuietHours, .escalateToWatch:
                    return .ask
                }
            }
        }
        return .ask
    }

    private func matches(_ match: AFKPolicy.Match, decision: AgentDecision) -> Bool {
        if let workspaceID = match.workspaceID,
           decision.workspaceID?.raw != workspaceID { return false }
        if let agent = match.agentName,
           decision.agentName != agent { return false }
        // Match against the **structured** tool_name field from the hook
        // payload — not the first token of the (free-form) `detail`
        // string. Matching `detail` previously let `sed -i ...` (a write)
        // collapse to a `sed` token and trip the "read-only file
        // inspection" rule. Auto-approve must only fire when the *agent*
        // says it's calling the named tool.
        if let toolRegex = match.toolNameRegex {
            guard let tool = decision.toolName,
                  regexMatch(pattern: toolRegex, value: tool) else { return false }
        }
        if let commandRegex = match.commandRegex {
            guard let command = decision.command,
                  regexMatch(pattern: commandRegex, value: command) else { return false }
        }
        // Honour `onlyReadOnly` — the agent payload carries a
        // `read_only: true|false` flag we now thread through. If the rule
        // demands read-only and the decision is not flagged read-only,
        // refuse to match.
        if match.onlyReadOnly && !decision.isReadOnly {
            return false
        }
        if let maxLines = match.maxLines,
           (decision.command?.split(separator: "\n").count ?? 0) > maxLines {
            return false
        }
        return true
    }

    private func regexMatch(pattern: String, value: String) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return false }
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        return regex.firstMatch(in: value, options: [], range: range) != nil
    }
}
