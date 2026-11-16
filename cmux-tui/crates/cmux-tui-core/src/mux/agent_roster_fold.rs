//! Agent hook records and the agent roster: applying hook records, folding the roster, reconciling roster projections, and report echoes.

use super::*;

// The roster's one owner thread: every fold and snapshot save runs there.
#[path = "agent_roster_worker.rs"]
mod agent_roster_worker;
pub(super) use agent_roster_worker::AgentRosterWorker;
// A stale roster's background rebuild, on that owner.
#[path = "agent_roster_rebuild.rs"]
mod agent_roster_rebuild;
#[cfg(test)]
pub(super) use agent_roster_rebuild::rebuild_faults;

/// How far the roster's cursor may run ahead of its saved snapshot before a
/// pass that a hook asked for saves it again (journal sequences; one replay
/// page). The snapshot holds every agent terminal's entry, fences and
/// evidence (96 KB at 170 agent terminals, 452 KB at 800), and a hook's pass
/// rewrote all of it for each hook. The journal is the truth: a start replays
/// it from the saved cursor (at most this stretch of it, besides what a crash
/// cut short), so saving less often loses nothing.
const ROSTER_SAVE_EVERY_SEQUENCES: u64 = 512;

/// The roster owner's fold state ([`AgentRosterWorker`]): its own journal
/// reader. Only the owner's passes take it, so it orders folds and snapshot
/// saves.
#[derive(Default)]
pub(super) struct AgentRosterFold {
    /// The cursor of the snapshot the owner's passes saved last. `None`
    /// before the first pass, which takes the cursor it starts from (the
    /// start's restore saved it).
    saved_cursor: Option<u64>,
    /// A read-only connection to the registry file, opened at the first
    /// fold. In WAL mode it reads committed records with no daemon lock: not
    /// the workspace registry lock, not the writer's connection lock, so a
    /// tail read never stalls a request or a journal commit. `None` until it
    /// opens, and always for an in-memory registry.
    reader: Option<crate::workspace_registry::SessionJournalReader>,
    /// Pauses the next fold after it reads one journal page (test seam).
    #[cfg(test)]
    page_hook: Option<(SyncSender<()>, Receiver<()>)>,
    /// Pauses the next fold after it took the requests and read the journal
    /// head, before it reads the roster cursor (test seam).
    #[cfg(test)]
    head_hook: Option<(SyncSender<()>, Receiver<()>)>,
    /// The thread of each journal read (head or page) and snapshot save of
    /// the roster, by name (test seam: only the roster's owner may do them).
    #[cfg(test)]
    io_threads: Vec<Option<String>>,
    /// Snapshot saves of the owner's passes (test seam).
    #[cfg(test)]
    snapshot_saves: usize,
}

impl AgentRosterFold {
    /// The fold's reader, opened on first use. `None` for an in-memory
    /// registry, or when the file cannot open (the fold then reads one page
    /// at a time under the registry, as the in-memory registry does).
    fn reader(
        &mut self,
        kernel: &crate::journal_kernel::JournalKernel,
    ) -> Option<&crate::workspace_registry::SessionJournalReader> {
        if self.reader.is_none() {
            match kernel.open_reader() {
                Ok(reader) => self.reader = reader,
                Err(error) => {
                    eprintln!("cmux-tui: opening the agent roster reader failed: {error}");
                }
            }
        }
        self.reader.as_ref()
    }

    #[cfg(test)]
    fn pause_after_page_for_test(&mut self) {
        if let Some((entered, release)) = self.page_hook.take() {
            // A test that gave up waiting dropped its ends; the fold goes on.
            let _ = entered.send(());
            let _ = release.recv();
        }
    }

    #[cfg(test)]
    fn pause_after_head_for_test(&mut self) {
        if let Some((entered, release)) = self.head_hook.take() {
            let _ = entered.send(());
            let _ = release.recv();
        }
    }

    #[cfg(test)]
    fn note_io_for_test(&mut self) {
        self.io_threads.push(std::thread::current().name().map(str::to_owned));
    }
}

impl Mux {
    /// Snapshot saves the roster owner's passes made so far.
    #[cfg(test)]
    pub(crate) fn agent_roster_snapshot_saves_for_test(&self) -> usize {
        self.agent_roster_worker.fold.lock().unwrap_or_else(PoisonError::into_inner).snapshot_saves
    }

    /// The next roster fold signals `entered` after it reads one page of
    /// the journal tail and waits for `release` before it goes on.
    #[cfg(test)]
    pub(crate) fn pause_agent_roster_fold_after_page_for_test(
        &self,
        entered: SyncSender<()>,
        release: Receiver<()>,
    ) {
        self.agent_roster_worker.fold.lock().unwrap_or_else(PoisonError::into_inner).page_hook =
            Some((entered, release));
    }

    /// The next roster fold signals `entered` after it took the requests and
    /// read the journal head, and waits for `release` before it goes on.
    #[cfg(test)]
    pub(crate) fn pause_agent_roster_fold_after_head_for_test(
        &self,
        entered: SyncSender<()>,
        release: Receiver<()>,
    ) {
        self.agent_roster_worker.fold.lock().unwrap_or_else(PoisonError::into_inner).head_hook =
            Some((entered, release));
    }

    /// The names of the threads that read the journal for the roster or
    /// saved its snapshot since the last call, in order.
    #[cfg(test)]
    pub(crate) fn take_agent_roster_io_threads_for_test(&self) -> Vec<Option<String>> {
        std::mem::take(
            &mut self
                .agent_roster_worker
                .fold
                .lock()
                .unwrap_or_else(PoisonError::into_inner)
                .io_threads,
        )
    }

    /// Committed agent hook events double as the live agent-status feed:
    /// a fresh `agent.*` journal event updates its terminal's agent record,
    /// so agents views show working/blocked/idle/done without a separate
    /// reporting channel. The journal commit remains durable even when the
    /// projection fails. The ingress path catches the projection error, stages
    /// a durable pending row, and still returns the journal receipt so callers
    /// can retain exactly-once semantics while the terminal becomes available.
    pub(super) fn project_agent_hook_record(
        &self,
        ingress: &crate::JournalIngress,
        sequence: u64,
    ) -> anyhow::Result<()> {
        if ingress.producer_id != crate::agent_hooks::AGENT_HOOK_PRODUCER_ID {
            return Ok(());
        }
        // Screen-detection events reuse the agent-hook envelope and the
        // `agent.session.ended` kind for process exits. They are owned by
        // the roster reducer, not the hook fence projector; otherwise a
        // detected process exit would create a Hook `Done` fence and could
        // suppress a later real hook lifecycle.
        if ingress.payload.get("native_event").and_then(Value::as_str)
            == Some(crate::journal_reducers::LEGACY_SCREEN_DETECT_NATIVE_EVENT)
        {
            return Ok(());
        }
        // A child agent changes no lifecycle state, but a turn's finish may wait for it.
        if ingress.kind.starts_with("agent.child.") {
            return self.apply_agent_child_hook(ingress, sequence);
        }
        use crate::journal_reducers::hook_roster_state;
        let native_event =
            ingress.payload.get("native_event").and_then(Value::as_str).unwrap_or_default();
        // Attention-worthy transitions earn a notification even when they
        // leave the roster state as it is (a failed tool call of a working
        // agent: PostToolUseFailure keeps it working but still reports the
        // error).
        let notification = agent_hook_notification(ingress);
        // Only a kind that moves a terminal under some current state, or
        // earns a notification, gets past this guard.
        if notification.is_none()
            && hook_roster_state(&ingress.kind, native_event, Some(AgentState::Blocked)).is_none()
        {
            return Ok(());
        }
        let Some(terminal_subject) =
            ingress.subjects.iter().find(|subject| subject.kind == "terminal")
        else {
            return Ok(());
        };
        let terminal_id = TerminalPublicId::parse(&terminal_subject.id)
            .with_context(|| format!("invalid terminal subject {:?}", terminal_subject.id))?;
        // A completed tool call resumes only a blocked agent, so the roster's state decides it.
        let current = self
            .agent_records
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .get(&terminal_id)
            .map(|record| record.state);
        let state = hook_roster_state(&ingress.kind, native_event, current);
        if state.is_none() && notification.is_none() {
            return Ok(());
        }
        let Some(surface) = self.resource_surface_for_terminal(&terminal_id) else {
            // A durable terminal that is still live may be between journal
            // commit and host materialization. A missing or tombstoned
            // terminal cannot become available, so do not retain its receipt
            // in the retry queue forever.
            let terminal_is_retryable = self
                .workspace_registry
                .lock()
                .unwrap()
                .agent_hook_terminal_retryable(&terminal_id)?;
            if !terminal_is_retryable {
                return Err(anyhow::Error::new(AgentHookTerminalGone));
            }
            return Err(anyhow::Error::new(AgentHookTerminalUnavailable).context(format!(
                "terminal {terminal_id} is not available for agent hook projection"
            )));
        };
        // How the CLI was started is read once, while it runs, at the first
        // hook of its session this terminal applies: its start, or a later
        // hook when that one was applied first (each hook is its own
        // connection, and the fence then drops the older start). Read before
        // the fences lock, which serializes every terminal's hooks.
        let first_of_session = ingress.kind == "agent.session.started" || {
            let session_id = ingress
                .payload
                .get("normalized")
                .and_then(|value| value.get("agent_session_id"))
                .and_then(Value::as_str)
                .filter(|session_id| !session_id.is_empty());
            let fences = self.agent_hook_fences.lock().unwrap();
            session_id.is_some_and(|session_id| {
                fences
                    .get(&terminal_id)
                    .is_none_or(|fence| fence.ended || fence.session_id != session_id)
            })
        };
        let job = first_of_session
            .then(|| {
                self.state
                    .lock()
                    .unwrap_or_else(PoisonError::into_inner)
                    .terminal_catalog
                    .get(&terminal_id)
                    .cloned()
            })
            .flatten()
            .and_then(|runtime| runtime.process_id())
            .and_then(|pid| {
                crate::platform::foreground_job_launch(
                    pid,
                    crate::workspace_registry::relaunch_store::AGENT_JOB_ENV_KEYS,
                )
            });
        // Serialize the sequence check, projection commit, and sequence
        // update as one operation. The projection path takes registry, state,
        // then agent-record locks, so teardown acquires sequence before those
        // locks as well.
        let mut fences = self.agent_hook_fences.lock().unwrap();
        let explicit_session_id = ingress
            .payload
            .get("normalized")
            .and_then(|value| value.get("agent_session_id"))
            .and_then(Value::as_str)
            .filter(|session_id| !session_id.is_empty());
        let is_session_start = ingress.kind == "agent.session.started";
        let observed_at_ms = crate::journal_reducers::hook_observed_at_ms(&ingress.payload);
        let previous_fence = fences.get(&terminal_id).cloned();
        let JournalHookTransition::Apply(agent_session_id) = HookFence::journal_transition(
            previous_fence.as_ref(),
            terminal_id.as_str(),
            explicit_session_id,
            is_session_start,
            sequence,
            observed_at_ms,
        ) else {
            return Ok(());
        };
        // Attention-worthy transitions become durable notifications before
        // the agent report commits. The notification key is derived from the
        // journal sequence, so a retry after a crash between the two commits
        // replays the notification instead of posting it twice, and the fence
        // (stored by the report) still advances exactly once. A turn that ends
        // while its child agents run is not done: its finish waits for them
        // (`agent_hook_children.rs`).
        let gate =
            self.gate_agent_finish(&terminal_id, &ingress.kind, sequence, notification.as_ref());
        if let agent_hook_children::FinishGate::Release(held) = &gate {
            self.release_held_agent_session_finish(&terminal_id, held, sequence)?;
        }
        let held = matches!(gate, agent_hook_children::FinishGate::Hold);
        if let Some((title, body, level)) = notification.filter(|_| !held) {
            self.create_durable_notification(
                &Actor::Daemon,
                &format!("agent-hook-notification-{sequence}"),
                title,
                None,
                body,
                level,
                Some(surface),
                NotificationSource::Agent,
            )
            .with_context(|| format!("agent hook notification for sequence {sequence}"))?;
        }
        // A notification that leaves the roster state as it is reports
        // nothing and leaves the fence where the last report stored it.
        let Some(state) = state else { return Ok(()) };
        let next_fence = HookFence::next(
            previous_fence.as_ref(),
            agent_session_id.clone(),
            sequence,
            state == AgentState::Done,
            observed_at_ms,
        );
        // The record's session field is a human-facing label; native agent
        // session ids are opaque, so views fall back to their own context.
        let marker = if state == AgentState::Done {
            format!("cmux-hook-ended:{sequence}")
        } else {
            format!("cmux-hook-sequence:{sequence}")
        };
        let (harness, ended) = (agent_provider_identity(ingress), state == AgentState::Done);
        self.note_relaunch_agent(&terminal_id, harness, explicit_session_id, ended, job);
        let hook_state = crate::workspace_registry::AgentHookProjectionState {
            agent_session_id,
            applied_sequence: sequence,
            ended: state == AgentState::Done,
            ended_at_ms: next_fence.ended_at_ms,
        };
        self.report_agent_with_sequence_lock(
            surface,
            state,
            AgentSource::Hook,
            Some(marker),
            true,
            Some(hook_state),
            Some(sequence),
            AgentReportOrigin::RosterFold,
            agent_provider_identity(ingress),
        )?;
        fences.insert(terminal_id.clone(), next_fence);
        // Projection ordering is complete. Do not carry the fence guard into
        // cleanup or any retry/reentrant path.
        drop(fences);
        // The terminal keeps its last harness session after it ends, so a
        // resume can find it once the roster dropped the record (W3-H).
        if let Some(session_id) = explicit_session_id {
            let harness = agent_provider_identity(ingress);
            self.note_agent_session(&terminal_id, session_id, harness.as_deref());
        }
        // An ended session leaves the roster entirely: the done state was
        // committed and broadcast above (so remote caches converge), and the
        // live record is dropped so agents views stop listing the terminal
        // and a fresh agent there starts clean. Hooks of one terminal are
        // sequential (they follow one agent process's lifecycle), so nothing
        // races this removal.
        if state == AgentState::Done {
            let mut records = self.agent_records.lock().unwrap();
            if records.get(&terminal_id).is_some_and(|record| record.state == AgentState::Done) {
                records.remove(&terminal_id);
            }
        }
        Ok(())
    }

    /// Fold one fresh `agent.*` journal commit into the roster reducer and
    /// apply the resulting deltas (projection commits, change broadcasts).
    /// The roster is derived state: this fold plus the startup tail replay
    /// are its only writers, so the journal fully determines it. Best
    /// effort by design: a hook may outlive its terminal, and a journal
    /// append must never start failing because a view cannot update.
    ///
    /// On a request path, so it only records the fold for the roster's owner
    /// (`agent_roster_worker.rs`) and returns: the owner folds right after,
    /// on its own thread (cmux-ad m11 2: a request that waited for a fold or
    /// did one held every later request of its connection).
    pub(super) fn fold_agent_roster(
        &self,
        ingress: &crate::JournalIngress,
        commit: &crate::JournalAppendCommit,
    ) {
        if ingress.producer_id != crate::agent_hooks::AGENT_HOOK_PRODUCER_ID
            && ingress.payload.get("format").and_then(Value::as_str)
                != Some(crate::journal_reducers::AGENT_PLUGIN_FORMAT)
        {
            return;
        }
        // The coalesced activity row changes no roster entry (it has no
        // terminal). A fold request for it would put the roster's cursor
        // behind what is wanted until the owner's next pass, and until then
        // every completed tool call is a journal row
        // (`tool_completion_may_resume_agent`): a row per tool report, each 5
        // minutes. The owner folds past it with the next agent row.
        if agent_hooks_at_rest::is_agent_activity_row(ingress) {
            return;
        }
        self.request_roster_work(Some(commit.sequence), None);
    }

    /// A closed terminal's roster entry goes once the roster has folded the
    /// journal head, so none of its earlier events brings it back; then the
    /// snapshot is saved, so a restart does not resurrect it either. On a
    /// request path: it records the retirement for the roster's owner and
    /// returns. `list_agents` hides the terminal at once, since it lists only
    /// terminals in the catalog, which the close already left.
    pub(super) fn retire_roster_terminal(&self, terminal_id: &TerminalPublicId) {
        self.request_roster_work(None, Some(terminal_id.to_string()));
    }

    /// One pass of the roster's owner, on its thread: fold the journal through
    /// what was asked (the head for a catch-up, or when a retirement waits;
    /// read again after each page for requests that came meanwhile), retire
    /// the closed terminals once the roster has folded that head, save the
    /// snapshot with its cursor when the pass changed either, and apply the
    /// plugin deltas. Returns the retirements it could not do (the head or a
    /// page could not be read), for the next pass.
    ///
    /// Only the owner folds and saves, so only it moves the cursor. Every
    /// record through the target is committed (a request's own commit, or the
    /// head), and the single journal writer commits sequences in order, so a
    /// reader of committed data sees every record the startup replay would
    /// fold. The tail is read with no lock a request takes (STATUS 6460: the
    /// read under the registry lock held it 1.378 s under load; cmux-ad m11 2:
    /// under the fold lock, which request paths took, 5-8 s); the roster lock
    /// is taken only to apply each page that was read.
    fn run_roster_pass(&self, pass: agent_roster_worker::RosterPass) -> Vec<String> {
        use crate::journal_reducers::{AGENT_ROSTER_REDUCER_ID, RosterEvent};
        let mut fold = self.agent_roster_worker.fold.lock().unwrap_or_else(PoisonError::into_inner);
        // The start's unfinished replay comes first, a slice per pass: its
        // records are older than any a request asks for, and they apply no
        // deltas (their effects happened when they first committed).
        let mut replayed = None;
        if self.agent_roster_replaying() {
            let mut slot =
                self.agent_roster_worker.replay.lock().unwrap_or_else(PoisonError::into_inner);
            if let Some(replay) = slot.as_mut() {
                #[cfg(test)]
                {
                    let mut gate = self
                        .agent_roster_worker
                        .replay_gate
                        .lock()
                        .unwrap_or_else(PoisonError::into_inner);
                    if let Some((entered, release)) = gate.as_ref() {
                        if entered.send(()).is_ok() && release.recv().is_ok() {
                            replay.stop_after_next_page();
                        } else {
                            *gate = None;
                            replay.run_on();
                        }
                    }
                }
                #[cfg(test)]
                fold.note_io_for_test();
                let reader = fold.reader(&self.journal_kernel);
                let journal = BackgroundRosterJournal { mux: self, reader };
                let slice = Instant::now() + agent_roster_restore::BACKGROUND_SLICE;
                #[cfg(test)]
                let injected = rebuild_faults::take_failing_replay_read(&self.session);
                #[cfg(not(test))]
                let injected = false;
                let progress = if injected {
                    Err(anyhow::anyhow!("an injected replay read failure"))
                } else {
                    replay.fold(&journal, &mut &self.agent_roster, Some(slice))
                };
                match progress {
                    Ok(agent_roster_restore::ReplayProgress::Paused) => {
                        self.agent_roster_worker.replay_failed_reads.store(0, Ordering::Release);
                        drop(slot);
                        drop(fold);
                        // The slice moved the roster: a subscriber's live
                        // count is read again from it.
                        self.activity.note_roster_changed();
                        self.continue_agent_roster_replay_later();
                        return pass.retire;
                    }
                    Ok(agent_roster_restore::ReplayProgress::Done { diagnostic }) => {
                        self.agent_roster_worker.replay_failed_reads.store(0, Ordering::Release);
                        *slot = None;
                        replayed = Some(diagnostic);
                    }
                    Err(error) => {
                        // A read that fails (I/O, a busy database) is tried
                        // again after a backoff, as the rebuild's are, with
                        // no request needed: until the replay is done, the
                        // roster is behind and `expect_agent` sends are
                        // refused. A stop drops the retry; the next start
                        // resumes from the last save.
                        let worker = &self.agent_roster_worker;
                        let failed = worker.replay_failed_reads.fetch_add(1, Ordering::AcqRel) + 1;
                        let delay = agent_roster_rebuild::roster_read_retry_delay(failed);
                        eprintln!(
                            "cmux-tui: the background agent roster replay failed ({failed} in a \
                             row), retried in {} ms: {error}",
                            delay.as_millis()
                        );
                        drop(slot);
                        drop(fold);
                        self.retry_agent_roster_replay_after(delay);
                        return pass.retire;
                    }
                }
            }
            drop(slot);
            if replayed.is_some() {
                self.agent_roster_worker.reconcile_pending.store(true, Ordering::Release);
            }
            self.agent_roster_worker.replaying.store(false, Ordering::Release);
        }
        // The reconcile the replay owes writes the roster's entries over the
        // public projections, so the roster must first fold every record
        // committed meanwhile: a hook that committed during the replay's last
        // slice (after this pass took `pass.wanted`) already wrote its row
        // through the hook projector, and its fold applies no delta. Folded
        // first, it makes the entry the hook's, which the reconcile leaves.
        let reconcile = self.agent_roster_worker.reconcile_pending.load(Ordering::Acquire);
        let mut target = pass.wanted;
        if reconcile {
            target = target.max(self.wanted_roster_sequence());
        }
        // The head a retirement waits for. It is read after the close
        // recorded the retirement, so every event of the closed terminal is at
        // or before it.
        let mut head = None;
        if pass.head || !pass.retire.is_empty() || reconcile {
            #[cfg(test)]
            fold.note_io_for_test();
            let read = match fold.reader(&self.journal_kernel) {
                Some(reader) => reader.head(),
                None => self.session_journal_head(),
            };
            match read {
                Ok(read) => {
                    head = Some(read);
                    target = target.max(read);
                }
                Err(error) => eprintln!("cmux-tui: reading the journal head failed: {error}"),
            }
        }
        #[cfg(test)]
        fold.pause_after_head_for_test();
        let start = self.agent_roster.lock().unwrap_or_else(PoisonError::into_inner).cursor;
        let mut cursor = start;
        let mut deltas = Vec::new();
        let mut changed = false;
        while cursor < target {
            #[cfg(test)]
            fold.note_io_for_test();
            // The read skips every kind the roster does not fold (terminal
            // output, session churn): the roster ignores them.
            let kinds = crate::journal_reducers::AgentRoster::folds_kind;
            let page = match fold.reader(&self.journal_kernel) {
                Some(reader) => reader.kinds_after(cursor, target, kinds, 512),
                // An in-memory registry has no file to read: one page under
                // the registry lock, which is released before the apply.
                None => self.session_journal_kinds_after(cursor, target, kinds, 512),
            };
            let (records, reached) = match page {
                Ok(page) => page,
                Err(error) => {
                    eprintln!("cmux-tui: reading agent journal tail failed: {error}");
                    break;
                }
            };
            #[cfg(test)]
            fold.pause_after_page_for_test();
            let mut host = self.agent_roster.lock().unwrap_or_else(PoisonError::into_inner);
            for record in &records {
                let changes = host.roster.apply(&RosterEvent::from_record(record));
                changed |= !changes.is_empty();
                // Hooks already use the durable projector, which decides
                // events with the same session fence as this fold.
                // Applying their reducer delta again would duplicate its
                // projection mutations. The daemon's own program status
                // evidence has no projector: its delta is applied here.
                if record.payload.get("format").and_then(Value::as_str)
                    == Some(crate::journal_reducers::AGENT_PLUGIN_FORMAT)
                    || crate::journal_reducers::is_program_status_evidence(
                        &record.producer.id,
                        &record.payload,
                    )
                {
                    deltas.extend(changes.into_iter().map(|delta| (delta, record.kind.clone())));
                }
            }
            if reached <= host.cursor {
                break;
            }
            host.cursor = reached;
            cursor = reached;
            drop(host);
            // A request that came meanwhile is folded in the same pass.
            target = target.max(self.wanted_roster_sequence());
        }
        let mut retired = false;
        let mut retired_terminals = Vec::new();
        let (left, saved) = {
            let mut host = self.agent_roster.lock().unwrap_or_else(PoisonError::into_inner);
            // Only after a head read and a fold that reached it: otherwise a
            // closed terminal's earlier event, folded later, would bring its
            // entry back.
            let left = match head {
                Some(head) if host.cursor >= head => {
                    for terminal in &pass.retire {
                        retired |= host.roster.retire_terminal(terminal);
                    }
                    retired_terminals = pass.retire;
                    Vec::new()
                }
                _ => pass.retire,
            };
            // The snapshot and its cursor are read together. A pass that
            // changed neither saves nothing and serializes nothing. A pass a
            // hook asked for saves only once the cursor ran
            // ROSTER_SAVE_EVERY_SEQUENCES past the last save; a retirement
            // is no journal record, so it saves at once, as does a pass a
            // caller waits for.
            let saved_at = *fold.saved_cursor.get_or_insert(start);
            let unsaved = retired || host.cursor != saved_at;
            let due = retired
                || pass.flush
                || host.cursor.saturating_sub(saved_at) >= ROSTER_SAVE_EVERY_SEQUENCES;
            let saved = (unsaved && due).then(|| (host.cursor, host.roster.snapshot().to_string()));
            (left, saved)
        };
        // A stale roster's rebuild folds only the journal, where a close is
        // no event: it retires the same terminals before it replaces this
        // roster, or their entries would come back.
        self.note_agent_roster_rebuild_retirements(retired_terminals);
        if let Some((cursor, snapshot)) = saved {
            #[cfg(test)]
            fold.note_io_for_test();
            #[cfg(test)]
            {
                fold.snapshot_saves += 1;
            }
            // The connection alone, never the workspace registry lock, so
            // state commits do not wait behind the snapshot write (issue 23038).
            match self.registry_connection.put_journal_reducer_state(
                AGENT_ROSTER_REDUCER_ID,
                self.agent_roster_save_version(),
                cursor,
                &snapshot,
            ) {
                Ok(()) => fold.saved_cursor = Some(cursor),
                Err(error) => {
                    eprintln!("cmux-tui: persisting the agent roster snapshot failed: {error}");
                }
            }
        }
        let reconciled = reconcile.then(|| {
            #[cfg(test)]
            fold.note_io_for_test();
            self.reconcile_after_replay(fold.reader(&self.journal_kernel))
        });
        drop(fold);
        let replay_finished = replayed.is_some();
        if let Some(diagnostic) = replayed {
            eprintln!("cmux-tui: the background agent roster replay finished");
            if let Some(diagnostic) = diagnostic {
                self.report_internal_diagnostic(diagnostic);
            }
        }
        // An agent record past the roster's cursor holds the reconcile for
        // another pass; a journal that cannot be read holds it for the next
        // request or maintenance tick.
        if reconciled == Some(Some(false)) {
            self.continue_agent_roster_replay_later();
        }
        for (delta, kind) in deltas {
            self.apply_roster_delta(delta, &kind);
        }
        // The live agent count reads the roster; an activity event sent
        // between the request and this pass read the old count. The end of a
        // background replay counts as a change whatever it folded: a
        // subscriber that came during the replay got a count from a roster
        // still behind the journal (its own snapshot or an event), and its
        // replayed records apply no deltas, so only a fresh full snapshot
        // brings that view to the current state.
        if changed || retired || replay_finished {
            self.activity.note_roster_changed();
        }
        left
    }

    /// Repair public projections whose plugin or program-status roster event
    /// was folded before the daemon stopped. The roster is the canonical live view; the
    /// projection is a separately committed compatibility view for clients.
    /// Compare durable values first so a healthy restart emits no mutations.
    pub(super) fn reconcile_agent_roster_projections(&self) {
        // A roster still replaying is behind the journal: its entries are
        // older than the projections. The replay reconciles when it is done.
        if self.agent_roster_replaying() {
            return;
        }
        // A stale roster (a reducer bump) can disagree with projections the
        // current reducer would make. The rebuild reconciles when it is done.
        if self.agent_roster_stale() {
            return;
        }
        let entries = self
            .agent_roster
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .roster
            .entries
            .iter()
            .filter(|(_, entry)| reducer_owned(entry))
            .map(|(terminal_id, entry)| (terminal_id.clone(), entry.clone()))
            .collect::<Vec<_>>();
        for (terminal_id, entry) in entries {
            let Ok(terminal_id) = TerminalPublicId::parse(&terminal_id) else { continue };
            self.reconcile_agent_roster_projection_for_entry(&terminal_id, entry);
        }
    }

    /// The projection reconcile a background replay owes, once the roster
    /// has folded every agent record: `Some(false)` when the journal holds
    /// one past the roster's cursor, `None` when it cannot be read.
    ///
    /// The check and the writes hold the hook projector's lock
    /// (`agent_hook_fences`), which a hook's projection holds from its fence
    /// check to its commit, and a hook commits its journal record before it
    /// projects. A hook projected before the check is a record past the
    /// cursor, so the reconcile waits for the pass that folds it; a hook
    /// projected after the check waits for the writes, and its newer row is
    /// the one that stays. Without the lock, a hook between the two had its
    /// row overwritten by the replay's older plugin state, and its fold
    /// applies no delta.
    fn reconcile_after_replay(
        &self,
        reader: Option<&crate::workspace_registry::SessionJournalReader>,
    ) -> Option<bool> {
        // A stale roster (a reducer bump) is not reconciled from: its
        // rebuild reconciles when it replaces the roster.
        if self.agent_roster_stale() {
            self.agent_roster_worker.reconcile_pending.store(false, Ordering::Release);
            return Some(true);
        }
        // Only the owner moves the roster, and this is the owner: its cursor
        // and entries stay as read. Read before the fences lock, as the fold
        // takes the roster lock without it.
        let (cursor, entries) = {
            let host = self.agent_roster.lock().unwrap_or_else(PoisonError::into_inner);
            let entries = host
                .roster
                .entries
                .iter()
                .filter(|(_, entry)| reducer_owned(entry))
                .map(|(terminal_id, entry)| (terminal_id.clone(), entry.clone()))
                .collect::<Vec<_>>();
            (host.cursor, entries)
        };
        let fences = self.agent_hook_fences.lock().unwrap_or_else(PoisonError::into_inner);
        let kinds = crate::journal_reducers::AgentRoster::folds_kind;
        let newer = match reader {
            Some(reader) => reader
                .head()
                .and_then(|head| reader.kinds_after(cursor, head.max(cursor), kinds, 1)),
            None => self.session_journal_head().and_then(|head| {
                self.session_journal_kinds_after(cursor, head.max(cursor), kinds, 1)
            }),
        };
        match newer {
            Ok((records, _)) if records.is_empty() => {}
            Ok(_) => return Some(false),
            Err(error) => {
                eprintln!(
                    "cmux-tui: the agent roster reconcile could not read the journal: {error}"
                );
                return None;
            }
        }
        self.agent_roster_worker.reconcile_pending.store(false, Ordering::Release);
        #[cfg(test)]
        if let Some(seam) = self
            .agent_roster_worker
            .reconcile_seam
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .take()
        {
            seam();
        }
        for (terminal_id, entry) in entries {
            let Ok(terminal_id) = TerminalPublicId::parse(&terminal_id) else { continue };
            self.reconcile_agent_roster_projection_with(&terminal_id, entry, true);
        }
        drop(fences);
        Some(true)
    }

    pub(super) fn reconcile_agent_roster_projections_for_terminal(
        &self,
        terminal_id: &TerminalPublicId,
    ) {
        // A stale roster (a reducer bump) waits for its rebuild, a replaying
        // one for its replay's reconcile.
        if self.agent_roster_settling() || self.agent_roster_stale() {
            return;
        }
        let entry = self
            .agent_roster
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .roster
            .entries
            .get(terminal_id.as_str())
            .filter(|entry| reducer_owned(entry))
            .cloned();
        if let Some(entry) = entry {
            self.reconcile_agent_roster_projection_for_entry(terminal_id, entry);
        }
    }

    pub(super) fn reconcile_agent_roster_projection_for_entry(
        &self,
        terminal_id: &TerminalPublicId,
        entry: crate::journal_reducers::RosterEntry,
    ) {
        self.reconcile_agent_roster_projection_with(terminal_id, entry, false);
    }

    /// [`Self::reconcile_agent_roster_projection_for_entry`]; with
    /// `sequence_lock_held`, the caller holds `agent_hook_fences`.
    fn reconcile_agent_roster_projection_with(
        &self,
        terminal_id: &TerminalPublicId,
        entry: crate::journal_reducers::RosterEntry,
        sequence_lock_held: bool,
    ) {
        let registry = match self.workspace_registry.lock() {
            Ok(registry) => registry,
            Err(_) => {
                eprintln!(
                    "cmux-tui: could not inspect agent projection for {terminal_id} during startup reconciliation: workspace registry mutex is poisoned"
                );
                return;
            }
        };
        let projection = match registry.public_agent_projections(Some(terminal_id), None) {
            Ok(projections) => projections.into_iter().next(),
            Err(error) => {
                eprintln!(
                    "cmux-tui: could not inspect agent projection for {terminal_id} during startup reconciliation: {error}"
                );
                return;
            }
        };
        drop(registry);
        let matches = projection.as_ref().is_some_and(|projection| {
            projection.state == entry.state
                && projection.source == entry.source
                && projection.source_session == entry.session
                && projection.agent == entry.agent
        });
        if matches {
            return;
        }
        self.apply_roster_delta_with(
            crate::journal_reducers::RosterDelta::Upsert {
                terminal_id: terminal_id.to_string(),
                entry,
            },
            "startup-reconcile",
            sequence_lock_held,
        );
    }

    /// Apply one roster delta's side effects: the durable agent projection
    /// commit and the agent-changed broadcast remote frontends converge on.
    /// A removal commits the done state (history keeps the exit; the roster
    /// already dropped the live entry).
    pub(super) fn apply_roster_delta(
        &self,
        delta: crate::journal_reducers::RosterDelta,
        kind: &str,
    ) {
        self.apply_roster_delta_with(delta, kind, false);
    }

    /// [`Self::apply_roster_delta`]; with `sequence_lock_held`, the caller
    /// holds `agent_hook_fences` (an upsert only: a hook session's end takes
    /// that lock itself).
    fn apply_roster_delta_with(
        &self,
        delta: crate::journal_reducers::RosterDelta,
        kind: &str,
        sequence_lock_held: bool,
    ) {
        use crate::journal_reducers::RosterDelta;
        let (terminal_id, state, source, session, agent_adapter) = match delta {
            RosterDelta::Upsert { terminal_id, entry } => (
                terminal_id,
                entry.agent_state(),
                entry.agent_source(),
                entry.session.clone(),
                entry.agent,
            ),
            RosterDelta::Remove { terminal_id, source } => {
                (terminal_id, AgentState::Done, source, None, None)
            }
            RosterDelta::EndHookSession { terminal_id, session_id, sequence, observed_at_ms } => {
                return self.end_hook_session_from_screen(
                    &terminal_id,
                    &session_id,
                    sequence,
                    observed_at_ms,
                );
            }
        };
        let Ok(terminal_id) = TerminalPublicId::parse(&terminal_id) else { return };
        let Some(surface) = self.resource_surface_for_terminal(&terminal_id) else { return };
        let mutation = match WorkspaceMutation::daemon(
            format!("roster-{}", crate::workspace_registry::new_uuid_v4()),
            "journal-reducer",
        ) {
            Ok(mutation) => mutation,
            Err(_) => return,
        };
        let fingerprint = serde_json::json!({
            "operation":"agent.report",
            "surface":surface,
            "state":state.as_str(),
            "source":source.as_str(),
            "source_session":session,
        });
        if let Err(error) = self.commit_agent_report(
            AgentReportTarget::Surface(surface),
            state,
            source,
            session,
            None,
            &mutation,
            &fingerprint,
            sequence_lock_held,
            None,
            None,
            AgentReportOrigin::RosterFold,
            agent_adapter,
        ) {
            eprintln!(
                "cmux-tui: agent projection update for {terminal_id} ({kind}) failed: {error}"
            );
        }
    }

    /// End a hook session the screen saw leave the foreground with no
    /// `SessionEnd` ([`crate::journal_reducers::RosterDelta::EndHookSession`]),
    /// as its `SessionEnd` would: commit its done state with the ended fence,
    /// which deletes the public row, then end the projector's fence so the
    /// next session's hooks take the terminal. Only when the fence is still
    /// that session's and no hook after the exit (journal `sequence`) was
    /// projected yet: the projector runs at ingress, ahead of this fold, and a
    /// later hook it applied is newer truth than the exit.
    fn end_hook_session_from_screen(
        &self,
        terminal_id: &str,
        session_id: &str,
        sequence: u64,
        observed_at_ms: u64,
    ) {
        let Ok(terminal_id) = TerminalPublicId::parse(terminal_id) else { return };
        let Some(surface) = self.resource_surface_for_terminal(&terminal_id) else { return };
        let mut fences = self.agent_hook_fences.lock().unwrap_or_else(PoisonError::into_inner);
        let Some(fence) = fences.get(&terminal_id).cloned().filter(|fence| {
            fence.session_id == session_id && !fence.ended && fence.sequence < sequence
        }) else {
            return;
        };
        let ended = HookFence::next(
            Some(&fence),
            fence.session_id.clone(),
            sequence,
            true,
            Some(observed_at_ms),
        );
        let hook_state = crate::workspace_registry::AgentHookProjectionState {
            agent_session_id: ended.session_id.clone(),
            applied_sequence: ended.sequence,
            ended: true,
            ended_at_ms: ended.ended_at_ms,
        };
        if let Err(error) = self.report_agent_with_sequence_lock(
            surface,
            AgentState::Done,
            AgentSource::Hook,
            Some(format!("cmux-hook-ended:{sequence}")),
            true,
            Some(hook_state),
            None,
            AgentReportOrigin::RosterFold,
            None,
        ) {
            eprintln!("cmux-tui: ending the hook session of {terminal_id} failed: {error}");
            return;
        }
        fences.insert(terminal_id.clone(), ended);
        drop(fences);
        // As a hook's `SessionEnd` does: the done state was committed and
        // broadcast, and the live record goes.
        let mut records = self.agent_records.lock().unwrap_or_else(PoisonError::into_inner);
        if records.get(&terminal_id).is_some_and(|record| record.state == AgentState::Done) {
            records.remove(&terminal_id);
        }
    }

    /// Record a direct socket/SDK agent report in the journal so the roster
    /// reducer (and any future reducer) sees every agent intent in one log.
    /// The event wears the agent-hook payload shape with a dedicated
    /// adapter, and the fold recognizes that adapter as an echo whose
    /// projection commit already happened.
    pub(super) fn append_agent_report_echo(
        &self,
        terminal_id: &TerminalPublicId,
        state: AgentState,
        source: AgentSource,
        session: Option<&str>,
        updated_at_ms: u64,
    ) {
        use crate::journal_reducers::{SOCKET_REPORT_ADAPTER, SOCKET_REPORT_NATIVE_EVENT};
        let ingress = crate::JournalIngress {
            producer_id: crate::agent_hooks::AGENT_HOOK_PRODUCER_ID.into(),
            manifest_version: crate::agent_hooks::AGENT_HOOK_MANIFEST_VERSION,
            kind: "agent.state.changed".into(),
            schema_version: 1,
            occurred_at_ms: None,
            subjects: vec![crate::JournalSubject {
                kind: "terminal".into(),
                id: terminal_id.to_string(),
            }],
            sensitivity: Some(crate::JournalSensitivity::Sensitive),
            payload: serde_json::json!({
                "format": crate::agent_hooks::AGENT_HOOK_FORMAT,
                "adapter": {"id": SOCKET_REPORT_ADAPTER, "version": 1},
                "native_event": SOCKET_REPORT_NATIVE_EVENT,
                "normalized": {
                    "state": state.as_str(),
                    "source": source.as_str(),
                    "source_session": session,
                    // The direct commit's timestamp, so the roster mirrors
                    // the projection exactly instead of stamping fold time.
                    "updated_at_ms": updated_at_ms.to_string(),
                },
                "native": {},
            }),
            causation_id: None,
            correlation_id: None,
        };
        let idempotency_key =
            format!("agent-report-echo-{}", crate::workspace_registry::new_uuid_v4());
        if let Err(error) = self.append_journal_ingress(&ingress, "agent-report", &idempotency_key)
        {
            eprintln!("cmux-tui: journaling an agent report for {terminal_id} failed: {error}");
        }
    }
}

/// Whether the roster pass, not the hook projector, commits `entry`'s public
/// projection: plugin rows, and the detected rows plugins and program-status
/// evidence write.
fn reducer_owned(entry: &crate::journal_reducers::RosterEntry) -> bool {
    matches!(entry.agent_source(), AgentSource::Plugin | AgentSource::Detected)
}

/// The background replay's journal: the roster reader's own connection for
/// the indexed read (no registry lock), the registry for the rare salvaging
/// read, and the writer's connection alone for saves, as a pass saves.
struct BackgroundRosterJournal<'a> {
    mux: &'a Mux,
    reader: Option<&'a crate::workspace_registry::SessionJournalReader>,
}

impl agent_roster_restore::RosterJournal for BackgroundRosterJournal<'_> {
    fn kinds_after(
        &self,
        cursor: u64,
        through: u64,
        limit: usize,
    ) -> anyhow::Result<(Vec<crate::workspace_registry::SessionJournalRecord>, u64)> {
        let kinds = crate::journal_reducers::AgentRoster::folds_kind;
        match self.reader {
            Some(reader) => reader.kinds_after(cursor, through, kinds, limit),
            None => self.mux.session_journal_kinds_after(cursor, through, kinds, limit),
        }
    }

    fn after_salvaging(
        &self,
        cursor: u64,
        limit: usize,
    ) -> anyhow::Result<crate::workspace_registry::session_journal::salvage::SalvagedJournalPage>
    {
        self.mux
            .workspace_registry
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .session_journal_after_salvaging(cursor, limit)
    }

    fn subject_ids_in_range(
        &self,
        kind: &str,
        start: u64,
        end: u64,
    ) -> anyhow::Result<Vec<String>> {
        self.mux
            .workspace_registry
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .journal_subject_ids_in_range(kind, start, end)
    }

    fn save(
        &self,
        how: agent_roster_restore::RosterSave,
        cursor: u64,
        snapshot: &str,
    ) -> anyhow::Result<()> {
        use crate::journal_reducers::{AGENT_ROSTER_REDUCER_ID, AGENT_ROSTER_REDUCER_VERSION};
        let connection = &self.mux.registry_connection;
        match how {
            agent_roster_restore::RosterSave::At(version) => connection.put_journal_reducer_state(
                AGENT_ROSTER_REDUCER_ID,
                version,
                cursor,
                snapshot,
            ),
            agent_roster_restore::RosterSave::FinishRebuild => connection
                .finish_journal_reducer_rebuild(
                    AGENT_ROSTER_REDUCER_ID,
                    AGENT_ROSTER_REDUCER_VERSION,
                    cursor,
                    snapshot,
                ),
        }
    }
}
