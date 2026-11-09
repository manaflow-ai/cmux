use serde_json::json;

use super::{facts, row_json, rows, table};

const ALPHA: &str = "term_a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1";
const STATUS: &str = "term_b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2";
const PLUGIN: &str = "term_c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3";

/// alpha: a hook agent with a last reply in a tab named alpha; a Claude
/// that only reports OSC 7501 status as `claude-code`; an old plugin record
/// that says `detected`, in a tab whose name is no agent name.
fn snapshot() -> serde_json::Value {
    json!({
        "tabs": [
            {"id": "tab_alpha", "name": "alpha", "content_id": ALPHA, "pane_id": "pane_1"},
            {"id": "tab_status", "name": null, "content_id": STATUS, "pane_id": "pane_1"},
            {"id": "tab_plugin", "name": "My Tab", "content_id": PLUGIN, "pane_id": "pane_2"},
        ],
        "terminals": [
            {"id": ALPHA, "tab_id": "tab_alpha", "lifecycle": "running", "title": "a"},
            {"id": STATUS, "tab_id": "tab_status", "lifecycle": "running", "title": "s",
             "extra": {"program_status": [{"app": "claude-code", "state": "idle",
                                           "updated_at_ms": "50"}]}},
            {"id": PLUGIN, "tab_id": "tab_plugin", "lifecycle": "running", "title": "p"},
        ],
        "agents": [
            {"terminal_id": ALPHA, "state": "idle", "source": "hook", "updated_at_ms": "90",
             "extra": {"agent": "claude", "last_reply": "ALPHA_OK"}},
            {"terminal_id": PLUGIN, "state": "working", "source": "detected",
             "updated_at_ms": "70", "extra": {"agent": "Claude Code"}},
        ],
    })
}

#[test]
fn w3h_agent_rows_carry_name_tab_pane_last_reply_and_one_vocabulary() {
    let snapshot = snapshot();
    let rows = rows(&snapshot);
    let facts = facts(&snapshot);
    let by_terminal = |id: &str| {
        let row = rows.iter().find(|row| row.terminal == id).expect("row");
        row_json(row, &facts, 100)
    };
    let alpha = by_terminal(ALPHA);
    assert_eq!(alpha["name"], "alpha");
    assert_eq!(alpha["tab_name"], "alpha");
    assert_eq!(alpha["tab_id"], "tab_alpha");
    assert_eq!(alpha["pane_id"], "pane_1");
    assert_eq!(alpha["last_reply"], "ALPHA_OK");
    assert_eq!(alpha["harness"], "claude");
    assert_eq!(alpha["source"], "hook");
    // The old fields stay.
    assert_eq!(alpha["terminal"], ALPHA);
    assert_eq!(alpha["state"], "idle");

    let status = by_terminal(STATUS);
    assert_eq!(status["harness"], "claude", "claude-code is an input alias only");
    assert_eq!(status["source"], "program_status");
    assert_eq!(status["name"], serde_json::Value::Null);
    assert_eq!(status["last_reply"], serde_json::Value::Null);

    let plugin = by_terminal(PLUGIN);
    assert_eq!(plugin["harness"], "claude");
    assert_eq!(plugin["source"], "plugin");
    assert_eq!(plugin["tab_name"], "My Tab");
    assert_eq!(plugin["name"], serde_json::Value::Null, "My Tab is no agent name");

    let shown = table(&rows, &facts, 100);
    let lines: Vec<&str> = shown.lines().collect();
    assert!(lines[0].starts_with("NAME   TERMINAL"), "{shown}");
    assert_eq!(lines.len(), 4, "{shown}");
    assert!(lines.iter().any(|line| line.starts_with("alpha  term_a1")), "{shown}");
    assert!(lines.iter().any(|line| line.starts_with("-      term_c3")), "{shown}");
}

/// W5-Q (bench round 4 orchestration #9): the text roster ends with a REPLY
/// column, the first line of the agent's last reply, aligned under its
/// header; `-` when there is none.
#[test]
fn w5q_terminal_list_agents_table_shows_the_last_reply() {
    let mut snapshot = snapshot();
    snapshot["agents"][0]["extra"]["last_reply"] = json!("Canberra is the capital.\nMore text");
    let rows = rows(&snapshot);
    let facts = facts(&snapshot);
    let shown = table(&rows, &facts, 100);
    let lines: Vec<&str> = shown.lines().collect();
    let header = lines.first().copied().unwrap_or_default();
    assert!(header.ends_with("REPLY"), "{shown}");
    let column = header.find("REPLY").unwrap_or_default();
    let alpha = lines.iter().find(|line| line.starts_with("alpha ")).copied().unwrap_or_default();
    assert_eq!(alpha.get(column..), Some("Canberra is the capital."), "{shown}");
    let plugin = lines.iter().find(|line| line.starts_with("-      term_c3")).copied();
    assert_eq!(plugin.and_then(|line| line.get(column..)), Some("-"), "{shown}");
}
