//! Attach entry points on `Surface`: byte attach streams (with lifecycle) and
//! render attach streams.

use super::*;
use crate::panic_free::RecoverPoison;

impl Surface {
    /// Attach to a PTY surface: a VT replay plus a live byte stream.
    pub fn attach_stream(&self) -> ghostty_vt::Result<AttachStream> {
        self.attach_stream_with_lifecycle(AttachLifecycle::default())
    }

    pub(crate) fn attach_stream_with_lifecycle(
        &self,
        lifecycle: AttachLifecycle,
    ) -> ghostty_vt::Result<AttachStream> {
        self.attach_stream_with_history(lifecycle, None)
    }

    /// A byte attach whose replay keeps at most `max_history_rows` rows of
    /// history above the active area (`replay_history_rows`,
    /// `attach-replay-history-rows-v1`): the latest screen first, for a
    /// viewer that fetches older rows only when it needs them. `None`: the
    /// whole history, as before.
    pub(crate) fn attach_stream_with_history(
        &self,
        lifecycle: AttachLifecycle,
        max_history_rows: Option<u64>,
    ) -> ghostty_vt::Result<AttachStream> {
        self.attach_stream_with_window(lifecycle, max_history_rows.map(HistoryWindow::tail), false)
    }

    /// A byte attach whose replay holds the screen and the history `window`
    /// (`history_window`): a tail, or with a start
    /// (`replay_history_start`, `attach-replay-history-window-v1`) rows far
    /// above the screen without the rows between, so a reader far up in a
    /// long history gets its rows and not the whole scrollback. With
    /// `windowed_resizes` (the viewer declared `attach-replay-history-window-v1`,
    /// so it reads `history_rows_omitted` on `resized`), its
    /// later resize and resync replays keep a window of the same size; an
    /// older viewer keeps getting the whole history there.
    pub(crate) fn attach_stream_with_window(
        &self,
        lifecycle: AttachLifecycle,
        window: Option<HistoryWindow>,
        windowed_resizes: bool,
    ) -> ghostty_vt::Result<AttachStream> {
        let Some(pty) = self.as_pty() else {
            return Err(ghostty_vt::Error::InvalidValue);
        };
        let mut term = pty.term.lock().unwrap();
        let dead = pty.dead.load(Ordering::Acquire);
        let exited = dead
            && pty.host_connection_state.load(Ordering::Acquire)
                == TerminalHostConnectionState::Exited as u8;
        // An exited terminal has no live tap, but its final replay remains
        // useful. Other dead states can represent an incomplete host loss.
        if dead && !exited {
            return Err(ghostty_vt::Error::NoValue);
        }
        let (mut tap, stream) =
            AttachTap::pair(lifecycle.clone(), ATTACH_STREAM_CAPACITY, ATTACH_STREAM_MAX_BYTES);
        tap.history = window.filter(|_| windowed_resizes).map(HistoryWindow::after_reflow);
        // Snapshot and tap registration under the same terminal lock:
        // the reader thread cannot apply bytes between the two.
        #[cfg(test)]
        pty.vt_replay_builds.fetch_add(1, Ordering::AcqRel);
        // Byte mirrors render in their own libghostty with their own theme.
        // A palette-including replay would pin every one of the 256 entries
        // (and the default fg/bg) to this process's colors; the sparse
        // `colors` sidecar below carries only what the PTY authored.
        let (replay, history_rows_omitted, history_rows_skipped) =
            window_replay_locked(&mut term, window)?;
        let (cols, rows) = (term.cols(), term.rows());
        let defaults = pty.mux.upgrade().map(|mux| mux.default_colors()).unwrap_or_default();
        let colors = pty.terminal_colors_locked(&term, defaults);
        if exited || pty.dead.load(Ordering::Acquire) {
            drop(tap);
        } else {
            let mut taps = pty.taps.lock().unwrap();
            if taps.is_empty() {
                let live = TerminalColors::from_pty_output(&term, defaults);
                let mut last = pty.last_attach_colors.lock().recover_poison();
                // A color change while nobody was attached: a viewer that
                // resumes by offset must not skip it.
                if last.as_deref() != Some(&live) {
                    pty.snapshot_position.ring.bump_epoch();
                }
                *last = Some(Box::new(live));
            }
            taps.push(tap);
        }
        let stamp = pty.snapshot_position.ring.stamp();
        Ok(AttachStream {
            cols,
            rows,
            replay: replay.bytes.into(),
            kitty_image_aliases: replay.kitty_image_aliases,
            kitty_state: replay.kitty_state,
            colors,
            pending_sequence: replay.pending_sequence.into(),
            history_rows_omitted,
            history_rows_skipped,
            stream,
            lifecycle,
            stamp,
        })
    }

    /// `terminal-resume-v1`: the bytes after `offset` of the stream whose
    /// `generation` the viewer holds, and a live tap behind them, when that
    /// range is still held and nothing but bytes changed since; `None`: attach
    /// as today. `size` is the grid the viewer holds; another grid is a resize
    /// its replay must carry.
    pub(crate) fn attach_resume_stream(
        &self,
        lifecycle: AttachLifecycle,
        generation: &str,
        offset: u64,
        size: Option<(u16, u16)>,
    ) -> Option<ResumeAttach> {
        let held = resume_ring::StreamStamp::parse_generation(generation)?;
        let pty = self.as_pty()?;
        let term = pty.term.lock().recover_poison();
        if pty.dead.load(Ordering::Acquire) {
            return None;
        }
        if size.is_some_and(|size| size != (term.cols(), term.rows())) {
            return None;
        }
        let defaults = pty.mux.upgrade().map(|mux| mux.default_colors()).unwrap_or_default();
        let live_colors = TerminalColors::from_pty_output(&term, defaults);
        let mut taps = pty.taps.lock().recover_poison();
        // With no viewer attached nothing announced a color change since the
        // last one sent: compare it here.
        taps.retain(|tap| !tap.lifecycle.is_canceled());
        if taps.is_empty()
            && pty.last_attach_colors.lock().recover_poison().as_deref() != Some(&live_colors)
        {
            return None;
        }
        let (missing, stamp) = pty.snapshot_position.ring.missing_after(held, offset)?;
        let (tap, stream) =
            AttachTap::pair(lifecycle.clone(), ATTACH_STREAM_CAPACITY, ATTACH_STREAM_MAX_BYTES);
        taps.push(tap);
        let attach = AttachStream {
            cols: term.cols(),
            rows: term.rows(),
            replay: Arc::from([]),
            kitty_image_aliases: Vec::new(),
            kitty_state: KittyReplayState::disabled(),
            colors: live_colors,
            pending_sequence: Arc::from([]),
            history_rows_omitted: None,
            history_rows_skipped: None,
            stream,
            lifecycle,
            stamp,
        };
        Some(ResumeAttach { missing, attach })
    }

    /// Attach to the shared protocol-v7 render stream without consuming
    /// terminal damage a second time.
    pub fn attach_render_stream(&self) -> ghostty_vt::Result<RenderAttachStream> {
        let Some(pty) = self.as_pty() else {
            return Err(ghostty_vt::Error::InvalidValue);
        };
        let mut term = pty.term.lock().unwrap();
        let dead = pty.dead.load(Ordering::Acquire);
        let exited = dead
            && pty.host_connection_state.load(Ordering::Acquire)
                == TerminalHostConnectionState::Exited as u8;
        if dead && !exited {
            return Err(ghostty_vt::Error::NoValue);
        }
        let permit = if exited {
            None
        } else {
            Some(
                pty.mux
                    .upgrade()
                    .and_then(|mux| mux.claim_render_attachment())
                    .ok_or(ghostty_vt::Error::OutOfSpace)?,
            )
        };
        let generation = pty.render_generation.load(Ordering::Acquire);
        let _ = pty.build_frame_locked(&mut term, generation, false)?;
        let (tap, stream) = RenderTap::pair(&pty.render);
        let (initial, registered) = {
            let mut render = pty.render.lock().unwrap();
            let initial = if exited {
                render.final_attach_initial(&term)?
            } else {
                render.build_attach_initial(&term)?
            };
            // `render-state` carries no viewport position, and a client
            // starts at the live bottom. A viewport scrolled back when the
            // snapshot was taken is announced as the stream's first event,
            // under the same terminal lock, so no later move can land between
            // them (spec/render.md "Stream Ordering"). An exited terminal's
            // stream gets it too: the dropped tap still delivers it before the
            // stream ends.
            if let (offset, false) = terminal_scroll_position(&term) {
                tap.send(RenderAttachFrame::ScrollChanged { offset, at_bottom: false });
            }
            let registered = if exited || pty.dead.load(Ordering::Acquire) {
                drop(tap);
                false
            } else {
                render.taps.push(tap);
                true
            };
            (initial, registered)
        };
        let permit = if registered {
            permit
        } else {
            drop(permit);
            None
        };
        Ok(RenderAttachStream { initial, stream, _permit: permit })
    }
}

/// The replay of `window` over `term` under its lock, with the history rows
/// it leaves out above its first row and between it and the screen. `None`:
/// the whole history (bounded by `VT_REPLAY_MAX_BYTES`), as before.
pub(super) fn window_replay_locked(
    term: &mut Terminal,
    window: Option<HistoryWindow>,
) -> ghostty_vt::Result<(ghostty_vt::VtReplay, Option<u64>, Option<u64>)> {
    let Some(window) = window else {
        return Ok((
            term.vt_replay_bounded_theme_portable_with_aliases(VT_REPLAY_MAX_BYTES)?,
            None,
            None,
        ));
    };
    let tail_rows = match window.plan(u64::from(term.history_rows())) {
        WindowPlan::Tail { rows } => rows,
        WindowPlan::Gap { start, rows, skipped } => {
            match term.vt_replay_window_theme_portable_with_aliases(
                VT_REPLAY_MAX_BYTES,
                start,
                rows,
            )? {
                Some(gap) => {
                    debug_assert_eq!(
                        gap.history_rows_skipped, skipped,
                        "the plan's gap is the replay's"
                    );
                    return Ok((
                        gap.replay,
                        Some(gap.history_rows_omitted),
                        Some(gap.history_rows_skipped),
                    ));
                }
                // Images, an alternate screen or a waiting prompt clear: the
                // rows from the window's start down to the screen, bounded by
                // the byte budget like any replay.
                None => u64::from(term.history_rows()).saturating_sub(start),
            }
        }
    };
    let tail = term.vt_replay_tail_theme_portable_with_aliases(VT_REPLAY_MAX_BYTES, tail_rows)?;
    Ok((tail.replay, Some(tail.history_rows_omitted), None))
}
