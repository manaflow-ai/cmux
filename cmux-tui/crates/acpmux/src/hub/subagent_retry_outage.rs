//! A subagent an outage failed waits it out (`subagent_retry.rs`), as a cut turn does.

/// How long after a subagent's failure an outage's attempts go on (6 h). A capacity outage (the
/// provider's 529, the SR2 gateway's 429/503 "no non-exhausted accounts"), a rate hold or a refused connection
/// ends by itself, so its subagent waits it out as a cut turn does
/// (`auto_resume::waits_it_out`): one attempt every `auto_resume::capacity_wait` (backing off to
/// 5 min, jittered per helper and attempt), honoring a longer Retry-After. Past this it is given
/// up (`exhausted`); a person's retry still works. On one machine, 2026-11-24, the four
/// configured attempts (about 26 min) ran out inside 60-99 minute outages, and 47 helpers sat
/// failed for 61-133 minutes until their coordinator sent "continue" by hand.
pub(in crate::hub) const OUTAGE_HORIZON_MS: u64 = 6 * 60 * 60 * 1000;

/// Whether `failure`'s retries wait out an outage instead of running out with the configured
/// attempts: what a cut turn's continuation does for the same error.
pub(super) fn waits_out(failure: &super::Failure, delays: &[u64]) -> bool {
    use crate::protocol::session::RetryReason;
    let reason = match failure.reason {
        "capacity" => RetryReason::Capacity,
        "rate_limit" => RetryReason::RateLimit,
        "transport" => RetryReason::Transport,
        _ => return false,
    };
    super::super::auto_resume::waits_it_out(reason, &failure.error, delays)
}

/// The wait before attempt `attempts` (from 0) at `failure`, at `now` (Unix ms), or None once
/// the automatic attempts are used up: an outage's at [`OUTAGE_HORIZON_MS`] after the failure,
/// any other error's after the configured waits. Off (`[]`) stays off.
pub(super) fn attempt_delay(
    failure: &super::Failure,
    attempts: usize,
    delays: &[u64],
    helper_id: &str,
    now: u64,
) -> Option<u64> {
    if waits_out(failure, delays) {
        (now.saturating_sub(failure.at) < OUTAGE_HORIZON_MS).then(|| {
            let backoff = super::super::auto_resume::capacity_wait(attempts, delays, helper_id);
            // The upstream's deadline is a minimum, even beyond our backoff cap. Measure it
            // from this failure, not each scheduling attempt, and stagger each helper so a
            // pool returning at once does not receive another synchronized storm.
            let reset =
                super::super::auto_resume::reset_hint::reset_at(&failure.error, None, failure.at);
            let remaining = reset.unwrap_or(now).saturating_sub(now);
            backoff.max(super::super::auto_resume::staggered(
                remaining,
                &format!("{helper_id}#{attempts}"),
            ))
        })
    } else {
        delays.get(attempts).map(|&delay| super::super::auto_resume::staggered(delay, helper_id))
    }
}

#[cfg(test)]
mod tests {
    use super::super::Failure;
    use super::*;

    #[test]
    fn a_subagent_rate_hold_honors_retry_after_and_staggers_the_storm() {
        let failure = Failure {
            agent_id: "a1".into(),
            error: "API Error: 429 rate_limit_error; Retry-After: 600".into(),
            reason: "rate_limit",
            at: 1_000,
            idle: false,
            wait: None,
        };
        let waits: std::collections::HashSet<_> = (0..12)
            .map(|i| {
                let delay = attempt_delay(&failure, 9, &[10], &format!("s/helper-{i}"), 1_000)
                    .expect("a rate hold must survive the configured retry count");
                assert!((600_000..=720_000).contains(&delay), "{delay}");
                delay
            })
            .collect();
        assert!(waits.len() > 1, "helpers must not all hit the pool together");
        assert!(attempt_delay(&failure, 9, &[10], "s/helper-1", 601_000).unwrap() < 600_000);
        assert!(attempt_delay(&failure, 0, &[], "s/helper-1", 1_000).is_none());
    }

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
}
