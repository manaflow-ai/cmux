use std::ops::{Add, Sub};

use super::*;

const HOUR: Duration = Duration::from_secs(60 * 60);

/// The awake and the wall clock, moving together unless a test says not.
#[derive(Debug, Clone, Copy)]
struct Clocks {
    awake: Instant,
    wall: SystemTime,
}

impl Clocks {
    fn now() -> Self {
        Self { awake: Instant::now(), wall: SystemTime::now() }
    }
}

impl Add<Duration> for Clocks {
    type Output = Self;

    fn add(self, by: Duration) -> Self {
        Self { awake: self.awake + by, wall: self.wall + by }
    }
}

impl Sub<Duration> for Clocks {
    type Output = Self;

    fn sub(self, by: Duration) -> Self {
        Self { awake: self.awake - by, wall: self.wall - by }
    }
}

fn due(
    tracker: &mut IdleCloseTracker,
    at: Clocks,
    candidates: &[IdleCandidate<'_>],
) -> Vec<String> {
    tracker.due(at.awake, at.wall, candidates)
}

fn candidate(terminal_id: &str, attached: bool, attach_epoch: u64) -> IdleCandidate<'_> {
    IdleCandidate { terminal_id, idle_close: HOUR, attached, attach_epoch }
}

#[test]
fn unattached_terminal_is_due_only_once_its_policy_elapses() {
    let start = Clocks::now();
    let mut tracker = IdleCloseTracker::default();
    let idle = [candidate("idle", false, 0)];

    assert!(due(&mut tracker, start, &idle).is_empty(), "the first observation starts the clock");
    assert!(due(&mut tracker, start + HOUR - Duration::from_secs(1), &idle).is_empty());
    assert_eq!(due(&mut tracker, start + HOUR, &idle), vec!["idle".to_string()]);
}

#[test]
fn attached_terminal_is_never_due_and_detaching_restarts_the_clock() {
    let start = Clocks::now();
    let mut tracker = IdleCloseTracker::default();

    assert!(due(&mut tracker, start, &[candidate("view", false, 1)]).is_empty());
    assert!(due(&mut tracker, start + 10 * HOUR, &[candidate("view", true, 1)]).is_empty());
    assert_eq!(tracker.tracked(), 0, "an attached terminal carries no idle clock");

    let detached_at = start + 11 * HOUR;
    assert!(due(&mut tracker, detached_at, &[candidate("view", false, 1)]).is_empty());
    assert!(due(&mut tracker, detached_at + HOUR / 2, &[candidate("view", false, 1)]).is_empty());
    assert_eq!(
        due(&mut tracker, detached_at + HOUR, &[candidate("view", false, 1)]),
        vec!["view".to_string()]
    );
}

#[test]
fn reattach_between_ticks_resets_the_clock() {
    let start = Clocks::now();
    let mut tracker = IdleCloseTracker::default();

    assert!(due(&mut tracker, start, &[candidate("flicker", false, 1)]).is_empty());
    // A view attached and detached again between two ticks: the tick
    // only sees a newer attach epoch.
    let reattached = start + HOUR - Duration::from_secs(1);
    assert!(due(&mut tracker, reattached, &[candidate("flicker", false, 2)]).is_empty());
    assert!(due(&mut tracker, start + HOUR, &[candidate("flicker", false, 2)]).is_empty());
    assert_eq!(
        due(&mut tracker, reattached + HOUR, &[candidate("flicker", false, 2)]),
        vec!["flicker".to_string()]
    );
}

#[test]
fn terminal_without_a_policy_is_forgotten() {
    let start = Clocks::now();
    let mut tracker = IdleCloseTracker::default();

    assert!(due(&mut tracker, start, &[candidate("cleared", false, 0)]).is_empty());
    assert_eq!(tracker.tracked(), 1);
    // Clearing the policy (`null`) removes the terminal from the candidates.
    assert!(due(&mut tracker, start + 100 * HOUR, &[]).is_empty());
    assert_eq!(tracker.tracked(), 0);
    // A policy set again later starts a fresh clock.
    assert!(due(&mut tracker, start + 101 * HOUR, &[candidate("cleared", false, 0)]).is_empty());
}

#[test]
fn the_time_the_mac_slept_counts_toward_the_policy() {
    let start = Clocks::now();
    let mut tracker = IdleCloseTracker::default();
    let idle = [candidate("slept", false, 0)];

    assert!(due(&mut tracker, start, &idle).is_empty());
    // A minute awake, then the Mac slept past the hour: the wall clock counts it.
    let minute = Duration::from_secs(60);
    let woke = Clocks { awake: start.awake + minute, wall: start.wall + HOUR + minute };
    assert_eq!(tracker.next_deadline(woke.awake, woke.wall, &idle), Some(woke.awake));
    assert_eq!(due(&mut tracker, woke, &idle), vec!["slept".to_string()]);
}

#[test]
fn a_wall_clock_set_back_counts_the_awake_time() {
    let start = Clocks::now();
    let mut tracker = IdleCloseTracker::default();
    let idle = [candidate("back", false, 0)];
    let back =
        |awake: Duration| Clocks { awake: start.awake + awake, wall: start.wall - 24 * HOUR };

    assert!(due(&mut tracker, start, &idle).is_empty());
    assert!(due(&mut tracker, back(HOUR - Duration::from_secs(1)), &idle).is_empty());
    assert_eq!(due(&mut tracker, back(HOUR), &idle), vec!["back".to_string()]);
}

#[test]
fn the_reaper_waits_at_most_one_recheck_on_the_awake_clock() {
    let start = Clocks::now();
    let mut tracker = IdleCloseTracker::default();
    let idle = [candidate("long", false, 0)];

    assert!(due(&mut tracker, start, &idle).is_empty());
    // An hour policy: the reaper looks again after one recheck, not the hour,
    // so a sleep in between is seen soon after waking.
    assert_eq!(
        tracker.next_deadline(start.awake, start.wall, &idle),
        Some(start.awake + IDLE_CLOSE_SLEEP_RECHECK)
    );
    let late = start + HOUR - Duration::from_secs(60);
    assert_eq!(
        tracker.next_deadline(late.awake, late.wall, &idle),
        Some(late.awake + Duration::from_secs(60))
    );
}
