//! The session journal writer's batch append (moved out of
//! journal_extensions.rs). It runs on the registry connection alone: the
//! writer holds only the connection lock, never the workspace registry or
//! state lock (see `registry_connection`).

use super::*;

/// The journal writer's batch append. It runs on the connection alone: the
/// writer holds only the registry connection lock (see `registry_connection`).
impl RegistryConnection {
    pub(crate) fn append_journal_ingress_events_with_deadline<F>(
        &self,
        connection: &Connection,
        events: &[&crate::journal_ingress::JournalIngressEvent],
        deadline: Instant,
        busy_timeout: Duration,
        admit_commit: F,
    ) -> anyhow::Result<Vec<crate::journal_ingress::JournalBatchReceipt>>
    where
        F: FnOnce() -> anyhow::Result<()>,
    {
        self.append_journal_ingress_events_with_limits(
            connection,
            events,
            busy_timeout,
            Some(deadline),
            admit_commit,
        )
    }

    pub(super) fn append_journal_ingress_events_with_limits<F>(
        &self,
        connection: &Connection,
        events: &[&crate::journal_ingress::JournalIngressEvent],
        busy_timeout: Duration,
        deadline: Option<Instant>,
        admit_commit: F,
    ) -> anyhow::Result<Vec<crate::journal_ingress::JournalBatchReceipt>>
    where
        F: FnOnce() -> anyhow::Result<()>,
    {
        ensure_journal_deadline(deadline)?;
        connection.busy_timeout(busy_timeout)?;
        let deadline_active = deadline.map(|_| Arc::new(AtomicBool::new(true)));
        if let (Some(deadline), Some(active)) = (deadline, deadline_active.as_ref())
            && let Err(error) = connection.progress_handler(
                1,
                Some({
                    let active = active.clone();
                    move || active.load(Ordering::Acquire) && Instant::now() >= deadline
                }),
            )
        {
            let error = anyhow::Error::new(error);
            return match connection.busy_timeout(Duration::from_secs(5)) {
                Ok(()) => Err(error),
                Err(reset_error) => Err(error.context(format!(
                    "also failed to restore workspace registry busy timeout: {reset_error}"
                ))),
            };
        }
        let result = self.append_journal_ingress_events_with_current_timeout(
            connection,
            events,
            deadline,
            deadline_active.as_deref(),
            busy_timeout,
            admit_commit,
        );
        let clear_progress = if deadline.is_some() {
            connection.progress_handler(0, None::<fn() -> bool>)
        } else {
            Ok(())
        };
        let reset_timeout = connection.busy_timeout(Duration::from_secs(5));
        let cleanup = match (clear_progress, reset_timeout) {
            (Ok(()), Ok(())) => Ok(()),
            (Err(error), _) => {
                Err(anyhow::Error::new(error).context("clear workspace registry deadline handler"))
            }
            (Ok(()), Err(error)) => {
                Err(anyhow::Error::new(error).context("restore workspace registry busy timeout"))
            }
        };
        match (result, cleanup) {
            (result, Ok(())) => result,
            (Ok(_), Err(error)) => Err(error),
            (Err(error), Err(cleanup_error)) => Err(error.context(format!(
                "also failed to restore workspace registry limits: {cleanup_error:#}"
            ))),
        }
    }

    fn append_journal_ingress_events_with_current_timeout<F>(
        &self,
        connection: &Connection,
        events: &[&crate::journal_ingress::JournalIngressEvent],
        deadline: Option<Instant>,
        deadline_active: Option<&AtomicBool>,
        busy_timeout: Duration,
        admit_commit: F,
    ) -> anyhow::Result<Vec<crate::journal_ingress::JournalBatchReceipt>>
    where
        F: FnOnce() -> anyhow::Result<()>,
    {
        ensure_journal_deadline(deadline)?;
        if events.is_empty() {
            return Ok(Vec::new());
        }
        #[cfg(test)]
        let (before_commit, after_commit_admission) = {
            let mut hooks =
                self.journal_hooks.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
            (hooks.before_commit.take(), hooks.after_commit_admission.take())
        };
        let tx = connection.unchecked_transaction()?;
        // This guard disables the progress callback before `tx` rolls back on
        // every early return. An expired callback must interrupt forward work,
        // but it must never interrupt the rollback that removes partial rows.
        let deadline_guard = JournalDeadlineTransactionGuard { active: deadline_active };
        let session_id = transaction_session_id(&tx)?;
        let terminal_ids = events
            .iter()
            .filter_map(|event| match *event {
                crate::journal_ingress::JournalIngressEvent::TerminalOutput {
                    terminal_id, ..
                }
                | crate::journal_ingress::JournalIngressEvent::TerminalResize {
                    terminal_id, ..
                }
                | crate::journal_ingress::JournalIngressEvent::TerminalOutputGap {
                    terminal_id,
                    ..
                } => Some(terminal_id.as_str().to_string()),
                crate::journal_ingress::JournalIngressEvent::Frontend { .. }
                | crate::journal_ingress::JournalIngressEvent::Producer { .. }
                | crate::journal_ingress::JournalIngressEvent::Effect(_)
                | crate::journal_ingress::JournalIngressEvent::TerminalBarrier => None,
            })
            .collect::<HashSet<_>>();
        let mut expanded_by_terminal =
            terminal_topology_subjects_batch(&tx, terminal_ids.iter().cloned())?;
        let mut subjects_by_terminal = HashMap::<String, Vec<JournalSubject>>::new();
        for terminal_id in terminal_ids {
            let mut subjects = BTreeSet::from([
                JournalSubject { kind: "session".into(), id: session_id.clone() },
                JournalSubject { kind: "terminal".into(), id: terminal_id.clone() },
            ]);
            subjects.extend(expanded_by_terminal.remove(&terminal_id).unwrap_or_default());
            subjects_by_terminal.insert(terminal_id, subjects.into_iter().collect::<Vec<_>>());
        }
        let mut terminal_offsets = HashMap::<(&str, &str), u64>::new();
        let mut commits = Vec::with_capacity(events.len());
        for event in events {
            ensure_journal_deadline(deadline)?;
            if matches!(*event, crate::journal_ingress::JournalIngressEvent::TerminalBarrier) {
                commits.push(crate::journal_ingress::JournalBatchReceipt::None);
                continue;
            }
            if let crate::journal_ingress::JournalIngressEvent::Producer {
                ingress,
                validated,
                origin,
                idempotency_key,
            } = *event
            {
                commits.push(crate::journal_ingress::JournalBatchReceipt::Append(
                    append_journal_ingress_transaction(
                        &tx,
                        ingress,
                        validated,
                        origin,
                        idempotency_key,
                    )?,
                ));
                continue;
            }
            // Effect intents ride the durable lane, after every terminal
            // event of this batch, so terminal records here sequence before
            // the patch and use the subjects computed at batch start. Output
            // a new terminal writes while its create intent is queued can
            // land in this batch with the pre-create subjects (as it could
            // when the create committed alone after it).
            if let crate::journal_ingress::JournalIngressEvent::Effect(intent) = *event {
                commits.push(crate::journal_ingress::JournalBatchReceipt::Effect(
                    intent.apply_in_savepoint(&tx)?,
                ));
                continue;
            }
            if let crate::journal_ingress::JournalIngressEvent::Frontend {
                principal_id,
                occurred_at_ms,
                event,
            } = *event
            {
                validate_identifier("frontend journal principal", principal_id)?;
                validate_identifier("frontend journal generation", event.generation())?;
                validate_identifier("frontend journal event id", event.event_id())?;
                let mut subjects = BTreeSet::from([
                    JournalSubject { kind: "session".into(), id: session_id.clone() },
                    JournalSubject { kind: "client".into(), id: principal_id.clone() },
                    JournalSubject {
                        kind: "frontend_projection".into(),
                        id: event.frontend_projection_id().to_string(),
                    },
                ]);
                let (kind, payload) = match event {
                    crate::FrontendJournalEvent::Focus {
                        event_id: _,
                        frontend_projection_id,
                        generation,
                        target,
                        workspace_id,
                        screen_id,
                        pane_id,
                        tab_id,
                        content_id,
                    } => {
                        if let Some(id) = workspace_id {
                            subjects.insert(JournalSubject {
                                kind: "workspace".into(),
                                id: id.to_string(),
                            });
                        }
                        if let Some(id) = screen_id {
                            subjects.insert(JournalSubject {
                                kind: "screen".into(),
                                id: id.to_string(),
                            });
                        }
                        if let Some(id) = pane_id {
                            subjects
                                .insert(JournalSubject { kind: "pane".into(), id: id.to_string() });
                        }
                        if let Some(id) = tab_id {
                            subjects
                                .insert(JournalSubject { kind: "tab".into(), id: id.to_string() });
                        }
                        if let Some(id) = content_id {
                            subjects.insert(JournalSubject {
                                kind: match id {
                                    ContentPublicId::Terminal(_) => "terminal",
                                    ContentPublicId::Browser(_) => "browser",
                                }
                                .into(),
                                id: id.as_str().into(),
                            });
                        }
                        (
                            "frontend.focus.changed",
                            json!({
                                "format":"cmux.frontend-focus.v1",
                                "frontend_projection_id":frontend_projection_id,
                                "generation":generation,
                                "target":target,
                                "workspace_id":workspace_id,
                                "screen_id":screen_id,
                                "pane_id":pane_id,
                                "tab_id":tab_id,
                                "content_id":content_id.as_ref().map(ContentPublicId::as_str),
                            }),
                        )
                    }
                    crate::FrontendJournalEvent::Resize {
                        event_id: _,
                        frontend_projection_id,
                        generation,
                        cols,
                        rows,
                        cell_width,
                        cell_height,
                    } => {
                        anyhow::ensure!(
                            *cols > 0 && *rows > 0 && *cell_width > 0 && *cell_height > 0,
                            "frontend journal geometry must be positive"
                        );
                        (
                            "frontend.resized",
                            json!({
                                "format":"cmux.frontend-geometry.v1",
                                "frontend_projection_id":frontend_projection_id,
                                "generation":generation,
                                "cols":cols,
                                "rows":rows,
                                "cell_width":cell_width,
                                "cell_height":cell_height,
                            }),
                        )
                    }
                    crate::FrontendJournalEvent::Viewport {
                        event_id: _,
                        frontend_projection_id,
                        generation,
                        screen_id,
                        offset,
                        target,
                        settled,
                    } => {
                        if let Some(id) = screen_id {
                            subjects.insert(JournalSubject {
                                kind: "screen".into(),
                                id: id.to_string(),
                            });
                        }
                        (
                            "frontend.viewport.changed",
                            json!({
                                "format":"cmux.frontend-viewport.v1",
                                "frontend_projection_id":frontend_projection_id,
                                "generation":generation,
                                "screen_id":screen_id,
                                "offset":offset.to_string(),
                                "target":target.to_string(),
                                "settled":settled,
                            }),
                        )
                    }
                };
                expand_topology_subjects(&tx, &mut subjects)?;
                let subjects = subjects.into_iter().collect::<Vec<_>>();
                let producer = JournalProducer {
                    kind: "frontend".into(),
                    id: event.frontend_projection_id().to_string(),
                };
                let authority = JournalAuthority {
                    principal_id: principal_id.clone(),
                    lease_id: format!("frontend:{}", event.frontend_projection_id()),
                    generation: event.generation().into(),
                    role: "frontend.observer".into(),
                };
                let duplicate_sequence = tx
                    .query_row(
                        "SELECT sequence FROM journal_event_index WHERE event_id = ?1",
                        [event.event_id()],
                        |row| row.get::<_, i64>(0),
                    )
                    .optional()?
                    .map(u64::try_from)
                    .transpose()
                    .context("frontend journal sequence is negative")?;
                if let Some(sequence) = duplicate_sequence {
                    let mut records = query_session_journal_sequences(&tx, &[sequence])?;
                    let stored = records
                        .pop()
                        .context("frontend journal event index points to an absent record")?;
                    anyhow::ensure!(
                        stored.kind == kind
                            && stored.class == JournalClass::Observation
                            && stored.replay == JournalReplayPolicy::Advisory
                            && stored.producer == producer
                            && stored.authority.as_ref() == Some(&authority)
                            && stored.sensitivity == JournalSensitivity::Metadata
                            && stored.payload == payload,
                        "frontend journal event id was reused with different content"
                    );
                    commits.push(crate::journal_ingress::JournalBatchReceipt::None);
                    continue;
                }
                append_journal_record(
                    &tx,
                    &JournalAppend {
                        event_id: event.event_id(),
                        schema_version: 1,
                        kind,
                        class: JournalClass::Observation,
                        replay: JournalReplayPolicy::Advisory,
                        occurred_at_ms: *occurred_at_ms,
                        producer: &producer,
                        authority: Some(&authority),
                        causation_id: None,
                        correlation_id: None,
                        causation_depth: 0,
                        subjects: &subjects,
                        sensitivity: JournalSensitivity::Metadata,
                        payload: &payload,
                        content: None,
                        resource_revision: None,
                        previous_resource_revision: None,
                        actor: None,
                    },
                )?;
                commits.push(crate::journal_ingress::JournalBatchReceipt::None);
                continue;
            }
            let (terminal_id, generation, occurred_at_ms, kind, class, payload, content) =
                match *event {
                    crate::journal_ingress::JournalIngressEvent::TerminalOutput {
                        terminal_id,
                        generation,
                        occurred_at_ms,
                        bytes,
                    } => {
                        let key = (terminal_id.as_str(), generation.as_ref());
                        let start = match terminal_offsets.get(&key).copied() {
                            Some(offset) => offset,
                            None => {
                                let offset = tx
                                    .query_row(
                                        "SELECT next_offset FROM journal_terminal_streams
                                     WHERE terminal_id = ?1 AND generation = ?2",
                                        params![terminal_id.as_str(), generation.as_ref()],
                                        |row| row.get::<_, i64>(0),
                                    )
                                    .optional()?
                                    .map(u64::try_from)
                                    .transpose()
                                    .context("terminal journal offset is negative")?
                                    .unwrap_or(0);
                                terminal_offsets.insert(key, offset);
                                offset
                            }
                        };
                        let end = start
                            .checked_add(u64::try_from(bytes.len())?)
                            .context("terminal journal offset exhausted")?;
                        terminal_offsets.insert(key, end);
                        let digest = Sha256::digest(bytes);
                        (
                            terminal_id,
                            generation,
                            *occurred_at_ms,
                            "terminal.output",
                            JournalClass::Observation,
                            json!({
                                "format":"cmux.terminal-output.v1",
                                "encoding":"raw",
                                "byte_count":bytes.len().to_string(),
                                "sha256":encode_hex(digest.as_slice()),
                                "stream_offset_start":start.to_string(),
                                "stream_offset_end":end.to_string(),
                            }),
                            Some(bytes.as_slice()),
                        )
                    }
                    crate::journal_ingress::JournalIngressEvent::TerminalResize {
                        terminal_id,
                        generation,
                        occurred_at_ms,
                        cols,
                        rows,
                        cell_width,
                        cell_height,
                    } => (
                        terminal_id,
                        generation,
                        *occurred_at_ms,
                        "terminal.resized",
                        JournalClass::State,
                        json!({
                            "format":"cmux.terminal-geometry.v1",
                            "cols":cols,
                            "rows":rows,
                            "cell_width":cell_width,
                            "cell_height":cell_height,
                        }),
                        None,
                    ),
                    crate::journal_ingress::JournalIngressEvent::TerminalOutputGap {
                        terminal_id,
                        generation,
                        occurred_at_ms,
                        reason,
                    } => (
                        terminal_id,
                        generation,
                        *occurred_at_ms,
                        "terminal.output.gap",
                        JournalClass::State,
                        json!({
                            "format":"cmux.terminal-output-gap.v1",
                            "reason":reason,
                        }),
                        None,
                    ),
                    crate::journal_ingress::JournalIngressEvent::Frontend { .. }
                    | crate::journal_ingress::JournalIngressEvent::Producer { .. }
                    | crate::journal_ingress::JournalIngressEvent::Effect(_)
                    | crate::journal_ingress::JournalIngressEvent::TerminalBarrier => {
                        unreachable!()
                    }
                };
            let subjects = subjects_by_terminal
                .get(terminal_id.as_str())
                .context("terminal journal subjects were not prepared")?;
            let producer = JournalProducer {
                kind: "terminal_runtime".into(),
                id: terminal_id.as_str().into(),
            };
            let authority = JournalAuthority {
                principal_id: "cmux.terminal-runtime".into(),
                lease_id: format!("terminal:{}", terminal_id.as_str()),
                generation: generation.to_string(),
                role: "terminal.runtime".into(),
            };
            let event_id = random_event_id("terminal");
            append_journal_record(
                &tx,
                &JournalAppend {
                    event_id: &event_id,
                    schema_version: 1,
                    kind,
                    class,
                    replay: JournalReplayPolicy::Required,
                    occurred_at_ms,
                    producer: &producer,
                    authority: Some(&authority),
                    causation_id: None,
                    correlation_id: None,
                    causation_depth: 0,
                    subjects,
                    sensitivity: JournalSensitivity::Sensitive,
                    payload: &payload,
                    content,
                    resource_revision: None,
                    previous_resource_revision: None,
                    actor: None,
                },
            )?;
            commits.push(crate::journal_ingress::JournalBatchReceipt::None);
        }
        ensure_journal_deadline(deadline)?;
        for ((terminal_id, generation), next_offset) in terminal_offsets {
            tx.execute(
                "INSERT INTO journal_terminal_streams(terminal_id, generation, next_offset)
                 VALUES(?1, ?2, ?3)
                 ON CONFLICT(terminal_id, generation) DO UPDATE SET
                   next_offset = excluded.next_offset",
                params![terminal_id, generation, i64::try_from(next_offset)?],
            )?;
        }
        #[cfg(test)]
        if let Some((entered, release)) = before_commit {
            entered.send(()).context("report journal before-commit test hook")?;
            release.recv().context("release journal before-commit test hook")?;
        }
        ensure_journal_deadline(deadline)?;
        if let Some(deadline) = deadline {
            tx.busy_timeout(deadline.saturating_duration_since(Instant::now()).min(busy_timeout))?;
        }
        ensure_journal_deadline(deadline)?;
        admit_commit()?;
        // The caller now owns the authoritative commit result. Disable the
        // transaction deadline so a slow fsync cannot produce a false timeout
        // followed by a durable commit.
        deadline_guard.disarm();
        #[cfg(test)]
        if let Some((entered, release)) = after_commit_admission {
            entered.send(()).context("report journal commit-admission test hook")?;
            release.recv().context("release journal commit-admission test hook")?;
        }
        match tx.execute_batch("COMMIT") {
            Ok(()) => Ok(commits),
            Err(error) => {
                deadline_guard.disarm();
                match tx.rollback() {
                    Ok(()) => Err(error.into()),
                    Err(rollback_error) => Err(anyhow::Error::new(error).context(format!(
                        "also failed to roll back expired journal transaction: {rollback_error}"
                    ))),
                }
            }
        }
    }

    #[cfg(test)]
    pub(crate) fn set_journal_before_commit_for_test(
        &self,
        entered: std::sync::mpsc::SyncSender<()>,
        release: std::sync::mpsc::Receiver<()>,
    ) {
        self.journal_hooks
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .before_commit = Some((entered, release));
    }

    #[cfg(test)]
    pub(crate) fn set_journal_after_commit_admission_for_test(
        &self,
        entered: std::sync::mpsc::SyncSender<()>,
        release: std::sync::mpsc::Receiver<()>,
    ) {
        self.journal_hooks
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .after_commit_admission = Some((entered, release));
    }
}
