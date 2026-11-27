//! The newest whole list accepted by one peer's outbox, until its marker reaches the shard.
//! Backlog, ingress, and shard capacity are all measured in notices. A marker keeps the
//! list's place across all three without keeping superseded payloads alive.
use crate::no_panic::LockExt;
use std::sync::{Arc, Mutex};

#[derive(Default)]
pub(super) struct ListSlot {
    state: Mutex<Pending>,
}

#[derive(Default)]
struct Pending {
    number: u64,
    rows: Option<Vec<Arc<str>>>,
}

fn bytes(rows: &[Arc<str>]) -> u64 {
    rows.iter().map(|row| row.len() as u64).sum()
}

impl ListSlot {
    pub(super) fn hold(&self, rows: Vec<Arc<str>>) -> u64 {
        let (number, old) = {
            let mut state = self.state.lock_or_recover();
            state.number = state.number.wrapping_add(1);
            (state.number, state.rows.replace(rows))
        };
        if let Some(old) = old {
            crate::gauges::peer_lists().superseded(bytes(&old));
        }
        number
    }

    pub(super) fn take(&self, number: u64) -> Option<Vec<Arc<str>>> {
        let mut state = self.state.lock_or_recover();
        if number != state.number {
            return None;
        }
        let rows = state.rows.take()?;
        drop(state);
        crate::gauges::peer_lists().taken(bytes(&rows));
        Some(rows)
    }
}

impl Drop for ListSlot {
    fn drop(&mut self) {
        if let Some(rows) = self.state.get_mut().unwrap_or_else(|e| e.into_inner()).rows.take() {
            crate::gauges::peer_lists().taken(bytes(&rows));
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn instances_hold_their_own_lists_and_only_their_newest_marker_takes_rows() {
        let a = ListSlot::default();
        let b = ListSlot::default();
        let old = a.hold(vec![Arc::from("old")]);
        let other = b.hold(vec![Arc::from("other")]);
        let new = a.hold(vec![Arc::from("new")]);
        assert!(a.take(old).is_none());
        assert_eq!(a.take(new), Some(vec![Arc::from("new")]));
        assert_eq!(b.take(other), Some(vec![Arc::from("other")]));
        assert!(a.take(new).is_none());
    }
}
