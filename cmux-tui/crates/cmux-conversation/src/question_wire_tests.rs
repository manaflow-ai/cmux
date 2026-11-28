//! question_wire.rs: one encoder for the answers the daemon sends and the app signs.

use serde_json::{Value, json};

use super::*;
use crate::{Question, QuestionAnswer};

fn question(harness: &str, multi: bool) -> Question {
    serde_json::from_value(json!({
        "harness": harness, "session": "sess_mux", "permission": "perm_1",
        "items": [{"id": "q0", "prompt": "Which auth method?", "multi_select": multi,
                   "options": [{"id": "oauth", "label": "OAuth"}, {"id": "keys", "label": "API keys"}]}]
    }))
    .unwrap()
}

fn answer(ids: &[&str], other: Option<&str>) -> QuestionAnswer {
    serde_json::from_value(json!({"selections": {"q0": {"option_ids": ids, "other": other}}}))
        .unwrap()
}

/// The live request acpmux holds for `question` (camelCase flags, as acpmux spells them).
fn request(harness: &str, multi: bool) -> Value {
    json!({
        "toolCall": {"_meta": {"acpmux": {"question": {"harness": harness, "items": [
            {"id": "q0", "prompt": "Which auth method?", "multiSelect": multi, "allowsOther": true,
             "options": [{"id": "oauth", "label": "OAuth"}, {"id": "keys", "label": "API keys"}]}]}}}},
        "options": [{"optionId": "answer", "kind": "allow_once", "name": "Answer"},
                    {"optionId": "skip", "kind": "reject_once", "name": "Skip"}]
    })
}

fn pending(harness: &str, multi: bool) -> Value {
    json!({"permissionId": "perm_1", "personInstance": "0123456789abcdef",
           "decisionNonce": "a".repeat(64), "request": request(harness, multi)})
}

#[test]
fn claude_and_chief_key_joined_labels_by_prompt_in_option_order() {
    for harness in ["claude", "chief"] {
        let q = question(harness, true);
        let encoded = acpmux_answers(&q, &answer(&["keys", "oauth"], Some("  SSO "))).unwrap();
        assert_eq!(encoded, json!({"Which auth method?": "OAuth, API keys, SSO"}));
    }
}

#[test]
fn codex_keys_a_label_list_by_item_id() {
    let encoded = acpmux_answers(&question("codex", false), &answer(&["oauth"], None)).unwrap();
    assert_eq!(encoded, json!({"q0": {"answers": ["OAuth"]}}));
}

#[test]
fn a_blank_other_is_dropped_and_an_empty_answer_refused() {
    let q = question("claude", false);
    assert_eq!(
        acpmux_answers(&q, &answer(&["oauth"], Some("   "))).unwrap(),
        json!({"Which auth method?": "OAuth"})
    );
    assert_eq!(acpmux_answers(&q, &answer(&[], Some(" "))), Err(WireError::InvalidAnswer));
    let none: QuestionAnswer = serde_json::from_value(json!({"selections": {}})).unwrap();
    assert_eq!(acpmux_answers(&q, &none), Err(WireError::InvalidAnswer));
}

#[test]
fn acp_harness_and_shared_prompts_are_refused() {
    assert_eq!(
        acpmux_answers(&question("acp", false), &answer(&["oauth"], None)),
        Err(WireError::UnsupportedHarness)
    );
    let mut q = question("claude", false);
    let mut twin = q.items[0].clone();
    twin.id = "q1".into();
    q.items.push(twin);
    let both: QuestionAnswer = serde_json::from_value(json!({"selections": {
        "q0": {"option_ids": ["oauth"]}, "q1": {"option_ids": ["keys"]}}}))
    .unwrap();
    assert_eq!(acpmux_answers(&q, &both), Err(WireError::Ambiguous));
}

#[test]
fn the_stored_question_must_be_the_live_pending_request() {
    let q = question("claude", false);
    assert_eq!(check_request(&q, &request("claude", false)), Ok(()));
    assert_eq!(check_request(&q, &request("claude", true)), Err(WireError::Stale));
    assert_eq!(check_request(&q, &request("codex", false)), Err(WireError::Stale));
    let tool = json!({"toolCall": {"title": "Run ls"}, "options": []});
    assert_eq!(check_request(&q, &tool), Err(WireError::NotQuestion));
    let mut answered = q;
    answered.state = QuestionState::Cancelled;
    assert_eq!(check_request(&answered, &request("claude", false)), Err(WireError::Stale));
}

#[test]
fn the_answer_goes_with_the_one_allow_once_option() {
    assert_eq!(answer_option(&request("claude", false)), Ok("answer".into()));
    let two = json!({"options": [{"optionId": "a", "kind": "allow_once"}, {"optionId": "b", "kind": "allow_once"}]});
    assert_eq!(answer_option(&two), Err(WireError::Stale));
    let always = json!({"options": [{"optionId": "a", "kind": "allow_always"}]});
    assert_eq!(answer_option(&always), Err(WireError::Stale));
}

#[test]
fn an_unsigned_decision_binds_the_live_prompt_and_the_exact_answers() {
    let q = question("chief", false);
    let decision =
        unsigned_decision(&q, &answer(&["keys"], None), &pending("chief", false)).unwrap();
    assert_eq!(
        decision,
        UnsignedDecision {
            session: "sess_mux".into(),
            permission: "perm_1".into(),
            option_id: "answer".into(),
            instance: "0123456789abcdef".into(),
            decision_nonce: "a".repeat(64),
            answers: json!({"Which auth method?": "API keys"}),
        }
    );
    // The app reads these field names (HomeQuestionDecision.swift).
    assert_eq!(serde_json::to_value(&decision).unwrap()["decision_nonce"], json!("a".repeat(64)));

    let mut other = pending("chief", false);
    other["permissionId"] = json!("perm_2");
    assert_eq!(unsigned_decision(&q, &answer(&["keys"], None), &other), Err(WireError::Stale));
    let mut no_nonce = pending("chief", false);
    no_nonce["decisionNonce"] = json!("");
    assert_eq!(unsigned_decision(&q, &answer(&["keys"], None), &no_nonce), Err(WireError::Stale));
    let mut unbound = q;
    unbound.permission = None;
    assert_eq!(
        unsigned_decision(&unbound, &answer(&["keys"], None), &pending("chief", false)),
        Err(WireError::NoRequest)
    );
}

#[test]
fn a_native_approval_card_is_told_from_a_question() {
    let card = |id: &str, options: &[&str], allows_other: bool| -> Question {
        let options: Vec<Value> = options.iter().map(|id| json!({"id": id, "label": id})).collect();
        serde_json::from_value(json!({
            "harness": "chief", "session": "sess_mux", "permission": "perm_1",
            "items": [{"id": id, "prompt": "Run it?", "multi_select": false,
                       "allows_other": allows_other, "options": options}]
        }))
        .unwrap()
    };
    let digest = format!("approval:{}", "0f".repeat(32));
    assert!(is_native_approval(&card(&digest, &["deny", "allow"], false)));
    assert!(!is_native_approval(&card(&digest, &["allow", "deny"], true)));
    assert!(!is_native_approval(&card(&digest, &["allow", "maybe"], false)));
    assert!(!is_native_approval(&card("approval:short", &["allow", "deny"], false)));
    assert!(!is_native_approval(&card(
        &format!("approval:{}", "0F".repeat(32)),
        &["allow", "deny"],
        false
    )));
    assert!(!is_native_approval(&question("chief", false)));
    let mut codex = card(&digest, &["allow", "deny"], false);
    codex.harness = QuestionHarness::Codex;
    assert!(!is_native_approval(&codex));
}

/// The golden bytes the app checks too (CmuxNextAgentPaneTests, CanonicalJSONFixtureTests).
#[test]
fn canonical_json_matches_the_golden_fixture() {
    let fixture: Value =
        serde_json::from_str(include_str!("../tests/fixtures/canonical_json.json")).unwrap();
    let cases = fixture["cases"].as_array().unwrap();
    assert!(cases.len() >= 5);
    for case in cases {
        let name = case["name"].as_str().unwrap();
        assert_eq!(canonical_json(&case["value"]), case["canonical"].as_str().unwrap(), "{name}");
    }
}
