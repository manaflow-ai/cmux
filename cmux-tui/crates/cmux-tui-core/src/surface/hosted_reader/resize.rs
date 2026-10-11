//! Geometry transitions of [`HostedReader`]'s host stream: a plain resize and
//! the authoritative replay that replaces the mirror's parser.

use super::*;

impl HostedReader {
    /// Apply one `Resized` transition: commit the host's geometry.
    pub(super) fn apply_resized(
        &mut self,
        surface: &Arc<Surface>,
        pty: &PtySurface,
        cols: u16,
        rows: u16,
        cell_pixels: Option<(u16, u16)>,
    ) -> Flow {
        let mux = self.mux.clone();
        let mut geometry = pty.geometry.lock().unwrap();
        let next_geometry = PtyGeometry {
            cols,
            rows,
            cell_width: cell_pixels.map(|pixels| pixels.0).unwrap_or(geometry.cell_width),
            cell_height: cell_pixels.map(|pixels| pixels.1).unwrap_or(geometry.cell_height),
        };
        let changed = match pty.commit_hosted_geometry(&mut geometry, next_geometry, false) {
            Ok(changed) => changed,
            Err(_) => return Flow::Break,
        };
        drop(geometry);
        if changed && let Some(mux) = mux.upgrade() {
            mux.emit(MuxEvent::SurfaceResized {
                surface: surface.id,
                cols,
                rows,
                reservation_id: None,
            });
        }
        Flow::Continue
    }

    /// Apply one `ResizedWithColors` transition: replace the mirror's parser
    /// with the host's replay and complete color state.
    #[allow(clippy::too_many_arguments)]
    pub(super) fn apply_resized_with_colors(
        &mut self,
        surface: &Arc<Surface>,
        pty: &PtySurface,
        (cols, rows): (u16, u16),
        cell_pixels: (u16, u16),
        replay: Vec<u8>,
        kitty_image_aliases: Vec<ghostty_vt::KittyImageAlias>,
        kitty_state: KittyReplayState,
        colors: TerminalColorOverrides,
    ) -> Flow {
        let mux = self.mux.clone();
        let mut geometry = pty.geometry.lock().unwrap();
        let next_geometry =
            PtyGeometry { cols, rows, cell_width: cell_pixels.0, cell_height: cell_pixels.1 };
        let defaults = mux.upgrade().map(|mux| mux.default_colors()).unwrap_or_default();
        let records = pty.program_status_records();
        let callbacks =
            hosted_terminal_callbacks(&self.pending_bells, self.title_changed.clone(), records);
        let Ok(mut replacement) = Terminal::new(cols, rows, self.scrollback, callbacks) else {
            return Flow::Break;
        };
        if replacement
            .resize(
                cols,
                rows,
                u32::from(next_geometry.cell_width),
                u32::from(next_geometry.cell_height),
            )
            .is_err()
        {
            return Flow::Break;
        }
        replacement.replace_default_colors(defaults.fg, defaults.bg, defaults.cursor);
        replacement.set_default_palette(&defaults.palette);
        replace_ghostty_cursor_defaults(&mut replacement, defaults);
        if replacement.apply_vt_replay_parts(&replay, &kitty_image_aliases, kitty_state).is_err() {
            return Flow::Break;
        }
        let delta = terminal_color_override_full_state(&colors);
        if !delta.is_empty() {
            replacement.vt_write(&delta);
        }
        self.title_changed.store(false, Ordering::Relaxed);
        let title = replacement.title().unwrap_or_default();
        let pwd = replacement.pwd();
        let mut scroll_changed = None;
        let generation = pty.with_terminal_stream_update(|term| {
            let before = terminal_scroll_position(term);
            *term = replacement;
            pty.mouse_encoders.lock().unwrap().sync_from_terminal(term);
            *geometry = next_geometry;
            pty.journal_geometry(next_geometry);
            *pty.title.lock().unwrap() = title.clone();
            pty.record_directory(pwd);
            *pty.kitty_graphics_limits.lock().unwrap() = kitty_state.limits;
            self.applied_color_overrides = colors;
            self.applied_color_revision = term.color_revision();
            self.applied_cursor_activity = term.cursor_activity().ok();
            let after = terminal_scroll_position(term);
            if before != after {
                scroll_changed = Some(after);
                broadcast_render_scroll_locked(pty, after);
            }
            // Both attach notifications are queued only
            // after the authoritative replay and complete
            // color state have replaced the old parser.
            pty.broadcast_attach_frame(AttachFrame::ResizedWithColors {
                cols,
                rows,
                replay: replay.into(),
                kitty_image_aliases,
                kitty_state,
                colors: Box::new(pty.terminal_colors_locked(term, defaults)),
                // Terminal hosts replay only at a
                // parser boundary.
                pending_sequence: Arc::from([]),
            });
            pty.render_generation.fetch_add(1, Ordering::AcqRel) + 1
        });
        drop(geometry);
        surface.publish_pending_directory();
        surface.publish_pending_progress();
        pty.stream_progress.notify();
        pty.request_frame(generation);
        if let Some(mux) = mux.upgrade() {
            mux.emit_terminal_title(surface.id, title.into());
            mux.emit_terminal_resized(surface.id, cols, rows, None);
            if let Some((offset, at_bottom)) = scroll_changed {
                mux.emit_terminal_scroll(surface.id, offset, at_bottom);
            }
        }
        Flow::Continue
    }
}
