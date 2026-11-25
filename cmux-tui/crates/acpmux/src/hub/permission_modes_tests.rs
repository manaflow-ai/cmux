use super::permission_modes;
use serde_json::{Value, json};

fn modes(ids: &[&str]) -> Value {
    let rows: Vec<Value> = ids.iter().map(|id| json!({"id": id})).collect();
    json!({"currentModeId": ids[0], "availableModes": rows})
}

fn option(id: &str, category: &str, values: &[&str]) -> Value {
    json!({"id": id, "category": category, "type": "select",
           "options": values.iter().map(|v| json!({"value": v})).collect::<Vec<_>>()})
}

#[test]
fn modes_that_copy_a_thinking_option_are_none() {
    let levels = ["off", "minimal", "low", "medium", "high", "xhigh"];
    let options = json!([
        option("model", "model", &["a", "b"]),
        option("thought_level", "thought_level", &levels)
    ]);
    assert_eq!(permission_modes(Some(&modes(&levels)), Some(&options)), None);
    // Grouped choices count as their values.
    let grouped = json!([{"id": "thought_level", "options": [{"group": "g", "name": "G",
        "options": levels.iter().map(|v| json!({"value": v})).collect::<Vec<_>>()}]}]);
    assert_eq!(permission_modes(Some(&modes(&levels)), Some(&grouped)), None);
}

#[test]
fn real_permission_modes_stay() {
    let claude = modes(&["default", "acceptEdits", "plan", "bypassPermissions"]);
    let mode_option =
        json!([option("mode", "mode", &["default", "acceptEdits", "plan", "bypassPermissions"])]);
    assert_eq!(permission_modes(Some(&claude), Some(&mode_option)), Some(claude.clone()));
    // OpenCode and Gemini: modes and no options.
    let opencode = modes(&["build", "plan"]);
    assert_eq!(permission_modes(Some(&opencode), None), Some(opencode.clone()));
    // Codex: a collaboration option that is not what its approval modes copy.
    let codex = modes(&["ask", "agent", "agent-full-access"]);
    let collaboration =
        json!([option("collaboration_mode", "collaboration_mode", &["default", "plan"])]);
    assert_eq!(permission_modes(Some(&codex), Some(&collaboration)), Some(codex.clone()));
    // Empty or absent modes stay what they are.
    let empty = json!({"currentModeId": "x", "availableModes": []});
    assert_eq!(permission_modes(Some(&empty), Some(&collaboration)), Some(empty.clone()));
    assert_eq!(permission_modes(None, Some(&collaboration)), None);
}
