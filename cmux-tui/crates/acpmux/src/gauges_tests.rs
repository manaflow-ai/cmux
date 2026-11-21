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
