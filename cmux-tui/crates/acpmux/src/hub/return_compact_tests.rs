//! The compaction before a person's prompt (`return_compact.rs`): the Settings keys, a client's
//! word for one prompt, and when it is due.

use super::*;

const SOURCE: &str = include_str!("../../../../../schemas/settings/source/agent-cache.json");

fn row(key: &str) -> Value {
    let doc: Value = serde_json::from_str(SOURCE).unwrap();
    doc["lists"][0]["rows"].as_array().unwrap().iter().find(|r| r["key"] == key).unwrap().clone()
}

fn usage(used: u64, expires: Option<u64>) -> Value {
    let mut u = json!({"sessionUpdate": "usage_update", "used": used, "size": 1_000_000});
    if let Some(at) = expires {
        u["_meta"] = json!({"acpmux": {"cacheExpiresAt": at}});
    }
    u
}

#[test]
fn the_settings_source_matches_the_daemon() {
    let mode = row(super::super::idle::cache_compact::SETTING_MODE);
    assert_eq!(mode["default"], json!("off"), "off unless Leo says otherwise");
    let values: Vec<_> =
        mode["choices"].as_array().unwrap().iter().map(|c| c["value"].clone()).collect();
    assert_eq!(values, [json!("off"), json!("beforeExpiry"), json!("onReturn")]);
    let min = row(SETTING_RETURN_MIN_TOKENS);
    assert_eq!(min["default"], json!(DEFAULT_RETURN_MIN_TOKENS));
    assert_eq!(min["range"]["min"], json!(RETURN_MIN_TOKENS_RANGE.0));
    assert_eq!(min["range"]["max"], json!(RETURN_MIN_TOKENS_RANGE.1));
}

#[test]
fn only_the_on_return_mode_has_a_floor() {
    assert_eq!(settings_min_tokens(None), None);
    assert_eq!(settings_min_tokens(Some(&json!({}))), None, "the default is off");
    let legacy = json!({"agents": {"cacheCompact": {"enabled": true}}});
    assert_eq!(settings_min_tokens(Some(&legacy)), None, "the old switch is the timer");
    let on = json!({"agents": {"cacheCompact": {"mode": "onReturn"}}});
    assert_eq!(settings_min_tokens(Some(&on)), Some(200_000));
    let flat = json!({"agents.cacheCompact.mode": "onReturn", "agents.cacheCompact.returnMinTokens": 50_000});
    assert_eq!(settings_min_tokens(Some(&flat)), Some(50_000));
    let wild = json!({"agents": {"cacheCompact": {"mode": "onReturn", "returnMinTokens": 1}}});
    assert_eq!(settings_min_tokens(Some(&wild)), Some(20_000), "clamped to the range");
}

#[test]
fn a_client_word_parses() {
    assert_eq!(Choice::parse(Some(&json!("compact"))), Some(Choice::Compact));
    assert_eq!(Choice::parse(Some(&json!("keep"))), Some(Choice::Keep));
    assert_eq!(Choice::parse(Some(&json!("later"))), None);
    assert_eq!(Choice::parse(None), None);
}

#[test]
fn it_is_due_once_a_big_chats_cache_lapsed() {
    let now = 10_000_000;
    let expired = Some(now - 1);
    let warm = Some(now + 60_000);
    let min = Some(200_000);
    assert!(due(None, min, Some(&usage(250_000, expired)), now));
    assert!(due(None, min, Some(&usage(200_000, Some(now))), now), "at the expiry");
    assert!(!due(None, min, Some(&usage(250_000, warm)), now), "still warm");
    assert!(!due(None, min, Some(&usage(199_999, expired)), now), "under the floor");
    assert!(!due(None, None, Some(&usage(250_000, expired)), now), "not the mode");
    assert!(!due(None, min, Some(&usage(250_000, None)), now), "no known cache");
    assert!(!due(None, min, None, now), "no usage yet");
}

#[test]
fn a_client_word_wins() {
    let now = 10_000_000;
    let expired = usage(250_000, Some(now - 1));
    assert!(!due(Some(Choice::Keep), Some(1), Some(&expired), now), "keep sends cold");
    assert!(due(Some(Choice::Compact), None, Some(&usage(5_000, Some(now + 60_000))), now));
    assert!(!due(Some(Choice::Compact), None, Some(&usage(5_000, None)), now), "no cache to save");
    assert!(!due(Some(Choice::Compact), None, Some(&usage(0, Some(now - 1))), now), "nothing held");
}

#[test]
fn a_slash_command_goes_as_it_is() {
    assert!(slash_command(&[json!({"type": "text", "text": "  /clear"})]));
    assert!(!slash_command(&[json!({"type": "text", "text": "go on"})]));
    assert!(!slash_command(&[json!({"type": "image", "data": ""})]));
}

#[test]
fn its_prompt_is_acpmuxs_own() {
    let ours = json!({"kind": KIND});
    assert!(super::super::idle::cache_compact::is_own(Some(&ours)));
    assert!(!super::super::inbox::persons_prompt(None, Some(&ours)));
}

#[test]
fn only_the_persons_own_prompt_is_compacted_ahead_of() {
    let with = |provenance: Option<Value>, agent: Option<&str>| PromptOptions {
        provenance,
        agent: agent.map(str::to_owned),
        ..PromptOptions::default()
    };
    assert!(persons_own(&with(None, None)), "a local prompt with no sender");
    let person = json!({"kind": "person_message", "from": "user_42", "fromName": "Bo"});
    assert!(persons_own(&with(Some(person), None)));
    assert!(!persons_own(&with(None, Some("helper"))), "another agent's message");
    let agent = json!({"kind": "agent_message", "from": "helper"});
    assert!(!persons_own(&with(Some(agent), None)), "an agent named by its provenance");
    let card = json!({"kind": "task_result"});
    assert!(!persons_own(&with(Some(card), None)), "a lane's task card");
    assert!(!persons_own(&with(Some(json!({"kind": KIND})), None)), "its own compaction");
    let guest = json!({"kind": "person_message", "from": "guest:k3x9", "fromName": "Cy"});
    assert!(crate::author::awaits_owner(Some(&guest)));
    assert!(!persons_own(&with(Some(guest), None)), "a guest's prompt waits for the owner");
}
