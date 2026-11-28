use super::*;

#[test]
fn checks_and_fills_the_machine() {
    let ask = check_ask(&json!({"vcpu": 64, "for": "cargo build", "until": "2h"})).unwrap();
    let op = request(&ask, "vm_1");
    assert_eq!(op.op, OP);
    assert_eq!(
        op.params,
        json!({"vcpu": 64, "for": "cargo build", "until": "2h", "machine": "vm_1"})
    );
    // A caller naming a machine does not choose it.
    let ask = check_ask(&json!({"vcpu": 4, "for": "x", "machine": "vm_other"})).unwrap();
    assert_eq!(request(&ask, "vm_1").params["machine"], "vm_1");
}

#[test]
fn refuses_bad_asks() {
    assert!(check_ask(&json!({"for": "x"})).is_err());
    assert!(check_ask(&json!({"vcpu": 0, "for": "x"})).is_err());
    assert!(check_ask(&json!({"vcpu": 4})).is_err());
    assert!(check_ask(&json!({"vcpu": 4, "for": "x", "kind": "tpu"})).is_err());
    assert!(check_ask(&json!({"vcpu": 4, "for": "x", "fanout": 65})).is_err());
}

#[test]
fn replies() {
    let body =
        json!({"ok": true, "value": {"outcome": "grow", "message": "Growing", "machine": "vm_1"}});
    let reply = reply_for(&Answer::Http { status: 200, body });
    assert_eq!(reply["ok"], true);
    assert_eq!(reply["outcome"], "grow");
    let body = json!({"ok": false, "error": {"code": "cloud.spend_cap.reached", "message": "cap"}});
    let reply = reply_for(&Answer::Http { status: 402, body });
    assert_eq!(reply["error"]["code"], "cloud.spend_cap.reached");
    assert_eq!(reply_for(&Answer::Transport)["error"]["code"], "machine.unreachable");
}
