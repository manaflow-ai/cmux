//! Forwarding keys and pastes to surfaces: terminal key encoding per surface
//! and pane, the sidebar plugin, browser key mapping, and paste delivery.

use cmux_tui_core::{PaneId, SurfaceId, SurfaceKind};
use crossterm::event::{KeyCode, KeyEvent, KeyEventKind, KeyModifiers};

use crate::app::{App, browser_key_mapping, browser_modifiers};
use crate::browser_input::{BrowserInputEvent, BrowserInputKind};
use crate::pty_input::{PtyInputBytes, PtyInputKind};
use crate::session::SurfaceHandle;
use crate::{keys, localization};

impl App {
    pub(super) fn forward_key(&mut self, input: keys::KeyboardInput) {
        if !self.session_available() {
            // Coming back to a machine that paused or lost its stream: the
            // first keystroke wakes it instead of bouncing off a dead pane.
            if self.wake_presented_machine() {
                return;
            }
            self.status_message =
                Some(localization::catalog().sidebar.no_active_session.to_string());
            return;
        }
        let Some(surface_id) = self.active_surface() else { return };
        self.forward_key_to_surface(input, surface_id);
    }

    pub(super) fn forward_key_to_surface(
        &mut self,
        input: keys::KeyboardInput,
        surface_id: SurfaceId,
    ) {
        if !self.session_available() {
            if self.wake_presented_machine() {
                return;
            }
            self.status_message =
                Some(localization::catalog().sidebar.no_active_session.to_string());
            return;
        }
        let Some(surface) = self.session.surface(surface_id) else { return };
        if surface.kind() == SurfaceKind::Browser {
            let key = input.ui_key();
            if matches!(key.code, KeyCode::Char('l') | KeyCode::Char('L'))
                && key.modifiers.contains(KeyModifiers::CONTROL)
            {
                if let Some(pane) = self.pane_for_surface(surface_id) {
                    self.focus_omnibar(pane);
                }
                return;
            }
            self.forward_browser_key_to(surface_id, surface, input);
            return;
        }
        let Some(input) = input.into_terminal_input() else {
            return;
        };
        self.encode_buf.clear();
        let _ = surface.scroll_to_bottom();
        let Some(encoded) = surface.with_terminal(|term| {
            self.encoder.sync_from_terminal(term);
            self.encoder.encode(&input, &mut self.encode_buf)
        }) else {
            return;
        };
        if encoded.is_ok() && !self.encode_buf.is_empty() {
            let _ = self.write_encoded_pty_bytes(surface_id, surface, PtyInputKind::Ordered);
        }
    }

    pub(super) fn forward_key_to_pane(&mut self, key: &KeyEvent, pane: Option<PaneId>) {
        if pane == self.active_pane() {
            self.forward_key((*key).into());
            return;
        }
        if !self.session_available() {
            if self.wake_presented_machine() {
                return;
            }
            self.status_message =
                Some(localization::catalog().sidebar.no_active_session.to_string());
            return;
        }
        let Some(surface_id) =
            pane.and_then(|pane| self.tree.pane(pane)).and_then(|pane| pane.active_surface())
        else {
            return;
        };
        let Some(surface) = self.session.surface(surface_id) else { return };
        if surface.kind() == SurfaceKind::Pty {
            self.forward_pty_key_to_surface(key, surface_id, surface);
        }
    }

    fn forward_pty_key_to_surface(
        &mut self,
        key: &KeyEvent,
        surface_id: SurfaceId,
        surface: SurfaceHandle,
    ) {
        let Some(input) = keys::key_input_from(key) else { return };
        self.encode_buf.clear();
        let _ = surface.scroll_to_bottom();
        let Some(encoded) = surface.with_terminal(|term| {
            self.encoder.sync_from_terminal(term);
            self.encoder.encode(&input, &mut self.encode_buf)
        }) else {
            return;
        };
        if encoded.is_ok() && !self.encode_buf.is_empty() {
            let _ = self.write_encoded_pty_bytes(surface_id, surface, PtyInputKind::Ordered);
        }
    }

    pub(super) fn forward_sidebar_key(&mut self, input: keys::KeyboardInput) {
        let Some(input) = input.into_terminal_input() else {
            return;
        };
        let Some(surface_id) = self.sidebar_plugin_surface else { return };
        let Some(surface) = self.sidebar_surface_handle() else { return };
        self.encode_buf.clear();
        let _ = surface.scroll_to_bottom();
        let Some(encoded) = surface.with_terminal(|term| {
            self.encoder.sync_from_terminal(term);
            self.encoder.encode(&input, &mut self.encode_buf)
        }) else {
            return;
        };
        if encoded.is_ok() && !self.encode_buf.is_empty() {
            let _ = self.write_encoded_pty_bytes(surface_id, surface, PtyInputKind::Ordered);
        }
    }

    pub(super) fn forward_browser_key_to(
        &mut self,
        surface_id: SurfaceId,
        surface: SurfaceHandle,
        mut input: keys::KeyboardInput,
    ) {
        let key = input.ui_key();
        if let Some(text) = input.take_text_for_direct_input() {
            let _ = self.browser_input.enqueue(BrowserInputEvent {
                surface_id,
                surface,
                kind: BrowserInputKind::InsertText(text),
            });
            return;
        }
        if let KeyCode::Char(c) = key.code
            && !key.modifiers.intersects(keys::SHORTCUT_MODIFIERS)
        {
            let _ = self.browser_input.enqueue(BrowserInputEvent {
                surface_id,
                surface,
                kind: BrowserInputKind::InsertText(c.to_string()),
            });
            return;
        }
        let Some((key_name, code, vk, text)) =
            browser_key_mapping(key.code, input.base_layout_key())
        else {
            return;
        };
        let Some(modifiers) = browser_modifiers(key.modifiers) else {
            return;
        };
        let kind = if key.kind == KeyEventKind::Press {
            BrowserInputKind::KeyPress {
                key: key_name,
                code,
                windows_virtual_key_code: vk,
                modifiers,
                text,
            }
        } else {
            BrowserInputKind::Key {
                event_type: "keyDown",
                key: key_name,
                code,
                windows_virtual_key_code: vk,
                modifiers,
                text,
            }
        };
        let _ = self.browser_input.enqueue(BrowserInputEvent { surface_id, surface, kind });
    }

    pub(super) fn paste(&mut self, text: &str) {
        if !self.session_available() {
            self.status_message =
                Some(localization::catalog().sidebar.no_active_session.to_string());
            return;
        }
        let Some(surface_id) = self.active_surface() else { return };
        self.paste_to_surface(text, surface_id);
    }

    pub(super) fn paste_to_surface(&mut self, text: &str, surface_id: SurfaceId) {
        if !self.session_available() {
            self.status_message =
                Some(localization::catalog().sidebar.no_active_session.to_string());
            return;
        }
        let Some(surface) = self.session.surface(surface_id) else { return };
        if surface.kind() == SurfaceKind::Browser {
            let _ = self.browser_input.enqueue(BrowserInputEvent {
                surface_id,
                surface,
                kind: BrowserInputKind::InsertText(text.to_string()),
            });
            return;
        }
        let Some(bracketed) = surface.with_terminal(|t| t.mode(2004, false)) else {
            return;
        };
        if bracketed {
            let mut bytes = Vec::with_capacity(text.len() + 12);
            bytes.extend_from_slice(b"\x1b[200~");
            bytes.extend_from_slice(text.as_bytes());
            bytes.extend_from_slice(b"\x1b[201~");
            let _ = self.write_pty_bytes(surface_id, surface, bytes.into(), PtyInputKind::Ordered);
        } else {
            let _ = self.write_pty_bytes(
                surface_id,
                surface,
                PtyInputBytes::from_slice(text.as_bytes()),
                PtyInputKind::Ordered,
            );
        }
    }

    pub(super) fn paste_sidebar(&mut self, text: &str) {
        let Some(surface_id) = self.sidebar_plugin_surface else { return };
        let Some(surface) = self.sidebar_surface_handle() else { return };
        let Some(bracketed) = surface.with_terminal(|t| t.mode(2004, false)) else {
            return;
        };
        if bracketed {
            let mut bytes = Vec::with_capacity(text.len() + 12);
            bytes.extend_from_slice(b"\x1b[200~");
            bytes.extend_from_slice(text.as_bytes());
            bytes.extend_from_slice(b"\x1b[201~");
            let _ = self.write_pty_bytes(surface_id, surface, bytes.into(), PtyInputKind::Ordered);
        } else {
            let _ = self.write_pty_bytes(
                surface_id,
                surface,
                PtyInputBytes::from_slice(text.as_bytes()),
                PtyInputKind::Ordered,
            );
        }
    }
}
