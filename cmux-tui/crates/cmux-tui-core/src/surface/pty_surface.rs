//! PTY surface internals: attach and render broadcast, frame building, geometry
//! transactions and terminal colors for `PtySurface`.

use super::*;

impl PtySurface {
    pub(super) fn journal_target(&self) -> Option<(Arc<Mux>, Arc<TerminalPublicId>)> {
        let terminal_id = self.terminal_public_id.clone()?;
        let mux = self.mux.upgrade()?;
        (mux.terminal_journal_enabled() && self.journal_capture_supported)
            .then_some((mux, terminal_id))
    }

    /// Hand output the parser accepted to the output store. Output never
    /// enters the session journal (output_store.rs); the store only copies
    /// the bytes into memory here. `history` is the parser's history size
    /// after it took `bytes` (`HistoryRows::of`, O(1) under the parser lock):
    /// the store's scrollback budget measures the terminal when it grew
    /// (memory_budget.rs).
    pub(super) fn record_output(
        &self,
        (mux, terminal_id): (Arc<Mux>, Arc<TerminalPublicId>),
        bytes: &[u8],
        history: Option<crate::output_store::HistoryRows>,
    ) {
        mux.output_store.append(&terminal_id, &self.journal_generation, bytes, history);
    }

    pub(super) fn journal_geometry(&self, geometry: PtyGeometry) {
        let (Some(terminal_id), Some(mux)) = (self.terminal_public_id.clone(), self.mux.upgrade())
        else {
            return;
        };
        mux.journal_terminal_resize(
            terminal_id,
            self.journal_generation.clone(),
            geometry.cols,
            geometry.rows,
            geometry.cell_width,
            geometry.cell_height,
        );
    }

    pub(super) fn view_scrollbar_locked(&self, term: &mut Terminal) -> Option<Scrollbar> {
        let scrollbar = term.scrollbar()?;
        let bottom = scrollbar.total.saturating_sub(scrollbar.len);
        let screen = term.active_screen();
        let mut viewport = self.viewport.lock().unwrap();
        let had_anchor = viewport.anchor(screen).is_some();
        let resolved = viewport
            .anchor(screen)
            .and_then(|anchor| term.tracked_screen_point(anchor))
            .map(|(_, row)| u64::from(row).min(bottom));
        let offset = match (had_anchor, resolved) {
            (_, Some(offset)) => offset,
            (false, None) => bottom,
            (true, None) if bottom > 0 => {
                *viewport.anchor_mut(screen) = term.track_screen_point(0, 0).ok();
                if viewport.anchor(screen).is_some() { 0 } else { bottom }
            }
            (true, None) => {
                *viewport.anchor_mut(screen) = None;
                bottom
            }
        };
        if offset == bottom {
            *viewport.anchor_mut(screen) = None;
        }
        Some(Scrollbar { offset, ..scrollbar })
    }

    pub(super) fn set_view_scroll_offset_locked(&self, term: &mut Terminal, offset: u64) {
        let Some(scrollbar) = term.scrollbar() else { return };
        let bottom = scrollbar.total.saturating_sub(scrollbar.len);
        let target = offset.min(bottom);
        let screen = term.active_screen();
        let mut viewport = self.viewport.lock().unwrap();
        let anchor = viewport.anchor_mut(screen);
        if target == bottom {
            *anchor = None;
            return;
        }
        let Ok(target) = u32::try_from(target) else {
            *anchor = None;
            return;
        };
        if anchor
            .as_mut()
            .is_some_and(|anchor| term.set_tracked_screen_point(anchor, 0, target).is_ok())
        {
            return;
        }
        *anchor = term.track_screen_point(0, target).ok();
    }

    #[cfg(test)]
    pub(super) fn run_geometry_test_hook(&self, step: PtyGeometryTestStep) {
        let hook = self.geometry_test_hook.lock().unwrap().clone();
        if let Some(hook) = hook {
            hook(step);
        }
    }

    /// Snapshot sparse colors and the host-resolved cursor visual without
    /// touching the shared renderer or consuming its damage.
    pub(super) fn terminal_colors_locked(
        &self,
        term: &Terminal,
        defaults: DefaultColors,
    ) -> TerminalColors {
        TerminalColors::from_terminal(term, defaults)
    }

    /// The hex terminal id flow marks name this terminal by (empty without a host identity).
    pub(crate) fn flow_terminal_id(&self) -> &str {
        self.host_identity.as_ref().map_or("", |id| id.terminal_id.as_str())
    }

    pub(super) fn broadcast_attach_output(&self, bytes: &[u8]) -> bool {
        cmux_flow_trace::hop("daemon.output.attach", 0, self.flow_terminal_id());
        self.snapshot_position.add_output(bytes.len());
        let mut taps = self.taps.lock().unwrap();
        if taps.is_empty() {
            return false;
        }
        let frame = AttachFrame::Output(bytes.to_vec());
        taps.retain(|tap| tap.try_send(frame.clone()));
        let sent = !taps.is_empty();
        drop(taps);
        if sent {
            self.mark_attach_output_sent();
        }
        sent
    }

    /// The first output a followed terminal sends an attachment
    /// (`CMUX_TUI_DEBUG_SPANS`).
    fn mark_attach_output_sent(&self) {
        if crate::debug_spans::following()
            && let Some(identity) = self.host_identity.as_ref()
        {
            crate::debug_spans::terminal_mark(&identity.terminal_id, "attach.first_output_sent");
        }
    }

    /// Viewers without pending-sequence support reconnect from a fresh
    /// snapshot rather than receive a replay that ends inside a sequence.
    pub(super) fn cancel_taps_without_pending_support(&self) {
        self.taps.lock().unwrap().retain(|tap| {
            let keep = tap.lifecycle.resumes_pending_sequence();
            if !keep {
                tap.lifecycle.cancel();
            }
            keep
        });
    }

    /// Send `frame` to replay viewers only; snapshot viewers are untouched.
    pub(super) fn broadcast_attach_frame_to_replay_taps(&self, frame: AttachFrame) {
        self.taps.lock().unwrap().retain(|tap| tap.is_snapshot() || tap.try_send(frame.clone()));
    }

    /// Disconnect replay viewers (they reattach from fresh state); snapshot
    /// viewers stay and resync by snapshot.
    pub(super) fn cancel_replay_taps(&self) {
        self.taps.lock().unwrap().retain(|tap| {
            let snapshot = tap.is_snapshot();
            if !snapshot {
                tap.lifecycle.cancel();
            }
            snapshot
        });
    }

    /// A grid or scene change with no replay broadcast: start a new
    /// generation and send every snapshot viewer a snapshot.
    pub(super) fn resync_snapshot_taps(&self) {
        self.snapshot_position.bump_generation();
        for tap in &*self.taps.lock().unwrap() {
            tap.resync_snapshot();
        }
    }

    pub(super) fn broadcast_attach_frame(&self, frame: AttachFrame) {
        self.snapshot_position.observe_frame(&frame);
        let mut taps = self.taps.lock().unwrap();
        taps.retain(|tap| tap.try_send(frame.clone()));
        let sent_output = matches!(frame, AttachFrame::OutputWithColors { .. }) && !taps.is_empty();
        drop(taps);
        if sent_output {
            self.mark_attach_output_sent();
        }
    }

    /// Replace every byte-stream mirror after a sidecar-only state change.
    /// Limit eviction has no PTY bytes, so continuing the old stream without
    /// this replay would leave mirrors on a different Kitty scene.
    pub(super) fn resynchronize_attach_taps_locked(&self, term: &mut Terminal) {
        {
            let mut taps = self.taps.lock().unwrap();
            taps.retain(|tap| !tap.lifecycle.is_canceled());
            if !taps.iter().any(|tap| !tap.is_snapshot()) {
                drop(taps);
                self.resync_snapshot_taps();
                return;
            }
        }
        let replay = match term.vt_replay_bounded_theme_portable_with_aliases(VT_REPLAY_MAX_BYTES) {
            Ok(replay) => replay,
            Err(_) => {
                self.cancel_replay_taps();
                self.resync_snapshot_taps();
                return;
            }
        };
        let defaults = self.mux.upgrade().map(|mux| mux.default_colors()).unwrap_or_default();
        let colors = Box::new(self.terminal_colors_locked(term, defaults));
        self.attach_colors_pending.store(false, Ordering::Release);
        self.attach_colors_force_pending.store(false, Ordering::Release);
        *self.last_attach_colors.lock().unwrap() =
            Some(Box::new(TerminalColors::from_pty_output(term, defaults)));
        if !replay.pending_sequence.is_empty() {
            self.cancel_taps_without_pending_support();
        }
        self.broadcast_attach_frame(AttachFrame::ResizedWithColors {
            cols: term.cols(),
            rows: term.rows(),
            replay: replay.bytes.into(),
            kitty_image_aliases: replay.kitty_image_aliases,
            kitty_state: replay.kitty_state,
            colors,
            pending_sequence: replay.pending_sequence.into(),
        });
    }

    /// Emit at most one latest effective palette snapshot per frame cadence.
    /// The caller holds `term`, so attach registration cannot interleave with
    /// the snapshot or miss a state transition.
    pub(super) fn flush_attach_colors_locked(
        &self,
        term: &Terminal,
        defaults: DefaultColors,
    ) -> bool {
        if !self.attach_colors_pending.swap(false, Ordering::AcqRel) {
            return false;
        }
        let force = self.attach_colors_force_pending.swap(false, Ordering::AcqRel);
        {
            let mut taps = self.taps.lock().unwrap();
            taps.retain(|tap| !tap.lifecycle.is_canceled());
            if taps.is_empty() {
                return false;
            }
        }

        let live_colors = TerminalColors::from_pty_output(term, defaults);
        let mut last = self.last_attach_colors.lock().unwrap();
        if !force && last.as_deref() == Some(&live_colors) {
            return false;
        }
        *last = Some(Box::new(live_colors));
        drop(last);
        let colors =
            if force { TerminalColors::from_terminal(term, defaults) } else { live_colors };
        self.broadcast_attach_frame(AttachFrame::ColorsChanged(Arc::new(colors)));
        true
    }

    /// Ask the frame producer for a frame of `generation`; the producer
    /// announces the output (`SurfaceOutput`) after it built the frame. For
    /// a caller that may hold `Mux::state`.
    pub(super) fn request_frame(&self, generation: u64) {
        self.frame_requests.request(generation, true);
    }

    /// [`Self::request_frame`] from a terminal's output reader: the output
    /// is announced now, from the reader that read it, not by the producer
    /// after the frame (H3). The caller holds no terminal or mux lock.
    pub(super) fn request_frame_from_reader(&self, generation: u64) {
        self.frame_requests.request(generation, false);
        self.mark_output_dirty();
    }

    /// Apply one replacement to the terminal stream and publish its revision.
    /// The revision must be published before another screen reader can acquire
    /// the terminal lock.
    pub(super) fn with_terminal_stream_update<R>(
        &self,
        update: impl FnOnce(&mut Terminal) -> R,
    ) -> R {
        let mut term = self.term.lock().unwrap();
        let result = update(&mut term);
        self.stream_progress.notify();
        result
    }

    /// Publish the last PTY generation before the mux drops this surface.
    ///
    /// A normal frame request may still be waiting for the cadence deadline,
    /// and the frame worker holds only a weak reference. Building here keeps
    /// the final render frame ordered after the byte taps and before detach.
    pub(super) fn publish_final_frame(&self) {
        let mut term = self.term.lock().unwrap();
        let generation = self.drop_exited_modes(&mut term);
        let _ = self.build_producer_frame(term, generation);
        // The last output's scroll position, before the surface goes.
        if let Some(mux) = self.mux.upgrade() {
            let _ = self.frame_requests.flush_scroll(&mux, self.event_surface_id);
        }
    }

    /// Preserve the last hosted frame, then end every live attachment while
    /// retaining the exited surface as a stable, snapshot-renderable tab.
    pub(super) fn finish_hosted_exit(&self) {
        let mut term = self.term.lock().unwrap();
        // Attach takes the same terminal lock. The caller that changes `dead`
        // owns finalization; a prior host-loss owner must keep its state and
        // reject an incomplete replay.
        if self.dead.swap(true, Ordering::AcqRel) {
            return;
        }
        let generation = self.drop_exited_modes(&mut term);
        let _ = self.build_frame_locked(&mut term, generation, true);
        self.taps.lock().unwrap().clear();
        self.render.lock().unwrap().taps.clear();
        // Publish Exited only after the final frame is built and both stream
        // sets are closed. An attacher that acquires `term` next can then
        // observe a live terminal or a complete, inert final snapshot.
        self.host_connection_state
            .store(TerminalHostConnectionState::Exited as u8, Ordering::Release);
        drop(term);
        self.mark_output_dirty();
    }

    /// The exited child's modes off, so its retained tab selects and
    /// pastes like plain text instead of capturing the mouse. Published as
    /// output: byte taps get the same reset and the returned generation
    /// renders it.
    fn drop_exited_modes(&self, term: &mut Terminal) -> u64 {
        let exit_reset = crate::prompt_mode_reset::exit_reset(term);
        let reset = term.vt_write_with_normalized(&exit_reset);
        self.broadcast_attach_output(&reset);
        self.mouse_encoders.lock().unwrap().sync_from_terminal(term);
        let generation = self.render_generation.fetch_add(1, Ordering::AcqRel) + 1;
        self.stream_progress.notify();
        generation
    }

    pub(super) fn mark_output_dirty(&self) {
        if self.dirty.swap(true, Ordering::AcqRel) {
            return;
        }
        #[cfg(test)]
        self.run_geometry_test_hook(PtyGeometryTestStep::OutputEventStarted);
        if let Some(mux) = self.mux.upgrade() {
            mux.emit_terminal_output(self.event_surface_id);
        }
    }

    /// Build a producer-driven frame, release `term`, then publish
    /// `SurfaceOutput`. The output event takes `Mux::state`, which is ordered
    /// before `term` (see [`PtyTerminalRuntime`]), so it must not run while the
    /// terminal lock is held.
    pub(super) fn build_producer_frame(
        &self,
        mut term: RankedGuard<'_, Box<Terminal>>,
        generation: u64,
    ) -> ghostty_vt::Result<bool> {
        let built = self.build_frame_locked(&mut term, generation, true);
        drop(term);
        self.mark_output_dirty();
        built
    }

    /// Build and fan out one immutable frame while the caller holds `term`.
    /// This never calls into the mux; a producer-driven caller publishes the
    /// output event through [`Self::build_producer_frame`] after unlocking.
    pub(super) fn build_frame_locked(
        &self,
        term: &mut Terminal,
        generation: u64,
        producer_driven: bool,
    ) -> ghostty_vt::Result<bool> {
        let built = {
            let mut render = self.render.lock().unwrap();
            if (producer_driven && render.taps.is_empty()) || render.built_generation >= generation
            {
                false
            } else {
                render.state.update(term)?;
                let palette_colors =
                    std::array::from_fn(|idx| render.state.palette_color(idx as u8));
                let palette_overridden =
                    std::array::from_fn(|idx| render.state.palette_overridden(idx as u8));
                let frame = Arc::new(SurfaceRenderFrame {
                    frame: render.state.build_frame()?,
                    content_generation: generation,
                    scrollback_rows: term.history_rows(),
                    history_epoch: term.history_epoch(),
                    pointer_semantics: term.pointer_semantic_snapshot(),
                    palette_colors,
                    palette_overridden,
                });
                if render
                    .initial_graphics
                    .as_ref()
                    .is_some_and(|cached| !Arc::ptr_eq(&cached.source, &frame.frame.kitty_graphics))
                {
                    render.initial_graphics = None;
                }
                render.built_generation = generation;
                render.latest = Some(frame.clone());
                render.final_initial = None;
                render.taps.retain(|tap| tap.send(RenderAttachFrame::Frame(frame.clone())));
                true
            }
        };
        Ok(built)
    }

    /// Resize both the PTY and the terminal state. Returns whether the
    /// final clamped size actually changed.
    pub(super) fn resize(&self, cols: u16, rows: u16) -> anyhow::Result<bool> {
        #[cfg(test)]
        self.run_geometry_test_hook(PtyGeometryTestStep::ResizeStarted);
        let (cols, rows) = (cols.max(1), rows.max(1));
        let mut geometry = self.geometry.lock().unwrap();
        let next = PtyGeometry { cols, rows, ..*geometry };
        #[cfg(any(unix, windows))]
        {
            let runtime = self.runtime.lock().unwrap();
            if let PtyRuntime::Hosted(host) = &*runtime {
                // Do not speculatively reflow the mirror. The host orders
                // either a compact smart-renderer marker or a legacy
                // Resized+Colors replay on its authoritative byte stream.
                // `true` only when a new size went to the host, so callers
                // wait for a `Resized` only when one can come.
                return Ok(host.send_viewer_size(cols, rows)?);
            }
            if matches!(&*runtime, PtyRuntime::ExitedHosted) {
                return Ok(false);
            }
        }
        self.commit_geometry(&mut geometry, next, true)
    }

    pub(super) fn set_cell_pixel_size(
        &self,
        width_px: u16,
        height_px: u16,
    ) -> anyhow::Result<bool> {
        self.set_cell_pixel_size_until(width_px, height_px, None)
    }

    pub(super) fn set_cell_pixel_size_until(
        &self,
        width_px: u16,
        height_px: u16,
        deadline: Option<Instant>,
    ) -> anyhow::Result<bool> {
        #[cfg(test)]
        self.run_geometry_test_hook(PtyGeometryTestStep::CellPixelStarted);
        let requested = (width_px.max(1), height_px.max(1));
        {
            let geometry = self.geometry.lock().unwrap();
            if (geometry.cell_width, geometry.cell_height) == requested {
                return Ok(false);
            }
        }
        #[cfg(any(unix, windows))]
        {
            let runtime = self.runtime.lock().unwrap();
            match &*runtime {
                PtyRuntime::Hosted(host) => {
                    let accepted = match deadline {
                        Some(deadline) => {
                            host.send_cell_pixel_size_until(requested.0, requested.1, deadline)?
                        }
                        None => host.send_cell_pixel_size(requested.0, requested.1)?,
                    };
                    if !accepted {
                        return Ok(false);
                    }
                    drop(runtime);
                    // The host publishes Resized+Colors before its targeted
                    // acknowledgement. The reader therefore installs the
                    // canonical parser and metrics before this wait returns.
                    let geometry = self.geometry.lock().unwrap();
                    if (geometry.cell_width, geometry.cell_height) != requested {
                        drop(geometry);
                        if let PtyRuntime::Hosted(host) = &*self.runtime.lock().unwrap() {
                            host.disconnect();
                        }
                        anyhow::bail!(
                            "terminal host acknowledged cell metrics without publishing \
                             the canonical geometry transition"
                        );
                    }
                    return Ok(true);
                }
                PtyRuntime::ExitedHosted => return Ok(false),
                PtyRuntime::Local { .. } => {}
            }
        }
        let mut geometry = self.geometry.lock().unwrap();
        let next = PtyGeometry { cell_width: requested.0, cell_height: requested.1, ..*geometry };
        self.commit_geometry(&mut geometry, next, false)
    }

    /// Commit the PTY ioctl or hosted mirror metrics, Ghostty geometry, and
    /// the published logical tuple while holding one geometry transaction.
    pub(super) fn commit_geometry(
        &self,
        geometry: &mut PtyGeometry,
        next: PtyGeometry,
        refresh_attach_colors: bool,
    ) -> anyhow::Result<bool> {
        self.commit_geometry_for_runtime(geometry, next, refresh_attach_colors, false)
    }

    #[cfg(any(unix, windows))]
    pub(super) fn commit_hosted_geometry(
        &self,
        geometry: &mut PtyGeometry,
        next: PtyGeometry,
        refresh_attach_colors: bool,
    ) -> anyhow::Result<bool> {
        // The authoritative host has already resized its PTY. Avoid taking
        // the attachment lock while applying its ordered mirror transition:
        // a control caller can be holding that lock while it waits for the
        // acknowledgement queued immediately after this frame.
        self.commit_geometry_for_runtime(geometry, next, refresh_attach_colors, true)
    }

    pub(super) fn commit_geometry_for_runtime(
        &self,
        geometry: &mut PtyGeometry,
        next: PtyGeometry,
        refresh_attach_colors: bool,
        hosted_mirror: bool,
    ) -> anyhow::Result<bool> {
        if *geometry == next {
            return Ok(false);
        }
        let grid_changed = (geometry.cols, geometry.rows) != (next.cols, next.rows);
        let previous = *geometry;
        let next_pty_size = next.pty_size();
        let previous_pty_size = previous.pty_size();
        // Parse queued direct-PTY bytes on the old grid, even if the reader
        // has not woken yet. Keep the shared parser through the ioctl and
        // reflow so no read-to-parser gap can cross this boundary. Observers
        // are queued for the reader to publish without geometry or term held.
        #[cfg(unix)]
        let mut local_output = self
            .local_output
            .as_ref()
            .map(|output| output.lock().unwrap_or_else(std::sync::PoisonError::into_inner));
        #[cfg(unix)]
        if let Some(output) = local_output.as_mut() {
            output.drain(self)?;
        }
        let mut term = self.term.lock().unwrap();
        let runtime = (!hosted_mirror).then(|| self.runtime.lock().unwrap());
        let master = match runtime.as_deref() {
            Some(PtyRuntime::Local { master, .. }) => master.as_deref(),
            #[cfg(any(unix, windows))]
            Some(PtyRuntime::Hosted(_)) => None,
            #[cfg(any(unix, windows))]
            Some(PtyRuntime::ExitedHosted) => return Ok(false),
            None => None,
        };
        // Replay viewers need a replay of the new grid; snapshot viewers get
        // a snapshot from their worker and never block or cancel a resize.
        let mut has_attach_taps = {
            let mut taps = self.taps.lock().unwrap();
            taps.retain(|tap| !tap.lifecycle.is_canceled());
            taps.iter().any(|tap| !tap.is_snapshot())
        };
        // A replacement replay ends inside the same incomplete sequence as
        // this parser, so byte mirrors follow a resize at any byte. Only a
        // control string larger than the replay's pending-sequence budget
        // cannot be carried; those mirrors reconnect from a fresh snapshot
        // instead of consuming a corrupt replay.
        if has_attach_taps && !term.vt_replay_resumes_stream() {
            self.cancel_replay_taps();
            has_attach_taps = false;
        }
        // The only replay state that cannot be bounded by dropping old text
        // and completed graphics is an oversized in-flight Kitty upload.
        // Reject it before resize mutates Ghostty's reflow and scrollback.
        if has_attach_taps {
            term.preflight_vt_replay_bounded(VT_REPLAY_MAX_BYTES).map_err(|error| {
                anyhow::anyhow!(
                    "could not preflight attach replay before resizing PTY surface to {}x{} at \
                     {}x{} px per cell: {error}; geometry unchanged",
                    next.cols,
                    next.rows,
                    next.cell_width,
                    next.cell_height
                )
            })?;
        }
        if let Some(master) = master {
            master.resize(next_pty_size).map_err(|error| {
                anyhow::anyhow!(
                    "could not resize PTY master to {}x{} at {}x{} px per cell: {error}",
                    next.cols,
                    next.rows,
                    next.cell_width,
                    next.cell_height
                )
            })?;
        }
        if let Err(error) = term.resize(
            next.cols,
            next.rows,
            u32::from(next.cell_width),
            u32::from(next.cell_height),
        ) {
            let rollback = master.map_or(Ok(()), |master| master.resize(previous_pty_size));
            return match rollback {
                Ok(()) => Err(anyhow::anyhow!(
                    "could not resize Ghostty terminal to {}x{} at {}x{} px per cell: {error}",
                    next.cols,
                    next.rows,
                    next.cell_width,
                    next.cell_height
                )),
                Err(rollback_error) => Err(anyhow::anyhow!(
                    "could not resize Ghostty terminal to {}x{} at {}x{} px per cell: {error}; \
                     PTY master rollback also failed: {rollback_error}",
                    next.cols,
                    next.rows,
                    next.cell_width,
                    next.cell_height
                )),
            };
        }
        let replay = if has_attach_taps {
            #[cfg(test)]
            self.vt_replay_builds.fetch_add(1, Ordering::AcqRel);
            match term.vt_replay_bounded_theme_portable_with_aliases(VT_REPLAY_MAX_BYTES) {
                Ok(replay) => Some(replay),
                Err(_) => {
                    // Budget failure was already ruled out under this same
                    // terminal lock. A formatter/backend failure must not be
                    // answered with a destructive inverse resize. Disconnect
                    // byte mirrors so they reattach from fresh state.
                    self.cancel_replay_taps();
                    None
                }
            }
        } else {
            None
        };
        drop(runtime);
        *geometry = next;
        self.journal_geometry(next);
        #[cfg(test)]
        self.run_geometry_test_hook(if refresh_attach_colors {
            PtyGeometryTestStep::ResizeCommitBoundary
        } else {
            PtyGeometryTestStep::CellPixelCommitBoundary
        });
        let generation = self.render_generation.fetch_add(1, Ordering::AcqRel) + 1;
        let _ = self.build_frame_locked(&mut term, generation, false);
        if let Some(replay) = replay {
            let defaults = self.mux.upgrade().map(|mux| mux.default_colors()).unwrap_or_default();
            let colors = Box::new(self.terminal_colors_locked(&term, defaults));
            if refresh_attach_colors {
                let live_colors = TerminalColors::from_pty_output(&term, defaults);
                self.attach_colors_pending.store(false, Ordering::Release);
                self.attach_colors_force_pending.store(false, Ordering::Release);
                *self.last_attach_colors.lock().unwrap() = Some(Box::new(live_colors));
            }
            if !replay.pending_sequence.is_empty() {
                self.cancel_taps_without_pending_support();
            }
            let frame = AttachFrame::ResizedWithColors {
                cols: next.cols,
                rows: next.rows,
                replay: replay.bytes.into(),
                kitty_image_aliases: replay.kitty_image_aliases,
                kitty_state: replay.kitty_state,
                colors,
                pending_sequence: replay.pending_sequence.into(),
            };
            if grid_changed {
                self.publish_resize_locked(&term, Some(frame));
            } else {
                // A cell-pixel-only change reflows nothing: snapshot viewers
                // keep their grid and generation.
                self.broadcast_attach_frame_to_replay_taps(frame);
            }
        } else if grid_changed {
            self.publish_resize_locked(&term, None);
        }
        // Geometry changes are terminal-stream transitions too. Publish the
        // revision before releasing the parser lock so screen snapshots have
        // one consistent boundary for text and dimensions.
        self.stream_progress.notify();
        Ok(true)
    }
}
