//! Terminal exit state and waits: exit snapshots, output reads, exit replay, and exit waiter subscription and notification.

use super::*;

impl Mux {
    /// Read only public terminal completion state. The host UUID and
    /// incarnation remain an internal fencing mechanism and never enter the
    /// resource API result.
    pub(crate) fn terminal_exit_state(
        &self,
        terminal_id: &TerminalPublicId,
    ) -> anyhow::Result<Value> {
        #[cfg(test)]
        let _query = TerminalExitStateQueryGuard(&self.terminal_exit_state_queries);
        let registry = self.workspace_registry.lock().unwrap();
        let host_id = registry
            .terminal_host_id(terminal_id)?
            .ok_or_else(|| anyhow::anyhow!("terminal {terminal_id} is not live"))?;
        let terminal = registry
            .terminal_record(&host_id)?
            .ok_or_else(|| anyhow::anyhow!("terminal {terminal_id} has no durable placement"))?;
        if terminal.lifecycle == TerminalLifecycle::Exited {
            let exit = terminal.exit.as_ref().and_then(Value::as_object).ok_or_else(|| {
                anyhow::anyhow!("exited terminal {terminal_id} omitted exit metadata")
            })?;
            let outcome = exit.get("outcome").cloned().ok_or_else(|| {
                anyhow::anyhow!("exited terminal {terminal_id} omitted its outcome")
            })?;
            let exited_at = exit.get("exited_at").and_then(Value::as_str).ok_or_else(|| {
                anyhow::anyhow!("exited terminal {terminal_id} omitted exited_at")
            })?;
            let exit_revision = exit.get("revision").and_then(Value::as_str).ok_or_else(|| {
                anyhow::anyhow!("exited terminal {terminal_id} omitted its revision")
            })?;
            return Ok(serde_json::json!({
                "state": "exited",
                "terminal_id": terminal_id,
                "lifecycle": "exited",
                "outcome": outcome,
                "exited_at": exited_at,
                "revision": exit_revision,
            }));
        }
        let revision = registry.resource_revision()?;
        let lifecycle = match terminal.lifecycle {
            TerminalLifecycle::Launching | TerminalLifecycle::Adopting => "launching",
            TerminalLifecycle::Running => "running",
            TerminalLifecycle::Exited => "exited",
            TerminalLifecycle::Tombstoned => {
                return Err(ResourceError::terminal_closed(terminal_id).into());
            }
        };
        Ok(serde_json::json!({
            "state": "pending",
            "terminal_id": terminal_id,
            "lifecycle": lifecycle,
            "revision": revision.to_string(),
        }))
    }

    /// Bounded plain-text projection of one terminal's journaled output
    /// stream. It works while the process runs and after it exits; callers
    /// resolve exited terminals through the same durable receipt as
    /// `terminal.wait_exit`.
    ///
    /// Offsets are `terminal.output` stream byte offsets of the terminal's
    /// most recent journal generation. A cursor before the exit snapshot's
    /// coverage answers with the snapshot's screen projection (start_offset
    /// 0, next_offset at the coverage end); at or past it, the window is the
    /// retained records after the cursor, rendered through a fresh terminal,
    /// never splitting one record and never exceeding `max_bytes` beyond the
    /// window's first record.
    pub(crate) fn terminal_output_read(
        &self,
        terminal_id: &TerminalPublicId,
        after: Option<u64>,
        max_bytes: u64,
    ) -> anyhow::Result<Value> {
        // Fence asynchronous output ingress so the read observes everything
        // the terminal emitted before this request.
        self.flush_terminal_journal()?;
        let requested = after.unwrap_or(0);
        let surface = self
            .terminal_resource_surface(terminal_id)
            .filter(|surface| surface.kind() == SurfaceKind::Pty);
        let (stream, snapshot, spec_geometry) = {
            let registry = self.workspace_registry.lock().unwrap();
            let stream = registry.terminal_stream_latest(terminal_id.as_str())?;
            let snapshot = registry.terminal_exit_snapshot(terminal_id.as_str())?;
            let spec_geometry = registry
                .terminal_host_id(terminal_id)?
                .map(|host_id| registry.terminal_record(&host_id))
                .transpose()?
                .flatten()
                .and_then(|terminal| {
                    Some((
                        u16::try_from(terminal.launch_spec["cols"].as_u64()?).ok()?,
                        u16::try_from(terminal.launch_spec["rows"].as_u64()?).ok()?,
                    ))
                });
            (stream, snapshot, spec_geometry)
        };
        let generation = stream
            .as_ref()
            .map(|(generation, _)| generation.clone())
            .or_else(|| snapshot.as_ref().map(|snapshot| snapshot.generation.clone()));
        let Some(generation) = generation else {
            // Nothing was ever journaled: an empty, complete stream.
            return Ok(terminal_output_read_result(String::new(), requested, requested, true));
        };
        // Offsets are per journal generation. Reads serve the most recent
        // stream; the snapshot participates only when it belongs to it.
        let snapshot = snapshot.filter(|snapshot| snapshot.generation == generation);
        let stream_end = stream.map(|(_, next_offset)| next_offset).unwrap_or(0);
        if let Some(snapshot) = &snapshot
            && requested < snapshot.covered_through
        {
            // The requested bytes are covered by the exit snapshot; earlier
            // records may already be pruned, and rendering the bounded
            // snapshot keeps the read O(snapshot) instead of O(history).
            let text = render_terminal_output_plain(
                std::iter::once(snapshot.replay_bytes.as_slice()),
                snapshot.cols,
                snapshot.rows,
            )?;
            let complete = snapshot.covered_through >= stream_end;
            return Ok(terminal_output_read_result(text, 0, snapshot.covered_through, complete));
        }
        let window = self.workspace_registry.lock().unwrap().terminal_output_records_after(
            terminal_id.as_str(),
            &generation,
            requested,
            max_bytes,
        )?;
        let Some((first, last)) = window.chunks.first().zip(window.chunks.last()) else {
            // Everything journaled so far is at or before the cursor.
            return Ok(terminal_output_read_result(String::new(), requested, requested, true));
        };
        let (cols, rows) = surface
            .as_ref()
            .map(|surface| surface.size())
            .or_else(|| snapshot.as_ref().map(|snapshot| (snapshot.cols, snapshot.rows)))
            .or(spec_geometry)
            .unwrap_or((80, 24));
        let start_offset = first.stream_offset_start;
        let next_offset = last.stream_offset_end;
        let text = render_terminal_output_plain(
            window.chunks.iter().map(|chunk| chunk.bytes.as_ref()),
            cols,
            rows,
        )?;
        Ok(terminal_output_read_result(text, start_offset, next_offset, !window.truncated))
    }

    /// Best-effort capture of a terminal's final screen as one bounded,
    /// compressed vt-replay blob. `None` whenever the runtime surface is
    /// unavailable (dead-host reconciliation, daemon restart) or any capture
    /// step fails; exit persistence never depends on it.
    pub(super) fn capture_terminal_exit_replay(
        &self,
        terminal_id: &str,
        generation: &str,
    ) -> Option<(TerminalPublicId, String, crate::workspace_registry::JournalContentBlob)> {
        let public_terminal_id =
            self.workspace_registry.lock().unwrap().terminal_resource_id(terminal_id).ok()??;
        let surface = self.terminal_resource_surface(&public_terminal_id)?;
        if surface.kind() != SurfaceKind::Pty {
            return None;
        }
        // Fence asynchronous output ingress so the journaled stream offset
        // recorded as the snapshot's coverage matches the captured VT state.
        self.flush_terminal_journal().ok()?;
        let blob =
            crate::journal_checkpoint::terminal_replay_blob(&surface, &public_terminal_id).ok()?;
        Some((public_terminal_id, generation.to_string(), blob))
    }

    pub(crate) fn subscribe_terminal_exit(
        &self,
        terminal_id: &TerminalPublicId,
    ) -> TerminalExitSubscription<'_> {
        self.terminal_exit_waiters.subscribe(terminal_id)
    }

    pub(super) fn terminal_public_ids_for_hosted(
        registry: &WorkspaceRegistry,
        hosted: &[(String, Option<String>)],
    ) -> anyhow::Result<Vec<TerminalPublicId>> {
        let mut public_ids = Vec::with_capacity(hosted.len());
        let mut unique = HashSet::with_capacity(hosted.len());
        for (terminal_id, _) in hosted {
            let is_tombstoned = registry
                .terminal_record(terminal_id)?
                .is_none_or(|terminal| terminal.lifecycle == TerminalLifecycle::Tombstoned);
            if is_tombstoned {
                continue;
            }
            if let Some(public_id) = registry.terminal_resource_id(terminal_id)?
                && unique.insert(public_id.clone())
            {
                public_ids.push(public_id);
            }
        }
        Ok(public_ids)
    }

    pub(super) fn notify_terminal_exit_waiters(
        &self,
        terminal_ids: impl IntoIterator<Item = TerminalPublicId>,
    ) {
        for terminal_id in terminal_ids {
            self.terminal_exit_waiters.notify(&terminal_id);
        }
    }

    pub(crate) fn wait_for_terminal_exit(
        &self,
        terminal_id: &TerminalPublicId,
        timeout: Option<Duration>,
    ) -> anyhow::Result<Value> {
        let deadline = timeout
            .map(|timeout| {
                Instant::now()
                    .checked_add(timeout)
                    .ok_or_else(|| anyhow::anyhow!("terminal exit timeout exceeds deadline range"))
            })
            .transpose()?;
        // Register before the initial query. A concurrent durable exit either
        // appears in that query or wakes this exact terminal subscription.
        let subscription = self.subscribe_terminal_exit(terminal_id);
        let state = self.terminal_exit_state(terminal_id)?;
        if state["state"] == "exited" || timeout == Some(Duration::ZERO) {
            return Ok(state);
        }
        let _explicit_wake = subscription.wait_until(deadline);
        // One targeted read closes either the exit-notification or deadline
        // race. Idle waits perform no periodic registry work.
        self.terminal_exit_state(terminal_id)
    }

    #[cfg(test)]
    pub(crate) fn terminal_exit_waiter_count_for_test(
        &self,
        terminal_id: &TerminalPublicId,
    ) -> usize {
        self.terminal_exit_waiters.waiter_count(terminal_id)
    }

    #[cfg(test)]
    pub(crate) fn reset_terminal_exit_state_query_count_for_test(&self) {
        self.terminal_exit_state_queries.store(0, Ordering::Release);
    }

    #[cfg(test)]
    pub(crate) fn terminal_exit_state_query_count_for_test(&self) -> u64 {
        self.terminal_exit_state_queries.load(Ordering::Acquire)
    }
}
