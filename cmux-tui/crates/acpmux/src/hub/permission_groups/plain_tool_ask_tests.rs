use super::plain_tool_ask;
use serde_json::json;

/// Full access answers a tool approval, never anything only a person answers.
#[test]
fn only_a_tool_approval_is_a_plain_tool_ask() {
    let ask = |tool: serde_json::Value| json!({"toolCall": tool, "options": []});
    assert!(plain_tool_ask(&ask(json!({"kind": "execute", "title": "rm -rf f/*"}))));
    assert!(plain_tool_ask(&ask(json!({"kind": "other", "title": "Allow network access"}))));
    for not_plain in [
        json!({"kind": "switch_mode", "title": "Ready to code?"}),
        json!({"kind": "other", "_meta": {"acpmux": {"trust": {"cwd": "/w"}}}}),
        json!({"kind": "other", "_meta": {"claude": {"tool": "AskUserQuestion"}}}),
        json!({"kind": "other", "_meta": {"claude": {"tool": "ExitPlanMode"}}}),
        json!({"kind": "execute", "_meta": {"claude": {"interactive": true}}}),
        // A Codex user-input request with no prompt text: no normalized question, still one.
        json!({"kind": "other", "rawInput": {"questions": [{"id": "q", "question": ""}]},
                   "_meta": {"codexAppServer": {"question": true}}}),
        json!({"kind": "other", "_meta": {"codexAppServer": {"question": true}}}),
        json!({"kind": "execute", "rawInput": {"questions": []}}),
    ] {
        assert!(!plain_tool_ask(&ask(not_plain.clone())), "{not_plain}");
    }
}
