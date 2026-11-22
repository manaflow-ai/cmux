//! Bounded retry rules, pure: the session host restart backoff and the
//! clock-set timer re-arm. Both count attempts, never wall time, because
//! the guest's clocks jump by the snapshot's age on resume.

/// Restart delay cap for a crash-looping session host.
pub const MAX_BACKOFF_MS: u64 = 30_000;
/// The first delayed restart.
pub const FIRST_BACKOFF_MS: u64 = 500;
/// Re-arm attempts before the clock-set timer gives up until the next wake.
pub const CLOCK_REARM_ATTEMPTS: u32 = 64;

/// Delay before restart number `fast_exits` (1-based count of consecutive
/// short-lived exits): the first restart is immediate, then 0.5 s doubling
/// to [`MAX_BACKOFF_MS`].
pub fn backoff_delay_ms(fast_exits: u32) -> u64 {
    match fast_exits {
        0 | 1 => 0,
        n => {
            let shift = (n - 2).min(16);
            FIRST_BACKOFF_MS.saturating_mul(1u64 << shift).min(MAX_BACKOFF_MS)
        }
    }
}

/// Why one re-arm attempt failed.
#[derive(Debug, PartialEq, Eq)]
pub enum ArmError {
    /// `ECANCELED`: the clock was set again between the read and the
    /// re-arm. Drain the timer and retry.
    Cancelled,
    /// Any other errno. Not retried.
    Other(i32),
}

#[derive(Debug, PartialEq, Eq)]
pub enum RearmOutcome {
    Armed {
        attempts: u32,
    },
    /// The caller disarms the timer (so it cannot stay readable) and tries
    /// again on the next wake of any kind. Never a crash.
    GaveUp {
        attempts: u32,
        last: ArmError,
    },
}

/// Re-arms the clock-set timer: `arm` until it succeeds, calling `drain`
/// after each `ECANCELED`, at most `max_attempts` times.
pub fn rearm_bounded(
    max_attempts: u32,
    mut arm: impl FnMut() -> Result<(), ArmError>,
    mut drain: impl FnMut(),
) -> RearmOutcome {
    let mut attempts = 0;
    let mut last = ArmError::Cancelled;
    while attempts < max_attempts.max(1) {
        attempts += 1;
        match arm() {
            Ok(()) => return RearmOutcome::Armed { attempts },
            Err(ArmError::Cancelled) => {
                drain();
                last = ArmError::Cancelled;
            }
            Err(other) => return RearmOutcome::GaveUp { attempts, last: other },
        }
    }
    RearmOutcome::GaveUp { attempts, last }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn backoff_starts_immediate_then_doubles_to_cap() {
        let delays: Vec<u64> = (1..=10).map(backoff_delay_ms).collect();
        assert_eq!(delays, [0, 500, 1_000, 2_000, 4_000, 8_000, 16_000, 30_000, 30_000, 30_000]);
        assert_eq!(backoff_delay_ms(u32::MAX), MAX_BACKOFF_MS);
    }

    #[test]
    fn rearm_retries_cancelled_and_drains() {
        let mut left = 3;
        let mut drained = 0;
        let outcome = rearm_bounded(
            10,
            || {
                if left == 0 {
                    Ok(())
                } else {
                    left -= 1;
                    Err(ArmError::Cancelled)
                }
            },
            || drained += 1,
        );
        assert_eq!(outcome, RearmOutcome::Armed { attempts: 4 });
        assert_eq!(drained, 3);
    }

    #[test]
    fn rearm_stops_on_other_errors() {
        let outcome = rearm_bounded(10, || Err(ArmError::Other(22)), || {});
        assert_eq!(outcome, RearmOutcome::GaveUp { attempts: 1, last: ArmError::Other(22) });
    }
}
