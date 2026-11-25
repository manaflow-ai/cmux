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

/// The paths a class sends on, best first. At most four: a link never has more live paths
/// than that, and a fixed array keeps the hot path allocation-free.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Pick<Id> {
    ids: [Option<Id>; 4],
}

impl<Id: Copy> Pick<Id> {
    fn new() -> Self {
        Self { ids: [None; 4] }
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

/// An unmeasured round trip sorts after every measured one.
fn rtt_key<Id>(path: &PathView<Id>) -> Duration {
    path.rtt.unwrap_or(Duration::MAX)
}

/// The paths `class` sends on, best first, from `paths` (dead ones are skipped).
///
/// - Input: the two lowest-RTT paths (each keystroke on both; first copy wins).
/// - State and Ordered: the lowest-RTT path.
/// - Bulk: every live path, most capacity first, to stripe over.
///
/// Ties keep the caller's order, so a caller that lists its current path first stays on it.
pub fn paths_for<Id: Copy>(class: Class, paths: &[PathView<Id>]) -> Pick<Id> {
    let mut slots: [Option<&PathView<Id>>; 4] = [None; 4];
    let mut count = 0;
    for (slot, path) in slots.iter_mut().zip(paths.iter().filter(|p| p.alive)) {
        *slot = Some(path);
        count += 1;
    }
    let alive = &mut slots[..count];
    // Stable sorts: ties keep the caller's order.
    let take = match class {
        Class::Bulk => {
            alive.sort_by_key(|p| std::cmp::Reverse(p.map_or(0, |p| p.capacity.unwrap_or(0))));
            count
        }
        _ => {
            alive.sort_by_key(|p| p.map_or(Duration::MAX, rtt_key));
            if class.duplicates() { 2 } else { 1 }
        }
    };
    let mut pick = Pick::new();
    for path in alive.iter().take(take).flatten() {
        pick.push(path.id);
    }
    pick
}

#[cfg(test)]
#[path = "paths_tests.rs"]
mod tests;
