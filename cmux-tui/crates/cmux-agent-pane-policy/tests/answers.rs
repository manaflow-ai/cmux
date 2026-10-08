//! The answers rule (Swift `AcpmuxPaneMethods.breaksAnswersRule`, cx-lz7j):
//! `answers` on `_acpmux/permission_respond` go only to a question the pane
//! saw, keyed by that question's item ids or prompts, 1 to 64 items, each
//! value a string, a list of at most 64 strings, or Codex's `{answers: [..]}`
//! with that one key; every key and string at most 4096 UTF-8 bytes.

use cmux_agent_pane_policy::PaneSessions;
use cmux_agent_pane_policy::check::{Checked, FrameState, check_frame};
use cmux_agent_pane_policy::gesture::PermissionOptions;
use serde_json::{Map, Value, json};

fn frame(value: Value) -> Map<String, Value> {
    value.as_object().cloned().unwrap()
}

/// A pane that saw permission `q` as a question (items `name` / "Name?") and
/// permission `t` as a tool permission.
fn options() -> PermissionOptions {
    let options = PermissionOptions::new();
    let question = json!({"jsonrpc": "2.0", "method": "_acpmux/permission_pending", "params": {
        "permissionId": "q", "request": {
            "toolCall": {"_meta": {"acpmux": {"question": {"harness": "codex", "items": [
                {"id": "name", "prompt": "Name?"}]}}}},
            "options": [{"optionId": "ok", "kind": "allow_once"}]}}});
    options.observe(&frame(question), None);
    let tool = json!({"jsonrpc": "2.0", "method": "_acpmux/permission_pending", "params": {
        "permissionId": "t", "request": {"toolCall": {"kind": "execute"},
            "options": [{"optionId": "ok", "kind": "allow_once"}]}}});
    options.observe(&frame(tool), None);
    options
}

fn refused(permission: &str, answers: Value) -> bool {
    let options = options();
    let scope = PaneSessions::new();
    scope.add("s1");
    let state = FrameState {
        is_first: false,
        local_app_token: None,
        mode_fields: None,
        scope: &scope,
        options: &options,
    };
    let text = json!({"jsonrpc": "2.0", "id": 7, "method": "_acpmux/permission_respond",
        "params": {"sessionId": "s1", "permissionId": permission, "optionId": "ok", "answers": answers}})
    .to_string();
    matches!(check_frame(&text, &state), Checked::Refuse { .. })
}

#[test]
fn answers_go_only_to_a_seen_question_with_its_own_keys() {
    assert!(!refused("q", json!({"name": {"answers": ["ledger"]}})));
    assert!(!refused("q", json!({"Name?": "ledger"})));
    assert!(!refused("q", json!({"name": ["a", "b"]})));
    assert!(refused("t", json!({"name": "ledger"})), "a tool permission takes no answers");
    assert!(refused("unknown", json!({"name": "ledger"})), "an unseen permission takes none");
    assert!(refused("q", json!({"other": "ledger"})), "a key not in the question");
    assert!(refused("q", json!({})), "at least one item");
    assert!(refused("q", json!("ledger")), "an object");
}

#[test]
fn answers_are_bounded_and_codex_values_hold_one_key() {
    assert!(!refused("q", json!({"name": "x".repeat(4096)})));
    assert!(refused("q", json!({"name": "x".repeat(4097)})));
    assert!(!refused("q", json!({"name": vec!["a"; 64]})));
    assert!(refused("q", json!({"name": vec!["a"; 65]})));
    assert!(refused("q", json!({"name": {"answers": ["a"], "junk": "x"}})));
    assert!(refused("q", json!({"name": {"answers": [1]}})));
    assert!(refused("q", json!({"name": 3})));
}

#[test]
fn a_permission_seen_once_without_a_question_is_no_question() {
    let options = options();
    let again = json!({"jsonrpc": "2.0", "method": "_acpmux/permission_pending", "params": {
        "permissionId": "q", "request": {"toolCall": {"kind": "execute"}, "options": []}}});
    options.observe(&frame(again), None);
    assert_eq!(options.question_keys("q"), None);
}

/// A pane that saw permission `p` as a question with `items` (`[id, prompt]`).
fn asked(items: &[(&str, &str)]) -> PermissionOptions {
    let options = PermissionOptions::new();
    observe_question(&options, "p", items);
    options
}

fn observe_question(options: &PermissionOptions, permission: &str, items: &[(&str, &str)]) {
    let items: Vec<Value> =
        items.iter().map(|(id, prompt)| json!({"id": id, "prompt": prompt})).collect();
    let pending = json!({"jsonrpc": "2.0", "method": "_acpmux/permission_pending", "params": {
        "permissionId": permission, "request": {
            "toolCall": {"_meta": {"acpmux": {"question": {"harness": "codex", "items": items}}}},
            "options": [{"optionId": "ok", "kind": "allow_once"}]}}});
    options.observe(&frame(pending), None);
}

fn observe_tool(options: &PermissionOptions, permission: &str) {
    let pending = json!({"jsonrpc": "2.0", "method": "_acpmux/permission_pending", "params": {
        "permissionId": permission, "request": {"toolCall": {"kind": "execute"},
            "options": [{"optionId": "ok", "kind": "allow_once"}]}}});
    options.observe(&frame(pending), None);
}

/// Whether `check_frame` refuses `params` on `_acpmux/permission_respond` for `options`.
fn refuses(options: &PermissionOptions, params: Value) -> bool {
    let scope = PaneSessions::new();
    scope.add("s1");
    let state = FrameState {
        is_first: false,
        local_app_token: None,
        mode_fields: None,
        scope: &scope,
        options,
    };
    let text = json!({"jsonrpc": "2.0", "id": 7, "method": "_acpmux/permission_respond", "params": params})
        .to_string();
    matches!(check_frame(&text, &state), Checked::Refuse { .. })
}

fn respond(answers: Value) -> Value {
    json!({"sessionId": "s1", "permissionId": "p", "optionId": "ok", "answers": answers})
}

#[test]
fn a_permission_seen_without_a_question_stays_no_question_in_either_order() {
    let options = PermissionOptions::new();
    observe_tool(&options, "p");
    observe_question(&options, "p", &[("name", "Name?")]);
    assert_eq!(options.question_keys("p"), None);
    assert!(refuses(&options, respond(json!({"name": "a"}))));
}

#[test]
fn keys_from_several_events_join() {
    let options = asked(&[("a", "A?")]);
    observe_question(&options, "p", &[("b", "B?")]);
    assert!(!refuses(&options, respond(json!({"a": "x", "b": "y"}))));
}

#[test]
fn an_answer_holds_one_to_sixty_four_items() {
    let ids: Vec<String> = (0..65).map(|i| format!("q{i}")).collect();
    let items: Vec<(&str, &str)> = ids.iter().map(|id| (id.as_str(), id.as_str())).collect();
    let options = asked(&items);
    let answer = |n: usize| {
        Value::Object(ids.iter().take(n).map(|id| (id.clone(), json!("a"))).collect::<Map<_, _>>())
    };
    assert!(!refuses(&options, respond(answer(64))));
    assert!(refuses(&options, respond(answer(65))));
}

#[test]
fn a_key_is_at_most_4096_bytes() {
    let fits = "k".repeat(4096);
    let over = "k".repeat(4097);
    let options = asked(&[("fits", &fits), ("over", &over)]);
    assert!(!refuses(&options, respond(json!({fits: "a"}))));
    assert!(refuses(&options, respond(json!({over: "a"}))));
}

#[test]
fn multibyte_strings_count_utf8_bytes() {
    let options = asked(&[("name", "Name?")]);
    // "é" is two UTF-8 bytes: 2048 of them are 4096 bytes, one more is 4098.
    let fits = "é".repeat(2048);
    let over = "é".repeat(2049);
    assert!(!refuses(&options, respond(json!({"name": fits.as_str()}))));
    assert!(refuses(&options, respond(json!({"name": over.as_str()}))));
    assert!(!refuses(&options, respond(json!({"name": {"answers": [fits.as_str()]}}))));
    assert!(refuses(&options, respond(json!({"name": {"answers": [over.as_str()]}}))));
}

#[test]
fn answers_without_a_permission_id_are_refused() {
    let options = asked(&[("name", "Name?")]);
    assert!(refuses(
        &options,
        json!({"sessionId": "s1", "optionId": "ok", "answers": {"name": "a"}})
    ));
    assert!(!refuses(&options, json!({"sessionId": "s1", "permissionId": "p", "optionId": "ok"})));
}
