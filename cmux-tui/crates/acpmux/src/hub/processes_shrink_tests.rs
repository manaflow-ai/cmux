//! A shrunk table (`ProcessTable::shrink`) answers what it says it answers as the whole history
//! does, and says no to the rest. Leo, 2026-11-19: "we need to be able to have infinite chats,
//! infinitely long chats" (cmux#51494: the table held every process ever run, 32 MB of a 4 GB
//! chat's 36 MB checkpoint).
use super::*;

fn row(index: usize, end: Option<u64>) -> Process {
    let mut process: Process = serde_json::from_value(json!({
        "id": format!("session/task-{index}"),
        "sessionId": "session",
        "toolCallId": format!("call-{index}"),
        "taskId": format!("task-{index}"),
        "harness": "claude",
        "command": format!("step {index}"),
        "cwd": "/tmp",
        "startedAt": index,
        "state": "exited",
        "origin": "background"
    }))
    .unwrap();
    match end {
        // Ends out of start order, with ties, as shells end.
        Some(end) => process.ended_at = Some(end),
        None => process.state = ProcessState::Running,
    }
    process
}

fn table(rows: usize) -> ProcessTable {
    let mut table = ProcessTable { loaded: true, ..ProcessTable::default() };
    for index in 0..rows {
        let end = (index % 997 != 3).then_some(10_000 + ((index * 7919) % 20_000) as u64 / 2);
        table.upsert(row(index, end));
    }
    table
}

fn recent(table: &ProcessTable, n: usize, since: Option<u64>) -> Value {
    let (rows, older, cutoff) = table.recent_snapshot(n, since);
    recent_values(rows, older, cutoff, n, PROCESS_PAGE_BUDGET, |_| 0).unwrap()
}

#[test]
fn a_shrunk_table_holds_its_running_rows_and_the_last_to_end() {
    let mut partial = table(10_000);
    partial.shrink(true);
    let running = partial.processes.iter().filter(|p| p.state == ProcessState::Running).count();
    assert_eq!(running, 11);
    assert!(partial.processes.len() - running >= HELD_ENDED);
    assert!(partial.processes.len() - running < HELD_ENDED + 8, "ties only");
    assert_eq!(partial.dropped.count + partial.processes.len(), 10_000);
    // Shrinks again only past the bound, not at every end.
    let held = partial.processes.len();
    partial.upsert(row(10_000, Some(99_999)));
    partial.shrink(false);
    assert_eq!(partial.processes.len(), held + 1);
}

#[test]
fn a_shrunk_table_answers_recent_as_the_whole_one_or_says_it_cannot() {
    let whole = table(10_000);
    let mut partial = table(10_000);
    partial.shrink(true);
    let mut answered = 0;
    for n in [0, 1, 10, 100, 500, HELD_ENDED, HELD_ENDED + 1, 5_000, 100_000] {
        for since in [None, Some(0), Some(14_000), Some(19_990), Some(u64::MAX)] {
            if partial.answers_recent(n, since) {
                answered += 1;
                assert_eq!(recent(&partial, n, since), recent(&whole, n, since), "{n} {since:?}");
            }
        }
    }
    assert!(answered >= 12, "the page's own reads are answered: {answered}");
    assert!(!partial.answers_recent(5_000, None));
}

#[test]
fn a_shrunk_table_answers_calls_it_holds_and_names_the_dropped_ones() {
    let whole = table(10_000);
    let mut partial = table(10_000);
    partial.shrink(true);
    let held: Vec<String> =
        partial.processes.iter().take(50).map(|p| p.tool_call_id.clone()).collect();
    assert!(partial.answers_calls(&held));
    let calls = |t: &ProcessTable, c: &[String]| {
        call_values(t.call_snapshot(c), PROCESS_PAGE_BUDGET, |_| 0)
    };
    assert_eq!(calls(&partial, &held), calls(&whole, &held));
    let gone =
        whole.processes.iter().find(|p| partial.find_tool(&p.tool_call_id).is_none()).unwrap();
    assert!(!partial.answers_calls(std::slice::from_ref(&gone.tool_call_id)));
    assert!(partial.id_needs_history(&gone.id));
    assert!(!partial.id_needs_history(&held_id(&partial)));
    assert!(partial.upsert_needs_history(gone));
    assert!(!partial.upsert_needs_history(&row(20_000, None)));
}

fn held_id(table: &ProcessTable) -> String {
    table.processes[0].id.clone()
}

#[test]
fn a_shrunk_table_saved_and_restored_keeps_what_it_dropped() {
    let mut partial = table(10_000);
    partial.shrink(true);
    let (count, before) = (partial.dropped.count, partial.dropped.before);
    let rows = partial.processes.len();
    let restored = ProcessTable::restored(partial.into_saved());
    assert_eq!((restored.dropped.count, restored.dropped.before), (count, before));
    assert_eq!(restored.processes.len(), rows);
    assert!(
        !restored.answers_calls(&["call-0".to_owned()]) || restored.find_tool("call-0").is_some()
    );
    // An older checkpoint, with no `dropped`, reads as a whole table.
    let old: SavedProcesses = serde_json::from_value(json!({"through": 3, "rows": []})).unwrap();
    assert!(ProcessTable::restored(old).dropped.is_empty());
}

#[test]
fn a_table_held_whole_is_not_shrunk_again() {
    let mut whole = table(10_000);
    whole.held_whole = true;
    whole.shrink(true);
    assert_eq!(whole.processes.len(), 10_000);
}
