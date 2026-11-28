use super::{ask_command, ask_summary};
use serde_json::json;

/// A subagent's shell ask reads as what it does, and its command as the agent wrote it,
/// never the `export ACPMUX_CALLER_SUBAGENT=...` line acpmux put first (Leo 2026-11-23).
#[test]
fn a_subagents_shell_ask_shows_its_description_and_unmarked_command() {
    let ask = json!({"toolCall": {"kind": "execute", "rawInput": {
        "command": "export ACPMUX_CALLER_SUBAGENT=general-purpose:a1b2\ncmux agent last desktop-helper",
        "description": "Read the newest desktop-helper message\nmore"}}});
    assert_eq!(ask_summary(&ask).as_deref(), Some("Read the newest desktop-helper message"));
    assert_eq!(ask_command(&ask).as_deref(), Some("cmux agent last desktop-helper"));
    let plain = json!({"toolCall": {"kind": "execute", "rawInput": {"command": "ls"}}});
    assert_eq!(ask_command(&plain), None);
    assert_eq!(ask_summary(&plain), None);
    let blank = json!({"toolCall": {"rawInput": {"command": "ls", "description": "  "}}});
    assert_eq!(ask_summary(&blank), None);
    let subject = json!({"subject": {"type": "command",
        "command": "export ACPMUX_CALLER_SUBAGENT=Explore:x9\ngit status"}});
    assert_eq!(ask_command(&subject).as_deref(), Some("git status"));
}
