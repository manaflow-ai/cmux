//! The row table's laws (TH1-TH5 of cmux-fp ARCHITECTURE.md section 17, as hq#9655 states
//! them) over random logs, and the rows of a few logs written out by hand.

use proptest::prelude::*;
use serde_json::{Value, json};

use super::fold::{Patch, RowMirror, RowTable};
use super::page::{MAX_ROW_PAGE_BYTES, RowsCursor};
use super::{RowKind, fold::Row};
use crate::store::EventRecord;

pub(super) fn update(seq: u64, update: Value) -> EventRecord {
    let kind = update["sessionUpdate"].as_str().unwrap_or("").to_owned();
    EventRecord {
        seq,
        at: 1_000 + seq,
        dir: "in".into(),
        kind,
        msg: json!({"jsonrpc": "2.0", "method": "session/update",
            "params": {"sessionId": "chat", "update": update}}),
        host_seq: None,
    }
}

pub(super) fn mux(seq: u64, kind: &str, msg: Value) -> EventRecord {
    EventRecord { seq, at: 1_000 + seq, dir: "mux".into(), kind: kind.into(), msg, host_seq: None }
}

pub(super) fn chunk(
    seq: u64,
    text: &str,
    message: Option<&str>,
    segment: Option<&str>,
) -> EventRecord {
    let mut u =
        json!({"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": text}});
    if let Some(m) = message {
        u["messageId"] = json!(m);
    }
    let mut rec = update(seq, u);
    if let Some(s) = segment {
        rec.msg["params"]["_meta"] = json!({"acpmux": {"segment": s}});
    }
    rec
}

fn fold_with_patches(records: &[EventRecord]) -> (RowTable, Vec<Patch>) {
    let mut table = RowTable::new();
    let mut patches = Vec::new();
    for rec in records {
        table.apply(rec, &mut patches);
    }
    (table, patches)
}

fn ids(rows: &[Row]) -> Vec<&str> {
    rows.iter().map(|r| r.head.id.as_str()).collect()
}

#[test]
fn a_turn_folds_to_its_rows_in_the_order_they_began() {
    let log = [
        mux(1, "user_message", json!({"promptId": "p1", "turnId": "t1", "text": "hi"})),
        mux(2, "turn_started", json!({"turnId": "t1", "promptId": "p1"})),
        chunk(3, "Let me ", Some("m1"), None),
        chunk(4, "look.", Some("m1"), None),
        update(5, json!({"sessionUpdate": "usage_update", "used": 1, "size": 2})),
        update(
            6,
            json!({"sessionUpdate": "tool_call", "toolCallId": "c1", "title": "Read a.rs",
            "kind": "read", "status": "pending", "_meta": {"claude": {"tool": "Read"}}}),
        ),
        update(
            7,
            json!({"sessionUpdate": "tool_call_update", "toolCallId": "c1", "status": "completed",
            "content": [{"type": "content", "content": {"type": "text", "text": "fn a() {}"}}]}),
        ),
        chunk(8, "Done.", Some("m2"), None),
        mux(9, "turn_result", json!({"turnId": "t1", "promptId": "p1", "status": "completed"})),
    ];
    let table = RowTable::fold(&log);
    let rows = table.rows();
    assert_eq!(ids(rows), ["prompt:p1", "reply:t1.1", "tool:c1", "reply:t1.2", "turn:t1"]);
    assert_eq!(rows[1].text, "Let me look.");
    assert!(!rows[1].head.streaming, "a tool call ends the reply before it");
    assert_eq!(rows[2].text, "fn a() {}");
    assert_eq!(rows[2].head.status.as_deref(), Some("completed"));
    assert_eq!(rows[2].head.tool.as_deref(), Some("Read"));
    assert!(rows.iter().all(|r| r.head.turn.as_deref() == Some("t1")));
    assert!(
        rows[0].head.forkable && rows[4].head.forkable,
        "an ended turn forks at its prompt and end"
    );
    assert!(!rows[1].head.forkable);
    assert_eq!(rows.iter().map(|r| r.head.seq).collect::<Vec<_>>(), [1, 3, 6, 8, 9]);
}

#[test]
fn a_stamped_segment_keys_its_row_and_an_unstamped_log_gets_the_same_ids() {
    let stamped = [
        mux(1, "user_message", json!({"promptId": "p", "turnId": "t", "text": "go"})),
        chunk(2, "a", Some("m"), Some("t.1")),
        chunk(3, "b", Some("m"), Some("t.1")),
        update(
            4,
            json!({"sessionUpdate": "agent_thought_chunk", "content": {"type": "text", "text": "hm"}}),
        ),
        chunk(5, "c", Some("m"), Some("t.2")),
    ];
    let plain: Vec<EventRecord> = stamped
        .iter()
        .cloned()
        .map(|mut r| {
            if let Some(p) = r.msg.get_mut("params").and_then(Value::as_object_mut) {
                p.remove("_meta");
            }
            r
        })
        .collect();
    let a = RowTable::fold(&stamped);
    let b = RowTable::fold(&plain);
    assert_eq!(ids(a.rows()), ["prompt:p", "reply:t.1", "thought@4", "reply:t.2"]);
    assert_eq!(a.rows(), b.rows());
}

#[test]
fn a_segment_id_seen_again_after_a_restart_starts_its_own_row() {
    let log = [
        mux(1, "user_message", json!({"promptId": "p", "turnId": "t", "text": "go"})),
        chunk(2, "one", Some("m"), Some("t.1")),
        update(3, json!({"sessionUpdate": "tool_call", "toolCallId": "c", "status": "pending"})),
        chunk(4, "two", Some("m2"), Some("t.1")),
    ];
    let table = RowTable::fold(&log);
    assert_eq!(ids(table.rows()), ["prompt:p", "reply:t.1", "tool:c", "reply:t.1@4"]);
    assert_eq!(table.rows()[1].text, "one");
}

#[test]
fn a_steer_that_runs_as_the_next_prompt_keeps_its_row_where_it_is() {
    let log = [
        mux(1, "user_message", json!({"promptId": "p1", "turnId": "t1", "text": "first"})),
        chunk(2, "working", None, None),
        mux(3, "user_message", json!({"promptId": "p2", "steer": true, "text": "also this"})),
        chunk(4, "ok", None, None),
        mux(5, "turn_result", json!({"turnId": "t1", "status": "completed"})),
        mux(6, "user_message", json!({"promptId": "p2", "turnId": "t2", "text": "also this"})),
        chunk(7, "doing it", None, None),
    ];
    let table = RowTable::fold(&log);
    let rows = table.rows();
    assert_eq!(
        ids(rows),
        ["prompt:p1", "reply:t1.1", "prompt:p2", "reply:t1.2", "turn:t1", "reply:t2.1"]
    );
    assert!(!rows[2].head.steer, "it ran as a prompt");
    assert_eq!(rows[2].head.turn.as_deref(), Some("t2"));
}

#[test]
fn a_superseded_message_and_a_cleared_checklist_hide_their_rows_in_place() {
    let entries = json!([{"content": "x", "status": "pending"}]);
    let log = [
        mux(1, "user_message", json!({"promptId": "p", "turnId": "t", "text": "go"})),
        update(2, json!({"sessionUpdate": "plan", "entries": entries})),
        chunk(3, "partial", Some("old"), None),
        mux(4, "message_superseded", json!({"oldMessageId": "old", "newMessageId": "new"})),
        chunk(5, "whole", Some("new"), None),
        update(6, json!({"sessionUpdate": "plan", "entries": []})),
    ];
    let table = RowTable::fold(&log);
    let rows = table.rows();
    assert_eq!(rows.len(), 4);
    assert!(rows[1].head.hidden && rows[1].head.kind == RowKind::Plan);
    assert!(rows[2].head.hidden && rows[2].text == "partial");
    assert!(!rows[3].head.hidden && rows[3].text == "whole");
}

#[test]
fn a_subagent_update_and_a_load_replay_draw_no_row() {
    let mut sub = chunk(1, "child", None, None);
    sub.msg["params"]["_meta"] = json!({"acpmux": {"subagent": "s1"}});
    let mut replay = chunk(2, "old", None, None);
    replay.kind = "agent_message_chunk.replay".into();
    assert!(RowTable::fold(&[sub, replay]).rows().is_empty());
}

#[test]
fn a_row_larger_than_a_page_goes_cut_and_says_how_long_it_is() {
    let big = "x".repeat(MAX_ROW_PAGE_BYTES * 2);
    let table = RowTable::fold(&[chunk(1, &big, None, None)]);
    let page = table.page(RowsCursor::After(0), usize::MAX);
    assert_eq!(page.rows.len(), 1);
    assert!(serde_json::to_vec(&page).unwrap().len() <= MAX_ROW_PAGE_BYTES + 4096);
    assert_eq!(page.cut.len(), 1);
    assert_eq!(page.cut[0].text_bytes, big.len() as u64);
}

#[derive(Debug, Clone)]
enum Op {
    Prompt { id: Option<u8>, steer: bool, turn: u8 },
    TurnStarted { turn: u8 },
    TurnResult { turn: Option<u8> },
    Chunk { message: Option<u8>, text: String },
    Thought { text: String },
    ToolCall { id: u8, status: u8 },
    ToolUpdate { id: u8, status: u8, content: Option<String>, out: Option<String> },
    Plan { entries: u8 },
    Compaction { done: bool },
    Usage,
    Superseded { message: u8 },
    Notice,
}

fn word() -> impl Strategy<Value = String> {
    "[a-z é\n\"\\\\]{1,12}"
}

fn op() -> impl Strategy<Value = Op> {
    prop_oneof![
        2 => (proptest::option::of(0u8..6), any::<bool>(), 0u8..5)
            .prop_map(|(id, steer, turn)| Op::Prompt { id, steer, turn }),
        1 => (0u8..5).prop_map(|turn| Op::TurnStarted { turn }),
        1 => proptest::option::of(0u8..5).prop_map(|turn| Op::TurnResult { turn }),
        8 => (proptest::option::of(0u8..3), word()).prop_map(|(message, text)| Op::Chunk { message, text }),
        2 => word().prop_map(|text| Op::Thought { text }),
        2 => (0u8..4, 0u8..4).prop_map(|(id, status)| Op::ToolCall { id, status }),
        3 => (0u8..4, 0u8..4, proptest::option::of(word()), proptest::option::of(word()))
            .prop_map(|(id, status, content, out)| Op::ToolUpdate { id, status, content, out }),
        1 => (0u8..3).prop_map(|entries| Op::Plan { entries }),
        1 => any::<bool>().prop_map(|done| Op::Compaction { done }),
        1 => Just(Op::Usage),
        1 => (0u8..3).prop_map(|message| Op::Superseded { message }),
        1 => Just(Op::Notice),
    ]
}

const STATUSES: [&str; 4] = ["pending", "in_progress", "completed", "failed"];

fn record(seq: u64, op: &Op) -> EventRecord {
    match op {
        Op::Prompt { id, steer, turn } => {
            let mut msg = json!({"text": format!("prompt {seq}"), "turnId": format!("t{turn}")});
            if let Some(id) = id {
                msg["promptId"] = json!(format!("p{id}"));
            }
            if *steer {
                msg["steer"] = json!(true);
            }
            mux(seq, "user_message", msg)
        }
        Op::TurnStarted { turn } => mux(seq, "turn_started", json!({"turnId": format!("t{turn}")})),
        Op::TurnResult { turn } => {
            let msg = turn.map_or_else(
                || json!({"status": "completed"}),
                |t| json!({"turnId": format!("t{t}"), "status": "completed"}),
            );
            mux(seq, "turn_result", msg)
        }
        Op::Chunk { message, text } => {
            chunk(seq, text, message.map(|m| format!("m{m}")).as_deref(), None)
        }
        Op::Thought { text } => update(
            seq,
            json!({"sessionUpdate": "agent_thought_chunk", "content": {"type": "text", "text": text}}),
        ),
        Op::ToolCall { id, status } => update(
            seq,
            json!({"sessionUpdate": "tool_call", "toolCallId": format!("c{id}"), "title": format!("call {seq}"),
                "status": STATUSES[*status as usize]}),
        ),
        Op::ToolUpdate { id, status, content, out } => {
            let mut u = json!({"sessionUpdate": "tool_call_update", "toolCallId": format!("c{id}"),
                "status": STATUSES[*status as usize]});
            if let Some(text) = content {
                u["content"] =
                    json!([{"type": "content", "content": {"type": "text", "text": text}}]);
            }
            if let Some(data) = out {
                u["_meta"] = json!({"terminal_output": {"data": data}});
            }
            update(seq, u)
        }
        Op::Plan { entries } => {
            let list: Vec<Value> =
                (0..*entries).map(|n| json!({"content": format!("step {n}")})).collect();
            update(seq, json!({"sessionUpdate": "plan", "entries": list}))
        }
        Op::Compaction { done } => update(
            seq,
            json!({"sessionUpdate": "compaction", "state": if *done { "completed" } else { "running" }}),
        ),
        Op::Usage => update(seq, json!({"sessionUpdate": "usage_update", "used": 1, "size": 9})),
        Op::Superseded { message } => {
            mux(seq, "message_superseded", json!({"oldMessageId": format!("m{message}")}))
        }
        Op::Notice => mux(seq, "failover", json!({"from": "a", "to": "b"})),
    }
}

fn log() -> impl Strategy<Value = Vec<EventRecord>> {
    proptest::collection::vec(op(), 0..120)
        .prop_map(|ops| ops.iter().enumerate().map(|(n, op)| record(n as u64 + 1, op)).collect())
}

proptest! {
    #![proptest_config(ProptestConfig { cases: 512, ..ProptestConfig::default() })]

    /// TH1: fold(a ++ b) == apply(fold(a), b), for the table and for a reader's copy of it.
    #[test]
    fn th1_folding_in_two_parts_is_folding_at_once(log in log(), cut in 0usize..121) {
        let cut = cut.min(log.len());
        let whole = RowTable::fold(&log);
        let (mut part, first) = fold_with_patches(&log[..cut]);
        let mut rest = Vec::new();
        for rec in &log[cut..] {
            part.apply(rec, &mut rest);
        }
        prop_assert_eq!(&part, &whole);
        let mut mirror = RowMirror::default();
        for p in first.iter().chain(&rest) {
            prop_assert_eq!(mirror.apply(p), Ok(()));
        }
        prop_assert_eq!(mirror.rows.as_slice(), whole.rows());
        prop_assert_eq!(mirror.version, whole.version());
        // A record read again (a page and the live stream) changes nothing.
        let mut again = Vec::new();
        for rec in &log {
            part.apply(rec, &mut again);
        }
        prop_assert!(again.is_empty());
    }

    /// TH2: a row once there stays, at its place, under its id.
    #[test]
    fn th2_rows_never_move_or_vanish(log in log()) {
        let mut table = RowTable::new();
        let mut before: Vec<String> = Vec::new();
        let mut sink = Vec::new();
        for rec in &log {
            table.apply(rec, &mut sink);
            let now = ids(table.rows());
            prop_assert!(now.len() >= before.len());
            let kept: Vec<&str> = before.iter().map(String::as_str).collect();
            prop_assert_eq!(&now[..before.len()], kept.as_slice());
            before = now.into_iter().map(str::to_owned).collect();
        }
    }

    /// TH3: a reply or thought delta that goes on in its row costs its own length: one `Append`
    /// carrying the delta, nothing else.
    #[test]
    fn th3_a_delta_costs_its_length(log in log()) {
        let mut table = RowTable::new();
        for rec in &log {
            let rows = table.rows().len();
            let mut out = Vec::new();
            table.apply(rec, &mut out);
            let delta = rec.msg.pointer("/params/update/content/text").and_then(Value::as_str);
            let streamed = matches!(rec.kind.as_str(), "agent_message_chunk" | "agent_thought_chunk");
            if streamed && table.rows().len() == rows && let Some(delta) = delta {
                prop_assert_eq!(out.len(), 1);
                let is_delta = matches!(&out[0], Patch::Append { text, .. } if text == delta);
                prop_assert!(is_delta, "{:?}", out);
            }
        }
    }

    /// TH4: versions, places and revisions have no gap; rows rise in seq.
    #[test]
    fn th4_no_gaps(log in log()) {
        let (table, patches) = fold_with_patches(&log);
        for (n, p) in patches.iter().enumerate() {
            prop_assert_eq!(p.version(), n as u64 + 1);
        }
        let mut revs = vec![0u64; table.rows().len()];
        for p in &patches {
            let (index, rev) = match p {
                Patch::Insert { row, .. } => (row.head.index, row.head.rev),
                Patch::Append { index, rev, .. } | Patch::Text { index, rev, .. } => (*index, *rev),
                Patch::Head { head, .. } => (head.index, head.rev),
            };
            prop_assert_eq!(rev, revs[index as usize] + 1);
            revs[index as usize] = rev;
        }
        for (n, row) in table.rows().iter().enumerate() {
            prop_assert_eq!(row.head.index, n as u64);
            prop_assert_eq!(row.head.rev, revs[n]);
        }
        prop_assert!(table.rows().windows(2).all(|w| w[0].head.seq < w[1].head.seq));
    }

    /// TH5: the same rows whatever page boundary a reader starts from and whatever page size it
    /// reads with, older pages and newer ones.
    #[test]
    fn th5_same_rows_from_any_page_boundary(log in log(), from in 0u64..130, size in 1usize..4096) {
        let table = RowTable::fold(&log);
        let mut newer = Vec::new();
        let mut after = from;
        loop {
            let page = table.page(RowsCursor::After(after), size);
            prop_assert!(page.cut.is_empty() || page.rows.len() == 1);
            let cut: Vec<u64> = page.cut.iter().map(|c| c.index).collect();
            for row in &page.rows {
                let whole = &table.rows()[row.head.index as usize];
                if !cut.contains(&row.head.index) {
                    prop_assert_eq!(row, whole);
                }
                prop_assert!(whole.text.starts_with(&row.text));
            }
            newer.extend(page.rows.iter().map(|r| r.head.index));
            match page.rows.last() {
                Some(last) if page.has_more => after = last.head.seq,
                _ => break,
            }
        }
        let mut older = Vec::new();
        let mut before = from + 1;
        loop {
            let page = table.page(RowsCursor::Before(before), size);
            older.splice(0..0, page.rows.iter().map(|r| r.head.index));
            match page.rows.first() {
                Some(first) if page.has_more => before = first.head.seq,
                _ => break,
            }
        }
        older.extend(newer);
        prop_assert_eq!(older, (0..table.rows().len() as u64).collect::<Vec<_>>());
    }
}

/// A hub with one closed chat named `id` and nothing in its log, on the memory store.
fn hub_with(id: &str) -> std::sync::Arc<crate::hub::Hub> {
    let mut config = crate::config::Config::default();
    config.store.mode = crate::config::StoreMode::Memory;
    let store = crate::store::open(&config.store, std::path::Path::new("/unused")).unwrap();
    let meta = serde_json::from_value(json!({
        "schema": crate::store::META_SCHEMA, "id": id, "name": id,
        "harness": "fake", "cwd": "/tmp", "status": "closed", "createdAt": 1, "updatedAt": 1
    }))
    .unwrap();
    crate::store::Store::save(&*store, &meta).unwrap();
    crate::hub::Hub::new(config, store)
}

#[test]
fn rows_reads_the_log_pages_it_and_patches_a_follower_with_each_live_record() {
    let hub = hub_with("chat");
    let session = hub.resolve("chat").unwrap();
    hub.append(
        &session,
        "mux",
        "user_message",
        json!({"promptId": "p", "turnId": "t", "text": "hi"}),
    );
    let first = chunk(0, "Hel", Some("m"), None);
    hub.append(&session, "in", "agent_message_chunk", first.msg.clone());
    let (page, following) = super::read(&hub, "chat", &json!({"follow": true})).unwrap();
    assert_eq!(page["count"], 2, "{page}");
    assert_eq!(page["rows"][1]["id"], "reply:t.1");
    assert_eq!(page["rows"][1]["text"], "Hel");
    let following = following.unwrap();
    let rec =
        hub.append(&session, "in", "agent_message_chunk", chunk(0, "lo", Some("m"), None).msg);
    let (notice, patch) = super::live(&hub, "chat", &rec, &following).unwrap();
    assert_eq!(notice, crate::rpc::method::MUX_ROWS_PATCH);
    assert_eq!(patch["patches"].as_array().unwrap().len(), 1, "{patch}");
    assert_eq!(patch["patches"][0]["op"], "append");
    assert_eq!(patch["patches"][0]["text"], "lo");
    assert_eq!(patch["version"].as_u64(), page["version"].as_u64().map(|v| v + 1));
    // Heard again (another connection's delivery): nothing new for this one.
    assert!(super::live(&hub, "chat", &rec, &following).is_none());
    let rows = super::held_rows(&hub, "chat").unwrap();
    assert_eq!(rows[1].text, "Hello");
    // An older page from the newest row's seq, and bad cursors.
    let older = super::read(&hub, "chat", &json!({"beforeSeq": rows[1].head.seq})).unwrap().0;
    assert_eq!(older["rows"].as_array().unwrap().len(), 1);
    assert!(super::read(&hub, "chat", &json!({"afterSeq": 1, "beforeSeq": 2})).is_err());
    assert!(super::read(&hub, "chat", &json!({"afterSeq": -1})).is_err());
}

#[test]
fn a_follower_too_far_behind_is_told_it_lagged() {
    let mut log =
        vec![mux(1, "user_message", json!({"promptId": "p", "turnId": "t", "text": "go"}))];
    let big = "y".repeat(64 * 1024);
    log.extend((2..80).map(|seq| chunk(seq, &big, Some("m"), None)));
    let folded = super::serve::folded_with(&log);
    assert!(super::serve::kept_patches(&folded) < log.len(), "older patches are let go");
    assert!(super::serve::since(&folded, 0).is_none(), "version 0 is past what is kept");
    assert_eq!(super::serve::since(&folded, folded_version(&folded)).map(|p| p.len()), Some(0));
}

fn folded_version(folded: &super::serve::Folded) -> u64 {
    super::serve::version(folded)
}
