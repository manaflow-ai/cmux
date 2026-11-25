#![allow(clippy::indexing_slicing, clippy::unwrap_used)]

use super::*;
use std::sync::Arc;

/// xorshift64*, so every run replays the same samples.
struct Random(u64);

impl Random {
    fn next(&mut self) -> u64 {
        self.0 ^= self.0 >> 12;
        self.0 ^= self.0 << 25;
        self.0 ^= self.0 >> 27;
        self.0.wrapping_mul(0x2545_F491_4F6C_DD1D)
    }
}

fn field(v: &Value, path: &[&str]) -> Value {
    let mut at = v;
    for key in path {
        at = at.get(*key).unwrap_or(&Value::Null);
    }
    at.clone()
}

#[test]
fn bucket_math_is_monotone_and_bounds_hold() {
    let mut last = 0;
    for micros in
        (0..70_000u64).chain([1 << 20, (1 << 20) + 1, 1 << 35, (1 << 36) - 1, 1 << 36, u64::MAX])
    {
        let index = bucket_of(micros);
        assert!(index < BUCKETS, "{micros}");
        assert!(index >= last || micros > 70_000, "monotone at {micros}");
        last = index;
        let upper = bucket_upper(index);
        assert!(micros <= upper, "{micros} above its bucket's upper {upper}");
        if index > 0 {
            assert!(bucket_upper(index - 1) < micros, "{micros} fits the bucket below");
        }
        if micros >= 4 && index < BUCKETS - 1 {
            // At most 25 % above.
            assert!(upper - micros <= micros / 4 + 1, "{micros} -> {upper}");
        }
    }
    assert_eq!(bucket_of(u64::MAX), BUCKETS - 1);
    assert_eq!(bucket_upper(BUCKETS - 1), u64::MAX);
}

#[test]
fn percentiles_match_a_sorted_vector_within_a_bucket() {
    let felt = Felt::new();
    let mut random = Random(0x9E37_79B9);
    let mut samples = Vec::new();
    for i in 0..20_000u64 {
        // Log-spread from 1 µs to about 1 s.
        let micros = 1u64 << (random.next() % 20);
        let micros = micros + random.next() % micros;
        samples.push(micros);
        felt.record_at(Metric::TerminalEcho, micros, i);
    }
    samples.sort_unstable();
    let snapshot = felt.snapshot_at(20_000);
    let stats = field(&snapshot, &["metrics", "terminal_echo", "since_start"]);
    assert_eq!(stats["count"], 20_000);
    assert_eq!(stats["max_us"], *samples.last().unwrap());
    for (name, percent) in [("p50_us", 50usize), ("p90_us", 90), ("p99_us", 99)] {
        let rank = (percent * samples.len()).div_ceil(100).max(1);
        let truth = samples[rank - 1];
        let got = stats[name].as_u64().unwrap();
        assert!(got >= truth, "{name}: {got} below the true {truth}");
        assert!(got <= truth + truth / 4 + 1, "{name}: {got} too far above {truth}");
    }
}

#[test]
fn no_samples_read_as_null() {
    let snapshot = Felt::new().snapshot_at(0);
    let stats = field(&snapshot, &["metrics", "prompt_send_to_ack", "last_60s"]);
    assert_eq!(stats["count"], 0);
    assert!(stats["p50_us"].is_null() && stats["max_us"].is_null());
    assert_eq!(snapshot["metrics"].as_object().unwrap().len(), METRICS.len());
}

#[test]
fn the_window_rolls_over_and_since_start_keeps_everything() {
    let felt = Felt::new();
    // One slow sample at t = 0, then one every 10 s of the minute after.
    felt.record_at(Metric::FrameIntervalChat, 90_000, 0);
    for step in 1..=5u64 {
        felt.record_at(Metric::FrameIntervalChat, 1_000, step * SLOT_MS);
    }
    let at = |ms: u64, which: &str| {
        field(&felt.snapshot_at(ms), &["metrics", "frame_interval_chat", which])
    };
    // Still inside the minute: six samples, the slow one the max.
    assert_eq!(at(55_000, "last_60s")["count"], 6);
    assert_eq!(at(55_000, "last_60s")["max_us"], 90_000);
    // 60 s on, the first slot has aged out.
    assert_eq!(at(60_000, "last_60s")["count"], 5);
    assert_eq!(at(60_000, "last_60s")["max_us"], 1_000);
    // Recording into the recycled slot clears what it held.
    felt.record_at(Metric::FrameIntervalChat, 2_000, 60_000);
    let now = at(60_000, "last_60s");
    assert_eq!(now["count"], 6);
    assert_eq!(now["max_us"], 2_000);
    // Long silence: the window is empty, the total is not.
    assert_eq!(at(1_000_000, "last_60s")["count"], 0);
    assert_eq!(at(1_000_000, "since_start")["count"], 7);
    assert_eq!(at(1_000_000, "since_start")["max_us"], 90_000);
}

#[test]
fn a_late_sample_for_a_recycled_slot_stays_out_of_the_window() {
    let felt = Felt::new();
    felt.record_at(Metric::TerminalEcho, 5, 70_000);
    felt.record_at(Metric::TerminalEcho, 5, 0);
    let snapshot = felt.snapshot_at(70_000);
    assert_eq!(field(&snapshot, &["metrics", "terminal_echo", "last_60s"])["count"], 1);
    assert_eq!(field(&snapshot, &["metrics", "terminal_echo", "since_start"])["count"], 2);
}

#[test]
fn eight_threads_record_without_loss() {
    let felt = Arc::new(Felt::new());
    let per_thread = 50_000u64;
    let threads: Vec<_> = (0..8u64)
        .map(|t| {
            let felt = Arc::clone(&felt);
            std::thread::spawn(move || {
                for i in 0..per_thread {
                    // All inside one 10 s slot, so the window loses nothing either.
                    felt.record_at(Metric::PromptSendToAck, 1 + (i + t) % 5_000, 1_000);
                }
            })
        })
        .collect();
    for thread in threads {
        thread.join().unwrap();
    }
    let snapshot = felt.snapshot_at(2_000);
    for which in ["since_start", "last_60s"] {
        let stats = field(&snapshot, &["metrics", "prompt_send_to_ack", which]);
        assert_eq!(stats["count"], 8 * per_thread, "{which}");
        assert_eq!(stats["max_us"], 5_000);
    }
}

#[test]
fn the_global_records_and_snapshots() {
    record(Metric::FrameIntervalBrowser, Duration::from_micros(16_700));
    let snapshot = snapshot();
    let stats = field(&snapshot, &["metrics", "frame_interval_browser", "since_start"]);
    assert!(stats["count"].as_u64().unwrap() >= 1);
    // Names and numbers only: no string value anywhere but the metric names.
    assert!(!snapshot.to_string().contains("text"));
}
