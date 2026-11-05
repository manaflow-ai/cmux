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
        busy.request(generation, false);
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

/// A producer-announced request (`request_frame`, a caller that may hold
/// `Mux::state`) landing between the producer's clear of `queued` and its
/// take of the generation still gets its output event (with the announce
/// flag read before the generation, the next round skipped a slot with the
/// flag but no generation).
#[test]
fn an_announced_request_inside_the_take_window_is_announced() {
    let mux = Mux::new_for_test("frame-announce-window", SurfaceOptions::default());
    let surface =
        Surface::spawn_for_test(9_950, SurfaceOptions::default(), Arc::downgrade(&mux)).unwrap();
    spawn_frame_producer(&surface).unwrap();
    let pty = surface.as_pty().unwrap();
    let slot = pty.frame_requests.slot_id_for_test();
    let fired = Arc::new(AtomicBool::new(false));
    // The hook asks again for this terminal, producer-announced, while the
    // producer is between the clear and the take.
    {
        let fired = fired.clone();
        let surface = surface.clone();
        *AFTER_CLEAR_HOOK.lock().unwrap() = Some(Arc::new(move |seen| {
            if seen == slot && !fired.swap(true, Ordering::SeqCst) {
                surface.as_pty().unwrap().frame_requests.request(2, true);
            }
        }));
    }
    pty.dirty.store(false, Ordering::SeqCst);
    // A reader's request: announced by the reader, so the producer must not.
    pty.frame_requests.request(1, false);
    let deadline = Instant::now() + Duration::from_secs(5);
    while !pty.dirty.load(Ordering::SeqCst) {
        assert!(
            Instant::now() < deadline,
            "the request made inside the take window never got its output event"
        );
        std::thread::sleep(Duration::from_millis(5));
    }
    assert!(fired.load(Ordering::SeqCst), "the window was never entered");
    *AFTER_CLEAR_HOOK.lock().unwrap() = None;
}
