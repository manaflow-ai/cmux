use super::*;

#[test]
fn a_viewer_lives_by_id_until_closed() {
    let mut m = RdHub::new();
    assert!(RdHub::serves("rd_hub_viewer_event") && !RdHub::serves("mac_screen_offer"));
    let open = m.call("rd_hub_viewer_open", json!({"id": "t1", "device_id": "host"})).unwrap();
    assert_eq!(open["phase"], json!({"phase": "idle"}));
    assert!(
        m.call("rd_hub_viewer_event", json!({"id": "t9", "event": {"event": "denied"}})).is_err()
    );
    let reply = m
        .call(
            "rd_hub_viewer_event",
            json!({"id": "t1", "event": {"event": "request", "scope": "view", "hub": true}}),
        )
        .unwrap();
    assert_eq!(reply["state"]["phase"], json!({"phase": "requesting", "scope": "view"}));
    assert_eq!(
        reply["effects"].as_array().unwrap().last().unwrap(),
        &json!({"effect": "send_request", "scope": "view"})
    );
    let ticket = json!({"session_id": "s1", "role": "viewer", "peer_id": "host", "scope": "view"});
    assert_eq!(
        m.call("rd_hub_viewer_accepts", json!({"id": "t1", "ticket": ticket})).unwrap()["accepts"],
        true
    );
    let reply = m
        .call(
            "rd_hub_viewer_event",
            json!({"id": "t1", "event": {"event": "request_returned", "scope": "view", "hub": true,
                "answer": {"ok": {"id": "s1", "state": "pending", "scope": null}}}}),
        )
        .unwrap();
    assert_eq!(reply["state"]["phase"]["phase"], "waiting_for_approval");
    let reply = m
        .call(
            "rd_hub_viewer_event",
            json!({"id": "t1", "event": {"event": "request_returned", "scope": "view", "hub": true,
                "answer": {"err": {"error": "server", "status": 403, "code": "permission_none", "message": ""}}}}),
        )
        .unwrap();
    assert_eq!(reply["state"]["phase"]["phase"], "waiting_for_approval", "only while requesting");
    assert_eq!(m.call("rd_hub_viewer_state", json!({"id": "t1"})).unwrap()["last_scope"], "view");
    assert_eq!(m.call("rd_hub_viewer_close", json!({"id": "t1"})).unwrap()["closed"], true);
    assert!(m.call("rd_hub_viewer_state", json!({"id": "t1"})).is_err());
    assert!(m.call("rd_hub_nope", Value::Null).is_err());
}

#[test]
fn the_host_serves_and_names_its_viewer() {
    let mut m = RdHub::new();
    assert_eq!(
        m.call("rd_hub_host_state", Value::Null).unwrap()["no_session_reason"]["key"],
        "macScreen.indicator.noSession"
    );
    let ticket = json!({"session_id": "s1", "scope": "view", "viewer_id": "v1", "viewer_name": "Studio", "own_account": true});
    let reply = m
        .call(
            "rd_hub_host_event",
            json!({"event": "serve", "ticket": ticket, "hub": true, "consent_gate": true}),
        )
        .unwrap();
    assert_eq!(reply["effects"][0]["effect"], "start");
    assert_eq!(reply["no_session_reason"], Value::Null);
    let reply = m
        .call("rd_hub_host_event", json!({"event": "viewer_connected", "session_id": "s1"}))
        .unwrap();
    assert_eq!(reply["indicator"]["key"], "macScreen.indicator.viewing");
    let reply = m.call("rd_hub_host_event", json!({"event": "stop", "hub": true})).unwrap();
    assert_eq!(
        reply["effects"],
        json!([{"effect": "end_then_stop", "session_id": "s1", "reason": "host_stopped"}])
    );
}

#[test]
fn the_stateless_rules_answer() {
    let mut m = RdHub::new();
    let end = m.call("rd_hub_end_reason", json!({"reason": "failed: no helper"})).unwrap();
    assert_eq!(
        (end["reason"].clone(), end["failure_detail"].clone()),
        (json!("failed"), json!("no helper"))
    );
    assert_eq!(m.call("rd_hub_end_reason", json!({"reason": null})).unwrap()["reason"], "other");
    assert_eq!(m.call("rd_hub_failure", json!({"why": "a\nb"})).unwrap()["reason"], "failed: a b");
    let r = m.call("rd_hub_refusal", json!({"error": {"error": "server", "status": 404, "code": "not_found", "message": ""}})).unwrap();
    assert_eq!(r, json!({"refusal": {"refusal": "not_found"}, "can_retry": false}));
    let a =
        m.call("rd_hub_approval", json!({"choice": "always_full", "requested": "view"})).unwrap();
    assert_eq!(
        a["answer"],
        json!({"decision": "always", "scope": "view", "then_permission": "full"})
    );
    let levels = m.call("rd_hub_access", Value::Null).unwrap();
    assert_eq!(levels["levels"].as_array().unwrap().len(), 4);
    assert_eq!(levels["choices"][0]["title"]["text"], "Deny");
    assert_eq!(
        m.call("rd_hub_scope_to_request", json!({"last": "full", "access": "view"})).unwrap()["scope"],
        "view"
    );
    let s = m
        .call("rd_hub_sharing", json!({"shared": false, "grant_known": true, "screen_recording": true, "turned_off": false}))
        .unwrap();
    assert_eq!(s, json!({"step": "turn_on", "state": "off"}));
    assert_eq!(
        m.call("rd_hub_startup_message", json!({"startup_failed": false})).unwrap()["message"],
        Value::Null
    );
}
