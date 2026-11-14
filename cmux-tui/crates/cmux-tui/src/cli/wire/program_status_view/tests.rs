use serde_json::{Value, json};

use super::{annotate, human_records};
use crate::cli::terminal_talk::roster;

const TERMINAL: &str = "term_c1a0de00000000000000000000000001";

/// A Claude Code that reported the end of its turn (OSC 7501 `done`).
fn finished_turn() -> Value {
    json!({
        "id": TERMINAL,
        "title": "claude",
        "lifecycle": "running",
        "extra": {"program_status": [
            {"id": "", "app": "claude-code", "state": "done", "kind": null,
             "msg": null, "updated_at_ms": "50"},
        ]},
    })
}

fn statuses(result: &Value) -> Vec<Value> {
    result["extra"]["program_status"]
        .as_array()
        .map(|records| records.iter().map(|record| record["status"].clone()).collect())
        .unwrap_or_default()
}

/// The roster's word for the terminal, as `terminal list --agents` shows it.
fn listed(terminal: &Value, agents: &[Value], unseen: bool) -> String {
    roster::agent_of_terminal(terminal, agents, unseen)
        .map(|row| row.status_word().to_owned())
        .unwrap_or_default()
}

/// W5-Q (bench r4 #7): `terminal status` said `done` while both lists said
/// `idle`. Each record now carries the `status` the lists show: a finished
/// turn somebody viewed is `idle`, one nobody viewed is `done`, and a
/// hook's record wins over the program's own report, as in the lists.
#[test]
fn w5q_terminal_status_records_carry_the_status_the_lists_show() {
    let seen = annotate(finished_turn(), &[], false);
    assert_eq!(statuses(&seen), [json!("idle")]);
    assert_eq!(listed(&finished_turn(), &[], false), "idle");
    assert_eq!(seen["extra"]["program_status"][0]["state"], "done", "the program's word stays");

    let unseen = annotate(finished_turn(), &[], true);
    assert_eq!(statuses(&unseen), [json!("done")]);
    assert_eq!(listed(&finished_turn(), &[], true), "done");

    let hook = [json!({"terminal_id": TERMINAL, "state": "blocked", "source": "hook",
                       "updated_at_ms": "90", "extra": {"agent": "claude"}})];
    let blocked = annotate(finished_turn(), &hook, false);
    assert_eq!(statuses(&blocked), [json!("blocked")]);
    assert_eq!(listed(&finished_turn(), &hook, false), "blocked");
}

/// The human table shows that one word in its STATE column, not the
/// program's own `done`.
#[test]
fn w5q_terminal_status_human_table_shows_the_shared_word() {
    let records = annotate(finished_turn(), &[], false)["extra"]["program_status"].clone();
    let shown = human_records(records);
    assert_eq!(shown[0]["state"], "idle", "{shown}");
    assert!(shown[0].get("status").is_none(), "one state column: {shown}");
}
