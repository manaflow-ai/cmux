//! Scrollbars and split resize: tab strip scrolling, pane and workspace
//! scrollbar drags, keyboard split resize, and pane resize drag targets.

use cmux_tui_core::{
    MAX_VIEWPORT_PANE_WIDTH, MIN_VIEWPORT_PANE_WIDTH, PaneId, Rect, SplitEdge, SurfaceId,
    ViewportColumn, exact_split_for_pane_edge, exact_split_for_pane_edge_with_viewport,
    layout_screen_with_viewport,
};
use ghostty_vt::Scrollbar;

use crate::app::App;
use crate::app::frame_geometry::clamp_split_ratio_for_tab_bars;
use crate::app::layout::{Hit, PaneEdge};
use crate::app::pointer::{Drag, PaneResizeDragTarget, ScrollbarDragState};
use crate::ui::{thumb_geometry, viewport_jump_offset, viewport_thumb_geometry};

impl App {
    /// Shift a pane's tab bar left/right. The renderer clamps to the
    /// valid range next frame.
    pub(super) fn scroll_tabs(&mut self, pane: PaneId, delta: isize) {
        let entry = self.tab_scroll.entry(pane).or_insert(0);
        *entry = entry.saturating_add_signed(delta);
    }

    /// Start a scrollbar drag. Clicking the thumb only anchors; clicking
    /// outside it jumps first, then anchors at the clicked position.
    pub(super) fn start_scrollbar_drag(
        &mut self,
        surface: SurfaceId,
        track: Rect,
        scrollbar: Scrollbar,
        y: u16,
    ) {
        let Some(handle) = self.session.surface(surface) else { return };
        let rel_y = y.saturating_sub(track.y).min(track.height.saturating_sub(1));
        let (thumb_y, thumb_len) = thumb_geometry(&scrollbar, track.height);
        let on_thumb = rel_y >= thumb_y && rel_y < thumb_y + thumb_len;
        let target = if on_thumb {
            scrollbar.offset
        } else {
            let denom = track.height.saturating_sub(1).max(1) as f64;
            let frac = (rel_y as f64 / denom).clamp(0.0, 1.0);
            ((scrollbar.total - scrollbar.len) as f64 * frac).round() as u64
        };
        let delta = (target as i128 - scrollbar.offset as i128)
            .clamp(isize::MIN as i128, isize::MAX as i128) as isize;
        let Some(scrollbar) = handle.scroll_delta_if_scrollbar(scrollbar, delta) else {
            return;
        };
        self.drag = Some(Drag::Scrollbar {
            surface,
            track,
            anchor_y: y,
            anchor_offset: scrollbar.offset,
            position_y: y,
            scrollbar,
        });
    }

    pub(super) fn rendered_scrollbar(&self, surface: SurfaceId) -> Option<(Rect, Scrollbar)> {
        self.rendered_pointer_frame.hits.iter().find_map(|route| match route.hit {
            Hit::Scrollbar { surface: candidate, track, scrollbar } if candidate == surface => {
                Some((track, scrollbar))
            }
            _ => None,
        })
    }

    /// Start a workspace viewport scrollbar drag, jumping on track clicks.
    pub(super) fn start_workspace_scrollbar_drag(
        &mut self,
        track: Rect,
        total_rows: usize,
        visible_rows: usize,
        y: u16,
    ) {
        if track.height == 0 {
            return;
        }
        let relative = y.saturating_sub(track.y).min(track.height.saturating_sub(1));
        let (thumb_y, thumb_height) = viewport_thumb_geometry(
            total_rows,
            visible_rows,
            self.workspace_rail_scroll,
            track.height,
        );
        if relative < thumb_y || relative >= thumb_y.saturating_add(thumb_height) {
            self.workspace_rail_scroll =
                viewport_jump_offset(total_rows, visible_rows, track.height, relative);
        }
        self.drag = Some(Drag::WorkspaceScrollbar {
            track,
            total_rows,
            visible_rows,
            anchor_y: y,
            anchor_offset: self.workspace_rail_scroll,
        });
    }

    /// Map an anchored scrollbar drag delta to a viewport offset.
    pub(super) fn drag_scrollbar(
        &mut self,
        surface: SurfaceId,
        state: ScrollbarDragState,
        rendered: (Rect, Scrollbar),
        y: u16,
    ) -> Option<ScrollbarDragState> {
        let handle = self.session.surface(surface)?;
        let (rendered_track, rendered_scrollbar) = rendered;
        let drag_delta = |track: Rect, anchor_y: u16, anchor_offset: u64, state: Scrollbar| {
            let (_, thumb_len) = thumb_geometry(&state, track.height);
            let range = state.total.saturating_sub(state.len);
            let travel = track.height.saturating_sub(thumb_len).max(1) as i128;
            let dy = y as i128 - anchor_y as i128;
            let delta = dy * range as i128 / travel;
            let target = (anchor_offset as i128 + delta).clamp(0, range as i128);
            (target - state.offset as i128).clamp(isize::MIN as i128, isize::MAX as i128) as isize
        };

        if state.track == rendered_track {
            let delta =
                drag_delta(state.track, state.anchor_y, state.anchor_offset, state.scrollbar);
            if let Some(updated) = handle.scroll_delta_if_scrollbar(state.scrollbar, delta) {
                return Some(ScrollbarDragState { position_y: y, scrollbar: updated, ..state });
            }
        }

        let anchor_y = state.position_y;
        let anchor_offset = rendered_scrollbar.offset;
        let delta = drag_delta(rendered_track, anchor_y, anchor_offset, rendered_scrollbar);
        handle.scroll_delta_if_scrollbar(rendered_scrollbar, delta).map(|updated| {
            ScrollbarDragState {
                track: rendered_track,
                anchor_y,
                anchor_offset,
                position_y: y,
                scrollbar: updated,
            }
        })
    }

    pub(super) fn resize_focused_split(&mut self, delta: f32) {
        let Some(pane) = self.active_pane() else { return };
        let Some(screen) = self.tree.active_screen() else { return };
        if screen.zoomed_pane.is_none()
            && !screen.viewport_splits.is_empty()
            && let Some(owner) = screen.layout.viewport_column_owner(pane, &screen.viewport_splits)
        {
            let current = match owner {
                ViewportColumn::Base => screen.viewport_base_width.unwrap_or(1.0),
                ViewportColumn::Split(split) => {
                    let Some(width) = screen.viewport_splits.get(&split).copied() else {
                        return;
                    };
                    width
                }
            };
            let width = (current + delta).clamp(MIN_VIEWPORT_PANE_WIDTH, MAX_VIEWPORT_PANE_WIDTH);
            if (width - current).abs() >= f32::EPSILON && self.prepare_pty_input_before_mutation() {
                self.session.set_viewport_pane_width(pane, width);
            }
            return;
        }
        let Some(area) = self.pane_areas.iter().find(|area| area.pane == pane) else {
            return;
        };
        let candidates = [
            (SplitEdge::Right, PaneEdge::Right),
            (SplitEdge::Left, PaneEdge::Left),
            (SplitEdge::Bottom, PaneEdge::Bottom),
            (SplitEdge::Top, PaneEdge::Top),
        ];
        let Some((edge, target)) = candidates
            .into_iter()
            .filter_map(|(split_edge, pane_edge)| {
                if screen.viewport_splits.is_empty() {
                    exact_split_for_pane_edge(
                        &screen.layout,
                        self.content_area,
                        Some(screen.active_pane),
                        pane,
                        split_edge,
                    )
                    .map(Into::into)
                } else {
                    exact_split_for_pane_edge_with_viewport(
                        &screen.layout,
                        self.content_area,
                        Some(screen.active_pane),
                        pane,
                        split_edge,
                        screen.viewport_base_width.unwrap_or(1.0),
                        &screen.viewport_splits,
                    )
                }
                .map(|target| (pane_edge, target))
            })
            .filter(|(_, target)| !screen.viewport_splits.contains_key(&target.split))
            .min_by_key(|(_, target)| {
                u128::from(target.area.width) * u128::from(target.area.height)
            })
        else {
            return;
        };
        let pane_rect = self
            .viewport_layout
            .iter()
            .find(|(candidate, _)| *candidate == pane)
            .map_or_else(|| area.rect.into(), |(_, rect)| *rect);
        let (current, sign) = match edge {
            PaneEdge::Left => (
                (pane_rect.x.saturating_sub(target.area.x)) as f32
                    / target.area.width.max(1) as f32,
                -1.0,
            ),
            PaneEdge::Right => (
                (pane_rect.x + pane_rect.width).saturating_sub(target.area.x) as f32
                    / target.area.width.max(1) as f32,
                1.0,
            ),
            PaneEdge::Top => (
                f32::from(pane_rect.y.saturating_sub(target.area.y))
                    / f32::from(target.area.height.max(1)),
                -1.0,
            ),
            PaneEdge::Bottom => (
                f32::from(
                    pane_rect.y.saturating_add(pane_rect.height).saturating_sub(target.area.y),
                ) / f32::from(target.area.height.max(1)),
                1.0,
            ),
        };
        let ratio = clamp_split_ratio_for_tab_bars(
            &screen.layout,
            target.split,
            target.area.height,
            current + delta * sign,
        );
        if self.prepare_pty_input_before_mutation() {
            self.session.set_split_ratio(target.split, ratio);
        }
    }

    pub(super) fn resolve_pane_resize_drag(
        &self,
        pane: PaneId,
        edge: PaneEdge,
    ) -> Option<PaneResizeDragTarget> {
        if self.content_area.width == 0 {
            return None;
        }
        let screen = self.tree.active_screen()?;
        if screen.zoomed_pane.is_none()
            && !screen.viewport_splits.is_empty()
            && matches!(edge, PaneEdge::Left | PaneEdge::Right)
        {
            let layout = layout_screen_with_viewport(
                &screen.layout,
                self.content_area,
                Some(screen.active_pane),
                screen.viewport_base_width.unwrap_or(1.0),
                &screen.viewport_splits,
            );
            let pane_rect = layout.rect_of(pane)?;
            let pane_right = pane_rect.x.saturating_add(pane_rect.width);
            let index = layout.columns.iter().position(|column| {
                pane_rect.width > 0
                    && pane_rect.x >= column.rect.x
                    && pane_right <= column.rect.x.saturating_add(column.rect.width)
            })?;
            let current = layout.columns[index];
            let target = match edge {
                PaneEdge::Right
                    if pane_right == current.rect.x.saturating_add(current.rect.width) =>
                {
                    Some(current)
                }
                PaneEdge::Left if pane_rect.x == current.rect.x && index > 0 => {
                    Some(layout.columns[index - 1])
                }
                _ => None,
            };
            if let Some(column) = target {
                return Some(PaneResizeDragTarget::ViewportColumn {
                    pane: column.representative,
                    edge,
                    column_x: column.rect.x,
                    viewport_x: self.content_area.x,
                    viewport_width: self.content_area.width,
                    viewport_offset: self.viewport_offset,
                });
            }
        }
        let split_edge = match edge {
            PaneEdge::Left => SplitEdge::Left,
            PaneEdge::Right => SplitEdge::Right,
            PaneEdge::Top => SplitEdge::Top,
            PaneEdge::Bottom => SplitEdge::Bottom,
        };
        let target = if screen.viewport_splits.is_empty() {
            exact_split_for_pane_edge(
                &screen.layout,
                self.content_area,
                Some(screen.active_pane),
                pane,
                split_edge,
            )
            .map(Into::into)
        } else {
            exact_split_for_pane_edge_with_viewport(
                &screen.layout,
                self.content_area,
                Some(screen.active_pane),
                pane,
                split_edge,
                screen.viewport_base_width.unwrap_or(1.0),
                &screen.viewport_splits,
            )
        };
        let target = target?;
        if screen.viewport_splits.contains_key(&target.split) {
            return None;
        }
        let minimum_ratio =
            clamp_split_ratio_for_tab_bars(&screen.layout, target.split, target.area.height, 0.0);
        let maximum_ratio =
            clamp_split_ratio_for_tab_bars(&screen.layout, target.split, target.area.height, 1.0);
        Some(PaneResizeDragTarget::Split {
            split: target.split,
            edge,
            area: target.area,
            minimum_ratio,
            maximum_ratio,
            viewport_x: self.content_area.x,
            viewport_offset: self.viewport_offset,
        })
    }

    pub(super) fn resize_drag_target(&mut self, target: PaneResizeDragTarget, x: u16, y: u16) {
        match target {
            PaneResizeDragTarget::ViewportColumn {
                pane,
                edge,
                column_x,
                viewport_x,
                viewport_width,
                viewport_offset,
            } => {
                let virtual_x = u64::from(viewport_x)
                    .saturating_add(viewport_offset)
                    .saturating_add(u64::from(x.saturating_sub(viewport_x)));
                let boundary =
                    if edge == PaneEdge::Right { virtual_x.saturating_add(1) } else { virtual_x };
                let cells = boundary.saturating_sub(column_x);
                let width = (((cells as f64) / f64::from(viewport_width)) as f32)
                    .clamp(MIN_VIEWPORT_PANE_WIDTH, MAX_VIEWPORT_PANE_WIDTH);
                if self.prepare_pty_input_before_mutation() {
                    self.session.set_viewport_pane_width_deferred(pane, width);
                }
            }
            PaneResizeDragTarget::Split {
                split,
                edge,
                area,
                minimum_ratio,
                maximum_ratio,
                viewport_x,
                viewport_offset,
            } => {
                let virtual_x = u64::from(viewport_x)
                    .saturating_add(viewport_offset)
                    .saturating_add(u64::from(x.saturating_sub(viewport_x)));
                let (coord, start, extent) = match edge {
                    PaneEdge::Left => (virtual_x, area.x, area.width),
                    PaneEdge::Right => (virtual_x.saturating_add(1), area.x, area.width),
                    PaneEdge::Top => (u64::from(y), u64::from(area.y), u64::from(area.height)),
                    PaneEdge::Bottom => {
                        (u64::from(y.saturating_add(1)), u64::from(area.y), u64::from(area.height))
                    }
                };
                if extent == 0 {
                    return;
                }
                let requested = (coord.saturating_sub(start) as f64 / extent as f64) as f32;
                let ratio = requested.clamp(minimum_ratio, maximum_ratio);
                if self.prepare_pty_input_before_mutation() {
                    self.session.set_split_ratio_deferred(split, ratio);
                }
            }
        }
    }
}
