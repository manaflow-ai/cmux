//! The cost of one hop, alone and under duress, with flow marks off and on.
//!
//! `cargo run --release -p cmux-flow-trace --example hop_cost [-- --on] [-- --seconds N]`
//!
//! `--on` points CMUX_TRACE_FLOWS at a fresh temporary directory before `init`, so hops also go to
//! the file's ring and writer thread. Each sample times a batch of [`BATCH`] hops with one pair of
//! clock reads and divides (a clock read costs about as much as a hop). One thread first for
//! `seconds`, then [`THREADS`] threads hopping at once for `seconds` (duress). p50 and p99 are per
//! hop, over the batches.

use std::time::{Duration, Instant};

const BATCH: u32 = 32;
const THREADS: usize = 8;

fn run(seconds: u64) -> Vec<u64> {
    let terminal = [0xab_u8; 16];
    let mut samples = Vec::with_capacity(1 << 20);
    let end = Instant::now() + Duration::from_secs(seconds);
    let mut flow = 1_u64;
    while Instant::now() < end {
        for _ in 0..64 {
            let start = Instant::now();
            for _ in 0..BATCH / 2 {
                cmux_flow_trace::hop("bench.send.read", flow, "00112233445566778899aabbccddeeff");
                cmux_flow_trace::hop_id("bench.pty.read", 0, &terminal);
                flow += 1;
            }
            samples.push(start.elapsed().as_nanos() as u64);
        }
    }
    samples
}

fn report(label: &str, mut batches: Vec<u64>) {
    batches.sort_unstable();
    let at = |q: f64| {
        let index = ((batches.len() - 1) as f64 * q) as usize;
        batches.get(index).copied().unwrap_or(0) as f64 / f64::from(BATCH)
    };
    println!(
        "{label}: {} hops, p50 {:.1} ns, p99 {:.1} ns, max {:.1} ns",
        batches.len() as u64 * u64::from(BATCH),
        at(0.50),
        at(0.99),
        at(1.0)
    );
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let on = args.iter().any(|arg| arg == "--on");
    let seconds = args
        .iter()
        .position(|arg| arg == "--seconds")
        .and_then(|index| args.get(index + 1))
        .and_then(|text| text.parse().ok())
        .unwrap_or(3);
    if on {
        let dir = std::env::temp_dir().join(format!("hop-cost-{}", std::process::id()));
        std::fs::create_dir_all(&dir).expect("temp dir");
        // SAFETY: set before any other thread starts.
        unsafe { std::env::set_var("CMUX_TRACE_FLOWS", &dir) };
    }
    let enabled = cmux_flow_trace::init();
    println!("flow marks to a file: {}", if enabled { "on" } else { "off" });
    report("1 thread", run(seconds));
    let threads: Vec<_> = (0..THREADS).map(|_| std::thread::spawn(move || run(seconds))).collect();
    let mut all = Vec::new();
    for thread in threads {
        all.extend(thread.join().expect("bench thread"));
    }
    report(&format!("{THREADS} threads at once"), all);
    extra::report_dump();
}

/// The cost of `dump_recent` (the flight recorder), idle and while [`THREADS`] threads hop.
mod extra {
    use cmux_flow_trace::{RECENT_EVENTS, RecentEvent, dump_recent};
    use std::sync::Arc;
    use std::sync::atomic::{AtomicBool, Ordering};
    use std::time::Instant;

    fn dumps(want: usize) -> (f64, f64, usize) {
        let mut out = [RecentEvent::EMPTY; RECENT_EVENTS];
        let mut samples = Vec::with_capacity(20_000);
        let mut got = 0;
        for _ in 0..20_000 {
            let start = Instant::now();
            got = dump_recent(&mut out[..want], None);
            samples.push(start.elapsed().as_nanos() as u64);
        }
        samples.sort_unstable();
        let at = |q: f64| samples[((samples.len() - 1) as f64 * q) as usize] as f64;
        (at(0.5), at(0.99), got)
    }

    pub fn report_dump() {
        for want in [64, RECENT_EVENTS] {
            let (p50, p99, got) = dumps(want);
            println!("dump_recent({want}) idle: {got} events, p50 {p50:.0} ns, p99 {p99:.0} ns");
        }
        let stop = Arc::new(AtomicBool::new(false));
        let threads: Vec<_> = (0..super::THREADS)
            .map(|_| {
                let stop = stop.clone();
                std::thread::spawn(move || {
                    let mut flow = 0;
                    while !stop.load(Ordering::Relaxed) {
                        cmux_flow_trace::hop("bench.send.read", flow, "00ff");
                        flow += 1;
                    }
                })
            })
            .collect();
        for want in [64, RECENT_EVENTS] {
            let (p50, p99, got) = dumps(want);
            println!(
                "dump_recent({want}) while {} threads hop: {got} events, p50 {p50:.0} ns, p99 {p99:.0} ns",
                super::THREADS
            );
        }
        stop.store(true, Ordering::Relaxed);
        for thread in threads {
            let _ = thread.join();
        }
    }
}
