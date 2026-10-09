//! Agent reports: raw socket and resource agent reports, the sequence-locked commit, and the agent list.

use super::*;

impl Mux {
    pub fn report_agent(
        &self,
        surface: SurfaceId,
        state: AgentState,
        source: AgentSource,
        session: Option<String>,
    ) -> anyhow::Result<AgentRecord> {
        self.report_agent_with_sequence_lock(
            surface,
            state,
            source,
            session,
            false,
            None,
            None,
            AgentReportOrigin::Direct,
            None,
        )
    }

    // Keep the sequence lock, hook fence, and origin explicit at this
    // internal transaction boundary. Grouping them into a bag would hide the
    // lock-order contract that protects journal replay.
    #[allow(clippy::too_many_arguments)]
    pub(super) fn report_agent_with_sequence_lock(
        &self,
        surface: SurfaceId,
        state: AgentState,
        source: AgentSource,
        session: Option<String>,
        sequence_lock_held: bool,
        hook_state: Option<crate::workspace_registry::AgentHookProjectionState>,
        journal_sequence: Option<u64>,
        origin: AgentReportOrigin,
        agent_adapter: Option<String>,
    ) -> anyhow::Result<AgentRecord> {
        let mutation = WorkspaceMutation::daemon(
            format!("raw-agent-{}", crate::workspace_registry::new_uuid_v4()),
            "raw-control",
        )?;
        let fingerprint = serde_json::json!({
            "operation":"agent.report",
            "surface":surface,
            "state":state.as_str(),
            "source":source.as_str(),
            "source_session":session,
        });
        let (_, record) = self.commit_agent_report(
            AgentReportTarget::Surface(surface),
            state,
            source,
            session,
            None,
            &mutation,
            &fingerprint,
            sequence_lock_held,
            hook_state.as_ref(),
            journal_sequence,
            origin,
            agent_adapter,
        )?;
        let record = record.context("fresh raw agent report unexpectedly replayed")?;
        if source != AgentSource::Hook {
            // A successful report means this terminal is available. Retry only
            // durable hooks for that terminal, never the entire pending table.
            let _ = self.retry_pending_agent_hooks_for_terminal(&record.terminal_id);
        }
        Ok(record)
    }

    #[allow(clippy::too_many_arguments)]
    pub(crate) fn resource_report_agent_selected(
        &self,
        selectors: crate::ResourceSelectors,
        terminal_id: &TerminalPublicId,
        agent_state: AgentState,
        source: AgentSource,
        source_session: Option<String>,
        expected_revision: Option<u64>,
        mutation: &WorkspaceMutation,
    ) -> anyhow::Result<ResourcePatchCommit> {
        let fingerprint = serde_json::json!({
            "operation":"agent.report",
            "selectors":selectors,
            "terminal_id":terminal_id,
            "state":agent_state.as_str(),
            "source":source.as_str(),
            "source_session":source_session,
        });
        let result = self.commit_agent_report(
            AgentReportTarget::Resource { selectors: &selectors, terminal_id },
            agent_state,
            source,
            source_session,
            expected_revision,
            mutation,
            &fingerprint,
            false,
            None,
            None,
            AgentReportOrigin::Direct,
            None,
        );
        if result.is_ok() && source != AgentSource::Hook {
            let _ = self.retry_pending_agent_hooks_for_terminal(terminal_id);
        }
        result.map(|(commit, _)| commit)
    }

    /// Commit one agent report as the terminal's durable projection and
    /// publish its upsert or delete. Hook reports carry the agent's native
    /// session id into `extra.agent_session_id`.
    #[allow(clippy::too_many_arguments)]
    pub(super) fn commit_agent_report(
        &self,
        target: AgentReportTarget<'_>,
        agent_state: AgentState,
        source: AgentSource,
        source_session: Option<String>,
        expected_revision: Option<u64>,
        mutation: &WorkspaceMutation,
        fingerprint: &Value,
        sequence_lock_held: bool,
        hook_state: Option<&crate::workspace_registry::AgentHookProjectionState>,
        journal_sequence: Option<u64>,
        origin: AgentReportOrigin,
        agent_adapter: Option<String>,
    ) -> anyhow::Result<(ResourcePatchCommit, Option<AgentRecord>)> {
        // Hook replay already owns this guard to serialize sequence checks and
        // projection commits. Other report sources acquire it before the
        // registry/state locks, so all paths use one lock order.
        let mut sequence_guard =
            (!sequence_lock_held).then(|| self.agent_hook_fences.lock().unwrap());
        let mut registry = self.workspace_registry.lock().unwrap();
        if let Some(replay) =
            registry.replay_resource_patch(mutation, "agent.report", fingerprint)?
        {
            if let Some(sequence) = journal_sequence {
                // The projection transaction committed before this replay was
                // observed. Repair the durable apply watermark separately.
                registry.advance_agent_hook_apply_cursor(sequence)?;
            }
            return Ok((replay, None));
        }
        let mut state = self.lock_state_pinned(&registry).unwrap();
        let (surface, terminal_id) = match target {
            AgentReportTarget::Surface(surface) => {
                let runtime = state
                    .surfaces
                    .get(&surface)
                    .or_else(|| state.terminal_runtime_by_id(surface))
                    .with_context(|| format!("unknown surface {surface}"))?;
                let identity = runtime.resource_identity().with_context(|| {
                    format!("surface {surface} has no durable resource identity")
                })?;
                let ContentPublicId::Terminal(terminal_id) = &identity.content_id else {
                    anyhow::bail!("surface {surface} is not a terminal");
                };
                (surface, terminal_id.clone())
            }
            AgentReportTarget::Resource { selectors, terminal_id } => {
                self.resolve_resource_path_in_state(
                    &state,
                    &registry,
                    crate::ResourceTarget::Session,
                    selectors,
                )
                .map_err(anyhow::Error::new)?;
                let surface = state
                    .placements_of_content(&ContentPublicId::Terminal((*terminal_id).clone()))
                    .first()
                    .copied()
                    .or_else(|| state.terminal_catalog.get(terminal_id).map(|surface| surface.id))
                    .with_context(|| format!("unknown terminal {terminal_id}"))?;
                (surface, (*terminal_id).clone())
            }
        };
        let mut direct_hook_state = None;
        if source != AgentSource::Hook {
            let ended_fence = sequence_guard
                .as_ref()
                .and_then(|guard| guard.get(&terminal_id))
                .filter(|fence| fence.ended);
            let fresh_session = source_session.as_deref().filter(|session| {
                !session.starts_with("cmux-hook-sequence:")
                    && !session.starts_with("cmux-hook-ended:")
            });
            if ended_fence.is_some_and(|fence| {
                fresh_session.is_none_or(|session| session == fence.session_id)
            }) {
                anyhow::bail!("agent_session_ended");
            }
        } else if hook_state.is_none()
            && let Some(fence) = sequence_guard.as_ref().and_then(|guard| guard.get(&terminal_id))
        {
            match fence
                .direct_transition(source_session.as_deref())
                .map_err(|rejection| anyhow::anyhow!(rejection.as_str()))?
            {
                DirectHookTransition::Continue => {}
                DirectHookTransition::Restart(agent_session_id) => {
                    let restarted =
                        HookFence::next(Some(fence), agent_session_id, fence.sequence, false, None);
                    direct_hook_state = Some(crate::workspace_registry::AgentHookProjectionState {
                        agent_session_id: restarted.session_id,
                        applied_sequence: restarted.sequence,
                        ended: false,
                        ended_at_ms: restarted.ended_at_ms,
                    });
                }
            }
        }
        let effective_hook_state = direct_hook_state.as_ref().or(hook_state);
        let persisted_source_session = if source == AgentSource::Hook {
            source_session.clone().filter(|value| {
                !value.starts_with("cmux-hook-sequence:") && !value.starts_with("cmux-hook-ended:")
            })
        } else {
            if source_session.as_deref().is_some_and(|value| {
                value.starts_with("cmux-hook-sequence:") || value.starts_with("cmux-hook-ended:")
            }) {
                anyhow::bail!("reserved hook marker is invalid for non-hook agent source");
            }
            // Preserve a valid fresh socket identity. The internal hook
            // marker is only a compatibility fallback when no identity was
            // supplied, while durable hook state carries the fence itself.
            source_session.clone().or_else(|| {
                sequence_guard
                    .as_ref()
                    .and_then(|guard| guard.get(&terminal_id))
                    .map(|fence| format!("cmux-hook-sequence:{}", fence.sequence))
            })
        };
        let source_session = source_session.filter(|value| {
            !value.starts_with("cmux-hook-sequence:") && !value.starts_with("cmux-hook-ended:")
        });
        let now = now_ms();
        let mut records = self.agent_records.lock().unwrap();
        // Hook and plugin observations are stronger agent truth than a direct
        // socket report. Check the durable projection as well as the
        // in-memory cache so arbitration survives a restart.
        let durable_stronger =
            registry.public_agent_projections(Some(&terminal_id), None)?.into_iter().next().filter(
                |projection| {
                    (projection.source == AgentSource::Hook.as_str()
                        || projection.source == AgentSource::Plugin.as_str()
                        || projection.source == AgentSource::Detected.as_str())
                        && projection.state != AgentState::Done.as_str()
                        && source == AgentSource::Socket
                },
            );
        let socket_report_ignored = source == AgentSource::Socket
            && !effective_hook_state.is_some_and(|state| state.ended)
            && (records.get(&terminal_id).is_some_and(|existing| {
                existing.source == AgentSource::Hook
                    || existing.source == AgentSource::Detected
                    || existing.source == AgentSource::Plugin
            }) || durable_stronger.is_some());
        let agent_adapter = agent_adapter
            .or_else(|| records.get(&terminal_id).and_then(|record| record.agent.clone()));
        // Only hook-owned records carry the native session id: the journal
        // or restart state for this report, else the live fence it continues.
        let hook_session_id = if source == AgentSource::Hook {
            effective_hook_state.map(|state| state.agent_session_id.clone()).or_else(|| {
                sequence_guard
                    .as_ref()
                    .and_then(|guard| guard.get(&terminal_id))
                    .filter(|fence| !fence.ended)
                    .map(|fence| fence.session_id.clone())
            })
        } else {
            None
        };
        let agent_session_id = hook_session_id
            .and_then(|session_id| published_agent_session_id(&terminal_id, &session_id));
        let record = match records.get(&terminal_id) {
            Some(existing) if socket_report_ignored => existing.clone(),
            None if socket_report_ignored => match durable_stronger {
                Some(existing) => TerminalAgentRecord {
                    state: parse_projection_agent_state(&existing.state),
                    source: if existing.source == AgentSource::Plugin.as_str() {
                        AgentSource::Plugin
                    } else if existing.source == AgentSource::Detected.as_str() {
                        AgentSource::Detected
                    } else {
                        AgentSource::Hook
                    },
                    session: existing.source_session,
                    agent: existing.agent,
                    agent_session_id: existing.agent_session_id,
                    updated_at_ms: existing.updated_at_ms,
                },
                None => TerminalAgentRecord {
                    state: agent_state,
                    source,
                    session: source_session,
                    agent: agent_adapter,
                    agent_session_id,
                    updated_at_ms: now,
                },
            },
            _ => TerminalAgentRecord {
                state: agent_state,
                source,
                session: source_session,
                agent: agent_adapter,
                agent_session_id,
                updated_at_ms: now,
            },
        };
        // A socket report that is intentionally ignored by the hook-owned
        // record must persist that effective record, not the discarded socket
        // identity. Otherwise durable and in-memory projections diverge.
        let persisted_source_session =
            if socket_report_ignored { record.session.clone() } else { persisted_source_session };
        let digest = Sha256::digest(format!("cmux.protocol/2/agent/{terminal_id}").as_bytes());
        let payload = digest[..16].iter().map(|byte| format!("{byte:02x}")).collect::<String>();
        let agent_id =
            AgentPublicId::parse(format!("agent_{payload}")).map_err(anyhow::Error::new)?;
        let session_id = registry.session_id().clone();
        let extra = crate::workspace_registry::agent_projection_extra(
            record.agent.as_deref(),
            record.agent_session_id.as_deref(),
        );
        let value = serde_json::json!({
            "id":agent_id,
            "session_id":session_id,
            "terminal_id":terminal_id,
            "state":record.state.as_str(),
            "source":record.source.as_str(),
            "updated_at_ms":record.updated_at_ms.to_string(),
            "source_session":persisted_source_session.as_deref().or(record.session.as_deref()),
            "extra":extra,
        });
        let mut public_value = value.clone();
        public_value["source_session"] = serde_json::json!(record.session.as_deref());
        let deltas = if effective_hook_state.is_some_and(|state| state.ended) {
            serde_json::json!([{
                "kind":"delete",
                "sequence":0,
                "resource":"agent",
                "id":agent_id,
            }])
        } else {
            serde_json::json!([{
                "kind":"upsert",
                "sequence":0,
                "resource":"agent",
                "id":agent_id,
                "value":public_value,
            }])
        };
        let commit = registry.commit_agent_projection_with_hook_state(
            mutation,
            fingerprint,
            expected_revision,
            &terminal_id,
            &value,
            &deltas,
            effective_hook_state,
            journal_sequence,
        )?;
        if !commit.replayed
            && let (Some(direct_state), Some(sequence_guard)) =
                (direct_hook_state.as_ref(), sequence_guard.as_mut())
        {
            sequence_guard.insert(
                terminal_id.clone(),
                HookFence {
                    session_id: direct_state.agent_session_id.clone(),
                    sequence: direct_state.applied_sequence,
                    ended: false,
                    ended_at_ms: direct_state.ended_at_ms,
                },
            );
        }
        records.insert(terminal_id.clone(), record.clone());
        drop(records);
        state.resource_revision = commit.revision;
        drop(state);
        drop(registry);
        drop(sequence_guard);
        let agent = AgentRecord {
            surface,
            terminal_id,
            state: record.state,
            source: record.source,
            session: record.session,
            agent: record.agent,
            updated_at_ms: record.updated_at_ms,
        };
        if !commit.replayed {
            self.publish_resource_event();
            self.emit(MuxEvent::AgentChanged {
                surface: agent.surface,
                state: Arc::from(agent.state.as_str()),
                source: Arc::from(agent.source.as_str()),
                session: agent.session.as_deref().map(Arc::from),
                agent: agent.agent.as_deref().map(Arc::from),
                updated_at_ms: agent.updated_at_ms,
            });
            if origin == AgentReportOrigin::Direct {
                // The roster only folds journal events, so a direct report
                // records its intent in the log; the fold recognizes the
                // echo adapter and applies it roster-only.
                self.append_agent_report_echo(
                    &agent.terminal_id,
                    agent.state,
                    agent.source,
                    agent.session.as_deref(),
                    agent.updated_at_ms,
                );
            }
        }
        Ok((commit, Some(agent)))
    }

    pub fn list_agents(
        &self,
        surface: Option<SurfaceId>,
        state: Option<AgentState>,
    ) -> Vec<AgentRecord> {
        let entries = self.agent_roster.lock().unwrap().roster.entries.clone();
        let state_snapshot = self.state.lock().unwrap();
        let requested_terminal = surface.and_then(|surface| {
            state_snapshot
                .surfaces
                .get(&surface)
                .or_else(|| state_snapshot.terminal_runtime_by_id(surface))
                .and_then(|surface| surface.terminal_public_id().cloned())
        });
        let mut records = entries
            .into_iter()
            .filter_map(|(terminal_id, entry)| {
                let terminal_id = TerminalPublicId::parse(terminal_id).ok()?;
                // A terminal without a runtime runs no agent: its tabs are
                // dead (a host loss keeps them, invariant 3) or kept.
                state_snapshot.terminal_catalog.get(&terminal_id)?;
                let representative = state_snapshot
                    .placements_of_content(&ContentPublicId::Terminal(terminal_id.clone()))
                    .first()
                    .copied()
                    .or_else(|| {
                        state_snapshot.terminal_catalog.get(&terminal_id).map(|surface| surface.id)
                    })?;
                Some(AgentRecord {
                    surface: representative,
                    terminal_id,
                    state: entry.agent_state(),
                    source: entry.agent_source(),
                    session: entry.session,
                    agent: entry.agent,
                    updated_at_ms: entry.updated_at_ms,
                })
            })
            .collect::<Vec<_>>();
        records.sort_by(|left, right| left.terminal_id.as_str().cmp(right.terminal_id.as_str()));
        records
            .into_iter()
            .filter(|record| {
                requested_terminal
                    .as_ref()
                    .is_none_or(|terminal_id| &record.terminal_id == terminal_id)
            })
            .filter(|record| state.is_none_or(|state| record.state == state))
            .collect()
    }
}
