//! Paged history keeps live process identity and order while responses stay within the
//! RPC frame cap. The full unpaged process/list contract is unchanged.
use super::*;

fn make(index: usize, command: String) -> Process {
    serde_json::from_value(json!({
        "id": format!("session/task-{index}"),
        "sessionId": "session",
        "toolCallId": format!("call-{index}"),
        "taskId": format!("task-{index}"),
        "harness": "claude",
        "command": command,
        "cwd": "/tmp",
        "startedAt": index,
        "state": "exited",
        "origin": "background"
    }))
    .unwrap()
}

#[test]
fn three_thousand_records_page_once_in_append_order_with_a_byte_budget() {
    let mut table = ProcessTable::default();
    for index in 0..3_000 {
        table.upsert(make(index, "build ".repeat(60)));
    }
    let (mut next, mut ids) = (None::<String>, Vec::new());
    for _ in 0..500 {
        let (window, more) = table.page_snapshot(1_000, next.as_deref()).unwrap();
        let result = process_page_values(window, more, 8_000).unwrap();
        assert!(result.to_string().len() < 8_000, "a page exceeded its byte budget");
        for row in result["processes"].as_array().unwrap() {
            ids.push(row["id"].as_str().unwrap().to_owned());
        }
        next = result["nextCursor"].as_str().map(str::to_owned);
        if next.is_none() {
            break;
        }
    }
    assert_eq!(ids.len(), 3_000);
    assert_eq!(ids[0], "session/task-0");
    assert_eq!(ids[2_999], "session/task-2999");
    assert_eq!(ids.iter().collect::<std::collections::HashSet<_>>().len(), 3_000);
}

#[test]
fn a_complete_short_page_returns_the_same_rows_as_the_unpaged_contract() {
    let mut table = ProcessTable::default();
    for index in 0..3 {
        table.upsert(make(index, format!("command-{index}")));
    }
    let full = process_values(table.snapshot(), output_len);
    let (window, more) = table.page_snapshot(10, None).unwrap();
    assert!(!more);
    let page = process_page_values(window, more, 16_000).unwrap();
    assert_eq!(page["processes"], json!(full));
    assert!(page["nextCursor"].is_null());
}

#[test]
fn a_page_sees_live_changes_and_new_records_after_its_cursor() {
    let mut table = ProcessTable::default();
    for index in 0..4 {
        table.upsert(make(index, "command".into()));
    }
    let (window, more) = table.page_snapshot(2, None).unwrap();
    let first = process_page_values(window, more, 4_096).unwrap();
    assert_eq!(first["processes"].as_array().unwrap().len(), 2);
    let cursor = first["nextCursor"].as_str().unwrap();
    let mut changed = make(2, "command".into());
    changed.state = ProcessState::Running;
    table.upsert(changed);
    table.upsert(make(4, "next command".into()));
    let (window, more) = table.page_snapshot(3, Some(cursor)).unwrap();
    let next = process_page_values(window, more, 4_096).unwrap();
    assert_eq!(next["processes"][0]["id"], "session/task-2");
    assert_eq!(next["processes"][0]["state"], "running");
    assert_eq!(next["processes"][2]["id"], "session/task-4");
    assert!(next["nextCursor"].is_null());
    assert!(table.page_snapshot(1, Some("session/missing")).is_err());
}

#[test]
fn one_oversized_command_yields_a_stop_capable_stub() {
    let mut table = ProcessTable::default();
    table.upsert(make(0, "x".repeat(20_000)));
    let (window, more) = table.page_snapshot(1, None).unwrap();
    let result = process_page_values(window, more, 1_000).unwrap();
    let row = &result["processes"][0];
    assert_eq!(row["id"], "session/task-0");
    assert_eq!(row["toolCallId"], "call-0");
    assert_eq!(row["state"], "exited");
    assert_eq!(row["command"], "");
    assert_eq!(row["omitted"]["reason"], "too_large");
    assert!(result.to_string().len() < 1_000);
    assert!(result["nextCursor"].is_null());
}
