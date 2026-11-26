use super::*;
use serde_json::json;

const REQ: &str = "apr_1";
const OP: &str = "cloud.machine.create";

fn request(steps: Vec<Value>) -> Request {
    Request {
        request: REQ.into(),
        op: OP.into(),
        params: json!({"name": "box", "size": {"cpu": 2}}),
        team: "team_a".into(),
        steps,
    }
}

fn call(next: Next) -> (String, Value) {
    match next {
        Next::Call { path, body } => (path, body),
        Next::Done { outcome } => panic!("expected a call, got {outcome:?}"),
    }
}

fn done(next: Next) -> Outcome {
    match next {
        Next::Done { outcome } => outcome,
        Next::Call { path, body } => panic!("expected done, got {path} {body}"),
    }
}

fn item(team: &str, digest: &str) -> Value {
    json!({"id": "fi_1", "kind": "approve",
        "prompt": {"action": {"type": "tool", "tool": OP, "input": {"approval": {"team": team, "request": REQ, "digest": digest}}}},
        "poster": {"kind": "integration", "scope": format!("system:cloud:{team}")}})
}

fn held(state: &str) -> Value {
    json!({"value": {"op": OP, "state": state, "params": {"size": {"cpu": 2}, "name": "box"}, "digest": "dg_1"}})
}

#[test]
fn the_first_call_is_the_one_call_approve() {
    let (path, body) = call(next(&request(vec![])));
    assert_eq!(path, "v1/ops");
    assert_eq!(
        body,
        json!({"op": "integration.approval.approve", "origin": "user", "idempotency_key": "approve:apr_1",
            "params": {"request": REQ, "op": OP, "params": {"name": "box", "size": {"cpu": 2}}, "team": "team_a"}})
    );
}

#[test]
fn the_one_call_answer_carries_the_machine() {
    let reply = json!({"ok": true, "value": {"request": REQ, "answered": "here", "state": "done",
        "reply": {"ok": true, "value": {"machine": {"id": "vm_1"}}}}});
    assert_eq!(
        done(next(&request(vec![reply]))),
        Outcome::Approved { reply: Some(json!({"machine": {"id": "vm_1"}})) }
    );
}

#[test]
fn a_run_still_going_or_refused_carries_no_reply_so_the_create_is_retried() {
    for value in [
        json!({"request": REQ, "answered": "here", "state": "running"}),
        json!({"request": REQ, "answered": "here", "state": "done", "reply": {"ok": false, "error": {"code": "cloud.quota.exceeded"}}}),
    ] {
        let reply = json!({"ok": true, "value": value});
        assert_eq!(done(next(&request(vec![reply]))), Outcome::Approved { reply: None });
    }
}

#[test]
fn answered_elsewhere_is_answered_with_its_reply() {
    let reply = json!({"ok": true, "value": {"request": REQ, "answered": "elsewhere", "state": "done",
        "reply": {"ok": true, "value": {"machine": {"id": "vm_1"}}}}});
    assert_eq!(
        done(next(&request(vec![reply]))),
        Outcome::AnsweredElsewhere { reply: Some(json!({"machine": {"id": "vm_1"}})) }
    );
}

#[test]
fn a_mismatch_of_the_one_call_is_the_mismatch_with_no_fallback() {
    let reply = json!({"ok": false, "error": {"code": "approval.mismatch", "details": {"reason": "params"}}});
    assert_eq!(done(next(&request(vec![reply]))), Outcome::Mismatch { reason: "params".into() });
    let other = json!({"ok": false, "error": {"code": "feed.closed"}});
    assert_eq!(done(next(&request(vec![other]))), Outcome::Refused { code: "feed.closed".into() });
}

#[test]
fn a_server_without_it_falls_back_to_the_three_calls() {
    for refusal in [
        json!({"ok": false, "error": {"code": "approval.one_call_off"}}),
        json!({"ok": false, "error": {"code": "validation.invalid", "message": "unknown mutation integration.approval.approve"}}),
        json!({"code": "validation.invalid", "message": "unknown mutation integration.approval.approve"}),
    ] {
        let (path, body) = call(next(&request(vec![refusal.clone()])));
        assert_eq!(path, "v1/read");
        assert_eq!(body, json!({"op": "integration.approval.get", "params": {"request": REQ}}));
        let (path, body) = call(next(&request(vec![refusal.clone(), held("pending")])));
        assert_eq!(path, "v1/read");
        assert_eq!(
            body,
            json!({"op": "feed.list", "params": {"state": "open", "type": "request", "kind": "approve", "poster_kind": "integration", "limit": 100}})
        );
        let open = json!({"value": {"items": [item("team_a", "dg_1")]}});
        let (path, body) =
            call(next(&request(vec![refusal.clone(), held("pending"), open.clone()])));
        assert_eq!(path, "v1/ops");
        assert_eq!(
            body,
            json!({"op": "feed.answer", "origin": "user", "idempotency_key": "approve:apr_1",
                "params": {"item": "fi_1", "answer": {"decision": "allow", "scope": "once"}}})
        );
        let answered = json!({"ok": true});
        assert_eq!(
            done(next(&request(vec![refusal, held("pending"), open, answered]))),
            Outcome::Approved { reply: None }
        );
    }
}

#[test]
fn the_fallback_keeps_every_check() {
    let off = json!({"ok": false, "error": {"code": "approval.one_call_off"}});
    let with = |steps: Vec<Value>| done(next(&request([vec![off.clone()], steps].concat())));
    let mut other_op = held("pending");
    other_op["value"]["op"] = json!("cloud.machine.delete");
    assert_eq!(with(vec![other_op]), Outcome::Mismatch { reason: "op".into() });
    assert_eq!(with(vec![held("done")]), Outcome::Mismatch { reason: "state".into() });
    let mut other_params = held("pending");
    other_params["value"]["params"] = json!({"name": "other"});
    assert_eq!(with(vec![other_params]), Outcome::Mismatch { reason: "params".into() });
    let mut no_digest = held("pending");
    no_digest["value"].as_object_mut().unwrap().remove("digest");
    assert_eq!(with(vec![no_digest]), Outcome::Mismatch { reason: "digest".into() });
    // No open item of the create's team: the closed list decides answered elsewhere or the closed-item mismatch.
    let other_team = json!({"value": {"items": [item("team_b", "dg_1")]}});
    let (_, closed) = call(next(&request(vec![off.clone(), held("pending"), other_team.clone()])));
    assert_eq!(closed["params"]["state"], "closed");
    assert_eq!(closed["params"]["order"], "recent");
    assert_eq!(
        with(vec![held("pending"), other_team.clone(), json!({"value": {"items": []}})]),
        Outcome::Mismatch { reason: CLOSED_ITEM.into() }
    );
    assert_eq!(
        with(vec![
            held("pending"),
            other_team,
            json!({"value": {"items": [item("team_a", "dg_1")]}})
        ]),
        Outcome::AnsweredElsewhere { reply: None }
    );
    let wrong_digest = json!({"value": {"items": [item("team_a", "dg_2")]}});
    assert_eq!(
        with(vec![held("pending"), wrong_digest.clone(), wrong_digest]),
        Outcome::Mismatch { reason: CLOSED_ITEM.into() }
    );
    // A refused read or answer is refused with its code.
    assert_eq!(
        with(vec![json!({"error": {"code": "auth.forbidden"}})]),
        Outcome::Refused { code: "auth.forbidden".into() }
    );
    let open = json!({"value": {"items": [item("team_a", "dg_1")]}});
    assert_eq!(
        with(vec![held("pending"), open, json!({"ok": false, "error": {"code": "feed.closed"}})]),
        Outcome::Refused { code: "feed.closed".into() }
    );
}

#[test]
fn an_empty_team_never_matches_an_item() {
    let off = json!({"ok": false, "error": {"code": "approval.one_call_off"}});
    let mut r = request(vec![
        off,
        held("pending"),
        json!({"value": {"items": [item("", "dg_1")]}}),
        json!({"value": {"items": []}}),
    ]);
    r.team = String::new();
    assert_eq!(done(next(&r)), Outcome::Mismatch { reason: CLOSED_ITEM.into() });
}
