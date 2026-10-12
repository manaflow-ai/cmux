//! Viewer sizes and parser resizes of a terminal host.

use super::*;

impl HostShared {
    pub(crate) fn set_viewer_size(
        &self,
        client: u64,
        cols: u16,
        rows: u16,
        acknowledge_with_replay: bool,
        targeted_ack: Option<(u64, &HostTap)>,
    ) -> anyhow::Result<bool> {
        let (cols, rows) = normalize_terminal_geometry(cols, rows)?;
        let mut acknowledgement_queued = true;
        mutate_viewer_sizes(
            &self.viewer_sizes,
            |viewer_sizes| {
                viewer_sizes.sizes.insert(client, (cols, rows));
            },
            |desired| {
                acknowledgement_queued =
                    self.apply_viewer_minimum(desired, acknowledge_with_replay, targeted_ack)?;
                Ok(())
            },
        )?;
        Ok(acknowledgement_queued)
    }

    pub(crate) fn remove_viewer_size(&self, client: u64) {
        let _ = mutate_viewer_sizes(
            &self.viewer_sizes,
            |viewer_sizes| viewer_sizes.release(client),
            |desired| self.apply_viewer_minimum(desired, false, None).map(|_| ()),
        );
    }

    pub(crate) fn apply_viewer_minimum(
        &self,
        desired: Option<(u16, u16)>,
        acknowledge_with_replay: bool,
        targeted_ack: Option<(u64, &HostTap)>,
    ) -> anyhow::Result<bool> {
        let Some((cols, rows)) = desired else { return Ok(true) };
        let (cols, rows) = normalize_terminal_geometry(cols, rows)?;
        // Geometry transitions share one source order. Keep this ahead of
        // size and cell_pixels, matching the other geometry mutation
        // paths, so concurrent viewer and cell-metric updates cannot
        // acquire the locks in opposite orders.
        let _source_order = self.source_order_lock.lock().unwrap();
        let mut size = self.size.lock().unwrap();
        let cell_pixels = self.cell_pixels.lock().unwrap();
        let changed = *size != (cols, rows);
        if !changed && !acknowledge_with_replay {
            let targeted = targeted_ack.map(|(request_id, tap)| {
                let mut frame =
                    Frame::new(MessageKind::ResizeAck, encode_resize_ack(cols, rows, false));
                frame.request_id = request_id;
                (tap, frame)
            });
            return Ok(publish_host_frames_and_targeted(
                &self.broadcast_lock,
                &self.sequence,
                &self.taps,
                std::iter::empty(),
                targeted,
            ));
        }
        // Output and geometry share one source order. Publish a compact
        // smart-renderer marker before the authoritative parser applies
        // it, then wait for the FIFO parser worker before admitting a
        // later source byte. Legacy clients keep their replay-bearing
        // Resized transition on the parser side of the same barrier.
        let source_cursor = changed.then(|| {
            let mut payload = Vec::with_capacity(4);
            payload.extend_from_slice(&cols.to_le_bytes());
            payload.extend_from_slice(&rows.to_le_bytes());
            self.smart.publish(Frame::new(MessageKind::Resized, payload))
        });
        let (response_sender, response_receiver) = sync_channel(1);
        let command = ParserCommand::Resize {
            cols,
            rows,
            cell_pixels: *cell_pixels,
            source_cursor,
            acknowledge_with_replay,
            targeted_ack: targeted_ack.map(|(request_id, tap)| (request_id, tap.clone())),
            response: response_sender,
        };
        if self.parser_commands.send(command).is_err() {
            self.smart.close_failed_transition(source_cursor);
            anyhow::bail!("terminal parser worker stopped");
        }
        let result = match response_receiver.recv() {
            Ok(result) => result,
            Err(_) => {
                self.smart.close_failed_transition(source_cursor);
                anyhow::bail!("terminal parser worker stopped");
            }
        };
        *size = result.applied;
        match result.acknowledgement_queued {
            Ok(acknowledgement_queued) => {
                debug_assert_eq!(result.changed, changed);
                Ok(acknowledgement_queued)
            }
            Err(error) => {
                self.smart.close_failed_transition(source_cursor);
                anyhow::bail!(error)
            }
        }
    }

    pub(crate) fn apply_parser_resize(
        &self,
        cols: u16,
        rows: u16,
        source_cursor: Option<u64>,
        acknowledge_with_replay: bool,
        targeted_ack: Option<(u64, HostTap)>,
        cell_pixels: (u16, u16),
    ) -> ParserResizeResult {
        let mut term = self.term.lock().unwrap();
        let previous = (term.cols(), term.rows());
        let acknowledgement_queued = (|| -> anyhow::Result<bool> {
            let requested_change = previous != (cols, rows);
            let master = self.master.lock().unwrap();
            let resize_sizes = if requested_change {
                Some((
                    pty_size(previous.0, previous.1, cell_pixels)?,
                    pty_size(cols, rows, cell_pixels)?,
                ))
            } else {
                None
            };
            let targeted = targeted_ack.as_ref().map(|(request_id, tap)| {
                let mut frame = Frame::new(
                    MessageKind::ResizeAck,
                    encode_resize_ack(cols, rows, requested_change),
                );
                frame.request_id = *request_id;
                (tap, frame)
            });
            let has_legacy_clients = !self.taps.lock().unwrap().is_empty();
            let publish_legacy_resize =
                acknowledge_with_replay || (requested_change && has_legacy_clients);
            let replay_is_safe = term.vt_stream_is_ground();
            if let Some((previous_size, next_size)) = resize_sizes {
                if publish_legacy_resize && replay_is_safe {
                    term.preflight_vt_replay_bounded(crate::surface::VT_REPLAY_MAX_BYTES).context(
                        "could not preflight terminal-host resize replay; geometry unchanged",
                    )?;
                }
                master.resize(next_size)?;
                if let Err(error) =
                    term.resize(cols, rows, u32::from(cell_pixels.0), u32::from(cell_pixels.1))
                {
                    let _ = master.resize(previous_size);
                    return Err(error.into());
                }
            }
            let acknowledgement_queued = if publish_legacy_resize && !replay_is_safe {
                // A replay cannot serialize an in-progress decoder or escape
                // sequence. Force compatibility clients to take a new safe
                // snapshot instead of orphaning the sequence's later bytes.
                publish_host_frames_and_targeted(
                    &self.broadcast_lock,
                    &self.sequence,
                    &self.taps,
                    [Frame::new(MessageKind::ResyncRequired, Vec::new())],
                    targeted,
                )
            } else if publish_legacy_resize {
                let replay = match term.vt_replay_bounded_theme_portable_with_aliases(
                    crate::surface::VT_REPLAY_MAX_BYTES,
                ) {
                    Ok(replay) => Some(replay),
                    Err(_) if requested_change => {
                        // Preflight ruled out persistent budget failure. Keep
                        // the canonical resize and make compatibility clients
                        // reconnect instead of attempting a destructive
                        // inverse resize after Ghostty has reflowed state.
                        let mut taps = self.taps.lock().unwrap();
                        for tap in taps.values() {
                            tap.close();
                        }
                        taps.clear();
                        None
                    }
                    Err(error) => return Err(error.into()),
                };
                if let Some(replay) = replay {
                    let colors = term.color_overrides();
                    #[cfg(test)]
                    if self.fail_next_resize_publication.swap(false, Ordering::AcqRel) {
                        anyhow::bail!("injected terminal resize publication failure");
                    }
                    let mut resized = Frame::new(
                        MessageKind::Resized,
                        encode_resize(
                            cols,
                            rows,
                            &replay.self_contained_bytes(),
                            &replay.kitty_image_aliases,
                            cell_pixels,
                            replay.kitty_state,
                        )?,
                    );
                    resized.flags = FLAG_COLORS_FOLLOW;
                    publish_host_frames_and_targeted(
                        &self.broadcast_lock,
                        &self.sequence,
                        &self.taps,
                        [
                            resized,
                            Frame::new(
                                MessageKind::Colors,
                                encode_terminal_color_overrides(&colors),
                            ),
                        ],
                        targeted,
                    )
                } else {
                    publish_host_frames_and_targeted(
                        &self.broadcast_lock,
                        &self.sequence,
                        &self.taps,
                        std::iter::empty(),
                        targeted,
                    )
                }
            } else {
                publish_host_frames_and_targeted(
                    &self.broadcast_lock,
                    &self.sequence,
                    &self.taps,
                    std::iter::empty(),
                    targeted,
                )
            };
            if let Some(cursor) = source_cursor {
                // Snapshot registration takes `term` before subscribing to
                // smart publication, so advancing while `term` remains held
                // makes snapshot state and the applied cursor indivisible.
                self.smart.mark_applied(cursor);
            }
            Ok(acknowledgement_queued)
        })();
        let applied = (term.cols(), term.rows());
        ParserResizeResult {
            acknowledgement_queued: acknowledgement_queued.map_err(|error| error.to_string()),
            changed: applied != previous,
            applied,
        }
    }
}
