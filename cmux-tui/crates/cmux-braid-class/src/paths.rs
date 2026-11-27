//! The paths each class rides (RFD 0164: input on the best two, interactive on the short
//! path, bulk on the fat ones).

use std::time::Duration;

use crate::Class;

/// What [`paths_for`] needs to know about one path. Callers fill it from their path set
/// (`cmux_braid_path::PathStats`, the phone link's `Paths`, cmux-wg's mesh paths).
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct PathView<Id> {
    pub id: Id,
    /// The path answers (alive in `Selector` terms).
    pub alive: bool,
    /// Smoothed round trip; `None` until measured.
    pub rtt: Option<Duration>,
    /// Estimated send rate in bytes per second; `None` until measured.
    pub capacity: Option<u64>,
}

/// The most paths a [`Pick`] holds: cmux-wg's mesh keeps at most eight per peer, the
/// widest path set any link has. A fixed array keeps the hot path allocation-free.
pub const MAX_PICK: usize = 8;

/// The paths a class sends on, best first.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Pick<Id> {
    ids: [Option<Id>; MAX_PICK],
}

impl<Id: Copy> Pick<Id> {
    fn new() -> Self {
        Self { ids: [None; MAX_PICK] }
    }

    fn push(&mut self, id: Id) {
        if let Some(slot) = self.ids.iter_mut().find(|slot| slot.is_none()) {
            *slot = Some(id);
        }
    }

    /// The best path, if any is alive.
    pub fn first(&self) -> Option<Id> {
        self.ids[0]
    }

    pub fn iter(&self) -> impl Iterator<Item = Id> + '_ {
        self.ids.iter().map_while(|id| *id)
    }

    pub fn len(&self) -> usize {
        self.iter().count()
    }

    pub fn is_empty(&self) -> bool {
        self.ids[0].is_none()
    }
}

/// The paths `class` sends on, best first, from `paths` (dead ones are skipped). Every
/// supplied path is considered, however many there are.
///
/// - Input: the two lowest-RTT paths (each keystroke on both; first copy wins).
/// - State and Ordered: the lowest-RTT path.
/// - Bulk: every live path (up to [`MAX_PICK`]), most capacity first, to stripe over.
///
/// An unmeasured round trip sorts after every measured one, unmeasured capacity after every
/// measured one. Ties keep the caller's order, so a caller that lists its current path
/// first stays on it.
#[allow(
    clippy::indexing_slicing,
    reason = "round is bounded by MAX_PICK, matching the fixed selection array"
)]
pub fn paths_for<Id: Copy>(class: Class, paths: &[PathView<Id>]) -> Pick<Id> {
    let take = match class {
        Class::Bulk => MAX_PICK,
        _ if class.duplicates() => 2,
        _ => 1,
    };
    // Lower key is better; selection keeps the earliest of equal keys.
    let key = |p: &PathView<Id>| -> (u128, u64) {
        match class {
            Class::Bulk => (0, u64::MAX - p.capacity.unwrap_or(0)),
            _ => (p.rtt.map_or(u128::MAX, |rtt| rtt.as_nanos()), 0),
        }
    };
    let mut taken = [usize::MAX; MAX_PICK];
    let mut pick = Pick::new();
    for round in 0..take {
        let best = paths
            .iter()
            .enumerate()
            .filter(|(i, p)| p.alive && !taken[..round].contains(i))
            .min_by_key(|(_, p)| key(p));
        let Some((i, path)) = best else { break };
        taken[round] = i;
        pick.push(path.id);
    }
    pick
}

#[cfg(test)]
#[path = "paths_tests.rs"]
mod tests;
