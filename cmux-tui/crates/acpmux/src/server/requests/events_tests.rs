//! `_acpmux/events` after a hard stop: the log holds records the saved session does not count.

use super::*;
use crate::store::{EventRecord, MemoryStore, SessionMeta, Store};

/// A chat whose `session.json` was last saved at seq 2 while its log went on to seq 5, as a hard
/// stop leaves it, in a daemon that started without reading chat logs yet (`new_deferred`).
fn hard_stopped() -> Arc<Hub> {
    let store = MemoryStore::default();
    let meta: SessionMeta = serde_json::from_value(json!({
        "schema": crate::store::META_SCHEMA, "id": "c", "name": "chat", "harness": "fake",
        "cwd": "/tmp", "status": "idle", "createdAt": 1, "updatedAt": 1,
        "lastSeq": 2, "eventCount": 2,
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
