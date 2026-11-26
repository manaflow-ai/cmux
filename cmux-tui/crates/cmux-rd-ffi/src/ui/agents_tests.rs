//! Parity with `CmuxRemoteAgentShare.redeem`/`post` and `CmuxRemoteShareApproval` as Swift had them.

use serde_json::{Value, json};

use crate::ui::call;

fn ok(op: &str, args: Value) -> Value {
    let request = json!({"op": op, "args": args});
    let reply = call(request.to_string().as_bytes());
    reply.get("ok").cloned().unwrap_or_else(|| panic!("{request} answered {reply}"))
}

#[test]
fn redeem_params_for_this_mac() {
    let base = json!({"ticket": "t1", "allowed": true, "account": "u1",
                      "thisDevice": {"id": "d1", "name": "Studio"}});
    assert_eq!(
        ok("agents.redeemParams", base.clone()),
        json!({"ticket": "t1", "allowed": true, "account": "u1",
               "this_device": {"id": "d1", "name": "Studio"}})
    );
    let mut shared = base.clone();
    shared["alreadyShared"] = json!(true);
    assert_eq!(ok("agents.redeemParams", shared)["already_shared"], json!(true));
}

#[test]
fn redeem_params_for_a_target_carry_the_account_and_never_already_shared() {
    let params = ok(
        "agents.redeemParams",
        json!({"ticket": "t", "allowed": false, "account": "", "thisDevice": {"id": "d", "name": "n"},
               "alreadyShared": true, "target": {"id": "m2", "name": "Laptop"}}),
    );
    assert_eq!(params["target"], json!({"id": "m2", "name": "Laptop", "account": ""}));
    assert!(params.get("already_shared").is_none());
    assert_eq!(params["allowed"], json!(false));
}

#[test]
fn redeem_refused_only_for_another_account() {
    for (error, refused) in [
        ("daemon: agents.other_account", true),
        ("Studio is not a device of this account", true),
        ("unknown method agent.redeem", false),
        ("", false),
    ] {
        assert_eq!(ok("agents.redeemRefused", json!({"error": error})), json!(refused), "{error}");
    }
}

#[test]
fn redeem_grant_only_without_a_dialog() {
    assert_eq!(ok("agents.redeemGrant", json!({"answer": {"dialog": true}})), Value::Null);
    assert_eq!(ok("agents.redeemGrant", json!({"answer": {}})), Value::Null);
    assert_eq!(ok("agents.redeemGrant", json!({"answer": null})), Value::Null);
    assert_eq!(ok("agents.redeemGrant", json!({"answer": {"dialog": "false"}})), Value::Null);
    let notice = json!({"kind": "shared", "device_name": "Studio", "turn_off": "x"});
    assert_eq!(
        ok(
            "agents.redeemGrant",
            json!({"answer": {"dialog": false, "agent": {"session": "s1"}, "agent_label": "fixer",
                              "notice": notice, "action": "share"}}),
        ),
        json!({"session": "s1", "label": "fixer", "notice": notice, "action": "share"})
    );
    assert_eq!(
        ok("agents.redeemGrant", json!({"answer": {"dialog": false}})),
        json!({"session": "", "label": "", "notice": null, "action": ""})
    );
}

#[test]
fn notice_offers_turn_off_only_when_shared_with_a_turn_off() {
    let n = |notice: Value| ok("agents.notice", json!({"notice": notice}));
    assert_eq!(
        n(json!({"kind": "shared", "device_name": "Studio", "turn_off": "share.stop"})),
        json!({"kind": "shared", "device": "Studio", "offersTurnOff": true})
    );
    assert_eq!(
        n(json!({"kind": "shared", "device_name": "Studio"})),
        json!({"kind": "shared", "device": "Studio", "offersTurnOff": false})
    );
    assert_eq!(
        n(json!({"kind": "unshared", "device_name": "Studio", "turn_off": "share.stop"})),
        json!({"kind": "unshared", "device": "Studio", "offersTurnOff": false})
    );
    assert_eq!(n(Value::Null), json!({"kind": "unshared", "device": "", "offersTurnOff": false}));
}

#[test]
fn approval_matches_the_shared_vectors() {
    let vectors: Value =
        serde_json::from_str(include_str!("../../../acpmux/src/share_approval_vectors.json"))
            .expect("vectors");
    for vector in vectors.as_array().expect("array") {
        let a = &vector["approval"];
        let s = |k: &str| a[k].clone();
        let confirmed_at: u64 = a["confirmed_at"].as_str().expect("at").parse().expect("secs");
        let out = ok(
            "agents.approval",
            json!({"target": s("target"), "targetName": s("target_name"), "asker": s("asker"),
                   "askerName": s("asker_name"), "confirmedBy": s("confirmed_by"),
                   "confirmedAt": confirmed_at, "nonce": s("nonce"), "signature": s("signature")}),
        );
        assert_eq!(out["canonical"], vector["canonical"]);
        assert_eq!(&out["wire"], a);
    }
}
