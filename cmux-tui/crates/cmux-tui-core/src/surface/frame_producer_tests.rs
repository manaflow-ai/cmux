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

/// Feed `bytes` to the test terminal as output and ask the producer for its
/// frame, as the PTY reader does; the requested generation.
fn feed_sync_output(pty: &PtySurface, bytes: &[u8]) -> u64 {
    pty.term.lock().unwrap().vt_write(bytes);
    let generation = pty.render_generation.fetch_add(1, Ordering::AcqRel) + 1;
    pty.frame_requests.request(generation, false);
    generation
}

fn built_generation(pty: &PtySurface) -> u64 {
    pty.render.lock().unwrap().built_generation
}

fn wait_for_built(pty: &PtySurface, generation: u64, within: Duration) -> Option<Duration> {
    let started = Instant::now();
    while built_generation(pty) < generation {
        if started.elapsed() > within {
            return None;
        }
        std::thread::sleep(Duration::from_millis(2));
    }
    Some(started.elapsed())
}

/// A synchronized update (DEC mode 2026) draws as one frame for a render
/// viewer: no frame while the program holds the mode, then one frame with the
/// whole update as soon as it ends.
#[test]
fn a_synchronized_update_is_one_frame_for_a_render_viewer() {
    let mux = Mux::new_for_test("frame-sync-output", SurfaceOptions::default());
    let surface =
        Surface::spawn_for_test(9_951, SurfaceOptions::default(), Arc::downgrade(&mux)).unwrap();
    spawn_frame_producer(&surface).unwrap();
    let pty = surface.as_pty().unwrap();
    let _viewer = surface.attach_render_stream().unwrap();

    let before = feed_sync_output(pty, b"\x1b[1;1Hbefore");
    assert!(wait_for_built(pty, before, Duration::from_secs(5)).is_some(), "plain output built no frame");

    let half = feed_sync_output(pty, b"\x1b[?2026h\x1b[2J\x1b[1;1Hhalf");
    std::thread::sleep(Duration::from_millis(200));
    assert!(built_generation(pty) < half, "a frame of the half-drawn update was built");

    let done = feed_sync_output(pty, b" done\x1b[?2026l");
    let waited = wait_for_built(pty, done, Duration::from_millis(500))
        .expect("the update's end built no frame");
    assert!(waited < SYNCHRONIZED_OUTPUT_HOLD / 2, "the end of the update waited {waited:?}");
}

/// A program that starts a synchronized update and never ends it is shown
/// again after the hold, so the view never freezes.
#[test]
fn an_update_that_never_ends_is_shown_after_the_hold() {
    let mux = Mux::new_for_test("frame-sync-output-stuck", SurfaceOptions::default());
    let surface =
        Surface::spawn_for_test(9_952, SurfaceOptions::default(), Arc::downgrade(&mux)).unwrap();
    spawn_frame_producer(&surface).unwrap();
    let pty = surface.as_pty().unwrap();
    let _viewer = surface.attach_render_stream().unwrap();

    let stuck = feed_sync_output(pty, b"\x1b[?2026h\x1b[1;1Hstuck");
    std::thread::sleep(Duration::from_millis(300));
    assert!(built_generation(pty) < stuck, "the open update was drawn before the hold ended");
    assert!(
        wait_for_built(pty, stuck, SYNCHRONIZED_OUTPUT_HOLD * 3).is_some(),
        "an update that never ended was never drawn"
    );
}

/// With no render viewer nothing is held: the output event still goes out.
#[test]
fn a_synchronized_update_without_a_viewer_holds_nothing() {
    let mux = Mux::new_for_test("frame-sync-output-unviewed", SurfaceOptions::default());
    let surface =
        Surface::spawn_for_test(9_953, SurfaceOptions::default(), Arc::downgrade(&mux)).unwrap();
    spawn_frame_producer(&surface).unwrap();
    let pty = surface.as_pty().unwrap();
    pty.dirty.store(false, Ordering::SeqCst);
    pty.term.lock().unwrap().vt_write(b"\x1b[?2026h\x1b[1;1Hx");
    let generation = pty.render_generation.fetch_add(1, Ordering::AcqRel) + 1;
    pty.frame_requests.request(generation, true);
    let deadline = Instant::now() + Duration::from_millis(500);
    while !pty.dirty.load(Ordering::SeqCst) {
        assert!(Instant::now() < deadline, "an unviewed synchronized update held its output event");
        std::thread::sleep(Duration::from_millis(5));
    }
}
