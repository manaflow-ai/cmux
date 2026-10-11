//! Render reads on `Surface`: default colors, render-state snapshots, shared
//! and per-view render frames, and pointer semantics probes.

use super::*;

impl Surface {
    pub fn set_default_colors(&self, colors: DefaultColors) {
        if let Some(pty) = self.as_pty() {
            #[cfg(unix)]
            if let PtyRuntime::Hosted(host) = &*pty.runtime.lock().unwrap() {
                // The local mirror updates immediately below. A v2 durable
                // host also receives the same complete defaults so later
                // output, resize snapshots, and reconnects cannot restore the
                // launch-time theme. Legacy hosts are feature-gated by record.
                let _ = host.send_default_colors(colors);
            }
            let mut term = pty.term.lock().unwrap();
            term.replace_default_colors(colors.fg, colors.bg, colors.cursor);
            term.set_default_palette(&colors.palette);
            replace_ghostty_cursor_defaults(&mut term, colors);
            let live_colors = TerminalColors::from_pty_output(&term, colors);
            let colors = pty.terminal_colors_locked(&term, colors);
            pty.attach_colors_pending.store(false, Ordering::Release);
            pty.attach_colors_force_pending.store(false, Ordering::Release);
            *pty.last_attach_colors.lock().unwrap() = Some(Box::new(live_colors));
            pty.broadcast_attach_frame(AttachFrame::ColorsChanged(Arc::new(colors)));
            let generation = pty.render_generation.fetch_add(1, Ordering::AcqRel) + 1;
            let _ = pty.build_frame_locked(&mut term, generation, false);
            pty.dirty.store(true, Ordering::Release);
        }
    }

    /// Snapshot the terminal into `rs` (holds the terminal lock only for
    /// the duration of the update).
    pub fn snapshot(&self, rs: &mut RenderState) -> ghostty_vt::Result<()> {
        let Some(pty) = self.as_pty() else {
            return Err(ghostty_vt::Error::InvalidValue);
        };
        rs.update(&mut pty.term.lock().unwrap())
    }

    /// Latest immutable frame from the surface's shared render producer.
    pub fn render_frame(&self) -> ghostty_vt::Result<Arc<SurfaceRenderFrame>> {
        let Some(pty) = self.as_pty() else {
            return Err(ghostty_vt::Error::InvalidValue);
        };
        let mut term = pty.term.lock().unwrap();
        let generation = pty.render_generation.load(Ordering::Acquire);
        let _ = pty.build_frame_locked(&mut term, generation, false)?;
        pty.render.lock().unwrap().latest.clone().ok_or(ghostty_vt::Error::NoValue)
    }

    /// Render this placement's frontend-local viewport without changing the
    /// session compatibility viewport used by backend render projections.
    pub fn render_view_frame(
        &self,
        render: &mut RenderState,
    ) -> ghostty_vt::Result<Arc<SurfaceRenderFrame>> {
        let Some(pty) = self.as_pty() else {
            return Err(ghostty_vt::Error::InvalidValue);
        };
        let mut term = pty.term.lock().unwrap();
        let original_offset = term.scrollbar().map(|scrollbar| scrollbar.offset);
        let view_offset = pty.view_scrollbar_locked(&mut term).map(|scrollbar| scrollbar.offset);
        let applied =
            view_offset.is_none_or(|offset| set_terminal_scroll_offset(&mut term, offset));
        let result = if applied {
            (|| {
                render.update(&mut term)?;
                let palette_colors = std::array::from_fn(|index| render.palette_color(index as u8));
                let palette_overridden =
                    std::array::from_fn(|index| render.palette_overridden(index as u8));
                Ok(Arc::new(SurfaceRenderFrame {
                    frame: render.build_frame()?,
                    content_generation: pty.render_generation.load(Ordering::Acquire),
                    scrollback_rows: term.history_rows(),
                    history_epoch: term.history_epoch(),
                    pointer_semantics: term.pointer_semantic_snapshot(),
                    palette_colors,
                    palette_overridden,
                }))
            })()
        } else {
            Err(ghostty_vt::Error::NoValue)
        };
        let restored =
            original_offset.is_none_or(|offset| set_terminal_scroll_offset(&mut term, offset));
        if !restored {
            // Cleanup errors take precedence because a successful-looking
            // frame would conceal mutation of the shared compatibility view.
            return Err(ghostty_vt::Error::NoValue);
        }
        result
    }

    /// Read current pointer-routing state without waiting behind terminal parsing.
    /// Contention is distinct so discrete input can be retained for replay.
    pub fn try_pointer_semantics(&self) -> Option<PointerSemanticProbe> {
        let pty = self.as_pty()?;
        match pty.term.try_lock() {
            Ok(term) => Some(PointerSemanticProbe::Ready(term.pointer_semantic_snapshot())),
            Err(TryLockError::Poisoned(error)) => {
                Some(PointerSemanticProbe::Ready(error.into_inner().pointer_semantic_snapshot()))
            }
            Err(TryLockError::WouldBlock) => Some(PointerSemanticProbe::Contended),
        }
    }

    /// Read terminal pointer semantics and content generation without waiting
    /// behind terminal parsing. Returns `None` for non-PTY surfaces.
    pub fn try_pointer_snapshot(&self) -> Option<PointerSnapshotProbe> {
        let pty = self.as_pty()?;
        match pty.term.try_lock() {
            Ok(term) => Some(PointerSnapshotProbe::Ready(TerminalPointerSnapshot {
                semantics: term.pointer_semantic_snapshot(),
                content_generation: pty.render_generation.load(Ordering::Acquire),
            })),
            Err(TryLockError::Poisoned(error)) => {
                Some(PointerSnapshotProbe::Ready(TerminalPointerSnapshot {
                    semantics: error.into_inner().pointer_semantic_snapshot(),
                    content_generation: pty.render_generation.load(Ordering::Acquire),
                }))
            }
            Err(TryLockError::WouldBlock) => Some(PointerSnapshotProbe::Contended),
        }
    }
}
