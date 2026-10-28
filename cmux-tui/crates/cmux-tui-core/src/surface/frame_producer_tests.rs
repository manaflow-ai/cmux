//! The shared frame producer under a busy terminal among many idle ones
//! (H3, audit batch 3). Run it: cargo test -p cmux-tui-core --release --lib --
//! frame_producer_bench --ignored --nocapture

use super::*;

/// The `surface-frames` thread's CPU time so far (Linux procfs), in ms.
#[cfg(target_os = "linux")]
fn producer_cpu_ms() -> Option<f64> {
    let tasks = std::fs::read_dir("/proc/self/task").ok()?;
    for task in tasks.flatten() {
        let comm = std::fs::read_to_string(task.path().join("comm")).unwrap_or_default();
        if comm.trim() != "surface-frames" {
            continue;
        }
        let stat = std::fs::read_to_string(task.path().join("stat")).ok()?;
        let fields: Vec<&str> = stat.rsplit_once(')')?.1.split_whitespace().collect();
        let ticks: f64 =
            fields.get(11)?.parse::<f64>().ok()? + fields.get(12)?.parse::<f64>().ok()?;
        // SAFETY: sysconf takes no pointers.
        let hz = unsafe { libc::sysconf(libc::_SC_CLK_TCK) } as f64;
        return Some(ticks * 1000.0 / hz);
    }
    None
}

/// One busy terminal requests a frame per output chunk while `IDLE` other
/// terminals are registered: what each request costs the reader, and what
/// the producer spends per request. Before H3 the request took the global
/// lock and woke the producer, which scanned every terminal.
#[cfg(target_os = "linux")]
#[test]
#[ignore = "bench: run with --ignored --nocapture"]
fn frame_producer_bench_one_busy_terminal_among_many_idle() {
    const IDLE: usize = 1000;
    const CHUNKS: u64 = 200_000;
    let idle: Vec<FrameRequests> = (0..IDLE).map(|_| FrameRequests::new()).collect();
    let busy = FrameRequests::new();
    // Settle: the producer thread exists once the scheduler does.
    std::thread::sleep(Duration::from_millis(50));
    let cpu_before = producer_cpu_ms().expect("the producer thread");
    let mut costs = Vec::with_capacity(CHUNKS as usize);
    let started = Instant::now();
    for generation in 1..=CHUNKS {
        let at = Instant::now();
        busy.request(generation);
        costs.push(at.elapsed().as_nanos() as u64);
    }
    let wall = started.elapsed();
    std::thread::sleep(Duration::from_millis(100));
    let cpu = producer_cpu_ms().expect("the producer thread") - cpu_before;
    costs.sort_unstable();
    let pct = |p: f64| costs[((costs.len() as f64 - 1.0) * p) as usize];
    println!(
        "FRAME-PRODUCER-BENCH idle={IDLE} chunks={CHUNKS} request_ns p50={} p95={} p99={} max={} \
         wall_ms={:.1} producer_cpu_ms={cpu:.1} producer_cpu_ns_per_chunk={:.0}",
        pct(0.50),
        pct(0.95),
        pct(0.99),
        costs[costs.len() - 1],
        wall.as_secs_f64() * 1000.0,
        cpu * 1e6 / CHUNKS as f64,
    );
    drop(idle);
}
