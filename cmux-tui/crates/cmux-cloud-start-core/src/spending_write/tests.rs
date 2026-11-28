use super::*;
use serde_json::json;

fn request(overage_usd: Option<f64>, steps: Vec<Value>) -> Request {
    Request { overage_usd, key: "save-1".into(), steps }
}

fn outcome(next: Next) -> Outcome {
    match next {
        Next::Done { outcome } => outcome,
        other => panic!("expected an outcome, got {other:?}"),
    }
}

#[test]
fn a_limit_is_one_usage_cap_set_call_with_the_save_key() {
    let next = next(&request(Some(40.5), vec![]));
    assert_eq!(
        next,
        Next::Call {
            path: "v1/ops".into(),
            body: json!({"op": "usage.cap.set", "origin": "user", "idempotency_key": "save-1",
                "params": {"overage_usd": 40.5}}),
        }
    );
}

#[test]
fn off_sends_null_not_zero() {
    let Next::Call { body, .. } = next(&request(None, vec![])) else { panic!("expected a call") };
    assert_eq!(body["params"], json!({"overage_usd": null}));
    assert!(body["params"].get("cap_usd").is_none(), "exactly one of cap_usd and overage_usd");
}

#[test]
fn amounts_cmux_api_refuses_are_not_sent() {
    for (usd, says) in [
        (0.0, "above $0"),
        (-5.0, "above $0"),
        (f64::NAN, "above $0"),
        (f64::INFINITY, "above $0"),
        (1_000_000.01, "at most"),
        (40.555, "dollars and cents"),
    ] {
        match outcome(next(&request(Some(usd), vec![]))) {
            Outcome::Invalid { message } => assert!(message.contains(says), "{usd}: {message}"),
            other => panic!("{usd}: {other:?}"),
        }
    }
    assert!(matches!(next(&request(Some(MAX_USD), vec![])), Next::Call { .. }));
    assert!(matches!(next(&request(Some(0.01), vec![])), Next::Call { .. }));
}

#[test]
fn a_save_needs_a_key() {
    for key in ["", "   ", "a\nb", &"k".repeat(129)] {
        let r = Request { overage_usd: Some(10.0), key: key.into(), steps: vec![] };
        assert!(matches!(outcome(next(&r)), Outcome::Invalid { .. }), "{key:?}");
    }
}

#[test]
fn a_success_reports_the_cap_it_makes() {
    for reply in [
        json!({"ok": true, "value": {"owner": "team:t", "team_cap_usd": 140.0, "overage_usd": 40.0}}),
        json!({"owner": "team:t", "team_cap_usd": 140.0, "overage_usd": 40.0}),
    ] {
        assert_eq!(
            outcome(next(&request(Some(40.0), vec![reply]))),
            Outcome::Saved { overage_usd: Some(40.0), team_cap_usd: Some(140.0) }
        );
    }
}

#[test]
fn turning_overage_off_reads_back_off() {
    let reply = json!({"ok": true, "value": {"owner": "team:t", "team_cap_usd": 100.0, "overage_usd": null}});
    assert_eq!(
        outcome(next(&request(None, vec![reply]))),
        Outcome::Saved { overage_usd: None, team_cap_usd: Some(100.0) }
    );
}

#[test]
fn an_answer_without_overage_keeps_what_was_asked() {
    let reply = json!({"ok": true, "value": {"owner": "team:t", "team_cap_usd": null}});
    assert_eq!(
        outcome(next(&request(Some(25.0), vec![reply]))),
        Outcome::Saved { overage_usd: Some(25.0), team_cap_usd: None }
    );
}

#[test]
fn a_member_hears_only_an_admin_can_change_it() {
    let reply =
        json!({"ok": false, "error": {"code": "team.roles_required", "message": "roles: admin"}});
    assert_eq!(
        outcome(next(&request(Some(40.0), vec![reply]))),
        Outcome::Refused {
            code: "team.roles_required".into(),
            message: "Only a team admin can change the overage limit.".into(),
            retry: false,
        }
    );
}

#[test]
fn refusals_word_the_card_and_say_whether_to_retry() {
    for (reply, code, retry) in [
        (
            json!({"ok": false, "error": {"code": "mutation.indeterminate"}}),
            "mutation.indeterminate",
            true,
        ),
        (json!({"code": "owner.unreachable", "message": "x"}), "owner.unreachable", true),
        (
            json!({"ok": false, "error": {"code": "auth.unauthenticated"}}),
            "auth.unauthenticated",
            false,
        ),
        (
            json!({"ok": false, "error": {"code": "validation.invalid"}}),
            "validation.invalid",
            false,
        ),
        (json!({"ok": false}), "unknown", false),
        (json!({"error": "boom"}), "unknown", false),
    ] {
        match outcome(next(&request(Some(40.0), vec![reply.clone()]))) {
            Outcome::Refused { code: got, message, retry: r } => {
                assert_eq!((got.as_str(), r), (code, retry), "{reply}");
                assert!(!message.is_empty() && !message.contains("x"), "{reply}: {message}");
            }
            other => panic!("{reply}: {other:?}"),
        }
    }
}

#[test]
fn more_replies_than_one_call_is_a_protocol_refusal() {
    let ok = json!({"ok": true, "value": {"team_cap_usd": 1.0}});
    assert!(matches!(
        outcome(next(&request(Some(1.0), vec![ok.clone(), ok]))),
        Outcome::Refused { retry: false, .. }
    ));
}

#[test]
fn the_wire_shape_is_camel_case_and_tagged() {
    let r: Request = serde_json::from_value(json!({"overageUsd": 12.0, "key": "k"})).unwrap();
    assert_eq!(r.overage_usd, Some(12.0));
    let off: Request = serde_json::from_value(json!({"overageUsd": null, "key": "k"})).unwrap();
    assert_eq!(off.overage_usd, None);
    let saved = done(Outcome::Saved { overage_usd: None, team_cap_usd: Some(100.0) });
    assert_eq!(
        serde_json::to_value(saved).unwrap(),
        json!({"next": "done", "outcome": {"kind": "saved", "overageUsd": null, "teamCapUsd": 100.0}})
    );
}
