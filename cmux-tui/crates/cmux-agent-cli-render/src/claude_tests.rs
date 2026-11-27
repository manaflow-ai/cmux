use super::*;
use serde_json::json;

fn chrome() -> Chrome {
    Chrome { mode: "manual mode on".into(), cwd: Some("/w".into()), ..Chrome::default() }
}

#[test]
fn a_turn_draws_prompt_tool_and_answer_above_the_input_box() {
    let update = |u: Value| json!({"jsonrpc": "2.0", "method": "session/update", "params": {"sessionId": "s", "update": u}});
    let records = vec![
        json!({"kind": "turn_started", "msg": {}, "at": 1000}),
        json!({"kind": "user_message", "msg": {"text": "hi"}}),
        json!({"kind": "tool_call", "msg": update(json!({"sessionUpdate": "tool_call", "toolCallId": "t", "title": "x", "rawInput": {"command": "ls"}, "_meta": {"claude": {"tool": "Bash"}}}))}),
        json!({"kind": "tool_call_update", "msg": update(json!({"sessionUpdate": "tool_call_update", "toolCallId": "t", "status": "completed", "content": [{"type": "content", "content": {"type": "text", "text": "a.txt"}}]}))}),
        json!({"kind": "agent_message_chunk", "msg": update(json!({"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": "Done `a.txt`."}}))}),
        json!({"kind": "turn_end", "msg": {}, "at": 3000}),
    ];
    let grid = render(&records, &chrome(), 40, 16);
    let text: Vec<String> = (0..16).map(|y| grid.row_text(y)).collect();
    assert_eq!(text.get(1).map(String::as_str), Some("❯ hi"));
    assert_eq!(text.get(3).map(String::as_str), Some("● Bash(ls)"));
    assert_eq!(text.get(4).map(String::as_str), Some("  ⎿ \u{a0}a.txt"));
    assert_eq!(text.get(6).map(String::as_str), Some("● Done a.txt."));
    assert!(text.get(8).is_some_and(|t| t.starts_with("✻ Worked for 2s")));
    assert!(text.iter().any(|t| t == "❯"));
    let code = grid.cells.get(6).and_then(|r| r.get(7)).map(|c| c.style.fg);
    assert_eq!(code, Some(crate::Color::Palette(CODE)));
}

#[test]
fn an_edit_marks_the_changed_word_not_its_common_letters() {
    assert_eq!(common_ends("print(\"hi\")", "print(\"hello\")"), (7, 2));
}

#[test]
fn a_tall_transcript_shows_its_bottom_rows() {
    let records: Vec<Value> = (0..20)
        .map(|i| json!({"kind": "user_message", "msg": {"text": format!("p{i}")}}))
        .collect();
    let grid = render(&records, &chrome(), 30, 10);
    assert_eq!(grid.row_text(4), "❯ p19");
}
