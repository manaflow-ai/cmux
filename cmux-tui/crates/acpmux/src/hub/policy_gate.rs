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
//! ([`crate::claude_stdio::TOOL_GATE`]) while the chat's policy is narrower than approve-all.
//! The hub turns the gate on at every agent start and at every narrowing
//! ([`crate::claude_stdio::POLICY_GATE`], `hold_policy_mode`, `follow_policy`, and again when a
//! daemon adopts the agent's host), and answers each call by the chat's policy as it is then
//! ([`gate_decision`]):
//!
//! | policy | read, search, think | fetch | edit | read-only shell | anything else |
//! | --- | --- | --- | --- | --- | --- |
//! | deny-all | none | deny | deny | allow | deny |
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
//! A harness with neither this gate nor a mode that keeps its policy does not start under it
//! (`policy_mode.rs` `require_enforced`).

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
    // could be one the agent wrote (`permissions.rs`).
    let reads_shell = matches!(
        policy,
        PermissionPolicy::DenyAll | PermissionPolicy::Review | PermissionPolicy::ApproveReads
    );
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
        PermissionPolicy::DenyAll => "deny-all allows reads and read-only shell commands only",
        _ => "the policy refuses it",
    };
    format!(
        "acpmux denied this tool call: this chat's permission policy is {policy} ({what}). Do not retry it; say what you would have done instead."
    )
}

/// Whether `meta`'s agent has the PreToolUse gate: acpmux's own Claude Code backend, which
/// registers it on unix (`claude_stdio::outbound::initialize_request`).
pub(super) fn has_gate(meta: &SessionMeta) -> bool {
    cfg!(unix) && crate::claude_stdio::steers_by_info(meta.agent_info.as_ref())
}

impl Hub {
    /// [`crate::claude_stdio::TOOL_GATE`]: the gate's answer for one tool call of `session`'s
    /// agent (module docs). `request` has the shape of a `session/request_permission`.
    pub(super) async fn answer_tool_gate(&self, session: &Arc<Session>, request: Value) -> Value {
        let default = self.config.read().await.permission_policy;
        let policy = self.policy_for(session, default);
        if policy == PermissionPolicy::ApproveAll {
            return json!({"decision": GateDecision::None.as_str()});
        }
        let kind = request.pointer("/toolCall/kind").and_then(Value::as_str).unwrap_or("");
        let rule = session
            .meta()
            .permission_rules
            .as_ref()
            .and_then(|r| super::rules::decide(r, &request));
        let needs_person = super::questions::needs_person(&request);
        let shell_reads = kind == "execute"
            && matches!(
                policy,
                PermissionPolicy::DenyAll
                    | PermissionPolicy::Review
                    | PermissionPolicy::ApproveReads
            )
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

    /// Tells `child`, acpmux's Claude Code backend, which policy its PreToolUse gate holds:
    /// `Some` turns the gate on, `None` off (module docs). The hub answers each call by the
    /// chat's policy as it is then, so a gate left on only asks more often.
    pub(super) async fn push_policy_gate(
        &self,
        session: &Session,
        child: &ChildAgent,
        policy: Option<PermissionPolicy>,
    ) -> Result<(), RpcError> {
        let sid = session.meta().agent_session_id.clone().unwrap_or_else(|| session.id.clone());
        let params = json!({"sessionId": sid, "policy": policy.map(|p| p.to_string())});
        child.request(crate::claude_stdio::POLICY_GATE, params).await.map(|_| ())
    }

    /// `session`'s policy changed, or a daemon reached its agent again: a running agent with the
    /// gate takes the policy it holds now (narrower than approve-all: on; else off). A gate that
    /// does not take a narrower policy is logged as `policy_unenforced`; the chat's mode still
    /// moves to the policy's (`follow_policy`).
    pub(super) async fn follow_policy_gate(&self, session: &Arc<Session>) {
        let meta = session.meta();
        if !has_gate(&meta) {
            return;
        }
        let child = session.child.lock().await.clone();
        let Some(child) = child else { return };
        if !child.is_alive().await {
            return;
        }
        let default = self.config.read().await.permission_policy;
        let policy = super::policy_mode::narrow_policy(&meta, default);
        // Bounded: a host that stopped reading must not hold a policy change.
        let pushed = tokio::time::timeout(
            std::time::Duration::from_secs(10),
            self.push_policy_gate(session, &child, policy),
        )
        .await;
        let error = match pushed {
            Ok(Ok(())) => return,
            Ok(Err(e)) => e.message,
            Err(_) => "the agent did not answer in 10 s".to_owned(),
        };
        tracing::warn!(session = %session.id, ?policy, "the policy gate did not take the policy: {error}");
        if let Some(policy) = policy {
            self.append(
                session,
                "mux",
                "policy_unenforced",
                json!({"policy": policy.to_string(), "modeId": crate::web_modes::mode_of(&meta), "reason": format!("the tool gate did not take the policy: {error}")}),
            );
        }
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
            (P::DenyAll, [G::None, G::Deny, G::Deny, G::Allow, G::Deny, G::Deny]),
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

    #[test]
    fn the_deny_reason_names_the_policy_and_tells_the_model_not_to_retry() {
        let reason = deny_reason(PermissionPolicy::Review, false);
        assert!(reason.contains("review") && reason.contains("Do not retry"), "{reason}");
        assert!(deny_reason(PermissionPolicy::DenyAll, true).contains("rule"));
    }
}
