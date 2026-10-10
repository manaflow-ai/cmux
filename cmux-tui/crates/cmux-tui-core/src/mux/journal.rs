//! Session and shared journal plumbing: event publication, terminal output and resize journaling, readers, waits, producer manifests and journal ingress.

use super::*;

impl Mux {
    pub(crate) fn publish_resource_event(&self) {
        self.publish_journal_event();
    }

    pub(crate) fn publish_journal_event(&self) {
        self.journal_kernel.notify_commit();
        let mut epoch = self.journal_event_epoch.lock().unwrap();
        *epoch = epoch.wrapping_add(1);
        self.journal_event_changed.notify_all();
    }

    #[cfg_attr(not(test), allow(dead_code))]
    pub(crate) fn journal_terminal_output(
        &self,
        terminal_id: Arc<TerminalPublicId>,
        generation: Arc<str>,
        bytes: Vec<u8>,
    ) {
        if bytes.is_empty() {
            return;
        }
        self.journal_ingress.send(crate::journal_ingress::JournalIngressEvent::TerminalOutput {
            terminal_id,
            generation,
            occurred_at_ms: crate::workspace_registry::unix_epoch_ms().unwrap_or(0),
            bytes,
        });
    }

    pub(crate) fn try_journal_terminal_output(
        &self,
        terminal_id: Arc<TerminalPublicId>,
        generation: Arc<str>,
        occurred_at_ms: u64,
        bytes: Vec<u8>,
    ) -> Result<Option<(Vec<u8>, u64)>, String> {
        if bytes.is_empty() {
            return Ok(None);
        }
        match self.journal_ingress.try_send(
            crate::journal_ingress::JournalIngressEvent::TerminalOutput {
                terminal_id,
                generation,
                occurred_at_ms,
                bytes,
            },
        ) {
            Ok(()) => Ok(None),
            Err(crate::journal_ingress::JournalIngressTrySendError::Full {
                event,
                space_epoch,
            }) => Ok(match *event {
                crate::journal_ingress::JournalIngressEvent::TerminalOutput { bytes, .. } => {
                    Some((bytes, space_epoch))
                }
                _ => None,
            }),
            Err(crate::journal_ingress::JournalIngressTrySendError::Failed { event, error }) => {
                debug_assert!(matches!(
                    *event,
                    crate::journal_ingress::JournalIngressEvent::TerminalOutput { .. }
                ));
                Err(error)
            }
        }
    }

    pub(crate) fn wait_for_terminal_journal_space(&self, observed: u64) -> Result<(), String> {
        self.journal_ingress.wait_for_queue_space(observed)
    }

    pub(crate) fn flush_terminal_journal(&self) -> anyhow::Result<()> {
        self.journal_ingress.flush_terminal()
    }

    pub(crate) fn spawn_journal_writer(
        &self,
        name: &str,
        task: impl FnOnce() + Send + 'static,
    ) -> anyhow::Result<()> {
        self.journal_ingress.spawn_writer(name, task)
    }

    #[cfg(test)]
    pub(crate) fn install_journal_failure_notifier_for_test(&self, notifier: SyncSender<String>) {
        self.journal_ingress.install_failure_notifier_for_test(notifier);
    }

    #[cfg(test)]
    pub(crate) fn install_journal_nonretryable_failure_hook_for_test(
        &self,
        entered: SyncSender<()>,
        release: Receiver<()>,
    ) {
        self.journal_ingress.install_nonretryable_failure_hook_for_test(entered, release);
    }

    pub(crate) fn terminal_journal_enabled(&self) -> bool {
        self.journal_ingress.enabled()
    }

    pub fn journal_local_frontend_event(
        &self,
        event: crate::FrontendJournalEvent,
    ) -> anyhow::Result<()> {
        let principal_id = crate::server::public_client_id(&self.session_public_id, 0)?.to_string();
        self.journal_frontend_event(principal_id, event)
    }

    pub(crate) fn session_public_id(&self) -> SessionPublicId {
        self.session_public_id.clone()
    }

    pub(crate) fn journal_frontend_event(
        &self,
        principal_id: String,
        event: crate::FrontendJournalEvent,
    ) -> anyhow::Result<()> {
        self.journal_ingress.send_durable(crate::journal_ingress::JournalIngressEvent::Frontend {
            principal_id,
            occurred_at_ms: crate::workspace_registry::unix_epoch_ms()?,
            event,
        })
    }

    pub(crate) fn journal_terminal_resize(
        &self,
        terminal_id: Arc<TerminalPublicId>,
        generation: Arc<str>,
        cols: u16,
        rows: u16,
        cell_width: u16,
        cell_height: u16,
    ) {
        self.journal_ingress.send(crate::journal_ingress::JournalIngressEvent::TerminalResize {
            terminal_id,
            generation,
            occurred_at_ms: crate::workspace_registry::unix_epoch_ms().unwrap_or(0),
            cols,
            rows,
            cell_width,
            cell_height,
        });
    }

    pub(crate) fn commit_session_journal_events<F>(
        &self,
        events: &[&crate::journal_ingress::JournalIngressEvent],
        deadline: Instant,
        sqlite_wait_cap: Duration,
        admit_commit: F,
    ) -> anyhow::Result<Vec<crate::journal_ingress::JournalBatchReceipt>>
    where
        F: FnOnce() -> anyhow::Result<()>,
    {
        // Lock order: workspace registry -> registry connection -> state.
        // The writer takes only the connection lock, so a request thread
        // that holds the registry or state never waits behind this commit's
        // fsync unless it needs the connection itself. A request thread that
        // sent an effect intent holds the registry while it waits for this
        // batch, so the writer must never take the registry lock.
        let writer_commit =
            crate::workspace_registry::registry_connection::JournalWriterCommitScope::enter();
        let stats = self.journal_ingress.stats();
        stats.set_phase(crate::diagnostics::WriterPhase::WaitingLock);
        let lock_wait_from = Instant::now();
        let connection = self.registry_connection.get_until(deadline);
        let lock_wait = lock_wait_from.elapsed();
        let Some(connection) = connection else {
            stats.commit_finished(lock_wait, Duration::ZERO);
            stats.set_phase(crate::diagnostics::WriterPhase::Idle);
            return Err(anyhow::Error::from(crate::JournalContention::MUTEX_DEADLINE)
                .context("waiting for the workspace registry connection (journal writer)"));
        };
        stats.set_phase(crate::diagnostics::WriterPhase::Committing);
        let commit_from = Instant::now();
        let remaining = deadline.saturating_duration_since(Instant::now());
        let commits = if remaining.is_zero() {
            Err(crate::JournalContention::COMMIT_DEADLINE.into())
        } else {
            self.registry_connection.append_journal_ingress_events_with_deadline(
                &connection,
                events,
                deadline,
                remaining.min(sqlite_wait_cap),
                admit_commit,
            )
        };
        drop(connection);
        drop(writer_commit);
        stats.commit_finished(lock_wait, commit_from.elapsed());
        stats.set_phase(crate::diagnostics::WriterPhase::Idle);
        let commits = commits?;
        let (committed, failed) =
            commits.iter().fold((0, 0), |(ok, failed), commit| match commit {
                crate::journal_ingress::JournalBatchReceipt::Effect(Ok(_)) => (ok + 1, failed),
                crate::journal_ingress::JournalBatchReceipt::Effect(Err(_)) => (ok, failed + 1),
                _ => (ok, failed),
            });
        self.registry_connection.write_path_stats().writer_batch_committed(committed, failed);
        self.publish_journal_event();
        Ok(commits)
    }

    /// Registry mutex contention, see [`crate::diagnostics::LockStats`].
    pub fn registry_lock_stats(&self) -> crate::diagnostics::LockStatsSnapshot {
        self.workspace_registry.stats().snapshot()
    }

    /// Journal writer metrics, `None` for ephemeral sessions without a
    /// durable journal.
    pub fn journal_writer_stats(&self) -> Option<crate::diagnostics::JournalWriterSnapshot> {
        self.journal_ingress.enabled().then(|| self.journal_ingress.stats().snapshot())
    }

    /// Resource projection and commit spans, see
    /// [`crate::diagnostics::ResourceProjectionStats`].
    pub fn resource_projection_stats(&self) -> crate::diagnostics::ResourceProjectionSnapshot {
        self.resource_projection_stats.snapshot()
    }

    pub fn write_path_stats(&self) -> crate::diagnostics::WritePathSnapshot {
        self.registry_connection.write_path_stats().snapshot()
    }

    pub(crate) fn connection_stats(&self) -> &Arc<crate::diagnostics::ConnectionStats> {
        &self.connection_stats
    }

    pub fn uptime(&self) -> Duration {
        self.started_at.elapsed()
    }

    #[cfg(test)]
    pub(crate) fn hold_workspace_registry_for_test(
        &self,
        entered: SyncSender<()>,
        release: Receiver<()>,
    ) {
        let _registry = self.workspace_registry.lock().unwrap();
        entered.send(()).unwrap();
        release.recv().unwrap();
    }

    /// Holds the registry connection lock (the journal writer's only lock)
    /// until `release` fires.
    #[cfg(test)]
    pub(crate) fn hold_registry_connection_for_test(
        &self,
        entered: SyncSender<()>,
        release: Receiver<()>,
    ) {
        let _connection = self.registry_connection.get();
        entered.send(()).unwrap();
        release.recv().unwrap();
    }

    #[cfg(test)]
    pub(crate) fn install_journal_before_commit_for_test(
        &self,
        entered: SyncSender<()>,
        release: Receiver<()>,
    ) {
        self.registry_connection.set_journal_before_commit_for_test(entered, release);
    }

    #[cfg(test)]
    pub(crate) fn install_journal_after_commit_admission_for_test(
        &self,
        entered: SyncSender<()>,
        release: Receiver<()>,
    ) {
        self.registry_connection.set_journal_after_commit_admission_for_test(entered, release);
    }

    pub(crate) fn journal_event_epoch(&self) -> u64 {
        *self.journal_event_epoch.lock().unwrap()
    }

    #[cfg(test)]
    pub(crate) fn wait_for_journal_event(&self, epoch: u64, timeout: Duration) -> u64 {
        let current = self.journal_event_epoch.lock().unwrap();
        if *current != epoch {
            return *current;
        }
        let (current, _) = self.journal_event_changed.wait_timeout(current, timeout).unwrap();
        *current
    }

    /// Like `wait_for_journal_event`, with no timeout: returns the new
    /// epoch, or `epoch` once `interrupt` has fired.
    pub(crate) fn wait_for_journal_event_until_interrupted(
        &self,
        epoch: u64,
        interrupt: &crate::stream_interrupt::StreamInterrupt,
    ) -> u64 {
        let mut current = self.journal_event_epoch.lock().unwrap();
        while *current == epoch && !interrupt.is_fired() {
            current = self.journal_event_changed.wait(current).unwrap();
        }
        *current
    }

    /// Like `wait_for_shared_journal`, with no timeout.
    pub(crate) fn wait_for_shared_journal_until_interrupted(
        &self,
        epoch: u64,
        interrupt: &crate::stream_interrupt::StreamInterrupt,
    ) -> u64 {
        self.journal_kernel.wait_until_interrupted(epoch, interrupt)
    }

    /// Wakes this mux's journal waiters when `interrupt` fires, so a
    /// session stream blocks until an event or its own close.
    pub(crate) fn wake_journal_waiters_on(
        self: &Arc<Self>,
        interrupt: &crate::stream_interrupt::StreamInterrupt,
    ) {
        let mux = Arc::downgrade(self);
        interrupt.on_fire(move || {
            if let Some(mux) = mux.upgrade() {
                {
                    let _epoch =
                        mux.journal_event_epoch.lock().unwrap_or_else(|error| error.into_inner());
                    mux.journal_event_changed.notify_all();
                }
                mux.journal_kernel.notify_waiters();
            }
        });
    }

    pub(crate) fn resource_event_epoch(&self) -> u64 {
        self.journal_event_epoch()
    }

    #[cfg(test)]
    pub(crate) fn wait_for_resource_event(&self, epoch: u64, timeout: Duration) -> u64 {
        self.wait_for_journal_event(epoch, timeout)
    }

    pub(crate) fn resource_events_after(
        &self,
        revision: u64,
    ) -> anyhow::Result<crate::workspace_registry::ResourceEventPage> {
        self.workspace_registry.lock().unwrap().resource_events_after(revision)
    }

    /// The journal head without decoding any record or sealed segment.
    pub(crate) fn session_journal_head(&self) -> anyhow::Result<u64> {
        self.workspace_registry.lock().unwrap().session_journal_head()
    }

    pub(crate) fn session_journal_after(
        &self,
        sequence: u64,
        limit: usize,
    ) -> anyhow::Result<crate::workspace_registry::SessionJournalPage> {
        self.workspace_registry.lock().unwrap().session_journal_after(sequence, limit)
    }

    pub(crate) fn session_journal_reader(
        &self,
    ) -> anyhow::Result<Option<crate::workspace_registry::SessionJournalReader>> {
        let database_path = self.workspace_registry.lock().unwrap().session_journal_database_path();
        database_path
            .as_deref()
            .map(crate::workspace_registry::SessionJournalReader::open)
            .transpose()
    }

    pub(crate) fn shared_journal_enabled(&self) -> bool {
        self.journal_kernel.enabled()
    }

    pub(crate) fn shared_journal_epoch(&self) -> u64 {
        self.journal_kernel.epoch()
    }

    pub(crate) fn shared_journal_handle(&self) -> Arc<crate::journal_kernel::JournalKernel> {
        self.journal_kernel.clone()
    }

    #[cfg(test)]
    pub(crate) fn wait_for_shared_journal(&self, epoch: u64, timeout: Duration) -> u64 {
        self.journal_kernel.wait(epoch, timeout)
    }

    pub(crate) fn shared_journal_after(
        &self,
        sequence: u64,
        limit: usize,
    ) -> crate::journal_kernel::SharedJournalRead {
        self.journal_kernel.read_after(sequence, limit)
    }

    pub(crate) fn journal_producer_manifests(
        &self,
    ) -> anyhow::Result<Vec<crate::JournalProducerManifest>> {
        self.workspace_registry.lock().unwrap().journal_producer_manifests()
    }

    pub(crate) fn userland_journal_producer_manifests(
        &self,
    ) -> anyhow::Result<Vec<crate::JournalProducerManifest>> {
        self.workspace_registry.lock().unwrap().userland_journal_producer_manifests()
    }

    pub(crate) fn put_journal_producer(
        &self,
        manifest: &crate::JournalProducerManifest,
        origin: &str,
        idempotency_key: &str,
    ) -> anyhow::Result<crate::JournalAppendCommit> {
        let prepared = crate::journal_kernel::JournalKernel::prepare_producer(manifest)?;
        let commit = self.workspace_registry.lock().unwrap().put_journal_producer(
            manifest,
            origin,
            idempotency_key,
        )?;
        if !commit.replayed {
            // Installation is version-monotonic, so concurrent successful
            // updates cannot publish their compiled validators out of order.
            self.journal_kernel.install_prepared_producer(prepared);
            self.publish_journal_event();
        }
        Ok(commit)
    }

    pub(crate) fn append_journal_ingress(
        &self,
        ingress: &crate::JournalIngress,
        origin: &str,
        idempotency_key: &str,
    ) -> anyhow::Result<crate::JournalAppendCommit> {
        let validated = match self.journal_kernel.validate_ingress(ingress) {
            Ok(validated) => validated,
            Err(validation_error) => {
                // A receipt is authoritative for an exact retry. Its ingress
                // may name a superseded manifest after a producer upgrade,
                // while a new ingress must still pass current validation.
                let replay = {
                    let registry = self.workspace_registry.lock().unwrap();
                    registry.replay_journal_ingress(ingress, origin, idempotency_key)?
                };
                if let Some(commit) = replay {
                    return self.finish_journal_ingress(ingress, origin, idempotency_key, commit);
                }
                return Err(validation_error);
            }
        };
        let commit = if self.journal_ingress.enabled() {
            self.journal_ingress.send_producer(
                ingress.clone(),
                validated,
                origin.into(),
                idempotency_key.into(),
            )?
        } else {
            let commit = self.workspace_registry.lock().unwrap().append_journal_ingress(
                ingress,
                &validated,
                origin,
                idempotency_key,
            )?;
            if !commit.replayed {
                self.publish_journal_event();
            }
            commit
        };
        if !commit.replayed && ingress.producer_id == crate::AGENT_HOOK_PRODUCER_ID {
            self.activity.note_agent_action();
        }
        self.finish_journal_ingress(ingress, origin, idempotency_key, commit)
    }

    pub(super) fn finish_journal_ingress(
        &self,
        ingress: &crate::JournalIngress,
        origin: &str,
        idempotency_key: &str,
        commit: crate::JournalAppendCommit,
    ) -> anyhow::Result<crate::JournalAppendCommit> {
        // Replayed journal commits still need projection reconciliation. A
        // process can crash after the durable journal commit and before the
        // in-memory/resource projection update. The sequence guard makes this
        // a no-op for already-applied events while allowing restart repair.
        if let Err(error) = self.apply_agent_hook_record(ingress, commit.sequence) {
            if agent_hook_terminal_gone(&error) {
                if let Err(_bookkeeping_error) = self
                    .workspace_registry
                    .lock()
                    .unwrap()
                    .clear_agent_hook_pending(&ingress.producer_id, origin, idempotency_key)
                {
                    self.report_internal_diagnostic("terminal-gone agent hook cleanup deferred");
                }
            } else {
                if let Err(_bookkeeping_error) =
                    self.workspace_registry.lock().unwrap().enqueue_agent_hook_pending(
                        &ingress.producer_id,
                        origin,
                        idempotency_key,
                        commit.sequence,
                        ingress,
                        AgentHookPendingFailure {
                            error: AGENT_HOOK_RETRY_ERROR,
                            retry_class: agent_hook_retry_class(&error),
                        },
                    )
                {
                    self.report_internal_diagnostic(
                        "durable agent hook receipt remains staged after retry bookkeeping failure",
                    );
                }
            }
        } else if let Err(_bookkeeping_error) = self
            .workspace_registry
            .lock()
            .unwrap()
            .clear_agent_hook_pending(&ingress.producer_id, origin, idempotency_key)
        {
            self.report_internal_diagnostic(
                "agent hook projection applied; retry bookkeeping cleanup deferred",
            );
        }
        // A replayed plugin event can repair a projection after a process
        // crash between the durable journal commit and the in-memory fold.
        // Hook replay remains owned by its durable retry projector, while the
        // generic plugin envelope is safe to fold repeatedly because the
        // reducer fences by journal sequence and observed timestamp.
        let is_plugin_event = ingress.payload.get("format").and_then(Value::as_str)
            == Some(crate::journal_reducers::AGENT_PLUGIN_FORMAT);
        // A replay can follow a crash before either projection or reducer
        // side effects. The reducer cursor makes folding an already-applied
        // sequence a no-op, so replay every agent event and repair a missing
        // roster fold without duplicating live deltas.
        if !commit.replayed
            || is_plugin_event
            || ingress.producer_id == crate::agent_hooks::AGENT_HOOK_PRODUCER_ID
        {
            self.fold_agent_roster(ingress, &commit);
        }
        Ok(commit)
    }
}
