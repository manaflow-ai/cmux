use super::*;

fn routed(request: Value) -> Routed {
    route(&request).expect("routed")
}

fn refused_code(request: Value) -> String {
    route(&request).expect_err("refused")["error"]["code"].as_str().unwrap().to_owned()
}

#[test]
fn reads_go_to_v1_read_without_a_key() {
    let r = routed(json!({"op": "automation.list", "params": {"limit": 50}}));
    assert_eq!(r.path, "/v1/read");
    assert_eq!(r.body["op"], "automation.list");
    assert_eq!(r.body["params"]["limit"], 50);
    assert!(r.body.get("idempotency_key").is_none());
    let audit = routed(json!({"op": "automation.audit.list", "params": {}}));
    assert_eq!(audit.path, "/v1/read");
}

#[test]
fn a_missing_params_is_an_empty_object() {
    assert_eq!(routed(json!({"op": "automation.list"})).body["params"], json!({}));
    assert_eq!(refused_code(json!({"op": "automation.list", "params": [1]})), "invalid_params");
}

#[test]
fn mutations_go_to_v1_ops_with_the_callers_key() {
    let r = routed(
        json!({"op": "automation.run", "params": {"automation": "auto_x"}, "idempotency_key": "k-1"}),
    );
    assert_eq!(r.path, "/v1/ops");
    assert_eq!(r.body["idempotency_key"], "k-1");
    assert_eq!(r.body["origin"], "cli");
}

#[test]
fn teleport_steps_go_to_v1_ops_with_their_key() {
    for op in [
        "automation.import",
        "automation.teleport.begin",
        "automation.teleport.complete",
        "automation.teleport.abort",
    ] {
        let r = routed(
            json!({"op": op, "params": {"automation": "auto_x"}, "idempotency_key": "teleport:tp_1"}),
        );
        assert_eq!(r.path, "/v1/ops", "{op}");
        assert_eq!(r.body["idempotency_key"], "teleport:tp_1");
    }
}

#[test]
fn a_mutation_without_a_key_is_refused_before_any_call() {
    for op in [
        "automation.create",
        "automation.update",
        "automation.delete",
        "automation.run",
        "automation.import",
        "automation.teleport.begin",
    ] {
        assert_eq!(refused_code(json!({"op": op, "params": {}})), "invalid_params", "{op}");
    }
    let long = "k".repeat(201);
    assert_eq!(
        refused_code(json!({"op": "automation.run", "idempotency_key": long})),
        "invalid_params"
    );
    let most = "k".repeat(200);
    assert_eq!(routed(json!({"op": "automation.run", "idempotency_key": most})).path, "/v1/ops");
}

#[test]
fn other_ops_are_not_forwarded() {
    for op in ["feed.post", "team.members.remove", "automation.deploy", "automation.settings.set"] {
        assert_eq!(
            refused_code(json!({"op": op, "params": {}, "idempotency_key": "k"})),
            "automation.op_not_allowed"
        );
    }
    assert_eq!(refused_code(json!({"op": "", "idempotency_key": "k"})), "invalid_params");
    assert_eq!(refused_code(json!([1])), "invalid_params");
}

#[test]
fn a_value_is_passed_on() {
    let a = answer(200, br#"{"ok":true,"value":{"automations":[]}}"#);
    assert_eq!(a, json!({"ok": true, "value": {"automations": []}}));
    assert_eq!(answer(200, br#"{"revision":"r"}"#), json!({"ok": true, "value": null}));
}

#[test]
fn a_refusal_keeps_its_details() {
    let body = br#"{"ok":false,"error":{"code":"automation.plan.required","message":"the free plan has 1 Cloud job","details":{"plan":"pro","checkout":"https://api.test/v1/billing/plan/x.y"}}}"#;
    let a = answer(200, body);
    assert_eq!(a["ok"], false);
    assert_eq!(a["error"]["code"], "automation.plan.required");
    assert_eq!(a["error"]["details"]["checkout"], "https://api.test/v1/billing/plan/x.y");
}

#[test]
fn a_failure_without_an_error_object_is_never_reported_as_success() {
    for (status, body) in [
        (401, &br#"{"error":"Unauthorized"}"#[..]),
        (500, b"{}"),
        (200, br#"{"ok":false}"#),
        (502, b"<html>bad gateway</html>"),
    ] {
        let a = answer(status, body);
        assert_eq!(a["ok"], false, "{status}");
        assert!(a["error"]["code"].is_string(), "{status}");
    }
    assert_eq!(answer(401, br#"{"error":"Unauthorized"}"#)["error"]["message"], "Unauthorized");
    assert_eq!(answer(502, b"<html>")["error"]["code"], "http_502");
    assert_eq!(answer(200, b"[1]")["error"]["code"], "owner.bad_reply");
}
