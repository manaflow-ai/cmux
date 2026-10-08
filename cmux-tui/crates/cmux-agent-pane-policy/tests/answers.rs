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
