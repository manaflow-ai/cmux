//! `cmux agent explain`: the words it takes, how it joins the daemon's
//! recorded reason with the journal records that reason names, and its text.

use std::collections::HashMap;

use serde_json::{Value, json};

use super::{explain_value, human, parse};

const TERMINAL: &str = "term_00000000000000000000000000000e51";
const NOW: u64 = 20_000;

fn words(text: &str) -> Vec<String> {
    text.split_whitespace().map(str::to_owned).collect()
}

fn snapshot() -> Value {
    json!({
        "session": {"id": "session_00000000000000000000000000000001"},
        "terminals": [{"id": TERMINAL, "tab_id": "tab_1", "title": "claude"}],
        "tabs": [{"id": "tab_1", "name": "alpha", "pane_id": "pane_1", "content_id": TERMINAL}],
        "agents": [{
            "terminal_id": TERMINAL,
            "state": "blocked",
            "source": "hook",
            "updated_at_ms": "12150",
            "extra": {"agent": "claude"},
        }],
        "notifications": [],
    })
}

/// A `list-agents` row: the hook's dialog holds while the screen already
/// shows the prompt again (no hook said the dialog closed).
fn row() -> Value {
    json!({
        "terminal_id": TERMINAL,
        "state": "blocked",
        "status": "blocked",
        "source": "hook",
        "since_ms": 12150,
        "updated_at_ms": 12150,
        "state_reason": {
            "since_ms": "12150",
            "updated_at_ms": "12150",
            "cause": {
                "sequence": "2",
                "at_ms": "12150",
                "kind": "agent.permission.requested",
                "event": "PermissionRequest",
                "decision": "hook",
            },
            "previous": {
                "state": "working",
                "source": "hook",
                "since_ms": "10000",
                "until_ms": "12150",
            },
            "screen": {
                "state": "idle",
                "producer": "agent-screen-detection",
                "observed_at_ms": "12500",
                "sequence": "3",
                "rule": "live_prompt_box",
            },
        },
    })
}

fn records() -> HashMap<u64, Value> {
    HashMap::from([
        (2, json!({"sequence": "2", "payload": {"native": {"tool_name": "Bash"}}})),
        (3, json!({"sequence": "3", "payload": {"native": {"evidence": "❯ \n  ? for shortcuts"}}})),
    ])
}

#[test]
fn w5t_explain_takes_both_word_orders_and_one_target() {
    assert_eq!(parse(&words("agent explain alpha")), Some(Ok("alpha".to_owned())));
    assert_eq!(parse(&words("agent alpha explain")), Some(Ok("alpha".to_owned())));
    assert_eq!(parse(&words("agent explain term_1")), Some(Ok("term_1".to_owned())));
    assert!(matches!(parse(&words("agent explain")), Some(Err(_))));
    assert!(matches!(parse(&words("agent explain alpha beta")), Some(Err(_))));
    assert!(matches!(parse(&words("agent alpha explain now")), Some(Err(_))));
    assert_eq!(parse(&words("agent list")), None);
    assert_eq!(parse(&words("agent start alpha")), None);
    assert_eq!(parse(&words("terminal alpha explain")), None);
}

#[test]
fn w5t_explain_joins_the_reason_with_the_journal_records_it_names() {
    let snapshot = snapshot();
    let terminal = snapshot["terminals"][0].clone();
    let value = explain_value(&snapshot, &terminal, Some(&row()), &records(), &[2, 3]).unwrap();
    assert_eq!(value["terminal"], TERMINAL, "{value}");
    assert_eq!(value["name"], "alpha", "{value}");
    assert_eq!(value["harness"], "claude", "{value}");
    assert_eq!(value["status"], "blocked", "{value}");
    assert_eq!(value["state"], "blocked", "{value}");
    assert_eq!(value["since_ms"], "12150", "{value}");
    assert_eq!(value["cause"]["event"], "PermissionRequest", "{value}");
    assert_eq!(value["cause"]["tool"], "Bash", "{value}");
    assert_eq!(value["cause"]["retained"], true, "{value}");
    assert_eq!(value["previous"]["state"], "working", "{value}");
    assert_eq!(value["screen"]["rule"], "live_prompt_box", "{value}");
    assert_eq!(value["screen"]["agrees"], false, "{value}");
    assert!(value["screen"]["screen_text"].as_str().unwrap().contains("? for shortcuts"));
}

#[test]
fn w5t_explain_says_when_the_named_record_left_the_journal() {
    let snapshot = snapshot();
    let terminal = snapshot["terminals"][0].clone();
    let value =
        explain_value(&snapshot, &terminal, Some(&row()), &HashMap::new(), &[2, 3]).unwrap();
    assert_eq!(value["cause"]["retained"], false, "{value}");
    assert_eq!(value["screen"]["retained"], false, "{value}");
    assert!(value["screen"].get("screen_text").is_none(), "{value}");
}

#[test]
fn w5t_explain_finds_no_agent_in_a_plain_terminal() {
    let snapshot = json!({
        "terminals": [{"id": TERMINAL}],
        "agents": [],
        "notifications": [],
    });
    let terminal = snapshot["terminals"][0].clone();
    assert_eq!(explain_value(&snapshot, &terminal, None, &HashMap::new(), &[]), None);
}

#[test]
fn w5t_explain_text_names_the_hook_event_the_state_before_and_the_ignored_screen() {
    let snapshot = snapshot();
    let terminal = snapshot["terminals"][0].clone();
    let value = explain_value(&snapshot, &terminal, Some(&row()), &records(), &[2, 3]).unwrap();
    let english = &crate::localization::catalog_for_locale("en").agent_state;
    let text = human(&value, english, NOW);
    assert!(text.starts_with("alpha  term_"), "{text}");
    assert!(text.contains("state: blocked, source hook, for 7s"), "{text}");
    assert!(text.contains("hook event PermissionRequest"), "{text}");
    assert!(text.contains("tool Bash"), "{text}");
    assert!(text.contains("journal 2"), "{text}");
    assert!(text.contains("before: working, source hook, for 2s"), "{text}");
    assert!(text.contains("rule live_prompt_box"), "{text}");
    assert!(text.contains("not taken: a fresh hook owns the state"), "{text}");
    assert!(text.contains("    | ❯"), "{text}");
    let japanese = &crate::localization::catalog_for_locale("ja").agent_state;
    let text = human(&value, japanese, NOW);
    assert!(text.contains("フックイベント PermissionRequest"), "{text}");
    assert!(text.contains("不採用"), "{text}");
}
