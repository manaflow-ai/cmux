//! `manifest - have`: the chunks a client must fetch to hold a tree.

use crate::Id;
use crate::manifest::{Chunk, Manifest};
use std::collections::HashSet;

/// The distinct chunks of `next` for which `have` is false, in first-appearance order.
pub fn want(next: &Manifest, have: impl Fn(&Id) -> bool) -> Vec<Chunk> {
    next.distinct_chunks().into_iter().filter(|c| !have(&c.id)).collect()
}

/// The chunks of `next` that a client holding exactly `held` (its previous trees) lacks.
pub fn want_after(next: &Manifest, held: &[&Manifest]) -> Vec<Chunk> {
    let have: HashSet<Id> = held
        .iter()
        .flat_map(|m| m.files.iter().flat_map(|f| f.chunks.iter().map(|c| c.id)))
        .collect();
    want(next, |id| have.contains(id))
}
