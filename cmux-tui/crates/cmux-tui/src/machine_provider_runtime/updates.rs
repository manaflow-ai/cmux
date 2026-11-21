//! Provider event subscription: the event and refresh worker threads that turn provider events
//! into `MachineUpdate`s for `ProviderMachineRuntime::subscribe_ui_updates`.

use super::*;

#[derive(Debug)]
enum ProviderRefreshSignal {
    Refresh(Option<protocol::ProviderEvent>),
    Disconnected,
}

impl ProviderMachineRuntime {
    pub(crate) fn subscribe_ui_updates(&self) -> anyhow::Result<MachineUpdateStream> {
        let events = self.client.subscribe_events()?;
        let client = self.client.clone();
        let keys = self.keys.clone();
        let connections = self.connections.clone();
        let connection_registry = self.connection_registry.clone();
        let provider_connect_supported = client
            .supports_capability(protocol::EXTERNAL_MACHINE_CONNECT_CAPABILITY)
            .unwrap_or(false);
        let durable_notices_supported =
            client.supports_capability(protocol::DURABLE_NOTICES_CAPABILITY).unwrap_or(false);
        let mut connected_session =
            self.open.as_ref().map(|open| (open.connection_id.clone(), open.machine_id.clone()));
        let stop = Arc::new(AtomicBool::new(false));
        let thread_stop = stop.clone();
        let (sender, receiver) = mpsc::sync_channel(PROVIDER_REFRESH_QUEUE_CAPACITY);
        let mut last_snapshot = self.snapshot.clone();
        let mut last_machine_lifecycle_snapshot = self.machine_lifecycle_snapshot.clone();
        let mut last_workspace_snapshot = self.workspace_snapshot.clone();
        let mut last_snapshot_notice = self.last_snapshot_notice.clone();
        let (mut desired_scope_id, mut desired_machine_id) = self.desired_selection();
        let (refresh_sender, refresh_receiver) =
            mpsc::sync_channel(PROVIDER_REFRESH_QUEUE_CAPACITY);
        let refresh_overflowed = Arc::new(AtomicBool::new(false));
        let worker_refresh_overflowed = refresh_overflowed.clone();
        let snapshot_refresh_pending = Arc::new(AtomicBool::new(false));
        let worker_snapshot_refresh_pending = snapshot_refresh_pending.clone();
        let refresh_stop = stop.clone();
        let refresh_output = sender.clone();
        let refresh_worker = std::thread::Builder::new()
            .name("machine-provider-refresh".into())
            .spawn(move || {
                // Latest-value cells for connection progress, one per machine
                // (see MachineUpdate::ConnectionProgress).
                let mut progress_cells: HashMap<String, Arc<Mutex<Option<String>>>> =
                    HashMap::new();
                let mut progress_last_sent: HashMap<String, std::time::Instant> = HashMap::new();
                while !refresh_stop.load(Ordering::Acquire) {
                    if worker_refresh_overflowed.load(Ordering::Acquire) {
                        let mut ui = machine_ui_state(
                            &last_snapshot,
                            &last_machine_lifecycle_snapshot,
                            last_workspace_snapshot.as_ref(),
                            &keys,
                            false,
                            false,
                        );
                        ui.notice = Some(
                            localization::catalog().sidebar.machine_provider_disconnected.into(),
                        );
                        ui.request = Some(MachineRequest::ReconnectProvider);
                        let _ = refresh_output.send(MachineUpdate::Ui(Box::new(ui)));
                        break;
                    }
                    let event = match refresh_receiver.recv_timeout(Duration::from_millis(250)) {
                        Ok(ProviderRefreshSignal::Refresh(event)) => {
                            if matches!(&event, Some(protocol::ProviderEvent::SnapshotChanged(_))) {
                                // Permit one follow-up invalidation while this authoritative
                                // refresh is in flight. Its snapshot will include every earlier
                                // state-free invalidation.
                                worker_snapshot_refresh_pending.store(false, Ordering::Release);
                            }
                            event
                        }
                        Ok(ProviderRefreshSignal::Disconnected) => {
                            let mut ui = machine_ui_state(
                                &last_snapshot,
                                &last_machine_lifecycle_snapshot,
                                last_workspace_snapshot.as_ref(),
                                &keys,
                                false,
                                false,
                            );
                            ui.notice = Some(
                                localization::catalog()
                                    .sidebar
                                    .machine_provider_disconnected
                                    .into(),
                            );
                            ui.request = Some(MachineRequest::ReconnectProvider);
                            let _ = refresh_output.send(MachineUpdate::Ui(Box::new(ui)));
                            break;
                        }
                        Err(mpsc::RecvTimeoutError::Timeout) => continue,
                        Err(mpsc::RecvTimeoutError::Disconnected) => {
                            if worker_refresh_overflowed.load(Ordering::Acquire) {
                                let mut ui = machine_ui_state(
                                    &last_snapshot,
                                    &last_machine_lifecycle_snapshot,
                                    last_workspace_snapshot.as_ref(),
                                    &keys,
                                    false,
                                    false,
                                );
                                ui.notice = Some(
                                    localization::catalog()
                                        .sidebar
                                        .machine_provider_disconnected
                                        .into(),
                                );
                                ui.request = Some(MachineRequest::ReconnectProvider);
                                let _ = refresh_output.send(MachineUpdate::Ui(Box::new(ui)));
                            }
                            break;
                        }
                    };
                    if let Some(protocol::ProviderEvent::ConnectionProgress(progress)) =
                        event.as_ref()
                    {
                        // Forward without a snapshot reload: the provider's
                        // serialized control loop is busy inside open_machine
                        // while it pushes these, so a snapshot request would
                        // stall exactly the message it is meant to show.
                        let machine_id = progress.machine_id.as_str().to_string();
                        // Provider-controlled text: strip terminal control
                        // characters (ESC/OSC injection) and cap it at the
                        // trust boundary (char-safe) before it is stored or
                        // drawn.
                        let mut message: String = progress
                            .message
                            .chars()
                            .map(|c| if c.is_control() { ' ' } else { c })
                            .collect();
                        if message.len() > 512 {
                            let mut end = 512;
                            while !message.is_char_boundary(end) {
                                end -= 1;
                            }
                            message.truncate(end);
                        }
                        // Hard bound against a provider spraying distinct
                        // ids while no snapshot prunes the map. Rejecting the
                        // event (progress is advisory) keeps the one-in-
                        // flight-per-machine invariant; clearing instead
                        // would mint fresh cells whose updates stack on top
                        // of unconsumed ones.
                        if progress_cells.len() >= 128 && !progress_cells.contains_key(&machine_id)
                        {
                            continue;
                        }
                        // Rate floor per machine, checked before any state is
                        // written: a provider emitting stages faster than
                        // 20/s buys no fidelity and would drive main-loop
                        // redraws at its own cadence. Dropped events leave
                        // the cell untouched, so the in-flight invariant
                        // holds (progress is advisory; the settle clears it).
                        let now = std::time::Instant::now();
                        if let Some(last) = progress_last_sent.get(&machine_id)
                            && now.duration_since(*last) < Duration::from_millis(50)
                        {
                            continue;
                        }
                        let cell = progress_cells.entry(machine_id.clone()).or_default();
                        let already_in_flight = {
                            let mut slot =
                                cell.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
                            let pending = slot.is_some();
                            *slot = Some(message);
                            pending
                        };
                        if already_in_flight {
                            // An unconsumed update for this machine is queued;
                            // it will deliver this newer message when read.
                            continue;
                        }
                        progress_last_sent.insert(machine_id.clone(), now);
                        if refresh_output
                            .send(MachineUpdate::ConnectionProgress {
                                machine_id,
                                latest: Arc::clone(cell),
                            })
                            .is_err()
                        {
                            // The app side is gone (shutdown): stop pumping
                            // like every other update path does.
                            break;
                        }
                        continue;
                    }
                    let mut notice = None;
                    let had_connected_session = connected_session.is_some();
                    if let Some(protocol::ProviderEvent::ConnectionClosed(closed)) = event.as_ref()
                    {
                        let closed_key = connection_registry.lock().ok().and_then(|registry| {
                            registry.iter().find_map(|(key, open)| {
                                (open.connection_id == closed.connection_id
                                    && open.machine_id == closed.machine_id)
                                    .then_some(*key)
                            })
                        });
                        if let Some(key) = closed_key {
                            connections.remove(key);
                        }
                        if connected_session.as_ref().is_some_and(|(connection_id, machine_id)| {
                            connection_id == &closed.connection_id
                                && machine_id == &closed.machine_id
                        }) {
                            connected_session = None;
                            notice = Some(closed.reason.clone());
                        }
                    }
                    if let Some(protocol::ProviderEvent::Notice(provider_notice)) = event.as_ref() {
                        notice = Some(provider_notice.message.clone());
                    }
                    let snapshot = match load_snapshot_for_selection(
                        &client,
                        Some(last_snapshot.revision),
                        &last_snapshot.selected_scope_id,
                        &mut desired_scope_id,
                        &mut desired_machine_id,
                    ) {
                        Ok(snapshot) => snapshot,
                        Err(error) => {
                            let mut ui = machine_ui_state(
                                &last_snapshot,
                                &last_machine_lifecycle_snapshot,
                                last_workspace_snapshot.as_ref(),
                                &keys,
                                false,
                                false,
                            );
                            ui.notice = Some(if client.is_live() {
                                format!(
                                    "{}: {error}",
                                    localization::catalog().sidebar.machine_provider_update_failed
                                )
                            } else {
                                localization::catalog().sidebar.machine_provider_disconnected.into()
                            });
                            ui.request = Some(MachineRequest::ReconnectProvider);
                            let _ = refresh_output.send(MachineUpdate::Ui(Box::new(ui)));
                            break;
                        }
                    };
                    // Each snapshot is the authoritative machine set: drop
                    // progress cells for machines that no longer exist, so a
                    // long-lived provider emitting many distinct ids cannot
                    // grow the registry without bound.
                    progress_cells.retain(|machine_id, _| {
                        snapshot
                            .machines
                            .iter()
                            .any(|machine| machine.id.as_str() == machine_id.as_str())
                    });
                    progress_last_sent.retain(|machine_id, _| {
                        snapshot
                            .machines
                            .iter()
                            .any(|machine| machine.id.as_str() == machine_id.as_str())
                    });
                    let changed_snapshot_notice =
                        if !durable_notices_supported && snapshot.notice != last_snapshot_notice {
                            snapshot.notice.clone()
                        } else {
                            None
                        };
                    last_snapshot_notice = snapshot.notice.clone();
                    last_snapshot = snapshot.clone();
                    last_machine_lifecycle_snapshot =
                        match load_machine_lifecycle_snapshot(&client, &snapshot) {
                            Ok(snapshot) => snapshot,
                            Err(error) => {
                                let mut ui = machine_ui_state(
                                    &last_snapshot,
                                    &last_machine_lifecycle_snapshot,
                                    last_workspace_snapshot.as_ref(),
                                    &keys,
                                    false,
                                    false,
                                );
                                ui.notice = Some(format!(
                                    "{}: {error}",
                                    localization::catalog()
                                        .sidebar
                                        .machine_provider_lifecycle_update_failed
                                ));
                                ui.request = Some(MachineRequest::ReconnectProvider);
                                let _ = refresh_output.send(MachineUpdate::Ui(Box::new(ui)));
                                break;
                            }
                        };
                    last_workspace_snapshot = match load_workspace_snapshot(&client, &snapshot) {
                        Ok(snapshot) => snapshot,
                        Err(error) => {
                            let mut ui = machine_ui_state(
                                &last_snapshot,
                                &last_machine_lifecycle_snapshot,
                                last_workspace_snapshot.as_ref(),
                                &keys,
                                false,
                                false,
                            );
                            ui.notice = Some(format!(
                                "{}: {error}",
                                localization::catalog()
                                    .sidebar
                                    .machine_provider_workspace_update_failed
                            ));
                            ui.request = Some(MachineRequest::ReconnectProvider);
                            let _ = refresh_output.send(MachineUpdate::Ui(Box::new(ui)));
                            break;
                        }
                    };
                    reconcile_keys(&keys, &snapshot, &last_machine_lifecycle_snapshot);
                    sync_provider_connection_hub(
                        &snapshot,
                        Arc::clone(&client),
                        &keys,
                        &connections,
                        &connection_registry,
                    );
                    let session_available = snapshot.selected_machine_id.is_some()
                        && connected_session.as_ref().is_some_and(|(_, machine_id)| {
                            snapshot.selected_machine_id.as_ref() == Some(machine_id)
                                && key_for_id(&keys, machine_id)
                                    .is_some_and(|key| connections.is_ready(key))
                        });
                    let mut ui = machine_ui_state(
                        &snapshot,
                        &last_machine_lifecycle_snapshot,
                        last_workspace_snapshot.as_ref(),
                        &keys,
                        session_available,
                        provider_connect_supported,
                    );
                    ui.set_connection_phases(connections.phases());
                    ui.notice = notice;
                    if let Some(snapshot_notice) = changed_snapshot_notice {
                        append_notice_once(&mut ui.notice, snapshot_notice.message);
                    }
                    if !session_available
                        && let Some(selected) = snapshot.selected_machine_id.as_ref()
                        && snapshot
                            .machines
                            .iter()
                            .any(|machine| &machine.id == selected && machine.connectable)
                        && let Some(key) = key_for_id(&keys, selected)
                    {
                        ui.request = Some(MachineRequest::Switch(key));
                    } else if !session_available && had_connected_session {
                        ui.request = Some(MachineRequest::ReconnectProvider);
                    }
                    if refresh_output.send(MachineUpdate::Ui(Box::new(ui))).is_err() {
                        break;
                    }
                }
            })?;
        refresh_sender.send(ProviderRefreshSignal::Refresh(None))?;
        let worker = std::thread::Builder::new().name("machine-provider-events".into()).spawn(
            move || {
                while !thread_stop.load(Ordering::Acquire) {
                    match events.recv_timeout(Duration::from_millis(250)) {
                        Ok(received) => {
                            let crate::machine_provider_client::ReceivedProviderEvent {
                                event,
                                delivery,
                            } = received;
                            if let (
                                protocol::ProviderEvent::Notice(provider_notice),
                                Some(delivery),
                            ) = (&event, delivery)
                            {
                                let level = match provider_notice.level {
                                    protocol::NoticeLevel::Info => DurableNoticeLevel::Info,
                                    protocol::NoticeLevel::Warning => DurableNoticeLevel::Warning,
                                    protocol::NoticeLevel::Error => DurableNoticeLevel::Error,
                                };
                                let update = MachineUpdate::DurableNotice(DurableProviderNotice {
                                    delivery: DurableNoticeDelivery {
                                        notice_id: delivery.notice_id.into_inner(),
                                        sequence: delivery.sequence,
                                    },
                                    level,
                                    message: provider_notice.message.clone(),
                                });
                                if sender.send(update).is_err() {
                                    break;
                                }
                                continue;
                            }
                            if matches!(&event, protocol::ProviderEvent::SnapshotChanged(_)) {
                                if snapshot_refresh_pending.swap(true, Ordering::AcqRel) {
                                    continue;
                                }
                                match refresh_sender
                                    .try_send(ProviderRefreshSignal::Refresh(Some(event)))
                                {
                                    Ok(()) => {}
                                    Err(mpsc::TrySendError::Full(_)) => {
                                        // Every queued refresh loads the latest snapshot, so a
                                        // state-free invalidation can be retried or subsumed
                                        // without treating the provider stream as lossy.
                                        snapshot_refresh_pending.store(false, Ordering::Release);
                                    }
                                    Err(mpsc::TrySendError::Disconnected(_)) => {
                                        snapshot_refresh_pending.store(false, Ordering::Release);
                                        break;
                                    }
                                }
                                continue;
                            }
                            match refresh_sender
                                .try_send(ProviderRefreshSignal::Refresh(Some(event)))
                            {
                                Ok(()) => {}
                                Err(mpsc::TrySendError::Full(_)) => {
                                    refresh_overflowed.store(true, Ordering::Release);
                                    break;
                                }
                                Err(mpsc::TrySendError::Disconnected(_)) => break,
                            }
                        }
                        Err(mpsc::RecvTimeoutError::Timeout) => continue,
                        Err(mpsc::RecvTimeoutError::Disconnected) => {
                            if let Err(mpsc::TrySendError::Full(_)) =
                                refresh_sender.try_send(ProviderRefreshSignal::Disconnected)
                            {
                                refresh_overflowed.store(true, Ordering::Release);
                            }
                            break;
                        }
                    }
                }
                drop(refresh_sender);
                let _ = refresh_worker.join();
            },
        )?;
        Ok(MachineUpdateStream::new(receiver, stop, worker))
    }
}
