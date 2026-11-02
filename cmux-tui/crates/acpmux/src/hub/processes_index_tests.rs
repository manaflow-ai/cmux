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
