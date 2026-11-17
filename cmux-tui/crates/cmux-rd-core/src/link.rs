//! What counts as a link outage (design D12, piece 0), for both ends.
//!
//! A path that holds every datagram for a while and then delivers them in
//! one burst (Wi-Fi away from the access point) is not losing them. The host
//! sees the outage as silent feedback and must not cut its rate for it; the
//! viewer sees it as a silent link and must not give frames up or ask for
//! keyframes for it. Both ends use [`outage_threshold_us`], so they agree on
//! when a silence is an outage.

/// The shortest silence that counts as an outage.
pub const OUTAGE_MIN_US: u64 = 100_000;

/// The longest an outage holds anything back: past this the link is treated
/// as gone, not away.
pub const OUTAGE_FREEZE_MAX_US: u64 = 1_000_000;

/// How long a link may be silent before the silence is an outage:
/// max([`OUTAGE_MIN_US`], 4 round trips); [`OUTAGE_MIN_US`] while no round
/// trip is known.
pub fn outage_threshold_us(rtt_us: Option<u64>) -> u64 {
    rtt_us.map_or(OUTAGE_MIN_US, |rtt| rtt.saturating_mul(4).max(OUTAGE_MIN_US))
}

/// The viewer's half of the outage state: whether its link is up or away,
/// from the arrivals of datagrams of any kind, and how long it has been
/// away in total (the time loss timers stand still for).
#[derive(Debug, Clone, Default)]
pub struct ViewerLinkState {
    last_arrival_us: Option<u64>,
    /// Time spent away over every outage that ended.
    away_total_us: u64,
}

impl ViewerLinkState {
    /// A datagram of any kind arrived at `now_us`; an outage in progress ends.
    pub fn on_arrival(&mut self, now_us: u64, rtt_us: Option<u64>) {
        self.away_total_us = self.away_total_us_at(now_us, rtt_us);
        self.last_arrival_us = Some(self.last_arrival_us.map_or(now_us, |at| at.max(now_us)));
    }

    /// True while the link has been silent past [`outage_threshold_us`].
    pub fn is_away(&self, now_us: u64, rtt_us: Option<u64>) -> bool {
        self.away_from_us(rtt_us).is_some_and(|from| now_us > from)
    }

    /// When the current silence becomes an outage, if nothing arrives first.
    pub fn away_from_us(&self, rtt_us: Option<u64>) -> Option<u64> {
        self.last_arrival_us.map(|at| at.saturating_add(outage_threshold_us(rtt_us)))
    }

    /// Total time away at `now_us`, the current outage included. An outage
    /// counts from its silence's start: it is only known to be one once the
    /// threshold passes, but everything late in it was late for the outage.
    pub fn away_total_us_at(&self, now_us: u64, rtt_us: Option<u64>) -> u64 {
        let current = match (self.last_arrival_us, self.away_from_us(rtt_us)) {
            (Some(at), Some(from)) if now_us > from => now_us - at,
            _ => 0,
        };
        self.away_total_us.saturating_add(current)
    }

    /// When the last datagram arrived.
    pub fn last_arrival_us(&self) -> Option<u64> {
        self.last_arrival_us
    }

    /// Total time away over the outages that ended.
    pub fn away_total_us(&self) -> u64 {
        self.away_total_us
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_threshold_is_four_round_trips_at_least_100_ms() {
        assert_eq!(outage_threshold_us(None), 100_000);
        assert_eq!(outage_threshold_us(Some(10_000)), 100_000);
        assert_eq!(outage_threshold_us(Some(40_000)), 160_000);
    }

    #[test]
    fn a_silence_past_the_threshold_is_away_until_an_arrival() {
        let mut s = ViewerLinkState::default();
        s.on_arrival(0, None);
        assert!(!s.is_away(100_000, None));
        assert!(s.is_away(100_001, None));
        assert_eq!(s.away_total_us_at(100_000, None), 0, "not an outage yet");
        assert_eq!(s.away_total_us_at(300_000, None), 300_000, "counted from the silence start");
        s.on_arrival(300_000, None);
        assert!(!s.is_away(300_000, None));
        assert_eq!(s.away_total_us(), 300_000);
    }
}
