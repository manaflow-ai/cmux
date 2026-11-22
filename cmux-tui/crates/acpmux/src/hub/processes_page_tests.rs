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

/// Process `index` that ended at `end` (None: still running).
fn ended(index: usize, end: Option<u64>, command: String) -> Process {
    let mut process = make(index, command);
    match end {
        Some(end) => process.ended_at = Some(end),
        None => process.state = ProcessState::Running,
    }
    process
}

/// What a chat's page holds (`recent`): every running process, however old, and the ones that
/// ended last, in start order, with every other ended one counted in `omitted` and split from the
/// kept ones by their end (`endedBefore`). A god chat (56,000 shells) gave its page all of them,
/// 66 MB of JSON parsed into the renderer (2026-11-16).
#[test]
fn recent_keeps_every_running_process_and_the_ones_that_ended_last() {
    let mut table = ProcessTable::default();
    for index in 0..10_000 {
        let end = (index % 2_500 != 7).then_some(1_000 + index as u64);
        table.upsert(ended(index, end, format!("step {index}")));
    }
    let (kept, older, cutoff) = table.recent_snapshot(100, None);
    let running: Vec<&str> =
        kept.iter().filter(|p| p.state == ProcessState::Running).map(|p| p.id.as_str()).collect();
    assert_eq!(
        running,
        ["session/task-7", "session/task-2507", "session/task-5007", "session/task-7507"]
    );
    let ends: Vec<u64> = kept.iter().filter_map(|p| p.ended_at).collect();
    assert_eq!(ends.len(), 100);
    assert!(ends.iter().all(|&end| end >= cutoff));
    assert_eq!(cutoff, 1_000 + 9_900);
    assert_eq!(kept.last().unwrap().id, "session/task-9999");
    assert_eq!(older + kept.len(), 10_000);
    let reply = recent_values(kept, older, cutoff, 100, PROCESS_PAGE_BUDGET, |_| 0).unwrap();
    assert_eq!(reply["processes"].as_array().unwrap().len(), 104);
    assert_eq!(reply["recent"], 100);
    assert_eq!(reply["omitted"], 10_000 - 104);
    assert_eq!(reply["endedBefore"], 10_900);

    let (all, none, zero) = table.recent_snapshot(1_000_000, None);
    assert_eq!((all.len(), none, zero), (10_000, 0, 0));
    let reply = recent_values(all, none, zero, 1_000_000, usize::MAX, |_| 0).unwrap();
    assert!(reply.get("omitted").is_none() && reply.get("endedBefore").is_none());
    let (empty, nothing, _) = ProcessTable::default().recent_snapshot(10, None);
    assert!(empty.is_empty() && nothing == 0);
}

/// The window is by end, not by start: a server started first that ended a moment ago is one of
/// the ones that ended last (the tray shows it as just ended), and every process that ended
/// within `endedWithin` is kept however many did. Ties at the split stay together.
#[test]
fn recent_is_by_end_keeps_ties_and_what_ended_within_the_window() {
    let mut table = ProcessTable::default();
    table.upsert(ended(0, Some(50_000), "serve".to_owned()));
    for index in 1..1_000 {
        table.upsert(ended(index, Some(index as u64), format!("step {index}")));
    }
    let (kept, older, cutoff) = table.recent_snapshot(10, None);
    assert_eq!(kept[0].id, "session/task-0", "the old server that ended last is kept, first");
    assert_eq!(kept.len(), 10);
    assert_eq!((older, cutoff), (990, 991));

    // Four processes end at the split's end (10): all four are kept, past `recent`.
    let mut tied = ProcessTable::default();
    for index in 0..20 {
        let end = if (5..8).contains(&index) { 10 } else { index as u64 };
        tied.upsert(ended(index, Some(end), String::new()));
    }
    let (kept, older, cutoff) = tied.recent_snapshot(11, None);
    assert_eq!(cutoff, 10);
    assert!(kept.iter().all(|p| p.ended_at.unwrap() >= 10));
    assert_eq!((kept.len(), older), (13, 7));

    // `ended_since` widens the window to every end at or after it.
    let (kept, older, cutoff) = table.recent_snapshot(10, Some(500));
    assert_eq!(cutoff, 500);
    assert_eq!(kept.len(), 1 + 500);
    assert_eq!(older, 499);
}

/// A reply cut to its size drops whole ends, the first to end first, never a running one: a dev
/// server started at the chat's beginning is the oldest row of all, and a cut from the oldest end
/// lost it (review of cmux#44174). `endedBefore` moves with the cut, so it still splits kept from
/// left out.
#[test]
fn a_recent_reply_cut_to_size_keeps_running_ones_and_one_split() {
    let mut table = ProcessTable::default();
    table.upsert(ended(0, None, "serve".to_owned()));
    for index in 1..400 {
        table.upsert(ended(index, Some(index as u64 / 2), "x".repeat(3_000)));
    }
    let (kept, older, cutoff) = table.recent_snapshot(500, None);
    let reply = recent_values(kept, older, cutoff, 500, 200_000, |_| 0).unwrap();
    let rows = reply["processes"].as_array().unwrap();
    assert!(reply.to_string().len() < 200_000);
    assert_eq!(rows[0]["id"], "session/task-0", "the running server is kept, first in start order");
    assert_eq!(rows.last().unwrap()["id"], "session/task-399");
    assert_eq!(reply["omitted"].as_u64().unwrap() as usize, 400 - rows.len());
    let split = reply["endedBefore"].as_u64().unwrap();
    assert!(rows.iter().skip(1).all(|row| row["endedAt"].as_u64().unwrap() >= split));
    let kept_ids: std::collections::HashSet<&str> =
        rows.iter().map(|row| row["id"].as_str().unwrap()).collect();
    for index in 1..400_u64 {
        let kept = kept_ids.contains(format!("session/task-{index}").as_str());
        assert_eq!(kept, index / 2 >= split, "task {index} ended at {}", index / 2);
    }
}

/// `calls`: the processes those tool calls started, however old, in start order, each call
/// answered whole; a reply full before the last call says how many it answered.
#[test]
fn calls_read_their_processes_whatever_their_age() {
    let mut table = ProcessTable::default();
    for index in 0..5_000 {
        table.upsert(ended(index, Some(index as u64), "y".repeat(2_000)));
    }
    let calls: Vec<String> =
        ["call-4000", "call-3", "call-none", "call-17"].map(str::to_owned).to_vec();
    let reply = call_values(table.call_snapshot(&calls), PROCESS_PAGE_BUDGET, |_| 0);
    let ids: Vec<&str> = reply["processes"]
        .as_array()
        .unwrap()
        .iter()
        .map(|row| row["id"].as_str().unwrap())
        .collect();
    assert_eq!(ids, ["session/task-3", "session/task-17", "session/task-4000"]);
    assert_eq!(reply["answered"], 4);

    let many: Vec<String> = (0..1_000).map(|n| format!("call-{n}")).collect();
    let reply = call_values(table.call_snapshot(&many), 100_000, |_| 0);
    let answered = reply["answered"].as_u64().unwrap() as usize;
    assert!((1..1_000).contains(&answered));
    assert_eq!(reply["processes"].as_array().unwrap().len(), answered);
    assert!(reply.to_string().len() < 100_000);
}

/// What a chat's page holds (`recent`): every running process, however old, and the newest ended
/// ones, in start order, with every older ended one counted in `omitted`. A god chat (56,000
/// shells) gave its page all of them, 66 MB of JSON parsed into the renderer (2026-11-16).
#[test]
fn recent_keeps_every_running_process_and_the_newest_ended_ones() {
    let mut table = ProcessTable::default();
    for index in 0..10_000 {
        let mut process = ended(index, Some(index as u64), format!("step {index}"));
        if index % 2_500 == 7 {
            process.state = ProcessState::Running;
            process.ended_at = None;
        }
        table.upsert(process);
    }
    let (kept, older, cutoff) = table.recent_snapshot(100, None);
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
    let reply = recent_values(kept, older, cutoff, 100, PROCESS_PAGE_BUDGET, |_| 0).unwrap();
    assert_eq!(reply["processes"].as_array().unwrap().len(), 104);
    assert_eq!(reply["recent"], 100);
    assert_eq!(reply["omitted"], 10_000 - 104);

    let (all, none, _) = table.recent_snapshot(1_000_000, None);
    assert_eq!((all.len(), none), (10_000, 0));
    let (empty, zero, _) = ProcessTable::default().recent_snapshot(10, None);
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
        table.upsert(ended(index, Some(index as u64), "x".repeat(3_000)));
    }
    let (kept, older, cutoff) = table.recent_snapshot(500, None);
    let reply = recent_values(kept, older, cutoff, 500, 200_000, |_| 0).unwrap();
    let rows = reply["processes"].as_array().unwrap();
    assert!(reply.to_string().len() < 200_000);
    assert_eq!(rows[0]["id"], "session/task-0", "the running server is kept, first in start order");
    assert_eq!(rows.last().unwrap()["id"], "session/task-399");
    assert_eq!(reply["omitted"].as_u64().unwrap() as usize, 400 - rows.len());
}

#[test]
fn a_recent_reply_refuses_running_rows_that_only_fit_individually() {
    let budget = 4_096;
    let mut table = ProcessTable::default();
    for index in 0..8 {
        let mut process = ended(index, Some(index as u64), "x".repeat(600));
        process.state = ProcessState::Running;
        process.ended_at = None;
        let single = recent_values(vec![process.clone()], 0, 0, 100, budget, |_| 0).unwrap();
        assert!(single.to_string().len() <= budget);
        assert_eq!(single["processes"][0]["id"], process.id);
        table.upsert(process);
    }
    let (kept, older, cutoff) = table.recent_snapshot(100, None);
    let error = recent_values(kept, older, cutoff, 100, budget, |_| 0).unwrap_err();
    assert_eq!(error.data.as_ref().unwrap()["reason"], "message.too_large");
    assert!(error.data.as_ref().unwrap()["bytes"].as_u64().unwrap() > budget as u64);
}

#[test]
fn a_recent_reply_keeps_every_running_row_when_ended_rows_exceed_the_budget() {
    let mut table = ProcessTable::default();
    for index in 0..100 {
        let mut process = ended(index, Some(index as u64), "x".repeat(600));
        if [0, 40, 80].contains(&index) {
            process.state = ProcessState::Running;
            process.ended_at = None;
        }
        table.upsert(process);
    }
    let (kept, older, cutoff) = table.recent_snapshot(100, None);
    let reply = recent_values(kept, older, cutoff, 100, 4_096, |_| 0).unwrap();
    assert!(reply.to_string().len() <= 4_096);
    let rows = reply["processes"].as_array().unwrap();
    let running: Vec<&str> = rows
        .iter()
        .filter(|row| row["state"] == "running")
        .map(|row| row["id"].as_str().unwrap())
        .collect();
    assert_eq!(running, ["session/task-0", "session/task-40", "session/task-80"]);
    assert_eq!(rows.last().unwrap()["id"], "session/task-99");
    assert_eq!(reply["omitted"].as_u64().unwrap() as usize, 100 - rows.len());
}

#[test]
fn a_recent_reply_refuses_a_running_identity_that_cannot_fit_as_a_stub() {
    let mut process = make(0, "serve".to_owned());
    process.state = ProcessState::Running;
    process.ended_at = None;
    process.id = format!("session/{}", "x".repeat(4_096));
    let error = recent_values(vec![process], 0, 0, 100, 1_000, |_| 0).unwrap_err();
    assert_eq!(error.data.as_ref().unwrap()["reason"], "message.too_large");
}
