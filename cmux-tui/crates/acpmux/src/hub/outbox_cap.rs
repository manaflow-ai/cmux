//! The count bound on the settled deliveries an outbox keeps (see [`MAX_SETTLED`]).

use super::*;

/// At most this many settled deliveries kept at once, besides the team receipts: past it
/// ([`Book::cap_settled`]) the ones settled longest ago leave first, before [`KEEP_SETTLED_MS`]
/// if they must. One a peer still holds open (`open_on_peer`) and one not settled never leave
/// this way. A daemon that sent 17 a minute held 25,000 of them a day, each a whole request tree
/// in memory and rewritten in every snapshot (`outbox.json` 59 MB, every change walking every
/// record; 2026-11-28, the daemon on a control-plane host held 4 GB RSS at 160% CPU).
///
/// Measured: 97,000 settled deliveries held 337 MB over an empty outbox at start (about 3.4 KB
/// each in memory, 100,000 of them in the daemon test), and 24,500 plain ones were settled in a day
/// at the busiest daemon; `send --status` reads one by id, and 5,000 covers its last few hours.
pub const MAX_SETTLED: usize = 5_000;

/// The same for the team receipts (`is_team_receipt`), which live seven days: bookkeeping of a
/// message posted to the hub, about 400 bytes on disk each.
///
/// Measured: 73,000 receipts were 26 MB on disk, so 20,000 are about 7 MB.
pub const MAX_SETTLED_RECEIPTS: usize = 20_000;

impl Book {
    /// Drops the settled deliveries past [`MAX_SETTLED`] (and the team receipts past
    /// [`MAX_SETTLED_RECEIPTS`]), the ones settled longest ago first. It runs only once a class is
    /// a tenth over its bound and then cuts to the bound, so a busy daemon does not sort on every
    /// change. Returns how many it dropped.
    pub(super) fn cap_settled(&mut self) -> usize {
        let mut dropped = 0;
        if self.deliveries.len() <= MAX_SETTLED + MAX_SETTLED / 10 {
            return dropped;
        }
        for (receipts, cap) in [(false, MAX_SETTLED), (true, MAX_SETTLED_RECEIPTS)] {
            let mut kept: Vec<(u64, &String)> = self
                .deliveries
                .iter()
                .filter(|(_, d)| d.settled() && !d.open_on_peer && d.is_team_receipt() == receipts)
                .map(|(id, d)| (d.updated_at, id))
                .collect();
            if kept.len() <= cap + cap / 10 {
                continue;
            }
            kept.sort_unstable();
            let drop: Vec<String> =
                kept[..kept.len() - cap].iter().map(|(_, id)| (*id).clone()).collect();
            dropped += drop.len();
            for id in drop {
                self.deliveries.remove(&id);
                self.dirty.remove(&id);
            }
        }
        dropped
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::hub::outbox::tests::delivery;

    /// 2026-11-28: a daemon that sent 17 messages a minute kept 97,000 settled deliveries (59 MB of
    /// `outbox.json`, every change walking all of them) and held GBs. Past the bounds the ones
    /// settled longest ago leave first; an unsettled one and one open on its peer never do.
    #[test]
    fn settled_deliveries_and_receipts_are_kept_within_their_bounds() {
        let now = crate::store::now_ms();
        let mut book = Book::default();
        let mut put = |mut d: Delivery, age: u64| {
            d.updated_at = now - age;
            book.deliveries.insert(d.id.clone(), d);
        };
        let settled = |n: usize| {
            let mut d = delivery(n);
            d.state = State::Delivered;
            d
        };
        let total = MAX_SETTLED + MAX_SETTLED / 5;
        for n in 0..total {
            put(settled(n), (total - n) as u64);
        }
        for n in 0..MAX_SETTLED_RECEIPTS + MAX_SETTLED_RECEIPTS / 5 {
            let mut d = settled(n);
            d.id = format!("mesh:{n}");
            d.request = json!({"teamOrigin": true});
            put(d, (MAX_SETTLED_RECEIPTS * 2 - n) as u64);
        }
        let mut waiting = delivery(900_000);
        waiting.state = State::Queued;
        put(waiting, 10_000_000);
        let mut open = settled(900_001);
        open.open_on_peer = true;
        put(open, 10_000_000);
        book.changed();
        let receipts = book.deliveries.values().filter(|d| d.is_team_receipt()).count();
        let plain =
            book.deliveries.values().filter(|d| d.settled() && !d.is_team_receipt()).count();
        assert_eq!(receipts, MAX_SETTLED_RECEIPTS);
        assert_eq!(plain, MAX_SETTLED + 1, "the bound, and the one open on its peer");
        assert!(book.deliveries.contains_key("d-900000"), "an unsettled delivery stays");
        assert!(book.deliveries.contains_key("d-900001"), "one open on its peer stays");
        assert!(book.deliveries.contains_key(&format!("d-{}", total - 1)), "the newest stays");
        assert!(!book.deliveries.contains_key("d-0"), "the oldest leaves");
        assert!(!book.deliveries.contains_key("mesh:0"));
    }
}
