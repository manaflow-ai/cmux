//! Queued text chunks merged on a peer link (`chunk_merge.rs`): only the same record's, never
//! across reply segments or past a line between them, the newest `seq` kept, every text once
//! and in order.

use super::{Chunk, MERGE_CAP, enabled_from};
use crate::rpc::{Message, method};
use crate::server::outbound::{OUTBOUND_BYTE_BOUND, start_bounded};
use serde_json::{Value, json};
use std::time::Duration;
use tokio::sync::mpsc;

fn chunk(session: &str, segment: &str, seq: u64, text: &str) -> String {
    Message::notification(
        method::SESSION_UPDATE,
        json!({"sessionId": session,
            "update": {"sessionUpdate": "agent_message_chunk",
                "content": {"type": "text", "text": text},
                "_meta": {"acpmux": {"segment": segment}}},
            "_meta": {"acpmux": {"seq": seq, "at": 1000 + seq, "kind": "agent"}}}),
    )
    .to_line()
}

fn event_chunk(session: &str, seq: u64, text: &str) -> String {
    Message::notification(
        method::MUX_EVENT,
        json!({"sessionId": session, "seq": seq, "at": 1000 + seq, "dir": "in",
            "msg": {"jsonrpc": "2.0", "method": "session/update", "params": {"sessionId": session,
                "update": {"sessionUpdate": "agent_message_chunk",
                    "content": {"type": "text", "text": text}}}}}),
    )
    .to_line()
}

fn parse(line: &str) -> Value {
    serde_json::from_str(line).unwrap()
}

#[test]
fn the_setting_is_off_unless_it_is_one() {
    assert!(!enabled_from(&|_| None));
    assert!(!enabled_from(&|_| Some("0".into())));
    assert!(enabled_from(&|_| Some(" 1 ".into())));
}

#[test]
fn the_same_record_merges_with_the_newer_seq_and_both_texts() {
    let mut a = Chunk::of(&chunk("s", "r1", 7, "hel")).unwrap();
    let b = Chunk::of(&chunk("s", "r1", 9, "lo")).unwrap();
    let line = parse(&a.merged(&b).expect("merged"));
    assert_eq!(line["params"]["update"]["content"]["text"], "hello");
    assert_eq!(line["params"]["_meta"]["acpmux"]["seq"], 9);
    assert_eq!(line["params"]["_meta"]["acpmux"]["at"], 1009);
    // And the next one onto that.
    let c = Chunk::of(&chunk("s", "r1", 10, "!")).unwrap();
    let line = parse(&a.merged(&c).expect("merged again"));
    assert_eq!(line["params"]["update"]["content"]["text"], "hello!");
    assert_eq!(line["params"]["_meta"]["acpmux"]["seq"], 10);
}

#[test]
fn event_stream_chunks_merge_too() {
    let mut a = Chunk::of(&event_chunk("s", 3, "a")).unwrap();
    let line = parse(&a.merged(&Chunk::of(&event_chunk("s", 4, "b")).unwrap()).unwrap());
    assert_eq!(line["method"], method::MUX_EVENT);
    assert_eq!(line["params"]["seq"], 4);
    assert_eq!(line["params"]["msg"]["params"]["update"]["content"]["text"], "ab");
}

#[test]
fn other_segments_chats_and_records_never_merge() {
    let mut a = Chunk::of(&chunk("s", "r1", 1, "x")).unwrap();
    assert!(a.merged(&Chunk::of(&chunk("s", "r2", 2, "y")).unwrap()).is_none(), "another reply");
    assert!(a.merged(&Chunk::of(&chunk("t", "r1", 2, "y")).unwrap()).is_none(), "another chat");
    let thought = Message::notification(
        method::SESSION_UPDATE,
        json!({"sessionId": "s", "update": {"sessionUpdate": "agent_thought_chunk",
            "content": {"type": "text", "text": "z"}}}),
    )
    .to_line();
    assert!(Chunk::of(&thought).is_none());
    let reply = Message::ok(json!(1), json!({"update": {}})).to_line();
    assert!(Chunk::of(&reply).is_none());
    let with_ref = Message::notification(method::MUX_EVENT, json!({"chunkRef": 1})).to_line();
    assert!(Chunk::of(&with_ref).is_none());
}

#[test]
fn a_merge_stops_at_the_cap() {
    let half = "x".repeat(MERGE_CAP / 2 + 1);
    let mut a = Chunk::of(&chunk("s", "r1", 1, &half)).unwrap();
    assert!(a.merged(&Chunk::of(&chunk("s", "r1", 2, &half)).unwrap()).is_none());
}

/// The queue merges only what is still queued, and a line between two chunks keeps them apart:
/// every text reaches the reader once, in order, in fewer lines.
#[tokio::test]
async fn a_backlog_of_chunks_reaches_the_reader_merged_in_order() {
    let scope = cmux_scope::Scope::new("chunk-merge-test");
    let (transport, mut rx) = mpsc::channel(4096);
    let (out, _) = start_bounded(&scope, None, transport, OUTBOUND_BYTE_BOUND);
    out.set_merge_chunks(true);
    // One line in the transport at a time: the rest wait in the queue, as behind a lossy link.
    out.set_window(1);
    let mut want = String::new();
    for n in 0..200u64 {
        let text = format!("t{n} ");
        want.push_str(&text);
        assert!(out.push(chunk("s", "r1", n + 1, &text)));
        if n == 100 {
            assert!(out.push(Message::notification("_acpmux/other", json!({})).to_line()));
        }
    }
    let mut got = String::new();
    let mut lines = 0;
    let mut last_seq = 0;
    let mut other = false;
    while last_seq < 200 {
        let line = tokio::time::timeout(Duration::from_secs(10), rx.recv())
            .await
            .expect("a line")
            .expect("open");
        let v = parse(&line);
        lines += 1;
        if v["method"] == "_acpmux/other" {
            assert!(got.ends_with("t100 "), "the line between kept its place: {got:?}");
            other = true;
            continue;
        }
        let seq = v["params"]["_meta"]["acpmux"]["seq"].as_u64().unwrap();
        assert!(seq > last_seq, "seq {seq} after {last_seq}");
        last_seq = seq;
        got.push_str(v["params"]["update"]["content"]["text"].as_str().unwrap());
    }
    assert!(other);
    assert_eq!(got, want, "every text once, in order");
    assert!(lines < 20, "merged: {lines} lines for 201");
}

/// Off (every connection but a peer link that asked), each chunk goes as its own line.
#[tokio::test]
async fn off_each_chunk_is_its_own_line() {
    let scope = cmux_scope::Scope::new("chunk-merge-test");
    let (transport, mut rx) = mpsc::channel(4096);
    let (out, _) = start_bounded(&scope, None, transport, OUTBOUND_BYTE_BOUND);
    out.set_window(1);
    for n in 0..20u64 {
        assert!(out.push(chunk("s", "r1", n + 1, "x")));
    }
    for n in 0..20u64 {
        let line = tokio::time::timeout(Duration::from_secs(10), rx.recv()).await.unwrap().unwrap();
        assert_eq!(parse(&line)["params"]["_meta"]["acpmux"]["seq"], n + 1);
    }
}
