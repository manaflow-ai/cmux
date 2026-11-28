//! A subagent an outage failed waits it out (`subagent_retry.rs`), as a cut turn does.

/// How long after a subagent's failure an outage's attempts go on (6 h). A capacity outage (the
/// provider's 529, the SR2 gateway's 503 "no non-exhausted accounts") or a refused connection
/// ends by itself, so its subagent waits it out as a cut turn does
/// (`auto_resume::waits_it_out`): one attempt every `auto_resume::capacity_wait` (backing off to
/// 5 min, jittered per chat and attempt), so it never hammers the upstream. Past this it is given
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
    session_id: &str,
    now: u64,
) -> Option<u64> {
    if waits_out(failure, delays) {
        (now.saturating_sub(failure.at) < OUTAGE_HORIZON_MS)
            .then(|| super::super::auto_resume::capacity_wait(attempts, delays, session_id))
    } else {
        delays.get(attempts).map(|&delay| super::super::auto_resume::staggered(delay, session_id))
    }
}

#[cfg(test)]
#[path = "subagent_retry_outage_tests.rs"]
mod tests;
