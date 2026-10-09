//! Terminal access on `Surface`: locked terminal access, Kitty graphics limits,
//! stream revisions, screen snapshots and stream-change subscriptions.

use super::*;

impl Surface {
    /// Run `f` with exclusive access to the terminal state.
    ///
    /// Browser-aware code should call [`Surface::kind`] first. This
    /// method is kept for existing PTY call sites. Access through this
    /// method is not terminal-stream progress; the local and hosted PTY
    /// readers signal progress only after applying actual output bytes.
    pub fn with_terminal<R>(&self, f: impl FnOnce(&mut Terminal) -> R) -> Option<R> {
        let pty = self.as_pty()?;
        let mut term = pty.term.lock().unwrap();
        let result = f(&mut term);
        pty.mouse_encoders.lock().unwrap().sync_from_terminal(&term);
        Some(result)
    }

    pub(super) fn configure_terminal_kitty_graphics_limits(
        terminal: &mut Terminal,
        limits: KittyGraphicsLimits,
    ) -> anyhow::Result<bool> {
        terminal.set_kitty_graphics_limits(limits).map_err(Into::into)
    }

    #[cfg_attr(not(test), allow(dead_code))]
    pub(crate) fn set_kitty_graphics_limits(
        &self,
        bytes: u64,
        inflight_bytes: u64,
        images: u64,
        placements: u64,
    ) -> anyhow::Result<()> {
        let requested =
            KittyGraphicsLimits { image_bytes: bytes, inflight_bytes, images, placements };
        self.set_kitty_graphics_limits_until(
            requested,
            Instant::now() + crate::terminal_host_runtime::CONTROL_RESPONSE_TIMEOUT,
        )
    }

    pub(crate) fn set_kitty_graphics_limits_until(
        &self,
        requested: KittyGraphicsLimits,
        deadline: Instant,
    ) -> anyhow::Result<()> {
        let Some(pty) = self.as_pty() else {
            return Ok(());
        };
        let requested = requested
            .validate()
            .map_err(|_| anyhow::anyhow!("Kitty graphics limits are out of range"))?;
        #[cfg(unix)]
        let next = {
            let runtime = pty.runtime.lock().unwrap();
            if let PtyRuntime::Hosted(host) = &*runtime {
                if *pty.kitty_graphics_limits.lock().unwrap() == requested {
                    return Ok(());
                }
                if host.send_kitty_graphics_limits_until(requested, deadline)? {
                    // The host committed them; a smart host's resync reopens the
                    // mirror later, so a repeat request compares against this.
                    *pty.kitty_graphics_limits.lock().unwrap() = requested;
                    return Ok(());
                }
                // Older hosts cannot carry Kitty sidecar state. Keep the
                // disposable mirror disabled so it cannot silently diverge.
                KittyGraphicsLimits::disabled()
            } else {
                requested
            }
        };
        #[cfg(not(unix))]
        let next = requested;
        let graphics_changed = {
            let mut term = pty.term.lock().unwrap();
            let mut limits = pty.kitty_graphics_limits.lock().unwrap();
            if *limits == next {
                return Ok(());
            }
            let graphics_changed = Self::configure_terminal_kitty_graphics_limits(&mut term, next)?;
            *limits = next;
            pty.resynchronize_attach_taps_locked(&mut term);
            if graphics_changed {
                let mut render = pty.render.lock().unwrap();
                render.state.clear_kitty_graphics_cache();
                render.latest = None;
                render.initial_graphics = None;
                render.final_initial = None;
            }
            graphics_changed
        };
        if !graphics_changed {
            return Ok(());
        }
        let generation = pty.render_generation.fetch_add(1, Ordering::AcqRel) + 1;
        pty.request_frame(generation);
        Ok(())
    }

    /// Return the coalesced revision advanced after terminal output or another
    /// viewport-text transition is applied. Callers can snapshot terminal
    /// state after reading this value, then wait on the same revision without
    /// losing an intervening update.
    pub(crate) fn terminal_stream_revision(&self) -> ghostty_vt::Result<u64> {
        let Some(pty) = self.as_pty() else {
            return Err(ghostty_vt::Error::InvalidValue);
        };
        Ok(pty.stream_progress.revision())
    }

    /// Capture the viewport, generic terminal metadata, and stream revision
    /// while the parser lock is held. This is the only screen-read path that
    /// can safely use the revision as a scheduling watermark.
    pub(crate) fn terminal_screen_snapshot(&self) -> anyhow::Result<TerminalScreenSnapshot> {
        let Some(pty) = self.as_pty() else {
            anyhow::bail!("browser surface does not have a VT terminal");
        };
        let mut term = pty.term.lock().unwrap();
        let text = term.viewport_text()?;
        let (cursor_col, cursor_row) = term.cursor_position().unwrap_or((0, 0));
        let cursor_visible = term.mode(25, false);
        // Match the parser's lock order, term -> metadata -> stream progress.
        // The revision is advanced before the terminal lock is released.
        let osc_progress = pty.terminal_osc_progress();
        let revision = pty.stream_progress.revision();
        Ok(TerminalScreenSnapshot {
            text,
            cols: term.cols(),
            rows: term.rows(),
            cursor_col,
            cursor_row,
            cursor_visible,
            revision,
            osc_progress,
        })
    }

    pub(crate) fn subscribe_terminal_stream_change(
        &self,
    ) -> ghostty_vt::Result<TerminalStreamSubscription<'_>> {
        let Some(pty) = self.as_pty() else {
            return Err(ghostty_vt::Error::InvalidValue);
        };
        Ok(pty.stream_progress.subscribe())
    }

    /// Wait until PTY output advances beyond `observed`, or until `deadline`.
    /// Unlike an attach stream, this wakeup is coalesced and cannot overflow.
    pub(crate) fn wait_for_terminal_stream_change(
        &self,
        observed: u64,
        deadline: Option<Instant>,
    ) -> ghostty_vt::Result<Option<u64>> {
        let Some(pty) = self.as_pty() else {
            return Err(ghostty_vt::Error::InvalidValue);
        };
        Ok(pty.stream_progress.wait_for_change_until(observed, deadline))
    }

    #[cfg(test)]
    pub(crate) fn apply_stream_output_for_test(&self, bytes: &[u8]) -> Option<()> {
        let pty = self.as_pty()?;
        let mut term = pty.term.lock().unwrap();
        term.vt_write(bytes);
        let _ = pty.observe_terminal_output(bytes);
        pty.mouse_encoders.lock().unwrap().sync_from_terminal(&term);
        pty.stream_progress.notify();
        Some(())
    }

    /// Apply PTY bytes the way the local reader does: parse them under the
    /// terminal lock and publish the normalized bytes to byte attachments.
    #[cfg(test)]
    pub(crate) fn apply_local_pty_output_for_test(&self, bytes: &[u8]) -> Option<()> {
        let pty = self.as_pty()?;
        let mut term = pty.term.lock().unwrap();
        let normalized = term.vt_write_with_normalized(bytes).into_owned();
        pty.broadcast_attach_output(&normalized);
        pty.stream_progress.notify();
        Some(())
    }

    #[cfg(test)]
    pub(crate) fn terminal_stream_waiter_count_for_test(&self) -> Option<usize> {
        Some(self.as_pty()?.stream_progress.waiter_count())
    }

    #[cfg(test)]
    pub(crate) fn terminal_stream_subscription_count_for_test(&self) -> Option<u64> {
        Some(self.as_pty()?.stream_progress.resource_subscription_count())
    }

    pub fn try_with_terminal<R>(&self, f: impl FnOnce(&mut Terminal) -> R) -> anyhow::Result<R> {
        let Some(pty) = self.as_pty() else {
            anyhow::bail!("browser surface does not have a VT terminal");
        };
        Ok(f(&mut pty.term.lock().unwrap()))
    }
}
