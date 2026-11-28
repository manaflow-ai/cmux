//! The feed push rules, ported with the Swift package's tests
//! (Packages/Shared/CmuxFeedPushCore/Tests, deleted with it).

use cmux_feed_push_core::ops::{OpError, call};
use cmux_feed_push_core::{
    ApnsEnvironment, ApproveMessage, CloudOp, CloudOpReply, FeedAnswer, FeedPushAction,
    FeedPushActionStyle, FeedPushCategory, FeedPushPayload, FeedPushResponse, ShownText,
    limited_utf16,
};
use serde_json::{Value, json};

#[test]
fn categories_match_the_owners_names() {
    // backend apnsPayload: FEED_<KIND upper, non-alnum -> _> for requests, FEED_NOTICE for notices.
    assert_eq!(FeedPushCategory::from_id("FEED_SIGN_IN"), Some(FeedPushCategory::SignIn));
    assert_eq!(FeedPushCategory::ALL.len(), 8);
    let ids: std::collections::BTreeSet<_> = FeedPushCategory::ALL.iter().map(|c| c.id()).collect();
    assert_eq!(ids.len(), 8);
}

#[test]
fn mac_only_kinds_offer_only_open_on_mac() {
    for category in [FeedPushCategory::SignIn, FeedPushCategory::Passkey, FeedPushCategory::Handoff]
    {
        assert_eq!(category.actions(), &[FeedPushAction::OpenOnMac]);
        assert!(category.actions().iter().all(|a| FeedAnswer::for_action(*a, None).is_none()));
    }
    assert!(FeedPushCategory::Choice.actions().is_empty());
    assert!(FeedPushCategory::Notice.actions().is_empty());
}

#[test]
fn answers_have_the_owners_shape() {
    let value = |action, text| FeedAnswer::for_action(action, text).map(|a| a.value());
    assert_eq!(value(FeedPushAction::Allow, None).unwrap()["decision"], "allow");
    assert_eq!(value(FeedPushAction::AllowForSession, None).unwrap()["scope"], "session");
    assert_eq!(value(FeedPushAction::Deny, None).unwrap()["decision"], "deny");
    assert_eq!(value(FeedPushAction::Confirm, None).unwrap()["confirmed"], true);
    assert_eq!(value(FeedPushAction::Cancel, None).unwrap()["confirmed"], false);
    assert_eq!(
        FeedAnswer::for_action(FeedPushAction::Reply, Some("  ship it ")),
        Some(FeedAnswer::Text { value: "ship it".into() })
    );
    assert_eq!(FeedAnswer::for_action(FeedPushAction::Reply, Some("   ")), None);
}

#[test]
fn approvals_need_an_unlocked_phone_denials_do_not() {
    assert_eq!(
        FeedPushAction::Allow.style(),
        FeedPushActionStyle::Answer { destructive: false, requires_unlock: true }
    );
    assert_eq!(
        FeedPushAction::Deny.style(),
        FeedPushActionStyle::Answer { destructive: true, requires_unlock: false }
    );
}

#[test]
fn payload_parses_feed_pushes_only() {
    let info = json!({"aps": {"category": "FEED_APPROVE"}, "cmux": {"feed_item": "fi_1", "kind": "approve", "type": "request"}});
    assert_eq!(
        FeedPushPayload::from_user_info(&info),
        Some(FeedPushPayload {
            item: "fi_1".into(),
            kind: Some("approve".into()),
            r#type: Some("request".into()),
            category: Some(FeedPushCategory::Approve),
        })
    );
    assert_eq!(FeedPushPayload::from_user_info(&json!({"aps": {"alert": "x"}})), None);
    let unknown = json!({"cmux": {"feed_item": "fi_2"}, "aps": {"category": "FEED_REVIEW"}});
    assert_eq!(FeedPushPayload::from_user_info(&unknown).unwrap().category, None);
}

#[test]
fn op_bodies_match_the_contract() {
    let register = CloudOp::register_push_target(
        &[0xAB, 0x01, 0xFF],
        "dev.cmux.ios.iosn2",
        ApnsEnvironment::Development,
        "Aziz",
        "k1",
    );
    let register: Value = serde_json::from_str(&register.body()).unwrap();
    assert_eq!(register["op"], "push.target.register");
    assert_eq!(register["idempotency_key"], "k1");
    assert_eq!(register["origin"], "cli");
    assert_eq!(register["params"]["token"], "ab01ff");
    assert_eq!(register["params"]["environment"], "development");
    let answer = CloudOp::answer("fi_1", &FeedAnswer::Decision { allow: true, scope: None }, "k2");
    let answer: Value = serde_json::from_str(&answer.body()).unwrap();
    assert_eq!(answer["origin"], "user");
    assert_eq!(answer["params"]["item"], "fi_1");
}

fn approve_info() -> Value {
    json!({"aps": {"category": "FEED_APPROVE"}, "cmux": {"feed_item": "fi_9"}})
}

#[test]
fn banner_answers_send_with_a_stable_key() {
    let first = FeedPushResponse::new("FEED_ALLOW", None, &approve_info());
    assert_eq!(first, FeedPushResponse::new("FEED_ALLOW", None, &approve_info()));
    let FeedPushResponse::Send { idempotency_key, answer, .. } = first else {
        panic!("expected send")
    };
    assert_eq!(idempotency_key, "feed-answer-fi_9-FEED_ALLOW");
    assert_eq!(answer, FeedAnswer::Decision { allow: true, scope: None });
}

#[test]
fn taps_and_mac_only_actions_open_the_item() {
    let open = FeedPushResponse::Open { item: "fi_9".into() };
    let info = approve_info();
    assert_eq!(
        FeedPushResponse::new("com.apple.UNNotificationDefaultActionIdentifier", None, &info),
        open
    );
    assert_eq!(FeedPushResponse::new("FEED_OPEN_ON_MAC", None, &info), open);
    assert_eq!(FeedPushResponse::new("FEED_REPLY", Some(" "), &info), open);
    assert_eq!(
        FeedPushResponse::new("FEED_ALLOW", None, &json!({"aps": {}})),
        FeedPushResponse::Ignore
    );
}

#[test]
fn a_domain_refusal_is_not_success() {
    let refused = br#"{"ok":false,"error":{"code":"feed.closed","retryable":false}}"#;
    assert_eq!(
        CloudOpReply::decode(refused),
        CloudOpReply::Rejected { code: "feed.closed".into(), retryable: false }
    );
    assert_eq!(
        CloudOpReply::decode(br#"{"ok":true,"replayed":true}"#),
        CloudOpReply::Committed { replayed: true }
    );
    assert_eq!(
        CloudOpReply::decode(b"<html>"),
        CloudOpReply::Rejected { code: "invalid_reply".into(), retryable: true }
    );
}

#[test]
fn an_action_outside_the_items_category_only_opens_it() {
    // A crafted push with a confirm category cannot be answered with Allow.
    let open = FeedPushResponse::Open { item: "fi_1".into() };
    let confirm = json!({"aps": {"category": "FEED_CONFIRM"}, "cmux": {"feed_item": "fi_1"}});
    assert_eq!(FeedPushResponse::new("FEED_ALLOW", None, &confirm), open);
    assert_eq!(
        FeedPushResponse::new("FEED_ALLOW", None, &json!({"cmux": {"feed_item": "fi_1"}})),
        open
    );
}

#[test]
fn malformed_item_ids_are_not_feed_pushes() {
    let long = format!("fi_{}", "a".repeat(90));
    for bad in ["", "fi_", "FI_x", "fi_a/b", long.as_str()] {
        assert_eq!(
            FeedPushPayload::from_user_info(&json!({"cmux": {"feed_item": bad}})),
            None,
            "{bad}"
        );
    }
}

#[test]
fn different_replies_get_different_keys() {
    let info = json!({"aps": {"category": "FEED_QUESTION"}, "cmux": {"feed_item": "fi_q"}});
    let key = |text| match FeedPushResponse::new("FEED_REPLY", Some(text), &info) {
        FeedPushResponse::Send { idempotency_key, .. } => idempotency_key,
        other => panic!("expected send, got {other:?}"),
    };
    assert_ne!(key("yes"), key("no"));
}

#[test]
fn approval_banner_does_not_offer_the_session_scope() {
    assert_eq!(FeedPushCategory::Approve.actions(), &[FeedPushAction::Allow, FeedPushAction::Deny]);
}

#[test]
fn device_names_are_cut_to_80_utf16_units() {
    let long = "📱".repeat(60); // 120 UTF-16 units
    assert_eq!(limited_utf16(&long, 80).encode_utf16().count(), 80);
}

#[test]
fn shown_text_is_truncated_only_by_the_json_boolean_true() {
    let truncated =
        |json: &str| ShownText::from_action(&serde_json::from_str(json).unwrap()).truncated;
    assert!(truncated(r#"{"truncated": true}"#));
    assert!(!truncated(r#"{"truncated": false}"#));
    assert!(!truncated(r#"{"truncated": 1}"#));
    assert!(!truncated(r#"{"truncated": "true"}"#));
    assert!(!truncated("{}"));
}

#[test]
fn shown_text_canonical_bytes_are_the_swift_ones() {
    // The v2 form the Mac recomputes; fields counted in UTF-8 bytes, inputs in name order.
    let action = json!({"tool": "Bash", "summary": "rm -r", "command": "rm -r tmp",
        "input": {"été": "ok", "path": "tmp", "n": 3}});
    let shown = ShownText::from_action(&action);
    assert_eq!(
        shown.canonical(),
        "cmux-feed-shown-v2\ntool:4:Bash\nsummary:5:rm -r\ncommand:9:rm -r tmp\n\
         input:4:path:3:tmp\ninput:5:été:2:ok\ntruncated:0\n"
    );
    assert_eq!(shown.sha256(), "31a2d58648f1f6c03e5bce43bec4e25849a9a173e2d323e7f55c3cc9587ac0f8");
}

#[test]
fn approve_message_joins_its_fields() {
    let message: ApproveMessage = serde_json::from_value(json!({
        "environment": "prod", "user": "u1", "phone_install": "p1", "mac_install": "m1",
        "item": "fi_1", "shown_sha256": "ab", "decision": "allow", "scope": "", "timestamp_ms": 7
    }))
    .unwrap();
    assert_eq!(message.text(), "cmux-feed-approve-v1\nprod\nu1\np1\nm1\nfi_1\nab\nallow\n\n7");
}

#[test]
fn ops_answer_like_the_types() {
    let response = call(
        "push_response",
        &json!({"action_identifier": "FEED_DENY", "user_info": approve_info()}),
    )
    .unwrap();
    assert_eq!(response["response"], "send");
    assert_eq!(response["idempotency_key"], "feed-answer-fi_9-FEED_DENY");
    let body: Value = serde_json::from_str(response["body"].as_str().unwrap()).unwrap();
    assert_eq!(body["params"]["answer"], json!({"decision": "deny"}));
    let categories = call("categories", &json!({})).unwrap();
    assert_eq!(categories["categories"].as_array().unwrap().len(), 8);
    let reply = call("op_reply", &json!({"body": "<html>"})).unwrap();
    assert_eq!(
        reply,
        json!({"committed": false, "replayed": false, "code": "invalid_reply", "retryable": true})
    );
    assert_eq!(call("nope", &json!({})), Err(OpError::Unknown));
    assert_eq!(call("op_answer", &json!({"item": 1})), Err(OpError::Invalid));
}
