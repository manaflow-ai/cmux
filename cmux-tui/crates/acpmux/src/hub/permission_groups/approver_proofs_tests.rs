use super::{PendingMember, allow_options, approver_proofs};
use serde_json::{Value, json};

fn member(id: &str, nonce: &str, kind: &str) -> PendingMember {
    PendingMember {
        id: id.into(),
        decision_nonce: nonce.into(),
        request: json!({"toolCall": {"toolCallId": id, "kind": "execute"},
                            "options": [{"optionId": format!("yes-{id}"), "kind": kind}]}),
    }
}

fn body(entries: Value) -> Value {
    json!({"_meta": {"acpmux": {"approverDecisions": entries}}})
}

fn entry(nonce: &str) -> Value {
    json!({"decisionNonce": nonce, "approverDecision": {"approver": "mac-1"}})
}

/// A group's signed allow names every pending member once, with its own nonce, and each
/// member offers a single one-time allow; anything else matches nothing.
#[test]
fn every_pending_member_needs_its_own_entry_and_nothing_else() {
    let members = [member("p1", "n1", "allow_once"), member("p2", "n2", "allow_once")];
    let options = allow_options(&members).expect("each offers a one-time allow");
    let both = body(json!({"p1": entry("n1"), "p2": entry("n2")}));
    let proofs = approver_proofs(&members, &options, &both).expect("both members");
    assert_eq!(proofs.iter().map(|p| p.option).collect::<Vec<_>>(), ["yes-p1", "yes-p2"]);
    assert_eq!(proofs.iter().map(|p| p.nonce).collect::<Vec<_>>(), ["n1", "n2"]);
    assert!(proofs.iter().all(|p| p.answers.is_none()));
    for refused in [
        body(json!({"p1": entry("n1")})),
        body(json!({"p1": entry("n1"), "p2": entry("n1")})),
        body(json!({"p1": entry("n1"), "p3": entry("n2")})),
        body(json!({"p1": entry("n1"), "p2": entry("n2"), "p3": entry("n3")})),
        body(json!({"p1": entry("n1"), "p2": {"decisionNonce": "n2"}})),
        body(json!([])),
        json!({}),
    ] {
        assert!(approver_proofs(&members, &options, &refused).is_none(), "{refused}");
    }
    assert!(approver_proofs(&[], &[], &body(json!({}))).is_none());
    let lasting = [member("p1", "n1", "allow_always")];
    assert!(allow_options(&lasting).is_none());
}
