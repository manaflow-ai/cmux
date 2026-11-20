//! The active-process set tracks logged replay and live transitions without scanning
//! historical finished work. It preserves the event order when a host ends.
use super::*;

fn process(index: usize, state: ProcessState) -> Process {
    serde_json::from_value(json!({
        "id": format!("session/task-{index}"),
        "sessionId": "session",
        "toolCallId": format!("tool-{index}"),
        "taskId": format!("task-{index}"),
        "harness": "claude",
        "command": "true",
        "cwd": "/tmp",
        "startedAt": 100,
        "state": state,
        "origin": "background",
    }))
    .unwrap()
}

#[test]
fn the_live_set_follows_replay_updates_and_preserves_lost_notification_order() {
    let mut table = ProcessTable::default();
    for index in 0..3_000 {
        table.upsert(process(index, ProcessState::Exited));
    }
    assert_eq!(table.processes.len(), 3_000);
    assert!(table.running.is_empty());

    // Late replay of an existing process turns it on, then off, without an extra row.
    for index in [2_999, 17, 1_500] {
        table.upsert(process(index, ProcessState::Running));
    }
    assert_eq!(table.running.len(), 3);
    table.upsert(process(17, ProcessState::Exited));
    assert_eq!(table.running.len(), 2);
    table.upsert(process(17, ProcessState::Running));
    assert_eq!(table.running.len(), 3);

    // A host exit logs active tasks in their original append order, even when
    // status updates arrived in a different order.
    let lost = table.lose_running(200, HARNESS_EXIT, true);
    let ids: Vec<_> = lost.iter().map(|p| p.id.as_str()).collect();
    assert_eq!(ids, ["session/task-17", "session/task-1500", "session/task-2999"]);
    assert!(lost.iter().all(|p| {
        p.state == ProcessState::Lost
            && p.ended_at == Some(200)
            && p.reason.as_deref() == Some(HARNESS_EXIT)
            && p.logged
    }));
    assert_eq!(table.processes.len(), 3_000);
    assert!(table.running.is_empty());
    assert!(table.lose_running(201, HARNESS_EXIT, true).is_empty());
}

#[test]
fn a_restored_running_task_is_removed_from_the_live_set_when_completed() {
    let mut table = ProcessTable::default();
    table.upsert(process(0, ProcessState::Running));
    assert_eq!(table.running.len(), 1);
    table.upsert(process(0, ProcessState::Failed));
    assert!(table.running.is_empty());
    table.upsert(process(1, ProcessState::Running));
    assert_eq!(table.running.len(), 1);
    table.upsert(process(1, ProcessState::Killed));
    assert!(table.running.is_empty());
    assert_eq!(table.processes.len(), 2);
}
