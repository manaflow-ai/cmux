//! Machine controller plumbing: the machine action worker thread, the machine
//! update pump, machine session preparation and completions, and initial
//! workspace recovery for provider-managed machines.

use std::sync::Arc;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::mpsc::{RecvTimeoutError, TrySendError as StdTrySendError};
use std::thread::JoinHandle;
use std::time::Duration;

use cmux_tui_core::{Mux, SurfaceId};
use crossbeam_channel::Sender as SyncSender;

use crate::app::events::{
    AppEvent, EventCancellation, SessionEventWorker, send_bounded_cancelable,
};
use crate::app::mux_ingress::{MuxTitleIngress, prepare_ordered_session};
use crate::app::ordered_session::OrderedSession;
use crate::localization;
use crate::machine::{
    DurableNoticeDelivery, MachineActionResult, MachineController, MachineKey, MachineRequest,
    MachineSession, MachineUiState, MachineUpdateStream, ManagedWorkspaceSessionMutation,
    WorkspaceCreationPolicy, validate_machine_session,
};
use crate::pty_input::PtyInputSender;
use crate::session::{Session, TreeView};

pub(super) struct MachineUpdatePump {
    pub(super) stop: Arc<AtomicBool>,
    pub(super) cancellation: EventCancellation,
    pub(super) provider: Option<JoinHandle<()>>,
    pub(super) forwarder: Option<JoinHandle<()>>,
}

pub(super) enum MachineControllerCommand {
    Perform { request: MachineRequest, preparation: Box<MachineSessionPreparation> },
    SubscribeUpdates,
    AcknowledgeDurableNotice(DurableNoticeDelivery),
    CommitReplacement { action_id: u64, present: bool },
    AbortReplacement(u64),
}

pub(super) struct MachineSessionPreparation {
    pub(super) initial_size: Option<(u16, u16)>,
    pub(super) generation: u64,
    pub(super) pty_input: PtyInputSender,
    pub(super) surface_filter: Option<SurfaceId>,
}

pub(super) struct PreparedMachineSession {
    pub(super) session: OrderedSession,
    pub(super) event_worker: SessionEventWorker,
    pub(super) generation: u64,
    pub(super) mux_titles: Arc<MuxTitleIngress>,
    pub(super) mux_recovery_generation: Arc<AtomicU64>,
    pub(super) tree: TreeView,
    pub(super) label: String,
    pub(super) session_available: bool,
    pub(super) machine: Option<MachineKey>,
}

pub(crate) struct PreparedMachineAction {
    pub(super) ui: MachineUiState,
    pub(super) session_mutation: Option<ManagedWorkspaceSessionMutation>,
    pub(super) session_label: Option<String>,
    pub(super) session: PreparedMachineSession,
}

pub(super) struct PendingMachineReplacement {
    pub(super) action_id: u64,
    pub(super) present: bool,
    pub(super) action: PreparedMachineAction,
}

pub(crate) enum MachineControllerCompletion {
    Action {
        result: Result<Box<MachineActionResult>, String>,
        updates: Option<Result<Option<MachineUpdateStream>, String>>,
    },
    ReplacementPrepared {
        action_id: u64,
        action: Box<PreparedMachineAction>,
    },
    ReplacementSettled {
        action_id: u64,
        committed: Result<bool, String>,
        updates: Option<Result<Option<MachineUpdateStream>, String>>,
    },
    Updates(Result<Option<MachineUpdateStream>, String>),
    DurableNoticeAcknowledged {
        delivery: DurableNoticeDelivery,
        result: Result<(), String>,
    },
}

pub(super) struct MachineActionWorker {
    pub(super) sender: Option<std::sync::mpsc::SyncSender<MachineControllerCommand>>,
    pub(super) stop: Arc<AtomicBool>,
    pub(super) cancellation: EventCancellation,
    pub(super) worker: Option<JoinHandle<()>>,
}

#[derive(Debug)]
pub(super) enum MachineSubmitError {
    Busy(MachineRequest),
    Stopped(MachineRequest),
}

impl MachineActionWorker {
    pub(super) fn spawn(
        mut controller: Box<dyn MachineController>,
        app_events: SyncSender<AppEvent>,
    ) -> anyhow::Result<Self> {
        let (sender, receiver) = std::sync::mpsc::sync_channel(1);
        let stop = Arc::new(AtomicBool::new(false));
        let worker_stop = stop.clone();
        let cancellation = EventCancellation::new();
        let worker_cancellation = cancellation.clone();
        let worker =
            std::thread::Builder::new().name("machine-actions".into()).spawn(move || {
                let mut next_action_id = 1_u64;
                let mut pending_replacement: Option<(u64, bool)> = None;
                while !worker_stop.load(Ordering::Acquire) {
                    let command = match receiver.recv_timeout(Duration::from_millis(50)) {
                        Ok(command) => command,
                        Err(RecvTimeoutError::Timeout) => continue,
                        Err(RecvTimeoutError::Disconnected) => break,
                    };
                    let completion = match command {
                        MachineControllerCommand::Perform { request, preparation } => {
                            if pending_replacement.is_some() {
                                MachineControllerCompletion::Action {
                                    result: Err(localization::catalog()
                                        .sidebar
                                        .machine_replacement_pending
                                        .to_string()),
                                    updates: None,
                                }
                            } else {
                                match controller.perform(request) {
                                    Ok(MachineActionResult {
                                        ui,
                                        replacement: Some(replacement),
                                        restart_updates,
                                        session_mutation,
                                        session_label,
                                    }) => match prepare_machine_session(
                                        replacement,
                                        &ui,
                                        *preparation,
                                        app_events.clone(),
                                    ) {
                                        Ok(session) => {
                                            let action_id = next_action_id;
                                            next_action_id = next_action_id.wrapping_add(1).max(1);
                                            pending_replacement =
                                                Some((action_id, restart_updates));
                                            MachineControllerCompletion::ReplacementPrepared {
                                                action_id,
                                                action: Box::new(PreparedMachineAction {
                                                    ui,
                                                    session_mutation,
                                                    session_label,
                                                    session,
                                                }),
                                            }
                                        }
                                        Err(error) => {
                                            controller.abort_replacement();
                                            MachineControllerCompletion::Action {
                                                result: Err(error.to_string()),
                                                updates: None,
                                            }
                                        }
                                    },
                                    result => {
                                        let restart_updates = result
                                            .as_ref()
                                            .is_ok_and(|result| result.restart_updates);
                                        let result =
                                            result.map(Box::new).map_err(|error| error.to_string());
                                        let updates = restart_updates.then(|| {
                                            controller
                                                .subscribe_updates()
                                                .map_err(|error| error.to_string())
                                        });
                                        MachineControllerCompletion::Action { result, updates }
                                    }
                                }
                            }
                        }
                        MachineControllerCommand::SubscribeUpdates => {
                            MachineControllerCompletion::Updates(
                                controller.subscribe_updates().map_err(|error| error.to_string()),
                            )
                        }
                        MachineControllerCommand::AcknowledgeDurableNotice(delivery) => {
                            let result = controller
                                .acknowledge_durable_notice(&delivery)
                                .map_err(|error| error.to_string());
                            MachineControllerCompletion::DurableNoticeAcknowledged {
                                delivery,
                                result,
                            }
                        }
                        MachineControllerCommand::CommitReplacement { action_id, present } => {
                            match pending_replacement.take() {
                                Some((pending_id, restart_updates)) if pending_id == action_id => {
                                    let committed = controller
                                        .commit_replacement(present)
                                        .map(|()| true)
                                        .map_err(|error| error.to_string());
                                    if committed.is_err() {
                                        controller.abort_replacement();
                                    }
                                    let updates =
                                        (committed.is_ok() && restart_updates).then(|| {
                                            controller
                                                .subscribe_updates()
                                                .map_err(|error| error.to_string())
                                        });
                                    MachineControllerCompletion::ReplacementSettled {
                                        action_id,
                                        committed,
                                        updates,
                                    }
                                }
                                Some(_) => {
                                    controller.abort_replacement();
                                    MachineControllerCompletion::ReplacementSettled {
                                        action_id,
                                        committed: Err(localization::catalog()
                                            .sidebar
                                            .machine_replacement_stale
                                            .to_string()),
                                        updates: None,
                                    }
                                }
                                None => MachineControllerCompletion::ReplacementSettled {
                                    action_id,
                                    committed: Err(localization::catalog()
                                        .sidebar
                                        .machine_replacement_not_pending
                                        .to_string()),
                                    updates: None,
                                },
                            }
                        }
                        MachineControllerCommand::AbortReplacement(action_id) => {
                            let committed = match pending_replacement.take() {
                                Some((pending_id, _)) if pending_id == action_id => {
                                    controller.abort_replacement();
                                    Ok(false)
                                }
                                Some(_) => {
                                    controller.abort_replacement();
                                    Err(localization::catalog()
                                        .sidebar
                                        .machine_replacement_stale
                                        .to_string())
                                }
                                None => Err(localization::catalog()
                                    .sidebar
                                    .machine_replacement_not_pending
                                    .to_string()),
                            };
                            MachineControllerCompletion::ReplacementSettled {
                                action_id,
                                committed,
                                updates: None,
                            }
                        }
                    };
                    if !send_machine_controller_completion(
                        &app_events,
                        completion,
                        &worker_cancellation,
                    ) {
                        break;
                    }
                }
                if pending_replacement.is_some() {
                    controller.abort_replacement();
                }
                controller.close();
            })?;
        Ok(Self { sender: Some(sender), stop, cancellation, worker: Some(worker) })
    }

    pub(super) fn perform(
        &self,
        request: MachineRequest,
        preparation: MachineSessionPreparation,
    ) -> Result<(), MachineSubmitError> {
        let Some(sender) = self.sender.as_ref() else {
            return Err(MachineSubmitError::Stopped(request));
        };
        match sender.try_send(MachineControllerCommand::Perform {
            request,
            preparation: Box::new(preparation),
        }) {
            Ok(()) => Ok(()),
            Err(StdTrySendError::Full(command)) => Err(MachineSubmitError::Busy(match command {
                MachineControllerCommand::Perform { request, .. } => request,
                MachineControllerCommand::SubscribeUpdates => {
                    unreachable!("perform returned a subscription command")
                }
                MachineControllerCommand::AcknowledgeDurableNotice(_) => {
                    unreachable!("perform returned a durable notice acknowledgement")
                }
                MachineControllerCommand::CommitReplacement { .. }
                | MachineControllerCommand::AbortReplacement(_) => {
                    unreachable!("perform returned a replacement decision")
                }
            })),
            Err(StdTrySendError::Disconnected(command)) => {
                Err(MachineSubmitError::Stopped(match command {
                    MachineControllerCommand::Perform { request, .. } => request,
                    MachineControllerCommand::SubscribeUpdates => {
                        unreachable!("perform returned a subscription command")
                    }
                    MachineControllerCommand::AcknowledgeDurableNotice(_) => {
                        unreachable!("perform returned a durable notice acknowledgement")
                    }
                    MachineControllerCommand::CommitReplacement { .. }
                    | MachineControllerCommand::AbortReplacement(_) => {
                        unreachable!("perform returned a replacement decision")
                    }
                }))
            }
        }
    }

    pub(super) fn subscribe_updates(&self) -> bool {
        self.sender.as_ref().is_some_and(|sender| {
            sender.try_send(MachineControllerCommand::SubscribeUpdates).is_ok()
        })
    }

    pub(super) fn acknowledge_durable_notice(
        &self,
        delivery: DurableNoticeDelivery,
    ) -> Result<(), DurableNoticeDelivery> {
        let Some(sender) = self.sender.as_ref() else {
            return Err(delivery);
        };
        match sender.try_send(MachineControllerCommand::AcknowledgeDurableNotice(delivery)) {
            Ok(()) => Ok(()),
            Err(StdTrySendError::Full(MachineControllerCommand::AcknowledgeDurableNotice(
                delivery,
            )))
            | Err(StdTrySendError::Disconnected(
                MachineControllerCommand::AcknowledgeDurableNotice(delivery),
            )) => Err(delivery),
            Err(StdTrySendError::Full(_)) | Err(StdTrySendError::Disconnected(_)) => {
                unreachable!("durable notice sender returned a different command")
            }
        }
    }

    pub(super) fn commit_replacement(&self, action_id: u64, present: bool) -> bool {
        self.sender.as_ref().is_some_and(|sender| {
            sender
                .try_send(MachineControllerCommand::CommitReplacement { action_id, present })
                .is_ok()
        })
    }

    pub(super) fn abort_replacement(&self, action_id: u64) -> bool {
        self.sender.as_ref().is_some_and(|sender| {
            sender.try_send(MachineControllerCommand::AbortReplacement(action_id)).is_ok()
        })
    }

    pub(super) fn shutdown(&mut self) {
        self.stop.store(true, Ordering::Release);
        self.cancellation.cancel();
        self.sender.take();
        if self.worker.as_ref().is_some_and(JoinHandle::is_finished)
            && let Some(worker) = self.worker.take()
        {
            let _ = worker.join();
        }
        // A provider action has a bounded transport deadline but may still be
        // in progress. Dropping the handle detaches that bounded cleanup so
        // quitting the TUI never waits for the provider deadline.
        self.worker.take();
    }
}

impl Drop for MachineActionWorker {
    fn drop(&mut self) {
        self.shutdown();
    }
}

pub(super) fn prepare_machine_session(
    replacement: MachineSession,
    machine_ui: &MachineUiState,
    preparation: MachineSessionPreparation,
    app_events: SyncSender<AppEvent>,
) -> anyhow::Result<PreparedMachineSession> {
    // The managed-workspace guard runs on every presentation, reused or
    // not: a pooled session can change state while it is not presented, and
    // the guard is the invariant that makes presenting it safe.
    ensure_managed_workspace_guard(&replacement.session, Some(machine_ui))?;
    ensure_initial_for_machine_ui(
        &replacement.session,
        preparation.initial_size,
        Some(machine_ui),
    )?;
    let session_available = machine_ui.session_available;
    let (session, event_worker, mux_titles, mux_recovery_generation) = prepare_ordered_session(
        replacement.session,
        preparation.pty_input,
        app_events,
        preparation.generation,
        preparation.surface_filter,
    )?;
    let tree = session.tree();
    Ok(PreparedMachineSession {
        session,
        event_worker,
        generation: preparation.generation,
        mux_titles,
        mux_recovery_generation,
        tree,
        label: replacement.label,
        session_available,
        machine: replacement.machine,
    })
}

pub(super) fn send_machine_controller_completion(
    app_events: &SyncSender<AppEvent>,
    completion: MachineControllerCompletion,
    cancellation: &EventCancellation,
) -> bool {
    send_bounded_cancelable(
        app_events,
        AppEvent::MachineControllerCompleted(Box::new(completion)),
        cancellation,
    )
    .is_ok()
}

impl MachineUpdatePump {
    pub(super) fn spawn(
        updates: MachineUpdateStream,
        app_events: SyncSender<AppEvent>,
        generation: u64,
    ) -> anyhow::Result<Self> {
        let stop = updates.stop_handle();
        let (updates, _, provider) = updates.into_parts();
        let forwarder_stop = stop.clone();
        let cancellation = EventCancellation::new();
        let forwarder_cancellation = cancellation.clone();
        let forwarder = match std::thread::Builder::new()
            .name("machine-provider-events".into())
            .spawn(move || {
                while !forwarder_stop.load(Ordering::Acquire) {
                    match updates.recv_timeout(Duration::from_millis(250)) {
                        Ok(update) => {
                            if send_bounded_cancelable(
                                &app_events,
                                AppEvent::MachineUpdatedForGeneration {
                                    generation,
                                    update: Box::new(update),
                                },
                                &forwarder_cancellation,
                            )
                            .is_err()
                            {
                                return;
                            }
                        }
                        Err(RecvTimeoutError::Timeout) => {}
                        Err(RecvTimeoutError::Disconnected) => break,
                    }
                }
            }) {
            Ok(forwarder) => forwarder,
            Err(error) => {
                stop.store(true, Ordering::Release);
                let _ = provider.join();
                return Err(error.into());
            }
        };
        Ok(Self { stop, cancellation, provider: Some(provider), forwarder: Some(forwarder) })
    }

    pub(super) fn stop_and_join(&mut self) {
        self.stop.store(true, Ordering::Release);
        self.cancellation.cancel();
        if let Some(forwarder) = self.forwarder.take() {
            let _ = forwarder.join();
        }
        if let Some(provider) = self.provider.take() {
            let _ = provider.join();
        }
    }
}

impl Drop for MachineUpdatePump {
    fn drop(&mut self) {
        self.stop_and_join();
    }
}

pub(super) fn ensure_initial_for_machine_ui(
    session: &Session,
    initial_size: Option<(u16, u16)>,
    machine_ui: Option<&MachineUiState>,
) -> anyhow::Result<()> {
    let should_create = match machine_ui {
        None => true,
        Some(machine) if !machine.session_available => false,
        Some(machine) => !matches!(
            machine.workspace_creation_policy(),
            Some(WorkspaceCreationPolicy::ProviderOwned { .. })
        ),
    };
    if should_create {
        session.ensure_initial(initial_size)?;
    }
    Ok(())
}

pub(super) fn recover_initial_workspace_failure(
    result: anyhow::Result<()>,
    machine_ui: Option<&MachineUiState>,
) -> anyhow::Result<Option<String>> {
    match result {
        Ok(()) => Ok(None),
        Err(error) if machine_ui.is_some() => {
            let error = error.to_string();
            let message = if error.contains("failed to open PTY:")
                && (error.contains("Device not configured")
                    || error.contains("No space left on device")
                    || error.contains("Resource temporarily unavailable"))
            {
                localization::catalog().runtime.terminal_capacity_exhausted.to_string()
            } else {
                error
            };
            Ok(Some(message))
        }
        Err(error) => Err(error),
    }
}

pub(super) fn uses_provider_managed_workspaces(machine_ui: Option<&MachineUiState>) -> bool {
    matches!(
        machine_ui.and_then(MachineUiState::workspace_creation_policy),
        Some(WorkspaceCreationPolicy::ProviderOwned { .. })
    )
}

/// Route core diagnostics to the bounded client log. Core work can run on a
/// reconnect thread while this process owns a raw terminal, so the sink must
/// not echo to stderr.
pub(crate) fn install_mux_diagnostic_logger(mux: &Arc<Mux>) {
    let _ = mux.set_diagnostic_reporter(Arc::new(|message| {
        crate::client_log::warn("mux", message);
    }));
}

pub(super) fn ensure_managed_workspace_guard(
    session: &Session,
    machine_ui: Option<&MachineUiState>,
) -> anyhow::Result<()> {
    if let Some(machine_ui) = machine_ui {
        validate_machine_session(session, machine_ui)?;
    }
    Ok(())
}
