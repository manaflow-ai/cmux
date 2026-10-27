//! A second client probes an owner it cannot watch on the shared
//! backoff, not every 25 ms for the whole restore (p14-energy-077b).

use std::time::{Duration, Instant};

use super::{PROBE_RETRY_MAX, pause_before_probe, probe_backoff};

#[test]
fn probes_of_a_foreign_owner_space_out_to_the_cap() {
    let mut retry = probe_backoff();
    let gaps: Vec<Duration> = (0..12).map(|_| retry.next_delay()).collect();
    assert!(gaps[0] < Duration::from_millis(40), "the first probe comes soon: {gaps:?}");
    assert!(gaps.iter().all(|gap| *gap <= PROBE_RETRY_MAX), "{gaps:?}");
    assert!(
        gaps[4..].iter().all(|gap| *gap >= PROBE_RETRY_MAX * 3 / 4),
        "a long restore is probed about four times a second: {gaps:?}"
    );
}

#[test]
fn a_probe_gap_never_runs_past_the_deadline() {
    let mut retry = probe_backoff();
    for _ in 0..8 {
        retry.next_delay();
    }
    let started = Instant::now();
    pause_before_probe(&mut retry, started + Duration::from_millis(20));
    assert!(started.elapsed() < Duration::from_millis(150));
}
