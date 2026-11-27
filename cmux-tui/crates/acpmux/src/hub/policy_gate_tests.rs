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
