use super::*;

/// #54378: an idle sweep that panicked ended the hand's sweeper for good. Supervised, the
/// sweeper starts again and its next sweep runs.
#[tokio::test]
async fn an_idle_sweep_that_panics_starts_the_sweeper_again() {
    crate::supervise::arm_panic("hand idle sweep", "");
    let fatal = crate::supervise::Fatal::default();
    let sweeper = idle_sweeper(Agents::default(), Duration::from_millis(20), &fatal);
    let within = Duration::from_secs(10);
    let again = crate::supervise::passed("hand idle sweep", "", 3, within).await;
    sweeper.abort();
    assert!(again, "the sweeper never swept again after a sweep panicked");
}
