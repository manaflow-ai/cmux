use super::*;

const HOUR: Duration = Duration::from_secs(60 * 60);

fn candidate(terminal_id: &str, attached: bool, attach_epoch: u64) -> IdleCandidate<'_> {
    IdleCandidate { terminal_id, idle_close: HOUR, attached, attach_epoch }
}

#[test]
fn unattached_terminal_is_due_only_once_its_policy_elapses() {
    let start = Instant::now();
    let mut tracker = IdleCloseTracker::default();
    let idle = [candidate("idle", false, 0)];

    assert!(tracker.due(start, &idle).is_empty(), "the first observation starts the clock");
    assert!(tracker.due(start + HOUR - Duration::from_secs(1), &idle).is_empty());
    assert_eq!(tracker.due(start + HOUR, &idle), vec!["idle".to_string()]);
}

#[test]
fn attached_terminal_is_never_due_and_detaching_restarts_the_clock() {
    let start = Instant::now();
    let mut tracker = IdleCloseTracker::default();

    assert!(tracker.due(start, &[candidate("view", false, 1)]).is_empty());
    assert!(tracker.due(start + 10 * HOUR, &[candidate("view", true, 1)]).is_empty());
    assert_eq!(tracker.tracked(), 0, "an attached terminal carries no idle clock");

    let detached_at = start + 11 * HOUR;
    assert!(tracker.due(detached_at, &[candidate("view", false, 1)]).is_empty());
    assert!(tracker.due(detached_at + HOUR / 2, &[candidate("view", false, 1)]).is_empty());
    assert_eq!(
        tracker.due(detached_at + HOUR, &[candidate("view", false, 1)]),
        vec!["view".to_string()]
    );
}

#[test]
fn reattach_between_ticks_resets_the_clock() {
    let start = Instant::now();
    let mut tracker = IdleCloseTracker::default();

    assert!(tracker.due(start, &[candidate("flicker", false, 1)]).is_empty());
    // A view attached and detached again between two ticks: the tick
    // only sees a newer attach epoch.
    let reattached = start + HOUR - Duration::from_secs(1);
    assert!(tracker.due(reattached, &[candidate("flicker", false, 2)]).is_empty());
    assert!(tracker.due(start + HOUR, &[candidate("flicker", false, 2)]).is_empty());
    assert_eq!(
        tracker.due(reattached + HOUR, &[candidate("flicker", false, 2)]),
        vec!["flicker".to_string()]
    );
}

#[test]
fn terminal_without_a_policy_is_forgotten() {
    let start = Instant::now();
    let mut tracker = IdleCloseTracker::default();

    assert!(tracker.due(start, &[candidate("cleared", false, 0)]).is_empty());
    assert_eq!(tracker.tracked(), 1);
    // Clearing the policy (`null`) removes the terminal from the candidates.
    assert!(tracker.due(start + 100 * HOUR, &[]).is_empty());
    assert_eq!(tracker.tracked(), 0);
    // A policy set again later starts a fresh clock.
    assert!(tracker.due(start + 101 * HOUR, &[candidate("cleared", false, 0)]).is_empty());
}
