//! Writing PTY input: byte enqueueing with rollback, enqueue results, input
//! preparation before a mutation, client tab, screen and workspace selection,
//! and current surface content and pointer helpers.

use cmux_tui_core::{PaneId, Rect, SurfaceId};
use crossterm::event::{KeyModifiers, MouseButton};
use ghostty_vt::{Mods, MouseButton as GhosttyMouseButton};

use crate::app::layout::PaneArea;
use crate::app::pointer::{Drag, PtyInputForwardResult};
use crate::app::{App, canonical_terminal_content};
use crate::localization;
use crate::pty_input::{PtyInputBytes, PtyInputEnqueueResult, PtyInputEvent, PtyInputKind};
use crate::session::SurfaceHandle;

impl App {
    pub(super) fn write_encoded_pty_bytes(
        &mut self,
        surface_id: SurfaceId,
        surface: SurfaceHandle,
        kind: PtyInputKind,
    ) -> PtyInputForwardResult {
        let bytes = PtyInputBytes::from_slice(&self.encode_buf);
        self.enqueue_pty_bytes(surface_id, surface, bytes, kind)
    }

    pub(super) fn write_pty_bytes(
        &mut self,
        surface_id: SurfaceId,
        surface: SurfaceHandle,
        bytes: PtyInputBytes,
        kind: PtyInputKind,
    ) -> bool {
        self.enqueue_pty_bytes(surface_id, surface, bytes, kind).accepted
    }

    pub(super) fn enqueue_pty_bytes(
        &mut self,
        surface_id: SurfaceId,
        surface: SurfaceHandle,
        bytes: PtyInputBytes,
        kind: PtyInputKind,
    ) -> PtyInputForwardResult {
        if !self.session_available() {
            self.status_message =
                Some(localization::catalog().sidebar.no_active_session.to_string());
            return PtyInputForwardResult { owned: true, accepted: false, reservation_id: None };
        }
        if surface.is_dead() {
            self.status_message =
                Some(localization::catalog().terminal.pty_input_exited.to_string());
            return PtyInputForwardResult { owned: true, accepted: false, reservation_id: None };
        }
        let (result, reservation_id) = self
            .pty_input
            .enqueue_with_reservation(PtyInputEvent::input(surface_id, surface, bytes, kind));
        self.rollback_mouse_motion_for_enqueue_failure(surface_id, kind, result);
        PtyInputForwardResult {
            owned: true,
            accepted: self.handle_pty_enqueue_result(result),
            reservation_id,
        }
    }

    pub(super) fn rollback_mouse_motion_for_enqueue_failure(
        &mut self,
        surface_id: SurfaceId,
        kind: PtyInputKind,
        result: PtyInputEnqueueResult,
    ) {
        if kind == PtyInputKind::Motion
            && matches!(result, PtyInputEnqueueResult::Saturated | PtyInputEnqueueResult::Failed)
            && let Some(surface) = self.session.surface(surface_id)
        {
            surface.reset_mouse_motion_dedupe();
        }
    }

    pub(super) fn handle_pty_enqueue_result(&mut self, result: PtyInputEnqueueResult) -> bool {
        match result {
            PtyInputEnqueueResult::Accepted => true,
            PtyInputEnqueueResult::Oversized => {
                self.status_message =
                    Some(localization::catalog().terminal.pty_input_too_large.to_string());
                false
            }
            PtyInputEnqueueResult::Saturated => {
                self.status_message =
                    Some(localization::catalog().terminal.pty_input_queue_full.to_string());
                false
            }
            PtyInputEnqueueResult::Failed => {
                self.status_message =
                    Some(localization::catalog().terminal.pty_input_unavailable.to_string());
                false
            }
        }
    }

    pub(super) fn prepare_pty_input_before_mutation(&mut self) -> bool {
        if !self.session_available() {
            self.status_message =
                Some(localization::catalog().sidebar.no_active_session.to_string());
            return false;
        }
        self.cancel_pty_mouse_drag();
        !matches!(self.drag, Some(Drag::PtyMouse { .. }))
    }

    pub(super) fn focus_pane_after_input(&mut self, pane: PaneId) {
        if self.prepare_pty_input_before_mutation() {
            let workspace_index = self.tree.active_workspace;
            let screen_index =
                self.tree.active_workspace().map(|workspace| workspace.active_screen);
            let focused = screen_index
                .is_some_and(|screen| self.tree.set_active_pane(workspace_index, screen, pane));
            if focused {
                self.pane_focus_history.record(pane);
                self.claim_active_terminal_geometry(true);
            }
        }
    }

    pub(super) fn select_tab_for_client(
        &mut self,
        pane: Option<PaneId>,
        index: Option<usize>,
        delta: Option<isize>,
    ) {
        let pane = pane.or_else(|| self.active_pane());
        if let Some(pane_id) = pane {
            let target = self.tree.pane(pane_id).and_then(|pane| {
                if pane.tabs.is_empty() {
                    return None;
                }
                index.filter(|index| *index < pane.tabs.len()).or_else(|| {
                    delta.map(|delta| {
                        ((pane.active_tab as isize + delta).rem_euclid(pane.tabs.len() as isize))
                            as usize
                    })
                })
            });
            if let Some(target) = target {
                self.tree.set_pane_active_tab(pane_id, target);
            }
        }
        self.claim_active_terminal_geometry(true);
    }

    pub(super) fn select_screen_for_client(&mut self, index: Option<usize>, delta: Option<isize>) {
        let mut selected = false;
        let target = self.tree.active_workspace().and_then(|workspace| {
            if workspace.screens.is_empty() {
                return None;
            }
            index.filter(|index| *index < workspace.screens.len()).or_else(|| {
                delta.map(|delta| {
                    ((workspace.active_screen as isize + delta)
                        .rem_euclid(workspace.screens.len() as isize)) as usize
                })
            })
        });
        if let Some(target) = target {
            let workspace_index = self.tree.active_workspace;
            selected = self.tree.set_active_screen(workspace_index, target);
        }
        if selected && let Some(active) = self.active_pane() {
            self.pane_focus_history.record(active);
        }
        self.claim_active_terminal_geometry(true);
    }

    pub(super) fn select_workspace_for_client(
        &mut self,
        index: Option<usize>,
        delta: Option<isize>,
    ) {
        let mut selected = false;
        if !self.tree.workspaces().is_empty() {
            if let Some(index) = index.filter(|index| *index < self.tree.workspaces().len()) {
                self.tree.active_workspace = index;
                selected = true;
            } else if let Some(delta) = delta {
                self.tree.active_workspace = ((self.tree.active_workspace as isize + delta)
                    .rem_euclid(self.tree.workspaces().len() as isize))
                    as usize;
                selected = true;
            }
        }
        if selected && let Some(active) = self.active_pane() {
            self.pane_focus_history.record(active);
        }
        self.claim_active_terminal_geometry(true);
    }

    pub(super) fn terminal_input_rect(&self, area: &PaneArea) -> Option<Rect> {
        self.rendered_terminal_bounds.get(&area.surface).copied()
    }

    pub(super) fn current_pty_content(&self, surface: SurfaceId) -> Option<Rect> {
        self.pane_areas
            .iter()
            .find(|area| area.surface == surface)
            .map(|area| self.canonical_pty_content(surface, area.logical_content_rect()))
    }

    pub(super) fn current_browser_content(&self, surface: SurfaceId) -> Option<Rect> {
        self.pane_areas.iter().find(|area| area.surface == surface).map(|area| area.content)
    }

    pub(super) fn current_selection_geometry(&self, surface: SurfaceId) -> Option<(Rect, u16)> {
        let area = self.pane_areas.iter().find(|area| area.surface == surface)?;
        Some((self.terminal_input_rect(area)?, area.content_source_x()))
    }

    pub(super) fn current_pty_pointer(
        &self,
        surface: SurfaceId,
        x: u16,
        y: u16,
    ) -> Option<(Rect, u16, u16)> {
        let area = self.pane_areas.iter().find(|area| area.surface == surface)?;
        let content = self.canonical_pty_content(surface, area.logical_content_rect());
        let (x, y) = area.logical_content_point(x, y);
        Some((content, x, y))
    }

    pub(super) fn canonical_pty_content(&self, surface: SurfaceId, content: Rect) -> Rect {
        canonical_terminal_content(content, self.rendered_terminal_sizes.get(&surface).copied())
    }

    pub(super) fn cancel_pty_release_reservation(&self) {
        if let Some(Drag::PtyMouse { reservation_id, .. }) = &self.drag {
            self.pty_input.cancel_release_reservation(*reservation_id);
        }
    }

    pub(super) fn ghostty_mouse_button(button: MouseButton) -> GhosttyMouseButton {
        match button {
            MouseButton::Left => GhosttyMouseButton::Left,
            MouseButton::Right => GhosttyMouseButton::Right,
            MouseButton::Middle => GhosttyMouseButton::Middle,
        }
    }

    pub(super) fn ghostty_mouse_mods(modifiers: KeyModifiers) -> Mods {
        let mut mods = Mods::default();
        if modifiers.contains(KeyModifiers::SHIFT) {
            mods = mods | Mods::SHIFT;
        }
        if modifiers.contains(KeyModifiers::CONTROL) {
            mods = mods | Mods::CTRL;
        }
        if modifiers.contains(KeyModifiers::ALT) {
            mods = mods | Mods::ALT;
        }
        if modifiers.contains(KeyModifiers::SUPER) {
            mods = mods | Mods::SUPER;
        }
        mods
    }
}
