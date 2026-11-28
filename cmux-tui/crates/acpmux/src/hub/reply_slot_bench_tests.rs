//! Bench: a chat's last reply at 10k and 100k records, read as `acpmux last` read it (newest
//! transcript pages back from the end, folded by the client's `Transcript`) and from the slot.
//!
//! The shape is the slow one measured on a fleet host (2026-11-27): the last reply sits behind a
//! long run of tool output, so the tail the old read walks grows with the chat. The slot's warm
//! read stays flat; `ACPMUX_BENCH=1` prints the numbers.

use std::time::{Duration, Instant};

use serde_json::{Value, json};

use super::super::*;
use crate::store::SessionMeta;

fn meta(id: &str) -> SessionMeta {
    serde_json::from_value(json!({
        "schema": crate::store::META_SCHEMA, "id": id, "name": "bench", "harness": "codex",
        "cwd": "/tmp", "status": "idle", "createdAt": 1, "updatedAt": 2,
    }))
    .unwrap()
}

/// A hub on the daemon's own on-disk store (`store.mode` local) in a fresh directory, holding
/// chat `id`: the memory store keeps only a chat's newest 20k records, and drops every append to
/// a chat it holds no meta for, so a bench on it reads an empty log.
fn hub_with(id: &str) -> (Arc<Hub>, Arc<Session>, std::path::PathBuf) {
    let root =
        std::env::temp_dir().join(format!("acpmux-reply-slot-bench-{}", uuid::Uuid::now_v7()));
    let mut cfg = crate::config::Config::default();
    cfg.store.mode = crate::config::StoreMode::Local;
    let store = crate::store::open(&cfg.store, &root).unwrap();
    store.save(&meta(id)).unwrap();
    let hub = Hub::new(cfg, store);
    let s = hub.resolve(id).unwrap();
    (hub, s, root)
}

fn update(kind: &str, body: Value) -> Value {
    let mut update = json!({"sessionUpdate": kind});
    update.as_object_mut().unwrap().extend(body.as_object().unwrap().clone());
    json!({"jsonrpc": "2.0", "method": "session/update", "params": {"sessionId": "n", "update": update}})
}

/// A chat of about `n` records: turns of a reply and a tool call, then a last reply, then a
/// tool run of half the chat (the shape that cost 2.7 s a page on the fleet).
fn chat(hub: &Hub, s: &Arc<Session>, n: usize) {
    let output = "x".repeat(400);
    let mut seq = 0usize;
    while seq < n / 2 {
        hub.append(s, "mux", "turn_started", json!({}));
        for i in 0..4 {
            hub.append(
                s,
                "in",
                "agent_message_chunk",
                update(
                    "agent_message_chunk",
                    json!({"content": {"type": "text", "text": format!("word {i} ")}}),
                ),
            );
        }
        hub.append(
            s,
            "in",
            "tool_call",
            update("tool_call", json!({"toolCallId": format!("t{seq}"), "title": "run"})),
        );
        hub.append(s, "in", "tool_call_update", update("tool_call_update", json!({"toolCallId": format!("t{seq}"), "status": "completed", "content": [{"type": "content", "content": {"type": "text", "text": output}}]})));
        seq += 7;
    }
    hub.append(s, "mux", "turn_started", json!({}));
    hub.append(
        s,
        "in",
        "agent_message_chunk",
        update(
            "agent_message_chunk",
            json!({"content": {"type": "text", "text": "the last reply"}}),
        ),
    );
    hub.append(
        s,
        "in",
        "tool_call",
        update("tool_call", json!({"toolCallId": "tail", "title": "run"})),
    );
    while seq < n {
        hub.append(s, "in", "tool_call_update", update("tool_call_update", json!({"toolCallId": "tail", "status": "in_progress", "content": [{"type": "content", "content": {"type": "text", "text": output}}]})));
        seq += 1;
    }
}

/// `acpmux last -n 1` before the slot (`cli/last_reply.rs` `last_replies`), on the hub.
fn scan_last(hub: &Hub, id: &str) -> Vec<String> {
    let filter = crate::hub::EventFilter::parse(Some(&json!(["transcript"])))
        .unwrap()
        .omitting_superseded(true);
    let (mut events, mut before, mut ask): (Vec<Value>, u64, usize) = (Vec::new(), u64::MAX, 256);
    loop {
        let limit = ask.min(5000 - events.len());
        let page =
            hub.events_page(id, 0, Some(before), limit, Some(4 << 20), true, &filter).unwrap();
        let Some(first) = page.events.first().map(|e| e.seq) else { break };
        before = first;
        let older: Vec<Value> =
            page.events.iter().map(|e| serde_json::to_value(e).unwrap()).collect();
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
    median(
        (0..reps)
            .map(|_| {
                let t = Instant::now();
                std::hint::black_box(f());
                t.elapsed()
            })
            .collect(),
    )
}

struct Row {
    scan: Duration,
    scan_right: bool,
    seed: Duration,
    warm: Duration,
    append: Duration,
}

fn row(n: usize) -> Row {
    let (hub, s, root) = hub_with("bench");
    chat(&hub, &s, n);
    // The old read stops at 5000 records: past a tool run that long it answers without the
    // reply (wrong, not only slow), so its answer is reported, not asserted.
    let scan_right = scan_last(&hub, "bench") == vec!["the last reply".to_owned()];
    let scan = time(5, || scan_last(&hub, "bench"));
    let t = Instant::now();
    assert_eq!(hub.last_replies(&s, 1).unwrap().0, vec!["the last reply".to_owned()]);
    let seed = t.elapsed();
    let warm = time(200, || hub.last_replies(&s, 1).unwrap());
    // A seeded slot on the append path: an append and a read, both O(1).
    let tick = update("tool_call_update", json!({"toolCallId": "tail", "status": "in_progress"}));
    let append = time(200, || {
        hub.append(&s, "in", "tool_call_update", tick.clone());
        hub.last_replies(&s, 1).unwrap()
    });
    drop((s, hub));
    let _ = std::fs::remove_dir_all(&root);
    Row { scan, scan_right, seed, warm, append }
}

#[test]
fn last_reply_read_is_flat_at_10x() {
    let (small, big) = (row(10_000), row(100_000));
    if std::env::var_os("ACPMUX_BENCH").is_some() {
        for (n, r) in [(10_000, &small), (100_000, &big)] {
            eprintln!(
                "reply_slot n={n}: scan(before) {:?} right={}  seed(first read) {:?}  slot(warm) {:?}  append+read {:?}",
                r.scan, r.scan_right, r.seed, r.warm, r.append
            );
        }
    }
    // Flat: the warm read does not grow with the chat (generous bound, CI noise).
    let floor = Duration::from_micros(50);
    assert!(
        big.warm <= small.warm.max(floor) * 4,
        "slot read grew with the chat: {:?} at 10k, {:?} at 100k",
        small.warm,
        big.warm
    );
    assert!(big.warm < big.scan, "slot read {:?} not under the scan {:?}", big.warm, big.scan);
}

/// The hub's read of a small chat, cold then warm: the bench's read at a size a test run takes.
#[test]
fn hub_reads_the_last_reply_of_a_small_chat() {
    let (hub, s, root) = hub_with("small");
    chat(&hub, &s, 40);
    let (replies, through) = hub.last_replies(&s, 1).unwrap();
    assert_eq!(replies, vec!["the last reply".to_owned()]);
    assert_eq!(through, super::last_seq(&s));
    // Warm: the append path's fold carries the next reply.
    hub.append(&s, "mux", "turn_started", json!({}));
    let next = json!({"content": {"type": "text", "text": "next"}});
    hub.append(&s, "in", "agent_message_chunk", update("agent_message_chunk", next));
    let both = vec!["the last reply".to_owned(), "next".to_owned()];
    assert_eq!(hub.last_replies(&s, 2).unwrap().0, both);
    drop((s, hub));
    let _ = std::fs::remove_dir_all(&root);
}
