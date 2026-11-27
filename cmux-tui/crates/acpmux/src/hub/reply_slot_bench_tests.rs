//! Bench: a chat's last reply at 10k and 100k records, read as `acpmux last` read it (newest
//! transcript pages back from the end, folded by the client's `Transcript`) and from the slot.
//!
//! The shape is the slow one measured on a fleet host (2026-11-27): the last reply sits behind a
//! long run of tool output, so the tail the old read walks grows with the chat. The slot's warm
//! read stays flat; `ACPMUX_BENCH=1` prints the numbers.

use std::time::{Duration, Instant};

use serde_json::{Value, json};

use super::super::*;
use crate::store::{MemoryStore, SessionMeta};

fn meta(id: &str) -> SessionMeta {
    serde_json::from_value(json!({
        "schema": crate::store::META_SCHEMA, "id": id, "name": "bench", "harness": "codex",
        "cwd": "/tmp", "status": "idle", "createdAt": 1, "updatedAt": 2,
    }))
    .unwrap()
}

fn update(kind: &str, body: Value) -> Value {
    let mut update = json!({"sessionUpdate": kind});
    update.as_object_mut().unwrap().extend(body.as_object().unwrap().clone());
    json!({"jsonrpc": "2.0", "method": "session/update", "params": {"sessionId": "n", "update": update}})
}

/// A chat of about `n` records: turns of a reply and a tool call, then a last reply, then a
/// tool run of half the chat (the shape that cost 2.7 s a page on the fleet).
fn chat(hub: &Hub, id: &str, n: usize) -> Arc<Session> {
    let s = hub.insert_test_session(meta(id));
    let output = "x".repeat(400);
    let mut seq = 0usize;
    while seq < n / 2 {
        hub.append(&s, "mux", "turn_started", json!({}));
        for i in 0..4 {
            hub.append(&s, "in", "agent_message_chunk", update("agent_message_chunk", json!({"content": {"type": "text", "text": format!("word {i} ")}})));
        }
        hub.append(&s, "in", "tool_call", update("tool_call", json!({"toolCallId": format!("t{seq}"), "title": "run"})));
        hub.append(&s, "in", "tool_call_update", update("tool_call_update", json!({"toolCallId": format!("t{seq}"), "status": "completed", "content": [{"type": "content", "content": {"type": "text", "text": output}}]})));
        seq += 7;
    }
    hub.append(&s, "mux", "turn_started", json!({}));
    hub.append(&s, "in", "agent_message_chunk", update("agent_message_chunk", json!({"content": {"type": "text", "text": "the last reply"}})));
    hub.append(&s, "in", "tool_call", update("tool_call", json!({"toolCallId": "tail", "title": "run"})));
    while seq < n {
        hub.append(&s, "in", "tool_call_update", update("tool_call_update", json!({"toolCallId": "tail", "status": "in_progress", "content": [{"type": "content", "content": {"type": "text", "text": output}}]})));
        seq += 1;
    }
    s
}

/// `acpmux last -n 1` before the slot (`cli/last_reply.rs` `last_replies`), on the hub.
fn scan_last(hub: &Hub, id: &str) -> Vec<String> {
    let filter = crate::hub::EventFilter::parse(Some(&json!(["transcript"]))).unwrap().omitting_superseded(true);
    let (mut events, mut before, mut ask): (Vec<Value>, u64, usize) = (Vec::new(), u64::MAX, 256);
    loop {
        let limit = ask.min(5000 - events.len());
        let page = hub.events_page(id, 0, Some(before), limit, Some(4 << 20), true, &filter).unwrap();
        let Some(first) = page.events.first().map(|e| e.seq) else { break };
        before = first;
        let older: Vec<Value> = page.events.iter().map(|e| serde_json::to_value(e).unwrap()).collect();
        events.splice(0..0, older);
        if !page.has_more || events.len() >= 5000 || crate::cli::last_reply::replies(&events, 1).1 {
            break;
        }
        ask = ask.saturating_mul(4);
    }
    crate::cli::last_reply::replies(&events, 1).0
}

fn median(mut runs: Vec<Duration>) -> Duration {
    runs.sort();
    runs[runs.len() / 2]
}

fn time<T>(reps: usize, mut f: impl FnMut() -> T) -> Duration {
    median((0..reps).map(|_| { let t = Instant::now(); std::hint::black_box(f()); t.elapsed() }).collect())
}

struct Row { scan: Duration, seed: Duration, warm: Duration, append: Duration }

fn row(n: usize) -> Row {
    let mut cfg: crate::config::Config = serde_json::from_value(json!({})).unwrap();
    cfg.store.mode = crate::config::StoreMode::Memory;
    let hub = Hub::new(cfg, Box::new(MemoryStore::default()));
    let s = chat(&hub, "bench", n);
    assert_eq!(scan_last(&hub, "bench"), vec!["the last reply".to_owned()]);
    let scan = time(5, || scan_last(&hub, "bench"));
    let t = Instant::now();
    assert_eq!(hub.last_replies(&s, 1).unwrap().0, vec!["the last reply".to_owned()]);
    let seed = t.elapsed();
    let warm = time(200, || hub.last_replies(&s, 1).unwrap());
    // A seeded slot on the append path: an append and a read, both O(1).
    let tick = update("tool_call_update", json!({"toolCallId": "tail", "status": "in_progress"}));
    let append = time(200, || { hub.append(&s, "in", "tool_call_update", tick.clone()); hub.last_replies(&s, 1).unwrap() });
    Row { scan, seed, warm, append }
}

#[test]
fn last_reply_read_is_flat_at_10x() {
    let (small, big) = (row(10_000), row(100_000));
    if std::env::var_os("ACPMUX_BENCH").is_some() {
        for (n, r) in [(10_000, &small), (100_000, &big)] {
            eprintln!(
                "reply_slot n={n}: scan(before) {:?}  seed(first read) {:?}  slot(warm) {:?}  append+read {:?}",
                r.scan, r.seed, r.warm, r.append
            );
        }
    }
    // Flat: the warm read does not grow with the chat (generous bound, CI noise).
    let floor = Duration::from_micros(50);
    assert!(
        big.warm <= small.warm.max(floor) * 4,
        "slot read grew with the chat: {:?} at 10k, {:?} at 100k", small.warm, big.warm
    );
    assert!(big.warm < big.scan, "slot read {:?} not under the scan {:?}", big.warm, big.scan);
}
