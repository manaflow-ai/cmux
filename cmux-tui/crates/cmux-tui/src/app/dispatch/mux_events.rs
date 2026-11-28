//! Mux event handlers: empty mux, surface exit and resize, graphics status,
//! config reload, surface output, pairing requests and resolutions.

use std::sync::Arc;

use cmux_tui_core::{GraphicsStatus, PairingChallenge, SurfaceId};

use crate::app::App;
use crate::app::overlays::PairingDialog;
use crate::app::render_pacing::RenderAction;
use crate::localization;

impl App {
    pub(super) fn on_mux_empty(&mut self) -> anyhow::Result<RenderAction> {
        // A genuinely emptied workspace list and a dead event
        // transport both end the event stream with this event, but
        // only the former is a clean exit. The remote reader records
        // why it stopped; consult that BEFORE any machine-session
        // request so a machine or provider surface cannot swallow the
        // dead transport into a stuck reconnect (issue 11042). A
        // deliberate local disconnect records no reason. The one
        // machine response that outranks the error is a sleeping or
        // stopped machine, whose stream loss is the designed result
        // of pausing it.
        if let Some(reason) = self.session.transport_disconnect_reason() {
            if self.present_machine_as_asleep_after_stream_loss() {
                return Ok(RenderAction::Draw);
            }
            crate::client_log::error("session", &format!("remote event transport lost: {reason}"));
            anyhow::bail!(localization::catalog().runtime.session_transport_lost());
        }
        if self.request_current_machine_session() {
            return Ok(RenderAction::Draw);
        }
        self.quit = true;
        Ok(RenderAction::None)
    }

    pub(super) fn on_surface_exited(&mut self, id: SurfaceId) -> anyhow::Result<RenderAction> {
        self.retire_surface_state(id);
        self.remove_surface_from_cached_tree(id);
        if self.surface_only == Some(id) {
            self.quit = true;
            return Ok(RenderAction::None);
        }
        Ok(RenderAction::Draw)
    }

    pub(super) fn on_surface_resize_failed(
        &mut self,
        surface: SurfaceId,
        cols: u16,
        rows: u16,
        error: Arc<str>,
        retry_after_ms: Option<u64>,
        reservation_id: Option<u64>,
    ) -> anyhow::Result<RenderAction> {
        if self.session.note_surface_resize_failure(
            surface,
            (cols, rows),
            retry_after_ms,
            reservation_id,
        ) {
            self.status_message = Some(
                localization::catalog()
                    .graphics
                    .browser_surface_resize_failed(surface, cols, rows, &error),
            );
            Ok(RenderAction::Draw)
        } else {
            Ok(RenderAction::None)
        }
    }

    pub(super) fn on_graphics_status(
        &mut self,
        status: GraphicsStatus,
    ) -> anyhow::Result<RenderAction> {
        let messages = &localization::catalog().graphics;
        let message = match status {
            GraphicsStatus::KittyImageBudgetWorkerStartFailed { error } => {
                messages.kitty_image_budget_worker_start_failed(&error)
            }
            // Kitty quota updates are advisory: the mux disables graphics
            // for an unresponsive surface and the terminal remains usable.
            // Keep the structured event available to logs and remote
            // observers, but do not replace user-facing command status
            // with a diagnostic the user cannot act on.
            GraphicsStatus::KittyImageBudgetUpdateFailed { retry_exhausted, summary } => {
                crate::client_log::log(
                    "WARN",
                    "kitty-graphics",
                    &messages.kitty_image_budget_update_failed(retry_exhausted, &summary),
                );
                return Ok(RenderAction::None);
            }
            GraphicsStatus::CellPixelUpdateRetriesExhausted {
                attempts,
                remaining,
                cell_pixels,
            } => messages.cell_pixel_update_retries_exhausted(attempts, remaining, cell_pixels),
        };
        self.status_message = Some(message);
        Ok(RenderAction::Draw)
    }

    pub(super) fn on_surface_output(&mut self, id: SurfaceId) -> anyhow::Result<RenderAction> {
        self.graphics_dirty_surfaces.insert(id);
        if self.sidebar_plugin_surface == Some(id) {
            return Ok(RenderAction::Paint);
        }
        if self.frame_only_browser_update(id) {
            Ok(RenderAction::Graphics)
        } else {
            Ok(RenderAction::Paint)
        }
    }

    pub(super) fn on_pairing_requested(
        &mut self,
        challenge: PairingChallenge,
    ) -> anyhow::Result<RenderAction> {
        let duplicate =
            self.pairing_dialog.as_ref().is_some_and(|dialog| dialog.challenge.id == challenge.id)
                || self.pairing_queue.iter().any(|queued| queued.id == challenge.id);
        if !duplicate {
            if self.pairing_dialog.is_none() {
                self.cancel_pointer_interaction();
                self.pairing_dialog = Some(PairingDialog::new(challenge));
            } else {
                self.pairing_queue.push_back(challenge);
            }
        }
        Ok(RenderAction::Draw)
    }

    pub(super) fn on_pairing_resolved(&mut self, request: u64) -> anyhow::Result<RenderAction> {
        self.pairing_queue.retain(|challenge| challenge.id != request);
        if self.pairing_dialog.as_ref().is_some_and(|dialog| dialog.challenge.id == request) {
            self.cancel_pointer_interaction();
            self.pairing_dialog = self.pairing_queue.pop_front().map(PairingDialog::new);
        }
        Ok(RenderAction::Draw)
    }
}
