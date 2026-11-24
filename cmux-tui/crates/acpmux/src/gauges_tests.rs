use super::*;

#[test]
fn a_phase_reports_its_length_and_a_mark_only_its_first_time() {
    let gauges: &'static Gauges = Box::leak(Box::new(Gauges::new()));
    {
        let _phase = gauges.phase("store load");
        std::thread::sleep(Duration::from_millis(5));
    }
    gauges.mark("socket ready");
    gauges.mark("socket ready");
    let status = gauges.status();
    let phases = status["startup"].as_array().unwrap();
    assert_eq!(phases.len(), 2, "{status}");
    assert_eq!(phases[0]["name"], "store load");
    assert!(phases[0]["ms"].as_u64().unwrap() >= 5, "{status}");
    assert_eq!(phases[1]["name"], "socket ready");
    assert_eq!(phases[1]["ms"], 0);
    #[cfg(any(target_os = "linux", target_os = "macos"))]
    assert!(status["memory"]["rssBytes"].as_u64().unwrap() > 0, "{status}");
    assert!(status["attach"].get("p95Ms").is_some(), "{status}");
    assert!(status["fanout"].get("p95Ms").is_some(), "{status}");
}

#[test]
fn a_held_count_goes_back_down_when_dropped_and_never_below_zero() {
    static COUNT: AtomicU64 = AtomicU64::new(0);
    let a = Held::on(&COUNT);
    let b = Held::on(&COUNT);
    assert_eq!(COUNT.load(Ordering::Relaxed), 2);
    drop(a);
    assert_eq!(COUNT.load(Ordering::Relaxed), 1);
    COUNT.store(0, Ordering::Relaxed);
    drop(b);
    assert_eq!(COUNT.load(Ordering::Relaxed), 0);
    assert!(global().status()["links"].get("linkRedials").is_some());
}

#[test]
fn a_lag_counts_its_events_as_dropped_and_one_resync() {
    let before = fanout_status();
    fanout_lagged(7);
    let after = fanout_status();
    let grew = |field: &str| after[field].as_u64().unwrap() - before[field].as_u64().unwrap();
    // Other tests in this process may lag too: at least this one's.
    assert!(grew("dropped") >= 7, "{before} {after}");
    assert!(grew("resyncs") >= 1, "{before} {after}");
}

#[test]
fn an_empty_ring_reports_no_quantiles() {
    let status = Latencies::default().status();
    let none = json!({"count": 0, "window": 0, "p50Ms": null, "p95Ms": null, "maxMs": null});
    assert_eq!(status, none);
}

#[test]
fn the_ring_reports_nearest_rank_quantiles_of_its_window() {
    let ring = Latencies::default();
    // 1..=100 ms, shuffled by a stride coprime to 100.
    for i in 0..100u64 {
        ring.record(Duration::from_millis((i * 37) % 100 + 1));
    }
    let status = ring.status();
    assert_eq!(status["count"], 100);
    assert_eq!(status["window"], 100);
    assert_eq!(status["p50Ms"], 50.0);
    assert_eq!(status["p95Ms"], 95.0);
    assert_eq!(status["maxMs"], 100.0);
}

#[test]
fn the_ring_keeps_only_its_last_samples() {
    let ring = Latencies::default();
    // A slow start the ring has since overwritten, then a whole ring of 2 ms.
    for _ in 0..10 {
        ring.record(Duration::from_secs(9));
    }
    for _ in 0..LATENCY_RING {
        ring.record(Duration::from_millis(2));
    }
    let status = ring.status();
    assert_eq!(status["count"], (LATENCY_RING + 10) as u64);
    assert_eq!(status["window"], LATENCY_RING);
    assert_eq!(status["p95Ms"], 2.0);
    assert_eq!(status["maxMs"], 2.0);
}

#[test]
fn a_sample_is_whole_microseconds_and_saturates() {
    let ring = Latencies::default();
    ring.record(Duration::from_micros(1500));
    assert_eq!(ring.status()["p50Ms"], 1.5);
    ring.record(Duration::from_secs(u64::MAX / 4));
    assert_eq!(ring.status()["maxMs"], f64::from(u32::MAX) / 1000.0);
}

#[test]
fn a_fanout_records_once_when_its_last_connection_takes_it() {
    let ring = Latencies::default();
    let clock = FanoutClock::default();
    clock.arm(3);
    clock.taken_into(&ring);
    clock.taken_into(&ring);
    assert_eq!(ring.status()["count"], 0);
    clock.taken_into(&ring);
    assert_eq!(ring.status()["count"], 1);
    // A task that subscribed after the send takes it too: no second sample, no wrap.
    clock.taken_into(&ring);
    assert_eq!(ring.status()["count"], 1);
    // An event built but never sent records nothing.
    FanoutClock::default().taken_into(&ring);
    assert_eq!(ring.status()["count"], 1);
}

#[test]
fn an_empty_worker_lag_reports_no_quantiles() {
    let status = WorkerLag::default().summary_at(0);
    assert_eq!(status["samples"], 0, "{status}");
    assert_eq!(status["p50Ms"], Value::Null, "{status}");
    assert_eq!(status["p99Ms"], Value::Null, "{status}");
    assert_eq!(status["maxMs"], Value::Null, "{status}");
    assert_eq!(status["periodMs"], 10);
    assert_eq!(status["windowS"], 60);
}

#[test]
fn worker_lag_reports_nearest_rank_quantiles_of_its_last_minute() {
    let ring = WorkerLag::default();
    // A 900 ms stall 61 s before the read: out of the window.
    ring.record_at(39, Duration::from_millis(900));
    // 1..=200 ms over the last minute, shuffled by a stride coprime to 200.
    for i in 0..200u64 {
        ring.record_at(41 + i % 60, Duration::from_millis((i * 37) % 200 + 1));
    }
    let status = ring.summary_at(100);
    assert_eq!(status["samples"], 200, "{status}");
    assert_eq!(status["p50Ms"], 100.0, "{status}");
    assert_eq!(status["p99Ms"], 198.0, "{status}");
    assert_eq!(status["maxMs"], 200.0, "{status}");
    // A minute later every one of them has aged out.
    assert_eq!(ring.summary_at(160)["samples"], 0);
    // The edge: a sample taken at second 41 is in a read at 100, not at 101.
    assert_eq!(ring.summary_at(101)["samples"], 200 - 4, "{}", ring.summary_at(101));
}

#[test]
fn worker_lag_memory_is_fixed_and_keeps_only_its_last_samples() {
    let ring = WorkerLag::default();
    for _ in 0..10 {
        ring.record_at(5, Duration::from_secs(9));
    }
    for _ in 0..WORKER_LAG_RING {
        ring.record_at(5, Duration::from_micros(1500));
    }
    let status = ring.summary_at(5);
    assert_eq!(status["samples"], WORKER_LAG_RING, "{status}");
    assert_eq!(status["maxMs"], 1.5, "{status}");
    ring.record_at(5, Duration::from_secs(u64::MAX / 4));
    assert_eq!(ring.summary_at(5)["maxMs"], f64::from(u32::MAX) / 1000.0);
}

/// The canary on a one-worker runtime for `run`, with a task that blocks that worker for
/// `block` (a `std` sleep, as a `std` lock or a blocking read would) after 50 ms.
fn canary_max_ms(block: Option<Duration>, run: Duration) -> f64 {
    let ring: &'static WorkerLag = Box::leak(Box::default());
    let runtime = tokio::runtime::Builder::new_multi_thread()
        .worker_threads(1)
        .enable_time()
        .build()
        .unwrap();
    runtime.spawn(worker_lag_canary(ring));
    runtime.block_on(async {
        tokio::time::sleep(Duration::from_millis(50)).await;
        if let Some(block) = block {
            runtime_spawn_blocker(block);
        }
        tokio::time::sleep(run).await;
    });
    runtime.shutdown_background();
    let status = ring.status();
    assert!(status["samples"].as_u64().unwrap() > 5, "{status}");
    status["maxMs"].as_f64().unwrap()
}

fn runtime_spawn_blocker(block: Duration) {
    tokio::spawn(async move { std::thread::sleep(block) });
}

#[test]
fn the_canary_backs_off_only_after_a_quiet_second_and_snaps_back_on_work() {
    let ms = Duration::from_millis;
    let mut period = CANARY_PERIOD;
    let mut quiet = Duration::ZERO;
    let mut wakes = 0;
    // Quiet: 10 ms wakes for the first second, then doubling to the idle period.
    while quiet < Duration::from_secs(120) {
        (period, quiet) = canary_next(period, Duration::ZERO, Duration::from_micros(20), quiet);
        wakes += 1;
        if quiet < CANARY_QUIET_BEFORE_BACKOFF {
            assert_eq!(period, CANARY_PERIOD, "backed off after {quiet:?} of quiet");
        }
    }
    assert_eq!(period, CANARY_IDLE_PERIOD);
    // Two minutes of quiet cost about 100 + 9 + 29 wakes, not 12,000.
    assert!(wakes < 150, "{wakes} wakes in two quiet minutes");
    // A coalesced idle timer (40 ms late on a 4 s sleep) is not a block.
    let (next, _) = canary_next(CANARY_IDLE_PERIOD, ms(40), Duration::ZERO, quiet);
    assert_eq!(next, CANARY_IDLE_PERIOD);
    // A late wake or busy workers put it back at 10 ms with no quiet left.
    assert_eq!(
        canary_next(CANARY_IDLE_PERIOD, ms(200), Duration::ZERO, quiet),
        (CANARY_PERIOD, Duration::ZERO)
    );
    assert_eq!(
        canary_next(CANARY_IDLE_PERIOD, Duration::ZERO, ms(50), quiet),
        (CANARY_PERIOD, Duration::ZERO)
    );
    // Steady work keeps it at 10 ms.
    assert_eq!(canary_next(CANARY_PERIOD, Duration::ZERO, ms(1), Duration::ZERO).0, CANARY_PERIOD);
}

#[test]
fn a_blocked_worker_shows_in_the_worker_lag_max() {
    let max = canary_max_ms(Some(Duration::from_millis(200)), Duration::from_millis(400));
    assert!(max >= 150.0, "the canary woke at most {max} ms late behind a 200 ms block");
}

#[test]
fn an_idle_worker_keeps_the_worker_lag_small() {
    let max = canary_max_ms(None, Duration::from_millis(400));
    // Timer granularity is 1 ms; the bound leaves a loaded CI host room.
    assert!(max < 100.0, "the canary woke {max} ms late on an idle runtime");
}
