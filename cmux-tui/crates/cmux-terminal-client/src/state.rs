//! `ClientState`: the terminal client's decoded screen, its frame handling and its diagnostics.

use super::*;

impl ClientState {
    pub(super) fn new(
        provider: String,
        path: String,
        generation: u64,
        terminal_id: TerminalPublicId,
    ) -> Result<Self, String> {
        Ok(Self {
            raw_mode: false,
            terminal: None,
            key_encoder: KeyEncoder::new().map_err(|error| error.to_string())?,
            render: RenderState::new().map_err(|error| error.to_string())?,
            frame_text: String::new(),
            frame_rows: Vec::new(),
            frame_dirty_rows: Vec::new(),
            render_dirty: false,
            status: "bootstrap".into(),
            transport_provider: provider,
            transport_path: path,
            generation,
            terminal_id,
            snapshot_boundary: 0,
            snapshot_applied: false,
            snapshot_bytes: 0,
            bootstrap_frames: 0,
            bootstrap_committed: false,
            ready: false,
            exited: false,
            raw_bytes: 0,
            raw_frames: 0,
            local_parser_cursor: 0,
            source_cursor: 0,
            resync_count: 0,
            expected_sequence: None,
            cols: 0,
            rows: 0,
            cell_pixels: (8, 16),
            resize_delivery: None,
            resize_acknowledgement: None,
        })
    }

    pub(super) fn prepare_handshake(
        &mut self,
        terminal_id: TerminalPublicId,
    ) -> Result<(), String> {
        self.terminal = None;
        self.render = RenderState::new().map_err(|error| error.to_string())?;
        self.render_dirty = false;
        self.status = "resyncing".into();
        self.terminal_id = terminal_id;
        self.snapshot_boundary = 0;
        self.snapshot_applied = false;
        self.snapshot_bytes = 0;
        self.bootstrap_frames = 0;
        self.bootstrap_committed = false;
        self.ready = false;
        self.exited = false;
        self.expected_sequence = None;
        self.cols = 0;
        self.rows = 0;
        self.cell_pixels = (8, 16);
        self.resize_acknowledgement = None;
        Ok(())
    }

    pub(super) fn encode_key(&mut self, chord: &str, repeat: bool) -> Result<Vec<u8>, String> {
        let mut input = key_input_from_chord(chord)
            .ok_or_else(|| format!("unsupported terminal key chord: {chord}"))?;
        if repeat {
            input.action = Some(KeyAction::Repeat);
        }
        let terminal = self
            .terminal
            .as_ref()
            .ok_or_else(|| "terminal keyboard state is not ready".to_string())?;
        self.key_encoder.sync_from_terminal(terminal);
        let mut encoded = Vec::new();
        self.key_encoder.encode(&input, &mut encoded).map_err(|error| error.to_string())?;
        Ok(encoded)
    }

    pub(super) fn apply(
        &mut self,
        frame: Frame,
    ) -> Result<(FrameEffect, Option<RawEvent>), String> {
        let mut event = None;
        let effect = match frame.kind {
            MessageKind::Snapshot => {
                let snapshot = decode_host_snapshot_payload(&frame.payload)
                    .map_err(|error| error.to_string())?;
                let terminal = if self.raw_mode {
                    event = Some(RawEvent::Snapshot {
                        cols: snapshot.cols,
                        rows: snapshot.rows,
                        replay: snapshot.replay,
                    });
                    None
                } else {
                    let mut terminal =
                        Terminal::new(snapshot.cols, snapshot.rows, 100_000, Callbacks::default())
                            .map_err(|error| error.to_string())?;
                    terminal
                        .resize(
                            snapshot.cols,
                            snapshot.rows,
                            u32::from(snapshot.cell_pixels.0),
                            u32::from(snapshot.cell_pixels.1),
                        )
                        .map_err(|error| error.to_string())?;
                    terminal
                        .apply_vt_replay_parts(
                            &snapshot.replay,
                            &snapshot.kitty_image_aliases,
                            snapshot.kitty_state,
                        )
                        .map_err(|error| error.to_string())?;
                    Some(terminal)
                };
                self.cols = snapshot.cols;
                self.rows = snapshot.rows;
                self.cell_pixels = snapshot.cell_pixels;
                self.snapshot_boundary = frame.sequence;
                self.snapshot_bytes = frame.payload.len() as u64;
                self.bootstrap_frames = 1;
                self.local_parser_cursor = frame.sequence;
                self.source_cursor = frame.sequence;
                self.expected_sequence = frame.sequence.checked_add(1);
                self.terminal = terminal;
                self.snapshot_applied = true;
                self.status = "snapshot".into();
                self.render_dirty = true;
                FrameEffect::Continue
            }
            MessageKind::Colors
                if self.snapshot_applied && frame.sequence == self.snapshot_boundary =>
            {
                let colors = decode_terminal_color_overrides(&frame.payload)
                    .map_err(|error| error.to_string())?;
                // In raw mode the embedding renderer owns palette state; the
                // application colors arrive again inside the replay bytes.
                if !self.raw_mode {
                    apply_terminal_color_overrides(
                        self.terminal
                            .as_mut()
                            .ok_or_else(|| "Colors arrived before snapshot".to_string())?,
                        &colors,
                    );
                }
                self.bootstrap_frames = self.bootstrap_frames.saturating_add(1);
                self.render_dirty = true;
                FrameEffect::Continue
            }
            MessageKind::Ready
                if self.snapshot_applied && frame.sequence == self.snapshot_boundary =>
            {
                self.ready = true;
                self.bootstrap_committed = true;
                self.status = "live".into();
                self.bootstrap_frames = self.bootstrap_frames.saturating_add(1);
                FrameEffect::Continue
            }
            MessageKind::Output => {
                self.require_sequence(frame.sequence)?;
                if self.raw_mode {
                    if !self.snapshot_applied {
                        return Err("output arrived before snapshot".into());
                    }
                    event = Some(RawEvent::Output(Bytes::from(frame.payload.clone())));
                } else {
                    let terminal = self
                        .terminal
                        .as_mut()
                        .ok_or_else(|| "output arrived before snapshot".to_string())?;
                    terminal.vt_write(&frame.payload);
                }
                self.raw_bytes = self.raw_bytes.saturating_add(frame.payload.len() as u64);
                self.raw_frames = self.raw_frames.saturating_add(1);
                self.local_parser_cursor = frame.sequence;
                self.render_dirty = true;
                FrameEffect::Continue
            }
            MessageKind::Resized if matches!(frame.payload.len(), 4 | 8) => {
                self.require_sequence(frame.sequence)?;
                let cols = u16::from_le_bytes([frame.payload[0], frame.payload[1]]).max(1);
                let rows = u16::from_le_bytes([frame.payload[2], frame.payload[3]]).max(1);
                let cell_pixels = if frame.payload.len() == 8 {
                    (
                        u16::from_le_bytes([frame.payload[4], frame.payload[5]]).max(1),
                        u16::from_le_bytes([frame.payload[6], frame.payload[7]]).max(1),
                    )
                } else {
                    self.cell_pixels
                };
                if self.raw_mode {
                    if !self.snapshot_applied {
                        return Err("resize arrived before snapshot".into());
                    }
                    event = Some(RawEvent::Resized { cols, rows });
                } else {
                    self.terminal
                        .as_mut()
                        .ok_or_else(|| "resize arrived before snapshot".to_string())?
                        .resize(cols, rows, u32::from(cell_pixels.0), u32::from(cell_pixels.1))
                        .map_err(|error| error.to_string())?;
                }
                self.cols = cols;
                self.rows = rows;
                self.cell_pixels = cell_pixels;
                self.local_parser_cursor = frame.sequence;
                self.render_dirty = true;
                FrameEffect::Continue
            }
            MessageKind::Exit => {
                self.require_sequence(frame.sequence)?;
                self.local_parser_cursor = frame.sequence;
                self.ready = false;
                self.exited = true;
                self.status = "exited".into();
                if self.raw_mode {
                    event = Some(RawEvent::Exit);
                }
                FrameEffect::Stop
            }
            MessageKind::ResyncRequired => {
                self.source_cursor = frame.sequence;
                self.resync_count = self.resync_count.saturating_add(1);
                self.status = "resync-required".into();
                FrameEffect::Restart
            }
            // Targeted resize acknowledgements are outside the source
            // sequence and carry no render state.
            MessageKind::ResizeAck if frame.sequence == 0 => {
                if frame.request_id == 0 {
                    return Err("ResizeAck request ID is zero".into());
                }
                if frame.payload.len() != 8 {
                    return Err("ResizeAck payload must be 8 bytes".into());
                }
                let cols = u16::from_le_bytes([frame.payload[0], frame.payload[1]]).max(1);
                let rows = u16::from_le_bytes([frame.payload[2], frame.payload[3]]).max(1);
                let flags = u32::from_le_bytes([
                    frame.payload[4],
                    frame.payload[5],
                    frame.payload[6],
                    frame.payload[7],
                ]);
                if flags & !RESIZE_ACK_CANONICAL_CHANGED != 0 {
                    return Err(format!("ResizeAck has unknown flags 0x{flags:08x}"));
                }
                let acknowledgement = ResizeAcknowledgement {
                    request_id: frame.request_id,
                    cols,
                    rows,
                    canonical_changed: flags & RESIZE_ACK_CANONICAL_CHANGED != 0,
                };
                self.resize_acknowledgement = Some(acknowledgement);
                if let Some(delivery) = &self.resize_delivery {
                    delivery.acknowledge(frame.request_id);
                }
                FrameEffect::Continue
            }
            other => return Err(format!("unexpected smart terminal frame {other:?}")),
        };
        Ok((effect, event))
    }

    pub(super) fn require_sequence(&mut self, sequence: u64) -> Result<(), String> {
        let expected = self
            .expected_sequence
            .ok_or_else(|| "live frame arrived before snapshot".to_string())?;
        if sequence != expected {
            return Err(format!("terminal sequence gap: expected {expected}, received {sequence}"));
        }
        self.expected_sequence = sequence.checked_add(1);
        self.source_cursor = sequence;
        Ok(())
    }

    pub(super) fn materialize_frame(&mut self) -> Result<(), String> {
        // Raw mode has no local parser; the embedding renderer holds the
        // screen, so there is nothing to materialize.
        if self.raw_mode {
            return Ok(());
        }
        // Snapshot and Colors are one bootstrap transaction. Do not expose
        // their renderable result until the host commits the same boundary
        // with Ready.
        if !self.bootstrap_committed || !self.render_dirty {
            return Ok(());
        }
        let terminal =
            self.terminal.as_mut().ok_or_else(|| "terminal is not initialized".to_string())?;
        self.render.update(terminal).map_err(|error| error.to_string())?;
        let frame = self.render.build_frame().map_err(|error| error.to_string())?;
        let mut text = String::new();
        let mut rows = Vec::with_capacity(frame.styled_rows().len());
        // The UI polls at a bounded cadence. Only the visible viewport is
        // materialized here; raw transport frames never trigger a grid walk,
        // and history remains local in libghostty for a later paged API.
        for row in frame.styled_rows() {
            let mut rendered = String::new();
            append_row(&mut rendered, row);
            text.push_str(&rendered);
            rows.push(rendered);
        }
        self.frame_text = text;
        self.frame_rows = rows;
        self.frame_dirty_rows = frame.dirty_rows;
        self.render_dirty = false;
        Ok(())
    }

    pub(super) fn diagnostics(&self) -> String {
        serde_json::to_string(&Diagnostics {
            carrier: &self.transport_provider,
            path: &self.transport_path,
            generation: self.generation,
            terminal: self.terminal_id.as_str(),
            service: "terminal-bytes-v1",
            status: &self.status,
            snapshot_boundary: self.snapshot_boundary,
            snapshot_bytes: self.snapshot_bytes,
            bootstrap_frames: self.bootstrap_frames,
            ready: self.ready,
            raw_bytes: self.raw_bytes,
            raw_frames: self.raw_frames,
            local_parser_cursor: self.local_parser_cursor,
            source_cursor: self.source_cursor,
            resync_count: self.resync_count,
            server_snapshot_rpc_count: 0,
            cols: self.cols,
            rows: self.rows,
        })
        .unwrap_or_else(|_| "{\"status\":\"diagnostics-error\"}".into())
    }
}

pub(super) fn append_row(output: &mut String, row: &[ghostty_vt::Cell]) {
    for cell in row {
        match cell.width {
            CellWidth::SpacerTail => {}
            _ if cell.text.is_empty() => output.push(' '),
            _ => output.push_str(&cell.text),
        }
    }
    while output.ends_with(' ') {
        output.pop();
    }
    output.push('\n');
}
