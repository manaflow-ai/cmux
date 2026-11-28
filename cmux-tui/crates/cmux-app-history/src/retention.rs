//! Recently closed retention (`ClosedHistoryRetention.swift`): for one
//! connected daemon, whether to send `closed.delete` now and when to check
//! again. The app computes the prune itself (`ClosedRetention.prune`) and
//! owns the timers and the clock.

use serde::{Deserialize, Serialize};

/// At most one delete a minute per machine.
pub const INTERVAL_MS: u64 = 60_000;
/// The wait after a failed delete, and while a full mirror cannot see its oldest groups.
pub const RETRY_MS: u64 = 3_600_000;
const DAY_MS: u64 = 86_400_000;

/// One machine's facts at a check.
#[derive(Debug, Clone, Copy, Default, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Check {
    /// The mirror is over a limit (`ClosedRetention.prune` gave a prune).
    #[serde(default)]
    pub over_limit: bool,
    #[serde(default)]
    pub max_age_days: u64,
    /// The oldest group's close, nil with no groups.
    #[serde(default)]
    pub oldest_ms: Option<u64>,
    #[serde(default)]
    pub now_ms: u64,
    /// The groups in the mirror, and how many it holds at most (`SessionStateMirror.closedLimit`).
    #[serde(default)]
    pub count: usize,
    #[serde(default)]
    pub closed_limit: usize,
    /// Since this machine's last delete; nil when none was sent.
    #[serde(default)]
    pub since_last_prune_ms: Option<u64>,
}

/// What to do: send the delete (and record it as the last), check again after a delay, or cancel the deadline.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Decision {
    pub prune: bool,
    pub recheck_after_ms: Option<u64>,
    pub cancel_deadline: bool,
}

const fn recheck(after: u64) -> Decision {
    Decision { prune: false, recheck_after_ms: Some(after), cancel_deadline: false }
}

/// The decision for one machine at one check.
pub fn decide(check: &Check) -> Decision {
    if !check.over_limit {
        // Within the limits: check again when the oldest group gets too old.
        return match check.oldest_ms {
            Some(oldest) if check.max_age_days > 0 => {
                let due = oldest.wrapping_add(check.max_age_days.wrapping_mul(DAY_MS));
                let wait = due.saturating_sub(check.now_ms).wrapping_add(1);
                recheck(wait.min(i64::MAX as u64))
            }
            _ => Decision { prune: false, recheck_after_ms: None, cancel_deadline: true },
        };
    }
    if let Some(since) = check.since_last_prune_ms.filter(|since| *since < INTERVAL_MS) {
        return recheck(INTERVAL_MS - since);
    }
    if check.max_age_days > 0 && check.count >= check.closed_limit {
        Decision { prune: true, recheck_after_ms: Some(RETRY_MS), cancel_deadline: false }
    } else {
        Decision { prune: true, recheck_after_ms: None, cancel_deadline: true }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn base() -> Check {
        Check { now_ms: 10 * DAY_MS, closed_limit: 500, ..Check::default() }
    }

    #[test]
    fn within_limits_waits_for_the_oldest_to_age_out() {
        let check = Check { max_age_days: 7, oldest_ms: Some(9 * DAY_MS), ..base() };
        assert_eq!(decide(&check), recheck(6 * DAY_MS + 1));
        // Already due (the prune saw nothing yet): one millisecond.
        let due = Check { max_age_days: 1, oldest_ms: Some(DAY_MS), ..base() };
        assert_eq!(decide(&due), recheck(1));
    }

    #[test]
    fn within_limits_without_an_age_or_groups_cancels() {
        let cancel = Decision { prune: false, recheck_after_ms: None, cancel_deadline: true };
        assert_eq!(decide(&Check { oldest_ms: Some(0), ..base() }), cancel);
        assert_eq!(decide(&Check { max_age_days: 7, ..base() }), cancel);
    }

    #[test]
    fn a_far_due_is_clamped() {
        let check = Check { max_age_days: 1, oldest_ms: Some(u64::MAX / 2), now_ms: 0, ..base() };
        assert_eq!(decide(&check).recheck_after_ms, Some(i64::MAX as u64));
    }

    #[test]
    fn over_limit_waits_out_the_minute() {
        let check = Check { over_limit: true, since_last_prune_ms: Some(15_000), ..base() };
        assert_eq!(decide(&check), recheck(45_000));
    }

    #[test]
    fn over_limit_prunes_and_rechecks_hourly_while_full() {
        let full = Check {
            over_limit: true,
            max_age_days: 7,
            count: 500,
            since_last_prune_ms: Some(60_000),
            ..base()
        };
        assert_eq!(
            decide(&full),
            Decision { prune: true, recheck_after_ms: Some(RETRY_MS), cancel_deadline: false }
        );
        let roomy = Check { count: 10, ..full };
        assert_eq!(
            decide(&roomy),
            Decision { prune: true, recheck_after_ms: None, cancel_deadline: true }
        );
        let no_age = Check { max_age_days: 0, ..full };
        assert_eq!(
            decide(&no_age),
            Decision { prune: true, recheck_after_ms: None, cancel_deadline: true }
        );
        let first = Check { since_last_prune_ms: None, ..full };
        assert!(decide(&first).prune);
    }
}
