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

/// `writers` chats appending at once while one reader pages a chat of its own. `shared`: all of
/// them in one store (what the daemon does); else each chat in a store of its own, the control
/// that shares no lock and sees the same machine (cores, disk, the suite's other tests).
fn run(writers: usize, shared: bool) -> Run {
    let homes: Vec<_> = (0..=writers).map(|_| tempfile::tempdir().unwrap()).collect();
    let stores: Vec<Arc<dyn Store>> = if shared {
        let one = local(homes[0].path());
        (0..=writers).map(|_| one.clone()).collect()
    } else {
        homes.iter().map(|h| local(h.path())).collect()
    };
    let text: String = "lorem ipsum dolor sit amet ".repeat(TEXT_BYTES / 27 + 1);
    let text: Arc<str> = Arc::from(&text[..TEXT_BYTES]);
    // The reader's store is the last; writer `w`'s is `stores[w]`.
    let reader_store = stores[writers].clone();
    chat(reader_store.as_ref(), "reader");
    for seq in 1..=400 {
        reader_store.append("reader", &record(seq, &text)).unwrap();
    }
    for (w, store) in stores.iter().take(writers).enumerate() {
        chat(store.as_ref(), &format!("w-{w:02}"));
    }
    let stop = Arc::new(AtomicBool::new(false));
    let reader = {
        let (store, stop) = (reader_store.clone(), stop.clone());
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
            let (store, text) = (stores[w].clone(), text.clone());
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
    for (w, store) in stores.iter().take(writers).enumerate() {
        let id = format!("w-{w:02}");
        let last = store.events(&id, PER_WRITER - 1, 10).unwrap();
        assert_eq!(last.len(), 1, "{id}'s last record");
    }
    Run { per_s: (writers as u64 * PER_WRITER) as f64 / took, read_p95_ms: p95(lat) }
}

/// The best of three runs each of one store and of the control, taken in turn so a loaded
/// runner's stalls fall on both alike: (shared, control).
fn best(writers: usize) -> (Run, Run) {
    let mut runs = (Vec::new(), Vec::new());
    for _ in 0..3 {
        runs.0.push(run(writers, true));
        runs.1.push(run(writers, false));
    }
    let pick = |rs: &[Run]| Run {
        per_s: rs.iter().map(|r| r.per_s).fold(0.0, f64::max),
        read_p95_ms: rs.iter().map(|r| r.read_p95_ms).fold(f64::INFINITY, f64::min),
    };
    (pick(&runs.0), pick(&runs.1))
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
    let (one, _) = best(1);
    let (many, apart) = best(n);
    let scale = many.per_s / one.per_s.max(1.0);
    let of_apart = many.per_s / apart.per_s.max(1.0);
    eprintln!(
        "STRESS ingest: 1 chat {:.0}/s read p95 {:.2} ms; {n} chats {:.0}/s read p95 {:.2} ms; \
         scale {scale:.2}x; {n} chats in stores of their own {:.0}/s, one store reaches \
         {of_apart:.2} of it",
        one.per_s, one.read_p95_ms, many.per_s, many.read_p95_ms, apart.per_s
    );
    // Chats that share nothing but the store: their appends go on beside one another about as
    // fast as the same chats in stores of their own on the same machine at the same time (a
    // floor against the control, not the core count, so the suite's other tests on the runner
    // do not decide it). A store that writes every chat's line under one lock stays near one
    // chat's rate, far under the control: about one/apart, 0.2 on the run that set this floor.
    // 0.4 keeps twice that margin; a loaded runner took the shared store to 0.54 (2026-11-22,
    // scale 2.6x over one chat), which no one-lock store reaches.
    assert!(
        of_apart >= 0.4,
        "{n} chats appending to one store reached {:.0}/s, {of_apart:.2} of the {:.0}/s they \
         reach in stores of their own (floor 0.4): the chats' appends wait on one another",
        many.per_s,
        apart.per_s
    );
    // A page of one chat while the others stream: never held behind their appends.
    assert!(
        many.read_p95_ms <= one.read_p95_ms * 3.0 + 5.0,
        "a page read's p95 went from {:.2} ms with one chat writing to {:.2} ms with {n}",
        one.read_p95_ms,
        many.read_p95_ms
    );
}
