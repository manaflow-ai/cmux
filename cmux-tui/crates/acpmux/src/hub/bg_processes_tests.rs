//! A daemon task's row (`bg_processes.rs`) outlives the harness: a harness exit loses Claude's
//! own background shells, which end with it, and leaves a daemon task's row running.
use super::*;

fn row(index: usize, origin: &str) -> Process {
    serde_json::from_value(json!({
        "id": format!("session/task-{index}"),
        "sessionId": "session",
        "toolCallId": format!("tool-{index}"),
        "taskId": format!("task-{index}"),
        "harness": "claude",
        "command": "sleep 30",
        "cwd": "/tmp",
        "startedAt": 100,
        "state": "running",
        "origin": origin,
    }))
    .unwrap()
}

#[test]
fn a_harness_exit_loses_claudes_shells_and_keeps_daemon_tasks_running() {
    let mut table = ProcessTable::default();
    table.upsert(row(0, "background"));
    table.upsert(row(1, DAEMON_TASK));
    table.upsert(row(2, "background"));
    let lost: Vec<String> =
        table.lose_running(200, HARNESS_EXIT, true).into_iter().map(|p| p.id).collect();
    assert_eq!(lost, ["session/task-0", "session/task-2"]);
    let task = table.find_id("session/task-1").unwrap();
    assert_eq!((task.state, task.ended_at), (ProcessState::Running, None));
    assert_eq!(table.running.iter().copied().collect::<Vec<_>>(), [1]);
    // A second exit loses nothing more.
    assert!(table.lose_running(300, HARNESS_EXIT, true).is_empty());
}
