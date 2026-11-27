use super::super::Failure;
use super::*;

/// A subagent an outage failed waits it out past the configured attempts, with capped,
/// jittered waits, until the horizon; a dropped stream keeps its configured attempts. Before,
/// a 529 or "no non-exhausted accounts" outage longer than the four attempts (about 26 min)
/// left its helpers failed until their coordinator sent "continue" by hand.
#[test]
fn an_outage_is_waited_out_until_the_horizon() {
    let failure = |reason: &'static str, error: &str| Failure {
        agent_id: "a1".into(),
        error: error.into(),
        reason,
        at: 1_000,
        idle: false,
        wait: None,
    };
    let delays = crate::hub::auto_resume::DEFAULT_DELAYS_MS.to_vec();
    let max = crate::hub::auto_resume::CAPACITY_MAX_WAIT_MS;
    let overloaded = failure("capacity", "API Error: Repeated 529 Overloaded errors.");
    let pool = failure(
        "capacity",
        "API Error: 503 no non-exhausted claude accounts available; retry after 331s",
    );
    let refused = failure("transport", "connect ECONNREFUSED 127.0.0.1:8787");
    let dropped = failure("transport", "API Error: socket hang up (ECONNRESET)");
    for f in [&overloaded, &pool, &refused] {
        assert!(waits_out(f, &delays), "{}", f.error);
        for attempt in 0..40 {
            let wait = attempt_delay(f, attempt, &delays, "s", f.at + 60_000)
                .unwrap_or_else(|| panic!("{} gave up at attempt {attempt}", f.error));
            // Jittered up to a fifth later, never past the cap by more.
            assert!(wait > 0 && wait <= max + max / 5, "{wait}");
        }
        // Still waiting just inside the horizon; given up past it.
        assert!(attempt_delay(f, 80, &delays, "s", f.at + OUTAGE_HORIZON_MS - 1).is_some());
        assert!(attempt_delay(f, 80, &delays, "s", f.at + OUTAGE_HORIZON_MS).is_none());
        // Off stays off.
        assert!(attempt_delay(f, 0, &[], "s", f.at).is_none());
    }
    assert!(!waits_out(&dropped, &delays));
    let last = delays.len() - 1;
    assert!(attempt_delay(&dropped, last, &delays, "s", 2_000).is_some());
    assert!(attempt_delay(&dropped, delays.len(), &delays, "s", 2_000).is_none());
}
