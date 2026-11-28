//! When an outbox change sweeps: only once a delivery can lapse open, age out settled, or a
//! settled class can pass its count bound ([`Book::changed_one`]).

use super::*;

impl Book {
    /// Counts a change that may have touched any delivery, and sweeps; returns its number.
    pub(super) fn changed(&mut self) -> u64 {
        self.sweep_at = 0;
        self.note_change()
    }

    /// Counts a change to delivery `id` alone; returns its number. It sweeps only when that
    /// delivery or the one due soonest can lapse or age out now, or a class can be over its
    /// bound: a daemon holding 25,000 deliveries walked them all on every change
    /// (2026-11-28, 160% CPU on a control plane, every peer snapshot write a change).
    pub(super) fn changed_one(&mut self, id: &str) -> u64 {
        // Only a settled, closed delivery counts against a class bound, and a change makes at
        // most one more of those; a change to a live one spends no room.
        if let Some(d) = self.deliveries.get(id) {
            self.sweep_at = self.sweep_at.min(d.sweep_due());
            if d.settled() && !d.open_on_peer {
                self.cap_room = self.cap_room.saturating_sub(1);
            }
        }
        self.note_change()
    }

    fn note_change(&mut self) -> u64 {
        self.pending_targets = None;
        let now = crate::store::now_ms();
        if now >= self.sweep_at || self.cap_room == 0 {
            self.sweep(now);
        }
        self.changes += 1;
        self.changes
    }

    /// Fails what lapsed open, drops what settled long ago and what is past the count bounds,
    /// and notes when the next of those can be due.
    pub(super) fn sweep(&mut self, now: u64) {
        self.sweeps += 1;
        for d in self.deliveries.values_mut().filter(|d| d.open_lapsed(now)) {
            tracing::warn!(delivery = %d.id, target = %d.target, "an open delivery lapsed; failed");
            let before = (d.state, d.attempts);
            d.fail_open(OPEN_LAPSED.to_owned());
            self.stats.note_change(
                before,
                d.state,
                d.attempts,
                d.created_at,
                d.error.as_deref(),
                now,
            );
            crate::attach::strip(&mut d.request);
            d.updated_at = now;
            // The journal gets its failed state too, not only the next snapshot.
            self.dirty.insert(d.id.clone());
        }
        self.deliveries.retain(|_, d| {
            // Team bodies/receipts live at the hub for seven days; retain their origin
            // for that entire lifetime, including owner sends with no caller session.
            let keep = if d.is_team_receipt() { 7 * KEEP_SETTLED_MS } else { KEEP_SETTLED_MS };
            // Open on its peer is not settled for this: kept until it closes or lapses.
            !d.settled() || d.open_on_peer || now.saturating_sub(d.updated_at) < keep
        });
        self.cap_settled();
        self.sweep_at = self.deliveries.values().map(Delivery::sweep_due).min().unwrap_or(u64::MAX);
        self.cap_room = self.cap_room();
    }
}
