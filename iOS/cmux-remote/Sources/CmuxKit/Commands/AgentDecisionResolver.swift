import Foundation

/// Sends a decision the user took on iOS back to cmux. Per the agent hooks
/// pipeline (`docs/agent-hooks.md`), cmux exposes two v2 socket methods
/// used here via `cmux rpc <method> <json-params>`:
///
///   * `feed.permission.reply { request_id, item_id, mode }` — for
///     tool-call / diff-approval requests. `mode` is one of
///     `once | always | all | bypass | deny`.
///   * `feed.question.reply { request_id, item_id, selection_ids }` — for
///     question hooks with a finite list of options.
///
/// There is no `cmux feed resolve` CLI subcommand; the resolver goes
/// straight through `cmux rpc`.
///
/// Remote iOS actions must always include the concrete feed `item_id`.
/// Request ids can collide across agent/session lifetimes and the desktop
/// RPC keeps request-id-only delivery for local blocking hooks, so this
/// client refuses to emit request-id-only decision replies.
extension CMUXClient {

    /// Resolve a pending agent decision. `decision` is the iOS-local
    /// projection produced by `AgentDecisionMapper`; we pick the right
    /// v2 method off the kind and translate the chosen `choiceID` into
    /// the cmux mode/selection vocabulary.
    @discardableResult
    public func resolveAgentDecision(
        decision: AgentDecision,
        choiceID: String
    ) async throws -> CmuxExecResult {
        let method: String
        let params: [String: Any]

        switch decision.kind {
        case .toolCall, .diff:
            method = "feed.permission.reply"
            let itemID = try Self.requiredItemID(decision.itemID, decisionID: decision.id, kind: decision.kind)
            let permissionParams: [String: Any] = [
                "request_id": decision.id,
                "item_id": itemID,
                "mode": try Self.permissionMode(for: choiceID)
            ]
            params = permissionParams
        case .choice:
            method = "feed.question.reply"
            let itemID = try Self.requiredItemID(decision.itemID, decisionID: decision.id, kind: decision.kind)
            // The cmux question API expects the option *label* (not id);
            // we include the label when it is already in app memory, plus
            // the opaque id so notification / Live Activity responses do
            // not need to persist sensitive labels in userInfo.
            guard let chosen = decision.choices.first(where: { $0.id == choiceID }) else {
                throw CmuxError.decoding("unknown question choice id \(choiceID)", underlying: nil)
            }
            var questionParams: [String: Any] = [
                "request_id": decision.id,
                "item_id": itemID
            ]
            if let questionSelections = chosen.questionSelections {
                questionParams["question_selections"] = Self.questionSelectionsPayload(questionSelections)
            } else {
                questionParams["selection_ids"] = [chosen.id]
            }
            params = questionParams
        case .exitPlan:
            method = "feed.exit_plan.reply"
            let itemID = try Self.requiredItemID(decision.itemID, decisionID: decision.id, kind: decision.kind)
            let exitPlanParams: [String: Any] = [
                "request_id": decision.id,
                "item_id": itemID,
                "mode": try Self.exitPlanMode(for: choiceID)
            ]
            params = exitPlanParams
        case .freeform:
            // Free-form replies are sent as a single-element question
            // reply; cmux feed coordinator accepts the user's text as
            // the only selection.
            method = "feed.question.reply"
            let itemID = try Self.requiredItemID(decision.itemID, decisionID: decision.id, kind: decision.kind)
            params = [
                "request_id": decision.id,
                "item_id": itemID,
                "selections": [choiceID]
            ]
        }

        return try await resolve(method: method, params: params)
    }

    /// Resolve a decision when the caller only has the durable metadata
    /// carried in a notification / Live Activity payload.
    @discardableResult
    public func resolveAgentDecision(
        decisionID: String,
        itemID: String? = nil,
        kind: AgentDecision.Kind,
        choiceID: String,
        choiceLabel: String?,
        questionSelections: [AgentDecision.QuestionSelection]? = nil
    ) async throws -> CmuxExecResult {
        let method: String
        let params: [String: Any]
        switch kind {
        case .toolCall, .diff:
            method = "feed.permission.reply"
            let itemID = try Self.requiredItemID(itemID, decisionID: decisionID, kind: kind)
            let permissionParams: [String: Any] = [
                "request_id": decisionID,
                "item_id": itemID,
                "mode": try Self.permissionMode(for: choiceID)
            ]
            params = permissionParams
        case .choice:
            method = "feed.question.reply"
            let itemID = try Self.requiredItemID(itemID, decisionID: decisionID, kind: kind)
            var questionParams: [String: Any] = [
                "request_id": decisionID,
                "item_id": itemID
            ]
            if let questionSelections {
                questionParams["question_selections"] = Self.questionSelectionsPayload(questionSelections)
            } else {
                questionParams["selection_ids"] = [choiceID]
            }
            params = questionParams
        case .exitPlan:
            method = "feed.exit_plan.reply"
            let itemID = try Self.requiredItemID(itemID, decisionID: decisionID, kind: kind)
            let exitPlanParams: [String: Any] = [
                "request_id": decisionID,
                "item_id": itemID,
                "mode": try Self.exitPlanMode(for: choiceID)
            ]
            params = exitPlanParams
        case .freeform:
            method = "feed.question.reply"
            let itemID = try Self.requiredItemID(itemID, decisionID: decisionID, kind: kind)
            let replyText = Self.nonEmptyLabel(choiceLabel) ?? choiceID
            params = [
                "request_id": decisionID,
                "item_id": itemID,
                "selections": [replyText]
            ]
        }
        return try await resolve(method: method, params: params)
    }

    private static func questionSelectionsPayload(
        _ selections: [AgentDecision.QuestionSelection]
    ) -> [[String: Any]] {
        selections.map { selection in
            [
                "question_id": selection.questionID,
                "option_ids": selection.optionIDs
            ]
        }
    }

    private static func requiredItemID(
        _ itemID: String?,
        decisionID: String,
        kind: AgentDecision.Kind
    ) throws -> String {
        guard let itemID else {
            throw CmuxError.decoding(
                "refusing to resolve \(kind.rawValue) decision \(decisionID) without item_id",
                underlying: nil
            )
        }
        let trimmed = itemID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw CmuxError.decoding(
                "refusing to resolve \(kind.rawValue) decision \(decisionID) with empty item_id",
                underlying: nil
            )
        }
        return trimmed
    }

    private static func nonEmptyLabel(_ label: String?) -> String? {
        guard let label else { return nil }
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : label
    }

    private func resolve(method: String, params: [String: Any]) async throws -> CmuxExecResult {
        let data = try JSONSerialization.data(withJSONObject: params, options: [.sortedKeys])
        let json = String(data: data, encoding: .utf8) ?? "{}"
        let result = try await transport.runOneShot(
            command: ShellEscape.command([cmuxBinaryPath, "rpc", method, json]),
            stdin: nil
        )
        if result.exitCode != 0 {
            throw CmuxError.command(
                exitCode: result.exitCode,
                stderr: result.stderrString
            )
        }
        try Self.assertDecisionReplyDelivered(result, method: method)
        return result
    }

    private static func assertDecisionReplyDelivered(
        _ result: CmuxExecResult,
        method: String
    ) throws {
        let trimmed = result.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw CmuxError.decoding("\(method) returned an empty response", underlying: nil)
        }
        guard let data = trimmed.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else {
            throw CmuxError.decoding("\(method) returned non-JSON output", underlying: nil)
        }
        guard let delivered = object["delivered"] as? Bool else {
            throw CmuxError.decoding("\(method) response did not include delivered", underlying: nil)
        }
        guard delivered else {
            let reason = (object["reason"] as? String) ?? "not_delivered"
            throw CmuxError.command(
                exitCode: 0,
                stderr: "\(method) did not deliver decision: \(reason)"
            )
        }
    }

    /// Map the iOS choice id (which AgentDecisionMapper assigned) to the
    /// cmux `feed.permission.reply` mode vocabulary.
    private static func permissionMode(for choiceID: String) throws -> String {
        switch choiceID {
        case "allow", "apply", "approve": return "once"
        case "allow_session": return "always"
        case "allow_all": return "all"
        case "allow_bypass": return "bypass"
        case "deny", "reject": return "deny"
        default:
            throw CmuxError.decoding("unknown permission choice id \(choiceID)", underlying: nil)
        }
    }

    private static func exitPlanMode(for choiceID: String) throws -> String {
        switch choiceID {
        case "manual": return "manual"
        case "auto_accept", "auto", "allow_session": return "autoAccept"
        case "ultraplan": return "ultraplan"
        case "allow_bypass", "bypass", "bypass_permissions": return "bypassPermissions"
        case "deny", "reject": return "deny"
        default:
            throw CmuxError.decoding("unknown exit-plan choice id \(choiceID)", underlying: nil)
        }
    }
}
