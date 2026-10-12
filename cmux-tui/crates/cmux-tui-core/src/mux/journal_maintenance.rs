//! Journal maintenance: hook delivery dispatch, internal diagnostics, reconnect checkpoints, journal checkpoints and segments, and their test hooks.

use super::*;

impl Mux {
    pub(crate) fn journal_hook_states(
        &self,
    ) -> anyhow::Result<Vec<crate::workspace_registry::JournalHookState>> {
        self.workspace_registry.lock().unwrap().journal_hook_states()
    }

    pub(crate) fn journal_events_caused_by_hooks(
        &self,
        hook_ids: &[String],
        event_ids: &[String],
    ) -> anyhow::Result<HashSet<(String, String)>> {
        self.workspace_registry.lock().unwrap().journal_events_caused_by_hooks(hook_ids, event_ids)
    }

    pub(crate) fn put_journal_hook(
        self: &Arc<Self>,
        manifest: &crate::JournalHookManifest,
        origin: &str,
        idempotency_key: &str,
    ) -> anyhow::Result<crate::JournalAppendCommit> {
        let commit = self.workspace_registry.lock().unwrap().put_journal_hook(
            manifest,
            origin,
            idempotency_key,
        )?;
        if !commit.replayed {
            self.publish_journal_event();
        }
        crate::journal_hooks::start(self)?;
        Ok(commit)
    }

    pub(crate) fn try_claim_journal_hook_dispatcher(&self) -> bool {
        self.journal_hook_dispatcher_started
            .compare_exchange(false, true, Ordering::AcqRel, Ordering::Acquire)
            .is_ok()
    }

    pub(crate) fn journal_hook_runtime(&self) -> Arc<crate::journal_hooks::JournalHookRuntime> {
        self.journal_hook_runtime.clone()
    }

    pub(crate) fn release_journal_hook_dispatcher(&self) {
        self.journal_hook_dispatcher_started.store(false, Ordering::Release);
    }

    pub(crate) fn schedule_journal_hook_deliveries(
        &self,
        scans: &[crate::workspace_registry::JournalHookScan],
    ) -> anyhow::Result<Vec<bool>> {
        self.workspace_registry.lock().unwrap().schedule_journal_hook_deliveries(scans)
    }

    /// When the next scheduled hook retry is due, if any.
    pub(crate) fn next_journal_hook_attempt_deadline(&self) -> anyhow::Result<Option<Instant>> {
        let now_ms = crate::workspace_registry::unix_epoch_ms()?;
        let next = self.workspace_registry.lock().unwrap().next_journal_hook_attempt_at_ms()?;
        Ok(next.map(|at| Instant::now() + Duration::from_millis(at.saturating_sub(now_ms))))
    }

    pub(crate) fn pending_journal_hook_deliveries(
        &self,
        limit: usize,
    ) -> anyhow::Result<Vec<crate::workspace_registry::JournalHookDelivery>> {
        let now_ms = crate::workspace_registry::unix_epoch_ms()?;
        self.workspace_registry.lock().unwrap().pending_journal_hook_deliveries(now_ms, limit)
    }

    pub(crate) fn start_journal_hook_deliveries(
        &self,
        deliveries: &[crate::workspace_registry::JournalHookDelivery],
    ) -> anyhow::Result<Vec<crate::workspace_registry::JournalHookAttempt>> {
        let attempts =
            self.workspace_registry.lock().unwrap().start_journal_hook_deliveries(deliveries)?;
        if !attempts.is_empty() {
            self.publish_journal_event();
        }
        Ok(attempts)
    }

    pub(crate) fn finish_journal_hook_deliveries(
        &self,
        results: &[crate::workspace_registry::JournalHookDeliveryResult],
    ) -> anyhow::Result<()> {
        self.workspace_registry.lock().unwrap().finish_journal_hook_deliveries(results)?;
        if !results.is_empty() {
            self.publish_journal_event();
        }
        Ok(())
    }

    /// Sends a diagnostic to the frontend-owned sink without writing to a
    /// frontend terminal. The first messages are retained when startup races
    /// sink installation, so a later startup message cannot replace an
    /// earlier one (the agent roster restore reports before hook retries).
    pub(crate) fn report_internal_diagnostic(&self, message: impl Into<String>) {
        let message = message.into();
        if let Some(reporter) = self.diagnostic_reporter.get().cloned() {
            reporter(&message);
            return;
        }

        // Mux construction can start hosted-surface readers before the
        // frontend has a chance to install its reporter. Recheck under the
        // pending slot lock so a concurrent setter cannot leave this message
        // stranded between the initial lookup and the store.
        let mut pending = self.pending_diagnostics.lock().unwrap();
        if let Some(reporter) = self.diagnostic_reporter.get().cloned() {
            drop(pending);
            reporter(&message);
        } else if pending.len() < MAX_PENDING_DIAGNOSTICS {
            pending.push(message);
        }
    }

    /// Logs a skipped terminal-host reconnect checkpoint at most once
    /// until a later reconnect checkpoint succeeds. A checkpoint is a
    /// journal-replay optimization: skipping one only moves the next replay
    /// boundary back, so repeated skips are daemon-log noise, not per-toast
    /// news.
    pub(crate) fn report_skipped_reconnect_checkpoint(
        &self,
        terminal_id: impl fmt::Display,
        error: &anyhow::Error,
    ) {
        let message = format!(
            "skipped terminal {terminal_id} reconnect checkpoint (replay starts from the previous boundary): {error:#}"
        );
        if self.reconnect_checkpoint_skip_reported.swap(true, Ordering::AcqRel) {
            return;
        }
        self.report_internal_diagnostic(message);
    }

    /// Installs the frontend-owned sink for diagnostics emitted by the mux.
    ///
    /// A mux has one owner for its lifetime, so accepting the first reporter
    /// avoids replacing a sink while a reconnect worker is reporting. A
    /// caller that tries to install a second sink receives `false` and must
    /// keep the original owner unchanged.
    pub fn set_diagnostic_reporter(&self, reporter: DiagnosticReporter) -> bool {
        let pending_reporter = reporter.clone();
        if self.diagnostic_reporter.set(reporter).is_err() {
            return false;
        }
        let pending = std::mem::take(&mut *self.pending_diagnostics.lock().unwrap());
        for message in pending {
            pending_reporter(&message);
        }
        true
    }

    pub(crate) fn note_reconnect_checkpoint_captured(&self) {
        self.reconnect_checkpoint_skip_reported.store(false, Ordering::Release);
    }

    pub(crate) fn create_journal_checkpoint(
        &self,
        origin: &str,
        idempotency_key: &str,
    ) -> anyhow::Result<crate::workspace_registry::JournalCheckpointCommit> {
        if let Some(commit) = self
            .workspace_registry
            .lock()
            .unwrap()
            .journal_checkpoint_receipt(origin, idempotency_key)?
        {
            return Ok(commit);
        }
        let captured = crate::journal_checkpoint::capture(self)?;
        let commit = self.workspace_registry.lock().unwrap().create_journal_checkpoint(
            captured.source_sequence,
            crate::journal_checkpoint::JOURNAL_REDUCER_VERSION,
            &captured.state,
            &captured.blobs,
            origin,
            idempotency_key,
        )?;
        if !commit.journal.replayed {
            self.publish_journal_event();
        }
        Ok(commit)
    }

    pub(crate) fn journal_checkpoints(
        &self,
    ) -> anyhow::Result<Vec<crate::workspace_registry::JournalCheckpointSummary>> {
        self.workspace_registry.lock().unwrap().journal_checkpoints()
    }

    pub(crate) fn journal_restore_preview(&self, selector: &str) -> anyhow::Result<Value> {
        let checkpoint = self
            .workspace_registry
            .lock()
            .unwrap()
            .journal_checkpoint(selector)?
            .with_context(|| format!("journal checkpoint {selector:?} does not exist"))?;
        let mut reducer = crate::journal_checkpoint::RestoreReducer::new(&checkpoint)?;

        let database_path = self.workspace_registry.lock().unwrap().session_journal_database_path();
        if let Some(database_path) = database_path {
            let reader = crate::workspace_registry::SessionJournalReader::open(&database_path)?;
            let mut cursor = reader.restore_cursor(checkpoint.source_sequence)?;
            let head_sequence = loop {
                let page = cursor.next_page(1024)?;
                let head = page.head_sequence;
                let empty = page.records.is_empty();
                for record in page.records {
                    reducer.apply(&record)?;
                }
                if empty {
                    break head;
                }
            };
            cursor.finish()?;
            return reducer.finish(head_sequence);
        }

        let mut sequence = checkpoint.source_sequence;
        let mut target_head = None;
        let head_sequence = loop {
            let page = self.session_journal_after(sequence, 1024)?;
            let head = *target_head.get_or_insert(page.head_sequence);
            let empty = page.records.is_empty();
            for record in page.records {
                if record.sequence > head {
                    break;
                }
                sequence = record.sequence;
                reducer.apply(&record)?;
            }
            if empty || sequence >= head {
                break head;
            }
        };
        reducer.finish(head_sequence)
    }

    pub(crate) fn journal_segments(&self) -> anyhow::Result<Vec<crate::JournalSegment>> {
        self.workspace_registry.lock().unwrap().journal_segments()
    }

    pub(crate) fn seal_journal_segments(
        &self,
        through_sequence: u64,
        origin: &str,
        idempotency_key: &str,
    ) -> anyhow::Result<crate::workspace_registry::JournalSegmentSealCommit> {
        let database_path = self
            .workspace_registry
            .lock()
            .unwrap()
            .session_journal_database_path()
            .context("journal segment sealing requires a persistent session")?;
        let reader = crate::workspace_registry::SessionJournalReader::open(&database_path)?;
        for _ in 0..4 {
            let start = self.workspace_registry.lock().unwrap().begin_journal_segment_seal(
                through_sequence,
                origin,
                idempotency_key,
            )?;
            let plan = match start {
                crate::workspace_registry::JournalSegmentSealStart::Replay(commit) => {
                    return Ok(commit);
                }
                crate::workspace_registry::JournalSegmentSealStart::Prepare(plan) => plan,
            };
            #[cfg(test)]
            if let Some(hook) = self.journal_segment_prepare_hook.lock().unwrap().take() {
                hook();
            }
            let prepared = plan.prepare(&reader)?;
            let commit = self.workspace_registry.lock().unwrap().commit_journal_segment_seal(
                prepared,
                origin,
                idempotency_key,
            )?;
            if let Some(commit) = commit {
                if !commit.journal.replayed {
                    self.publish_journal_event();
                }
                return Ok(commit);
            }
        }
        anyhow::bail!("journal segment boundary changed repeatedly during sealing")
    }

    #[cfg(test)]
    pub(crate) fn set_screen_created_hook_for_test(
        &self,
        hook: impl FnOnce(SurfaceId) + Send + 'static,
    ) {
        *self.screen_created_hook.lock().unwrap_or_else(PoisonError::into_inner) =
            Some(Box::new(hook));
    }

    #[cfg(test)]
    pub(crate) fn set_journal_segment_prepare_hook_for_test(
        &self,
        hook: impl FnOnce() + Send + 'static,
    ) {
        *self.journal_segment_prepare_hook.lock().unwrap() = Some(Box::new(hook));
    }

    #[cfg(test)]
    pub(crate) fn journal_database_reader_count_for_test(&self) -> u64 {
        self.journal_kernel.database_reader_count()
    }

    #[cfg(test)]
    pub(crate) fn resource_mutation_count_for_test(&self) -> anyhow::Result<u64> {
        self.workspace_registry.lock().unwrap().resource_mutation_count_for_test()
    }

    #[cfg(test)]
    pub(crate) fn resource_agent_projection_count_for_test(&self) -> anyhow::Result<u64> {
        self.workspace_registry.lock().unwrap().resource_agent_projection_count_for_test()
    }

    #[cfg(test)]
    pub(crate) fn corrupt_agent_projection_for_test(&self, terminal_id: &TerminalPublicId) {
        self.workspace_registry.lock().unwrap().corrupt_agent_projection_for_test(terminal_id);
    }
}
