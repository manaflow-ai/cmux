//! In-memory id/tool indexes mirror the append-order process log, including replay corrections.
use super::*;

fn process(id: &str, tool: &str) -> Process {
    serde_json::from_value(json!({
        "id": id, "sessionId": "session", "toolCallId": tool, "taskId": "task",
        "harness": "claude", "command": "true", "cwd": "/tmp",
        "startedAt": 1, "state": "running", "origin": "background"
    }))
    .unwrap()
}

#[test]
fn ids_remain_unique_and_tool_indices_preserve_first_occurrence() {
    let mut table = ProcessTable::default();
    table.upsert(process("session/task", "tool-a"));
    table.upsert(process("session/task-2", "tool-a"));
    table.upsert(process("session/task-3", "tool-b"));
    assert_eq!(table.find_tool("tool-a"), Some(0));
    assert_eq!(table.find_id("session/task-2").unwrap().tool_call_id, "tool-a");
    assert_eq!(table.unused_id("session/task".into()), "session/task-4");

    // Upsert replaces its existing id's slot without reordering either process.
    table.upsert(process("session/task", "tool-c"));
    assert_eq!(table.find_tool("tool-a"), Some(1));
    assert_eq!(table.find_tool("tool-c"), Some(0));
    table.upsert(process("session/task-3", "tool-a"));
    assert_eq!(table.find_tool("tool-a"), Some(1)); // earliest occurrence still wins
    table.upsert(process("session/task-2", "tool-d"));
    assert_eq!(table.find_tool("tool-a"), Some(2));
    assert_eq!(table.processes.len(), 3);
    assert_eq!(table.find_id("session/task-2").unwrap().tool_call_id, "tool-d");
}

#[test]
fn three_thousand_replayed_processes_have_one_index_slot_each() {
    let mut table = ProcessTable::default();
    for i in 0..3_000 {
        table.upsert(process(&format!("session/task-{i}"), &format!("tool-{i}")));
    }
    assert_eq!(table.processes.len(), 3_000);
    assert_eq!(table.by_id.len(), 3_000);
    assert_eq!(table.by_tool.len(), 3_000);
    for i in 0..3_000 {
        assert_eq!(table.find_tool(&format!("tool-{i}")), Some(i));
        assert_eq!(
            table.find_id(&format!("session/task-{i}")).unwrap().tool_call_id,
            format!("tool-{i}")
        );
    }
    // A historical answer arriving again replaces its row, never duplicates it.
    table.upsert(process("session/task-999", "tool-999"));
    assert_eq!(table.processes.len(), 3_000);
    assert_eq!(table.unused_id("session/task-999".into()), "session/task-999-2");
}

#[test]
fn a_description_round_trips_and_is_left_out_when_absent() {
    let mut value = serde_json::to_value(process("session/task", "tool-a")).unwrap();
    assert!(value.get("description").is_none());
    value["description"] = json!("Wait for the PR checks to finish");
    let process: Process = serde_json::from_value(value).unwrap();
    assert_eq!(process.description.as_deref(), Some("Wait for the PR checks to finish"));
    assert_eq!(
        serde_json::to_value(&process).unwrap()["description"],
        json!("Wait for the PR checks to finish")
    );
}

/// A running daemon task (`bg_registry.rs`) stays out of the harness's live set through an index
/// rebuild (a shrink, a checkpoint restore), so it never keeps its chat awake, and a row the table
/// dropped (it had ended) is never put back.
#[test]
fn a_rebuilt_index_keeps_daemon_tasks_out_of_the_harness_live_set() {
    let mut table = ProcessTable::default();
    table.upsert(process("session/shell", "tool-shell"));
    let mut daemon = process("session/bg-1", "tool-bg");
    daemon.daemon_task = true;
    table.upsert(daemon);
    table.reindex();
    assert_eq!(table.running.len(), 1, "only the harness's shell");
    assert_eq!(table.daemon_live(), vec![("session/bg-1".to_owned(), "task".to_owned())]);
    table.dropped.ids.push(key("session/bg-old"));
    table.dropped.count = 1;
    let mut gone = process("session/bg-old", "tool-old");
    gone.state = ProcessState::Lost;
    assert!(table.daemon_upsert(gone).is_none(), "a dropped row stays ended");
    assert!(table.find_id("session/bg-old").is_none());
}

/// A daemon task an older daemon logged as a harness shell (no `daemonTask`): running, it moves
/// from the harness's live set to the daemon's; lost with its harness, the task's folder, which
/// says it runs, brings it back.
#[test]
fn a_daemon_task_an_older_daemon_logged_comes_back_as_a_daemon_task() {
    let mut table = ProcessTable::default();
    table.upsert(process("session/bg-1", "tool-1"));
    assert_eq!(table.running.len(), 1, "read as a harness shell");
    let mut daemon = process("session/bg-1", "tool-1");
    daemon.daemon_task = true;
    daemon.origin = "daemon".to_owned();
    assert!(table.daemon_upsert(daemon.clone()).is_some());
    assert_eq!(table.running.len(), 0, "out of the harness's live set");
    assert_eq!(table.daemon_live().len(), 1);

    let mut lost = process("session/bg-2", "tool-2");
    lost.state = ProcessState::Lost;
    lost.reason = Some(HARNESS_EXIT.to_owned());
    table.upsert(lost);
    assert!(table.daemon_row_missing("session/bg-2"));
    let mut again = daemon;
    again.id = "session/bg-2".to_owned();
    again.tool_call_id = "tool-2".to_owned();
    assert!(table.daemon_upsert(again).is_some(), "its folder says it runs");
    assert_eq!(table.daemon_live().len(), 2);
    assert!(!table.daemon_row_missing("session/bg-2"));
}

/// Daemon tasks with no call share an empty one: a shrink keys none for it, so a later row with no
/// call never reads the whole history back.
#[test]
fn a_shrink_keys_no_empty_call() {
    let mut table = ProcessTable::default();
    for i in 0..(HELD_ENDED + 10) {
        let mut row = process(&format!("session/bg-{i}"), "");
        row.daemon_task = true;
        row.state = ProcessState::Exited;
        row.ended_at = Some(10 + i as u64);
        table.upsert(row);
    }
    table.shrink(true);
    assert!(!table.dropped.is_empty(), "it shrank");
    assert!(!table.dropped.has_tool(""));
    let mut next = process("session/bg-new", "");
    next.daemon_task = true;
    assert!(!table.upsert_needs_history(&next));
}
