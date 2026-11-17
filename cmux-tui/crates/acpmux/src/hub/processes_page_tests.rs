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

/// An unpaged list of a long history (the 34 MB `_acpmux/process/list` refused on 2026-11-11)
/// is one reply's worth: the newest that fit, in the order they started, with how many older
/// ones it left out; and only those rows have their output file's size read.
#[test]
fn an_unpaged_list_past_one_reply_keeps_the_newest_that_fit() {
    let processes: Vec<Process> = (0..20_000).map(|i| make(i, "build ".repeat(300))).collect();
    let read = std::cell::Cell::new(0_usize);
    let length = |_: &str| {
        read.set(read.get() + 1);
        0
    };
    let mut processes = processes;
    for p in &mut processes {
        p.output_file = Some("/nonexistent".into());
    }
    let reply = process_window_values(processes, PROCESS_PAGE_BUDGET, length);
    let bytes = reply.to_string().len();
    assert!(bytes <= PROCESS_PAGE_BUDGET, "{bytes} bytes");
    assert!(bytes <= crate::rpc::REPLY_PAGE_BYTES, "{bytes} bytes");
    let rows = reply["processes"].as_array().unwrap();
    assert!(rows.len() > 100, "{} rows", rows.len());
    assert_eq!(rows.last().unwrap()["id"], "session/task-19999", "the newest is kept");
    let first: usize =
        rows[0]["taskId"].as_str().unwrap().trim_start_matches("task-").parse().unwrap();
    assert_eq!(first + rows.len(), 20_000, "a contiguous newest window, oldest first");
    assert_eq!(reply["omitted"], 20_000 - rows.len());
    // The rows kept, and the one that did not fit.
    assert_eq!(read.get(), rows.len() + 1);
}

/// One that fits is the whole list, as before, and says nothing was left out.
#[test]
fn an_unpaged_list_that_fits_is_whole() {
    let processes: Vec<Process> = (0..3).map(|i| make(i, format!("command-{i}"))).collect();
    let full = process_values(processes.clone(), output_len);
    let reply = process_window_values(processes, PROCESS_PAGE_BUDGET, output_len);
    assert_eq!(reply, json!({"processes": full}));
}

/// What a chat's page holds (`recent`): every running process, however old, and the newest ended
/// ones, in start order, with every older ended one counted in `omitted`. A god chat (56,000
/// shells) gave its page all of them, 66 MB of JSON parsed into the renderer (2026-11-16).
#[test]
fn recent_keeps_every_running_process_and_the_newest_ended_ones() {
    let mut table = ProcessTable::default();
    for index in 0..10_000 {
        let mut process = make(index, format!("step {index}"));
        if index % 2_500 == 7 {
            process.state = ProcessState::Running;
        }
        table.upsert(process);
    }
    let (kept, older) = table.recent_snapshot(100);
    let ids: Vec<&str> = kept.iter().map(|p| p.id.as_str()).collect();
    let running: Vec<&str> =
        kept.iter().filter(|p| p.state == ProcessState::Running).map(|p| p.id.as_str()).collect();
    assert_eq!(
        running,
        ["session/task-7", "session/task-2507", "session/task-5007", "session/task-7507"]
    );
    assert_eq!(kept.iter().filter(|p| p.state != ProcessState::Running).count(), 100);
    assert_eq!(ids.last(), Some(&"session/task-9999"));
    assert_eq!(ids[4], "session/task-9900", "the ended window follows the older running ones");
    assert_eq!(older + kept.len(), 10_000);
    let reply = recent_values(kept, older, 100, PROCESS_PAGE_BUDGET, |_| 0);
    assert_eq!(reply["processes"].as_array().unwrap().len(), 104);
    assert_eq!(reply["recent"], 100);
    assert_eq!(reply["omitted"], 10_000 - 104);

    let (all, none) = table.recent_snapshot(1_000_000);
    assert_eq!((all.len(), none), (10_000, 0));
    let (empty, zero) = ProcessTable::default().recent_snapshot(10);
    assert!(empty.is_empty() && zero == 0);
}

/// A reply cut to its size drops the oldest ended rows, never a running one: a dev server started at
/// the chat's beginning is the oldest row of all, and a cut from the oldest end lost it (review of
/// cmux#44174).
#[test]
fn a_recent_reply_cut_to_size_keeps_the_oldest_running_process() {
    let mut table = ProcessTable::default();
    let mut server = make(0, "serve".to_owned());
    server.state = ProcessState::Running;
    table.upsert(server);
    for index in 1..400 {
        table.upsert(make(index, "x".repeat(3_000)));
    }
    let (kept, older) = table.recent_snapshot(500);
    let reply = recent_values(kept, older, 500, 200_000, |_| 0);
    let rows = reply["processes"].as_array().unwrap();
    assert!(reply.to_string().len() < 200_000);
    assert_eq!(rows[0]["id"], "session/task-0", "the running server is kept, first in start order");
    assert_eq!(rows.last().unwrap()["id"], "session/task-399");
    assert_eq!(reply["omitted"].as_u64().unwrap() as usize, 400 - rows.len());
}
