//! Many chats streaming into the store at once (coord-sim drive, 2026-11-19: 20 coordinators at
//! Leo's own rate put an agent's update 11 s behind at p95 in the store). An append of one chat
//! must not wait on another chat's: the store's throughput grows with the chats that write, and a
//! reader of one chat's page is not held behind every other chat's appends.
//!
//! Each writer thread appends agent-sized records (about 3 KB, the drive's mean) to its own chat
//! through the daemon's store (`store/journal_store.rs` over real files); one reader pages its
//! own chat (`Store::events`, which ends on the appends' read fence) the whole time.

use crate::config::{StoreConfig, StoreMode};
use crate::store::{EventRecord, META_SCHEMA, SessionMeta, Store};
use serde_json::json;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{Duration, Instant};

/// Records each writer appends per run.
const PER_WRITER: u64 = 1_500;
/// The payload of one record: the drive's mean agent update is 2.8 KB on the wire.
const TEXT_BYTES: usize = 2_800;

fn local(home: &std::path::Path) -> Arc<dyn Store> {
    let config = StoreConfig { mode: StoreMode::Local, ..StoreConfig::default() };
    Arc::from(crate::store::open(&config, home).unwrap_or_else(|e| panic!("open the store: {e:#}")))
}

fn chat(store: &dyn Store, id: &str) {
    let meta: SessionMeta = serde_json::from_value(json!({
        "schema": META_SCHEMA, "id": id, "name": id, "harness": "claude", "family": "claude",
        "cwd": "/w", "status": "running", "createdAt": 1, "updatedAt": 1,
    }))
    .unwrap();
    store.save(&meta).unwrap_or_else(|e| panic!("save {id}: {e:#}"));
}

fn record(seq: u64, text: &str) -> EventRecord {
    EventRecord {
        seq,
        at: 1_000 + seq,
        dir: "in".into(),
        kind: "agent_thought_chunk".into(),
        msg: json!({"jsonrpc": "2.0", "method": "session/update", "params": {
            "sessionId": "agent-1",
            "update": {"sessionUpdate": "agent_thought_chunk",
                       "content": {"type": "text", "text": text}}}}),
        host_seq: Some(seq),
    }
}

struct Run {
    /// Appends a second, all writers together.
    per_s: f64,
    /// The reader's page latency, 95th percentile, ms.
    read_p95_ms: f64,
}

fn p95(mut v: Vec<f64>) -> f64 {
    if v.is_empty() {
        return 0.0;
    }
    v.sort_by(|a, b| a.total_cmp(b));
    v[(v.len() - 1) * 95 / 100]
}

/// `writers` chats appending at once while one reader pages a chat of its own.
fn run(writers: usize) -> Run {
    let home = tempfile::tempdir().unwrap();
    let store = local(home.path());
    let text: String = "lorem ipsum dolor sit amet ".repeat(TEXT_BYTES / 27 + 1);
    let text: Arc<str> = Arc::from(&text[..TEXT_BYTES]);
    chat(store.as_ref(), "reader");
    for seq in 1..=400 {
        store.append("reader", &record(seq, &text)).unwrap();
    }
    for w in 0..writers {
        chat(store.as_ref(), &format!("w-{w:02}"));
    }
    let stop = Arc::new(AtomicBool::new(false));
    let reader = {
        let (store, stop) = (store.clone(), stop.clone());
        std::thread::spawn(move || {
            let mut lat = Vec::new();
            while !stop.load(Ordering::Relaxed) {
                let t = Instant::now();
                let page = store.events("reader", 0, 400).unwrap();
                lat.push(t.elapsed().as_secs_f64() * 1e3);
                assert_eq!(page.len(), 400);
                std::thread::sleep(Duration::from_millis(2));
            }
            lat
        })
    };
    let started = Instant::now();
    let threads: Vec<_> = (0..writers)
        .map(|w| {
            let (store, text) = (store.clone(), text.clone());
            std::thread::spawn(move || {
                let id = format!("w-{w:02}");
                for seq in 1..=PER_WRITER {
                    store.append(&id, &record(seq, &text)).unwrap();
                }
            })
        })
        .collect();
    for t in threads {
        t.join().unwrap();
    }
    let took = started.elapsed().as_secs_f64();
    stop.store(true, Ordering::Relaxed);
    let lat = reader.join().unwrap();
    for w in 0..writers {
        let id = format!("w-{w:02}");
        assert_eq!(store.events(&id, PER_WRITER - 1, 10).unwrap().len(), 1, "{id}'s last record");
    }
    Run { per_s: (writers as u64 * PER_WRITER) as f64 / took, read_p95_ms: p95(lat) }
}

/// The best of three runs: a loaded runner's stalls do not decide it.
fn best(writers: usize) -> Run {
    let runs: Vec<Run> = (0..3).map(|_| run(writers)).collect();
    let per_s = runs.iter().map(|r| r.per_s).fold(0.0, f64::max);
    let read_p95_ms = runs.iter().map(|r| r.read_p95_ms).fold(f64::INFINITY, f64::min);
    Run { per_s, read_p95_ms }
}

#[test]
fn appends_of_many_chats_go_on_side_by_side() {
    let cores = std::thread::available_parallelism().map(|n| n.get()).unwrap_or(1);
    // One writer per core, up to the 20 coordinators the drive ran; below 4 there is nothing to
    // tell apart.
    let n = cores.saturating_sub(1).min(20);
    if n < 4 {
        eprintln!("STRESS ingest: {cores} cores, skipped");
        return;
    }
    let one = best(1);
    let many = best(n);
    let scale = many.per_s / one.per_s.max(1.0);
    eprintln!(
        "STRESS ingest: 1 chat {:.0}/s read p95 {:.2} ms; {n} chats {:.0}/s read p95 {:.2} ms; \
         scale {scale:.2}x",
        one.per_s, one.read_p95_ms, many.per_s, many.read_p95_ms
    );
    // Chats that share nothing but the store: each one's appends go on beside the others'. A
    // store that writes every chat's line under one lock stays near 1x however many chats write.
    let floor = n as f64 * 0.35;
    assert!(
        scale >= floor,
        "{n} chats appending at once reached {scale:.2}x one chat's throughput (floor \
         {floor:.1}x): the chats' appends wait on one another"
    );
    // A page of one chat while the others stream: never held behind their appends.
    assert!(
        many.read_p95_ms <= one.read_p95_ms * 3.0 + 5.0,
        "a page read's p95 went from {:.2} ms with one chat writing to {:.2} ms with {n}",
        one.read_p95_ms,
        many.read_p95_ms
    );
}
