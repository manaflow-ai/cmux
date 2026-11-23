//! Terminal exit state and waits: exit snapshots, output reads, exit replay, and exit waiter subscription and notification.

use super::*;

impl Mux {
    /// Capture once per recovery epoch. A failed or racing capture is an
    /// explicit error, never a fallthrough to an apparently complete raw read.
    fn terminal_live_snapshot_after_gap(
        &self,
        terminal_id: &TerminalPublicId,
        epoch: &str,
        max_bytes: u64,
    ) -> anyhow::Result<Arc<crate::output_store::RecoveryCut>> {
        let Some(surface) = self
            .terminal_resource_surface(terminal_id)
            .filter(|surface| surface.kind() == SurfaceKind::Pty)
        else {
            let read = self.terminal_output_read_raw(terminal_id, None, max_bytes)?;
            anyhow::ensure!(
                read.get("snapshot").and_then(Value::as_bool) == Some(true)
                    && read.get("complete").and_then(Value::as_bool) == Some(true),
                "terminal recovery surface unavailable; retry"
            );
            let text = read.get("text").and_then(Value::as_str).unwrap_or_default().to_owned();
            anyhow::ensure!(
                text.len() as u64 <= max_bytes.min(4 * 1024 * 1024),
                "terminal recovery snapshot exceeds max_bytes"
            );
            let end = read
                .get("next_offset")
                .and_then(Value::as_str)
                .ok_or_else(|| anyhow::anyhow!("terminal recovery cursor missing"))?
                .parse()?;
            self.output_store.check_recovery_epoch(terminal_id, epoch)?;
            return self.output_store.make_recovery_cut(text, end);
        };
        let (text, end) = surface.try_with_terminal(|terminal| -> anyhow::Result<_> {
            anyhow::ensure!(
                surface.terminal_journal_capture_epoch().is_some_and(|epoch| epoch & 1 == 0),
                "terminal output capture is in progress; retry"
            );
            let (current, _, _, end) = self
                .output_store
                .recovery_state(terminal_id)
                .ok_or_else(|| anyhow::anyhow!("terminal output recovery disappeared; retry"))?;
            anyhow::ensure!(current.as_ref() == epoch, "terminal output recovery changed; retry");
            let text = terminal
                .recovery_text_bounded(usize::try_from(max_bytes.min(4 * 1024 * 1024))?)?
                .ok_or_else(|| anyhow::anyhow!("terminal recovery snapshot exceeds max_bytes"))?;
            Ok((text, end))
        })??;
        anyhow::ensure!(
            text.len() as u64 <= max_bytes.min(4 * 1024 * 1024),
            "terminal recovery snapshot exceeds max_bytes"
        );
        self.output_store.check_recovery_epoch(terminal_id, epoch)?;
        self.output_store.make_recovery_cut(text, end)
    }

    #[cfg(test)]
    pub(crate) fn terminal_output_read(
        &self,
        terminal_id: &TerminalPublicId,
        after: Option<u64>,
        max_bytes: u64,
    ) -> anyhow::Result<Value> {
        self.terminal_output_read_with_recovery(terminal_id, after, max_bytes, None)
    }

    /// Recovery is opt-in: the caller echoes the token only after applying its
    /// snapshot. No read consumes shared state on another reader's behalf.
    pub(crate) fn terminal_output_read_with_recovery(
        &self,
        terminal_id: &TerminalPublicId,
        after: Option<u64>,
        max_bytes: u64,
        recovery: Option<&str>,
    ) -> anyhow::Result<Value> {
        let requested = after.unwrap_or(0);
        let before = self.output_store.recovery_state(terminal_id);
        if let (Some(token), Some((epoch, gap, cached, end))) = (recovery, &before) {
            let mut cached = cached
                .lock()
                .map_err(|_| anyhow::anyhow!("terminal recovery cache unavailable"))?;
            let needs_cut = (token != epoch.as_ref() && (*gap || !token.is_empty()))
                || cached.as_ref().is_some_and(|cut| requested < cut.end);
            if needs_cut {
                let cut = match cached.as_ref() {
                    Some(cut) => cut.clone(),
                    None => {
                        let cut =
                            self.terminal_live_snapshot_after_gap(terminal_id, epoch, max_bytes)?;
                        *cached = Some(cut.clone());
                        cut
                    }
                };
                anyhow::ensure!(
                    cut.text.len() as u64 <= max_bytes,
                    "terminal recovery snapshot exceeds max_bytes"
                );
                let mut result =
                    terminal_output_read_result(cut.text.clone(), 0, cut.end, true, true);
                result
                    .as_object_mut()
                    .ok_or_else(|| anyhow::anyhow!("terminal recovery response is not an object"))?
                    .insert("recovery".into(), serde_json::json!(epoch.as_ref()));
                return Ok(result);
            }
            anyhow::ensure!(
                requested <= *end,
                "terminal output cursor is beyond the current stream; retry recovery"
            );
        }
        let mut result = self.terminal_output_read_raw(terminal_id, after, max_bytes)?;
        let current = self.output_store.recovery_state(terminal_id);
        anyhow::ensure!(
            before.as_ref().map(|state| &state.0) == current.as_ref().map(|state| &state.0),
            "terminal output recovery changed during read; retry"
        );
        if let Some((epoch, gap, _, _)) = current {
            let fields = result
                .as_object_mut()
                .ok_or_else(|| anyhow::anyhow!("terminal output response is not an object"))?;
            if recovery.is_some() {
                fields.insert("recovery".into(), serde_json::json!(epoch.as_ref()));
            } else if gap && fields.get("snapshot").and_then(Value::as_bool) != Some(true) {
                fields.insert("complete".into(), serde_json::json!(false));
            }
        }
        Ok(result)
    }

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

    /// Bounded plain-text projection of one terminal's output stream. It
    /// works while the process runs and after it exits; callers resolve
    /// exited terminals through the same durable receipt as
    /// `terminal.wait_exit`.
    ///
    /// Output never enters the session journal: the stream is the output
    /// store's (output_store.rs), and offsets are byte offsets of the
    /// terminal's current generation. The store keeps a bounded tail in
    /// memory (full mode: every stored byte in its segment files); a cursor
    /// older than what is kept starts at the oldest kept byte. After a daemon
    /// restart the store has no stream for an exited terminal; its exit
    /// snapshot (the final screen) answers instead, as it does for a cursor
    /// before the snapshot's coverage.
    fn terminal_output_read_raw(
        &self,
        terminal_id: &TerminalPublicId,
        after: Option<u64>,
        max_bytes: u64,
    ) -> anyhow::Result<Value> {
        let requested = after.unwrap_or(0);
        let surface = self
            .terminal_resource_surface(terminal_id)
            .filter(|surface| surface.kind() == SurfaceKind::Pty);
        let stream = self.output_store.stream_cursor(terminal_id);
        let (snapshot, spec_geometry) = {
            let registry = self.workspace_registry.lock().unwrap();
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
            (snapshot, spec_geometry)
        };
        // The snapshot takes part only when it belongs to the stream's
        // generation (or there is no stream in this daemon).
        let snapshot = snapshot.filter(|snapshot| {
            stream.as_ref().is_none_or(|(generation, _)| snapshot.generation == generation.as_ref())
        });
        let stream_end = stream.as_ref().map(|(_, next_offset)| *next_offset);
        if let Some(snapshot) = &snapshot
            && (stream_end.is_none() || requested < snapshot.covered_through)
        {
            if stream_end.is_none() && requested >= snapshot.covered_through {
                return Ok(terminal_output_read_result(
                    String::new(),
                    requested,
                    requested,
                    true,
                    false,
                ));
            }
            let text = render_terminal_output_plain(
                std::iter::once(snapshot.replay_bytes.as_slice()),
                snapshot.cols,
                snapshot.rows,
            )?;
            let complete = stream_end.is_none_or(|end| snapshot.covered_through >= end);
            return Ok(terminal_output_read_result(
                text,
                0,
                snapshot.covered_through,
                complete,
                true,
            ));
        }
        let Some(window) = self.output_store.read_after(terminal_id, requested, max_bytes) else {
            // Nothing was ever printed in this daemon: an empty, complete stream.
            return Ok(terminal_output_read_result(
                String::new(),
                requested,
                requested,
                true,
                false,
            ));
        };
        if window.bytes.is_empty() {
            return Ok(terminal_output_read_result(
                String::new(),
                window.start_offset,
                window.next_offset,
                !window.truncated,
                false,
            ));
        }
        let (cols, rows) = surface
            .as_ref()
            .map(|surface| surface.size())
            .or_else(|| snapshot.as_ref().map(|snapshot| (snapshot.cols, snapshot.rows)))
            .or(spec_geometry)
            .unwrap_or((80, 24));
        let text =
            render_terminal_output_plain(std::iter::once(window.bytes.as_slice()), cols, rows)?;
        Ok(terminal_output_read_result(
            text,
            window.start_offset,
            window.next_offset,
            !window.truncated,
            false,
        ))
    }

    /// Best-effort capture of a terminal's final screen as one bounded,
    /// compressed vt-replay blob. `None` whenever the runtime surface is
    /// unavailable (dead-host reconciliation, daemon restart) or any capture
    /// step fails; exit persistence never depends on it.
    pub(super) fn capture_terminal_exit_replay(
        &self,
        terminal_id: &str,
        generation: &str,
    ) -> Option<(TerminalPublicId, String, u64, crate::workspace_registry::JournalContentBlob)>
    {
        // terminal.persistence.mode memory: no screen reaches the disk.
        if self.output_store.memory_only() {
            return None;
        }
        let public_terminal_id =
            self.workspace_registry.lock().unwrap().terminal_resource_id(terminal_id).ok()??;
        // Nor does an incognito terminal's.
        if !self.output_store.keeps_screen(self, &public_terminal_id) {
            return None;
        }
        let surface = self.terminal_resource_surface(&public_terminal_id)?;
        if surface.kind() != SurfaceKind::Pty {
            return None;
        }
        // The snapshot covers the output store's stream up to its current
        // end; a generation that printed nothing has nothing to cover.
        let covered_through = self
            .output_store
            .stream_end(&public_terminal_id)
            .filter(|(stream_generation, end)| {
                stream_generation.as_ref() == generation && *end > 0
            })?
            .1;
        let blob =
            crate::journal_checkpoint::terminal_replay_blob(&surface, &public_terminal_id).ok()?;
        Some((public_terminal_id, generation.to_string(), covered_through, blob))
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
