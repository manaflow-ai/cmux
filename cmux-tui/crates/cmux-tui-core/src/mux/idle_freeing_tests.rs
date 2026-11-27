use super::*;

const MIN_MS: u64 = 60 * 1000;
const IDLE_MS: u64 = 1440 * MIN_MS;

fn view(
    host: &str,
    attached: bool,
    attach_epoch: u64,
    last_output_ms: Option<u64>,
) -> FreeingCandidate<'_> {
    FreeingCandidate { host, attached, attach_epoch, last_output_ms }
}

#[test]
fn a_quiet_unattached_terminal_comes_due_after_the_idle_time() {
    let start = 100 * IDLE_MS;
    let mut tracker = FreeingTracker::default();
    let quiet = [view("quiet", false, 0, Some(start - 10 * IDLE_MS))];
    assert!(tracker.due(start, IDLE_MS, &quiet).is_empty(), "no idle time from before tracking");
    assert_eq!(tracker.next_deadline_ms(IDLE_MS), Some(start + IDLE_MS));
    assert!(tracker.due(start + IDLE_MS - 1, IDLE_MS, &quiet).is_empty());
    assert_eq!(tracker.due(start + IDLE_MS, IDLE_MS, &quiet), ["quiet"]);
}

#[test]
fn output_moves_the_deadline_without_a_wakeup() {
    let start = 100 * IDLE_MS;
    let mut tracker = FreeingTracker::default();
    assert!(tracker.due(start, IDLE_MS, &[view("t", false, 0, None)]).is_empty());
    let printed = start + 10 * MIN_MS;
    // The pass at the first deadline reads the newer output and sleeps until its deadline.
    assert!(
        tracker.due(start + IDLE_MS, IDLE_MS, &[view("t", false, 0, Some(printed))]).is_empty()
    );
    assert_eq!(tracker.next_deadline_ms(IDLE_MS), Some(printed + IDLE_MS));
    assert_eq!(
        tracker.due(printed + IDLE_MS, IDLE_MS, &[view("t", false, 0, Some(printed))]),
        ["t"]
    );
}

#[test]
fn an_attached_terminal_is_never_due_and_its_detach_restarts_the_clock() {
    let start = 100 * IDLE_MS;
    let mut tracker = FreeingTracker::default();
    assert!(tracker.due(start, IDLE_MS, &[view("t", true, 1, None)]).is_empty());
    assert_eq!(tracker.next_deadline_ms(IDLE_MS), None, "an attached terminal adds no wakeup");
    assert!(tracker.due(start + 5 * IDLE_MS, IDLE_MS, &[view("t", true, 1, None)]).is_empty());
    // The detach wakes the pass: the clock starts there.
    let detached = start + 6 * IDLE_MS;
    assert!(tracker.due(detached, IDLE_MS, &[view("t", false, 1, None)]).is_empty());
    assert_eq!(tracker.next_deadline_ms(IDLE_MS), Some(detached + IDLE_MS));
    assert_eq!(tracker.due(detached + IDLE_MS, IDLE_MS, &[view("t", false, 1, None)]), ["t"]);
}

#[test]
fn an_attach_between_two_passes_counts_as_use() {
    let start = 100 * IDLE_MS;
    let mut tracker = FreeingTracker::default();
    assert!(tracker.due(start, IDLE_MS, &[view("t", false, 1, None)]).is_empty());
    let later = start + IDLE_MS;
    assert!(
        tracker.due(later, IDLE_MS, &[view("t", false, 2, None)]).is_empty(),
        "a newer attach epoch: someone looked at it since the last pass"
    );
    assert_eq!(tracker.due(later + IDLE_MS, IDLE_MS, &[view("t", false, 2, None)]), ["t"]);
}

#[test]
fn a_refused_terminal_waits_a_full_period_and_a_gone_one_is_forgotten() {
    let start = 100 * IDLE_MS;
    let mut tracker = FreeingTracker::default();
    assert!(tracker.due(start, IDLE_MS, &[view("busy", false, 0, None)]).is_empty());
    let due_at = start + IDLE_MS;
    assert_eq!(tracker.due(due_at, IDLE_MS, &[view("busy", false, 0, None)]), ["busy"]);
    tracker.restart("busy", due_at);
    assert_eq!(tracker.next_deadline_ms(IDLE_MS), Some(due_at + IDLE_MS));
    assert!(tracker.due(due_at + 1, IDLE_MS, &[]).is_empty());
    assert!(tracker.is_empty());
    assert_eq!(tracker.next_deadline_ms(IDLE_MS), None, "nothing tracked: no wakeup");
}
