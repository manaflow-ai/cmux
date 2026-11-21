//! How one window's sidebar positions map to the daemon's workspace order.
//! Each window lists only the workspaces it owns; the daemon keeps one
//! order per machine for all of them, so a slot in a filtered sidebar maps
//! to the global slot next to its visible neighbours.

use serde::{Deserialize, Serialize};

use super::wire;
use std::collections::{HashMap, HashSet};

/// The daemon root index for local index `local_index` into `local` (the
/// window's remaining workspaces of one machine, in order), given that
/// machine's full remaining order `global`: before the first workspace at or
/// after that slot that `global` lists, else after the last one before it,
/// or at the end when it lists none. A shown workspace `global` does not
/// list yet (a new one whose own placement is in flight) is no anchor:
/// placing before it once sent quick Cmd-N presses to the bottom.
pub fn global_index(local_index: i64, local: &[String], global: &[String]) -> i64 {
    let slot = usize::try_from(local_index.max(0)).unwrap_or(usize::MAX).min(local.len());
    let mut position: HashMap<&str, usize> = HashMap::with_capacity(global.len());
    for (index, key) in global.iter().enumerate() {
        position.entry(key.as_str()).or_insert(index);
    }
    if let Some(anchor) = local.iter().skip(slot).find_map(|key| position.get(key.as_str())) {
        return wire(*anchor);
    }
    if let Some(index) = local.iter().take(slot).rev().find_map(|key| position.get(key.as_str())) {
        return wire(index.saturating_add(1));
    }
    wire(global.len())
}

/// One personal placement (`workspace.place`): `key` goes to `index` in the
/// personal order counted after `key` itself is removed.
#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct PersonalPlacement {
    pub key: String,
    pub index: i64,
}

/// The personal placements, in sending order, that put `moving` (in order)
/// at `local_index` of `shown` (the window's remaining workspaces without
/// `moving`, as its sidebar shows them). `rowed` is the personal order of
/// every workspace with a personal position (without `moving`).
///
/// A workspace without a personal position shows after every positioned
/// one, so an index into `rowed` cannot name a slot after one of them. The
/// shown workspaces before the slot with no position get one first, at the
/// end of `rowed` in the order they show; then the moved workspaces go
/// after the slot's last shown workspace, or before its first.
pub fn personal_placements(
    moving: &[String],
    local_index: i64,
    shown: &[String],
    rowed: &[String],
) -> Vec<PersonalPlacement> {
    let mut rowed = rowed.to_vec();
    let mut positioned: HashSet<String> = rowed.iter().cloned().collect();
    let slot = usize::try_from(local_index.max(0)).unwrap_or(usize::MAX).min(shown.len());
    let mut plan = Vec::new();
    for key in shown.iter().take(slot) {
        if positioned.insert(key.clone()) {
            plan.push(PersonalPlacement { key: key.clone(), index: wire(rowed.len()) });
            rowed.push(key.clone());
        }
    }
    let index = global_index(wire(slot), shown, &rowed);
    plan.extend(moving.iter().enumerate().map(|(offset, key)| PersonalPlacement {
        key: key.clone(),
        index: index.saturating_add(wire(offset)),
    }));
    plan
}
