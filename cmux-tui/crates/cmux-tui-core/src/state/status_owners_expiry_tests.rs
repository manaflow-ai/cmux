use std::time::Duration;

use super::ExpiryPass;

const NOW: u64 = 1_800_000_000_000;

/// The thread's waits over `passes` passes in which one daemon's clear
/// at `NOW` succeeds and its earliest deadline left is `deadline`.
fn waits(deadline: u64, passes: usize) -> Vec<Duration> {
    let mut failures = 0;
    (0..passes)
        .map(|_| {
            let mut pass = ExpiryPass::default();
            assert!(!pass.add(NOW, true, Some(Some(deadline))));
            pass.wait(&mut failures, NOW).expect("a deadline is left")
        })
        .collect()
}

/// A clear that succeeds but leaves a deadline it should have removed
/// (due at or before the time it cleared up to) will leave it on every
/// pass. Before, the thread slept 1 ms and tried again, about 1000
/// wakeups a second for as long as the row stayed; now that counts as a
/// failure and waits the failure's growing delay.
#[test]
fn a_deadline_the_clear_left_behind_waits_longer_each_pass() {
    let waits = waits(NOW - 5, 4);
    assert!(waits[0] >= Duration::from_secs(1), "{waits:?}");
    assert!(waits.windows(2).all(|pair| pair[1] > pair[0]), "{waits:?}");
}

/// A deadline that came due after the time the clear used is a real
/// one: the next pass clears it at once, and the pass is no failure.
#[test]
fn a_deadline_due_after_the_clear_runs_the_next_pass_at_once() {
    let mut failures = 0;
    let mut pass = ExpiryPass::default();
    assert!(!pass.add(NOW - 3, true, Some(Some(NOW - 1))));
    assert_eq!(pass.wait(&mut failures, NOW), Some(Duration::from_millis(1)));
    assert_eq!(failures, 0);
}

/// A future deadline is waited for exactly; no deadline waits for a new one.
#[test]
fn a_future_deadline_is_waited_for_and_none_waits_for_an_event() {
    assert_eq!(waits(NOW + 2_500, 2), vec![Duration::from_millis(2_500); 2]);
    let mut failures = 0;
    let mut pass = ExpiryPass::default();
    assert!(pass.add(NOW, true, Some(None)));
    assert_eq!(pass.wait(&mut failures, NOW), None);
}
