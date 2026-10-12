//! PTY mouse reporting: press, drag and release capture, release reservations,
//! pointer interaction cancel, active drag finish, and encoding mouse events
//! for the terminal.

use cmux_tui_core::{GuardedMouseEncode, PointerSemanticProbe, Rect, SurfaceId, SurfaceKind};
use crossterm::event::{KeyModifiers, MouseButton};
use ghostty_vt::{MouseAction, MouseButton as GhosttyMouseButton, MouseInput};

use crate::app::pointer::{
    Drag, PtyInputForwardResult, PtyMousePressResult, PtyMouseReleaseCapture,
    TerminalPointerAdmission, TerminalPointerEncoding,
};
use crate::app::{App, BrowserMouseDispatch};
use crate::pty_input::{PtyInputBytes, PtyInputEvent, PtyInputKind};
use crate::session::SurfaceHandle;

impl App {
    #[cfg(test)]
    pub(super) fn begin_pty_mouse_drag(
        &mut self,
        x: u16,
        y: u16,
        button: MouseButton,
        modifiers: KeyModifiers,
    ) -> PtyMousePressResult {
        self.begin_pty_mouse_drag_with_admission(x, y, button, modifiers, None)
    }

    pub(super) fn begin_pty_mouse_drag_with_admission(
        &mut self,
        x: u16,
        y: u16,
        button: MouseButton,
        modifiers: KeyModifiers,
        terminal_admission: Option<TerminalPointerAdmission>,
    ) -> PtyMousePressResult {
        if modifiers.contains(KeyModifiers::SHIFT)
            || (button == MouseButton::Right && modifiers.contains(KeyModifiers::ALT))
            || self.menu.is_some()
            || self.prompt.is_some()
            || self.drag.is_some()
        {
            return PtyMousePressResult::NotOwned;
        }
        let Some(area) = self.pane_area_at(x, y).copied() else {
            return PtyMousePressResult::NotOwned;
        };
        if !area.content.contains(x, y) || self.surface_kind(area.surface) != Some(SurfaceKind::Pty)
        {
            return PtyMousePressResult::NotOwned;
        }
        let content = self.canonical_pty_content(area.surface, area.logical_content_rect());
        let (logical_x, logical_y) = area.logical_content_point(x, y);
        if !content.contains(logical_x, logical_y) {
            return PtyMousePressResult::NotOwned;
        }
        let Some(handle) = self.session.surface(area.surface) else {
            return PtyMousePressResult::Consumed;
        };
        let semantics = terminal_admission.as_ref().map(|admission| admission.semantics).or_else(
            || match handle.try_pointer_semantics() {
                Some(PointerSemanticProbe::Ready(semantics)) => Some(semantics),
                Some(PointerSemanticProbe::Contended) | None => None,
            },
        );
        let (release_capture, forwarded) = self.prepare_pty_mouse_press(
            (area.surface, handle.clone()),
            content,
            (logical_x, logical_y),
            button,
            modifiers,
            terminal_admission,
        );
        if matches!(release_capture, PtyMouseReleaseCapture::Failed) {
            self.active_pointer_buttons.remove(&button);
            return PtyMousePressResult::Consumed;
        }
        if !forwarded.owned {
            return PtyMousePressResult::NotOwned;
        }
        if self.active_pane() != Some(area.pane) {
            self.focus_pane_after_input(area.pane);
        }
        self.leave_workspace_sidebar();
        self.reset_selection_click_sequence();
        self.replace_selection(None);
        if !forwarded.accepted {
            return PtyMousePressResult::Consumed;
        }
        let Some(reservation_id) = forwarded.reservation_id else {
            return PtyMousePressResult::Consumed;
        };
        let PtyMouseReleaseCapture::Bytes(release_bytes) = release_capture else {
            self.pty_input.cancel_release_reservation(reservation_id);
            return PtyMousePressResult::Consumed;
        };
        self.drag = Some(Drag::PtyMouse {
            surface: area.surface,
            handle: Some(handle),
            reservation_id,
            release_bytes,
            semantics,
            content,
            button,
            position: (logical_x, logical_y),
            modifiers,
        });
        self.ignored_pty_mouse_buttons.clear();
        PtyMousePressResult::Started
    }

    fn prepare_pty_mouse_press(
        &mut self,
        route: (SurfaceId, SurfaceHandle),
        content: Rect,
        position: (u16, u16),
        button: MouseButton,
        modifiers: KeyModifiers,
        terminal_admission: Option<TerminalPointerAdmission>,
    ) -> (PtyMouseReleaseCapture, PtyInputForwardResult) {
        let (surface_id, surface) = route;
        let (x, y) = position;
        let failed =
            || PtyInputForwardResult { owned: true, accepted: false, reservation_id: None };
        let cell_width = u32::from(self.cell_pixels.0.max(1));
        let cell_height = u32::from(self.cell_pixels.1.max(1));
        let position = (
            (x as f32 - content.x as f32 + 0.5) * cell_width as f32,
            (y as f32 - content.y as f32 + 0.5) * cell_height as f32,
        );
        let screen_size = (
            u32::from(content.width).saturating_mul(cell_width),
            u32::from(content.height).saturating_mul(cell_height),
        );
        let press = MouseInput {
            action: MouseAction::Press,
            button: Some(Self::ghostty_mouse_button(button)),
            mods: Self::ghostty_mouse_mods(modifiers),
            position,
            screen_size,
            cell_size: (cell_width, cell_height),
            any_button_pressed: true,
        };
        let release =
            MouseInput { action: MouseAction::Release, any_button_pressed: false, ..press };
        let (press_output, release_output, encoded) = match terminal_admission {
            Some(TerminalPointerAdmission {
                surface,
                encoding:
                    TerminalPointerEncoding::PressPair {
                        press: encoded_press,
                        release: encoded_release,
                    },
                ..
            }) if surface == surface_id => (encoded_press, encoded_release, true),
            Some(_) => (PtyInputBytes::new(), PtyInputBytes::new(), false),
            None => {
                let mut press_output = PtyInputBytes::new();
                let mut release_output = PtyInputBytes::new();
                let encoded = surface
                    .encode_mouse_press_pair(press, release, &mut press_output, &mut release_output)
                    .is_some_and(|encoded| encoded.is_ok());
                (press_output, release_output, encoded)
            }
        };
        self.encode_buf.clear();
        #[cfg(test)]
        self.encode_buf.extend_from_slice(&press_output);
        if !encoded {
            return (PtyMouseReleaseCapture::Failed, failed());
        }
        let release_capture = if release_output.is_empty() {
            PtyMouseReleaseCapture::NotReported
        } else {
            PtyMouseReleaseCapture::Bytes(release_output)
        };
        if press_output.is_empty() {
            return (
                release_capture,
                PtyInputForwardResult { owned: false, accepted: true, reservation_id: None },
            );
        }
        let kind = if matches!(release_capture, PtyMouseReleaseCapture::Bytes(_)) {
            PtyInputKind::Press
        } else {
            PtyInputKind::Ordered
        };
        let forwarded = self.enqueue_pty_bytes(surface_id, surface, press_output, kind);
        (release_capture, forwarded)
    }

    pub(super) fn forward_pty_mouse_drag(
        &mut self,
        x: u16,
        y: u16,
        _reported_button: MouseButton,
        modifiers: KeyModifiers,
    ) -> bool {
        let Some(Drag::PtyMouse { surface, semantics, content, button: active_button, .. }) =
            self.drag
        else {
            return false;
        };
        // Some host protocols report a drag as left regardless of the
        // pressed button. This TUI owns one active button, so it is authoritative.
        if self.menu.is_some() || self.prompt.is_some() {
            self.cancel_pty_mouse_drag();
            return true;
        }
        let (content, x, y) = self.current_pty_pointer(surface, x, y).unwrap_or((content, x, y));
        if let Some(Drag::PtyMouse { position, modifiers: stored_modifiers, .. }) = &mut self.drag {
            *position = (x, y);
            *stored_modifiers = modifiers;
        }
        self.encode_buf.clear();
        let Some(semantics) = semantics else {
            return true;
        };
        let _ = self.forward_pty_mouse_motion_if_uncontended(
            (surface, content),
            (x, y),
            Some(Self::ghostty_mouse_button(active_button)),
            modifiers,
            true,
            Some(TerminalPointerAdmission {
                surface,
                semantics,
                encoding: TerminalPointerEncoding::None,
            }),
        );
        true
    }

    pub(super) fn finish_pty_mouse_drag(
        &mut self,
        x: u16,
        y: u16,
        reported_button: MouseButton,
        modifiers: KeyModifiers,
    ) -> bool {
        let Some(Drag::PtyMouse {
            surface,
            handle,
            reservation_id,
            release_bytes,
            content,
            button,
            ..
        }) = &self.drag
        else {
            return false;
        };
        let (surface, handle, reservation_id, fallback, content, button) =
            (*surface, handle.clone(), *reservation_id, release_bytes.clone(), *content, *button);
        if reported_button != button {
            self.ignored_pty_mouse_buttons.remove(&reported_button);
            return true;
        }
        let (content, x, y) = self.current_pty_pointer(surface, x, y).unwrap_or((content, x, y));
        let release = self.capture_pty_mouse_release(surface, content, x, y, button, modifiers);
        self.drag = None;
        self.ignored_pty_mouse_buttons.clear();
        match release {
            PtyMouseReleaseCapture::Bytes(bytes) => {
                if !self.enqueue_pty_release(surface, handle, reservation_id, bytes) {
                    self.pty_input.cancel_release_reservation(reservation_id);
                }
            }
            PtyMouseReleaseCapture::Failed | PtyMouseReleaseCapture::NotReported => {
                if !self.enqueue_pty_release(surface, handle, reservation_id, fallback) {
                    self.pty_input.cancel_release_reservation(reservation_id);
                }
            }
        }
        true
    }

    fn capture_pty_mouse_release(
        &mut self,
        surface_id: SurfaceId,
        content: Rect,
        x: u16,
        y: u16,
        button: MouseButton,
        modifiers: KeyModifiers,
    ) -> PtyMouseReleaseCapture {
        let Some(surface) = self.session.surface(surface_id) else {
            return PtyMouseReleaseCapture::Failed;
        };
        let cell_width = u32::from(self.cell_pixels.0.max(1));
        let cell_height = u32::from(self.cell_pixels.1.max(1));
        let input = MouseInput {
            action: MouseAction::Release,
            button: Some(Self::ghostty_mouse_button(button)),
            mods: Self::ghostty_mouse_mods(modifiers),
            position: (
                (x as f32 - content.x as f32 + 0.5) * cell_width as f32,
                (y as f32 - content.y as f32 + 0.5) * cell_height as f32,
            ),
            screen_size: (
                u32::from(content.width).saturating_mul(cell_width),
                u32::from(content.height).saturating_mul(cell_height),
            ),
            cell_size: (cell_width, cell_height),
            any_button_pressed: false,
        };
        let mut output = PtyInputBytes::new();
        let Some(encoded) = surface.encode_mouse_release(input, &mut output) else {
            return PtyMouseReleaseCapture::Failed;
        };
        match encoded {
            Ok(()) if output.is_empty() => PtyMouseReleaseCapture::NotReported,
            Ok(()) => PtyMouseReleaseCapture::Bytes(output),
            Err(_) => PtyMouseReleaseCapture::Failed,
        }
    }

    pub(super) fn enqueue_pty_release(
        &mut self,
        surface_id: SurfaceId,
        retained: Option<SurfaceHandle>,
        reservation_id: u64,
        bytes: PtyInputBytes,
    ) -> bool {
        let Some(surface) = retained.or_else(|| self.session.surface(surface_id)) else {
            return false;
        };
        self.encode_buf.clear();
        #[cfg(test)]
        self.encode_buf.extend_from_slice(bytes.as_ref());
        let (result, _) = self.pty_input.enqueue_with_reservation(PtyInputEvent::release(
            surface_id,
            surface,
            bytes,
            reservation_id,
        ));
        self.handle_pty_enqueue_result(result)
    }

    pub(super) fn cancel_pointer_interaction(&mut self) -> bool {
        self.reset_selection_click_sequence();
        let menu_scrollbar_dragged =
            self.menu.as_mut().is_some_and(|menu| menu.finish_scrollbar_drag());
        let pointer_dragged = self.drag.is_some();
        if matches!(self.drag, Some(Drag::PtyMouse { .. })) {
            self.cancel_pty_mouse_drag();
        } else if let Some(Drag::Browser { surface, content, position, frame_seq }) = &self.drag {
            let (surface, content, position, frame_seq) =
                (*surface, *content, *position, *frame_seq);
            self.drag = None;
            let x = position.0.clamp(content.x, content.x + content.width.saturating_sub(1));
            let y = position.1.clamp(content.y, content.y + content.height.saturating_sub(1));
            let _ = self.send_browser_mouse(
                surface,
                content,
                x,
                y,
                frame_seq,
                BrowserMouseDispatch::new("mouseReleased", Some("left"), Some(1)),
            );
        } else {
            let settle_split = matches!(self.drag, Some(Drag::ResizeSplit { .. }));
            self.drag = None;
            if settle_split {
                self.session.settle_split_ratio();
            }
        }
        self.active_pointer_buttons.clear();
        self.ignored_pty_mouse_buttons.clear();
        menu_scrollbar_dragged || pointer_dragged
    }

    pub(super) fn cancel_pty_mouse_drag(&mut self) {
        let Some(Drag::PtyMouse {
            surface,
            handle,
            reservation_id,
            release_bytes,
            content,
            button,
            position,
            modifiers,
            ..
        }) = &self.drag
        else {
            return;
        };
        let (surface, handle, reservation_id, fallback, content, button, position, modifiers) = (
            *surface,
            handle.clone(),
            *reservation_id,
            release_bytes.clone(),
            *content,
            *button,
            *position,
            *modifiers,
        );
        let content = self.current_pty_content(surface).unwrap_or(content);
        let release = self
            .capture_pty_mouse_release(surface, content, position.0, position.1, button, modifiers);
        self.drag = None;
        self.ignored_pty_mouse_buttons.clear();
        match release {
            PtyMouseReleaseCapture::Bytes(bytes) => {
                if !self.enqueue_pty_release(surface, handle, reservation_id, bytes) {
                    self.pty_input.cancel_release_reservation(reservation_id);
                }
            }
            PtyMouseReleaseCapture::Failed | PtyMouseReleaseCapture::NotReported => {
                if !self.enqueue_pty_release(surface, handle, reservation_id, fallback) {
                    self.pty_input.cancel_release_reservation(reservation_id);
                }
            }
        }
    }

    pub(super) fn finish_active_drag(&mut self) {
        let had_drag = self.drag.is_some();
        if let Some(menu) = self.menu.as_mut() {
            menu.finish_scrollbar_drag();
        }
        if matches!(self.drag, Some(Drag::PtyMouse { .. })) {
            self.cancel_pty_mouse_drag();
            self.reset_selection_click_sequence();
            return;
        }
        match self.drag.take() {
            Some(Drag::Browser { surface, content, position, frame_seq }) => {
                let content = self.current_browser_content(surface).unwrap_or(content);
                let position = (
                    position.0.clamp(content.x, content.x + content.width.saturating_sub(1)),
                    position.1.clamp(content.y, content.y + content.height.saturating_sub(1)),
                );
                let _ = self.send_browser_mouse(
                    surface,
                    content,
                    position.0,
                    position.1,
                    frame_seq,
                    BrowserMouseDispatch::new("mouseReleased", Some("left"), Some(1)),
                );
            }
            Some(Drag::ResizeSplit { .. }) => self.session.settle_split_ratio(),
            Some(
                Drag::TabArm { .. }
                | Drag::Tab { .. }
                | Drag::WorkspaceArm { .. }
                | Drag::Workspace { .. }
                | Drag::Select { .. }
                | Drag::StatusMessage { .. }
                | Drag::Scrollbar { .. }
                | Drag::HorizontalScrollbar { .. }
                | Drag::WorkspaceScrollbar { .. }
                | Drag::RailResize(_),
            )
            | None => {}
            Some(Drag::PtyMouse { .. }) => unreachable!("PTY drag returned before take"),
        }
        if had_drag {
            self.reset_selection_click_sequence();
        }
    }

    #[cfg(test)]
    pub(super) fn forward_pty_mouse_at(
        &mut self,
        x: u16,
        y: u16,
        action: MouseAction,
        button: Option<GhosttyMouseButton>,
        modifiers: KeyModifiers,
        any_button_pressed: bool,
    ) -> bool {
        self.forward_pty_mouse_at_with_admission(
            (x, y),
            action,
            button,
            modifiers,
            any_button_pressed,
            None,
        )
        .unwrap_or(true)
    }

    pub(super) fn forward_pty_mouse_at_with_admission(
        &mut self,
        position: (u16, u16),
        action: MouseAction,
        button: Option<GhosttyMouseButton>,
        modifiers: KeyModifiers,
        any_button_pressed: bool,
        terminal_admission: Option<TerminalPointerAdmission>,
    ) -> Option<bool> {
        let (x, y) = position;
        if modifiers.contains(KeyModifiers::SHIFT) || self.menu.is_some() || self.prompt.is_some() {
            return Some(false);
        }
        let Some(area) = self.pane_area_at(x, y).copied() else { return Some(false) };
        if !area.content.contains(x, y) || self.surface_kind(area.surface) != Some(SurfaceKind::Pty)
        {
            return Some(false);
        }
        let content = self.canonical_pty_content(area.surface, area.logical_content_rect());
        let (logical_x, logical_y) = area.logical_content_point(x, y);
        if action == MouseAction::Motion {
            let inside = content.contains(logical_x, logical_y);
            let owned = self.forward_pty_mouse_motion_if_uncontended(
                (area.surface, content),
                (logical_x, logical_y),
                None,
                modifiers,
                any_button_pressed,
                terminal_admission,
            );
            // A no-button motion outside the canonical viewport is
            // intentionally suppressed by Ghostty. Reset dedupe so re-entering
            // through the same edge cell still reports a fresh hover sample.
            if !inside
                && !any_button_pressed
                && let Some(surface) = self.session.surface(area.surface)
            {
                surface.reset_mouse_motion_dedupe();
            }
            return Some(owned);
        }
        if !content.contains(logical_x, logical_y) {
            return Some(false);
        }
        self.forward_pty_mouse_to_surface(
            area.surface,
            content,
            logical_x,
            logical_y,
            action,
            button,
            modifiers,
            any_button_pressed,
            terminal_admission,
        )
        .map(|forwarded| forwarded.owned)
    }

    pub(super) fn forward_pty_mouse_motion_if_uncontended(
        &mut self,
        route: (SurfaceId, Rect),
        position: (u16, u16),
        button: Option<GhosttyMouseButton>,
        modifiers: KeyModifiers,
        any_button_pressed: bool,
        terminal_admission: Option<TerminalPointerAdmission>,
    ) -> bool {
        let (surface_id, content) = route;
        let Some(surface) = self.session.surface(surface_id) else { return false };
        let (x, y) = position;
        let cell_width = u32::from(self.cell_pixels.0.max(1));
        let cell_height = u32::from(self.cell_pixels.1.max(1));
        let input = MouseInput {
            action: MouseAction::Motion,
            button,
            mods: Self::ghostty_mouse_mods(modifiers),
            position: (
                (x as f32 - content.x as f32 + 0.5) * cell_width as f32,
                (y as f32 - content.y as f32 + 0.5) * cell_height as f32,
            ),
            screen_size: (
                u32::from(content.width).saturating_mul(cell_width),
                u32::from(content.height).saturating_mul(cell_height),
            ),
            cell_size: (cell_width, cell_height),
            any_button_pressed,
        };

        self.encode_buf.clear();
        let bytes = match terminal_admission {
            Some(TerminalPointerAdmission {
                surface,
                encoding: TerminalPointerEncoding::Single(encoded),
                ..
            }) if surface == surface_id => encoded,
            Some(TerminalPointerAdmission {
                surface: admission_surface,
                semantics,
                encoding: TerminalPointerEncoding::None,
            }) if admission_surface == surface_id => {
                let mut output = PtyInputBytes::new();
                match surface.encode_mouse_if_semantics(semantics, input, &mut output) {
                    Some(GuardedMouseEncode::Encoded(Ok(()))) => output,
                    Some(
                        GuardedMouseEncode::Contended
                        | GuardedMouseEncode::SemanticsChanged
                        | GuardedMouseEncode::ContentChanged
                        | GuardedMouseEncode::Encoded(Err(_)),
                    )
                    | None => return true,
                }
            }
            Some(_) => return true,
            None => {
                let mut output = PtyInputBytes::new();
                match surface.encode_mouse(input, &mut output) {
                    Some(Ok(())) => output,
                    Some(Err(_)) | None => return true,
                }
            }
        };
        #[cfg(test)]
        self.encode_buf.extend_from_slice(&bytes);
        if bytes.is_empty() {
            return false;
        }
        let _ = self.enqueue_pty_bytes(surface_id, surface, bytes, PtyInputKind::Motion);
        true
    }

    #[allow(clippy::too_many_arguments)]
    fn forward_pty_mouse_to_surface(
        &mut self,
        surface_id: SurfaceId,
        content: Rect,
        x: u16,
        y: u16,
        action: MouseAction,
        button: Option<GhosttyMouseButton>,
        modifiers: KeyModifiers,
        any_button_pressed: bool,
        terminal_admission: Option<TerminalPointerAdmission>,
    ) -> Option<PtyInputForwardResult> {
        let Some(surface) = self.session.surface(surface_id) else {
            return Some(PtyInputForwardResult {
                owned: false,
                accepted: false,
                reservation_id: None,
            });
        };
        let cell_width = u32::from(self.cell_pixels.0.max(1));
        let cell_height = u32::from(self.cell_pixels.1.max(1));
        let position = (
            (x as f32 - content.x as f32 + 0.5) * cell_width as f32,
            (y as f32 - content.y as f32 + 0.5) * cell_height as f32,
        );
        let input = MouseInput {
            action,
            button,
            mods: Self::ghostty_mouse_mods(modifiers),
            position,
            screen_size: (
                u32::from(content.width).saturating_mul(cell_width),
                u32::from(content.height).saturating_mul(cell_height),
            ),
            cell_size: (cell_width, cell_height),
            any_button_pressed,
        };

        let (bytes, encoded) = match terminal_admission {
            Some(TerminalPointerAdmission {
                surface,
                encoding: TerminalPointerEncoding::Single(encoded),
                ..
            }) if surface == surface_id => (encoded, true),
            Some(_) => return None,
            None => {
                let mut output = PtyInputBytes::new();
                let encoded = surface.encode_mouse(input, &mut output)?.is_ok();
                (output, encoded)
            }
        };
        self.encode_buf.clear();
        #[cfg(test)]
        self.encode_buf.extend_from_slice(&bytes);
        if !encoded {
            return Some(PtyInputForwardResult {
                owned: true,
                accepted: false,
                reservation_id: None,
            });
        }
        if bytes.is_empty() {
            if action == MouseAction::Release {
                self.cancel_pty_release_reservation();
            }
            return Some(PtyInputForwardResult {
                owned: false,
                accepted: true,
                reservation_id: None,
            });
        }
        let kind = match action {
            MouseAction::Press
                if matches!(
                    button,
                    Some(
                        GhosttyMouseButton::Left
                            | GhosttyMouseButton::Right
                            | GhosttyMouseButton::Middle
                    )
                ) =>
            {
                PtyInputKind::Press
            }
            MouseAction::Press => PtyInputKind::Ordered,
            MouseAction::Release => PtyInputKind::Release,
            MouseAction::Motion => PtyInputKind::Motion,
        };
        let mut forwarded = self.enqueue_pty_bytes(surface_id, surface, bytes, kind);
        forwarded.owned = true;
        Some(forwarded)
    }
}
