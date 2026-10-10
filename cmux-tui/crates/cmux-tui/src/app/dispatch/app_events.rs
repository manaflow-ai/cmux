//! App-level event handlers: status command updates, mux recovery, sidebar
//! plugin updates, machine updates, owner config reloads, browser resize
//! failures, normalized input and host input failures.

use std::sync::atomic::Ordering;

use crate::app::App;
use crate::app::host_input::TerminalInput;
use crate::app::pointer::TerminalPointerAdmission;
use crate::app::pointer::deferred::ReplayedInputContext;
use crate::app::render_pacing::RenderAction;
use crate::browser_input::BrowserResizeFailure;
use crate::localization;
use crate::machine::MachineUpdate;

impl App {
    pub(super) fn on_mux_recovery_complete(
        &mut self,
        recovery_generation: u64,
    ) -> anyhow::Result<RenderAction> {
        if recovery_generation != self.mux_recovery_generation.load(Ordering::Acquire) {
            return Ok(RenderAction::None);
        }
        if self
            .mux_recovery_generation
            .compare_exchange(recovery_generation, 0, Ordering::AcqRel, Ordering::Acquire)
            .is_err()
        {
            return Ok(RenderAction::None);
        }
        Ok(RenderAction::Draw)
    }

    pub(super) fn on_machine_updated_for_generation(
        &mut self,
        generation: u64,
        update: MachineUpdate,
    ) -> anyhow::Result<RenderAction> {
        if generation != self.machine_update_generation {
            return Ok(RenderAction::None);
        }
        Ok(match update {
            MachineUpdate::Ui(update) => self.apply_machine_ui_update(*update),
            MachineUpdate::DurableNotice(notice) => self.accept_durable_notice(notice),
            MachineUpdate::ConnectionProgress { machine_id, latest } => {
                self.apply_connection_progress(machine_id, latest)
            }
        })
    }

    pub(super) fn on_owner_config_reload_requested(&mut self) -> anyhow::Result<RenderAction> {
        let owner = self.owner_mux.clone();
        let request = owner.as_ref().map(|mux| mux.begin_config_reload_application());
        self.reload_config();
        if let (Some(owner), Some(request)) = (owner, request) {
            crate::session::apply_config_to_local_owner(&owner, &self.config);
            owner.complete_config_reload_application(request);
        }
        Ok(RenderAction::Draw)
    }

    pub(super) fn on_browser_resize_failed(
        &mut self,
        failure: BrowserResizeFailure,
    ) -> anyhow::Result<RenderAction> {
        self.status_message = Some(localization::catalog().graphics.browser_surface_resize_failed(
            failure.surface_id,
            failure.cols,
            failure.rows,
            &failure.error,
        ));
        Ok(RenderAction::Draw)
    }

    pub(super) fn on_normalized_input(
        &mut self,
        input: TerminalInput,
        input_sequence: Option<u64>,
        replay_context: Option<ReplayedInputContext>,
        terminal_pointer_admission: Option<TerminalPointerAdmission>,
    ) -> anyhow::Result<RenderAction> {
        let admission = replay_context.as_ref().and_then(|context| context.admission.as_ref());
        let semantic_result = admission.and_then(|value| value.semantic_result);
        let semantic_destination = self.semantic_destination_for_input(&input, admission);
        let action_destination = if matches!(&input, TerminalInput::FrontendAction { .. }) {
            semantic_destination.or_else(|| admission.and_then(|value| value.destination))
        } else {
            semantic_destination
        };
        let action_fallback_destination = self
            .input_creates_session_destination(&input)
            .then(|| admission.and_then(|value| value.destination))
            .flatten()
            .filter(|fallback| Some(*fallback) != action_destination);
        self.dispatch_terminal_input(
            input,
            input_sequence,
            terminal_pointer_admission,
            semantic_result,
            action_destination,
            action_fallback_destination,
        )
    }
}
