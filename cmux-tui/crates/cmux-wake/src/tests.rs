use std::sync::Arc;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::time::Duration;

use super::*;

const MS: u64 = 1_000_000;
const S: u64 = 1_000_000_000;

fn at(ns: u64) -> Ticks {
    Ticks(ns)
}

#[test]
fn zero_and_short_precise_delays_are_exact() {
    let now = at(S + 1);
    let zero = deadline(now, Duration::ZERO, Policy::FlexibleNoSooner);
    assert_eq!((zero.policy, zero.fire, zero.leeway), (Policy::Precise, now, Duration::ZERO));

    let short = deadline(now, Duration::from_millis(10), Policy::Precise);
    assert_eq!(short.policy, Policy::Precise);
    assert_eq!(short.fire, at(S + 1 + 10 * MS));
}

#[test]
fn precise_at_36_ms_or_more_snaps_to_the_8_ms_grid() {
    let window = deadline(at(S + 1), Duration::from_millis(50), Policy::Precise);
    assert_eq!(window.policy, Policy::FlexibleNoSooner);
    assert_eq!(window.leeway, DEFAULT_ALIGNMENT);
    assert_eq!(window.fire, at(S + 56 * MS));
    assert!(window.fire <= window.latest && window.fire >= window.earliest);
}

#[test]
fn saver_takes_the_32_ms_grid_below_one_second() {
    let window = deadline_aligned(
        at(S + 1),
        Duration::from_millis(500),
        Policy::FlexibleNoSooner,
        SAVER_ALIGNMENT,
    );
    assert_eq!(window.leeway, SAVER_ALIGNMENT);
    assert_eq!(window.fire.0 % (32 * MS), 0);
    assert_eq!(window.fire, at(S + 504 * MS));
}

#[test]
fn a_second_or_more_gets_ten_percent_capped_at_one_second_on_a_whole_second_grid() {
    let now = at(S / 2);
    let ten = deadline(now, Duration::from_secs(10), Policy::FlexibleNoSooner);
    assert_eq!(ten.leeway, MAX_LEEWAY);
    assert_eq!(ten.fire, at(11 * S));

    // 3.5 s target, 300 ms leeway: the 4 s boundary is past the window, so
    // it fires at the latest instant.
    let three = deadline(now, Duration::from_secs(3), Policy::FlexibleNoSooner);
    assert_eq!(three.leeway, Duration::from_millis(300));
    assert_eq!(three.fire, at(3 * S + 800 * MS));
}

#[test]
fn prefer_early_never_fires_after_the_deadline() {
    let window = deadline(at(S / 2), Duration::from_secs(10), Policy::FlexiblePreferEarly);
    assert_eq!(window.earliest, at(9 * S + S / 2));
    assert_eq!(window.latest, at(10 * S + S / 2));
    assert_eq!(window.fire, at(10 * S));
}

#[test]
fn nearby_flexible_deadlines_share_one_wake() {
    let first = deadline(at(0), Duration::from_millis(10_200), Policy::FlexibleNoSooner);
    let second = deadline(at(0), Duration::from_millis(10_600), Policy::FlexibleNoSooner);
    assert_eq!(first.fire, second.fire);
    assert_eq!(first.fire, at(11 * S));
}

#[test]
fn ticks_now_moves_forward_and_waits_count_from_now() {
    let before = Ticks::now();
    let window = deadline(before, Duration::from_secs(2), Policy::FlexibleNoSooner);
    assert!(Ticks::now() >= before);
    assert!(window.wait_from(before) >= Duration::from_secs(2));
    assert_eq!(window.wait_from(window.fire), Duration::ZERO);
}

#[test]
fn energy_mode_notifies_once_per_edge_and_stops_after_the_watch_drops() {
    let mode = EnergyMode::new(false);
    let calls = Arc::new(AtomicUsize::new(0));
    let seen = Arc::clone(&calls);
    let watch = mode.watch(move || {
        seen.fetch_add(1, Ordering::SeqCst);
    });

    assert!(!mode.set_saver(false), "the current value is not an edge");
    assert_eq!(calls.load(Ordering::SeqCst), 0);
    assert!(mode.set_saver(true));
    assert!(mode.is_saver());
    assert_eq!(calls.load(Ordering::SeqCst), 1);
    assert!(!mode.set_saver(true));
    assert_eq!(calls.load(Ordering::SeqCst), 1);

    drop(watch);
    assert!(mode.set_saver(false));
    assert_eq!(calls.load(Ordering::SeqCst), 1);
}

#[test]
fn energy_mode_deadlines_follow_the_mode() {
    let mode = EnergyMode::new(false);
    assert_eq!(mode.alignment(), DEFAULT_ALIGNMENT);
    mode.set_saver(true);
    assert_eq!(mode.alignment(), SAVER_ALIGNMENT);
    let window = mode.deadline(at(S + 1), Duration::from_millis(100), Policy::FlexibleNoSooner);
    assert_eq!(window.fire.0 % (32 * MS), 0);
    // A second or more keeps its whole-second window in the saver.
    let long = mode.deadline(at(0), Duration::from_secs(30), Policy::FlexibleNoSooner);
    assert_eq!(long.leeway, MAX_LEEWAY);
}

#[test]
fn the_module_never_sleeps_a_thread() {
    let banned = concat!("thread", "::sleep(");
    for source in
        [include_str!("lib.rs"), include_str!("energy.rs"), include_str!("maintenance.rs")]
    {
        assert!(!source.contains(banned));
    }
}
