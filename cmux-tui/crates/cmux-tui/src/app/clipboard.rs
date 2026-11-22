//! Clipboard and toasts: copying the selection, status messages and short ids
//! to the clipboard, and showing and expiring toasts.

use std::io::Write;
use std::time::{Duration, Instant};

use base64::Engine;

use crate::app::App;
use crate::app::overlays::Toast;
use crate::app::selection::{Selection, StatusMessageSelection};
use crate::localization;
use crate::session::SurfaceHandle;

impl App {
    /// Copy the selected text to the host clipboard via OSC 52 (the host
    /// terminal owns the clipboard; this works over SSH too).
    pub(super) fn copy_selection(&mut self, sel: Selection) {
        let Some(surface) = self.session.surface(sel.surface) else { return };
        let (start, end) = sel.range();
        let Some(text) = surface.with_terminal(|t| t.selection_text_absolute(start, end)).flatten()
        else {
            return;
        };
        if text.is_empty() {
            return;
        }
        if let SurfaceHandle::Local(local, _) = &surface {
            local.set_selection_text(Some(text.clone()));
        }
        self.copy_text_to_clipboard(&text);
        self.show_toast(localization::catalog().menu.copied.to_string());
    }

    pub(super) fn copy_status_message_selection(&mut self) {
        let Some(text) = self
            .status_selection
            .as_ref()
            .map(StatusMessageSelection::selected_text)
            .filter(|text| !text.is_empty())
        else {
            return;
        };
        self.copy_text_to_clipboard(&text);
        self.show_toast(localization::catalog().menu.copied.to_string());
    }

    pub(super) fn copy_status_message(&mut self) {
        let Some(message) = self.status_message.clone() else { return };
        self.copy_text_to_clipboard(&message);
        self.show_toast(localization::catalog().menu.copied.to_string());
    }

    pub(super) fn copy_text_to_clipboard(&self, text: &str) {
        let encoded = base64::engine::general_purpose::STANDARD.encode(text.as_bytes());
        let lock = self.stdout_lock.clone();
        let _guard = lock.lock();
        if lock.recover_stream_locked().is_err() {
            return;
        }
        if self.ensure_graphics_writer_healthy().is_err() {
            return;
        }
        let mut stdout = std::io::stdout();
        let _ = write!(stdout, "\x1b]52;c;{encoded}\x07");
        let _ = stdout.flush();
    }

    pub(super) fn copy_short_id(&mut self, short_id: String) {
        self.copy_text_to_clipboard(&short_id);
        self.show_toast(format!("{} {short_id}", localization::catalog().menu.copied));
    }

    pub(super) fn show_toast(&mut self, text: String) {
        crate::client_log::info("toast", &text);
        self.toast = Some(Toast { text, deadline: Instant::now() + Duration::from_millis(1500) });
    }

    pub(super) fn expire_toast(&mut self) -> bool {
        if self.toast.as_ref().is_some_and(|toast| Instant::now() >= toast.deadline) {
            self.toast = None;
            true
        } else {
            false
        }
    }
}
