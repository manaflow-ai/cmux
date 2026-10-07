//! Tests for `question_answer.rs`.

use super::question_answer::*;
use serde_json::{Value, json};

fn claude() -> Value {
    json!({"harness": "claude", "agent": "Claude Code", "items": [
        {"id": "q0", "header": "Auth", "prompt": "Which auth?", "multiSelect": false, "allowsOther": true,
         "options": [{"id": "OAuth", "label": "OAuth", "detail": "Delegated"}, {"id": "Keys", "label": "Keys"}]},
        {"id": "q1", "prompt": "Which checks?", "multiSelect": true, "allowsOther": true,
         "options": [{"id": "Lint", "label": "Lint"}, {"id": "Test", "label": "Test"}, {"id": "Docs", "label": "Docs"}]}]})
}

fn codex() -> Value {
    json!({"harness": "codex", "agent": "Codex", "items": [
        {"id": "name", "prompt": "Name?", "options": [], "multiSelect": false, "allowsOther": true},
        {"id": "env", "prompt": "Env=where?", "multiSelect": false, "allowsOther": false,
         "options": [{"id": "prod", "label": "Prod"}, {"id": "dev", "label": "Dev"}]}]})
}

fn args(list: &[&str]) -> Vec<String> {
    list.iter().map(|s| s.to_string()).collect()
}

#[test]
fn a_key_names_an_item_by_id_prompt_or_header() {
    let q = claude();
    assert_eq!(find_item(&q, "q1"), Ok(1));
    assert_eq!(find_item(&q, "Which auth?"), Ok(0));
    assert_eq!(find_item(&q, "auth"), Ok(0));
    assert_eq!(find_item(&q, "which checks?"), Ok(1));
    assert!(find_item(&q, "nope").unwrap_err().contains("Which auth?"));
}

#[test]
fn a_value_maps_to_labels_ids_or_other_text() {
    let q = claude();
    let list = items(&q);
    assert_eq!(parse_choice(&list[0], "keys"), Ok(Choice { options: vec![1], other: None }));
    assert_eq!(
        parse_choice(&list[1], "Lint, docs"),
        Ok(Choice { options: vec![0, 2], other: None })
    );
    assert_eq!(
        parse_choice(&list[1], "Lint, my own"),
        Ok(Choice { options: vec![0], other: Some("my own".into()) })
    );
    // A single select takes exactly one choice.
    assert!(parse_choice(&list[0], "OAuth, Keys").is_err());
    assert!(parse_choice(&list[0], " ").is_err());
    // No Other row: anything that is not an option is an error naming the options.
    let c = codex();
    let err = parse_choice(&items(&c)[1], "staging").unwrap_err();
    assert!(err.contains("Prod") && err.contains("Dev"), "{err}");
    assert_eq!(parse_choice(&items(&c)[1], "dev"), Ok(Choice { options: vec![1], other: None }));
}

#[test]
fn answers_use_the_asking_harness_shape() {
    let q = claude();
    let answers = encode(
        &q,
        &[
            Choice { options: vec![1], other: None },
            Choice { options: vec![0, 2], other: Some("mine".into()) },
        ],
    );
    assert_eq!(answers, json!({"Which auth?": "Keys", "Which checks?": "Lint, Docs, mine"}));
    let c = codex();
    let answers = encode(
        &c,
        &[
            Choice { options: vec![], other: Some("ledger".into()) },
            Choice { options: vec![0], other: None },
        ],
    );
    assert_eq!(answers, json!({"name": {"answers": ["ledger"]}, "env": {"answers": ["Prod"]}}));
}

#[test]
fn every_item_must_be_answered_once() {
    let q = claude();
    let err = parse_answers(&q, &args(&["q0=Keys"])).unwrap_err();
    assert!(err.contains("Which checks?"), "{err}");
    assert!(parse_answers(&q, &args(&["q0=Keys", "auth=OAuth", "q1=Lint"])).is_err());
    assert!(parse_answers(&q, &args(&["Keys"])).is_err());
    assert_eq!(
        parse_answers(&q, &args(&["auth=Keys", "Which checks?=Test,Docs"])),
        Ok(json!({"Which auth?": "Keys", "Which checks?": "Test, Docs"}))
    );
    // A prompt that holds '=' still matches.
    assert_eq!(
        parse_answers(&codex(), &args(&["name=a=b", "Env=where?=Prod"])),
        Ok(json!({"name": {"answers": ["a=b"]}, "env": {"answers": ["Prod"]}}))
    );
}

#[test]
fn the_usage_lists_numbered_options_and_the_command() {
    let text = usage(&claude(), "s1");
    assert!(text.contains("1. OAuth"), "{text}");
    assert!(text.contains("3. Docs"), "{text}");
    assert!(
        text.contains("acpmux answer s1 --answer \"q0=<choice>\" --answer \"q1=<choice>\""),
        "{text}"
    );
}

#[test]
fn the_question_is_read_from_the_request_meta() {
    let request = json!({"toolCall": {"_meta": {"acpmux": {"question": claude()}}}});
    assert_eq!(question(&request).map(|q| q["harness"].clone()), Some(json!("claude")));
    assert!(question(&json!({"toolCall": {}})).is_none());
}

#[test]
fn pending_hint_names_answer_for_a_question_and_allow_for_a_tool() {
    let question = json!({"toolCall": {"_meta": {"acpmux": {"question": claude()}}},
                          "options": [{"optionId": "allow_once", "kind": "allow_once"}]});
    let hint = pending_hint(&question, "s1");
    assert!(hint.contains("acpmux session answer s1 --answer \"Auth=<choice>\""), "{hint}");
    assert!(hint.contains("acpmux session deny s1"), "{hint}");
    assert!(!hint.contains("allow"), "{hint}");
    let tool = json!({"toolCall": {"kind": "execute"},
                      "options": [{"optionId": "yes", "kind": "allow_once"}, {"optionId": "no", "kind": "reject_once"}]});
    assert_eq!(
        pending_hint(&tool, "s1"),
        "acpmux session allow s1 [yes|no] | acpmux session deny s1"
    );
}
