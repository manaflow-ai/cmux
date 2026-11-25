//! When to scan each source, from its file events: the debounce and the
//! minimum interval, on an injected clock (`now` is any monotonic time as a
//! `Duration`; the thread passes the time since it started).
//!
//! A source with events is due once `debounce` passed since its last event
//! (a burst of commits is one scan), but no later than `min_interval` after
//! its first one (a store that never goes quiet is still scanned), and never
//! sooner than `min_interval` after its last scan. Nothing is due without an
//! event; a removed source is never due again.

use std::time::Duration;

#[derive(Debug, Clone, Copy, Default)]
struct Slot {
    removed: bool,
    first_event: Option<Duration>,
    last_event: Option<Duration>,
    last_scan: Option<Duration>,
}

/// The scan schedule of every source, by index.
#[derive(Debug, Clone)]
pub struct Scheduler {
    debounce: Duration,
    min_interval: Duration,
    slots: Vec<Slot>,
}

impl Scheduler {
    pub fn new(sources: usize, debounce: Duration, min_interval: Duration) -> Self {
        Self { debounce, min_interval, slots: vec![Slot::default(); sources] }
    }

    /// A file event of source `index`.
    pub fn event(&mut self, index: usize, now: Duration) {
        if let Some(slot) = self.slots.get_mut(index)
            && !slot.removed
        {
            if slot.first_event.is_none() {
                slot.first_event = Some(now);
            }
            slot.last_event = Some(now);
        }
    }

    /// Source `index` was scanned at `now`: its events so far are handled.
    pub fn scanned(&mut self, index: usize, now: Duration) {
        if let Some(slot) = self.slots.get_mut(index) {
            slot.first_event = None;
            slot.last_event = None;
            slot.last_scan = Some(now);
        }
    }

    /// Source `index` is no longer watched.
    pub fn remove(&mut self, index: usize) {
        if let Some(slot) = self.slots.get_mut(index) {
            *slot = Slot { removed: true, ..Slot::default() };
        }
    }

    /// When source `index` is due, if it has events.
    fn due_at(&self, slot: &Slot) -> Option<Duration> {
        if slot.removed {
            return None;
        }
        let (first, last) = (slot.first_event?, slot.last_event?);
        let quiet = last.saturating_add(self.debounce);
        let cap = first.saturating_add(self.min_interval.max(self.debounce));
        let paced =
            slot.last_scan.map_or(Duration::ZERO, |scan| scan.saturating_add(self.min_interval));
        Some(quiet.min(cap).max(paced))
    }

    /// The sources due at `now`.
    pub fn due(&self, now: Duration) -> Vec<usize> {
        self.slots
            .iter()
            .enumerate()
            .filter(|(_, slot)| self.due_at(slot).is_some_and(|at| at <= now))
            .map(|(index, _)| index)
            .collect()
    }

    /// The earliest time a source is due; none when no source has events
    /// (then the thread sleeps until the next event or its stop).
    pub fn next_due(&self) -> Option<Duration> {
        self.slots.iter().filter_map(|slot| self.due_at(slot)).min()
    }
}

#[cfg(test)]
mod tests {
    use super::Scheduler;
    use std::time::Duration;

    fn ms(value: u64) -> Duration {
        Duration::from_millis(value)
    }

    #[test]
    fn nothing_is_due_without_an_event() {
        let schedule = Scheduler::new(2, ms(2000), ms(30_000));
        assert_eq!(schedule.next_due(), None);
        assert!(schedule.due(ms(1_000_000)).is_empty());
    }

    #[test]
    fn a_burst_is_one_scan_after_the_quiet_period() {
        let mut schedule = Scheduler::new(1, ms(2000), ms(30_000));
        for at in [0, 100, 300, 900] {
            schedule.event(0, ms(at));
        }
        assert_eq!(schedule.next_due(), Some(ms(2900)));
        assert!(schedule.due(ms(2899)).is_empty());
        assert_eq!(schedule.due(ms(2900)), vec![0]);
        schedule.scanned(0, ms(2900));
        assert_eq!(schedule.next_due(), None);
    }

    #[test]
    fn scans_are_at_least_min_interval_apart() {
        let mut schedule = Scheduler::new(1, ms(2000), ms(30_000));
        schedule.scanned(0, ms(0));
        schedule.event(0, ms(1000));
        assert_eq!(schedule.next_due(), Some(ms(30_000)));
        assert!(schedule.due(ms(3000)).is_empty());
        assert_eq!(schedule.due(ms(30_000)), vec![0]);
    }

    #[test]
    fn a_store_that_never_goes_quiet_is_still_scanned() {
        let mut schedule = Scheduler::new(1, ms(2000), ms(30_000));
        let mut at = 0;
        while at < 40_000 {
            schedule.event(0, ms(at));
            at += 500;
        }
        assert_eq!(schedule.next_due(), Some(ms(30_000)));
    }

    #[test]
    fn sources_are_scheduled_apart_and_a_removed_one_never_again() {
        let mut schedule = Scheduler::new(2, ms(100), ms(0));
        schedule.event(0, ms(0));
        schedule.event(1, ms(50));
        assert_eq!(schedule.due(ms(100)), vec![0]);
        assert_eq!(schedule.due(ms(150)), vec![0, 1]);
        schedule.remove(1);
        schedule.event(1, ms(200));
        assert_eq!(schedule.due(ms(10_000)), vec![0]);
    }
}
