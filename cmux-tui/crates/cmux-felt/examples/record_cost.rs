//! What one `record` costs, alone and with 8 threads hammering the same histogram.
//!
//! `cargo run --release -p cmux-felt --example record_cost`
//!
//! Each call is timed on its own (two clock reads around it, so the figures include about one
//! clock read of timer overhead; `empty` is that overhead alone, measured the same way). The
//! hammer threads record into the same metric in a loop for the length of the run.

use cmux_felt::{Felt, Metric};
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{Duration, Instant};

const CALLS: usize = 200_000;

fn percentiles(mut ns: Vec<u64>) -> (u64, u64) {
    ns.sort_unstable();
    let at = |p: usize| {
        ns.get((ns.len() * p / 100).min(ns.len().saturating_sub(1))).copied().unwrap_or(0)
    };
    (at(50), at(99))
}

fn measure(felt: &Felt) -> (u64, u64) {
    let mut ns = Vec::with_capacity(CALLS);
    for i in 0..CALLS {
        let start = Instant::now();
        felt.record(Metric::TerminalEcho, Duration::from_micros(100 + (i as u64 % 40_000)));
        ns.push(u64::try_from(start.elapsed().as_nanos()).unwrap_or(u64::MAX));
    }
    percentiles(ns)
}

fn main() {
    let mut ns = Vec::with_capacity(CALLS);
    for _ in 0..CALLS {
        let start = Instant::now();
        ns.push(u64::try_from(start.elapsed().as_nanos()).unwrap_or(u64::MAX));
    }
    let (p50, p99) = percentiles(ns);
    println!("record cost per call, {CALLS} calls (wall clock, ns)");
    println!("empty (two clock reads)   p50 {p50:>5}  p99 {p99:>5}");

    let felt = Arc::new(Felt::new());
    let (p50, p99) = measure(&felt);
    println!("1 thread                  p50 {p50:>5}  p99 {p99:>5}");

    let stop = Arc::new(AtomicBool::new(false));
    let hammers: Vec<_> = (0..7)
        .map(|_| {
            let (felt, stop) = (Arc::clone(&felt), Arc::clone(&stop));
            std::thread::spawn(move || {
                let mut i = 0u64;
                while !stop.load(Ordering::Relaxed) {
                    felt.record(Metric::TerminalEcho, Duration::from_micros(100 + i % 40_000));
                    i += 1;
                }
                i
            })
        })
        .collect();
    let (p50, p99) = measure(&felt);
    stop.store(true, Ordering::Relaxed);
    let hammered: u64 = hammers.into_iter().filter_map(|h| h.join().ok()).sum();
    println!("8 threads (7 hammering)   p50 {p50:>5}  p99 {p99:>5}   ({hammered} hammer records)");
    println!("{}", serde_json::to_string_pretty(&felt.snapshot()).unwrap_or_default());
}
