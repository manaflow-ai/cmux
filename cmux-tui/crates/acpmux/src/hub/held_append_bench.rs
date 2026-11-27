//! What appending a held tool output snapshot costs (`store/deferred.rs`): p50 and p95 of one
//! `Hub::append` of a snapshot a newer one may replace, at 4 KiB, 64 KiB and 1 MiB of output, in
//! a small chat and in the god chat (`god_fixture`), on a store on disk as the daemon opens it.
//! It appends through the hub only, so the same file runs on a build that keeps held bodies in
//! memory alone: copy it there with its `mod` lines in `hub/mod.rs` for the before numbers.
//! Manual: `cargo test -p acpmux --release --lib held_append_cost -- --ignored --nocapture
//! --test-threads=1` (`ACPMUX_GOD_SCALE=0.1` for a quick run). One JSON line per shape.

use super::*;
use std::time::{Duration, Instant};

/// Output bytes per snapshot, and how many calls each shape runs (two held snapshots each).
const SHAPES: [(usize, usize); 3] = [(4 << 10, 200), (64 << 10, 200), (1 << 20, 40)];

fn update(update: Value) -> Value {
    json!({"jsonrpc": "2.0", "method": "session/update", "params": {"sessionId": "a", "update": update}})
}

/// A hub on a store on disk in `home` holding the chat of `shape`'s god size, and the chat.
fn chat_of(home: &Path, shape: &crate::god_fixture::Shape) -> (Arc<Hub>, Arc<Session>, u64) {
    let mut cfg = Config::default();
    cfg.store.mode = crate::config::StoreMode::Local;
    let store = crate::store::open(&cfg.store, home).unwrap();
    let id = crate::god_fixture::chat_id(0);
    let (_, last_seq) =
        crate::god_fixture::append_log(store.as_ref(), &id, shape.god_messages, shape.god_bytes)
            .unwrap();
    let agent = crate::god_fixture::agent_session_id(0);
    let meta = crate::god_fixture::session_meta(&id, shape.name, "/tmp", &agent, last_seq, 1);
    let meta: SessionMeta = serde_json::from_value(meta).unwrap();
    store.save(&meta).unwrap();
    store.flush().unwrap();
    let hub = Hub::new(cfg, store);
    let session = hub.insert_test_session(meta);
    (hub, session, last_seq)
}

fn percentile(sorted: &[Duration], p: usize) -> f64 {
    let at = (sorted.len() * p / 100).min(sorted.len().saturating_sub(1));
    sorted.get(at).map_or(0.0, |d| d.as_secs_f64() * 1e6)
}

#[test]
#[ignore = "manual per-append cost measurement"]
fn held_append_cost() {
    let runtime = tokio::runtime::Builder::new_current_thread().enable_all().build().unwrap();
    let _enter = runtime.enter();
    for shape in [crate::god_fixture::Shape::small(), crate::god_fixture::Shape::god_from_env()] {
        let home = tempfile::tempdir().unwrap();
        let (hub, session, log_seq) = chat_of(home.path(), &shape);
        for (bytes, calls) in SHAPES {
            let from = session.seq.load(Ordering::SeqCst);
            let mut took = Vec::with_capacity(calls * 2);
            for call in 0..calls {
                let id = format!("bench_{bytes}_{call}");
                hub.append(&session, "in", "tool_call", update(json!({"sessionUpdate": "tool_call", "toolCallId": id, "title": "cargo test", "kind": "execute", "status": "in_progress"})));
                // Two snapshots of the running command, the second a little longer: under twice
                // the bytes and within `MAX_AGE_MS`, so both are held.
                for step in 0..2 {
                    let text = "o".repeat(bytes - 16 + step * 8);
                    let msg = update(json!({"sessionUpdate": "tool_call_update", "toolCallId": id,
                        "_meta": {"terminal_output_delta": {"data": "o\n"}},
                        "content": [{"type": "content", "content": {"type": "text", "text": text}}]}));
                    let started = Instant::now();
                    hub.append(&session, "in", "tool_call_update", msg);
                    took.push(started.elapsed());
                }
                // Its end with no content stores the held one (not timed).
                hub.append(&session, "in", "tool_call_update", update(json!({"sessionUpdate": "tool_call_update", "toolCallId": id, "status": "completed"})));
            }
            let held = hub
                .store
                .events(&session.id, from, usize::MAX)
                .unwrap()
                .iter()
                .filter(|r| {
                    r.msg.pointer("/params/update/_meta/acpmux/supersededContent").is_some()
                })
                .count();
            took.sort();
            println!(
                "{}",
                json!({
                    "bench": "held_append",
                    "shape": shape.name,
                    "logSeq": log_seq,
                    "outputBytes": bytes,
                    "appends": took.len(),
                    "held": held,
                    "p50Us": (percentile(&took, 50) * 10.0).round() / 10.0,
                    "p95Us": (percentile(&took, 95) * 10.0).round() / 10.0,
                })
            );
        }
    }
}
