//! Noticing that the machine slept or that its addresses changed, so the
//! [`crate::Endpoint`] re-checks every path at once
//! ([`crate::Endpoint::on_network_change`]).
//!
//! The link's clock (`Instant`: uptime on macOS, `CLOCK_MONOTONIC` on Linux)
//! stops while the machine sleeps, so after a wake the endpoint believes the
//! path it chose was heard a moment ago. While it slept, that path can have
//! died: a NAT mapping expired, Wi-Fi joined again with another address, the
//! peer gave up on it. The first frame after the wake then goes on the dead
//! path alone, and is resent only after the silence window, a probe and the
//! media layer's 250 ms tail probe. Nothing told the endpoint: no caller of
//! the `net` driver sends `network_changed`. [`SleepWatch`] sees the sleep
//! itself, as the difference between the link's clock and a clock that keeps
//! counting through sleep, and [`AddressWatch`] sees the interface addresses
//! change; either makes the next send go on every path while fresh probes
//! pick the path again, so the first frame after a wake arrives in one trip.

/// A gap this much longer on the clock that counts sleep than on the link's
/// clock was a sleep. Well above a scheduling stall, well below any NAT
/// mapping's lifetime.
pub const SLEEP_GAP_US: u64 = 1_000_000;

/// How often the driver reads the interface addresses ([`AddressWatch`]).
pub const ADDRESS_CHECK_US: u64 = 1_000_000;

/// Compares two clocks: `awake_us` stops while the machine sleeps,
/// `with_sleep_us` does not.
#[derive(Debug, Default)]
pub struct SleepWatch {
    last: Option<(u64, u64)>,
}

impl SleepWatch {
    /// Feeds both clocks now. True when, since the last call, the clock
    /// that counts sleep ran [`SLEEP_GAP_US`] or more ahead of the other:
    /// the machine slept in between.
    pub fn observe(&mut self, awake_us: u64, with_sleep_us: u64) -> bool {
        let slept = self.last.is_some_and(|(awake, with_sleep)| {
            let asleep = with_sleep_us
                .saturating_sub(with_sleep)
                .saturating_sub(awake_us.saturating_sub(awake));
            asleep >= SLEEP_GAP_US
        });
        self.last = Some((awake_us, with_sleep_us));
        slept
    }
}

/// The machine's interface addresses, read every [`ADDRESS_CHECK_US`].
#[derive(Debug)]
pub struct AddressWatch<A> {
    known: Option<Vec<A>>,
    next_us: u64,
}

impl<A> Default for AddressWatch<A> {
    fn default() -> Self {
        Self { known: None, next_us: 0 }
    }
}

impl<A: Ord> AddressWatch<A> {
    /// Whether a check is due at `now_us`.
    pub fn due(&self, now_us: u64) -> bool {
        now_us >= self.next_us
    }

    /// Feeds the addresses read at `now_us`. True when they differ from the
    /// last read (the first read only records them).
    pub fn observe(&mut self, mut addresses: Vec<A>, now_us: u64) -> bool {
        self.next_us = now_us.saturating_add(ADDRESS_CHECK_US);
        addresses.sort();
        addresses.dedup();
        let changed = self.known.as_ref().is_some_and(|known| *known != addresses);
        self.known = Some(addresses);
        changed
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_sleep_shows_as_the_clocks_drifting_apart() {
        let mut watch = SleepWatch::default();
        assert!(!watch.observe(0, 5_000_000));
        // Awake: both clocks advance together, a long poll included.
        assert!(!watch.observe(1_000_000, 6_000_000));
        assert!(!watch.observe(1_900_000, 6_950_000));
        // Asleep for 200 s: the link's clock moved 10 ms.
        assert!(watch.observe(1_910_000, 206_960_000));
        assert!(!watch.observe(1_920_000, 206_970_000));
    }

    #[test]
    fn addresses_changing_is_a_network_change_and_order_is_not() {
        let mut watch = AddressWatch::default();
        assert!(watch.due(0));
        assert!(!watch.observe(vec![2, 1], 0), "the first read only records");
        assert!(!watch.due(ADDRESS_CHECK_US - 1));
        assert!(!watch.observe(vec![1, 2], ADDRESS_CHECK_US));
        assert!(watch.observe(vec![1, 3], 2 * ADDRESS_CHECK_US));
        assert!(watch.observe(vec![1], 3 * ADDRESS_CHECK_US));
    }
}
