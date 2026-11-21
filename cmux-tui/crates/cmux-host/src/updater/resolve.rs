//! How the new `cmux host run` waits on a pending update ([`resolve_with`]):
//! the health deadline, which starts at the session host's replacement when
//! the supervisor deferred it (`crate::machine::ReplaceWhy`), and the waits
//! a rollback makes for attached carrier sessions.

use std::sync::mpsc::Receiver;
use std::time::Duration;

use super::role::{BUSY_RETRY, HEALTH_TIMEOUT, Msg, log, wait};

/// Before a rollback's restart: waits while `carrier` says carrier sessions
/// hold it (the flip's own rule, `carrier_busy`, with its
/// [`super::carrier::CARRIER_MAX_HOLD`] bound), looking again every [`BUSY_RETRY`] through
/// `wait`. False when `wait` says the waiter stopped.
pub(super) fn rollback_waits(
    carrier: &mut impl FnMut() -> Option<String>,
    mut wait: impl FnMut(Duration) -> bool,
) -> bool {
    let mut logged = false;
    while let Some(why) = carrier() {
        if !logged {
            log(&format!("the rollback waits: {why}"));
            logged = true;
        }
        if !wait(BUSY_RETRY) {
            return false;
        }
    }
    true
}

/// The health timeout's rollback waits for carrier sessions, waking on the
/// role's messages; false when the role stops (the guard still covers it).
pub(super) fn timeout_rollback_waits(
    carrier: &mut impl FnMut() -> Option<String>,
    rx: &Receiver<Msg>,
) -> bool {
    rollback_waits(carrier, |d| wait(rx, d))
}

/// The guard's rollback (`cmux host update guard`, a oneshot unit with no
/// start timeout) waits for carrier sessions by sleeping; `sleep` is
/// injected for the tests.
pub(super) fn guard_rollback_waits(
    carrier: &mut impl FnMut() -> Option<String>,
    mut sleep: impl FnMut(Duration),
) {
    rollback_waits(carrier, |d| {
        sleep(d);
        true
    });
}

/// How long [`resolve_with`] lets a deferred session host replacement hold
/// back the health deadline: the supervisor replaces it within
/// [`crate::machine::HOST_MAX_DEFER_MS`], so a mark older than that and a
/// health timeout more is not one it still keeps, and the deadline runs.
pub(super) const DEFER_EXCUSE: Duration =
    Duration::from_millis(crate::machine::HOST_MAX_DEFER_MS).saturating_add(HEALTH_TIMEOUT);

/// What [`resolve_with`] found.
#[derive(Debug, PartialEq, Eq)]
pub(super) enum Resolved {
    /// The new build serves.
    Healthy,
    /// It did not within [`HEALTH_TIMEOUT`] of its session host's replacement.
    TimedOut,
    /// The role stopped meanwhile.
    Stopped,
}

/// The guard steps [`resolve_with`] takes around a deferred replacement.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) enum GuardStep {
    /// The new build runs and waits on its session host: the previous
    /// build's guard, which knows no deferral, must not roll it back.
    Disarm,
    /// The session host was replaced: the guard covers the new one again.
    Rearm,
}

/// The health wait of [`resolve`], pure over its seams: `healthy` (the new
/// build serves), `deferred` (the supervisor's [`crate::config::HOST_DEFERRED_FILE`]:
/// the old-build session host still serves a person's session and is not
/// replaced yet), `elapsed` (a monotonic clock from the role's start), `wait`
/// (false when the role stops) and `guard`.
///
/// The [`HEALTH_TIMEOUT`] runs from the replacement, not from the role's
/// start: while the replacement is deferred, the deadline keeps moving (up
/// to [`DEFER_EXCUSE`]), and when the mark goes the deadline is that moment
/// plus the timeout. Without a deferral it is the role's start plus the
/// timeout, as before.
pub(super) fn resolve_with(
    mut healthy: impl FnMut() -> bool,
    mut deferred: impl FnMut() -> bool,
    mut elapsed: impl FnMut() -> Duration,
    mut wait: impl FnMut(Duration) -> bool,
    mut guard: impl FnMut(GuardStep),
) -> Resolved {
    let mut deadline = HEALTH_TIMEOUT;
    let mut deferred_since: Option<Duration> = None;
    let mut past_excuse = false;
    loop {
        if healthy() {
            return Resolved::Healthy;
        }
        let now = elapsed();
        if deferred() {
            let since = *deferred_since.get_or_insert_with(|| {
                log("the old-build session host still serves a session: the health deadline starts at its replacement");
                guard(GuardStep::Disarm);
                now
            });
            if now.saturating_sub(since) <= DEFER_EXCUSE {
                deadline = now + HEALTH_TIMEOUT;
            } else if !past_excuse {
                past_excuse = true;
                log(&format!(
                    "the session host's replacement is still deferred after {} h: the health deadline runs",
                    DEFER_EXCUSE.as_secs() / 3600
                ));
            }
        } else if deferred_since.take().is_some() {
            log("the old-build session host was replaced: the health deadline starts now");
            deadline = now + HEALTH_TIMEOUT;
            guard(GuardStep::Rearm);
        }
        if now >= deadline {
            return Resolved::TimedOut;
        }
        if !wait(Duration::from_secs(5)) {
            return Resolved::Stopped;
        }
    }
}
