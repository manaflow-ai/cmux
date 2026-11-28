//! Drop-target rules: what a drop means, decided once for every shell.
//!
//! These were Swift in the macOS app (`TabReorderMath`, `TabGroupDropMath`,
//! `WorkspaceDragResolver`, `LinkDropPlan`, the Files pane's `DropPolicy`);
//! the app keeps the drag session, the pasteboard and the hit test, sends the
//! facts over the app FFI (`drop_*` ops) and applies the answer.
//!
//! - [`insertion_index`]: where a dragged tab lands among its group's tabs.
//! - [`resolve_tab`], [`units`], [`resolve_group`]: a tab or a whole tab
//!   group over a strip with groups (index and membership, with hysteresis
//!   at a group's trailing edge).
//! - [`workspace_outcome`]: how a sidebar workspace drag ends (a slot, a
//!   group, a merge into a pane, beside the shown workspace, a new window).
//! - [`link_plan`]: what a link dropped on a layout target does.
//! - [`transfer_mode`]: Finder's copy-or-move rule for a file drop.

use serde::{Deserialize, Serialize};

/// The leading edge nearest `dragged_min_x` among `other_widths` laid out
/// from `group_start`: the index the dragged tab lands at.
pub fn insertion_index(dragged_min_x: f64, group_start: f64, other_widths: &[f64]) -> usize {
    let mut best = 0;
    let mut best_distance = f64::INFINITY;
    let mut edge = group_start;
    for index in 0..=other_widths.len() {
        let distance = (edge - dragged_min_x).abs();
        if distance < best_distance {
            best_distance = distance;
            best = index;
        }
        if let Some(width) = other_widths.get(index) {
            edge += width;
        }
    }
    best
}

/// One unpinned strip slot in display order (the dragged item left out).
#[derive(Clone, Debug, Default, PartialEq, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", default)]
pub struct Slot {
    pub width: f64,
    pub group: Option<String>,
    pub is_group_chip: bool,
    pub is_collapsed: bool,
}

/// Where a dragged tab lands relative to groups.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct TabLanding {
    /// Insertion index among the tabs (chips left out).
    pub index: usize,
    /// The group it joins there; none for ungrouped.
    pub group: Option<String>,
}

fn is_valid_position(k: usize, entries: &[Slot]) -> bool {
    entries.get(k).is_none_or(|entry| !entry.is_collapsed)
}

fn membership(
    left: Option<&Slot>,
    right: Option<&Slot>,
    offset: f64,
    current: Option<&str>,
    hysteresis: f64,
) -> Option<String> {
    let left = left?;
    let group = left.group.as_deref()?;
    if left.is_group_chip {
        return Some(group.to_owned());
    }
    if left.is_collapsed {
        return None;
    }
    if let Some(right) = right
        && right.group.as_deref() == Some(group)
        && !right.is_group_chip
    {
        return Some(group.to_owned());
    }
    // The trailing edge of an expanded group is ambiguous: hysteresis keeps the
    // current membership until the probe is past it.
    let threshold = if current == Some(group) { hysteresis } else { -hysteresis };
    (offset < threshold).then(|| group.to_owned())
}

/// Index and membership for a dragged tab probed at `dragged_min_x` (the card's
/// leading edge for a reorder, the pointer for a tab from elsewhere). The
/// nearest valid edge wins; positions inside a collapsed group are never chosen.
pub fn resolve_tab(
    entries: &[Slot],
    start: f64,
    dragged_min_x: f64,
    current_group: Option<&str>,
    hysteresis: f64,
) -> TabLanding {
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
        if let Some(entry) = entries.get(k) {
            edge += entry.width;
        }
    }
    let index = entries.iter().take(best_k).filter(|entry| !entry.is_group_chip).count();
    let left = best_k.checked_sub(1).and_then(|k| entries.get(k));
    let right = entries.get(best_k);
    TabLanding {
        index,
        group: membership(left, right, dragged_min_x - best_edge, current_group, hysteresis),
    }
}

/// A movable unit: an ungrouped tab, or a chip with all its members.
#[derive(Clone, Copy, Debug, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Unit {
    pub width: f64,
    pub tab_count: usize,
}

pub fn units(entries: &[Slot]) -> Vec<Unit> {
    let mut units: Vec<Unit> = Vec::new();
    let mut current: Option<&str> = None;
    for entry in entries {
        let tabs = usize::from(!entry.is_group_chip);
        let joins =
            entry.group.is_some() && entry.group.as_deref() == current && !entry.is_group_chip;
        match units.last_mut() {
            Some(last) if joins => {
                last.width += entry.width;
                last.tab_count += tabs;
            }
            _ => {
                units.push(Unit { width: entry.width, tab_count: tabs });
                current = entry.group.as_deref();
            }
        }
    }
    units
}

/// Where a whole group lands.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct GroupLanding {
    pub unit_index: usize,
    pub tab_index: usize,
}

/// The unit index for a whole group whose leading edge is at `dragged_min_x`,
/// and the matching tab insertion index.
pub fn resolve_group(entries: &[Slot], start: f64, dragged_min_x: f64) -> GroupLanding {
    let units = units(entries);
    let widths: Vec<f64> = units.iter().map(|unit| unit.width).collect();
    let unit_index = insertion_index(dragged_min_x, start, &widths);
    GroupLanding {
        unit_index,
        tab_index: units.iter().take(unit_index).map(|unit| unit.tab_count).sum(),
    }
}

/// A pane edge.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum Edge {
    Left,
    Right,
    Top,
    Bottom,
}

/// What a drop on a pane does (the app's `TabDropKind`): a split on an edge
/// places, anything else merges. Only the edge of a split matters here; the
/// rest of the kind rides along untouched.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PaneHit {
    /// The split edge, when the kind is a new split.
    #[serde(default)]
    pub split_edge: Option<Edge>,
}

/// Where a workspace drag lands inside a window.
#[derive(Clone, Debug, PartialEq, Serialize)]
#[serde(rename_all = "camelCase", tag = "kind")]
pub enum WorkspaceTarget {
    /// The slot of the window's sidebar the app hit.
    Position,
    /// The group header the app hit.
    IntoGroup,
    /// Anywhere else in the window: appended to its sidebar.
    Window,
    /// The pane hit merges the workspace's tabs there.
    Merge,
    /// Beside the shown workspace, on `edge`.
    Beside { edge: Edge },
}

/// What the app's sidebar hit is.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum SidebarHit {
    /// A slot in the window's sidebar.
    Position,
    /// A group header.
    IntoGroup,
    /// The sidebar, onto a workspace: the window as a whole.
    Window,
}

/// The facts of a workspace drag at one pointer position.
#[derive(Clone, Debug, Default, PartialEq, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct WorkspaceDrag {
    /// The frontmost window under the pointer; none outside every window.
    pub window: Option<String>,
    pub sidebar_hit: Option<SidebarHit>,
    pub layout_hit: Option<PaneHit>,
    /// `sidebar.multiView`: a pane edge places the workspace beside the shown one.
    pub places_beside: bool,
    pub source_window: Option<String>,
    pub dragging_all_of_source: bool,
    /// The drag carries a whole workspace group.
    pub is_group: bool,
    /// The shown workspace's edge near the pointer.
    pub beside_edge: Option<Edge>,
}

/// How a workspace drag ends.
#[derive(Clone, Debug, PartialEq, Serialize)]
#[serde(rename_all = "camelCase", tag = "outcome")]
pub enum WorkspaceOutcome {
    Window {
        id: String,
        target: WorkspaceTarget,
    },
    /// Released outside every window: a new window under the pointer.
    NewWindow,
    /// Released outside every window with every workspace of its window: that window moves.
    MoveWindow,
    Cancel,
}

fn pane_target(hit: &PaneHit, places_beside: bool) -> WorkspaceTarget {
    match hit.split_edge {
        Some(edge) if places_beside => WorkspaceTarget::Beside { edge },
        _ => WorkspaceTarget::Merge,
    }
}

/// How a sidebar workspace drag ends.
pub fn workspace_outcome(drag: &WorkspaceDrag) -> WorkspaceOutcome {
    let Some(window) = &drag.window else {
        return if drag.dragging_all_of_source {
            WorkspaceOutcome::MoveWindow
        } else {
            WorkspaceOutcome::NewWindow
        };
    };
    // A group keeps its members together: it joins the window as a whole.
    let beside = drag
        .beside_edge
        .filter(|_| drag.places_beside)
        .map(|edge| WorkspaceTarget::Beside { edge });
    let sidebar = drag.sidebar_hit.map(|hit| match hit {
        SidebarHit::Position => WorkspaceTarget::Position,
        SidebarHit::IntoGroup => WorkspaceTarget::IntoGroup,
        SidebarHit::Window => WorkspaceTarget::Window,
    });
    let target = if drag.is_group {
        WorkspaceTarget::Window
    } else {
        sidebar
            .or_else(|| drag.layout_hit.as_ref().map(|hit| pane_target(hit, drag.places_beside)))
            .or(beside)
            .unwrap_or(WorkspaceTarget::Window)
    };
    if drag.source_window.as_deref() == Some(window.as_str()) {
        // Back home: only a sidebar slot (a reorder) or a pane means something.
        match target {
            WorkspaceTarget::Position | WorkspaceTarget::Merge | WorkspaceTarget::Beside { .. } => {
            }
            WorkspaceTarget::IntoGroup | WorkspaceTarget::Window => {
                return WorkspaceOutcome::Cancel;
            }
        }
    }
    WorkspaceOutcome::Window { id: window.clone(), target }
}

/// A layout drop target (the app's `LayoutDropTarget`), by kind.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum LayoutTarget {
    PaneCenter,
    PaneEdge(Edge),
    NewColumn,
    NewDock,
}

/// What a link dropped on a layout target does.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase", tag = "plan")]
pub enum LinkPlan {
    /// A new tab in the pane, selected.
    Tab,
    /// A new split of the pane on `edge`.
    Split { edge: Edge },
    /// A new column where the target says.
    Column,
    /// A new dock band where the target says.
    Dock,
    /// Refused: the center of a pane that takes no tabs (the pinned Home column).
    Refused,
}

/// The plan for a link dropped on `target`; `takes_tabs` says whether the pane
/// can hold a new tab.
pub fn link_plan(target: LayoutTarget, takes_tabs: bool) -> LinkPlan {
    match target {
        LayoutTarget::PaneCenter if takes_tabs => LinkPlan::Tab,
        LayoutTarget::PaneCenter => LinkPlan::Refused,
        LayoutTarget::PaneEdge(edge) => LinkPlan::Split { edge },
        LayoutTarget::NewColumn => LinkPlan::Column,
        LayoutTarget::NewDock => LinkPlan::Dock,
    }
}

/// Copy or move.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum TransferMode {
    Copy,
    Move,
}

/// Finder's rule: Option copies, Command moves; else the same volume moves and
/// another (or an unknown one) copies. Volumes are device ids; none is unknown.
pub fn transfer_mode(
    sources: &[Option<i64>],
    destination: Option<i64>,
    option: bool,
    command: bool,
) -> TransferMode {
    if option {
        return TransferMode::Copy;
    }
    if command {
        return TransferMode::Move;
    }
    let Some(target) = destination else { return TransferMode::Copy };
    if sources.iter().all(|volume| *volume == Some(target)) {
        TransferMode::Move
    } else {
        TransferMode::Copy
    }
}

#[cfg(test)]
#[path = "drop_rules_tests.rs"]
mod tests;
