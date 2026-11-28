use super::*;

#[test]
fn starved_time_sums_over_the_window_and_old_seconds_fall_out() {
    let t0 = Instant::now();
    let meter = Starved::new(t0);
    meter.record(t0 + Duration::from_secs(1), Duration::from_millis(900));
    meter.record(t0 + Duration::from_secs(2), Duration::from_millis(800));
    meter.record(t0 + Duration::from_secs(2), Duration::from_millis(10)); // slack
    let now = t0 + Duration::from_secs(3);
    assert_eq!(meter.within(now, Duration::from_secs(5)), Duration::from_millis(1700));
    assert_eq!(
        meter.within(now, Duration::from_secs(1)),
        Duration::from_secs(1),
        "never past the window"
    );
    assert_eq!(meter.within(t0 + Duration::from_secs(60), Duration::from_secs(5)), Duration::ZERO);
    // A second KEPT later reuses the slot and does not read the old one's time.
    let later = t0 + Duration::from_secs(1 + KEPT as u64);
    meter.record(later, Duration::from_millis(100));
    assert_eq!(meter.within(later, Duration::from_secs(0)), Duration::from_millis(100));
}

/// The canary wakes the process 10 times a second; with no link loop reading the meter that was
/// all an idle daemon did (cmux20-bench, 2026-11-28, acpmux-daemon idle: 11.37 wakeups/s against
/// a 1.0/s budget, 0.88/s before the canary). It sleeps while no link loop watches, and wakes
/// again when one does.
#[test]
fn the_canary_sleeps_while_no_link_loop_watches() {
    static METER: OnceLock<Starved> = OnceLock::new();
    static GATE: Gate = Gate::new();
    let meter = METER.get_or_init(Starved::default);
    let rt = tokio::runtime::Builder::new_current_thread().enable_time().build().unwrap();
    rt.block_on(async {
        let watch = GATE.watch();
        let canary = tokio::spawn(canary(meter, &GATE));
        tokio::time::sleep(TICK * 3).await;
        assert!(GATE.ticks() >= 1, "it runs while watched");
        drop(watch);
        // The tick under way ends; then it waits.
        tokio::time::sleep(TICK * 2).await;
        let resting = GATE.ticks();
        tokio::time::sleep(Duration::from_secs(1)).await;
        assert_eq!(
            GATE.ticks(),
            resting,
            "it woke {} times in 1 s with no watcher",
            GATE.ticks() - resting
        );
        let _again = GATE.watch();
        tokio::time::sleep(TICK * 3).await;
        assert!(GATE.ticks() > resting, "a new watcher wakes it");
        canary.abort();
    });
}

/// A runtime whose one thread is blocked 1.5 s: the canary's next wake records it.
#[test]
fn a_blocked_runtime_reads_as_starved() {
    static METER: OnceLock<Starved> = OnceLock::new();
    static GATE: Gate = Gate::new();
    let meter = METER.get_or_init(Starved::default);
    let rt = tokio::runtime::Builder::new_current_thread().enable_time().build().unwrap();
    rt.block_on(async {
        let _watch = GATE.watch();
        let canary = tokio::spawn(canary(meter, &GATE));
        tokio::time::sleep(Duration::from_millis(20)).await;
        std::thread::sleep(Duration::from_millis(1500));
        tokio::time::sleep(Duration::from_millis(250)).await;
        canary.abort();
    });
    let starved = meter.within(Instant::now(), Duration::from_secs(5));
    assert!(starved >= Duration::from_millis(1200), "starved {starved:?}");
}

/// The 2 s floor (cmux#54786) on a starved host: 3 s silent, 2.5 s of it starved, is a slow
/// reader, not a dead peer; 3 s silent on a host that ran is past the budget.
#[test]
fn a_starved_link_at_the_two_second_floor_is_not_dropped() {
    let floor = Duration::from_secs(2);
    let silent = Duration::from_secs(3);
    assert!(!past_budget(silent, Duration::ZERO, Duration::from_millis(2500), floor));
    assert!(!past_budget(silent, Duration::from_millis(1500), Duration::from_millis(1000), floor));
    assert!(past_budget(silent, Duration::ZERO, Duration::ZERO, floor));
    assert!(past_budget(silent, Duration::from_millis(500), Duration::from_millis(900), floor));
}
