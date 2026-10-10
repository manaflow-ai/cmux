//! Reconnect of [`HostedReader`] after a lost or resynced host stream: adopt
//! the live host again (or rehost a dead one) and install the replacement
//! attachment, parser and geometry.

use super::*;

impl HostedReader {
    /// Retry until a replacement attachment is installed; returns its reader,
    /// or `None` when the reader thread must stop.
    pub(super) fn reconnect(
        &mut self,
        surface: &Arc<Surface>,
        pty: &PtySurface,
        identity: crate::terminal_host_runtime::TerminalHostIdentity,
    ) -> Option<UnixStream> {
        let mux = self.mux.clone();
        let mut retry = TerminalHostReconnectBackoff::default();
        loop {
            if pty.owner_detaching.load(Ordering::Acquire) {
                return None;
            }
            let discovery = {
                let runtime = pty.runtime.lock().unwrap();
                match &*runtime {
                    PtyRuntime::Hosted(host) => Some(host.discovery_record()),
                    PtyRuntime::ExitedHosted | PtyRuntime::Local { .. } => None,
                }
            };
            let (record, record_path) = discovery?;
            let replaced = match crate::terminal_host_runtime::terminal_host_record_liveness(
                &record_path,
                &record,
            ) {
                Ok(crate::terminal_host_runtime::TerminalHostLiveness::Dead) => {
                    match rehost::after_host_death(
                        surface,
                        &mux,
                        &identity,
                        &record,
                        &record_path,
                        self.scrollback,
                    ) {
                        rehost::DeadHost::Replaced(attachment) => Some(*attachment),
                        rehost::DeadHost::Retry if retry.wait_or_fail(pty) => continue,
                        rehost::DeadHost::Retry | rehost::DeadHost::Stop => return None,
                    }
                }
                Ok(crate::terminal_host_runtime::TerminalHostLiveness::Live)
                | Ok(crate::terminal_host_runtime::TerminalHostLiveness::Indeterminate)
                | Err(_) => None,
            };

            let reconnect_mux = mux.upgrade()?;
            let Ok(kitty_limits) = reconnect_mux.kitty_image_limits_for_reconnect(surface) else {
                return None;
            };
            let replacement = match replaced.map_or_else(
                || {
                    crate::terminal_host_runtime::adopt_terminal_host_with_kitty_limits(
                        record,
                        record_path,
                        kitty_limits,
                    )
                },
                Ok,
            ) {
                Ok(replacement) if replacement.identity() == identity => replacement,
                Ok(_) | Err(_) => {
                    if !retry.wait_or_fail(pty) {
                        return None;
                    }
                    continue;
                }
            };
            let replacement_protocol_version = replacement.protocol_version();
            let replacement_smart_renderer = replacement.is_smart_renderer();
            let replacement_snapshot = replacement.snapshot.clone();
            let replacement_control_responses = replacement.control_responses();
            let installed = {
                let mut runtime = pty.runtime.lock().unwrap();
                if pty.owner_detaching.load(Ordering::Acquire) {
                    replacement.disconnect();
                    return None;
                }
                let viewer_size = match &*runtime {
                    PtyRuntime::Hosted(current) if current.identity() == identity => {
                        current.viewer_size()
                    }
                    PtyRuntime::Hosted(_) | PtyRuntime::ExitedHosted | PtyRuntime::Local { .. } => {
                        return None;
                    }
                };
                let defaults = mux.upgrade().map(|mux| mux.default_colors()).unwrap_or_default();
                if (if let Some((cols, rows)) = viewer_size {
                    replacement.send_viewer_size(cols, rows).map(|_| ())
                } else {
                    Ok(())
                })
                .and_then(|()| replacement.send_default_colors(defaults).map(|_| ()))
                .is_err()
                {
                    false
                } else {
                    // Keep desired-lease capture, replay, and the
                    // runtime swap atomic with respect to mux
                    // resize/release operations.
                    let supports_clear_history = replacement.supports_clear_history();
                    *runtime = PtyRuntime::Hosted(Box::new(replacement));
                    pty.supports_clear_history_key_fallback
                        .store(supports_clear_history, Ordering::Release);
                    true
                }
            };
            if !installed {
                if !retry.wait_or_fail(pty) {
                    return None;
                }
                continue;
            }
            Surface::install_deferred_cell_pixel_handler(surface, &replacement_control_responses);
            Surface::install_clipboard_read_handler(surface);

            let replacement_reader = {
                let mut runtime = pty.runtime.lock().unwrap();
                let PtyRuntime::Hosted(replacement) = &mut *runtime else { return None };
                replacement.take_reader().ok()
            };
            let Some(replacement_reader) = replacement_reader else {
                if !retry.wait_or_fail(pty) {
                    return None;
                }
                continue;
            };

            let defaults = mux.upgrade().map(|mux| mux.default_colors()).unwrap_or_default();
            let mut geometry = pty.geometry.lock().unwrap();
            let next_geometry = PtyGeometry {
                cols: replacement_snapshot.cols,
                rows: replacement_snapshot.rows,
                cell_width: replacement_snapshot.cell_pixels.0,
                cell_height: replacement_snapshot.cell_pixels.1,
            };
            let records = pty.program_status_records();
            let callbacks = hosted_terminal_callbacks(
                &self.pending_bells,
                self.title_changed.clone(),
                records.clone(),
            );
            let Ok(mut replacement_term) = Terminal::new(
                replacement_snapshot.cols,
                replacement_snapshot.rows,
                self.scrollback,
                callbacks,
            ) else {
                if !wait_for_reconnect_after_geometry_failure(&mut retry, pty, geometry) {
                    return None;
                }
                continue;
            };
            if replacement_term
                .resize(
                    next_geometry.cols,
                    next_geometry.rows,
                    u32::from(next_geometry.cell_width),
                    u32::from(next_geometry.cell_height),
                )
                .is_err()
            {
                if !wait_for_reconnect_after_geometry_failure(&mut retry, pty, geometry) {
                    return None;
                }
                continue;
            }
            replacement_term.replace_default_colors(defaults.fg, defaults.bg, defaults.cursor);
            replacement_term.set_default_palette(&defaults.palette);
            replace_ghostty_cursor_defaults(&mut replacement_term, defaults);
            if replacement_term
                .apply_vt_replay_parts(
                    &replacement_snapshot.replay,
                    &replacement_snapshot.kitty_image_aliases,
                    replacement_snapshot.kitty_state,
                )
                .is_err()
            {
                if !wait_for_reconnect_after_geometry_failure(&mut retry, pty, geometry) {
                    return None;
                }
                continue;
            }
            let color_delta = terminal_color_override_full_state(&replacement_snapshot.colors);
            if !color_delta.is_empty() {
                replacement_term.vt_write(&color_delta);
            }
            let mut replacement_metadata =
                crate::terminal_metadata::TerminalMetadata::with_program_status(records);
            if !replacement_metadata.set_osc_progress(&replacement_snapshot.osc_progress) {
                if !retry.wait_or_fail(pty) {
                    return None;
                }
                continue;
            }
            self.title_changed.store(false, Ordering::Relaxed);
            let title = replacement_term.title().unwrap_or_default();
            let pwd = replacement_term.pwd();
            let generation = {
                let mut term = pty.term.lock().unwrap();
                **term = replacement_term;
                *pty.terminal_metadata.lock().unwrap() = replacement_metadata;
                pty.mouse_encoders.lock().unwrap().sync_from_terminal(&term);
                *geometry = next_geometry;
                *pty.title.lock().unwrap() = title.clone();
                pty.record_directory(pwd);
                *pty.kitty_graphics_limits.lock().unwrap() =
                    replacement_snapshot.kitty_state.limits;
                self.applied_color_overrides = replacement_snapshot.colors;
                self.applied_color_revision = term.color_revision();
                self.applied_cursor_activity = term.cursor_activity().ok();
                pty.broadcast_attach_frame(AttachFrame::ResizedWithColors {
                    cols: replacement_snapshot.cols,
                    rows: replacement_snapshot.rows,
                    replay: replacement_snapshot.replay.into(),
                    kitty_image_aliases: replacement_snapshot.kitty_image_aliases,
                    kitty_state: replacement_snapshot.kitty_state,
                    colors: Box::new(pty.terminal_colors_locked(&term, defaults)),
                    pending_sequence: Arc::from([]),
                });
                pty.stream_progress.notify_reconnect();
                pty.render_generation.fetch_add(1, Ordering::AcqRel) + 1
            };
            drop(geometry);
            pty.request_frame(generation);
            if !reconnect_mux.terminal_host_reconnected(
                surface.id,
                &identity,
                replacement_snapshot.kitty_state.limits,
            ) {
                replacement_control_responses.fail_all();
                if let PtyRuntime::Hosted(host) = &*pty.runtime.lock().unwrap()
                    && host.identity() == identity
                {
                    host.disconnect();
                }
                pty.host_connection_state
                    .store(TerminalHostConnectionState::Reconnecting as u8, Ordering::Release);
                if !reconnect_mux.terminal_host_connection_lost(surface.id, &identity) {
                    pty.host_connection_state
                        .store(TerminalHostConnectionState::Failed as u8, Ordering::Release);
                    return None;
                }
                if !retry.wait_or_fail(pty) {
                    return None;
                }
                continue;
            }
            // Bytes the host wrote while no daemon tap existed are
            // not in the journal: record that gap before any new
            // output (surface/journal_reconnect.rs).
            pty.journal_host_reconnect_gap(&reconnect_mux);
            reconnect_mux
                .reconcile_deferred_cell_pixel_ack(surface.id, replacement_snapshot.cell_pixels);
            surface.publish_pending_directory();
            surface.publish_pending_progress();
            reconnect_mux.emit_terminal_title(pty.event_surface_id, title.into());
            reconnect_mux.emit_terminal_resized(
                pty.event_surface_id,
                replacement_snapshot.cols,
                replacement_snapshot.rows,
                None,
            );
            self.control_responses = replacement_control_responses;
            self.sequence_boundary = replacement_snapshot.sequence_boundary;
            self.protocol_version = replacement_protocol_version;
            self.smart_renderer = replacement_smart_renderer;
            pty.host_connection_state
                .store(TerminalHostConnectionState::Connected as u8, Ordering::Release);
            self.connected_at = Some(Instant::now());
            return Some(replacement_reader);
        }
    }
}
