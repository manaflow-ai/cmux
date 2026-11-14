use super::*;

fn tool() -> Value {
    json!({"toolCall": {"kind": "execute", "title": "Run ls"},
               "options": [{"optionId": "ok", "name": "Allow", "kind": "allow_once"},
                           {"optionId": "no", "name": "Deny", "kind": "reject_once"}]})
}

#[test]
fn a_decision_reads_allow_deny_answer_or_nothing() {
    let selected = |o: &str| json!({"outcome": {"outcome": "selected", "optionId": o}});
    assert_eq!(
        decision(Kind::Approval, &tool(), &selected("ok"), None),
        Some((Some("ok".into()), "allow"))
    );
    assert_eq!(
        decision(Kind::Approval, &tool(), &selected("no"), None),
        Some((Some("no".into()), "deny"))
    );
    let answered = json!({"outcome": {"outcome": "selected", "optionId": "ok",
                                          "_meta": {"updatedInput": {"answers": {"q": "a"}}}}});
    assert_eq!(
        decision(Kind::Question, &tool(), &answered, None),
        Some((Some("ok".into()), "answer"))
    );
    let cancelled = json!({"outcome": {"outcome": "cancelled"}});
    // Withdrawn, or cancelled by a stop or the shutdown: nobody answered.
    assert_eq!(decision(Kind::Approval, &tool(), &cancelled, None), None);
    // Its caller dismissed it (a question skipped that has no reject option).
    assert_eq!(
        decision(Kind::Question, &tool(), &cancelled, Some(Settled::Caller)),
        Some((None, "cancel"))
    );
    let by = json!({"outcome": {"outcome": "cancelled"}, "answeredBy": {"device": "phone"}});
    assert_eq!(decision(Kind::Approval, &tool(), &by, None), Some((None, "cancel")));
}

#[test]
fn only_a_persons_allow_or_answer_is_marked_theirs() {
    assert_eq!(answered_by("allow", None, None), json!({"person": true}));
    assert_eq!(answered_by("deny", None, None), json!({"person": false}));
    let device = json!({"device": "iphone", "feedItem": "f1"});
    assert_eq!(
        answered_by("allow", Some(&device), None),
        json!({"person": true, "device": "iphone", "feedItem": "f1", "via": "device"})
    );
    let ancestor = json!({"session": "parent", "name": "lead"});
    assert_eq!(
        answered_by("answer", Some(&ancestor), None),
        json!({"person": false, "via": "ancestor"})
    );
    // Allowed by itself after a switch to full access or approve-all: never the person's.
    assert_eq!(
        answered_by("allow", None, Some(Settled::Auto("mode"))),
        json!({"person": false, "via": "mode"})
    );
    assert_eq!(
        answered_by("allow", None, Some(Settled::Auto("policy"))),
        json!({"person": false, "via": "policy"})
    );
}

#[test]
fn a_queued_ask_masks_a_secret_the_preview_cut_goes_through() {
    // The token starts at char 190: the 200-char preview would keep only its head.
    let token = "ghp_aZ3kQ9mX7pL2vB8nR4tW6yC1dF5gH0jSaZ3k";
    let text = format!("{} {token} and more words after it", "x".repeat(189));
    let ask = queued_ask(&text);
    assert!(!ask.contains("aZ3kQ9"), "{ask}");
    // The cut keeps ASK_CHARS and marks itself with an ellipsis.
    assert!(ask.chars().count() <= ASK_CHARS + 1, "{ask}");
}
