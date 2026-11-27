use super::*;
use crate::store::{EventRecord, MemoryStore, Store};
use serde_json::json;

fn rec(seq: u64, dir: &str, kind: &str, msg: Value) -> EventRecord {
    EventRecord { seq, at: seq * 1000, dir: dir.into(), kind: kind.into(), msg, host_seq: None }
}

fn chunk(seq: u64, message: &str, text: &str) -> EventRecord {
    rec(
        seq,
        "in",
        "agent_message_chunk",
        json!({"params": {"update": {
        "sessionUpdate": "agent_message_chunk", "messageId": message,
        "content": {"type": "text", "text": text}}}}),
    )
}

fn prompt(seq: u64, text: &str) -> EventRecord {
    rec(seq, "mux", "user_message", json!({"text": text}))
}

fn tool(seq: u64, title: &str) -> EventRecord {
    rec(
        seq,
        "in",
        "tool_call",
        json!({"params": {"update": {"sessionUpdate": "tool_call", "title": title}}}),
    )
}

/// A memory store holds a chat's records only once its meta is saved.
fn memory() -> MemoryStore {
    let store = MemoryStore::default();
    let meta = serde_json::from_value(json!({
        "schema": crate::store::META_SCHEMA, "id": "c", "name": "c", "harness": "claude",
        "family": "claude", "cwd": "/tmp", "status": "idle", "createdAt": 1, "updatedAt": 1,
    }))
    .unwrap();
    store.save(&meta).unwrap();
    store
}

fn store(log: &[EventRecord]) -> MemoryStore {
    let store = memory();
    for r in log {
        store.append("c", r).unwrap();
    }
    store
}

fn hits(store: &MemoryStore, params: Value) -> Vec<Value> {
    let query = Query::from_params(&params).unwrap();
    search(store, "c", &query).unwrap()["hits"].as_array().cloned().unwrap()
}

fn seqs(hits: &[Value]) -> Vec<u64> {
    hits.iter().filter_map(|h| h.get("seq").and_then(Value::as_u64)).collect()
}

/// The agent's chunks join into one message per `messageId`, so words split across records are
/// found together; a subagent's text, a replayed record and a tool's output are not messages.
#[test]
fn chunks_join_by_message_and_only_the_sessions_own_text_counts() {
    let mut subagent = chunk(5, "m9", "secret subagent words");
    if let Some(params) = subagent.msg.get_mut("params") {
        params["_meta"] = json!({"acpmux": {"subagent": "c/toolu_1"}});
    }
    let mut replay = chunk(6, "m8", "replayed words");
    replay.kind = "agent_message_chunk.replay".into();
    let log = [
        prompt(1, "which PRs?"),
        chunk(2, "m1", "cmux-platform#469 "),
        chunk(3, "m1", "and cmux-platform#470."),
        tool(4, "Run cargo test"),
        subagent,
        replay,
        chunk(7, "m2", "second reply"),
        chunk(8, "m3", "third reply"),
    ];
    let mut projector = Projector::default();
    log.iter().for_each(|r| projector.feed(r));
    let got: Vec<(u64, Role, &str)> =
        projector.entries.iter().map(|e| (e.seq, e.role, e.text.as_str())).collect();
    assert_eq!(
        got,
        vec![
            (1, Role::User, "which PRs?"),
            (2, Role::Assistant, "cmux-platform#469 and cmux-platform#470."),
            (4, Role::Tool, "Run cargo test"),
            (7, Role::Assistant, "second reply"),
            (8, Role::Assistant, "third reply"),
        ]
    );
    let store = store(&log);
    let found = hits(&store, json!({"query": "#469 AND #470"}));
    assert_eq!(seqs(&found), vec![2]);
    assert_eq!(found[0]["role"], "assistant");
    assert_eq!(found[0]["snippet"], "cmux-platform#469 and cmux-platform#470.");
    assert!(hits(&store, json!({"query": "subagent"})).is_empty());
    assert!(hits(&store, json!({"query": "replayed"})).is_empty());
}

/// Newest first, at most `limit`; `role` and `sinceMs` narrow the messages searched.
#[test]
fn newest_first_with_role_since_and_limit() {
    let log = [
        prompt(1, "deploy the relay"),
        chunk(2, "m1", "I will deploy the relay now"),
        tool(3, "deploy relay"),
        prompt(4, "relay deploy again"),
        chunk(5, "m2", "relay: deploy done"),
    ];
    let store = store(&log);
    assert_eq!(seqs(&hits(&store, json!({"query": "deploy relay"}))), vec![5, 4, 3, 2, 1]);
    assert_eq!(seqs(&hits(&store, json!({"query": "deploy relay", "limit": 2}))), vec![5, 4]);
    assert_eq!(
        seqs(&hits(&store, json!({"query": "deploy relay", "role": "assistant"}))),
        vec![5, 2]
    );
    assert_eq!(seqs(&hits(&store, json!({"query": "deploy relay", "role": "tool"}))), vec![3]);
    assert_eq!(seqs(&hits(&store, json!({"query": "deploy", "sinceMs": 4000}))), vec![5, 4]);
    let all = search(&store, "c", &Query::from_params(&json!({"query": "zzz"})).unwrap()).unwrap();
    assert_eq!(all["entries"], 5);
    assert_eq!(all["sessionId"], "c");
}

#[test]
fn a_bad_query_is_refused() {
    for params in [
        json!({}),
        json!({"query": "   "}),
        json!({"query": "x", "role": "system"}),
        json!({"query": "x", "limit": 0}),
        json!({"query": "x", "sinceMs": "yesterday"}),
    ] {
        assert!(Query::from_params(&params).is_err(), "{params}");
    }
    let q = Query::from_params(&json!({"query": "x", "limit": 5000})).unwrap();
    assert_eq!(q.limit, MAX_LIMIT);
}

/// One message keeps at most [`MAX_TEXT`] bytes, cut at a character boundary.
#[test]
fn a_huge_message_is_capped_at_a_character_boundary() {
    let big = "é".repeat(MAX_TEXT);
    let mut projector = Projector::default();
    projector.feed(&chunk(1, "m1", &big));
    projector.feed(&chunk(2, "m1", "tail"));
    let text = &projector.entries[0].text;
    assert!(text.len() <= MAX_TEXT && text.len() > MAX_TEXT - 4);
    assert!(text.chars().all(|c| c == 'é'));
}
