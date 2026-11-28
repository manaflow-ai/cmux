use serde_json::{Value, json};

use super::*;

fn tab(id: &str, page: &str) -> Value {
    json!({
        "id": id,
        "kind": "page",
        "extra": {"conversation": {"page": page, "route": {"device": "mac-mini"}}},
    })
}

fn row(key: &str, store_tab: Option<&str>, device: &str) -> Value {
    json!({
        "tab": key,
        "store_tab": store_tab,
        "device_id": format!("{device}-id"),
        "device": device,
        "phase": "streaming",
        "connected": true,
        "has_frame": true,
        "first_frame_ms": 412,
        "state": "live",
        "hub_phase": "attached",
        "hub_reason": null,
        "scope": "screen",
        "error": null,
        "connect_stage": "streaming",
        "path": "Direct",
        "transport": "quic",
        "fps": 59.8,
        "rtt_ms": 7,
    })
}

#[test]
fn only_a_mac_screen_page_tab_is_one() {
    assert!(is_mac_screen_tab(&tab("tab_1", "mac-screen")));
    assert!(!is_mac_screen_tab(&tab("tab_1", "settings")));
    assert!(!is_mac_screen_tab(&json!({"id": "tab_1", "kind": "terminal"})));
}

#[test]
fn shape_names_the_share_state_an_agent_reads() {
    let route = json!({"device": "mac-mini"});
    let shaped = shape(&row("key-1", Some("tab_1"), "mac-mini"), Some(&route));
    assert_eq!(shaped["tab"], "tab_1");
    assert_eq!(shaped["device"], "mac-mini");
    assert_eq!(shaped["route"], route);
    assert_eq!(shaped["connect_stage"], "streaming");
    assert_eq!(shaped["hub_phase"], "attached");
    assert_eq!(shaped["hub_reason"], Value::Null);
    assert_eq!(shaped["phase"], "streaming");
    assert_eq!(shaped["first_frame_ms"], 412);
    assert_eq!(shaped["fps"], 59.8);
    assert_eq!(shaped["transport"], "Direct");
    assert_eq!(shaped["carrier"], "quic");
    assert_eq!(shaped["error"], Value::Null);
    assert!(shaped.get("rtt_ms").is_none(), "only the agent's fields: {shaped}");
}

#[test]
fn field_for_finds_the_tab_by_its_daemon_id() {
    let state = json!({"tabs": [row("key-0", Some("tab_0"), "other"), row("key-1", Some("tab_1"), "mac-mini")]});
    let field = field_for(&tab("tab_1", "mac-screen"), Ok(state));
    assert_eq!(field["device"], "mac-mini");
    assert_eq!(field["route"]["device"], "mac-mini");
}

#[test]
fn field_for_says_why_when_the_app_cannot_answer() {
    let field = field_for(&tab("tab_9", "mac-screen"), Err("no cmux app is running".into()));
    assert_eq!(field["unavailable"], "no cmux app is running");
    assert_eq!(field["route"]["device"], "mac-mini");

    let field = field_for(&tab("tab_9", "mac-screen"), Ok(json!({"tabs": []})));
    assert_eq!(field["unavailable"], "the app lists no Screen Sharing tab tab_9");
}

#[test]
fn opens_tab_is_the_mac_screen_open_action_only() {
    assert!(opens_tab("action.run", &json!({"action": "macScreen.open"})));
    assert!(opens_tab("action.run", &json!({"action": "tab new-mac-screen", "cli": true})));
    assert!(!opens_tab("action.run", &json!({"action": "tab new"})));
    assert!(!opens_tab("mac_screen.state", &json!({"action": "macScreen.open"})));
}

#[test]
fn the_opened_tab_is_the_one_not_there_before() {
    let before = keys(&json!({"tabs": [row("key-0", Some("tab_0"), "other")]}));
    assert_eq!(before, vec!["key-0".to_owned()]);
    let after = json!({"tabs": [row("key-0", Some("tab_0"), "other"), row("key-1", Some("tab_1"), "mac-mini")]});
    let mut answer = json!({"ok": true, "created": []});
    with_opened(&mut answer, opened_row(&before, &after, None));
    assert_eq!(answer["tab"], "tab_1");
    assert_eq!(answer["mac_screen"]["device"], "mac-mini");
    assert_eq!(answer["ok"], true);
}

#[test]
fn an_open_that_showed_an_open_tab_answers_with_that_device() {
    let state =
        json!({"tabs": [row("key-0", Some("tab_0"), "other"), row("key-1", None, "Mac-Mini")]});
    let before = keys(&state);
    let mut answer = json!({});
    with_opened(&mut answer, opened_row(&before, &state, Some("mac-mini")));
    assert_eq!(answer["tab"], "key-1", "no store tab yet: the provider key");

    let mut untouched = json!({"ok": true});
    with_opened(&mut untouched, opened_row(&before, &state, Some("nowhere")));
    assert_eq!(untouched, json!({"ok": true}));
}
