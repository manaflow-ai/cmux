use super::{TICK, timer_due};
use std::time::Duration;

#[test]
fn a_wake_burst_cannot_starve_or_replay_periodic_samples() {
    let start = tokio::time::Instant::now();
    let mut next = start + TICK;
    let mut samples = 0;
    for millis in (0..1000).step_by(10) {
        if timer_due(&mut next, start + Duration::from_millis(millis)) {
            samples += 1;
        }
    }
    assert_eq!(samples, 0, "the first deadline has not arrived");
    assert!(timer_due(&mut next, start + TICK));
    assert!(!timer_due(&mut next, start + TICK + Duration::from_millis(1)));
    assert!(timer_due(&mut next, start + Duration::from_secs(4)));
    assert!(!timer_due(&mut next, start + Duration::from_secs(4)));
}
