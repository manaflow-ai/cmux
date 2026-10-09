//! Cell-metric and Kitty-limit commits of one terminal host. Both change the
//! authoritative terminal outside the PTY byte stream, publish their
//! transition, and mark it applied on the requesting client thread. So each
//! first waits for the FIFO parser to apply every Output published before it
//! (FLAKE-TERMINAL-HOST-RECOVERY-SIDECARS). Marking the transition while an
//! earlier Output was still queued moved the applied cursor backwards when
//! the parser caught up: a debug build panicked the parser while it held the
//! terminal, so the PTY drain and the exit were never published and the host
//! lived forever; a release build put the snapshot boundary ahead of the
//! parsed bytes.

use super::*;

impl HostShared {
    /// Waits until the parser has applied every command queued before this
    /// call. The caller holds `source_order_lock`, so no Output is published
    /// meanwhile, and must not hold `term`, which the parser takes. A stopped
    /// parser holds no queued command to wait for (as in `set_default_colors`).
    fn wait_for_parser_fifo(&self) {
        let (response, applied) = sync_channel(1);
        if self.parser_commands.send(ParserCommand::Barrier(response)).is_ok() {
            let _ = applied.recv();
        }
    }

    pub(super) fn set_cell_pixel_size(
        &self,
        width_px: u16,
        height_px: u16,
        request_id: u64,
        target: &HostTap,
    ) -> anyhow::Result<bool> {
        let _source_order = self.source_order_lock.lock().unwrap();
        self.wait_for_parser_fifo();
        let next = (width_px.max(1), height_px.max(1));
        let size = self.size.lock().unwrap();
        let mut cell_pixels = self.cell_pixels.lock().unwrap();
        let previous = *cell_pixels;
        let changed = previous != next;
        let resize_sizes = if changed {
            Some((pty_size(size.0, size.1, previous)?, pty_size(size.0, size.1, next)?))
        } else {
            None
        };
        let mut term = self.term.lock().unwrap();
        let mut source_cursor = None;
        if let Some((previous_size, next_size)) = resize_sizes {
            term.preflight_vt_replay_bounded(crate::surface::VT_REPLAY_MAX_BYTES).context(
                "could not preflight terminal-host cell-metric replay; geometry unchanged",
            )?;
            let mut payload = Vec::with_capacity(8);
            payload.extend_from_slice(&size.0.to_le_bytes());
            payload.extend_from_slice(&size.1.to_le_bytes());
            payload.extend_from_slice(&next.0.to_le_bytes());
            payload.extend_from_slice(&next.1.to_le_bytes());
            source_cursor = Some(self.smart.publish(Frame::new(MessageKind::Resized, payload)));
            let master = self.master.lock().unwrap();
            if let Err(error) = master.resize(next_size) {
                self.smart.close_failed_transition(source_cursor);
                return Err(error);
            }
            if let Err(error) = term.resize(size.0, size.1, u32::from(next.0), u32::from(next.1)) {
                let rollback = master.resize(previous_size);
                self.smart.close_failed_transition(source_cursor);
                return match rollback {
                    Ok(()) => Err(error.into()),
                    Err(rollback_error) => Err(anyhow::anyhow!(
                        "could not update authoritative cell metrics: {error}; \
                         PTY rollback also failed: {rollback_error}"
                    )),
                };
            }
            *cell_pixels = next;
        }
        let transition = if changed {
            let replay = match term
                .vt_replay_bounded_theme_portable_with_aliases(crate::surface::VT_REPLAY_MAX_BYTES)
            {
                Ok(replay) => replay,
                Err(_) => {
                    // Preflight ruled out persistent budget failure. Keep
                    // the canonical commit and force every client to take
                    // a fresh snapshot instead of broadcasting partial
                    // geometry state or destructively resizing backward.
                    let mut taps = self.taps.lock().unwrap();
                    for tap in taps.values() {
                        tap.close();
                    }
                    taps.clear();
                    self.smart.close_failed_transition(source_cursor);
                    target.close();
                    return Ok(false);
                }
            };
            let mut resized = Frame::new(
                MessageKind::Resized,
                encode_resize(
                    size.0,
                    size.1,
                    &replay.self_contained_bytes(),
                    &replay.kitty_image_aliases,
                    next,
                    replay.kitty_state,
                )?,
            );
            resized.flags = FLAG_COLORS_FOLLOW;
            Some([
                resized,
                Frame::new(
                    MessageKind::Colors,
                    encode_terminal_color_overrides(&term.color_overrides()),
                ),
            ])
        } else {
            None
        };
        let mut ack = Frame::new(MessageKind::CellPixelSizeAck, {
            let mut payload = Vec::with_capacity(4);
            payload.extend_from_slice(&next.0.to_le_bytes());
            payload.extend_from_slice(&next.1.to_le_bytes());
            payload
        });
        ack.request_id = request_id;
        // Keep the parser locked through canonical publication and the
        // targeted acknowledgement. Output parsed at the new metrics
        // cannot overtake the complete Resized+Colors transition.
        let acknowledgement_queued = publish_host_frames_and_targeted(
            &self.broadcast_lock,
            &self.sequence,
            &self.taps,
            transition.into_iter().flatten(),
            Some((target, ack)),
        );
        if let Some(source_cursor) = source_cursor {
            self.smart.mark_applied(source_cursor);
        }
        Ok(acknowledgement_queued)
    }

    pub(super) fn set_kitty_graphics_limits(
        &self,
        limits: KittyGraphicsLimits,
        request_id: u64,
        target: &HostTap,
    ) -> anyhow::Result<bool> {
        let limits = limits
            .validate()
            .map_err(|_| anyhow::anyhow!("Kitty graphics limits are out of range"))?;
        let _source_order = self.source_order_lock.lock().unwrap();
        self.wait_for_parser_fifo();
        let size = *self.size.lock().unwrap();
        let cell_pixels = *self.cell_pixels.lock().unwrap();
        let mut term = self.term.lock().unwrap();
        term.preflight_vt_replay_bounded(crate::surface::VT_REPLAY_MAX_BYTES)
            .context("could not preflight terminal-host Kitty limit replay")?;
        // Kitty quota changes can evict scene state and have no raw PTY
        // representation. Smart renderers must reopen from the committed
        // authoritative state instead of retaining their old scene, unless
        // the change evicted nothing (nx-scale 1b): then the ResyncRequired
        // carries the new limits, and a client that applies them to its own
        // parser at this sequence may continue. No Output is published while
        // the parser and source-order locks are held, so publishing after the
        // change keeps the frame at the same stream position.
        let quiet = !term.kitty_upload_in_progress();
        let generation = term.kitty_image_generation();
        let applied = term.set_kitty_graphics_limits(limits);
        let evicted_nothing = quiet
            && applied.is_ok()
            && generation.is_ok_and(|before| term.kitty_image_generation().ok() == Some(before));
        let mut resync_payload = Vec::new();
        if evicted_nothing && encode_kitty_graphics_limits(&mut resync_payload, limits).is_err() {
            resync_payload.clear();
        }
        let source_cursor =
            self.smart.publish(Frame::new(MessageKind::ResyncRequired, resync_payload));
        if let Err(error) = applied {
            self.smart.mark_applied(source_cursor);
            let mut taps = self.taps.lock().unwrap();
            for tap in taps.values() {
                tap.close();
            }
            taps.clear();
            target.close();
            return Err(error.into());
        }
        let replay = match term
            .vt_replay_bounded_theme_portable_with_aliases(crate::surface::VT_REPLAY_MAX_BYTES)
        {
            Ok(replay) => replay,
            Err(error) => {
                // The authoritative limit change may already have evicted
                // state. Disconnect every mirror so none can continue from
                // the pre-eviction scene.
                self.smart.mark_applied(source_cursor);
                let mut taps = self.taps.lock().unwrap();
                for tap in taps.values() {
                    tap.close();
                }
                taps.clear();
                target.close();
                return Err(error.into());
            }
        };
        let resize_payload = match encode_resize(
            size.0,
            size.1,
            &replay.self_contained_bytes(),
            &replay.kitty_image_aliases,
            cell_pixels,
            replay.kitty_state,
        ) {
            Ok(payload) => payload,
            Err(error) => {
                self.smart.mark_applied(source_cursor);
                let mut taps = self.taps.lock().unwrap();
                for tap in taps.values() {
                    tap.close();
                }
                taps.clear();
                target.close();
                return Err(error);
            }
        };
        let mut resized = Frame::new(MessageKind::Resized, resize_payload);
        resized.flags = FLAG_COLORS_FOLLOW;
        let mut ack_payload = Vec::with_capacity(KITTY_GRAPHICS_LIMITS_ENCODED_LEN);
        if let Err(error) = encode_kitty_graphics_limits(&mut ack_payload, limits) {
            self.smart.mark_applied(source_cursor);
            target.close();
            return Err(error);
        }
        let mut ack = Frame::new(MessageKind::KittyGraphicsLimitsAck, ack_payload);
        ack.request_id = request_id;
        // The parser stays locked until all mirrors receive one complete
        // replacement and the requester receives its acknowledgement.
        let acknowledgement_queued = publish_host_frames_and_targeted(
            &self.broadcast_lock,
            &self.sequence,
            &self.taps,
            [
                resized,
                Frame::new(
                    MessageKind::Colors,
                    encode_terminal_color_overrides(&term.color_overrides()),
                ),
            ],
            Some((target, ack)),
        );
        self.smart.mark_applied(source_cursor);
        Ok(acknowledgement_queued)
    }
}
