//! Part of `Hub`; see `hub/mod.rs`. A chat's permission policy held whatever mode its harness
//! runs in, on acpmux's own Claude Code backend (`claude_stdio`, and so every Claude Code
//! launcher profile, such as `claude-sr2`).
//!
//! acpmux's policy answers the questions a harness asks (`permissions.rs`), and the policy's mode
//! (`policy_mode.rs`) makes the harness ask. For Claude Code that is not enough: in `auto` (its
//! classifier decides) and for a call its own settings allow, it runs the tool without asking.
//! W5-L, 2026-11-08: chats on the `claude-sr2` profile under deny-all and under review ran a
//! `touch` and a Write with no prompt and no deny, and the daemon only warned.
//!
//! So Claude Code's PreToolUse gate (`claude_stdio/policy_gate.rs`), a hook callback that Claude
//! Code fires before every tool call in every mode, asks the hub about each call
//! ([`crate::claude_stdio::TOOL_GATE`]). The hub answers by the chat's policy as it is when the
//! call comes ([`gate_policy`], [`gate_decision`]); the agent keeps no copy of it, so a policy
//! change, a daemon restart or an agent start cannot leave the gate open:
//!
//! | policy | read, search, think | fetch | edit | read-only shell | anything else |
//! | --- | --- | --- | --- | --- | --- |
//! | deny-all | none | deny | deny | deny | deny |
//! | review | none | none | deny | allow | deny |
//! | approve-reads | none | none | ask | allow | ask |
//! | approve-edits | none | none | none | ask | ask |
//! | ask | none | none | ask | ask | ask |
//!
//! `none` lets Claude Code go on as it would (a question it then asks reaches the policy as
//! before), `allow` runs the call with no prompt, `ask` makes Claude Code ask (the policy or the
//! person then answers), and `deny` blocks the call with the reason. A chat rule (`rules.rs`)
//! decides first, as it does for an ask, and deny-all still refuses what a rule approves. In a
//! Web turn an `allow` becomes `ask`: only a person approves there (`remote_floor.rs`). Each
//! `allow` and `deny` is logged as `permission_auto`, as the policy's answers to asks are.
//!
//! The policy the gate holds is the one the chat's mode follows (`policy_mode.rs`
//! `narrow_policy`: its own, else a deny-all or review default, a lockdown). A default of ask,
//! approve-reads or approve-edits is not narrowing (chats start in full access by design).
//!
//! Deny-all denies every shell command, a read-only one too (lead, 2026-11-08: the name promises
//! it). Review is the read-only preset: its read-only shell commands run (`shell_readonly.rs`
//! decides what only reads).
//!
//! A chat whose harness has neither this gate nor another way to keep its policy does not run
//! under it (`policy_mode.rs` `require_enforced`).

use super::*;
use cmux_json::JsonSet as _;

/// What the PreToolUse gate tells Claude Code to do with one tool call (module docs).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum GateDecision {
    /// Go on as Claude Code would: run it, or ask as its mode says.
    None,
    /// Run it with no prompt.
    Allow,
    /// Ask before it runs, whatever Claude Code's mode or settings say.
    Ask,
    /// Block it.
    Deny,
}

impl GateDecision {
    /// The value Claude Code's backend reads (`claude_stdio/policy_gate.rs`).
    pub(crate) fn as_str(self) -> &'static str {
        match self {
            Self::None => "none",
            Self::Allow => "allow",
            Self::Ask => "ask",
            Self::Deny => "deny",
        }
    }
}

/// The gate's answer for one tool call of ACP kind `kind` under `policy` (module docs). `rule`:
/// the chat's rule for it; `needs_person`: it is a question only a person answers;
/// `shell_reads`: it is a shell command that only reads (`shell_readonly.rs`).
pub(crate) fn gate_decision(
    policy: PermissionPolicy,
    rule: Option<super::rules::RuleDecision>,
    kind: &str,
    needs_person: bool,
    shell_reads: bool,
) -> GateDecision {
    use super::rules::RuleDecision;
    if policy == PermissionPolicy::ApproveAll {
        return GateDecision::None;
    }
    if rule == Some(RuleDecision::Deny) {
        return GateDecision::Deny;
    }
    // deny-all refuses whatever a rule approves, as it does for an ask (`permissions.rs`).
    if policy != PermissionPolicy::DenyAll {
        match rule {
            Some(RuleDecision::Approve) => return GateDecision::Allow,
            Some(RuleDecision::Ask) => return GateDecision::Ask,
            _ => {}
        }
    }
    if needs_person {
        return GateDecision::None;
    }
    let reads = matches!(kind, "read" | "search" | "think" | "switch")
        || (kind == "fetch" && policy != PermissionPolicy::DenyAll);
    if reads || (policy == PermissionPolicy::ApproveEdits && kind == "edit") {
        return GateDecision::None;
    }
    // Approve-edits and ask never run a shell command unasked: under approve-edits its program
    // could be one the agent wrote (`permissions.rs`). Deny-all runs none.
    let reads_shell = matches!(policy, PermissionPolicy::Review | PermissionPolicy::ApproveReads);
    if kind == "execute" && shell_reads && reads_shell {
        return GateDecision::Allow;
    }
    match policy {
        PermissionPolicy::DenyAll | PermissionPolicy::Review => GateDecision::Deny,
        _ => GateDecision::Ask,
    }
}

/// Why the gate denied a call, as Claude Code shows it to the model.
fn deny_reason(policy: PermissionPolicy, by_rule: bool) -> String {
    if by_rule {
        return "acpmux denied this tool call: a permission rule of this chat refuses it"
            .to_owned();
    }
    let what = match policy {
        PermissionPolicy::Review => {
            "review allows reads, searches and read-only shell commands only"
        }
        PermissionPolicy::DenyAll => {
            "deny-all allows the file read and search tools only (Read, Grep, Glob) and denies every shell command, a read-only one too"
        }
        _ => "the policy refuses it",
    };
    format!(
        "acpmux denied this tool call: this chat's permission policy is {policy} ({what}). Do not retry it; say what you would have done instead."
    )
}

/// Whether `meta`'s agent has the PreToolUse gate: acpmux's own Claude Code backend, started by
/// a build that registers it (`claude_stdio::has_tool_gate`).
pub(super) fn has_gate(meta: &SessionMeta) -> bool {
    crate::claude_stdio::has_tool_gate(meta.agent_info.as_ref())
}

/// The policy the gate holds for `meta` under default policy `default`, or `None`: nothing to
/// hold (module docs).
pub(super) fn gate_policy(
    meta: &SessionMeta,
    default: PermissionPolicy,
) -> Option<PermissionPolicy> {
    super::policy_mode::narrow_policy(meta, default)
}

impl Hub {
    /// [`crate::claude_stdio::TOOL_GATE`]: the gate's answer for one tool call of `session`'s
    /// agent (module docs). `request` has the shape of a `session/request_permission`.
    pub(super) async fn answer_tool_gate(&self, session: &Arc<Session>, request: Value) -> Value {
        // Claude Code's own SendMessage to another session, whatever the policy: it never
        // reaches an acpmux session visibly (`native_messaging.rs`).
        if let Some(reason) = self.native_message_refusal(session, &request) {
            let record = json!({
                "permissionId": uuid::Uuid::now_v7().to_string(),
                "policy": Value::Null,
                "optionId": "reject_once",
                "request": request,
                "gate": "preToolUse",
                "reason": "native_message",
            });
            self.append(session, "mux", "permission_auto", record);
            tracing::info!(session = %session.id, "the gate refused a native SendMessage");
            return json!({"decision": GateDecision::Deny.as_str(), "reason": reason});
        }
        let default = self.config.read().await.permission_policy;
        let Some(policy) = gate_policy(&session.meta(), default) else {
            return json!({"decision": GateDecision::None.as_str()});
        };
        let kind = request.pointer("/toolCall/kind").and_then(Value::as_str).unwrap_or("");
        let rule = session
            .meta()
            .permission_rules
            .as_ref()
            .and_then(|r| super::rules::decide(r, &request));
        let needs_person = super::questions::needs_person(&request);
        let shell_reads = kind == "execute"
            && matches!(policy, PermissionPolicy::Review | PermissionPolicy::ApproveReads)
            && self.probe_shell_reads(session, &request).await;
        let mut decision = gate_decision(policy, rule, kind, needs_person, shell_reads);
        if decision == GateDecision::Allow && Self::web_turn(session) {
            decision = GateDecision::Ask;
        }
        let by_rule = rule == Some(super::rules::RuleDecision::Deny);
        let option = match decision {
            GateDecision::Deny => Some("reject_once"),
            GateDecision::Allow => Some("allow_once"),
            GateDecision::None | GateDecision::Ask => None,
        };
        if let Some(option) = option {
            let record = json!({
                "permissionId": uuid::Uuid::now_v7().to_string(),
                "policy": policy.to_string(),
                "rule": rule.map(|r| format!("{r:?}").to_lowercase()),
                "optionId": option,
                "request": request,
                "gate": "preToolUse",
            });
            self.append(session, "mux", "permission_auto", record);
        }
        let mut answer = json!({"decision": decision.as_str()});
        if decision == GateDecision::Deny {
            answer.set("reason", json!(deny_reason(policy, by_rule)));
            tracing::info!(session = %session.id, %policy, "the policy gate denied a tool call");
        }
        answer
    }
}

#[cfg(test)]
mod tests {
    use super::super::rules::RuleDecision;
    use super::*;

    const ALL: [PermissionPolicy; 5] = [
        PermissionPolicy::Ask,
        PermissionPolicy::ApproveReads,
        PermissionPolicy::ApproveEdits,
        PermissionPolicy::DenyAll,
        PermissionPolicy::Review,
    ];

    fn decide(policy: PermissionPolicy, kind: &str, shell_reads: bool) -> GateDecision {
        gate_decision(policy, None, kind, false, shell_reads)
    }

    /// The module docs' table, row by row.
    #[test]
    fn each_policy_gates_each_kind_of_call_as_the_table_says() {
        use GateDecision as G;
        use PermissionPolicy as P;
        // read, fetch, edit, read-only shell, other shell, other tool
        let rows = [
            (P::DenyAll, [G::None, G::Deny, G::Deny, G::Deny, G::Deny, G::Deny]),
            (P::Review, [G::None, G::None, G::Deny, G::Allow, G::Deny, G::Deny]),
            (P::ApproveReads, [G::None, G::None, G::Ask, G::Allow, G::Ask, G::Ask]),
            (P::ApproveEdits, [G::None, G::None, G::None, G::Ask, G::Ask, G::Ask]),
            (P::Ask, [G::None, G::None, G::Ask, G::Ask, G::Ask, G::Ask]),
        ];
        for (policy, want) in rows {
            let got = [
                decide(policy, "read", false),
                decide(policy, "fetch", false),
                decide(policy, "edit", false),
                decide(policy, "execute", true),
                decide(policy, "execute", false),
                decide(policy, "other", false),
            ];
            assert_eq!(got, want, "{policy}");
            for kind in ["search", "think", "switch"] {
                assert_eq!(decide(policy, kind, false), G::None, "{policy} {kind}");
            }
        }
    }

    /// Approve-all has no gate: every call goes on as Claude Code would.
    #[test]
    fn approve_all_gates_nothing() {
        for kind in ["read", "edit", "execute", "other"] {
            let got = gate_decision(
                PermissionPolicy::ApproveAll,
                Some(RuleDecision::Deny),
                kind,
                false,
                false,
            );
            assert_eq!(got, GateDecision::None, "{kind}");
        }
    }

    /// A rule decides first; deny-all still refuses what a rule approves.
    #[test]
    fn a_rule_decides_first_and_deny_all_refuses_an_approved_call() {
        for policy in ALL {
            let deny = gate_decision(policy, Some(RuleDecision::Deny), "read", false, false);
            assert_eq!(deny, GateDecision::Deny, "{policy}");
            let approve = gate_decision(policy, Some(RuleDecision::Approve), "edit", false, false);
            let ask = gate_decision(policy, Some(RuleDecision::Ask), "read", false, false);
            if policy == PermissionPolicy::DenyAll {
                assert_eq!(approve, GateDecision::Deny);
                assert_eq!(ask, GateDecision::None, "a read under deny-all");
            } else {
                assert_eq!(approve, GateDecision::Allow, "{policy}");
                assert_eq!(ask, GateDecision::Ask, "{policy}");
            }
        }
    }

    /// A question goes to the person as Claude Code asks it; the gate does not answer it.
    #[test]
    fn a_question_is_left_to_the_person() {
        for policy in ALL {
            assert_eq!(gate_decision(policy, None, "other", true, false), GateDecision::None);
        }
    }

    fn meta(own: Option<&str>) -> SessionMeta {
        serde_json::from_value(json!({
            "schema": crate::store::META_SCHEMA, "id": "s", "name": "s", "harness": "claude",
            "cwd": "/tmp", "status": "idle", "createdAt": 1, "updatedAt": 1,
            "permissionPolicy": own,
        }))
        .unwrap()
    }

    /// The chat's own policy, else a deny-all or review default; approve-all and the defaults
    /// that are not narrowing hold nothing.
    #[test]
    fn the_gate_holds_the_chats_policy_or_a_deny_all_or_review_default() {
        use PermissionPolicy as P;
        for (own, default, want) in [
            (Some("review"), P::Ask, Some(P::Review)),
            (Some("ask"), P::ApproveAll, Some(P::Ask)),
            (Some("approve-all"), P::DenyAll, None),
            (Some("approve-all"), P::Review, None),
            (None, P::DenyAll, Some(P::DenyAll)),
            (None, P::Review, Some(P::Review)),
            (None, P::Ask, None),
            (None, P::ApproveReads, None),
            (None, P::ApproveAll, None),
        ] {
            assert_eq!(gate_policy(&meta(own), default), want, "{own:?} {default}");
        }
    }

    #[test]
    fn the_deny_reason_names_the_policy_and_tells_the_model_not_to_retry() {
        let reason = deny_reason(PermissionPolicy::Review, false);
        assert!(reason.contains("review") && reason.contains("Do not retry"), "{reason}");
        assert!(deny_reason(PermissionPolicy::DenyAll, true).contains("rule"));
        // The real build's agent read "searches" as `rg` in a shell: deny-all names its tools.
        let reason = deny_reason(PermissionPolicy::DenyAll, false);
        assert!(reason.contains("Read, Grep, Glob") && reason.contains("every shell"), "{reason}");
    }
}
