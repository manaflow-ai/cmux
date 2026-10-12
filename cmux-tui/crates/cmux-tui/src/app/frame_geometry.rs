//! Frame geometry: rail width clamping, the sidebar layout for a frame, rail
//! drag widths, content sizes, minimum tabbed heights for split ratios, and
//! pane parts for a rect.

use std::collections::{HashMap, HashSet};

use cmux_tui_core::{Node, Rect, SplitDir, SplitId, split_sides};

use crate::app::layout::{RailKind, RailPlacement, SidebarLayout};
use crate::app::pane_projection::PaneParts;
use crate::config::{Config, ScrollbarPosition, SidebarColumnKind, SidebarResourceKind};

pub(super) const MIN_RAIL_WIDTH: u16 = 10;
pub(super) const MIN_CONTENT_WIDTH: u16 = 40;
pub(super) const MIN_TABBED_PANE_HEIGHT: u16 = 3;
pub(super) const RAIL_REVEAL_HYSTERESIS: u16 = 4;

#[derive(Clone, Copy, Default)]
pub(super) struct SidebarWidthOverrides {
    pub(super) workspace: Option<u16>,
    pub(super) machine: Option<u16>,
    pub(super) tabs: Option<u16>,
}

pub(super) fn clamp_rail_width(desired: u16, configured_max: u16, available: u16) -> Option<u16> {
    let configured_max = if configured_max > 0 { configured_max } else { u16::MAX };
    let effective_max = available.min(configured_max);
    // `then_some` evaluates eagerly and would clamp with min > max while the
    // outer terminal is still publishing its initial zero-width geometry.
    (effective_max >= MIN_RAIL_WIDTH).then(|| desired.clamp(MIN_RAIL_WIDTH, effective_max))
}

pub(super) fn sidebar_layout_for(
    config: &Config,
    visible: bool,
    compact: bool,
    machine_visible: bool,
    size: (u16, u16),
    overrides: SidebarWidthOverrides,
) -> SidebarLayout {
    sidebar_layout_for_state(
        config,
        visible,
        compact,
        machine_visible,
        size,
        overrides.workspace,
        overrides.machine,
        overrides.tabs,
        &HashMap::new(),
        &HashSet::new(),
        None,
    )
}

#[allow(clippy::too_many_arguments)]
pub(super) fn sidebar_layout_for_state(
    config: &Config,
    visible: bool,
    compact: bool,
    machine_visible: bool,
    size: (u16, u16),
    workspace_override: Option<u16>,
    machine_override: Option<u16>,
    tabs_override: Option<u16>,
    projection_overrides: &HashMap<String, u16>,
    hidden_views: &HashSet<String>,
    previous: Option<&SidebarLayout>,
) -> SidebarLayout {
    let (width, height) = size;
    // The bottom row belongs to the screens status bar unless the user
    // hides it; a hidden bar gives the row back to the panes.
    let content_height = if config.status_bar.visible { height.saturating_sub(1) } else { height };
    if !visible {
        return SidebarLayout {
            content: Rect { x: 0, y: 0, width, height: content_height },
            ..SidebarLayout::default()
        };
    }

    #[derive(Clone, Copy)]
    struct Spec {
        kind: RailKind,
        view_index: usize,
        desired: u16,
        max_width: u16,
        priority: u16,
        collapsed: bool,
    }

    let mut specs = config
        .sidebar
        .views
        .iter()
        .enumerate()
        .filter_map(|(view_index, view)| {
            if hidden_views.contains(&view.id) {
                return None;
            }
            if view.includes(SidebarResourceKind::Machines) && !machine_visible {
                return None;
            }
            let kind = match view.legacy_kind() {
                Some(SidebarColumnKind::Machines) => RailKind::Machine,
                Some(SidebarColumnKind::Workspaces) => RailKind::Workspace,
                Some(SidebarColumnKind::Tabs) => RailKind::Tabs,
                None => RailKind::Projection(view_index),
            };
            let width_override = match kind {
                RailKind::Machine => machine_override,
                RailKind::Workspace => workspace_override,
                RailKind::Tabs => tabs_override,
                RailKind::Projection(_) => projection_overrides.get(&view.id).copied(),
            };
            let legacy_width = match kind {
                RailKind::Machine => config.machine_sidebar.width,
                RailKind::Workspace => config.sidebar.width,
                RailKind::Tabs | RailKind::Projection(_) => view.width,
            };
            let desired = if compact && kind == RailKind::Workspace {
                config.sidebar.compact_width
            } else {
                width_override.unwrap_or(if config.sidebar.views_explicit {
                    view.width
                } else {
                    legacy_width
                })
            };
            let max_width = if config.sidebar.views_explicit {
                view.max_width
            } else {
                match kind {
                    RailKind::Machine => config.machine_sidebar.max_width,
                    RailKind::Workspace => config.sidebar.max_width,
                    RailKind::Tabs | RailKind::Projection(_) => view.max_width,
                }
            };
            Some(Spec {
                kind,
                view_index,
                desired,
                max_width,
                priority: view.collapse_priority,
                collapsed: false,
            })
        })
        .collect::<Vec<_>>();

    // Sort only when a collapse decision is needed. The configured index is a
    // deterministic tie breaker for equal priorities, then a final in-place
    // sort restores configured order before the layout is built. This keeps
    // the normal frame path allocation-free beyond the specs vector itself and
    // bounds collapse selection to O(n log n).
    let needs_width_collapse =
        width < MIN_CONTENT_WIDTH.saturating_add(MIN_RAIL_WIDTH.saturating_mul(specs.len() as u16));
    let needs_hysteresis_collapse = previous.is_some()
        && width
            < MIN_CONTENT_WIDTH
                .saturating_add(MIN_RAIL_WIDTH.saturating_mul(specs.len() as u16))
                .saturating_add(RAIL_REVEAL_HYSTERESIS)
        && previous
            .is_some_and(|previous| specs.iter().any(|spec| previous.rail(spec.kind).is_none()));
    let mut collapsed_count = 0;
    let mut retained_count = specs.len();
    if needs_width_collapse || needs_hysteresis_collapse {
        specs.sort_unstable_by_key(|spec| (spec.priority, spec.view_index));

        while retained_count > 0
            && width
                < MIN_CONTENT_WIDTH
                    .saturating_add(MIN_RAIL_WIDTH.saturating_mul(retained_count as u16))
        {
            specs[collapsed_count].collapsed = true;
            collapsed_count += 1;
            retained_count -= 1;
        }
    }

    if let Some(previous) = previous {
        let mut candidate_index = collapsed_count;
        while width
            < MIN_CONTENT_WIDTH
                .saturating_add(MIN_RAIL_WIDTH.saturating_mul(retained_count as u16))
                .saturating_add(RAIL_REVEAL_HYSTERESIS)
        {
            while candidate_index < specs.len()
                && (specs[candidate_index].collapsed
                    || previous.rail(specs[candidate_index].kind).is_some())
            {
                candidate_index += 1;
            }
            if candidate_index == specs.len() {
                break;
            }
            specs[candidate_index].collapsed = true;
            collapsed_count += 1;
            candidate_index += 1;
            retained_count -= 1;
        }
    }

    if collapsed_count > 0 {
        specs.sort_unstable_by_key(|spec| spec.view_index);
        specs.retain(|spec| !spec.collapsed);
    }

    let mut layout = SidebarLayout::default();
    let mut x = 0u16;
    for (index, spec) in specs.iter().enumerate() {
        let remaining = specs.len().saturating_sub(index + 1) as u16;
        let available = width
            .saturating_sub(MIN_CONTENT_WIDTH)
            .saturating_sub(x)
            .saturating_sub(MIN_RAIL_WIDTH.saturating_mul(remaining));
        let Some(rail_width) = clamp_rail_width(spec.desired, spec.max_width, available) else {
            continue;
        };
        let rect = Rect { x, y: 0, width: rail_width, height };
        match spec.kind {
            RailKind::Machine => layout.machine = Some(rect),
            RailKind::Workspace => layout.workspace = Some(rect),
            RailKind::Tabs => layout.tabs = Some(rect),
            RailKind::Projection(_) => {}
        }
        layout.ordered.push(RailPlacement { kind: spec.kind, view_index: spec.view_index, rect });
        x = x.saturating_add(rail_width);
    }
    layout.content = Rect { x, y: 0, width: width.saturating_sub(x), height: content_height };
    layout
}

pub(super) fn rail_drag_width(
    config: &Config,
    layout: &SidebarLayout,
    kind: RailKind,
    x: u16,
) -> Option<u16> {
    let rail = layout.rail(kind)?;
    let terminal_width = layout.content.x.saturating_add(layout.content.width);
    let other_width = layout
        .ordered
        .iter()
        .filter(|placement| placement.kind != kind)
        .map(|placement| placement.rect.width)
        .fold(0u16, u16::saturating_add);
    let available = terminal_width.saturating_sub(MIN_CONTENT_WIDTH).saturating_sub(other_width);
    let view_index = layout.ordered.iter().find(|placement| placement.kind == kind)?.view_index;
    let view = config.sidebar.views.get(view_index)?;
    let configured_max = if config.sidebar.views_explicit {
        view.max_width
    } else {
        match kind {
            RailKind::Machine => config.machine_sidebar.max_width,
            RailKind::Workspace => config.sidebar.max_width,
            RailKind::Tabs | RailKind::Projection(_) => view.max_width,
        }
    };
    let desired = x.saturating_sub(rail.x).saturating_add(1);
    clamp_rail_width(desired, configured_max, available)
}

pub(super) fn content_size_for_rect(
    rect: Rect,
    scrollbar: ScrollbarPosition,
    padding: u16,
) -> Option<(u16, u16)> {
    let (_, _, content, _) = pane_parts_for_rect(rect, scrollbar, padding, false);
    (content.width > 0 && content.height > 0).then_some((content.width, content.height))
}

pub(super) fn browser_content_size_for_rect(
    rect: Rect,
    scrollbar: ScrollbarPosition,
    padding: u16,
) -> Option<(u16, u16)> {
    let (_, _, content, _) = pane_parts_for_rect(rect, scrollbar, padding, true);
    (content.width > 0 && content.height > 0).then_some((content.width, content.height))
}

#[derive(Clone, Copy)]
pub(super) struct SubtreeMinimumHeight {
    full: u16,
    bar_only: u16,
}

pub(super) fn minimum_tabbed_height(node: &Node) -> SubtreeMinimumHeight {
    match node {
        Node::Leaf(_) => SubtreeMinimumHeight { full: MIN_TABBED_PANE_HEIGHT, bar_only: 1 },
        Node::Split { dir: SplitDir::Right, a, b, .. } => {
            let first = minimum_tabbed_height(a);
            let second = minimum_tabbed_height(b);
            SubtreeMinimumHeight {
                full: first.full.max(second.full),
                bar_only: first.bar_only.max(second.bar_only),
            }
        }
        Node::Split { dir: SplitDir::Down, ratio, a, b, .. } => {
            let first = minimum_tabbed_height(a);
            let second = minimum_tabbed_height(b);
            SubtreeMinimumHeight {
                full: minimum_split_height(*ratio, first.full, second.full),
                bar_only: minimum_split_height(*ratio, first.bar_only, second.bar_only),
            }
        }
        Node::Stack { panes, .. } => {
            let collapsed_headers =
                u16::try_from(panes.len().saturating_sub(1)).unwrap_or(u16::MAX);
            SubtreeMinimumHeight {
                full: MIN_TABBED_PANE_HEIGHT.saturating_add(collapsed_headers),
                bar_only: 1u16.saturating_add(collapsed_headers),
            }
        }
    }
}

pub(super) fn minimum_split_height(ratio: f32, first_minimum: u16, second_minimum: u16) -> u16 {
    let fits = |height| {
        let (first, second) =
            split_sides(Rect { width: 1, height, ..Rect::default() }, SplitDir::Down, ratio);
        first.height >= first_minimum && second.height >= second_minimum
    };
    if !fits(u16::MAX) {
        return u16::MAX;
    }

    let mut low = first_minimum.saturating_add(second_minimum).max(2);
    let mut high = u16::MAX;
    while low < high {
        let middle = low + (high - low) / 2;
        if fits(middle) {
            high = middle;
        } else {
            low = middle + 1;
        }
    }
    low
}

pub(super) fn vertical_split_minimum_heights(
    node: &Node,
    target: SplitId,
) -> Option<(SubtreeMinimumHeight, SubtreeMinimumHeight)> {
    match node {
        Node::Leaf(_) | Node::Stack { .. } => None,
        Node::Split { id, dir, a, b, .. } if *id == target => {
            (*dir == SplitDir::Down).then(|| (minimum_tabbed_height(a), minimum_tabbed_height(b)))
        }
        Node::Split { a, b, .. } => vertical_split_minimum_heights(a, target)
            .or_else(|| vertical_split_minimum_heights(b, target)),
    }
}

pub(super) fn clamp_ratio_to_minimum_heights(
    height: u16,
    requested: f32,
    first_minimum: u16,
    second_minimum: u16,
) -> Option<f32> {
    let minimum = (f32::from(first_minimum) / f32::from(height)).max(0.05);
    let maximum = (f32::from(height.saturating_sub(second_minimum)) / f32::from(height)).min(0.95);
    (minimum <= maximum).then(|| requested.clamp(minimum, maximum))
}

pub(super) fn clamp_split_ratio_for_tab_bars(
    root: &Node,
    split: SplitId,
    height: u16,
    requested: f32,
) -> f32 {
    let requested = requested.clamp(0.05, 0.95);
    let Some((first_minimum, second_minimum)) = vertical_split_minimum_heights(root, split) else {
        return requested;
    };
    if height == 0 {
        return requested;
    }

    if let Some(clamped) =
        clamp_ratio_to_minimum_heights(height, requested, first_minimum.full, second_minimum.full)
    {
        return clamped;
    }
    clamp_ratio_to_minimum_heights(
        height,
        requested,
        first_minimum.bar_only,
        second_minimum.bar_only,
    )
    .unwrap_or(requested)
}

pub(super) fn pane_parts_for_rect(
    rect: Rect,
    scrollbar: ScrollbarPosition,
    padding: u16,
    browser_omnibar: bool,
) -> PaneParts<Rect> {
    let (bar, mut content, track) = if rect.width > 2 && rect.height > 2 {
        let reserved_cols = match scrollbar {
            ScrollbarPosition::Column => 3,
            ScrollbarPosition::Border => 2,
        };
        let right_border_x = rect.x + rect.width - 1;
        let track_x = match scrollbar {
            ScrollbarPosition::Column => right_border_x.saturating_sub(1),
            ScrollbarPosition::Border => right_border_x,
        };
        (
            Some(Rect { height: 1, ..rect }),
            Rect {
                x: rect.x + 1,
                y: rect.y + 1,
                width: rect.width.saturating_sub(reserved_cols).max(1),
                height: rect.height - 2,
            },
            Some(Rect { x: track_x, y: rect.y + 1, width: 1, height: rect.height - 2 }),
        )
    } else if rect.width > 2 && rect.height > 0 {
        (
            Some(Rect { height: 1, ..rect }),
            Rect { y: rect.y.saturating_add(1), height: 0, ..rect },
            None,
        )
    } else {
        (None, rect, None)
    };
    // Configured padding: blank cells between border and content, applied
    // only while at least one content cell survives on that axis.
    if content.width > 0 && content.height > 0 {
        let pad_x = padding.min(content.width.saturating_sub(1) / 2);
        let pad_y = padding.min(content.height.saturating_sub(1) / 2);
        content.x = content.x.saturating_add(pad_x);
        content.width = content.width.saturating_sub(pad_x.saturating_mul(2)).max(1);
        content.y = content.y.saturating_add(pad_y);
        content.height = content.height.saturating_sub(pad_y.saturating_mul(2)).max(1);
    }
    let omnibar = if browser_omnibar && content.height >= 2 {
        let row = Rect { height: 1, ..content };
        content.y = content.y.saturating_add(1);
        content.height = content.height.saturating_sub(1);
        Some(row)
    } else {
        None
    };
    (bar, omnibar, content, track)
}

pub(super) fn stacked_header_parts_for_rect(rect: Rect) -> PaneParts<Rect> {
    (Some(rect), None, Rect { y: rect.y.saturating_add(rect.height), height: 0, ..rect }, None)
}
