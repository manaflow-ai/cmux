//! A session that completed its handshake but carries no data back.
//!
//! Measured on Freestyle (transport/fs RESULTS-round2 test 3): on a tunnel
//! that sat unused for more than about five minutes, the first session's
//! handshake completes but the gateway drops its data. WireGuard starts a
//! new handshake only after KEEPALIVE + REKEY_TIMEOUT (15 s) of silence, so
//! the first connection takes about 15 s; a second handshake fixes it at
//! once.
//!
//! The watchdog arms when the session sends data and no authenticated data
//! has come back since the session began. If nothing comes back within
//! max(1 s, 2 x smoothed RTT), it asks for one forced handshake. It is then
//! spent until authenticated data arrives again, so a peer that is dead, or
//! that answers handshakes but never data, gets one forced handshake and then
//! only WireGuard's normal backoff: never a handshake storm.
//!
//! The watchdog also keeps the packets the silent session sent (up to
//! [`MAX_REPLAY`]). When the forced handshake completes they leave again at
//! once on the new session, so the connection does not wait for TCP's next
//! retransmission (a SYN backs off 1, 3, 7, 15 s). TCP drops duplicates.

use std::time::Duration;

use tokio::time::Instant;

/// The least time to wait for data back before forcing a handshake.
pub(crate) const MIN_WAIT: Duration = Duration::from_secs(1);
/// Packets of a silent session kept for the replay.
const MAX_REPLAY: usize = 64;

#[derive(Debug, Default)]
pub(crate) struct Watchdog {
    /// When the first unanswered data of this session left.
    armed: Option<Instant>,
    /// A forced handshake was asked for, and no data has come back since.
    spent: bool,
    /// Authenticated data arrived since the current session began.
    answered: bool,
    /// What the silent session sent, for the replay.
    unanswered: Vec<Vec<u8>>,
}

impl Watchdog {
    /// A handshake completed: a new session begins and must prove itself.
    /// Returns the packets to send again when the watchdog forced it.
    pub(crate) fn on_new_session(&mut self) -> Vec<Vec<u8>> {
        self.answered = false;
        self.armed = None;
        let unanswered = std::mem::take(&mut self.unanswered);
        if self.spent { unanswered } else { Vec::new() }
    }

    /// Authenticated data (a data message, keepalives included) arrived.
    pub(crate) fn on_inbound_data(&mut self) {
        self.answered = true;
        self.armed = None;
        self.spent = false;
        self.unanswered.clear();
    }

    /// The session sent a data packet (a plaintext IP packet).
    pub(crate) fn on_data_sent(&mut self, now: Instant, packet: &[u8]) {
        if self.answered || self.spent {
            return;
        }
        if self.armed.is_none() {
            self.armed = Some(now);
        }
        if self.unanswered.len() < MAX_REPLAY {
            self.unanswered.push(packet.to_vec());
        }
    }

    fn wait(srtt: Option<Duration>) -> Duration {
        srtt.map_or(MIN_WAIT, |srtt| (srtt * 2).max(MIN_WAIT))
    }

    /// When the watchdog fires, if it is armed.
    pub(crate) fn deadline(&self, srtt: Option<Duration>) -> Option<Instant> {
        self.armed.map(|armed| armed + Self::wait(srtt))
    }

    /// Whether to force a handshake now. True at most once until data
    /// comes back.
    pub(crate) fn fire(&mut self, now: Instant, srtt: Option<Duration>) -> bool {
        if self.deadline(srtt).is_none_or(|deadline| now < deadline) {
            return false;
        }
        self.armed = None;
        self.spent = true;
        true
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn fires_once_after_a_second_of_silence() {
        let start = Instant::now();
        let mut dog = Watchdog::default();
        dog.on_data_sent(start, b"syn");
        assert!(!dog.fire(start + Duration::from_millis(999), None));
        assert!(dog.fire(start + MIN_WAIT, None));
        // The forced handshake completes: the silent session's packets
        // leave again. The new session is silent too.
        assert_eq!(dog.on_new_session(), vec![b"syn".to_vec()]);
        dog.on_data_sent(start + Duration::from_secs(2), b"syn");
        assert_eq!(dog.deadline(None), None, "spent until data comes back");
        assert!(!dog.fire(start + Duration::from_secs(60), None));
    }

    #[test]
    fn data_back_disarms_and_rearms_the_next_session() {
        let start = Instant::now();
        let mut dog = Watchdog::default();
        dog.on_data_sent(start, b"syn");
        dog.on_inbound_data();
        assert_eq!(dog.deadline(None), None);
        dog.on_data_sent(start + Duration::from_secs(5), b"data");
        assert_eq!(dog.deadline(None), None, "an answered session never arms");
        assert!(dog.on_new_session().is_empty(), "a rekey replays nothing");
        dog.on_data_sent(start + Duration::from_secs(120), b"data");
        assert_eq!(dog.deadline(None), Some(start + Duration::from_secs(121)));
    }

    #[test]
    fn a_slow_path_waits_twice_its_round_trip() {
        let start = Instant::now();
        let mut dog = Watchdog::default();
        dog.on_data_sent(start, b"syn");
        let srtt = Some(Duration::from_millis(800));
        assert_eq!(dog.deadline(srtt), Some(start + Duration::from_millis(1600)));
        assert!(!dog.fire(start + MIN_WAIT, srtt));
    }
}
