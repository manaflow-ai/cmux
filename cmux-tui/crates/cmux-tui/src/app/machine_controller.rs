//! App side of the machine controller: the selected machine and its
//! transition, connection progress and transactions, machine update stream
//! restarts, provider reconnect backoff, and controller completions.

use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use crate::app::frame_geometry::content_size_for_rect;
use crate::app::layout::FocusTarget;
use crate::app::machine_worker::{
    MachineControllerCompletion, MachineSessionPreparation, MachineSubmitError, MachineUpdatePump,
    PendingMachineReplacement, PreparedMachineAction,
};
use crate::app::overlays::{ConnectionDialogPhase, PromptTarget};
use crate::app::{
    App, DURABLE_NOTICE_ACK_MAX_BACKOFF_EXPONENT, MACHINE_PROVIDER_RECONNECT_MAX_BACKOFF_EXPONENT,
    RenderAction,
};
use crate::localization;
use crate::machine::{
    MachineActionResult, MachineConnectionPhase, MachineKey, MachineRailTarget, MachineRequest,
    MachineTransitionView, MachineUiState, MachineUpdateStream, WorkspaceCreationMode,
    WorkspaceCreationPolicy,
};

impl App {
    pub(crate) fn selected_machine(&self) -> Option<MachineKey> {
        self.machine_selection_intent.or(self.machine_presented)
    }

    pub(crate) fn machine_transition(&self) -> Option<MachineTransitionView<'_>> {
        let selected = self.machine_selection_intent?;
        let ui = self.machine_ui.as_ref()?;
        if self.machine_presented == Some(selected) && ui.session_available {
            return None;
        }
        // Switching to a machine whose connection is already warm settles in
        // one round-trip: keep painting the current machine instead of
        // blanking the content with a "connecting" interstitial. Only while
        // the current machine is actually paintable - if its session is gone
        // (it paused; its stream died), "keep painting it" would show a dead
        // screen with no sign a switch is running.
        if self.machine_presented.is_some()
            && self.machine_presented != Some(selected)
            && ui.session_available
            && ui.connection_phase(selected) == MachineConnectionPhase::Ready
        {
            return None;
        }
        let machine = ui.snapshot.machines.iter().find(|machine| machine.key == selected)?;
        Some(MachineTransitionView {
            name: machine.name.as_str(),
            phase: ui.connection_phase(selected),
            status: machine.status,
            progress: ui.connection_progress(selected),
        })
    }

    /// Latest provider progress for a machine that is opening. Presentation
    /// only: dropped when the switch settles, fails, or is re-aimed.
    pub(super) fn apply_connection_progress(
        &mut self,
        machine_id: String,
        latest: Arc<Mutex<Option<String>>>,
    ) -> RenderAction {
        // Latest-value cell: the pump overwrites it while this update sat in
        // the queue, so this read is the newest stage; an emptied cell means
        // a newer update for this machine already consumed it.
        let Some(message) = latest.lock().unwrap_or_else(|p| p.into_inner()).take() else {
            return RenderAction::None;
        };
        let Some(ui) = self.machine_ui.as_mut() else { return RenderAction::None };
        let Some(key) = ui
            .snapshot
            .machines
            .iter()
            .find(|machine| machine.id == machine_id)
            .map(|machine| machine.key)
        else {
            return RenderAction::None;
        };
        // Progress is only meaningful while an open for this machine is
        // being shown. A late event queued before the open settled (failed,
        // or presented) must not repopulate the stage the settle cleared.
        match ui.connection_phase(key) {
            MachineConnectionPhase::Connecting => {}
            MachineConnectionPhase::Ready
                if self.machine_selection_intent == Some(key)
                    && self.machine_presented != Some(key) =>
            {
                // The aim believed this target was warm, but the provider is
                // narrating an open: the pooled session was dead and a real
                // (re)connect or wake is running. Flip to Connecting so the
                // interstitial appears instead of silently showing the old
                // machine for the whole reconnect.
                ui.set_connection_phase(key, MachineConnectionPhase::Connecting);
            }
            _ => return RenderAction::None,
        }
        ui.set_connection_progress(key, message);
        if self.machine_selection_intent == Some(key) {
            RenderAction::Draw
        } else {
            RenderAction::None
        }
    }

    pub(super) fn select_machine_intent(&mut self, machine: MachineKey) {
        if self.machine_selection_intent != Some(machine) {
            self.cancel_pointer_interaction();
            self.machine_selection_generation =
                self.machine_selection_generation.wrapping_add(1).max(1);
            self.machine_selection_intent = Some(machine);
            // A fresh aim starts with a fresh interstitial, not the last
            // attempt's progress message.
            if let Some(ui) = self.machine_ui.as_mut() {
                ui.clear_connection_progress(machine);
            }
        }
        let presented_live = self.machine_presented == Some(machine)
            && self.machine_ui.as_ref().is_some_and(|ui| ui.session_available);
        if let Some(ui) = self.machine_ui.as_mut() {
            let phase = if presented_live
                || ui.connection_phase(machine) == MachineConnectionPhase::Ready
            {
                // A warm pooled connection stays Ready: the switch reuses it,
                // so neither the rail badge nor the content interstitial
                // should flash "connecting". A presented machine whose
                // session is gone (it paused; the stream died) is NOT ready:
                // reselecting it starts a real wake, and the interstitial
                // must say so instead of briefly claiming Ready.
                MachineConnectionPhase::Ready
            } else {
                MachineConnectionPhase::Connecting
            };
            ui.set_connection_phase(machine, phase);
        }
    }

    pub fn workspace_creation_policy(&self) -> Option<WorkspaceCreationPolicy> {
        self.machine_ui.as_ref().map_or(
            Some(WorkspaceCreationPolicy::SessionOwned),
            MachineUiState::workspace_creation_policy,
        )
    }

    pub(crate) fn workspace_creation_modes(&self) -> Vec<Option<WorkspaceCreationMode>> {
        match self.workspace_creation_policy() {
            Some(WorkspaceCreationPolicy::SessionOwned) => vec![None],
            Some(WorkspaceCreationPolicy::ProviderOwned { modes, .. }) => {
                modes.into_iter().map(Some).collect()
            }
            None => Vec::new(),
        }
    }

    pub(super) fn default_workspace_creation_mode(&self) -> Option<Option<WorkspaceCreationMode>> {
        match self.workspace_creation_policy()? {
            WorkspaceCreationPolicy::SessionOwned => Some(None),
            WorkspaceCreationPolicy::ProviderOwned { default_mode, modes } => {
                modes.contains(&default_mode).then_some(Some(default_mode))
            }
        }
    }
}

impl App {
    pub(super) fn restart_machine_updates(&mut self) -> anyhow::Result<()> {
        let Some(worker) = self.machine_action_worker.as_ref() else {
            return Ok(());
        };
        if !worker.subscribe_updates() {
            anyhow::bail!(localization::catalog().sidebar.machine_replacement_worker_stopped)
        }
        Ok(())
    }

    fn replace_machine_updates(
        &mut self,
        updates: Option<MachineUpdateStream>,
    ) -> anyhow::Result<()> {
        let generation = self.machine_update_generation.wrapping_add(1).max(1);
        let next = updates
            .map(|updates| MachineUpdatePump::spawn(updates, self.app_events.clone(), generation))
            .transpose()?;
        if let Some(mut current) = self.machine_update_pump.take() {
            current.stop_and_join();
        }
        self.machine_update_pump = next;
        self.machine_update_generation = generation;
        Ok(())
    }

    pub(super) fn shutdown_background_workers(&mut self) {
        if let Some(stop) = self.status_command_worker_stop.take() {
            stop.raise();
        }
        // Join, so a status command's process group is reaped before exit.
        // The capture loop observes the flag every poll tick, so each join
        // is bounded by that tick.
        for handle in
            self.status_command_workers.drain(..).chain(self.retiring_status_workers.drain(..))
        {
            let _ = handle.join();
        }
        self.frontend_journal.stop_and_join();
        if let Some(mut updates) = self.machine_update_pump.take() {
            updates.stop_and_join();
        }
        if let Some(mut actions) = self.machine_action_worker.take() {
            actions.shutdown();
        }
        if let Some(mut session_events) = self.session_event_worker.take() {
            session_events.stop_and_join();
        }
        if let Some(mut owner_reload) = self.owner_reload_worker.take() {
            owner_reload.stop_and_join();
        }
    }

    pub(super) fn shutdown_runtime_components(&mut self) {
        self.host_input.shutdown();
        self.shutdown_background_workers();
        self.cancel_pointer_interaction();
        self.session.begin_shutdown();
        let _ = self.pty_input.shutdown(Duration::from_secs(3));
        if let Some(writer) = self.graphics_writer.as_mut() {
            writer.shutdown(Duration::from_millis(200));
        }
        let _ = std::panic::take_hook();
    }

    pub(super) fn process_machine_requests(&mut self) -> RenderAction {
        self.submit_pending_durable_notice_ack();
        if self.machine_action_in_flight {
            return RenderAction::None;
        }
        if let Some(retry_at) = self.machine_provider_reconnect_retry_at {
            if Instant::now() < retry_at {
                if self
                    .machine_ui
                    .as_ref()
                    .is_some_and(|ui| matches!(ui.request, Some(MachineRequest::ReconnectProvider)))
                {
                    return RenderAction::None;
                }
            } else if let Some(ui) = self.machine_ui.as_mut()
                && ui.request.is_none()
            {
                ui.request = Some(MachineRequest::ReconnectProvider);
            }
        }
        let Some(request) = self.machine_ui.as_mut().and_then(|ui| ui.request.take()) else {
            return RenderAction::None;
        };
        crate::client_log::info(
            "machine",
            &format!("dispatching machine request: {}", request.kind()),
        );
        if let MachineRequest::Switch(machine) = &request {
            self.select_machine_intent(*machine);
        }
        let Some(worker) = self.machine_action_worker.as_ref() else {
            if let Some(ui) = self.machine_ui.as_mut() {
                ui.request = Some(request);
            }
            self.quit = true;
            return RenderAction::None;
        };
        let preparation = MachineSessionPreparation {
            initial_size: content_size_for_rect(
                self.content_area,
                self.config.scrollbar.position,
                self.config.pane.padding,
            ),
            generation: self.session_generation.wrapping_add(1).max(1),
            pty_input: self.pty_input.sender(),
            surface_filter: self.surface_only,
        };
        match worker.perform(request.clone(), preparation) {
            Ok(()) => {
                self.machine_action_connection_attempt = self
                    .connection_transaction
                    .as_ref()
                    .filter(|transaction| {
                        matches!(
                            &request,
                            MachineRequest::Connect { target, route }
                                if target == &transaction.target && route == &transaction.route
                        )
                    })
                    .map(|transaction| transaction.attempt);
                self.machine_action_in_flight = true;
                self.machine_action_request = Some(request);
                self.machine_action_intent_generation = Some(self.machine_selection_generation);
            }
            Err(MachineSubmitError::Busy(request)) => {
                if let Some(ui) = self.machine_ui.as_mut() {
                    ui.request = Some(request);
                }
            }
            Err(MachineSubmitError::Stopped(request)) => {
                if let Some(ui) = self.machine_ui.as_mut() {
                    ui.request = Some(request);
                }
                self.quit = true;
            }
        }
        RenderAction::None
    }

    pub(super) fn schedule_machine_provider_reconnect(&mut self) {
        self.machine_provider_reconnect_attempts =
            self.machine_provider_reconnect_attempts.saturating_add(1);
        let exponent = self
            .machine_provider_reconnect_attempts
            .saturating_sub(1)
            .min(MACHINE_PROVIDER_RECONNECT_MAX_BACKOFF_EXPONENT);
        self.machine_provider_reconnect_retry_at =
            Some(Instant::now() + Duration::from_secs(1_u64 << exponent));
        if let Some(ui) = self.machine_ui.as_mut()
            && ui.request.is_none()
        {
            ui.request = Some(MachineRequest::ReconnectProvider);
        }
    }

    pub(super) fn clear_machine_provider_reconnect(&mut self) {
        self.machine_provider_reconnect_attempts = 0;
        self.machine_provider_reconnect_retry_at = None;
    }

    fn connection_attempt_was_canceled(&self, attempt: Option<u64>) -> bool {
        attempt.is_some() && self.canceled_machine_connection_attempt == attempt
    }

    fn take_machine_action_request(&mut self) -> (Option<MachineRequest>, Option<u64>, bool) {
        self.machine_action_intent_generation = None;
        let request = self.machine_action_request.take();
        let attempt = self.machine_action_connection_attempt.take();
        let canceled = self.connection_attempt_was_canceled(attempt);
        if canceled {
            self.canceled_machine_connection_attempt = None;
        }
        (request, attempt, canceled)
    }

    fn connection_request_matches(
        &self,
        request: Option<&MachineRequest>,
        attempt: Option<u64>,
    ) -> bool {
        let Some(transaction) = self.connection_transaction.as_ref() else { return false };
        attempt == Some(transaction.attempt)
            && matches!(
                request,
                Some(MachineRequest::Connect { target, route })
                    if target == &transaction.target && route == &transaction.route
            )
    }

    fn advance_connection_transaction(
        &mut self,
        request: Option<&MachineRequest>,
        attempt: Option<u64>,
        phase: ConnectionDialogPhase,
    ) {
        if self.connection_request_matches(request, attempt)
            && let Some(transaction) = self.connection_transaction.as_mut()
        {
            transaction.phase = phase;
        }
    }

    pub(super) fn fail_connection_transaction(
        &mut self,
        request: Option<&MachineRequest>,
        attempt: Option<u64>,
        error: String,
    ) -> bool {
        if !self.connection_request_matches(request, attempt) {
            return false;
        }
        self.advance_connection_transaction(
            request,
            attempt,
            ConnectionDialogPhase::Failed(error.clone()),
        );
        self.status_message = Some(error);
        true
    }

    pub(super) fn report_machine_action_failure(
        &mut self,
        request: Option<&MachineRequest>,
        attempt: Option<u64>,
        message: String,
    ) {
        let is_connection = matches!(request, Some(MachineRequest::Connect { .. }));
        let matched = self.fail_connection_transaction(request, attempt, message.clone());
        if !matched && (!is_connection || self.connection_transaction.is_none()) {
            self.status_message = Some(message);
        }
    }

    fn complete_connection_transaction(
        &mut self,
        request: Option<&MachineRequest>,
        attempt: Option<u64>,
    ) {
        if !self.connection_request_matches(request, attempt) {
            return;
        }
        self.connection_transaction = None;
        if self
            .prompt
            .as_ref()
            .is_some_and(|prompt| matches!(prompt.target, PromptTarget::ConnectMachine(_)))
        {
            self.prompt = None;
        }
    }

    pub(super) fn fail_machine_action(&mut self, request: Option<&MachineRequest>) {
        crate::client_log::info(
            "machine",
            &format!(
                "machine request failed: {}",
                request.map(MachineRequest::kind).unwrap_or("none")
            ),
        );
        if let Some(MachineRequest::Switch(machine)) = request
            && let Some(ui) = self.machine_ui.as_mut()
        {
            ui.set_connection_phase(*machine, MachineConnectionPhase::Failed);
            // A stale progress message must not sit under "unavailable".
            ui.clear_connection_progress(*machine);
        }
    }

    pub(super) fn apply_machine_controller_completion(
        &mut self,
        completion: MachineControllerCompletion,
    ) -> RenderAction {
        match completion {
            MachineControllerCompletion::DurableNoticeAcknowledged { delivery, result } => {
                let mut continue_acknowledgements = true;
                if self.durable_notice_ack_in_flight.as_ref() == Some(&delivery) {
                    self.durable_notice_ack_in_flight = None;
                    match result {
                        Ok(()) => {
                            self.durable_notice_ack_failures = 0;
                            self.durable_notice_ack_retry_at = None;
                        }
                        Err(_) => {
                            continue_acknowledgements = false;
                            self.durable_notice_ack_failures =
                                self.durable_notice_ack_failures.saturating_add(1);
                            let exponent = self
                                .durable_notice_ack_failures
                                .saturating_sub(1)
                                .min(DURABLE_NOTICE_ACK_MAX_BACKOFF_EXPONENT);
                            self.durable_notice_ack_retry_at =
                                Some(Instant::now() + Duration::from_secs(1_u64 << exponent));
                            self.schedule_machine_provider_reconnect();
                        }
                    }
                }
                if continue_acknowledgements {
                    self.submit_pending_durable_notice_ack();
                }
                RenderAction::None
            }
            MachineControllerCompletion::Updates(updates) => {
                if let Err(error) = updates
                    .map_err(anyhow::Error::msg)
                    .and_then(|updates| self.replace_machine_updates(updates))
                {
                    self.status_message = Some(format!(
                        "{}: {error}",
                        localization::catalog().sidebar.machine_catalog_updates_failed
                    ));
                    return RenderAction::Draw;
                }
                RenderAction::None
            }
            MachineControllerCompletion::Action { result, updates } => {
                self.machine_action_in_flight = false;
                let (request, connection_attempt, connection_canceled) =
                    self.take_machine_action_request();
                let reconnecting =
                    matches!(request.as_ref(), Some(MachineRequest::ReconnectProvider));
                if connection_canceled {
                    drop((result, updates));
                    return RenderAction::Draw;
                }
                let result = match result {
                    Ok(result) => result,
                    Err(error) => {
                        self.fail_machine_action(request.as_ref());
                        if reconnecting {
                            self.schedule_machine_provider_reconnect();
                        }
                        let message = format!(
                            "{}: {error}",
                            localization::catalog().sidebar.machine_action_failed
                        );
                        self.report_machine_action_failure(
                            request.as_ref(),
                            connection_attempt,
                            message,
                        );
                        return RenderAction::Draw;
                    }
                };
                if reconnecting {
                    self.clear_machine_provider_reconnect();
                }
                let MachineActionResult {
                    ui,
                    replacement,
                    restart_updates: _,
                    session_mutation,
                    session_label,
                } = *result;
                debug_assert!(replacement.is_none());
                let mut action = RenderAction::None;
                drop(replacement);
                if let Some(label) = session_label {
                    self.session_label = label;
                }
                action = action.merge(self.apply_machine_ui_update(ui));
                // Provider notices apply before local mirror errors so they cannot mask them.
                if let Some(mutation) = session_mutation {
                    self.apply_managed_workspace_session_mutation(mutation);
                }
                if let Some(updates) = updates
                    && let Err(error) = updates
                        .map_err(anyhow::Error::msg)
                        .and_then(|updates| self.replace_machine_updates(updates))
                {
                    self.status_message = Some(format!(
                        "{}: {error}",
                        localization::catalog().sidebar.machine_catalog_restart_failed
                    ));
                    action = action.merge(RenderAction::Draw);
                }
                self.complete_connection_transaction(request.as_ref(), connection_attempt);
                action
            }
            MachineControllerCompletion::ReplacementPrepared { action_id, action } => {
                let connection_canceled =
                    self.connection_attempt_was_canceled(self.machine_action_connection_attempt);
                if self.pending_machine_replacement.is_some() {
                    if let Some(worker) = self.machine_action_worker.as_ref() {
                        let _ = worker.abort_replacement(action_id);
                    }
                    self.machine_action_in_flight = false;
                    let (request, connection_attempt, connection_canceled) =
                        self.take_machine_action_request();
                    self.fail_machine_action(request.as_ref());
                    if matches!(request.as_ref(), Some(MachineRequest::ReconnectProvider)) {
                        self.schedule_machine_provider_reconnect();
                    }
                    let message = format!(
                        "{}: {}",
                        localization::catalog().sidebar.machine_action_failed,
                        localization::catalog().sidebar.machine_replacement_pending
                    );
                    if !connection_canceled {
                        self.report_machine_action_failure(
                            request.as_ref(),
                            connection_attempt,
                            message,
                        );
                    }
                    return RenderAction::Draw;
                }
                let request = self.machine_action_request.clone();
                self.advance_connection_transaction(
                    request.as_ref(),
                    self.machine_action_connection_attempt,
                    ConnectionDialogPhase::Starting,
                );
                let present = !connection_canceled
                    && self.machine_action_intent_generation
                        == Some(self.machine_selection_generation)
                    && match self.machine_action_request.as_ref() {
                        Some(MachineRequest::Switch(_)) => action
                            .session
                            .machine
                            .is_none_or(|machine| self.machine_selection_intent == Some(machine)),
                        _ => true,
                    };
                crate::client_log::info(
                    "machine",
                    &format!(
                        "replacement prepared: present={present} canceled={connection_canceled}"
                    ),
                );
                self.pending_machine_replacement =
                    Some(PendingMachineReplacement { action_id, present, action: *action });
                if self
                    .machine_action_worker
                    .as_ref()
                    .is_none_or(|worker| !worker.commit_replacement(action_id, present))
                {
                    self.pending_machine_replacement.take();
                    self.machine_action_in_flight = false;
                    let (request, connection_attempt, connection_canceled) =
                        self.take_machine_action_request();
                    self.fail_machine_action(request.as_ref());
                    if matches!(request.as_ref(), Some(MachineRequest::ReconnectProvider)) {
                        self.schedule_machine_provider_reconnect();
                    }
                    let message = format!(
                        "{}: {}",
                        localization::catalog().sidebar.machine_action_failed,
                        localization::catalog().sidebar.machine_replacement_worker_stopped
                    );
                    if !connection_canceled {
                        self.report_machine_action_failure(
                            request.as_ref(),
                            connection_attempt,
                            message,
                        );
                    }
                    return RenderAction::Draw;
                }
                RenderAction::Draw
            }
            MachineControllerCompletion::ReplacementSettled { action_id, committed, updates } => {
                if self
                    .pending_machine_replacement
                    .as_ref()
                    .is_none_or(|pending| pending.action_id != action_id)
                {
                    self.status_message = Some(format!(
                        "{}: {}",
                        localization::catalog().sidebar.machine_action_failed,
                        localization::catalog().sidebar.machine_replacement_stale
                    ));
                    return RenderAction::Draw;
                }
                let pending = self
                    .pending_machine_replacement
                    .take()
                    .expect("matching pending replacement was checked");
                self.machine_action_in_flight = false;
                let (request, connection_attempt, connection_canceled) =
                    self.take_machine_action_request();
                let reconnecting =
                    matches!(request.as_ref(), Some(MachineRequest::ReconnectProvider));
                let mut action = RenderAction::None;
                match committed {
                    Ok(true) => {
                        if reconnecting {
                            self.clear_machine_provider_reconnect();
                        }
                        let PendingMachineReplacement { present, action: prepared, .. } = pending;
                        let present = present && !connection_canceled;
                        let PreparedMachineAction { ui, session_mutation, session_label, session } =
                            prepared;
                        let target = session.machine;
                        crate::client_log::info(
                            "machine",
                            &format!(
                                "replacement settled: present={present} target={:?} ui_active={:?}",
                                target.map(|k| k.0),
                                ui.snapshot.active.map(|k| k.0),
                            ),
                        );
                        if present {
                            self.machine_presented = target.or(ui.snapshot.active);
                            // A runtime-driven replacement (deleting the open
                            // machine) presents without a Switch dispatch, so
                            // the aim never moved; align it, or every later
                            // keystroke fails the intent==presented gate and
                            // input goes nowhere.
                            if let Some(machine) = self.machine_presented {
                                self.select_machine_intent(machine);
                            }
                            if let Some(machine) = self.machine_presented
                                && let Some(machine_ui) = self.machine_ui.as_mut()
                            {
                                machine_ui.clear_connection_progress(machine);
                            }
                            self.install_prepared_machine_session(session, false);
                            if let Some(label) = session_label {
                                self.session_label = label;
                            }
                            action = action.merge(self.apply_machine_ui_update(ui));
                            // The rail follows the machine that now presents,
                            // not whatever row reconciliation kept (the
                            // deleted machine's recoverable ghost, usually).
                            if let Some(machine) = self.machine_presented
                                && let Some(machine_ui) = self.machine_ui.as_mut()
                            {
                                machine_ui.select_rail_target(MachineRailTarget::Machine(machine));
                            }
                            // Provider notices apply before local mirror errors so they cannot mask them.
                            if let Some(mutation) = session_mutation {
                                self.apply_managed_workspace_session_mutation(mutation);
                            }
                            if self.tree.active_surface().is_some() {
                                self.focus = FocusTarget::Pane;
                            }
                        } else {
                            if let Some(target) = target
                                && let Some(ui) = self.machine_ui.as_mut()
                            {
                                ui.set_connection_phase(target, MachineConnectionPhase::Ready);
                            }
                            drop((ui, session_mutation, session_label, session));
                            action = action.merge(RenderAction::Draw);
                        }
                        self.complete_connection_transaction(request.as_ref(), connection_attempt);
                    }
                    Ok(false) => {
                        crate::client_log::info("machine", "replacement settled: not committed");
                        drop(pending);
                        if reconnecting {
                            self.schedule_machine_provider_reconnect();
                        }
                    }
                    Err(error) => {
                        drop(pending);
                        self.fail_machine_action(request.as_ref());
                        if reconnecting {
                            self.schedule_machine_provider_reconnect();
                        }
                        if !connection_canceled {
                            let message = format!(
                                "{}: {error}",
                                localization::catalog().sidebar.machine_action_failed
                            );
                            self.report_machine_action_failure(
                                request.as_ref(),
                                connection_attempt,
                                message,
                            );
                        }
                        action = action.merge(RenderAction::Draw);
                    }
                }
                if let Some(updates) = updates
                    && let Err(error) = updates
                        .map_err(anyhow::Error::msg)
                        .and_then(|updates| self.replace_machine_updates(updates))
                {
                    self.status_message = Some(format!(
                        "{}: {error}",
                        localization::catalog().sidebar.machine_catalog_restart_failed
                    ));
                    action = action.merge(RenderAction::Draw);
                }
                action
            }
        }
    }
}
