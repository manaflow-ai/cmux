//! Pacing after a temporarily slow build, with a paused clock so the regression
//! measures deliberate sleep rather than runner contention.
use super::*;

#[tokio::test(start_paused = true)]
async fn cheaper_builds_do_not_inherit_the_slow_builds_time_debt() {
    let now = Instant::now();
    let slow = Duration::from_secs(15);
    let fast = Duration::from_millis(100);
    let mut pace = Pacer::default();
    for _ in 0..BURST {
        pace.spend(now, slow, slow);
    }
    let old_wait = pace.ahead_to.unwrap().saturating_duration_since(now + fast * (BURST - 1));
    let wait = pace.wait(now, fast * (BURST - 1), fast);
    eprintln!("list pacing: old={old_wait:?}, repriced={wait:?}");
    assert_eq!(old_wait, Duration::from_millis(59_700));
    assert_eq!(wait, fast);
    // A completed cheap build updates its rate before charging that build too.
    pace.spend(now + wait, fast, fast);
    assert!(pace.wait(now + wait, fast * (BURST - 1), fast) <= fast);
}

#[tokio::test(start_paused = true)]
async fn rising_and_falling_costs_preserve_outstanding_work() {
    let now = Instant::now();
    let fast = Duration::from_millis(100);
    let slow = Duration::from_secs(15);
    let mut pace = Pacer::default();
    pace.spend(now, fast, fast);
    assert_eq!(pace.wait(now, Duration::ZERO, slow), slow);
    pace.spend(now, slow, slow);
    assert_eq!(pace.wait(now, Duration::ZERO, slow), slow * 2);
    tokio::time::advance(slow * 2).await;
    assert_eq!(pace.wait(Instant::now(), Duration::ZERO, fast), Duration::ZERO);
}

#[tokio::test(start_paused = true)]
async fn oscillating_build_costs_keep_the_sustained_cpu_budget() {
    let mut pace = Pacer::default();
    let mut now = Instant::now();
    let mut window = Duration::ZERO;
    let mut sleep = Duration::ZERO;
    let mut work = Duration::ZERO;
    for n in 0..1_000 {
        // Same builder pacing and charging as snapshot(), invalidated each time.
        let wait = pace.wait(now, window * (BURST - 1), window).min(window);
        sleep += wait;
        now += wait;
        let cost = Duration::from_millis(if n % 2 == 0 { 10 } else { 30 });
        window = cost.saturating_mul(PACE).min(MAX_WINDOW);
        pace.spend(now, window, window);
        now += cost;
        work += cost;
    }
    eprintln!("oscillating list cost: {work:?} work, {sleep:?} deliberate sleep");
    // The former asymmetric repricing admitted all 20 s of work with zero sleep.
    // Allow the initial burst; sustained work still consumes about 1/32 of a core.
    assert!(sleep >= work * (PACE - 2), "{work:?} work, {sleep:?} sleep");
}

#[tokio::test(start_paused = true)]
async fn reply_reservations_reprice_connection_and_shared_debt() {
    let guard = ListGuard::default();
    let connection = StdMutex::default();
    guard.window_nanos.store(15_000_000_000, Ordering::Relaxed);
    assert_eq!(guard.reserve(&connection, 1.0), Ok(Duration::ZERO));
    assert_eq!(guard.reserve(&connection, 1.0), Ok(Duration::ZERO));
    guard.window_nanos.store(100_000_000, Ordering::Relaxed);
    assert_eq!(guard.reserve(&connection, 1.0), Ok(Duration::from_millis(100)));
    // Separate connections exhaust the shared burst, with no per-connection debt.
    let guard = ListGuard::default();
    guard.window_nanos.store(15_000_000_000, Ordering::Relaxed);
    for _ in 0..=REPLIES {
        assert_eq!(guard.reserve(&StdMutex::default(), 1.0), Ok(Duration::ZERO));
    }
    guard.window_nanos.store(100_000_000, Ordering::Relaxed);
    assert_eq!(guard.reserve(&StdMutex::default(), 1.0), Ok(Duration::from_micros(12_500)));
}

/// Repricing must not treat a refused request's future slot as the current clock.
#[tokio::test(start_paused = true)]
async fn a_rejected_reservation_does_not_advance_shared_debt() {
    let guard = ListGuard::default();
    let connection = StdMutex::default();
    guard.window_nanos.store(15_000_000_000, Ordering::Relaxed);
    for _ in 0..4 {
        assert!(guard.reserve(&connection, 1.0).is_ok());
    }
    guard.window_nanos.store(14_000_000_000, Ordering::Relaxed);
    assert_eq!(guard.reserve(&connection, 1.0), Err(Duration::from_secs(42)));
    // Prior admitted shared debt is 31.875 s, repriced to 29.75 s. With the
    // 14 s shared burst, a new connection waits 15.75 s, not the rejected 28 s.
    assert_eq!(guard.reserve(&StdMutex::default(), 1.0), Ok(Duration::from_millis(15_750)));
}

/// A dogfood-sized hub: 7,295 closed records must stay out of the live list index.
fn scale_hub() -> Arc<Hub> {
    let store = crate::store::MemoryStore::default();
    for n in 0..7_828 {
        let meta = serde_json::from_value(json!({
            "schema": crate::store::META_SCHEMA, "id": format!("scale-{n:04}"),
            "name": format!("scale-{n:04}"), "harness": "claude", "family": "claude",
            "agentSessionId": format!("chat-{n:04}"), "cwd": "/nonexistent",
            "status": if n < 7_295 { "closed" } else { "idle" },
            "createdAt": 1, "updatedAt": n + 1,
            "preview": "A short synthetic reply", "configOptions": [{"payload": "x".repeat(32_768)}]
        }))
        .unwrap();
        crate::store::Store::save(&store, &meta).unwrap();
    }
    Hub::new(Config::default(), Box::new(store))
}

#[tokio::test(start_paused = true)]
async fn a_700_session_snapshot_sleeps_at_most_one_current_window() {
    let hub = scale_hub();
    let guard = &hub.list_guard;
    let window = Duration::from_millis(100);
    guard.window_nanos.store(100_000_000, Ordering::Relaxed);
    // Excess debt is bounded even independently of repricing (e.g. queued work).
    guard.state.lock().await.pace =
        Pacer { ahead_to: Some(Instant::now() + Duration::from_secs(60)), period: window };
    let started = Instant::now();
    let snapshot = guard.snapshot_live(&hub).await;
    assert_eq!(snapshot.keys.len(), 533);
    assert!(started.elapsed() <= window + Duration::from_millis(1), "{:?}", started.elapsed());
    eprintln!(
        "700-session snapshot: paced sleep={:?}, rows={}",
        started.elapsed(),
        snapshot.keys.len()
    );
}

#[cfg(target_os = "linux")]
fn process_cpu() -> Duration {
    let mut value = std::mem::MaybeUninit::<libc::timespec>::uninit();
    assert_eq!(
        unsafe { libc::clock_gettime(libc::CLOCK_PROCESS_CPUTIME_ID, value.as_mut_ptr()) },
        0
    );
    let value = unsafe { value.assume_init() };
    Duration::new(u64::try_from(value.tv_sec).unwrap(), u32::try_from(value.tv_nsec).unwrap())
}

/// Same 7,828-record fixture used for the live-index before/after measurement. Each pair uses
/// the same operation with the pre-index full walk and the indexed live projection.
#[cfg(target_os = "linux")]
#[tokio::test]
#[ignore = "manual live-index measurement"]
async fn measure_7828_exclude_closed_index() {
    let rounds = 5;
    let measure = |mut run: Box<dyn FnMut()>| {
        let start = std::time::Instant::now();
        let cpu = process_cpu();
        for _ in 0..rounds {
            run();
        }
        (
            start.elapsed().as_secs_f64() * 1000.0 / f64::from(rounds),
            (process_cpu() - cpu).as_secs_f64() * 1000.0 / f64::from(rounds),
        )
    };

    let baseline = scale_hub();
    let (wall, cpu) = measure(Box::new(|| {
        std::hint::black_box(Snapshot::build(&baseline));
    }));
    eprintln!("7828 list baseline Snapshot::build: {wall:.3} wall ms/list, {cpu:.3} CPU ms/list");
    let indexed = scale_hub();
    let (wall, cpu) = measure(Box::new(|| {
        std::hint::black_box(Snapshot::build_live(&indexed));
    }));
    eprintln!("7828 list indexed Snapshot::build_live: {wall:.3} wall ms/list, {cpu:.3} CPU ms/list");

    let baseline = scale_hub();
    let (wall, cpu) = measure(Box::new(|| {
        std::hint::black_box(baseline.all_session_summaries());
    }));
    eprintln!("7828 locate/wait baseline all_session_summaries: {wall:.3} wall ms/list, {cpu:.3} CPU ms/list");
    let indexed = scale_hub();
    let (wall, cpu) = measure(Box::new(|| {
        std::hint::black_box(indexed.live_session_summaries());
    }));
    eprintln!("7828 locate/wait indexed live_session_summaries: {wall:.3} wall ms/list, {cpu:.3} CPU ms/list");
}
