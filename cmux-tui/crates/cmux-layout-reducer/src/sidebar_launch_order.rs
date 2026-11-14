//! The sidebar's launch order hold (`sidebar_launch_order`): from launch until the home
//! session's owner serves, the sidebar keeps the order it first drew (Leo, 2026-11-09: "tens of
//! seconds after restarting to update the sidebar kinda reshuffled or something weird").
//!
//! At launch the rows draw from caches: the daemon's launch snapshot (tree, personal state and
//! sidebar document), the window's saved sidebar. Until the owner answers, other feeds still
//! change what is listed (the snapshot document's projection over a changing live set, the
//! personal order once a handshake says the mixed order applies, agent lanes, a remote machine
//! that connects, the end of the launch grace), and each of them may order the same rows another
//! way. Each such pass reshuffled rows the person was already looking at. While the hold is on,
//! a row keeps its place among the rows drawn before it: a row the cache did not show is inserted
//! right after the row it follows in the new order, and a row that leaves is remembered, so it
//! comes back where it was. When the owner serves, the hold ends with one transition to the live
//! order, and only the rows whose place truly differs move (`moved`, the fewest rows that do).
//!
//! Pure: the app sends one request per structural sidebar pass while the hold is on (each list
//! is one section's top-level rows, a group's members, or the section order) and one at the end.

use serde::{Deserialize, Serialize};
use std::collections::{HashMap, HashSet};

/// One structural pass.
#[derive(Clone, Debug, Default, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Request {
    /// The hold is still on (the owner does not serve yet). False ends it: each list answers the
    /// live order and the rows that move to reach it.
    #[serde(default)]
    pub hold: bool,
    pub lists: Vec<List>,
}

/// One ordered list of row keys.
#[derive(Clone, Debug, Default, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct List {
    pub key: String,
    /// The order held so far: every row this list drew since launch, in its drawn order (rows
    /// that left too). Empty for a list not drawn before.
    #[serde(default)]
    pub reference: Vec<String>,
    /// Ending the hold: the rows on screen now, in their drawn order (the last pass's `order`).
    /// A remembered row that is not drawn comes back as an insert, never a move. Empty: every
    /// row of `reference` counts as drawn.
    #[serde(default)]
    pub drawn: Vec<String>,
    /// The order the pass computed.
    pub next: Vec<String>,
}

#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Reply {
    pub lists: Vec<ListReply>,
}

#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ListReply {
    pub key: String,
    /// The rows of `next` in the order to draw.
    pub order: Vec<String>,
    /// The held order to send with the next pass (empty once the hold ended).
    pub reference: Vec<String>,
    /// Ending the hold: the rows that move to reach the live order (the fewest; every other row
    /// keeps its place). Empty while the hold is on.
    pub moved: Vec<String>,
}

/// Answers every list of `request`.
pub fn respond(request: &Request) -> Reply {
    Reply {
        lists: request
            .lists
            .iter()
            .map(|list| {
                if request.hold {
                    let (order, reference) = hold(&list.reference, &list.next);
                    ListReply { key: list.key.clone(), order, reference, moved: Vec::new() }
                } else {
                    ListReply {
                        key: list.key.clone(),
                        order: list.next.clone(),
                        reference: Vec::new(),
                        moved: moved(
                            if list.drawn.is_empty() { &list.reference } else { &list.drawn },
                            &list.next,
                        ),
                    }
                }
            })
            .collect(),
    }
}

/// `next` in the held order, and the held order to keep. A row of `reference` keeps its place
/// among the other rows of `reference`; a run of new rows goes right after the row it follows in
/// `next` (first when it follows none). `next` with a key listed twice is answered as it is: the
/// app cannot tell its rows apart.
pub fn hold(reference: &[String], next: &[String]) -> (Vec<String>, Vec<String>) {
    let mut seen = HashSet::with_capacity(next.len());
    if !next.iter().all(|key| seen.insert(key.as_str())) {
        return (next.to_vec(), reference.to_vec());
    }
    let mut rank: HashMap<&str, usize> = HashMap::with_capacity(reference.len());
    for (index, key) in reference.iter().enumerate() {
        rank.entry(key.as_str()).or_insert(index);
    }
    // The runs of new rows: each after the held row it follows (`None`: before every held row).
    let mut leading: Vec<&str> = Vec::new();
    let mut runs: HashMap<&str, Vec<&str>> = HashMap::new();
    let mut anchor: Option<&str> = None;
    let mut held: Vec<(usize, &str)> = Vec::new();
    for key in next {
        let key = key.as_str();
        match rank.get(key) {
            Some(&index) => {
                held.push((index, key));
                anchor = Some(key);
            }
            None => match anchor {
                Some(after) => runs.entry(after).or_default().push(key),
                None => leading.push(key),
            },
        }
    }
    held.sort_by_key(|&(index, _)| index);
    let mut order: Vec<String> = Vec::with_capacity(next.len());
    order.extend(leading.iter().map(|key| key.to_string()));
    for &(_, key) in &held {
        order.push(key.to_string());
        if let Some(run) = runs.get(key) {
            order.extend(run.iter().map(|key| key.to_string()));
        }
    }
    let mut kept: Vec<String> = Vec::with_capacity(reference.len() + next.len());
    kept.extend(leading.iter().map(|key| key.to_string()));
    let mut placed = HashSet::with_capacity(reference.len());
    for key in reference {
        if !placed.insert(key.as_str()) {
            continue;
        }
        kept.push(key.clone());
        if let Some(run) = runs.get(key.as_str()) {
            kept.extend(run.iter().map(|key| key.to_string()));
        }
    }
    (order, kept)
}

/// The rows of `next` that move when the list goes from the held order (`reference`) to `next`:
/// the shared rows outside one longest run that keeps its relative order. New rows open their
/// slot and gone rows close theirs; neither is a move.
pub fn moved(reference: &[String], next: &[String]) -> Vec<String> {
    let mut rank: HashMap<&str, usize> = HashMap::with_capacity(reference.len());
    for (index, key) in reference.iter().enumerate() {
        rank.entry(key.as_str()).or_insert(index);
    }
    let shared: Vec<(usize, &str)> = next
        .iter()
        .filter_map(|key| rank.get(key.as_str()).map(|&rank| (rank, key.as_str())))
        .collect();
    // Longest increasing run of ranks (patience sort with back links). `tails` holds positions
    // into `shared` and `previous` one entry per position, so every lookup is in range; `get`
    // keeps that from being a panic path.
    let mut tails: Vec<usize> = Vec::new();
    let mut previous: Vec<Option<usize>> = vec![None; shared.len()];
    for (position, &(rank, _)) in shared.iter().enumerate() {
        let slot = tails.partition_point(|&tail| shared.get(tail).is_some_and(|&(r, _)| r < rank));
        if let (Some(back), Some(link)) =
            (slot.checked_sub(1).and_then(|s| tails.get(s)), previous.get_mut(position))
        {
            *link = Some(*back);
        }
        match tails.get_mut(slot) {
            Some(tail) => *tail = position,
            None => tails.push(position),
        }
    }
    let mut stays = vec![false; shared.len()];
    let mut cursor = tails.last().copied();
    while let Some(position) = cursor {
        if let Some(stay) = stays.get_mut(position) {
            *stay = true;
        }
        cursor = previous.get(position).copied().flatten();
    }
    shared
        .iter()
        .zip(stays)
        .filter(|(_, stays)| !stays)
        .map(|((_, key), _)| key.to_string())
        .collect()
}

#[cfg(test)]
mod tests;
