//! Event dispatch for the App: after `handle_inner` has admitted an event
//! (session scoping, normalization, pending-mutation and pointer admission),
//! `dispatch_event` routes it by kind. Short arms stay inline; each larger
//! handler is an `on_<event>` method in `dispatch/{app,mux,session}_events.rs`.

mod app_events;
mod mux_events;
mod session_events;

// The arms came verbatim from app.rs and name its items and imports.
use crate::app::pointer::TerminalPointerAdmission;
use crate::app::*;

impl App {
    pub(super) fn dispatch_event(
        &mut self,
        event: AppEvent,
        input_sequence: Option<u64>,
        replay_context: Option<ReplayedInputContext>,
        terminal_pointer_admission: Option<TerminalPointerAdmission>,
    ) -> anyhow::Result<RenderAction> {
        match event {
            AppEvent::HostInputReady => Ok(RenderAction::None),
            AppEvent::GraphicsWriterReady => Ok(self.apply_graphics_completion()),
            AppEvent::MuxTitlesReady => {
                Ok(if self.apply_mux_titles() { RenderAction::Paint } else { RenderAction::None })
            }
            AppEvent::StatusCommandsUpdated => {
                self.status_poke_pending.store(false, Ordering::Release);
                Ok(if self.config.status_bar.visible && !self.is_surface_only() {
                    RenderAction::Draw
                } else {
                    RenderAction::None
                })
            }
            AppEvent::MuxSubscriptionRecovered {
                recovery_generation,
                destination_generation,
                result,
            } => self.on_mux_subscription_recovered(
                recovery_generation,
                destination_generation,
                result,
            ),
            AppEvent::MuxRecoveryComplete { recovery_generation } => {
                self.on_mux_recovery_complete(recovery_generation)
            }
            AppEvent::SidebarPluginUpdated { status, relaunch } => {
                self.apply_sidebar_plugin_status(status, relaunch);
                Ok(RenderAction::Draw)
            }
            #[cfg(test)]
            AppEvent::MachineUiUpdated(update) => Ok(self.apply_machine_ui_update(*update)),
            AppEvent::MachineUpdatedForGeneration { generation, update } => {
                self.on_machine_updated_for_generation(generation, *update)
            }
            AppEvent::MachineControllerCompleted(completion) => {
                Ok(self.apply_machine_controller_completion(*completion))
            }
            AppEvent::Mux(MuxEvent::Empty) => self.on_mux_empty(),
            AppEvent::Mux(MuxEvent::SurfaceExited(id)) => self.on_surface_exited(id),
            AppEvent::Mux(MuxEvent::SurfaceResized { surface, cols, rows, reservation_id }) => {
                self.session.confirm_surface_resize(surface, (cols, rows), reservation_id);
                // This acknowledges geometry already computed by the host-resize draw.
                // Re-running layout here creates an acknowledgement feedback loop while
                // the outer terminal is being dragged; only repaint terminal content.
                Ok(RenderAction::Paint)
            }
            AppEvent::Mux(MuxEvent::SurfaceResizeFailed {
                surface,
                cols,
                rows,
                error,
                retry_after_ms,
                reservation_id,
            }) => self.on_surface_resize_failed(
                surface,
                cols,
                rows,
                error,
                retry_after_ms,
                reservation_id,
            ),
            AppEvent::Mux(MuxEvent::Status(message)) => {
                self.status_message = Some(message);
                Ok(RenderAction::Draw)
            }
            AppEvent::Mux(MuxEvent::GraphicsStatus(status)) => self.on_graphics_status(status),
            AppEvent::Mux(MuxEvent::ConfigReloadRequested) => {
                if self.presenting_owner_session() {
                    return Ok(RenderAction::None);
                }
                self.reload_config();
                Ok(RenderAction::Draw)
            }
            AppEvent::OwnerConfigReloadRequested => self.on_owner_config_reload_requested(),
            AppEvent::Mux(MuxEvent::WindowTitleRequested(title)) => {
                self.write_window_title(&title)?;
                Ok(RenderAction::None)
            }
            AppEvent::Mux(MuxEvent::MachineUsageChanged(usage)) => {
                if self.machine_usage == usage {
                    return Ok(RenderAction::None);
                }
                self.machine_usage = usage;
                Ok(RenderAction::Draw)
            }
            AppEvent::Mux(MuxEvent::SurfaceOutput(id)) => self.on_surface_output(id),
            AppEvent::Mux(MuxEvent::PairingRequested(challenge)) => {
                self.on_pairing_requested(challenge)
            }
            AppEvent::Mux(MuxEvent::PairingResolved { request }) => {
                self.on_pairing_resolved(request)
            }
            AppEvent::Mux(
                MuxEvent::ClientAttached { .. }
                | MuxEvent::ClientChanged { .. }
                | MuxEvent::ClientDetached(_)
                | MuxEvent::ClientListInvalidated,
            ) => {
                self.session.refresh_clients_background();
                Ok(RenderAction::Draw)
            }
            AppEvent::Mux(MuxEvent::SizeStateChanged { surface, .. }) => {
                self.refresh_size_state_label(surface);
                Ok(RenderAction::Draw)
            }
            AppEvent::Mux(_) => Ok(RenderAction::Draw),
            AppEvent::BrowserResizeFailed(failure) => self.on_browser_resize_failed(failure),
            AppEvent::PtyFailuresReady => Ok(self.apply_pty_failures()),
            AppEvent::PtyOperationFailed(failure) => Ok(self.apply_pty_operation_failure(failure)),
            AppEvent::SurfaceAttachSettled { outcome } => self.on_surface_attach_settled(outcome),
            AppEvent::ClearHistorySucceeded {
                surface,
                input_revision,
                selection_at_invocation,
                selection_generation,
            } => self.on_clear_history_succeeded(
                surface,
                input_revision,
                selection_at_invocation,
                selection_generation,
            ),
            AppEvent::SessionMutationSettled { outcome, impact } => {
                self.on_session_mutation_settled(outcome, impact)
            }
            AppEvent::RemoteTreeUpdated { refresh_sequence, destination_generation, result } => {
                self.on_remote_tree_updated(refresh_sequence, destination_generation, result)
            }
            AppEvent::ClientsUpdated { generation, result } => {
                self.on_clients_updated(generation, result)
            }
            AppEvent::NormalizedInput(input) => self.on_normalized_input(
                input,
                input_sequence,
                replay_context,
                terminal_pointer_admission,
            ),
            AppEvent::HostInputFailed(error) => {
                anyhow::bail!(localization::catalog().runtime.host_input_failed(&error))
            }
            AppEvent::Input(_) => unreachable!("raw input is normalized before dispatch"),
            AppEvent::SessionScoped { .. } => {
                unreachable!("session-scoped events are unwrapped before dispatch")
            }
        }
    }
}
