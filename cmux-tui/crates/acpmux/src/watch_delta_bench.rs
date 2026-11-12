//! A reconnecting peer's delta of a god list against a small one (rework stage 3, the heap
//! attribution of 2026-11-12): the most bytes one `delta` holds at once (the test allocator's
//! count on its thread), and its time. God: 10,848 rows of 75 keys, about 42 MB of text, as the dogfood Mac's peer lists
//! were. Small: 100 rows. The link knows every row, as after a short drop.
//!
//! Only this crate's API from before the fix is used, so the same file measures both sides:
//! `cargo test -p acpmux --release --lib watch_delta_bench -- --ignored --nocapture --test-threads=1`.

use super::{delta, digest};
use crate::hub::peer_snapshot::thread_peak_bytes;
use serde_json::{Map, Value, json};
use std::time::Instant;

fn fixture(rows: usize) -> (String, Map<String, Value>) {
    let rows: Vec<Value> = (0..rows)
        .map(|i| {
            let mut row = serde_json::Map::new();
            row.insert("sessionId".into(), json!(format!("box-chat-{i}")));
            for k in 0..74 {
                row.insert(
                    format!("field{k:02}"),
                    json!(format!("value {i} {k} {}", "v".repeat(40))),
                );
            }
            Value::Object(row)
        })
        .collect();
    let known = rows
        .iter()
        .map(|row| (row["sessionId"].as_str().unwrap().to_owned(), json!(digest(row))))
        .collect();
    (json!({"sessions": rows}).to_string(), known)
}

fn measure(name: &str, rows: usize) -> (usize, f64) {
    let (list, known) = fixture(rows);
    let mut peaks = Vec::new();
    let mut times = Vec::new();
    for _ in 0..20 {
        let started = Instant::now();
        let (reply, peak) = thread_peak_bytes(|| delta(&list, &known).expect("a delta"));
        times.push(started.elapsed().as_secs_f64() * 1e3);
        peaks.push(peak >> 10);
        assert!(reply.contains("\"unchanged\""));
    }
    peaks.sort_unstable();
    times.sort_by(f64::total_cmp);
    let p95 = |v: &[f64]| v[(v.len() * 95 / 100).min(v.len() - 1)];
    let peak = peaks[peaks.len() * 95 / 100];
    eprintln!(
        "WATCH-DELTA {name}: rows {rows}, list {} KiB, peak held p95 {peak} KiB, time p95 {:.2} ms",
        list.len() >> 10,
        p95(&times)
    );
    (peak, p95(&times))
}

#[test]
#[ignore = "bench: run with --ignored --nocapture --test-threads=1"]
fn watch_delta_bench_god_and_small() {
    let (small_peak, small_ms) = measure("small", 100);
    let (god_peak, god_ms) = measure("god", 10_848);
    eprintln!(
        "WATCH-DELTA god/small: peak {god_peak} / {small_peak} KiB, time {god_ms:.2} / {small_ms:.2} ms"
    );
}
