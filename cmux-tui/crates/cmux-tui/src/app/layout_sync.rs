//! Layout sync: viewport animation and motion, `sync_layout` (tree to pane
//! areas and sizes), and the sidebar plugin surface sync and retry.

use std::collections::HashSet;
use std::time::{Duration, Instant};

use cmux_tui_core::{
    Node, PaneId, Rect, ScreenId, SurfaceKind, ViewportLayoutResult, VirtualRect, layout_screen,
    layout_screen_with_viewport,
};

use crate::app::frame_geometry::sidebar_layout_for_state;
use crate::app::layout::{FocusTarget, RailKind, SidebarLayout, first_pane_by_id};
use crate::app::pane_projection::{
    PaneAreaProjection, rebuild_pane_areas, swept_viewport_size_leases, visible_pane_size_leases,
};
use crate::app::pointer::Drag;
use crate::app::surface_sync::SurfaceResizeDecision;
use crate::app::viewport::{ViewportGeometry, ViewportMotion};
use crate::app::{App, RenderAction};
use crate::session::SidebarPluginSurface;

impl App {
    pub(super) fn viewport_animation_active(&self) -> bool {
        self.config.viewport.animation
            && self
                .active_screen_id()
                .and_then(|screen| self.viewport_states.get(&screen))
                .is_some_and(ViewportMotion::animating)
    }

    pub(super) fn advance_viewport_animation(&mut self, now: Instant) -> RenderAction {
        if !self.config.viewport.animation {
            return RenderAction::None;
        }
        let Some(screen) = self.active_screen_id() else {
            return RenderAction::None;
        };
        let maximum =
            self.viewport_virtual_width.saturating_sub(u64::from(self.content_area.width));
        let (offset, settled) = {
            let Some(motion) = self.viewport_states.get_mut(&screen) else {
                return RenderAction::None;
            };
            let was_animating = motion.animating();
            let _ = motion.update(now);
            (motion.offset().min(maximum), was_animating && !motion.animating())
        };
        if offset == self.viewport_offset {
            return if settled { RenderAction::Draw } else { RenderAction::None };
        }
        self.viewport_offset = offset;
        self.reclip_viewport_panes();
        if settled { RenderAction::Draw } else { RenderAction::Paint }
    }

    pub(super) fn reclip_viewport_panes(&mut self) {
        if self.viewport_layout.is_empty() {
            return;
        }
        let Some(screen) = self.tree.active_screen() else {
            self.pane_areas.clear();
            self.viewport_projection.clear();
            return;
        };
        if !self.viewport_projection.is_for_screen(screen.id) {
            self.viewport_projection.rebuild(PaneAreaProjection {
                screen,
                layout: &self.viewport_layout,
                stacked_headers: &self.viewport_stacked_headers,
                area: self.content_area,
                scrollbar_position: self.config.scrollbar.position,
                pane_padding: self.config.pane.padding,
                surface_only: self.surface_only,
                viewport_offset: Some(self.viewport_offset),
            });
        }
        self.viewport_projection.project_into(
            &mut self.pane_areas,
            self.content_area,
            self.viewport_offset,
        );
    }

    pub(super) fn sync_viewport_motion(
        &mut self,
        screen: ScreenId,
        active_pane: PaneId,
        active_rect: Option<VirtualRect>,
        area: Rect,
        virtual_width: u64,
        now: Instant,
    ) -> u64 {
        let maximum = virtual_width.saturating_sub(u64::from(area.width));
        let animate = self.config.viewport.animation;
        let motion = self.viewport_states.entry(screen).or_insert_with(|| ViewportMotion::new(now));
        let geometry = ViewportGeometry {
            active_span: active_rect.map(|rect| (rect.x, rect.width)),
            viewport_x: u64::from(area.x),
            viewport_width: area.width,
            virtual_width,
        };
        let reveal_active =
            motion.last_active_pane != Some(active_pane) || motion.last_geometry != Some(geometry);
        let mut target = (motion.target.round() as u64).min(maximum);
        if reveal_active && let Some(rect) = active_rect {
            let left = rect.x.saturating_sub(u64::from(area.x));
            let right = left.saturating_add(rect.width);
            if left < target {
                target = left;
            } else if right > target.saturating_add(u64::from(area.width)) {
                target = right.saturating_sub(u64::from(area.width));
            }
        }
        motion.retarget(target.min(maximum), animate, now);
        motion.last_active_pane = Some(active_pane);
        motion.last_geometry = Some(geometry);
        motion.offset().min(maximum)
    }

    pub(super) fn set_viewport_target(&mut self, target: u64, animate: bool) -> bool {
        let Some(screen) = self.active_screen_id() else { return false };
        let maximum =
            self.viewport_virtual_width.saturating_sub(u64::from(self.content_area.width));
        let target = target.min(maximum);
        let now = Instant::now();
        let motion = self.viewport_states.entry(screen).or_insert_with(|| ViewportMotion::new(now));
        let changed = motion.target.round() as u64 != target || motion.offset() != target;
        motion.retarget(target, animate && self.config.viewport.animation, now);
        changed
    }

    /// Refresh the tree snapshot, recompute the active screen's layout
    /// (each pane's border box eats one cell on every side), and push
    /// content sizes to surfaces.
    pub(super) fn sync_layout(&mut self, size: (u16, u16)) {
        let (width, height) = size;
        self.outer_size = size;
        let sidebar_layout = if self.surface_only.is_some() {
            SidebarLayout {
                content: Rect { x: 0, y: 0, width, height },
                ..SidebarLayout::default()
            }
        } else {
            let hidden_views = self
                .hidden_sidebar_views
                .get(&self.config.sidebar.active_profile)
                .cloned()
                .unwrap_or_default();
            let previous =
                (!self.sidebar_layout.ordered.is_empty()).then_some(&self.sidebar_layout);
            sidebar_layout_for_state(
                &self.config,
                self.sidebar_visible,
                self.sidebar_compact,
                self.machine_ui.is_some(),
                size,
                self.sidebar_width_override,
                self.machine_sidebar_width_override,
                self.tabs_sidebar_width_override,
                &self.projection_sidebar_width_overrides,
                &hidden_views,
                previous,
            )
        };
        self.sidebar_layout = sidebar_layout;
        self.sidebar_width = self.sidebar_layout.workspace.map_or(0, |rect| rect.width);
        self.machine_sidebar_width = self.sidebar_layout.machine.map_or(0, |rect| rect.width);
        self.tabs_sidebar_width = self.sidebar_layout.tabs.map_or(0, |rect| rect.width);
        if self.sidebar_width == 0 && self.focus == FocusTarget::WorkspaceRail {
            self.focus = FocusTarget::Pane;
        }
        if self.machine_sidebar_width == 0 && self.focus == FocusTarget::MachineRail {
            self.focus = FocusTarget::Pane;
        }
        if self.tabs_sidebar_width == 0 && self.focus == FocusTarget::TabsRail {
            self.focus = FocusTarget::Pane;
        }
        if let FocusTarget::ProjectionRail(index) = self.focus
            && self.sidebar_layout.rail(RailKind::Projection(index)).is_none()
        {
            self.focus = FocusTarget::Pane;
        }
        let area = self.sidebar_layout.content;
        self.content_area = area;
        if self.surface_only.is_none() {
            let _ = self.sync_sidebar_plugin(false);
        }
        self.replace_tree(self.session.tree());
        self.claim_active_terminal_geometry(false);
        if self.surface_only.is_none() {
            self.sidebar_workspace_selection = self
                .sidebar_workspace_selection
                .min(self.tree.workspaces().len().saturating_sub(1));
            self.sync_sidebar_files_to_focus(false);
        }
        self.pane_areas.clear();
        let Some(screen) = self.tree.active_screen().cloned() else {
            self.viewport_projection.clear();
            self.viewport_layout.clear();
            self.viewport_stacked_headers.clear();
            self.viewport_virtual_width = 0;
            self.viewport_offset = 0;
            let hidden = self
                .visible_size_surfaces
                .difference(&self.pending_size_releases)
                .copied()
                .collect::<Vec<_>>();
            if hidden.is_empty() || self.prepare_pty_input_before_mutation() {
                for surface in hidden {
                    if self.session.release_surface_size(surface) {
                        self.pending_size_releases.insert(surface);
                    }
                }
            }
            return;
        };
        let viewport_enabled = self.surface_only.is_none()
            && screen.zoomed_pane.is_none()
            && !screen.viewport_splits.is_empty();
        let layout: ViewportLayoutResult = if self.surface_only.is_some() {
            layout_screen(&Node::Leaf(screen.active_pane), area, Some(screen.active_pane)).into()
        } else if let Some(pane) = screen.zoomed_pane {
            layout_screen(&Node::Leaf(pane), area, Some(pane)).into()
        } else if viewport_enabled {
            layout_screen_with_viewport(
                &screen.layout,
                area,
                Some(screen.active_pane),
                screen.viewport_base_width.unwrap_or(1.0),
                &screen.viewport_splits,
            )
        } else {
            layout_screen(&screen.layout, area, Some(screen.active_pane)).into()
        };
        let viewport_enabled = viewport_enabled && layout.virtual_width > u64::from(area.width);
        self.viewport_layout = if viewport_enabled { layout.panes.clone() } else { Vec::new() };
        self.viewport_stacked_headers =
            if viewport_enabled { layout.stacked_headers.clone() } else { HashSet::new() };
        self.viewport_virtual_width = layout.virtual_width;
        self.viewport_offset = if viewport_enabled {
            self.sync_viewport_motion(
                screen.id,
                screen.active_pane,
                layout.rect_of(screen.active_pane),
                area,
                layout.virtual_width,
                Instant::now(),
            )
        } else {
            0
        };
        let pane_projection = PaneAreaProjection {
            screen: &screen,
            layout: &layout.panes,
            stacked_headers: &layout.stacked_headers,
            area,
            scrollbar_position: self.config.scrollbar.position,
            pane_padding: self.config.pane.padding,
            surface_only: self.surface_only,
            viewport_offset: viewport_enabled.then_some(self.viewport_offset),
        };
        if viewport_enabled {
            self.viewport_projection.rebuild(pane_projection);
            self.viewport_projection.project_into(&mut self.pane_areas, area, self.viewport_offset);
        } else {
            self.viewport_projection.clear();
            rebuild_pane_areas(&mut self.pane_areas, pane_projection);
        }

        // Size and attach every pane crossed by a short animation up front.
        // Paint-only ticks can then reveal cached surfaces without socket
        // work. Expensive jumps settle immediately and synchronize only the
        // destination viewport instead of saturating the ordered PTY lane.
        let target_offset = viewport_enabled.then(|| {
            let maximum = layout.virtual_width.saturating_sub(u64::from(area.width));
            self.viewport_states
                .get(&screen.id)
                .map_or(self.viewport_offset, |motion| motion.target.round() as u64)
                .min(maximum)
        });
        let size_leases = if let Some(target_offset) =
            target_offset.filter(|target| *target != self.viewport_offset)
        {
            if let Some(leases) = swept_viewport_size_leases(
                PaneAreaProjection {
                    screen: &screen,
                    layout: &layout.panes,
                    stacked_headers: &layout.stacked_headers,
                    area,
                    scrollbar_position: self.config.scrollbar.position,
                    pane_padding: self.config.pane.padding,
                    surface_only: self.surface_only,
                    viewport_offset: Some(self.viewport_offset),
                },
                target_offset,
            ) {
                leases
            } else {
                if let Some(motion) = self.viewport_states.get_mut(&screen.id) {
                    motion.retarget(target_offset, false, Instant::now());
                }
                self.viewport_offset = target_offset;
                self.viewport_projection.project_into(
                    &mut self.pane_areas,
                    area,
                    self.viewport_offset,
                );
                visible_pane_size_leases(&self.pane_areas)
            }
        } else {
            visible_pane_size_leases(&self.pane_areas)
        };

        let visible = size_leases.iter().map(|lease| lease.surface).collect::<HashSet<_>>();
        let hidden = self
            .visible_size_surfaces
            .difference(&visible)
            .filter(|surface| !self.pending_size_releases.contains(surface))
            .copied()
            .collect::<Vec<_>>();
        if !hidden.is_empty() && !self.prepare_pty_input_before_mutation() {
            return;
        }
        for surface in hidden {
            if self.session.release_surface_size(surface) {
                self.pending_size_releases.insert(surface);
            }
        }
        let resurfaced =
            visible.intersection(&self.pending_size_releases).copied().collect::<HashSet<_>>();
        let mut newly_visible =
            visible.difference(&self.visible_size_surfaces).copied().collect::<HashSet<_>>();
        newly_visible.extend(resurfaced.iter().copied());
        self.visible_size_surfaces.extend(visible.iter().copied());

        // Keep inactive tabs attached for instant rendering, but give only
        // active tabs in the swept viewport a sizing lease. The settling draw
        // releases panes outside the final viewport.
        // `ScreenView::pane` performs a linear scan. Build an index once for
        // this active screen so one lease per pane does not turn this loop
        // into quadratic work. `or_insert` preserves `pane`'s first-match
        // behavior if malformed input contains duplicate pane IDs.
        let panes_by_id = first_pane_by_id(&screen.panes);
        for lease in size_leases {
            let Some(pane) = panes_by_id.get(&lease.pane).copied() else { continue };
            let content_size = lease.content_size;
            for tab in &pane.tabs {
                if self.surface_only.is_some_and(|surface| surface != tab.surface) {
                    continue;
                }
                if self.session.has_surface(tab.surface) {
                    continue;
                }
                let size = (tab.surface == lease.surface)
                    .then_some(content_size)
                    .filter(|(cols, rows)| *cols > 0 && *rows > 0);
                if self.session.can_attach_surface(tab.surface)
                    && self.prepare_pty_input_before_mutation()
                {
                    self.session.attach_surface(tab.surface, size);
                }
            }
            let Some(surface) = self.session.surface(lease.surface) else { continue };
            let desired = content_size;
            if surface.kind() == SurfaceKind::Browser
                && self.browser_input.resize_failed(lease.surface, desired)
            {
                continue;
            }
            let needs = newly_visible.contains(&lease.surface)
                || !self.session.has_surface_size_report(lease.surface)
                || surface.resize_needed(content_size.0, content_size.1, false);
            let resize_decision = if resurfaced.contains(&lease.surface) {
                self.session.surface_resize_reclaim_decision(lease.surface, desired)
            } else {
                self.session.surface_resize_decision(lease.surface, desired, needs)
            };
            if let SurfaceResizeDecision::NeedsQueue(claim) = resize_decision
                && self.prepare_pty_input_before_mutation()
            {
                let accepted = if resurfaced.contains(&lease.surface) {
                    self.enqueue_surface_size_reclaim(
                        lease.surface,
                        surface,
                        content_size.0,
                        content_size.1,
                        Some(claim),
                    )
                } else {
                    self.enqueue_surface_resize(
                        lease.surface,
                        surface,
                        content_size.0,
                        content_size.1,
                        false,
                        Some(claim),
                    )
                };
                if accepted && resurfaced.contains(&lease.surface) {
                    self.pending_size_releases.remove(&lease.surface);
                }
            }
        }
    }

    pub fn sidebar_plugin_rect(&self) -> Rect {
        self.workspace_sidebar_area(self.content_area.height.saturating_add(1))
            .map(|area| Rect { width: area.width.saturating_sub(1), ..area })
            .unwrap_or_default()
    }

    pub(super) fn sync_sidebar_plugin(&mut self, relaunch: bool) -> bool {
        if self.config.sidebar.plugin.is_none() {
            self.session.invalidate_sidebar_plugin_sync();
            self.sidebar_plugin_surface = None;
            self.sidebar_plugin_error = None;
            self.sidebar_plugin_retry_after_ms = None;
            self.sidebar_plugin_retry_at = None;
            self.sidebar_focus_pending = false;
            return false;
        }
        if self.sidebar_width < 3 || !self.sidebar_visible {
            self.session.invalidate_sidebar_plugin_sync();
            self.sidebar_plugin_surface = None;
            self.sidebar_plugin_error = None;
            self.sidebar_plugin_retry_after_ms = None;
            self.sidebar_plugin_retry_at = None;
            self.leave_workspace_sidebar();
            self.sidebar_focus_pending = false;
            return false;
        }
        let rect = self.sidebar_plugin_rect();
        if rect.width == 0 || rect.height == 0 {
            return false;
        }
        let terminal_failure =
            self.sidebar_plugin_error.is_some() && self.sidebar_plugin_retry_after_ms.is_none();
        if !relaunch && (self.sidebar_plugin_retry_at.is_some() || terminal_failure) {
            return false;
        }
        if relaunch && !self.prepare_pty_input_before_mutation() {
            return false;
        }
        self.session.sidebar_plugin((rect.width, rect.height), relaunch);
        true
    }

    pub(super) fn retry_sidebar_plugin_if_due(&mut self) {
        if self.sidebar_plugin_retry_at.is_none_or(|retry_at| Instant::now() < retry_at) {
            return;
        }
        if matches!(self.drag, Some(Drag::PtyMouse { .. })) {
            self.sidebar_plugin_retry_at = Some(Instant::now() + Duration::from_millis(250));
            return;
        }
        self.sidebar_plugin_retry_at = None;
        self.sidebar_plugin_retry_after_ms = None;
        if !self.sync_sidebar_plugin(true) {
            self.sidebar_plugin_retry_at = Some(Instant::now() + Duration::from_millis(250));
        }
    }

    pub(super) fn apply_sidebar_plugin_status(
        &mut self,
        status: SidebarPluginSurface,
        relaunch: bool,
    ) {
        if self.config.sidebar.plugin.is_none() {
            self.session.invalidate_sidebar_plugin_sync();
            self.sidebar_plugin_surface = None;
            self.sidebar_plugin_error = None;
            self.sidebar_plugin_retry_after_ms = None;
            self.sidebar_plugin_retry_at = None;
            self.sidebar_focus_pending = false;
            return;
        }
        if !self.sidebar_visible {
            self.session.invalidate_sidebar_plugin_sync();
            self.sidebar_plugin_surface = None;
            self.sidebar_plugin_error = None;
            self.sidebar_plugin_retry_after_ms = None;
            self.sidebar_plugin_retry_at = None;
            self.leave_workspace_sidebar();
            self.sidebar_focus_pending = false;
            return;
        }
        let had_surface = self.sidebar_plugin_surface.is_some();
        self.sidebar_plugin_surface = status.surface_id;
        self.sidebar_plugin_error = status.error;
        self.sidebar_plugin_retry_after_ms = status.retry_after_ms;
        self.sidebar_plugin_retry_at =
            status.retry_after_ms.map(|delay_ms| Instant::now() + Duration::from_millis(delay_ms));
        if had_surface && self.sidebar_plugin_surface.is_none() {
            self.session.invalidate_sidebar_plugin_sync();
        }
        if self.sidebar_focus_pending && (self.sidebar_plugin_surface.is_some() || relaunch) {
            self.sidebar_focus_pending = false;
            if self.sidebar_plugin_surface.is_some() {
                self.focus = FocusTarget::WorkspaceRail;
                self.menu = None;
                self.prompt = None;
                self.omnibar = None;
                self.replace_selection(None);
            }
        }
        if self.workspace_sidebar_focused() && self.sidebar_plugin_surface.is_none() {
            self.leave_workspace_sidebar();
        }
    }
}
