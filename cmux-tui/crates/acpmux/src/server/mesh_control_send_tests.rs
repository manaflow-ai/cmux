use super::*;

/// A start carries this Mac's answer over whatever its caller put there; its other fields stay.
#[test]
fn a_start_carries_this_macs_answer_not_the_callers() {
    let caller = json!({"cwd": "/w", "_meta": {"acpmux": {"cmuxTools": "on", "harness": "codex"}}});
    let params = start_params(&caller, "off").unwrap();
    assert_eq!(params["_meta"]["acpmux"]["cmuxTools"], "off");
    assert_eq!(params["_meta"]["acpmux"]["harness"], "codex");
    assert_eq!(params["cwd"], "/w");
    assert_eq!(
        start_params(&json!({"cwd": "/w"}), "on").unwrap()["_meta"]["acpmux"]["cmuxTools"],
        "on"
    );
    assert!(start_params(&json!("x"), "on").is_err());
}

fn receipt(state: &str, detail: Option<&str>) -> crate::mesh::Receipt {
    serde_json::from_value(json!({"messageId": "msg_1", "state": state, "detail": detail})).unwrap()
}

/// A start through the hub answers as a peer's start does once the machine there started it,
/// and says why it did not otherwise.
#[test]
fn a_start_through_the_hub_answers_as_a_peers_start() {
    let v = started(receipt("delivered", Some("s-1")), "lane-17", Some("w"), "k").unwrap();
    assert_eq!(v["sessionId"], "s-1");
    assert_eq!(v["peer"], "lane-17");
    assert_eq!(v["via"], "hub");
    assert_eq!(v["_meta"]["acpmux"]["name"], "w");
    assert_eq!(crate::session_identity::routed_id(&v).unwrap(), "lane-17/s-1");
    let refused = started(receipt("refused", Some("no")), "lane-17", None, "k").unwrap_err();
    assert!(refused.message.contains("no"), "{}", refused.message);
    let pending = started(receipt("leased", None), "lane-17", None, "key-1").unwrap_err();
    assert!(pending.message.contains("msg_1"), "{}", pending.message);
}
