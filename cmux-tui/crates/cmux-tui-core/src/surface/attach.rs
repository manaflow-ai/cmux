//! Attach entry points on `Surface`: byte attach streams (with lifecycle) and
//! render attach streams.

use super::*;

impl Surface {
    /// Attach to a PTY surface: a VT replay plus a live byte stream.
    pub fn attach_stream(&self) -> ghostty_vt::Result<AttachStream> {
        self.attach_stream_with_lifecycle(AttachLifecycle::default())
    }

    pub(crate) fn attach_stream_with_lifecycle(
        &self,
        lifecycle: AttachLifecycle,
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
        let (tap, stream) =
            AttachTap::pair(lifecycle.clone(), ATTACH_STREAM_CAPACITY, ATTACH_STREAM_MAX_BYTES);
        // Snapshot and tap registration under the same terminal lock:
        // the reader thread cannot apply bytes between the two.
        #[cfg(test)]
        pty.vt_replay_builds.fetch_add(1, Ordering::AcqRel);
        // Byte mirrors render in their own libghostty with their own theme.
        // A palette-including replay would pin every one of the 256 entries
        // (and the default fg/bg) to this process's colors; the sparse
        // `colors` sidecar below carries only what the PTY authored.
        let replay = term.vt_replay_bounded_theme_portable_with_aliases(VT_REPLAY_MAX_BYTES)?;
        let (cols, rows) = (term.cols(), term.rows());
        let defaults = pty.mux.upgrade().map(|mux| mux.default_colors()).unwrap_or_default();
        let colors = pty.terminal_colors_locked(&term, defaults);
        if exited || pty.dead.load(Ordering::Acquire) {
            drop(tap);
        } else {
            let mut taps = pty.taps.lock().unwrap();
            if taps.is_empty() {
                *pty.last_attach_colors.lock().unwrap() =
                    Some(Box::new(TerminalColors::from_pty_output(&term, defaults)));
            }
            taps.push(tap);
        }
        Ok(AttachStream {
            cols,
            rows,
            replay: replay.bytes.into(),
            kitty_image_aliases: replay.kitty_image_aliases,
            kitty_state: replay.kitty_state,
            colors,
            pending_sequence: replay.pending_sequence.into(),
            stream,
            lifecycle,
        })
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
