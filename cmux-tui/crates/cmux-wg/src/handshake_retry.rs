//! A handshake initiation lost while data waits for the session.
//!
//! Measured on a real tunnel: after a hub was paused 190 s (past the 180 s
//! session lifetime) the client had no session, the initiation that would
//! have made one was lost, and boringtun sent nothing again until its 5 s
//! REKEY_TIMEOUT retry, so the next connection took 5.15 s. Nothing on the
//! client changed, so no rebind or refresh restarted it, and the watchdog
//! (`crate::watchdog`) arms only on a session that exists.
//!
//! While data waits for a session, this sends the initiation again on its
//! own schedule: max(250 ms, 2 x smoothed RTT) after the last initiation
//! left, doubling each time, at most [`MAX_RESENDS`] times and only while
//! the wait is shorter than boringtun's own retry, which then takes over.
//! A handshake attempt gets these resends once: a dead peer sees at most
//! four more initiations per boringtun attempt (90 s), never a storm. With
//! no data waiting there is no deadline, so an idle tunnel never wakes for
//! it.
//!
//! The responder accepts each resend: every initiation carries a fresh
//! TAI64N timestamp, boringtun rate-limits initiations only above 10 a
//! second, and the initiator keeps the previous handshake state, so an
//! answer to the one before the last still completes.

use std::time::Duration;

use tokio::time::Instant;

/// The least wait for an answer before sending the initiation again.
pub(crate) const MIN_WAIT: Duration = Duration::from_millis(250);
/// boringtun's REKEY_TIMEOUT: its own retry, which needs no help past it.
const REKEY_TIMEOUT: Duration = Duration::from_secs(5);
/// Resends per handshake attempt: 0.25, 0.5, 1 and 2 s waits.
pub(crate) const MAX_RESENDS: u32 = 4;

#[derive(Debug, Default)]
pub(crate) struct HandshakeRetry {
    /// When the last initiation left, by anyone (this, boringtun's timers,
    /// a reassertion or the watchdog).
    last_initiation: Option<Instant>,
    /// When data began waiting for the session, while it waits.
    waiting: Option<Instant>,
    /// Resends this handshake attempt has had.
    resends: u32,
}

impl HandshakeRetry {
    /// An initiation left. `fresh`: it began a new handshake attempt, which
    /// gets its own resends.
    pub(crate) fn on_initiation(&mut self, now: Instant, fresh: bool) {
        self.last_initiation = Some(now);
        if fresh {
            self.resends = 0;
        }
    }

    /// A session exists: nothing waits for a handshake.
    pub(crate) fn on_session(&mut self) {
        self.waiting = None;
        self.resends = 0;
    }

    /// Whether data waits for the session, as of `now`.
    pub(crate) fn set_waiting(&mut self, now: Instant, waiting: bool) {
        match (waiting, self.waiting) {
            (true, None) => self.waiting = Some(now),
            (false, _) => self.waiting = None,
            (true, Some(_)) => {}
        }
    }

    fn wait(&self, srtt: Option<Duration>) -> Duration {
        let base = srtt.map_or(MIN_WAIT, |srtt| (srtt * 2).max(MIN_WAIT));
        base * 2u32.pow(self.resends)
    }

    /// When the next resend is due, while data waits and resends are left.
    pub(crate) fn deadline(&self, srtt: Option<Duration>) -> Option<Instant> {
        let waiting = self.waiting?;
        let wait = self.wait(srtt);
        if self.resends >= MAX_RESENDS || wait >= REKEY_TIMEOUT {
            return None;
        }
        // An initiation sent before the data began waiting (a keepalive's,
        // during the outage) had its time: resend at once if its answer is
        // already overdue, else when it is.
        let anchor = self.last_initiation.unwrap_or(waiting);
        Some(anchor + wait)
    }

    /// Whether to send the initiation again now. The caller sends it and
    /// reports it with `on_initiation(now, false)`.
    pub(crate) fn fire(&mut self, now: Instant, srtt: Option<Duration>) -> bool {
        if self.deadline(srtt).is_none_or(|deadline| now < deadline) {
            return false;
        }
        self.resends += 1;
        true
    }
}

#[cfg(test)]
#[path = "handshake_retry_tests.rs"]
mod tests;
