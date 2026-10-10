//! Output, resize and color transitions of [`HostedReader`]'s host stream.

use super::*;

impl HostedReader {
    /// Apply one `Output` or `OutputWithColors` transition to the mirror.
    pub(super) fn apply_output(
        &mut self,
        surface: &Arc<Surface>,
        pty: &PtySurface,
        transition: HostedTransition,
        journal_target: &mut Option<(Arc<Mux>, Arc<TerminalPublicId>)>,
        journal_update: &mut Option<TerminalJournalUpdateGuard<'_>>,
    ) -> Flow {
        let mux = self.mux.clone();
        if let Some(delay) = self.output_apply_delay {
            std::thread::sleep(delay);
        }
        let (output, colors) = match transition {
            HostedTransition::Output(output) => (output, None),
            HostedTransition::OutputWithColors { output, colors } => (output, Some(colors)),
            _ => unreachable!(),
        };
        let mut scroll_changed = None;
        let mut title_update = None;
        let terminal_notifications;
        let finished_commands;
        let defaults = mux.upgrade().map(|mux| mux.default_colors()).unwrap_or_default();
        let generation = {
            let mut term = pty.term.lock().unwrap();
            if let Some(update) = journal_update.as_mut()
                && !update.activate()
            {
                return Flow::Break;
            }
            let journal_enabled = journal_update.is_some();
            let before = terminal_scroll_position(&term);
            let normalized = term.vt_write_with_normalized(&output);
            terminal_notifications = pty.observe_terminal_output(&output);
            finished_commands = pty.observe_shell_marks(&mut term, || {
                mux.upgrade().is_some_and(|mux| mux.terminal_command_history_enabled())
            });
            let output = match normalized {
                Cow::Borrowed(_) => output,
                Cow::Owned(normalized) => normalized,
            };
            if let Some(colors) = colors.as_ref() {
                let delta = terminal_color_override_delta(&self.applied_color_overrides, colors);
                if !delta.is_empty() {
                    term.vt_write(&delta);
                }
                self.applied_color_overrides = colors.clone();
                self.applied_color_revision = term.color_revision();
                self.applied_cursor_activity = term.cursor_activity().ok();
            } else if self.smart_renderer {
                let color_revision = term.color_revision();
                let cursor_activity = term.cursor_activity().ok();
                if color_revision != self.applied_color_revision
                    || cursor_activity != self.applied_cursor_activity
                {
                    self.applied_color_overrides = term.color_overrides();
                    self.applied_color_revision = color_revision;
                    self.applied_cursor_activity = cursor_activity;
                }
            } else if !terminal_color_overrides_match_applied(
                term.color_overrides(),
                &self.applied_color_overrides,
            ) {
                // An unflagged Output that changed colors
                // violated the producer's iff contract.
                return Flow::Break;
            }
            pty.mouse_encoders.lock().unwrap().sync_from_terminal(&term);
            let after = terminal_scroll_position(&term);
            // The parser already contains the complete
            // coupled state before any attach observer can
            // see the Output or ColorsChanged callback.
            let journal_output = if colors.is_some() {
                let journal_output = journal_enabled.then(|| output.clone());
                pty.broadcast_attach_frame(AttachFrame::OutputWithColors {
                    output,
                    colors: Box::new(pty.terminal_colors_locked(&term, defaults)),
                });
                journal_output
            } else {
                pty.broadcast_attach_output(&output);
                journal_enabled.then_some(output)
            };
            if self.title_changed.swap(false, Ordering::Relaxed) {
                let title = term.title().unwrap_or_default();
                *pty.title.lock().unwrap() = title.clone();
                title_update = Some(title);
            }
            pty.record_directory(term.pwd());
            if before != after {
                scroll_changed = Some(after);
                broadcast_render_scroll_locked(pty, after);
            }
            // Advance the output watermark while the
            // parser lock is held. A screen snapshot
            // cannot then pair this text with an old
            // revision.
            pty.stream_progress.notify();
            (pty.render_generation.fetch_add(1, Ordering::AcqRel) + 1, journal_output)
        };
        let (generation, journal_output) = generation;
        if let (Some(journal_target), Some(journal_output)) =
            (journal_target.take(), journal_output)
        {
            pty.journal_output_if_open(journal_target, journal_output);
        }
        drop(journal_update.take());
        surface.publish_pending_directory();
        surface.publish_pending_progress();
        pty.stream_progress.notify();
        pty.request_frame(generation);
        if let Some(title) = title_update
            && let Some(mux) = mux.upgrade()
        {
            mux.emit_terminal_title(surface.id, title.into());
        }
        if let Some((offset, at_bottom)) = scroll_changed
            && let Some(mux) = mux.upgrade()
        {
            mux.emit_terminal_scroll(surface.id, offset, at_bottom);
        }
        if !terminal_notifications.is_empty()
            && let Some(mux) = mux.upgrade()
        {
            mux.post_terminal_notifications(surface.id, terminal_notifications);
        }
        if !finished_commands.is_empty()
            && let Some(mux) = mux.upgrade()
            && let Some(terminal) = surface.terminal_public_id()
        {
            mux.append_shell_commands(terminal.clone(), finished_commands);
        }
        Flow::Continue
    }
}
