//! The live link's ping, as a game shows it: a smoothed round trip of the link that carries
//! the chats (`rttMs`) and its tier (`quality`: good, slow, poor), in each
//! `_acpmux/peer_state_changed` (Leo, 2026-11-24: "we are probably not using as many gigabrain
//! optimizations and even regular brain optimizations and patterns that they have wrt ergo and
//! connectivity and sync and de-lagging"). A link that is up but slow was invisible until it
//! failed: the person could not tell a slow machine from a slow agent.
//!
//! - The estimate is TCP's and every netcode's smoothed round trip (RFC 6298):
//!   `srtt += (s - srtt) / 8`, from the WebSocket pongs the link already sends every
//!   `ping_every` (2 s). No new traffic.
//! - The tier moves to a worse one as soon as the smoothed round trip crosses its bound, and back
//!   to a better one only below [`RECOVER`] of it (hysteresis), so a link at the edge does not
//!   flap. Only a tier change is news (`peer_states.rs` `Key`); `rttMs` rides along, so a pong
//!   never sends a note by itself.
//! - A new link starts over: a path switch or a redial does not inherit the old path's ping.
//!
//! Constant memory and O(1) per pong.

use crate::protocol::peer_state::LinkQuality;

/// At or past this smoothed round trip a link is `slow`: typing echo and token streams lag
/// visibly (about 9 frames at 60 Hz).
pub const SLOW_MS: u32 = 150;
/// At or past this a link is `poor`: every action waits a noticeable beat.
pub const POOR_MS: u32 = 400;
/// A tier is left for a better one only once the smoothed round trip is below this share of
/// its bound (in percent).
pub const RECOVER: u32 = 80;

/// One link's smoothed round trip and tier.
#[derive(Debug, Default, Clone, Copy, PartialEq, Eq)]
pub struct RttEstimate {
    /// Smoothed round trip, microseconds; 0 before the first pong.
    srtt_us: u64,
    quality: Option<LinkQuality>,
}

impl RttEstimate {
    /// One pong after `rtt_us`. True when the tier changed (the note is news).
    pub fn sample(&mut self, rtt_us: u64) -> bool {
        let s = rtt_us.max(1);
        if self.srtt_us == 0 {
            self.srtt_us = s;
        } else {
            self.srtt_us = self.srtt_us - self.srtt_us / 8 + s / 8;
        }
        let next = tier(self.quality, self.srtt_ms());
        let changed = self.quality != Some(next);
        self.quality = Some(next);
        changed
    }

    /// The smoothed round trip in whole milliseconds, once a pong came.
    pub fn rtt_ms(&self) -> Option<u32> {
        (self.srtt_us > 0).then(|| self.srtt_ms())
    }

    pub fn quality(&self) -> Option<LinkQuality> {
        self.quality
    }

    fn srtt_ms(&self) -> u32 {
        ms(self.srtt_us)
    }
}

fn ms(us: u64) -> u32 {
    u32::try_from(us.div_ceil(1000)).unwrap_or(u32::MAX)
}

/// The tier of a link whose smoothed round trip is `srtt_ms`, coming from `was`.
pub fn tier(was: Option<LinkQuality>, srtt_ms: u32) -> LinkQuality {
    let raw = if srtt_ms >= POOR_MS {
        LinkQuality::Poor
    } else if srtt_ms >= SLOW_MS {
        LinkQuality::Slow
    } else {
        LinkQuality::Good
    };
    let Some(was) = was else { return raw };
    if rank(raw) >= rank(was) {
        return raw;
    }
    // Better than before: only once clearly under the bound of the tier it leaves.
    let leave = |bound: u32| srtt_ms.saturating_mul(100) < bound.saturating_mul(RECOVER);
    match was {
        LinkQuality::Poor if leave(POOR_MS) => {
            if leave(SLOW_MS) {
                LinkQuality::Good
            } else {
                LinkQuality::Slow
            }
        }
        LinkQuality::Slow if leave(SLOW_MS) => LinkQuality::Good,
        other => other,
    }
}

fn rank(q: LinkQuality) -> u8 {
    match q {
        LinkQuality::Good => 0,
        LinkQuality::Slow => 1,
        LinkQuality::Poor => 2,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const MS: u64 = 1000;

    #[test]
    fn first_pong_sets_the_estimate_and_its_tier() {
        let mut e = RttEstimate::default();
        assert_eq!(e.rtt_ms(), None);
        assert!(e.sample(20 * MS));
        assert_eq!(e.rtt_ms(), Some(20));
        assert_eq!(e.quality(), Some(LinkQuality::Good));
        assert!(!e.sample(22 * MS), "same tier is no news");
    }

    #[test]
    fn one_spike_does_not_change_the_tier_a_sustained_rise_does() {
        let mut e = RttEstimate::default();
        for _ in 0..20 {
            e.sample(30 * MS);
        }
        assert!(!e.sample(900 * MS), "one 900 ms pong on a 30 ms link is a spike");
        assert_eq!(e.quality(), Some(LinkQuality::Good));
        let mut moved = 0;
        for _ in 0..40 {
            if e.sample(500 * MS) {
                moved += 1;
            }
        }
        assert_eq!(e.quality(), Some(LinkQuality::Poor));
        assert!(moved <= 2, "good -> slow -> poor at most, got {moved} notes");
        assert!(e.rtt_ms().unwrap() >= 450);
    }

    #[test]
    fn a_link_at_the_edge_does_not_flap() {
        let mut e = RttEstimate::default();
        for _ in 0..40 {
            e.sample(160 * MS);
        }
        assert_eq!(e.quality(), Some(LinkQuality::Slow));
        let mut notes = 0;
        for i in 0..200 {
            // Wobbles around the 150 ms bound.
            let s = if i % 2 == 0 { 135 } else { 165 };
            if e.sample(s * MS) {
                notes += 1;
            }
        }
        assert_eq!(notes, 0, "a link wobbling around the bound stays one tier");
        for _ in 0..40 {
            e.sample(40 * MS);
        }
        assert_eq!(e.quality(), Some(LinkQuality::Good), "a clear recovery is said");
    }

    #[test]
    fn hysteresis_needs_a_clear_drop_below_the_bound() {
        assert_eq!(tier(Some(LinkQuality::Slow), 130), LinkQuality::Slow);
        assert_eq!(tier(Some(LinkQuality::Slow), 119), LinkQuality::Good);
        assert_eq!(tier(Some(LinkQuality::Poor), 330), LinkQuality::Poor);
        assert_eq!(tier(Some(LinkQuality::Poor), 300), LinkQuality::Slow);
        assert_eq!(tier(Some(LinkQuality::Poor), 100), LinkQuality::Good);
        assert_eq!(tier(Some(LinkQuality::Good), 150), LinkQuality::Slow);
        assert_eq!(tier(None, 400), LinkQuality::Poor);
    }
}
