//! `_acpmux/events` after a hard stop: the log holds records the saved session does not count.

use super::*;
use crate::store::{EventRecord, MemoryStore, SessionMeta, Store};

/// A chat whose `session.json` was last saved at seq 2 while its log went on to seq 5, as a hard
/// stop leaves it, in a daemon that started without reading chat logs yet (`new_deferred`).
fn hard_stopped() -> Arc<Hub> {
    hard_stopped_with_seen(None)
}

fn hard_stopped_with_seen(seen_seq: Option<u64>) -> Arc<Hub> {
    hard_stopped_with_cursors(seen_seq, seen_seq, None)
}

fn hard_stopped_with_cursors(
    seen_seq: Option<u64>,
    owner_read_through: Option<u64>,
    alice_read_through: Option<u64>,
) -> Arc<Hub> {
    let store = MemoryStore::default();
    let mut read_through = serde_json::Map::new();
    if let Some(seq) = owner_read_through {
        read_through.insert("owner".into(), json!(seq));
    }
    if let Some(seq) = alice_read_through {
        read_through.insert("user_alice".into(), json!(seq));
    }
    let meta: SessionMeta = serde_json::from_value(json!({
        "schema": crate::store::META_SCHEMA, "id": "c", "name": "chat", "harness": "fake",
        "cwd": "/tmp", "status": "idle", "createdAt": 1, "updatedAt": 1,
        "lastSeq": 2, "eventCount": 2, "seenSeq": seen_seq, "readThrough": read_through,
    }))
    .unwrap();
    store.save(&meta).unwrap();
    for seq in 1..=5 {
        let record = EventRecord {
            seq,
            at: seq,
            dir: "in".into(),
            kind: "agent_message_chunk".into(),
            msg: json!({"text": format!("part {seq}")}),
            host_seq: None,
        };
        store.append("c", &record).unwrap();
    }
    let mut config = crate::config::Config::default();
    config.store.mode = crate::config::StoreMode::Memory;
    Hub::new_deferred(config, Box::new(store), crate::mailbox::Mailbox::memory())
}

fn seqs(page: &Value) -> Vec<u64> {
    page["events"].as_array().unwrap().iter().map(|e| e["seq"].as_u64().unwrap()).collect()
}

/// A client that saw seq 3 before the stop (a lag's resync, a reconnect reading its own cursor)
/// reads what came after it, not `cursor_future`, before the chat's log is loaded.
#[test]
fn a_read_past_the_saved_last_seq_gets_the_logs_tail_before_the_log_loads() {
    let hub = hard_stopped();
    let page = handle(&hub, method::MUX_EVENTS, &json!({"sessionId": "c", "afterSeq": 3}), None)
        .expect("the log holds seq 4 and 5: the read is not past the last event");
    assert_eq!(seqs(&page), [4, 5]);
    assert_eq!(page["lastSeq"], 5);
    assert_eq!(page["pageThrough"], 5);

    // A read from inside the saved run says the log's end too, so a cursor moves past it.
    let hub = hard_stopped();
    let page =
        handle(&hub, method::MUX_EVENTS, &json!({"sessionId": "c", "afterSeq": 1}), None).unwrap();
    assert_eq!(seqs(&page), [2, 3, 4, 5]);
    assert_eq!(page["lastSeq"], 5);

    // One truly past the log is still refused.
    let hub = hard_stopped();
    let past = handle(&hub, method::MUX_EVENTS, &json!({"sessionId": "c", "afterSeq": 9}), None)
        .unwrap_err();
    assert!(past.message.contains("cursor_future"), "{}", past.message);
}

#[test]
fn since_seen_reads_after_the_saved_cutover_without_moving_it() {
    let hub = hard_stopped_with_seen(Some(2));
    let page =
        handle(&hub, method::MUX_EVENTS, &json!({"sessionId": "c", "sinceSeen": true}), None)
            .expect("the recap starts after the saved seen cursor");
    assert_eq!(seqs(&page), [3, 4, 5]);
    assert_eq!(page["seenSeq"], 2);
    assert_eq!(page["lastSeq"], 5);
    assert_eq!(page["pageThrough"], 5);
    assert_eq!(hub.resolve("c").unwrap().meta().seen_seq, Some(2));

    let never_focused = hard_stopped_with_seen(None);
    let empty = handle(
        &never_focused,
        method::MUX_EVENTS,
        &json!({"sessionId": "c", "sinceSeen": true}),
        None,
    )
    .unwrap();
    assert_eq!(seqs(&empty), Vec::<u64>::new());
    assert_eq!(empty["seenSeq"], Value::Null);
    assert_eq!(empty["lastSeq"], 5);

    let invalid = handle(
        &hub,
        method::MUX_EVENTS,
        &json!({"sessionId": "c", "sinceSeen": true, "afterSeq": 1}),
        None,
    )
    .unwrap_err();
    assert!(invalid.message.contains("cannot be combined"), "{}", invalid.message);
}

#[test]
fn since_seen_uses_the_request_reader_cursor_over_legacy_seen_seq() {
    let hub = hard_stopped_with_cursors(Some(4), Some(4), Some(3));
    let owner = crate::hub::presence::Who { id: "owner".into(), name: "Owner".into() };
    hub.presence.view_with_cutover("c", "conn-owner", &owner, true, true, Some(2)).unwrap();
    let owner =
        handle(&hub, method::MUX_EVENTS, &json!({"sessionId": "c", "sinceSeen": true}), None)
            .unwrap();
    assert_eq!(seqs(&owner), [3, 4, 5]);
    assert_eq!(owner["seenSeq"], 2);

    let other = handle(
        &hub,
        method::MUX_EVENTS,
        &json!({"sessionId": "c", "sinceSeen": true,
            "_meta": {"acpmux": {"author": {"id": "user_alice", "name": "Alice"}}}}),
        None,
    )
    .unwrap();
    assert_eq!(seqs(&other), [4, 5]);
    assert_eq!(other["seenSeq"], 3);
    hub.presence.leave("c", "conn-owner");
    let away =
        handle(&hub, method::MUX_EVENTS, &json!({"sessionId": "c", "sinceSeen": true}), None)
            .unwrap();
    assert_eq!(away["seenSeq"], 4);
    assert_eq!(seqs(&away), [5]);
}

/// A reader that pages forward on its own (a durable watch on a peer chat, `hub/watch_events.rs`)
/// bounds each page, but a page always carries its first record: a 300 KB tool output was the
/// whole page every time it was asked, past the reader's deadline, and its cursor never moved.
/// With `recordMaxBytes` a record past it goes as a stub that keeps its seq, kind and short
/// fields, and every page moves on.
#[test]
fn a_page_bounded_per_record_moves_past_a_record_larger_than_the_page() {
    let store = MemoryStore::default();
    let meta: SessionMeta = serde_json::from_value(json!({
        "schema": crate::store::META_SCHEMA, "id": "c", "name": "chat", "harness": "fake",
        "cwd": "/tmp", "status": "idle", "createdAt": 1, "updatedAt": 1,
        "lastSeq": 4, "eventCount": 4,
    }))
    .unwrap();
    store.save(&meta).unwrap();
    let huge = "o".repeat(300 * 1024);
    let record = |seq: u64, dir: &str, kind: &str, msg: Value| EventRecord {
        seq,
        at: seq,
        dir: dir.into(),
        kind: kind.into(),
        msg,
        host_seq: None,
    };
    let update = |update: Value| {
        json!({"jsonrpc": "2.0", "method": "session/update",
        "params": {"sessionId": "c", "update": update}})
    };
    let log = [
        record(
            1,
            "in",
            "tool_call",
            update(json!({"sessionUpdate": "tool_call", "toolCallId": "t"})),
        ),
        record(
            2,
            "in",
            "tool_call_update",
            update(json!({"sessionUpdate": "tool_call_update",
            "toolCallId": "t", "content": [{"type": "content", "content": {"type": "text", "text": huge}}]})),
        ),
        record(
            3,
            "mux",
            "permission_request",
            json!({"permissionId": "p1", "turnId": "u1",
            "toolCall": {"content": [{"type": "text", "text": huge}]}}),
        ),
        record(4, "mux", "turn_result", json!({"turnId": "u1", "pendingPermissions": 1})),
    ];
    for rec in &log {
        store.append("c", rec).unwrap();
    }
    let mut config = crate::config::Config::default();
    config.store.mode = crate::config::StoreMode::Memory;
    let hub = Hub::new(config, Box::new(store));
    // A watch's page of a peer chat (`watch_events::remote_page`).
    let budget = 64 * 1024;
    let ask = |after: u64| {
        json!({"sessionId": "c", "afterSeq": after, "limit": 256,
        "kinds": ["tool_call", "tool_call_update", "permission_request", "turn_result"],
        "maxBytes": budget, "recordMaxBytes": budget})
    };
    let (mut after, mut pages, mut seen) = (0, 0, Vec::new());
    loop {
        let page = handle(&hub, method::MUX_EVENTS, &ask(after), None).unwrap();
        pages += 1;
        let events = page["events"].as_array().unwrap();
        assert!(!events.is_empty() && pages <= 4, "page {pages} after {after} moved nothing");
        for e in events {
            let bytes = e.to_string().len();
            assert!(bytes <= budget, "seq {} came whole: {bytes} bytes", e["seq"]);
            seen.push(e.clone());
        }
        after = page["pageThrough"].as_u64().unwrap();
        if page["hasMore"] != true {
            break;
        }
    }
    assert_eq!(seen.iter().map(|e| e["seq"].as_u64().unwrap()).collect::<Vec<_>>(), [1, 2, 3, 4]);
    // The stubs say what they left out, and keep what names them.
    let msg = |i: usize| seen[i]["msg"].clone();
    assert!(seen[1].to_string().contains("omitted"), "{}", seen[1]);
    assert_eq!(seen[1]["kind"], "tool_call_update");
    assert_eq!(msg(2)["permissionId"], "p1", "{}", seen[2]);
    assert_eq!(msg(2)["turnId"], "u1");
    assert_eq!(msg(3)["pendingPermissions"], 1, "a small record goes whole");
}

/// One page of chat `c`, holding `log`, as a durable watch on a peer asks for it.
fn watch_page(log: &[EventRecord], ask: Value) -> Value {
    let store = MemoryStore::default();
    let meta: SessionMeta = serde_json::from_value(json!({
        "schema": crate::store::META_SCHEMA, "id": "c", "name": "chat", "harness": "fake",
        "cwd": "/tmp", "status": "idle", "createdAt": 1, "updatedAt": 1,
        "lastSeq": log.len(), "eventCount": log.len(),
    }))
    .unwrap();
    store.save(&meta).unwrap();
    for rec in log {
        store.append("c", rec).unwrap();
    }
    let mut config = crate::config::Config::default();
    config.store.mode = crate::config::StoreMode::Memory;
    let hub = Hub::new(config, Box::new(store));
    let mut params = json!({"sessionId": "c", "afterSeq": 0, "limit": 256,
        "kinds": ["agent_message_chunk", "permission_request", "turn_result"],
        "maxBytes": 64 * 1024, "recordMaxBytes": 64 * 1024});
    params.as_object_mut().unwrap().extend(ask.as_object().unwrap().clone());
    handle(&hub, method::MUX_EVENTS, &params, None).unwrap()
}

/// A stub is a stub of its own size: a record of 300 short fields made an 81 KB "stub", past
/// the page it was cut for. It keeps its ids first, then fields while they fit, and says it
/// left some out.
#[test]
fn a_stub_stays_under_its_own_budget_and_keeps_its_ids() {
    let mut msg = serde_json::Map::new();
    for n in 0..300 {
        msg.insert(format!("field{n:03}"), json!("f".repeat(256)));
    }
    msg.insert("permissionId".into(), json!("p1"));
    msg.insert("toolCall".into(), json!({"content": "x".repeat(70 * 1024)}));
    let rec = EventRecord {
        seq: 1,
        at: 1,
        dir: "mux".into(),
        kind: "permission_request".into(),
        msg: Value::Object(msg),
        host_seq: None,
    };
    let page = watch_page(&[rec], json!({}));
    let stub = &page["events"][0]["msg"];
    let bytes = stub.to_string().len();
    assert!(bytes <= 8 * 1024, "the stub is {bytes} bytes");
    assert_eq!(stub["permissionId"], "p1");
    assert_eq!(stub.pointer("/_meta/acpmux/omitted/truncated"), Some(&json!(true)));
}

/// A durable watch with `--match` reads a peer's reply chunks for its text: an 80 KiB reply
/// holding "finished" came as a stub with no text, and the watch moved past it and never woke.
/// The serving side checks the whole text, past the stub's kept ends too.
#[test]
fn a_stubbed_reply_chunk_says_whether_its_whole_text_matched() {
    let text = format!("{}finished{}", "a".repeat(40 * 1024), "b".repeat(40 * 1024));
    let chunk = EventRecord {
        seq: 1,
        at: 1,
        dir: "in".into(),
        kind: "agent_message_chunk".into(),
        msg: json!({"jsonrpc": "2.0", "method": "session/update", "params": {"sessionId": "c",
            "update": {"sessionUpdate": "agent_message_chunk",
                "content": {"type": "text", "text": text}}}}),
        host_seq: None,
    };
    let done = EventRecord {
        seq: 2,
        at: 2,
        dir: "mux".into(),
        kind: "turn_result".into(),
        msg: json!({"turnId": "u1"}),
        host_seq: None,
    };
    let log = [chunk, done];
    let page = watch_page(&log, json!({"match": "finished"}));
    let omitted = &page["events"][0]["msg"]["_meta"]["acpmux"]["omitted"];
    assert_eq!(omitted["matched"], true, "{omitted}");
    assert!(omitted["textHead"].as_str().unwrap().starts_with("aaa"));
    assert!(omitted["textTail"].as_str().unwrap().ends_with("bbb"));
    assert!(page["events"][0]["msg"].to_string().len() <= 8 * 1024);
    assert_eq!(page["events"][1]["msg"]["turnId"], "u1");
    let page = watch_page(&log, json!({"match": "never said"}));
    assert_eq!(page["events"][0]["msg"]["_meta"]["acpmux"]["omitted"]["matched"], false);
}

/// Codex review of #40885, F1: `_acpmux/events` took a `match` of any length, and every stub keeps
/// that much of its text's ends, so one multi-megabyte pattern defeated the page bounds. A match
/// past `MAX_MATCH_BYTES` is refused, as `watch_add` refuses it.
#[test]
fn a_match_past_the_cap_is_refused() {
    let hub = hard_stopped();
    let pattern = "m".repeat(4 << 20);
    let err = handle(&hub, method::MUX_EVENTS, &json!({"sessionId": "c", "match": pattern}), None)
        .expect_err("a 4 MiB match was taken");
    assert!(err.message.contains("match is at most"), "{}", err.message);
    // The longest one taken still reads.
    let longest = "m".repeat(crate::hub::MAX_MATCH_BYTES);
    handle(&hub, method::MUX_EVENTS, &json!({"sessionId": "c", "match": longest}), None).unwrap();
}

/// The phone's older page of a chat with a 2 MB command log in it (cmux-next-ios
/// `chat_older_page`): a page always carries its first record whole, so the page was the 256 KiB
/// asked plus the whole log, on the wire and in the parse. With `toolOutputMaxBytes` the log goes
/// cut to its head, marked with the record's size and seq, and a read of that one seq (the
/// person opening the output) gets it whole. A reader that does not ask gets it whole as before.
#[test]
fn a_page_cuts_an_oversized_tool_output_and_the_record_reads_whole_on_its_own() {
    let store = MemoryStore::default();
    let meta: SessionMeta = serde_json::from_value(json!({
        "schema": crate::store::META_SCHEMA, "id": "c", "name": "chat", "harness": "fake",
        "cwd": "/tmp", "status": "idle", "createdAt": 1, "updatedAt": 1,
        "lastSeq": 3, "eventCount": 3,
    }))
    .unwrap();
    store.save(&meta).unwrap();
    let log: String = (0..60_000).map(|i| format!("step {i} ok\n")).collect();
    assert!(log.len() > 600 * 1024);
    let update = |update: Value| {
        json!({"jsonrpc": "2.0", "method": "session/update",
        "params": {"sessionId": "c", "update": update}})
    };
    let records = [
        (1, "mux", "user_message", json!({"turnId": "u1", "text": "build it"})),
        (
            2,
            "in",
            "tool_call",
            update(
                json!({"sessionUpdate": "tool_call", "toolCallId": "t", "title": "swift build"}),
            ),
        ),
        (
            3,
            "in",
            "tool_call_update",
            update(json!({"sessionUpdate": "tool_call_update", "toolCallId": "t",
            "status": "completed",
            "content": [{"type": "content", "content": {"type": "text", "text": log}}]})),
        ),
    ];
    for (seq, dir, kind, msg) in records {
        let rec =
            EventRecord { seq, at: seq, dir: dir.into(), kind: kind.into(), msg, host_seq: None };
        store.append("c", &rec).unwrap();
    }
    let mut config = crate::config::Config::default();
    config.store.mode = crate::config::StoreMode::Memory;
    let hub = Hub::new(config, Box::new(store));
    let older = |cut: Option<u64>| {
        let mut ask = json!({"sessionId": "c", "beforeSeq": 4, "limit": 400,
            "maxBytes": 256 * 1024, "kinds": ["transcript"]});
        if let Some(cut) = cut {
            ask["toolOutputMaxBytes"] = json!(cut);
        }
        handle(&hub, method::MUX_EVENTS, &ask, None).unwrap()
    };

    let whole = older(None);
    assert!(whole.to_string().len() > log.len(), "a reader that does not ask reads the log whole");

    let page = older(Some(64 * 1024));
    assert_eq!(seqs(&page), [1, 2, 3]);
    let wire = page.to_string().len();
    assert!(wire < 96 * 1024, "the page is {wire} bytes");
    let cut = &page["events"][2]["msg"]["params"]["update"];
    assert_eq!(cut["_meta"]["acpmux"]["cut"]["seq"], 3);
    assert!(cut["_meta"]["acpmux"]["cut"]["bytes"].as_u64().unwrap() > log.len() as u64);
    let head = cut["content"][0]["content"]["text"].as_str().unwrap();
    assert!(log.starts_with(head) && !head.is_empty());

    // The person opens the output: that one record, whole.
    let full = handle(
        &hub,
        method::MUX_EVENTS,
        &json!({"sessionId": "c", "afterSeq": 2, "limit": 1}),
        None,
    )
    .unwrap();
    assert_eq!(seqs(&full), [3]);
    let update = &full["events"][0]["msg"]["params"]["update"];
    assert_eq!(update["content"][0]["content"]["text"].as_str(), Some(log.as_str()));
    assert!(update.pointer("/_meta/acpmux/cut").is_none());
}

/// Bytes this thread has read (Linux `rchar`): other tests' reads are not counted.
fn read_bytes() -> u64 {
    std::fs::read_to_string("/proc/thread-self/io")
        .ok()
        .and_then(|io| {
            io.lines().find(|l| l.starts_with("rchar:"))?.split_whitespace().nth(1)?.parse().ok()
        })
        .unwrap_or(0)
}

/// A chat on disk whose newest records are `filler` raw harness lines, a page's transcript kinds
/// sparse among them: 200 reply chunks, then that many lines the transcript page skips.
fn sparse_tail_chat(filler: u64) -> (std::path::PathBuf, Arc<Hub>) {
    let root = std::env::temp_dir().join(format!("acpmux-page-replies-{}", uuid::Uuid::now_v7()));
    let sessions = root.join("sessions");
    let writer = crate::store::LocalStore::new(sessions.clone(), 8 << 20).unwrap();
    let mut seq = 0;
    let line = "x".repeat(1000);
    for n in 0..200 + filler {
        seq += 1;
        let (kind, msg) = if n < 200 {
            let update = json!({"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": "word "}});
            (
                "agent_message_chunk",
                json!({"method": "session/update", "params": {"sessionId": "a", "update": update}}),
            )
        } else {
            ("claude.stream_event", json!({"line": line}))
        };
        let record =
            EventRecord { seq, at: seq, dir: "in".into(), kind: kind.into(), msg, host_seq: None };
        writer.append("c", &record).unwrap();
    }
    let meta: SessionMeta = serde_json::from_value(json!({
        "schema": crate::store::META_SCHEMA, "id": "c", "name": "chat", "harness": "fake",
        "cwd": "/tmp", "status": "idle", "createdAt": 1, "updatedAt": 2,
        "lastSeq": seq, "eventCount": seq,
    }))
    .unwrap();
    writer.save(&meta).unwrap();
    writer.flush().unwrap();
    drop(writer);
    let mut config = crate::config::Config::default();
    config.store.mode = crate::config::StoreMode::Memory;
    let store = crate::store::LocalStore::new(sessions, 8 << 20).unwrap();
    (root, Hub::new_deferred(config, Box::new(store), crate::mailbox::Mailbox::memory()))
}

/// The app's ask for a chat's newest transcript page, as it sends it.
fn newest_transcript_page() -> Value {
    json!({
        "_meta": {"acpmux": {"personVerified": true, "via": "app"}},
        "sessionId": "c", "beforeSeq": 9007199254740991u64, "limit": 400, "maxBytes": 131072,
        "kinds": ["transcript", "available_commands_update", "usage_update", "config_option_update", "bookmarks"],
    })
}

/// The app asks for a chat's newest page again and again while nothing is appended
/// (cmuxterm-hq#13733: 45 asks read 159 MB in 30 s). The same ask of an unchanged log is answered
/// as it was, with no read; an append makes the next ask read the log and see the new record.
#[test]
fn an_unchanged_chats_newest_page_asked_again_reads_nothing() {
    if !cfg!(target_os = "linux") {
        return; // A thread's reads are counted on Linux only.
    }
    let (root, hub) = sparse_tail_chat(8_000);
    let ask = newest_transcript_page();
    let first_read = read_bytes();
    let first = handle(&hub, method::MUX_EVENTS, &ask, None).unwrap();
    let first_read = read_bytes() - first_read;
    assert_eq!(first["events"].as_array().unwrap().len(), 200);
    assert!(first_read > 4 << 20, "the first ask reads back past the filler: {first_read}");

    let again_read = read_bytes();
    let again = handle(&hub, method::MUX_EVENTS, &ask, None).unwrap();
    let again_read = read_bytes() - again_read;
    assert_eq!(again, first);
    assert!(again_read < 64 << 10, "the same ask read {again_read} bytes of an unchanged log");

    // A lane's own read marks its reports read: it reads the log every time.
    let lane_read = read_bytes();
    handle(&hub, method::MUX_EVENTS, &ask, Some("lane")).unwrap();
    assert!(read_bytes() - lane_read > 4 << 20);

    let s = hub.resolve("c").unwrap();
    let update =
        json!({"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": "new"}});
    let appended = hub.append(
        &s,
        "in",
        "agent_message_chunk",
        json!({"method": "session/update", "params": {"sessionId": "a", "update": update}}),
    );
    let after = handle(&hub, method::MUX_EVENTS, &ask, None).unwrap();
    assert_eq!(after["lastSeq"], appended.seq);
    assert_eq!(seqs(&after).last(), Some(&appended.seq), "the page holds the appended record");
    let _ = std::fs::remove_dir_all(&root);
}

/// A chat on disk of `turns` reply chunks of about 2 KB each, as `sparse_tail_chat` makes one.
fn chat_of(turns: u64) -> (std::path::PathBuf, Arc<Hub>) {
    let root = std::env::temp_dir().join(format!("acpmux-page-history-{}", uuid::Uuid::now_v7()));
    let sessions = root.join("sessions");
    let writer = crate::store::LocalStore::new(sessions.clone(), 8 << 20).unwrap();
    let text = "word ".repeat(400);
    for seq in 1..=turns {
        let update = json!({"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": text}});
        let record = EventRecord {
            seq,
            at: seq,
            dir: "in".into(),
            kind: "agent_message_chunk".into(),
            msg: json!({"method": "session/update", "params": {"sessionId": "a", "update": update}}),
            host_seq: None,
        };
        writer.append("c", &record).unwrap();
    }
    let meta: SessionMeta = serde_json::from_value(json!({
        "schema": crate::store::META_SCHEMA, "id": "c", "name": "chat", "harness": "fake",
        "cwd": "/tmp", "status": "idle", "createdAt": 1, "updatedAt": 2,
        "lastSeq": turns, "eventCount": turns,
    }))
    .unwrap();
    writer.save(&meta).unwrap();
    writer.flush().unwrap();
    drop(writer);
    let mut config = crate::config::Config::default();
    config.store.mode = crate::config::StoreMode::Memory;
    let store = crate::store::LocalStore::new(sessions, 8 << 20).unwrap();
    (root, Hub::new_deferred(config, Box::new(store), crate::mailbox::Mailbox::memory()))
}

/// hq#14027: the bytes of a chat's newest page at 1x and 10x history, asked as a Cloud chat's
/// page reached acpmux before `agent-session-page-bytes-v1` (no `maxBytes`: the 1 MiB default)
/// and with the pane's own 128 KiB budget, which a local chat's page always carried. Prints one
/// `cloud-page-bytes` line per cell; the budgeted page stays the same size as history grows.
#[test]
fn a_chats_newest_page_with_the_panes_budget_stays_constant_with_history() {
    let page = |hub: &Arc<Hub>, budget: Option<u64>| {
        let mut ask = newest_transcript_page();
        match budget {
            Some(bytes) => ask["maxBytes"] = json!(bytes),
            None => {
                ask.as_object_mut().unwrap().remove("maxBytes");
            }
        }
        serde_json::to_vec(&handle(hub, method::MUX_EVENTS, &ask, None).unwrap()).unwrap().len()
    };
    let mut budgeted = Vec::new();
    for (history, turns) in [("1x", 100), ("10x", 1000)] {
        let (root, hub) = chat_of(turns);
        let before = page(&hub, None);
        let after = page(&hub, Some(131_072));
        println!(
            "cloud-page-bytes history={history} records={turns} before={before} after={after}"
        );
        let _ = std::fs::remove_dir_all(&root);
        assert!(after <= 131_072 + 4096, "{history}: {after}");
        budgeted.push((before, after));
    }
    let (before_10x, after_10x) = budgeted[1];
    assert!(before_10x > after_10x, "10x history: {before_10x} vs {after_10x}");
    assert!(after_10x <= budgeted[0].1.max(131_072) + 4096, "the budgeted page grew: {budgeted:?}");
}
