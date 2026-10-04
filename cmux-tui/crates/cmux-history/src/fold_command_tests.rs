use serde_json::{Value, json};

use super::TerminalCommandFold;
use crate::hidden::HiddenHistory;
use crate::journal::EntryContext;

fn record(sequence: u64, command: Option<&str>, exit: Option<i64>, started: i64, kind: &str) -> Value {
    json!({
        "sequence": sequence.to_string(), "kind": kind,
        "subjects": [{"kind": "terminal", "id": "term_1"}, {"kind": "workspace", "id": "ws_1"}],
        "payload": {"command": command, "cwd": "/repo", "exit_code": exit,
            "started_at_ms": started.to_string(), "duration_ms": "250"},
    })
}

fn finished(sequence: u64, command: Option<&str>, exit: Option<i64>, started: i64) -> Value {
    record(sequence, command, exit, started, "shell.command.finished")
}

#[test]
fn folds_finished_commands_once_in_order() {
    let mut fold = TerminalCommandFold::new("local");
    let records = vec![finished(1, Some("make"), Some(0), 1_000), finished(2, None, None, 2_000)];
    fold.apply(&records);
    fold.apply(&records);
    let commands: Vec<_> = fold.commands().cloned().collect();
    assert_eq!(commands.len(), 2);
    let first = &commands[0];
    assert_eq!(first.command.as_deref(), Some("make"));
    assert_eq!(first.cwd.as_deref(), Some("/repo"));
    assert_eq!((first.exit_code, first.terminal.as_str()), (Some(0), "term_1"));
    assert_eq!((first.started_at_ms, first.duration_ms), (1_000, Some(250.0)));
    assert_eq!(first.qualified_id(), "local/term_1/1000");
    assert_eq!((commands[1].command.as_deref(), commands[1].exit_code), (None, None));
    assert_eq!(fold.cursor(), 2);
}

#[test]
fn other_kinds_advance_the_cursor_only() {
    let mut fold = TerminalCommandFold::with_capacity("local", 2);
    fold.apply(&[record(1, Some("x"), Some(0), 1_000, "agent.turn.started")]);
    assert_eq!((fold.commands().len(), fold.cursor()), (0, 1));
    let records: Vec<Value> = (2..=5).map(|n| finished(n, Some(&format!("c{n}")), Some(0), n as i64 * 1000)).collect();
    fold.apply(&records);
    let names: Vec<_> = fold.commands().map(|command| command.command.clone().unwrap_or_default()).collect();
    assert_eq!(names, ["c4", "c5"]);
}

#[test]
fn a_record_without_a_terminal_or_start_moves_the_cursor_only() {
    let mut fold = TerminalCommandFold::new("local");
    fold.apply(&[
        json!({"sequence": 1, "kind": "shell.command.finished", "payload": {"started_at_ms": "5"}}),
        json!({"sequence": 2, "kind": "shell.command.finished", "subjects": [{"kind": "terminal", "id": "t"}], "payload": {}}),
    ]);
    assert_eq!((fold.commands().len(), fold.cursor()), (0, 2));
}

#[test]
fn entries_carry_command_fields_and_skip_hidden_ones() {
    let mut fold = TerminalCommandFold::new("box");
    fold.apply(&[finished(1, Some("make"), Some(2), 1_000), finished(2, None, None, 2_000)]);
    let mut hidden = HiddenHistory::new();
    hidden.hide_entry("box/term_1/1000");
    let entries = fold.entries(&EntryContext { local_machine: "home", available: true }, &hidden);
    assert_eq!(entries.len(), 1);
    assert_eq!(entries[0].id, "command:box/term_1/2000");
    assert_eq!(entries[0].title, "Command");
    assert_eq!(entries[0].machine.as_deref(), Some("box"));
    let all = fold.entries(&EntryContext { local_machine: "box", available: true }, &HiddenHistory::new());
    assert_eq!((all[0].exit_code, all[0].command.as_deref(), all[0].machine.as_deref()), (Some(2), Some("make"), None));
}
