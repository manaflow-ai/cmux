//! Each peer's newest whole list, waiting for its notice shard (cmux#56153).
//!
//! A link that cannot follow its cursor reads the peer's whole list on every reconnect, and the
//! hub's queues are bounded by notices, not bytes: under churn a starved shard held every list of
//! every flap, each a whole copy of the peer's rows (782 MB to 1,548 MB RSS in 600 s of churn, and
//! 11 GB on Leo's Mac). A whole list stands for the peer's rows entire, so one that comes while an
//! older one of the same peer instance still waits replaces it: the notice loop keeps one list per
//! peer here and hands the shard a small marker ([`super::peer_grace`]'s `Work::List`), and the
//! shard applies only the marker of the list held now. The changes the link sent after an older
//! list still apply in their order; the newer list, read after them, comes after them too.
//!
//! A follow's patch is not held here: it is relative to the rows the hub holds, so it goes in
//! order with the other notices.
//!
//! Pattern page: cmuxterm-hq `docs/handbook/queue-counts-items-not-bytes.md`.
use std::collections::HashMap;
use std::sync::Arc;
use std::sync::Mutex as StdMutex;
use std::sync::atomic::{AtomicU64, Ordering};

/// The lists waiting, by peer instance (name, generation), each with its number.
#[derive(Default)]
pub(crate) struct WaitingLists {
    lists: StdMutex<HashMap<(String, u64), (u64, Vec<Arc<str>>)>>,
    /// The last number handed out: each list held gets the next one.
    held: AtomicU64,
}

impl WaitingLists {
    fn lock(&self) -> std::sync::MutexGuard<'_, HashMap<(String, u64), (u64, Vec<Arc<str>>)>> {
        self.lists.lock().unwrap_or_else(|e| e.into_inner())
    }

    /// Holds `rows`, peer `peer`'s whole list, in place of any of the same instance still
    /// waiting, and gives its number. A replaced list is counted as superseded
    /// (`gauges.peerLists`).
    pub(crate) fn hold(&self, peer: &str, generation: u64, rows: Vec<Arc<str>>) -> u64 {
        let number = self.held.fetch_add(1, Ordering::Relaxed) + 1;
        let replaced = self.lock().insert((peer.to_owned(), generation), (number, rows));
        if let Some((_, old)) = replaced {
            crate::gauges::peer_lists().superseded(row_bytes(&old));
        }
        number
    }

    /// The list numbered `number` of that peer instance, if it is still the one held; None when a
    /// newer one replaced it (its own marker comes later).
    pub(crate) fn take(&self, peer: &str, generation: u64, number: u64) -> Option<Vec<Arc<str>>> {
        let mut lists = self.lock();
        let key = (peer.to_owned(), generation);
        if lists.get(&key).is_some_and(|(held, _)| *held == number) {
            return lists.remove(&key).map(|(_, rows)| rows);
        }
        None
    }

    /// How many lists were held, since the hub started.
    #[cfg(test)]
    pub(crate) fn held_count(&self) -> u64 {
        self.held.load(Ordering::Relaxed)
    }

    /// How many lists wait now.
    #[cfg(test)]
    pub(crate) fn waiting(&self) -> usize {
        self.lock().len()
    }
}

fn row_bytes(rows: &[Arc<str>]) -> u64 {
    rows.iter().map(|row| row.len() as u64).sum()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn list(text: &str) -> Vec<Arc<str>> {
        vec![Arc::from(text)]
    }

    #[test]
    fn a_newer_list_replaces_the_one_waiting_and_only_its_marker_takes_it() {
        let lists = WaitingLists::default();
        let first = lists.hold("box", 1, list("a"));
        let second = lists.hold("box", 1, list("b"));
        assert_eq!(lists.waiting(), 1, "one list per peer instance waits");
        assert_eq!(lists.take("box", 1, first), None, "the replaced list's marker takes nothing");
        assert_eq!(lists.take("box", 1, second), Some(list("b")));
        assert_eq!(lists.waiting(), 0);
    }

    #[test]
    fn instances_and_peers_hold_their_own_lists() {
        let lists = WaitingLists::default();
        let old = lists.hold("box", 1, list("old"));
        let new = lists.hold("box", 2, list("new"));
        let other = lists.hold("pod", 1, list("pod"));
        assert_eq!(lists.take("box", 1, old), Some(list("old")));
        assert_eq!(lists.take("box", 2, new), Some(list("new")));
        assert_eq!(lists.take("pod", 1, other), Some(list("pod")));
    }
}
