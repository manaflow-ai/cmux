//! The link model, offline: when each write reaches the phone through a `cmux-fault` link
//! profile, computed ahead of time instead of by a live proxy. It is the per-direction model
//! `cmux_fault::shaper` documents and runs (daemon to phone, `down_kbit`):
//!
//! - bytes leave in 1460-byte segments, each after the one before it has serialized
//!   (`size * 8 / down_kbit`; 0 is unlimited), so a burst queues behind itself;
//! - each segment then takes `rtt_ms / 2` plus a seeded draw in `0..=jitter_ms`;
//! - a segment is lost with `loss_percent` and arrives one RTO later
//!   (`max(rto_min_ms, 2 * rtt_ms)`, the shaper's), doubling while the retransmission is lost too;
//! - TCP delivers in order, so no segment arrives before the one ahead of it (head of line).
//!
//! A write is delivered when its last segment arrives. A profile's `disruption` (blackout,
//! address change) is a live event the harness triggers, not part of this schedule.

use cmux_fault::Rng;
use cmux_fault::shaper::{LinkProfile, SEGMENT};

/// Linux's `TCP_RTO_MAX`, in microseconds (the shaper's cap).
const RTO_MAX_US: u64 = 120_000_000;

/// One direction of one link, in microseconds since the schedule's start.
pub struct Link {
    profile: Option<LinkProfile>,
    rng: Rng,
    free_at_us: u64,
    floor_us: u64,
}

impl Link {
    pub fn new(profile: Option<LinkProfile>, rng: Rng) -> Self {
        Self { profile, rng, free_at_us: 0, floor_us: 0 }
    }

    /// When `bytes` written at `sent_us` are all delivered. Calls come in send order; the result
    /// never goes backwards. With no profile a write arrives when it is sent.
    pub fn deliver(&mut self, sent_us: u64, bytes: usize) -> u64 {
        let Some(profile) = &self.profile else {
            self.floor_us = self.floor_us.max(sent_us);
            return self.floor_us;
        };
        let one_way_us = profile.rtt_ms * 500;
        let rto_us = profile.rto_min_ms.max(2 * profile.rtt_ms) * 1000;
        let mut left = bytes;
        loop {
            let size = left.min(SEGMENT);
            left -= size;
            let start = self.free_at_us.max(sent_us);
            let serialized = if profile.down_kbit == 0 {
                0
            } else {
                // bits * 1000 / kbit = microseconds
                (size as u64 * 8 * 1000).div_ceil(profile.down_kbit)
            };
            self.free_at_us = start + serialized;
            let jitter_us =
                if profile.jitter_ms > 0 { self.rng.range(0, profile.jitter_ms) * 1000 } else { 0 };
            let mut arrive = self.free_at_us + one_way_us + jitter_us;
            let mut rto = rto_us;
            while lost(&mut self.rng, profile.loss_percent) {
                arrive += rto;
                rto = (rto * 2).min(RTO_MAX_US);
            }
            self.floor_us = self.floor_us.max(arrive);
            if left == 0 {
                return self.floor_us;
            }
        }
    }
}

/// The shaper's loss draw: 53 random bits as a fraction in [0, 1).
fn lost(rng: &mut Rng, percent: f64) -> bool {
    if percent <= 0.0 {
        return false;
    }
    let draw = (rng.next_u64() >> 11) as f64 / (1_u64 << 53) as f64;
    draw * 100.0 < percent
}

#[cfg(test)]
mod tests {
    use super::*;

    fn profile(down_kbit: u64, rtt_ms: u64, jitter_ms: u64, loss_percent: f64) -> LinkProfile {
        LinkProfile {
            name: "test".to_owned(),
            version: 1,
            up_kbit: down_kbit,
            down_kbit,
            rtt_ms,
            jitter_ms,
            loss_percent,
            rto_min_ms: 200,
            disruption: None,
            source: String::new(),
        }
    }

    #[test]
    fn no_link_delivers_on_send() {
        let mut link = Link::new(None, Rng::new(1));
        assert_eq!(link.deliver(5_000, 100_000), 5_000);
    }

    #[test]
    fn rate_and_delay_hold() {
        // 256 kbit/s: one 1460-byte segment serializes in 45.625 ms.
        let mut link = Link::new(Some(profile(256, 100, 0, 0.0)), Rng::new(1));
        let first = link.deliver(0, SEGMENT);
        assert_eq!(first, 45_625 + 50_000);
        // A megabyte sent at once cannot arrive faster than the rate.
        let done = link.deliver(0, 1_000_000);
        let min_us = (1_000_000 + SEGMENT as u64) * 8 * 1000 / 256;
        assert!(done >= min_us, "{done} < {min_us}");
    }

    #[test]
    fn loss_holds_a_segment_one_rto() {
        // 99.9% loss on the first draw is a near certainty: the RTO is max(200, 2 * 100) ms.
        let mut link = Link::new(Some(profile(0, 100, 0, 99.9)), Rng::new(3));
        assert!(link.deliver(0, 10) >= 50_000 + 200_000);
    }
}
