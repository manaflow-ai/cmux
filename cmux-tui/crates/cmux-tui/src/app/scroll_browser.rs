//! Scroll wheel handling (vertical and horizontal, with admission) and
//! browser pointer helpers: surface kind, browser source and point, and
//! sending browser mouse events.

use cmux_tui_core::{BrowserSource, Rect, SurfaceId, SurfaceKind};
use crossterm::event::KeyModifiers;
use ghostty_vt::{MouseAction, MouseButton as GhosttyMouseButton, Screen};

use crate::app::layout::{Hit, PaneArea, RailKind};
use crate::app::pointer::{PaneContentGeneration, TerminalPointerAdmission};
use crate::app::{App, BrowserMouseDispatch, RenderAction};
use crate::browser_input::{BrowserInputEvent, BrowserInputKind};
use crate::config::SidebarView;
use crate::pty_input::{PtyInputBytes, PtyInputKind};

impl App {
    #[cfg(test)]
    pub(super) fn handle_scroll(
        &mut self,
        x: u16,
        y: u16,
        down: bool,
        modifiers: KeyModifiers,
    ) -> anyhow::Result<RenderAction> {
        self.handle_scroll_with_admission(x, y, down, modifiers, None)
    }

    pub(super) fn handle_scroll_with_admission(
        &mut self,
        x: u16,
        y: u16,
        down: bool,
        modifiers: KeyModifiers,
        terminal_admission: Option<TerminalPointerAdmission>,
    ) -> anyhow::Result<RenderAction> {
        self.reset_selection_click_sequence();
        if let Some(menu) = self.menu.as_mut() {
            return Ok(if menu.scroll_at(x, y, down) {
                RenderAction::Draw
            } else {
                RenderAction::None
            });
        }
        if self.prompt.is_some() {
            return Ok(RenderAction::None);
        }
        if let Some(area) = self
            .machine_sidebar_area(self.content_area.height.saturating_add(1))
            .filter(|area| area.contains(x, y))
        {
            let footer_rows = self.machine_ui.as_ref().map_or(0, |ui| {
                usize::from(ui.snapshot.capabilities.create)
                    + usize::from(ui.snapshot.capabilities.connect)
            });
            let footer_is_clipped = footer_rows > usize::from(area.height.saturating_sub(2));
            if footer_is_clipped {
                self.machine_footer_scroll = if down {
                    self.machine_footer_scroll.saturating_add(1)
                } else {
                    self.machine_footer_scroll.saturating_sub(1)
                };
            } else {
                self.machine_rail_scroll = if down {
                    self.machine_rail_scroll.saturating_add(3)
                } else {
                    self.machine_rail_scroll.saturating_sub(3)
                };
            }
            self.machine_rail_follow_selection = false;
            return Ok(RenderAction::Draw);
        }
        if let Some(area) = (self.config.sidebar.plugin.is_none()
            && self.sidebar_view == SidebarView::Workspaces)
            .then(|| self.workspace_sidebar_area(self.content_area.height.saturating_add(1)))
            .flatten()
            .filter(|area| area.contains(x, y))
        {
            let footer_rows = self.workspace_sidebar_action_rows().len();
            let footer_is_clipped = footer_rows > usize::from(area.height.saturating_sub(2));
            if footer_is_clipped {
                self.workspace_footer_scroll = if down {
                    self.workspace_footer_scroll.saturating_add(1)
                } else {
                    self.workspace_footer_scroll.saturating_sub(1)
                };
            } else {
                self.workspace_rail_scroll = if down {
                    self.workspace_rail_scroll.saturating_add(3)
                } else {
                    self.workspace_rail_scroll.saturating_sub(3)
                };
            }
            self.workspace_rail_follow_selection = false;
            return Ok(RenderAction::Draw);
        }
        if let Some(_area) = self
            .tabs_sidebar_area(self.content_area.height.saturating_add(1))
            .filter(|area| area.contains(x, y))
        {
            self.tabs_rail_scroll = if down {
                self.tabs_rail_scroll.saturating_add(3)
            } else {
                self.tabs_rail_scroll.saturating_sub(3)
            };
            self.tabs_rail_follow_selection = false;
            return Ok(RenderAction::Draw);
        }
        if let Some(view_index) = self.sidebar_layout.ordered.iter().find_map(|placement| {
            matches!(placement.kind, RailKind::Projection(_))
                .then_some((placement.view_index, placement.rect))
                .filter(|(_, area)| area.contains(x, y))
                .map(|(view_index, _)| view_index)
        }) {
            let footer_rows = self.sidebar_action_rows(view_index).len();
            let footer_is_clipped = self
                .projection_sidebar_area(view_index)
                .is_some_and(|area| footer_rows > usize::from(area.height.saturating_sub(2)));
            let state = self.projection_rail_state_mut(view_index);
            if footer_is_clipped {
                state.footer_scroll = if down {
                    state.footer_scroll.saturating_add(1)
                } else {
                    state.footer_scroll.saturating_sub(1)
                };
            } else {
                state.scroll = if down {
                    state.scroll.saturating_add(3)
                } else {
                    state.scroll.saturating_sub(3)
                };
            }
            state.follow_selection = false;
            return Ok(RenderAction::Draw);
        }
        let Some(area) = self.pane_area_at(x, y).copied() else { return Ok(RenderAction::None) };
        if self.surface_kind(area.surface) == Some(SurfaceKind::Pty)
            && area.content.contains(x, y)
            && !self.terminal_input_rect(&area).is_some_and(|rect| rect.contains(x, y))
        {
            return Ok(RenderAction::None);
        }
        if self.active_pane() != Some(area.pane) {
            self.focus_pane_after_input(area.pane);
        }
        // Wheel over the tab bar scrolls the tabs, not the terminal.
        if area.bar.is_some_and(|bar| bar.contains(x, y)) {
            self.scroll_tabs(area.pane, if down { 1 } else { -1 });
            return Ok(RenderAction::Draw);
        }
        let (surface_id, _) = (area.surface, area.pane);
        let Some(surface) = self.session.surface(surface_id) else { return Ok(RenderAction::None) };
        if surface.kind() == SurfaceKind::Browser {
            if area.content.contains(x, y) {
                let Some(frame_seq) = self.processed_browser_pointer_authority(surface_id) else {
                    return Ok(RenderAction::None);
                };
                let (px, py) = self.browser_point(surface_id, area.content, x, y);
                let delta = if down { 3.0 } else { -3.0 } * f64::from(self.cell_pixels.1);
                let _ = self.browser_input.enqueue(BrowserInputEvent {
                    surface_id,
                    surface,
                    kind: BrowserInputKind::Wheel { x: px, y: py, delta_y: delta, frame_seq },
                });
                return Ok(RenderAction::Draw);
            }
            return Ok(RenderAction::None);
        }
        let canonical_content = self.canonical_pty_content(surface_id, area.logical_content_rect());
        let (logical_x, logical_y) = area.logical_content_point(x, y);
        if !canonical_content.contains(logical_x, logical_y) {
            return Ok(RenderAction::None);
        }
        if area.content.contains(x, y) {
            let forwarded = self.forward_pty_mouse_at_with_admission(
                (x, y),
                MouseAction::Press,
                Some(if down {
                    GhosttyMouseButton::WheelDown
                } else {
                    GhosttyMouseButton::WheelUp
                }),
                modifiers,
                false,
                terminal_admission.clone(),
            );
            match forwarded {
                None => return Ok(RenderAction::None),
                Some(true) => return Ok(RenderAction::Draw),
                Some(false) => {}
            }
        }
        let sent_arrows = if let Some(admission) = terminal_admission {
            if admission.surface != surface_id {
                return Ok(RenderAction::None);
            }
            admission.semantics.active_screen == Screen::Alternate
                && !admission.semantics.mouse_tracking
        } else {
            let Some(sent_arrows) = surface.with_terminal(|term| {
                term.active_screen() == Screen::Alternate && !term.mouse_tracking()
            }) else {
                return Ok(RenderAction::None);
            };
            sent_arrows
        };
        if sent_arrows {
            let _ = surface.scroll_to_bottom();
            // Alt-screen apps without mouse support get arrow keys
            // (the usual alternate-scroll behavior).
            let seq: &[u8] = if down { b"\x1b[B\x1b[B\x1b[B" } else { b"\x1b[A\x1b[A\x1b[A" };
            let _ = self.write_pty_bytes(
                surface_id,
                surface,
                PtyInputBytes::from_slice(seq),
                PtyInputKind::Ordered,
            );
        } else {
            let _ = surface.scroll_delta(if down { 3 } else { -3 });
        }
        Ok(RenderAction::Draw)
    }

    #[cfg(test)]
    pub(super) fn handle_horizontal_scroll(
        &mut self,
        x: u16,
        y: u16,
        right: bool,
        modifiers: KeyModifiers,
    ) -> anyhow::Result<RenderAction> {
        self.handle_horizontal_scroll_with_admission(x, y, right, modifiers, None)
    }

    pub(super) fn handle_horizontal_scroll_with_admission(
        &mut self,
        x: u16,
        y: u16,
        right: bool,
        modifiers: KeyModifiers,
        terminal_admission: Option<TerminalPointerAdmission>,
    ) -> anyhow::Result<RenderAction> {
        self.reset_selection_click_sequence();
        if self.menu.is_some() || self.prompt.is_some() {
            return Ok(RenderAction::None);
        }
        let over_scrollbar = matches!(self.hit_at(x, y), Some(Hit::HorizontalScrollbar { .. }));
        let over_pane = self.pane_area_at(x, y).is_some();
        if self.horizontal_scrollbar_state().is_some() && (over_scrollbar || over_pane) {
            let step = (self.content_area.width / 6).max(1) as i16;
            self.scroll_horizontal_viewport(if right { step } else { -step }, true);
            return Ok(RenderAction::Draw);
        }
        let Some(area) = self.pane_area_at(x, y).copied() else {
            return Ok(RenderAction::None);
        };
        if self.surface_kind(area.surface) == Some(SurfaceKind::Pty)
            && area.content.contains(x, y)
            && !self.terminal_input_rect(&area).is_some_and(|rect| rect.contains(x, y))
        {
            return Ok(RenderAction::None);
        }
        if self.active_pane() != Some(area.pane) {
            self.focus_pane_after_input(area.pane);
        }
        if self.surface_kind(area.surface) == Some(SurfaceKind::Pty) && {
            let content = self.canonical_pty_content(area.surface, area.logical_content_rect());
            let (x, y) = area.logical_content_point(x, y);
            !content.contains(x, y)
        } {
            return Ok(RenderAction::None);
        }
        if area.content.contains(x, y) {
            let forwarded = self.forward_pty_mouse_at_with_admission(
                (x, y),
                MouseAction::Press,
                Some(if right {
                    GhosttyMouseButton::WheelRight
                } else {
                    GhosttyMouseButton::WheelLeft
                }),
                modifiers,
                false,
                terminal_admission,
            );
            return Ok(match forwarded {
                Some(true) => RenderAction::Draw,
                Some(false) | None => RenderAction::None,
            });
        }
        Ok(RenderAction::None)
    }

    pub(super) fn surface_kind(&self, surface: SurfaceId) -> Option<SurfaceKind> {
        self.tab_locations
            .get(&surface)
            .and_then(|[workspace, screen, pane, tab]| {
                self.tree
                    .workspaces()
                    .get(*workspace)
                    .and_then(|workspace| workspace.screens.get(*screen))
                    .and_then(|screen| screen.panes.get(*pane))
                    .and_then(|pane| pane.tabs.get(*tab))
            })
            .map(|tab| tab.kind)
            .or_else(|| self.session.surface(surface).map(|surface| surface.kind()))
    }

    pub(super) fn browser_source(&self, surface: SurfaceId) -> Option<BrowserSource> {
        self.tree
            .workspaces()
            .iter()
            .flat_map(|ws| ws.screens.iter())
            .flat_map(|screen| screen.panes.iter())
            .flat_map(|pane| pane.tabs.iter())
            .find(|tab| tab.surface == surface)
            .and_then(|tab| tab.browser_source)
    }

    fn browser_point(&self, surface: SurfaceId, content: Rect, x: u16, y: u16) -> (f64, f64) {
        let source_x = self
            .pane_areas
            .iter()
            .find(|area| area.surface == surface)
            .map_or(0, PaneArea::content_source_x);
        let col = source_x.saturating_add(x.saturating_sub(content.x)) as f64 + 0.5;
        let row = y.saturating_sub(content.y) as f64 + 0.5;
        (col * f64::from(self.cell_pixels.0), row * f64::from(self.cell_pixels.1))
    }

    pub(super) fn processed_browser_pointer_authority(&self, surface: SurfaceId) -> Option<u64> {
        match self.rendered_pointer_frame.pane_content_generations.get(&surface) {
            Some(PaneContentGeneration::Browser(frame_seq)) => Some(*frame_seq),
            Some(PaneContentGeneration::Terminal(_)) | None => None,
        }
    }

    /// Queue a mouse event for the off-loop browser input worker; the
    /// event loop never waits on the CDP/socket round trip.
    pub(super) fn send_browser_mouse(
        &self,
        surface_id: SurfaceId,
        content: Rect,
        x: u16,
        y: u16,
        frame_seq: u64,
        dispatch: BrowserMouseDispatch,
    ) -> bool {
        if !self.session_available() {
            return false;
        }
        let Some(surface) = self.session.surface(surface_id) else { return false };
        let (px, py) = self.browser_point(surface_id, content, x, y);
        self.browser_input.enqueue(BrowserInputEvent {
            surface_id,
            surface,
            kind: BrowserInputKind::Mouse {
                event_type: dispatch.event_type,
                x: px,
                y: py,
                button: dispatch.button,
                click_count: dispatch.click_count,
                frame_seq,
            },
        })
    }
}
