//! Mac output to phone paint, timed on the Mac's clock only (ask-0e9bbe35bb: "the scroll occurs
//! on mac, then it delays on my actual iphone display").
//!
//! The Mac numbers every output byte it sends a viewer: byte `n` of the attach's output stream,
//! counted from the attach. [`SendStamps`] keeps, for the last [`RING`] output events, the offset
//! each one ends at and when it went out (the Mac's clock, microseconds). The viewer says, for
//! each frame it presented, how many of those bytes its terminal had parsed by then (its
//! *painted-through* offset) and how long before it sent the report that frame was (a duration
//! on the viewer's own monotonic clock: no clock sync). The Mac places each frame on its own
//! clock as `report received - age`, and [`window`] gives every output event the first frame
//! that painted all of it: `that frame - sent`.
//!
//! That time still holds the report's own trip back to the Mac, so a window has two columns:
//! [`Window::raw`] (send to paint, plus the uplink) and [`Window::less_half_rtt`] (minus half
//! the link's round trip: the phone's share). Their difference is the link.
//!
//! Bounded: a ring holds at most [`RING`] events (older ones fall off and the window says
//! [`Window::partial`]); a window walks its stamps and paints once, in order.

use std::collections::VecDeque;

/// Most output events one viewer's ring keeps.
pub const RING: usize = 4096;

/// One output event: the stream offset it ends at and when it was sent (µs, the Mac's clock).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Stamp {
    pub end: u64,
    pub at_us: u64,
}

/// When each of a viewer's last [`RING`] output events was sent.
#[derive(Debug, Clone)]
pub struct SendStamps {
    ring: VecDeque<Stamp>,
    cap: usize,
    offset: u64,
    dropped_through: u64,
}

impl Default for SendStamps {
    fn default() -> Self {
        Self::new(RING)
    }
}

impl SendStamps {
    /// A ring of at most `cap` events (at least one).
    pub fn new(cap: usize) -> Self {
        let cap = cap.max(1);
        Self { ring: VecDeque::with_capacity(cap.min(RING)), cap, offset: 0, dropped_through: 0 }
    }

    /// `bytes` of output went out at `at_us`. An empty event is not one.
    pub fn sent(&mut self, bytes: u64, at_us: u64) {
        if bytes == 0 {
            return;
        }
        self.offset += bytes;
        if self.ring.len() == self.cap
            && let Some(dropped) = self.ring.pop_front()
        {
            self.dropped_through = dropped.end;
        }
        self.ring.push_back(Stamp { end: self.offset, at_us });
    }

    /// Bytes sent so far: the offset the next event starts at.
    pub fn offset(&self) -> u64 {
        self.offset
    }

    /// The offset the oldest kept event starts at: everything from there on is stamped (the
    /// end of the last event that fell off the ring; 0 when none did).
    pub fn first_kept(&self) -> u64 {
        self.dropped_through
    }

    pub fn len(&self) -> usize {
        self.ring.len()
    }

    pub fn is_empty(&self) -> bool {
        self.ring.is_empty()
    }

    pub fn stamps(&self) -> impl Iterator<Item = &Stamp> {
        self.ring.iter()
    }
}

/// One presented frame: the output it had parsed, and when it was on screen (µs, the Mac's clock).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Paint {
    pub through: u64,
    pub at_us: u64,
}

impl Paint {
    /// A frame the viewer reported `age_ms` before its report reached the Mac at `received_us`.
    pub fn reported(through: u64, age_ms: f64, received_us: u64) -> Self {
        let age_us = if age_ms.is_finite() && age_ms > 0.0 { (age_ms * 1000.0) as u64 } else { 0 };
        Self { through, at_us: received_us.saturating_sub(age_us) }
    }
}

/// p50/p95/max of one column (ms, 0.01 ms steps).
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Column {
    /// Output events timed.
    pub events: usize,
    pub p50_ms: f64,
    pub p95_ms: f64,
    pub max_ms: f64,
}

/// One window's output-to-paint.
#[derive(Debug, Clone, PartialEq)]
pub struct Window {
    /// Sent to painted, as the Mac sees it (the report's trip back included).
    pub raw: Column,
    /// The same, less half the link's round trip, when the window knows it.
    pub less_half_rtt: Option<Column>,
    /// Some of the window's output fell off the ring before the report came: those events
    /// are not in it.
    pub partial: bool,
    /// Frames that said they had parsed more than the Mac sent (a stream the two sides count
    /// differently): taken as painted through what was sent.
    pub ahead: usize,
}

/// Every output event painted within `paints` (any order), timed from `stamps`: the first
/// frame whose painted-through offset covers the whole event, less when it was sent. Events
/// the first frame already held were painted before the window, so they are not counted.
/// `half_rtt_ms` fills [`Window::less_half_rtt`]. `None` when no event was painted in it.
pub fn window(stamps: &SendStamps, paints: &[Paint], half_rtt_ms: Option<f64>) -> Option<Window> {
    let mut paints = paints.to_vec();
    paints.sort_by_key(|paint| paint.at_us);
    let first = paints.first()?;
    let sent = stamps.offset();
    let mut ahead = 0usize;
    let mut clamp = |through: u64| {
        if through > sent {
            ahead += 1;
            sent
        } else {
            through
        }
    };
    let base = clamp(first.through);
    let partial = stamps.first_kept() > base;
    let mut through = base;
    let mut iter = stamps.stamps().skip_while(|stamp| stamp.end <= base).peekable();
    let mut latencies: Vec<f64> = Vec::new();
    for paint in paints.iter().skip(1) {
        through = through.max(clamp(paint.through));
        while let Some(stamp) = iter.next_if(|stamp| stamp.end <= through) {
            latencies.push(paint.at_us.saturating_sub(stamp.at_us) as f64 / 1000.0);
        }
    }
    if latencies.is_empty() {
        return None;
    }
    let raw = column(&latencies);
    let less_half_rtt = half_rtt_ms.filter(|half| half.is_finite() && *half >= 0.0).map(|half| {
        let less: Vec<f64> = latencies.iter().map(|ms| (ms - half).max(0.0)).collect();
        column(&less)
    });
    Some(Window { raw, less_half_rtt, partial, ahead })
}

fn column(values: &[f64]) -> Column {
    let mut sorted = values.to_vec();
    sorted.sort_by(f64::total_cmp);
    let round = |v: f64| (v * 100.0).round() / 100.0;
    Column {
        events: sorted.len(),
        p50_ms: round(percentile(&sorted, 0.5)),
        p95_ms: round(percentile(&sorted, 0.95)),
        max_ms: round(*sorted.last().unwrap_or(&0.0)),
    }
}

/// Nearest-rank percentile of sorted values (as `phone_frames.rs` and the phone).
pub fn percentile(sorted: &[f64], p: f64) -> f64 {
    if sorted.is_empty() {
        return 0.0;
    }
    let rank = (p * sorted.len() as f64).ceil() as usize;
    sorted.get(rank.clamp(1, sorted.len()) - 1).copied().unwrap_or(0.0)
}

/// The decoded length of a base64 string's `len` characters ending in `padding` `=`s.
pub fn base64_decoded_len(len: usize, padding: usize) -> u64 {
    ((len / 4) * 3).saturating_sub(padding.min(2)) as u64
}

#[cfg(test)]
mod tests {
    use super::*;

    fn stamps(events: &[(u64, u64)]) -> SendStamps {
        let mut s = SendStamps::default();
        for &(bytes, at_us) in events {
            s.sent(bytes, at_us);
        }
        s
    }

    #[test]
    fn each_event_is_timed_to_the_first_frame_that_painted_all_of_it() {
        // Three events of 10 bytes at 0, 5 and 10 ms.
        let s = stamps(&[(10, 0), (10, 5_000), (10, 10_000)]);
        assert_eq!(s.offset(), 30);
        // A frame at 1 ms had nothing; at 9 ms the first 15 bytes (event 1 whole, event 2 half);
        // at 20 ms everything.
        let paints = [
            Paint { through: 0, at_us: 1_000 },
            Paint { through: 15, at_us: 9_000 },
            Paint { through: 30, at_us: 20_000 },
        ];
        let w = window(&s, &paints, Some(4.0)).unwrap();
        // 9 - 0, 20 - 5, 20 - 10.
        assert_eq!(w.raw, Column { events: 3, p50_ms: 10.0, p95_ms: 15.0, max_ms: 15.0 });
        assert_eq!(
            w.less_half_rtt,
            Some(Column { events: 3, p50_ms: 6.0, p95_ms: 11.0, max_ms: 11.0 })
        );
        assert!(!w.partial);
        assert_eq!(w.ahead, 0);
    }

    #[test]
    fn output_the_first_frame_already_held_is_not_counted() {
        let s = stamps(&[(10, 0), (10, 5_000)]);
        let paints = [Paint { through: 10, at_us: 100_000 }, Paint { through: 20, at_us: 6_000 }];
        // Sorted by time: the 6 ms frame is first and holds 20: nothing new after it.
        assert_eq!(window(&s, &paints, None), None);
        let paints = [Paint { through: 10, at_us: 1_000 }, Paint { through: 20, at_us: 8_000 }];
        let w = window(&s, &paints, None).unwrap();
        assert_eq!((w.raw.events, w.raw.max_ms), (1, 3.0));
        assert_eq!(w.less_half_rtt, None);
    }

    #[test]
    fn a_frame_ahead_of_what_was_sent_is_clamped_and_counted() {
        let s = stamps(&[(10, 0)]);
        let paints = [Paint { through: 0, at_us: 0 }, Paint { through: 12, at_us: 2_000 }];
        let w = window(&s, &paints, None).unwrap();
        assert_eq!((w.raw.events, w.ahead), (1, 1));
    }

    #[test]
    fn the_ring_is_bounded_and_says_when_it_lost_the_window_start() {
        let mut s = SendStamps::new(4);
        for i in 0..10u64 {
            s.sent(1, i * 1_000);
        }
        assert_eq!(s.len(), 4);
        assert_eq!(s.offset(), 10);
        let paints = [Paint { through: 2, at_us: 0 }, Paint { through: 10, at_us: 20_000 }];
        let w = window(&s, &paints, None).unwrap();
        assert!(w.partial);
        assert_eq!(w.raw.events, 4, "only the kept events");
        // A ring that kept everything is not partial.
        let s = stamps(&[(1, 0), (1, 1_000)]);
        let w =
            window(&s, &[Paint { through: 0, at_us: 0 }, Paint { through: 2, at_us: 3_000 }], None)
                .unwrap();
        assert!(!w.partial);
        assert_eq!(s.first_kept(), 0);
    }

    #[test]
    fn a_reported_frame_lands_on_the_macs_clock_by_its_age() {
        assert_eq!(Paint::reported(5, 12.5, 100_000), Paint { through: 5, at_us: 87_500 });
        assert_eq!(Paint::reported(5, f64::NAN, 100_000).at_us, 100_000);
        assert_eq!(Paint::reported(5, 1e9, 100).at_us, 0);
    }

    #[test]
    fn empty_events_and_base64_lengths() {
        let s = stamps(&[(0, 0)]);
        assert!(s.is_empty());
        assert_eq!(base64_decoded_len(4, 0), 3);
        assert_eq!(base64_decoded_len(8, 1), 5);
        assert_eq!(base64_decoded_len(8, 2), 4);
        assert_eq!(base64_decoded_len(0, 0), 0);
    }
}
