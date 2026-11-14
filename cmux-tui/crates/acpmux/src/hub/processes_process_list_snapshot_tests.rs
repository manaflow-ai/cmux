use super::*;

#[test]
fn a_process_list_reads_output_metadata_after_releasing_its_table() {
    let process: Process = serde_json::from_value(json!({
        "id": "chat/task", "sessionId": "chat", "toolCallId": "call",
        "taskId": "task", "harness": "claude", "command": "cargo test",
        "cwd": "/tmp", "startedAt": 100, "endedAt": 200,
        "state": "exited", "origin": "background", "outputFile": "/tmp/task-output"
    }))
    .unwrap();
    let table = std::sync::Mutex::new(ProcessTable {
        loaded: true,
        processes: vec![process],
        ..ProcessTable::default()
    });
    // Every caller first takes its snapshot, then drops the guard before
    // collecting live file sizes and serializing the reply.
    let snapshot = table.lock().unwrap().snapshot();
    let rows = process_values(snapshot, |path| {
        assert_eq!(path, "/tmp/task-output");
        assert!(table.try_lock().is_ok(), "filesystem metadata read under process-table lock");
        42
    });
    assert_eq!(rows.len(), 1);
    assert_eq!(rows[0]["id"], "chat/task");
    assert_eq!(rows[0]["state"], "exited");
    assert_eq!(rows[0]["outputBytes"], 42);
    // The saved table remains unchanged: a later list re-reads the file size.
    assert_eq!(table.lock().unwrap().processes[0].output_bytes, None);
}
