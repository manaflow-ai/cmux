//! The background hour's byte bound (`cmux-next-ios/design/background-delta-sync.md`, "Budgets":
//! 256 KiB per background hour). Each background wake spends from it what its reply weighed;
//! a wake asks its chats for no more than the hour has left after the two lists, so a busy Mac
//! pushing a wake every few minutes cannot drain the phone's data or battery. What a cut wake
//! leaves stays behind its cursor for the next wake, or for the foreground, which is unbounded
//! here (the person asked for it).
//!
//! A sliding window, kept in [`super::Cursors`] so the app and its notification service
//! extension (separate processes, one read store) spend from one hour.

use std::collections::VecDeque;

use super::{LIST_ESTIMATE_BYTES, WAKE_BUDGET_BYTES};

/// Bytes the background replies of one hour may weigh.
pub const HOUR_BUDGET_BYTES: u64 = 256 * 1024;
/// The window, in seconds.
pub const HOUR_SECS: u64 = 3600;
/// Spends within this many seconds of the last one are kept as one entry.
const COALESCE_SECS: u64 = 60;
/// Entries kept; past it the oldest two merge (at the later time: the hour never under-counts).
const MAX_ENTRIES: usize = 64;

/// What the background replies of the last hour weighed: `(at, bytes)`, oldest first, `at` in
/// seconds of the wall clock.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct HourLedger {
    spends: VecDeque<(u64, u64)>,
}

impl HourLedger {
    /// A background reply of `bytes` arrived at `at`.
    pub fn spend(&mut self, at: u64, bytes: u64) {
        self.forget(at);
        // A clock that stepped back counts at the newest time it saw: never earlier out.
        let at = self.spends.back().map_or(at, |(last, _)| at.max(*last));
        match self.spends.back_mut() {
            Some((last, spent)) if at - *last < COALESCE_SECS => {
                *last = at;
                *spent = spent.saturating_add(bytes);
            }
            _ => self.spends.push_back((at, bytes)),
        }
        while self.spends.len() > MAX_ENTRIES {
            let Some((_, first)) = self.spends.pop_front() else { break };
            if let Some((_, next)) = self.spends.front_mut() {
                *next = next.saturating_add(first);
            }
        }
    }

    /// Bytes spent in the hour before `now`. A spend stamped later than `now` (the clock
    /// stepped back) counts, unless it is more than an hour ahead: a clock that was wrong.
    pub fn spent(&self, now: u64) -> u64 {
        self.spends
            .iter()
            .filter(|(at, _)| {
                at.saturating_add(HOUR_SECS) > now && *at <= now.saturating_add(HOUR_SECS)
            })
            .fold(0u64, |sum, (_, bytes)| sum.saturating_add(*bytes))
    }

    /// Bytes the hour has left at `now`.
    pub fn left(&self, now: u64) -> u64 {
        HOUR_BUDGET_BYTES.saturating_sub(self.spent(now))
    }

    /// What a background wake at `now` may ask its chats for, at most `wake` (0: the default
    /// [`WAKE_BUDGET_BYTES`]): what the hour has left after the two lists. 0: lists only.
    pub fn chat_budget(&self, now: u64, wake: u64) -> u64 {
        let wake = if wake == 0 { WAKE_BUDGET_BYTES } else { wake };
        wake.min(self.left(now).saturating_sub(2 * LIST_ESTIMATE_BYTES))
    }

    /// The kept entries, oldest first (for [`super::Cursors::encode`]).
    pub fn entries(&self) -> impl Iterator<Item = (u64, u64)> + '_ {
        self.spends.iter().copied()
    }

    /// Reads one kept entry back, in order.
    pub(crate) fn restore(&mut self, at: u64, bytes: u64) {
        self.spends.push_back((at, bytes));
        while self.spends.len() > MAX_ENTRIES {
            self.spends.pop_front();
        }
    }

    fn forget(&mut self, now: u64) {
        while self.spends.front().is_some_and(|(at, _)| at.saturating_add(HOUR_SECS) <= now) {
            self.spends.pop_front();
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_hour_slides_and_a_full_hour_asks_lists_only() {
        let mut hour = HourLedger::default();
        assert_eq!(hour.chat_budget(0, 0), WAKE_BUDGET_BYTES);
        for wake in 0..4 {
            hour.spend(wake * 600, WAKE_BUDGET_BYTES);
        }
        assert_eq!(hour.spent(1800), HOUR_BUDGET_BYTES);
        assert_eq!(hour.chat_budget(1800, 0), 0, "spent: the next wake asks the lists only");
        // The first spend leaves the window an hour after it came.
        assert_eq!(hour.spent(3600), 3 * WAKE_BUDGET_BYTES);
        assert_eq!(hour.chat_budget(3600, 0), WAKE_BUDGET_BYTES - 2 * LIST_ESTIMATE_BYTES);
        assert_eq!(hour.chat_budget(3600, 16 * 1024), 16 * 1024);
        assert_eq!(hour.spent(4200 + HOUR_SECS), 0);
    }

    #[test]
    fn a_clock_stepping_back_never_frees_the_hour_early() {
        let mut hour = HourLedger::default();
        hour.spend(10_000, 200 * 1024);
        // The clock went back ten minutes: the spend still counts.
        assert_eq!(hour.spent(9_400), 200 * 1024);
        hour.spend(9_400, 50 * 1024);
        assert_eq!(hour.spent(10_000), 250 * 1024);
        // A stamp more than an hour ahead is a wrong clock, not a spend.
        assert_eq!(hour.spent(10_000 - HOUR_SECS - 1), 0);
    }

    #[test]
    fn the_ledger_stays_bounded_and_over_counts_when_it_merges() {
        let mut hour = HourLedger::default();
        for i in 0..500u64 {
            hour.spend(i * COALESCE_SECS, 100);
        }
        assert!(hour.entries().count() <= MAX_ENTRIES);
        let total: u64 = hour.entries().map(|(_, bytes)| bytes).sum();
        assert!(total <= 500 * 100);
        // Everything in the last hour is still counted.
        let now = 499 * COALESCE_SECS;
        assert!(hour.spent(now) >= (HOUR_SECS / COALESCE_SECS) * 100, "{}", hour.spent(now));
    }
}
