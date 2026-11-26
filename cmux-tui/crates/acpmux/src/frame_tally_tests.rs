use serde_json::json;

use super::*;

fn counts_of(frames: &[(usize, u64)]) -> Vec<u64> {
    let mut counts = vec![0u64; BUCKETS + 1];
    for (index, count) in frames {
        if let Some(bucket) = counts.get_mut(*index) {
            *bucket += count;
        }
    }
    counts
}

#[test]
fn percentiles_are_nearest_rank_bucket_middles() {
    // 95 frames at 8.3 ms (bucket 83), 4 at 16.6 ms (166), 1 at 40 ms (400).
    let counts = counts_of(&[(83, 95), (166, 4), (400, 1)]);
    assert_eq!(percentile(&counts, 0.50), Some(8.35));
    assert_eq!(percentile(&counts, 0.95), Some(8.35));
    assert_eq!(percentile(&counts, 0.96), Some(16.65));
    assert_eq!(percentile(&counts, 0.99), Some(16.65));
    assert_eq!(percentile(&counts, 1.0), Some(40.05));
    assert_eq!(percentile(&vec![0u64; BUCKETS + 1], 0.95), None);
}

#[test]
fn a_steady_60_hz_chat_is_under_the_budget() {
    // A 16.67 ms frame falls in [16.6, 16.7): said as 16.65, under the goal's 16.7.
    let index = (16.67 / BUCKET_MS) as usize;
    let summary = summary(&counts_of(&[(index, 1000)]));
    assert_eq!(summary["p95_ms"], json!(16.65));
    assert_eq!(summary["over_budget"], json!(0));
    let slow = super::summary(&counts_of(&[(167, 10)]));
    assert_eq!(slow["over_budget"], json!(10));
}

#[test]
fn the_overflow_bucket_reads_as_the_limit_and_is_counted() {
    let summary = summary(&counts_of(&[(10, 1), (BUCKETS, 3)]));
    assert_eq!(summary["frames"], json!(4));
    assert_eq!(summary["p95_ms"], json!(LIMIT_MS));
    assert_eq!(summary["max_ms"], json!(LIMIT_MS));
    assert_eq!(summary["over_limit"], json!(3));
}

#[test]
fn the_window_keeps_the_last_five_minutes_only() {
    let mut tally = Tally::new();
    let start = 1_000_000_000u64;
    tally.add(start, 50, 7);
    tally.add(start + 60_000, 60, 3);
    assert_eq!(tally.window(start + 60_000).iter().sum::<u64>(), 10);
    // The first slot ages out once WINDOW_MS has passed; the second is still in.
    let later = start + WINDOW_MS + SLOT_MS;
    let window = tally.window(later);
    assert_eq!(window.get(50), Some(&0));
    assert_eq!(window.get(60), Some(&3));
    // A slot reused a ring turn later starts from zero.
    tally.add(start + WINDOW_MS, 70, 1);
    assert_eq!(tally.window(start + WINDOW_MS).get(50), Some(&0));
    assert_eq!(tally.window(start + WINDOW_MS).get(70), Some(&1));
}

#[test]
fn a_read_changes_nothing() {
    let mut tally = Tally::new();
    let now = 2_000_000_000u64;
    tally.add(now, 83, 40);
    tally.add(now, 250, 2);
    let first = tally.read(now + 1_000);
    let second = tally.read(now + 1_000);
    assert_eq!(first, second);
    assert_eq!(first["visible_chat"]["frames"], json!(42));
    assert_eq!(first["visible_chat"]["window_s"], json!(1));
    assert_eq!(first["visible_chat"]["since"], json!(now));
    let empty = Tally::new().read(now);
    assert_eq!(empty["visible_chat"]["frames"], json!(0));
    assert_eq!(empty["visible_chat"]["p95_ms"], json!(null));
    assert_eq!(empty["visible_chat"]["since"], json!(null));
}

#[test]
fn a_page_report_is_added_and_a_foreign_bucket_width_refused() {
    let mut tally = Tally::new();
    let now = 3_000_000_000u64;
    let added = add_report(
        &mut tally,
        now,
        &json!({"bucketMs": 0.1, "gaps": [[83, 10], [5000, 2], ["x", 1], [1]]}),
    );
    assert_eq!(added, Ok(12));
    let window = tally.window(now);
    assert_eq!(window.get(83), Some(&10));
    assert_eq!(window.get(BUCKETS), Some(&2));
    assert!(add_report(&mut tally, now, &json!({"bucketMs": 0.5, "gaps": [[1, 1]]})).is_err());
    assert_eq!(tally.window(now).iter().sum::<u64>(), 12);
}

/// The daemon's half of the per-frame cost: one tally of a busy page's 5 s (300 frames in 20
/// buckets) added, and one read. Prints ns per call; run with `--nocapture` for the numbers.
#[test]
fn tally_cost_microbench() {
    let mut tally = Tally::new();
    let report =
        json!({"bucketMs": 0.1, "gaps": (0..20).map(|i| json!([80 + i, 15])).collect::<Vec<_>>()});
    let rounds = 2_000u64;
    let start = std::time::Instant::now();
    for round in 0..rounds {
        let _ = add_report(&mut tally, 4_000_000_000 + round * 5_000, &report);
    }
    let add_ns = start.elapsed().as_nanos() / u128::from(rounds);
    let start = std::time::Instant::now();
    for _ in 0..200 {
        std::hint::black_box(tally.read(4_000_000_000 + rounds * 5_000));
    }
    let read_ns = start.elapsed().as_nanos() / 200;
    println!("frame_tally: add one 5 s page tally {add_ns} ns, read {read_ns} ns");
}
