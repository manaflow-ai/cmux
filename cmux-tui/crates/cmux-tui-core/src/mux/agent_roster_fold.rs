//! Agent hook records and the agent roster: applying hook records, folding the roster, reconciling roster projections, and report echoes.

use super::*;

impl Mux {
    /// Committed agent hook events double as the live agent-status feed:
    /// a fresh `agent.*` journal event updates its terminal's agent record,
    /// so agents views show working/blocked/idle/done without a separate
    /// reporting channel. The journal commit remains durable even when the
    /// projection fails. The ingress path catches the projection error, stages
    /// a durable pending row, and still returns the journal receipt so callers
    /// can retain exactly-once semantics while the terminal becomes available.
    pub(super) fn apply_agent_hook_record(
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
        let Some(state) = agent_state_for_hook_kind(&ingress.kind) else { return Ok(()) };
        let Some(terminal_subject) =
            ingress.subjects.iter().find(|subject| subject.kind == "terminal")
        else {
            return Ok(());
        };
        let terminal_id = TerminalPublicId::parse(&terminal_subject.id)
            .with_context(|| format!("invalid terminal subject {:?}", terminal_subject.id))?;
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
        let next_fence = HookFence::next(
            previous_fence.as_ref(),
            agent_session_id.clone(),
            sequence,
            state == AgentState::Done,
            observed_at_ms,
        );
        // Attention-worthy transitions become durable notifications before
        // the agent report commits. The notification key is derived from the
        // journal sequence, so a retry after a crash between the two commits
        // replays the notification instead of posting it twice, and the fence
        // (stored by the report) still advances exactly once.
        if let Some((title, body, level)) = agent_hook_notification(ingress) {
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
        // The record's session field is a human-facing label; native agent
        // session ids are opaque, so views fall back to their own context.
        let marker = if state == AgentState::Done {
            format!("cmux-hook-ended:{sequence}")
        } else {
            format!("cmux-hook-sequence:{sequence}")
        };
        let (harness, ended) = (agent_provider_identity(ingress), state == AgentState::Done);
        self.note_relaunch_agent(&terminal_id, harness, explicit_session_id, ended);
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
    pub(super) fn fold_agent_roster(
        &self,
        ingress: &crate::JournalIngress,
        commit: &crate::JournalAppendCommit,
    ) {
        use crate::journal_reducers::{
            AGENT_ROSTER_REDUCER_ID, AGENT_ROSTER_REDUCER_VERSION, RosterEvent,
        };
        if ingress.producer_id != crate::agent_hooks::AGENT_HOOK_PRODUCER_ID
            && ingress.payload.get("format").and_then(Value::as_str)
                != Some(crate::journal_reducers::AGENT_PLUGIN_FORMAT)
        {
            return;
        }
        let _fold = self.agent_roster_fold.lock().unwrap();
        // Consume every intervening committed record under registry -> roster
        // lock order. Concurrent appends and delayed hook retries cannot jump
        // the cursor over a record that startup replay would have consumed.
        let (deltas, cursor, snapshot) = {
            let registry = self.workspace_registry.lock().unwrap();
            let mut host = self.agent_roster.lock().unwrap();
            if commit.sequence <= host.cursor {
                return;
            }
            let mut deltas = Vec::new();
            while host.cursor < commit.sequence {
                let page = match registry.session_journal_after(host.cursor, 512) {
                    Ok(page) => page,
                    Err(error) => {
                        eprintln!("cmux-tui: reading agent journal tail failed: {error}");
                        return;
                    }
                };
                if page.records.is_empty() {
                    break;
                }
                for record in
                    page.records.iter().take_while(|record| record.sequence <= commit.sequence)
                {
                    let changes = host.roster.apply(&RosterEvent::from_record(record));
                    // Hooks already use the durable projector, which decides
                    // events with the same session fence as this fold.
                    // Applying their reducer delta again would duplicate its
                    // projection mutations.
                    if record.payload.get("format").and_then(Value::as_str)
                        == Some(crate::journal_reducers::AGENT_PLUGIN_FORMAT)
                    {
                        deltas.extend(changes);
                    }
                    host.cursor = record.sequence;
                }
            }
            (deltas, host.cursor, host.roster.snapshot().to_string())
        };
        if let Err(error) = self.workspace_registry.lock().unwrap().put_journal_reducer_state(
            AGENT_ROSTER_REDUCER_ID,
            AGENT_ROSTER_REDUCER_VERSION,
            cursor,
            &snapshot,
        ) {
            eprintln!("cmux-tui: persisting the agent roster snapshot failed: {error}");
        }
        for delta in deltas {
            self.apply_roster_delta(delta, &ingress.kind);
        }
    }

    /// Repair public projections whose plugin roster event was folded before
    /// the daemon stopped. The roster is the canonical live view; the
    /// projection is a separately committed compatibility view for clients.
    /// Compare durable values first so a healthy restart emits no mutations.
    pub(super) fn reconcile_agent_roster_projections(&self) {
        let entries = self
            .agent_roster
            .lock()
            .unwrap()
            .roster
            .entries
            .iter()
            .filter(|(_, entry)| entry.agent_source() == AgentSource::Plugin)
            .map(|(terminal_id, entry)| (terminal_id.clone(), entry.clone()))
            .collect::<Vec<_>>();
        for (terminal_id, entry) in entries {
            let Ok(terminal_id) = TerminalPublicId::parse(&terminal_id) else { continue };
            self.reconcile_agent_roster_projection_for_entry(&terminal_id, entry);
        }
    }

    pub(super) fn reconcile_agent_roster_projections_for_terminal(
        &self,
        terminal_id: &TerminalPublicId,
    ) {
        let entry = self
            .agent_roster
            .lock()
            .unwrap()
            .roster
            .entries
            .get(terminal_id.as_str())
            .filter(|entry| entry.agent_source() == AgentSource::Plugin)
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
        self.apply_roster_delta(
            crate::journal_reducers::RosterDelta::Upsert {
                terminal_id: terminal_id.to_string(),
                entry,
            },
            "startup-reconcile",
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
            false,
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
