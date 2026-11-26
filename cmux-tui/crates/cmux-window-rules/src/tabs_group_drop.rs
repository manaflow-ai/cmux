//! Where a dragged tab or whole group lands over a strip that has groups
//! (the Mac app's `TabGroupDropMath`). Pure.
//!
//! `entries` are the unpinned layout slots in display order without the
//! dragged item (chips included, the drop gap excluded). Only their widths,
//! group ids and chip/collapsed flags matter: positions are recomputed from
//! `start`, because the real slots still hold the dragged item's space.

use serde::{Deserialize, Serialize};

/// One layout slot as the drop math reads it (`TabLayoutSlot`).
#[derive(Clone, Debug, Default, PartialEq, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct Entry {
    pub width: f64,
    pub group_id: Option<String>,
    pub is_group_chip: bool,
    pub is_collapsed: bool,
}

/// Where a dragged tab lands (`TabGroupDropResolution`).
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Resolution {
    /// Insertion index among the tabs (chips excluded) of the entries.
    pub index: usize,
    /// The group the tab joins there, None for ungrouped.
    pub group_id: Option<String>,
}

/// Resolves index and group membership for a dragged tab probed at
/// `dragged_min_x`: the nearest valid edge wins (never inside a collapsed
/// group); after a group's last member the tab keeps its current membership
/// until the probe passes the group's edge by `hysteresis`.
pub fn resolve_tab(
    entries: &[Entry],
    start: f64,
    dragged_min_x: f64,
    current_group: Option<&str>,
    hysteresis: f64,
) -> Resolution {
    let mut best_k = 0;
    let mut best_distance = f64::INFINITY;
    let mut best_edge = start;
    let mut edge = start;
    for k in 0..=entries.len() {
        if is_valid_position(k, entries) {
            let distance = (edge - dragged_min_x).abs();
            if distance < best_distance {
                best_distance = distance;
                best_k = k;
                best_edge = edge;
            }
        }
        if k < entries.len() {
            edge += entries[k].width;
        }
    }
    let index = entries[..best_k].iter().filter(|entry| !entry.is_group_chip).count();
    let left = best_k.checked_sub(1).map(|at| &entries[at]);
    let right = entries.get(best_k);
    Resolution {
        index,
        group_id: membership(left, right, dragged_min_x - best_edge, current_group, hysteresis)
            .map(str::to_string),
    }
}

/// Positions before a collapsed member are inside a collapsed group.
fn is_valid_position(k: usize, entries: &[Entry]) -> bool {
    entries.get(k).is_none_or(|entry| !entry.is_collapsed)
}

fn membership<'a>(
    left: Option<&'a Entry>,
    right: Option<&Entry>,
    offset: f64,
    current: Option<&str>,
    hysteresis: f64,
) -> Option<&'a str> {
    let left = left?;
    let group = left.group_id.as_deref()?;
    if left.is_group_chip {
        return Some(group);
    }
    if left.is_collapsed {
        return None;
    }
    if let Some(right) = right
        && right.group_id.as_deref() == Some(group)
        && !right.is_group_chip
    {
        return Some(group);
    }
    // The trailing edge of an expanded group: ambiguous, so hysteresis.
    let threshold = if current == Some(group) { hysteresis } else { -hysteresis };
    (offset < threshold).then_some(group)
}

/// A movable unit: an ungrouped tab, or a chip with all its members.
#[derive(Clone, Debug, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Unit {
    pub width: f64,
    pub tab_count: usize,
}

pub fn units(entries: &[Entry]) -> Vec<Unit> {
    let mut units: Vec<Unit> = Vec::new();
    let mut current_group: Option<&str> = None;
    for entry in entries {
        let tabs = usize::from(!entry.is_group_chip);
        let joins = entry.group_id.is_some() && entry.group_id.as_deref() == current_group;
        match units.last_mut() {
            Some(unit) if joins && !entry.is_group_chip => {
                unit.width += entry.width;
                unit.tab_count += tabs;
            }
            _ => {
                units.push(Unit { width: entry.width, tab_count: tabs });
                current_group = entry.group_id.as_deref();
            }
        }
    }
    units
}

/// The insertion index nearest `dragged_min_x` among the edges of widths laid
/// from `group_start` (`TabReorderMath.insertionIndex`).
fn insertion_index(dragged_min_x: f64, group_start: f64, other_widths: &[f64]) -> usize {
    let mut best = 0;
    let mut best_distance = f64::INFINITY;
    let mut edge = group_start;
    for index in 0..=other_widths.len() {
        let distance = (edge - dragged_min_x).abs();
        if distance < best_distance {
            best_distance = distance;
            best = index;
        }
        if index < other_widths.len() {
            edge += other_widths[index];
        }
    }
    best
}

/// The unit index for a whole group whose leading edge is at
/// `dragged_min_x`, and the matching tab insertion index among the entries' tabs.
pub fn resolve_group(entries: &[Entry], start: f64, dragged_min_x: f64) -> (usize, usize) {
    let units = units(entries);
    let widths: Vec<f64> = units.iter().map(|unit| unit.width).collect();
    let unit_index = insertion_index(dragged_min_x, start, &widths);
    (unit_index, units[..unit_index].iter().map(|unit| unit.tab_count).sum())
}

#[cfg(test)]
#[path = "tabs_group_drop_tests.rs"]
mod tests;
