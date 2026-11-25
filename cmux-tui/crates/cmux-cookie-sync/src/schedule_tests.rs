use super::Scheduler;
use std::time::Duration;

fn ms(value: u64) -> Duration {
    Duration::from_millis(value)
}

#[test]
fn nothing_is_due_without_an_event() {
    let schedule = Scheduler::new(2, ms(2000), ms(30_000));
    assert_eq!(schedule.next_due(), None);
    assert!(schedule.due(ms(1_000_000)).is_empty());
}

#[test]
fn a_burst_is_one_scan_after_the_quiet_period() {
    let mut schedule = Scheduler::new(1, ms(2000), ms(30_000));
    for at in [0, 100, 300, 900] {
        schedule.event(0, ms(at));
    }
    assert_eq!(schedule.next_due(), Some(ms(2900)));
    assert!(schedule.due(ms(2899)).is_empty());
    assert_eq!(schedule.due(ms(2900)), vec![0]);
    schedule.scanned(0, ms(2900));
    assert_eq!(schedule.next_due(), None);
}

#[test]
fn scans_are_at_least_min_interval_apart() {
    let mut schedule = Scheduler::new(1, ms(2000), ms(30_000));
    schedule.scanned(0, ms(0));
    schedule.event(0, ms(1000));
    assert_eq!(schedule.next_due(), Some(ms(30_000)));
    assert!(schedule.due(ms(3000)).is_empty());
    assert_eq!(schedule.due(ms(30_000)), vec![0]);
}

#[test]
fn a_store_that_never_goes_quiet_is_still_scanned() {
    let mut schedule = Scheduler::new(1, ms(2000), ms(30_000));
    let mut at = 0;
    while at < 40_000 {
        schedule.event(0, ms(at));
        at += 500;
    }
    assert_eq!(schedule.next_due(), Some(ms(30_000)));
}

#[test]
fn sources_are_scheduled_apart_and_a_removed_one_never_again() {
    let mut schedule = Scheduler::new(2, ms(100), ms(0));
    schedule.event(0, ms(0));
    schedule.event(1, ms(50));
    assert_eq!(schedule.due(ms(100)), vec![0]);
    assert_eq!(schedule.due(ms(150)), vec![0, 1]);
    schedule.remove(1);
    schedule.event(1, ms(200));
    assert_eq!(schedule.due(ms(10_000)), vec![0]);
}
