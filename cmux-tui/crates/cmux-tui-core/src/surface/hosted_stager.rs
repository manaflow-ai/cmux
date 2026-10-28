//! Hosted frame staging: holds terminal host frames until their color state
//! arrives, so a renderer never sees output or a resize without its colors.

use super::*;

/// A host frame is not actionable until its wire-level atomicity contract is
/// satisfied. In particular, a renderer must never expose output or a resize
/// whose authoritative color state is still sitting in the socket.
#[cfg(any(unix, windows))]
#[derive(Debug)]
pub(super) enum HostedTransition {
    Output(Vec<u8>),
    /// [`Self::Output`] of the host's first PTY read after the key press
    /// `flow` reached the PTY: its echo (`FLAG_INPUT_FLOW`).
    FlowOutput {
        output: Vec<u8>,
        flow: u64,
        /// The host's PTY write and read of the press (trace clock ns, 0:
        /// unknown), with `FLAG_INPUT_STAGES`; `None` from a
        /// host that sends no stages.
        host_stages: Option<(u64, u64)>,
    },
    OutputWithColors {
        output: Vec<u8>,
        colors: TerminalColorOverrides,
    },
    Resized {
        cols: u16,
        rows: u16,
        cell_pixels: Option<(u16, u16)>,
    },
    ResizedWithColors {
        cols: u16,
        rows: u16,
        cell_pixels: (u16, u16),
        replay: Vec<u8>,
        kitty_image_aliases: Vec<ghostty_vt::KittyImageAlias>,
        kitty_state: KittyReplayState,
        colors: TerminalColorOverrides,
    },
    Metadata(MessageKind),
    Exit(TerminalExit),
    ResyncRequired,
    /// A smart host's quota change that evicted nothing (host_kitty_limits.rs).
    KittyGraphicsLimits(KittyGraphicsLimits),
}

#[cfg(any(unix, windows))]
#[derive(Debug)]
enum PendingHostedTransition {
    Output(Vec<u8>),
    Resized {
        cols: u16,
        rows: u16,
        cell_pixels: (u16, u16),
        replay: Vec<u8>,
        kitty_image_aliases: Vec<ghostty_vt::KittyImageAlias>,
        kitty_state: KittyReplayState,
    },
}

#[cfg(any(unix, windows))]
pub(super) struct HostedFrameStager {
    protocol_version: u16,
    expected_sequence: u64,
    smart_renderer: bool,
    /// The connection negotiated `FLAG_INPUT_FLOW`: an `Output` may carry
    /// a key press's flow.
    input_flow: bool,
    /// The connection negotiated `FLAG_INPUT_STAGES`: a flow's `Output` also
    /// carries the host's write and read of the press.
    input_stages: bool,
    pending: Option<PendingHostedTransition>,
}

#[cfg(any(unix, windows))]
impl HostedFrameStager {
    #[cfg(test)]
    pub(super) fn new(sequence_boundary: u64, smart_renderer: bool) -> Self {
        Self::new_for_version(sequence_boundary, PROTOCOL_VERSION, smart_renderer)
    }

    pub(super) fn new_for_version(
        sequence_boundary: u64,
        protocol_version: u16,
        smart_renderer: bool,
    ) -> Self {
        Self {
            protocol_version,
            expected_sequence: sequence_boundary.wrapping_add(1),
            smart_renderer,
            input_flow: false,
            input_stages: false,
            pending: None,
        }
    }

    /// Accept `Output` frames that carry a key press's flow: the
    /// connection negotiated `FLAG_INPUT_FLOW`.
    pub(super) fn with_input_flow(mut self, input_flow: bool) -> Self {
        self.input_flow = input_flow;
        self
    }

    /// Accept flow `Output` frames that carry the host's key stages: the
    /// connection negotiated `FLAG_INPUT_STAGES`.
    pub(super) fn with_input_stages(mut self, input_stages: bool) -> Self {
        self.input_stages = input_stages;
        self
    }

    pub(super) fn push(&mut self, frame: Frame) -> Result<Option<HostedTransition>, &'static str> {
        if frame.version != self.protocol_version || frame.request_id != 0 {
            return Err("invalid live-frame envelope");
        }
        if frame.sequence != self.expected_sequence {
            return Err("non-contiguous live-frame sequence");
        }
        self.expected_sequence = self.expected_sequence.wrapping_add(1);

        if let Some(pending) = self.pending.take() {
            if frame.kind != MessageKind::Colors || frame.flags != 0 {
                return Err("coupled frame was not followed by Colors");
            }
            let colors =
                crate::terminal_host_runtime::decode_terminal_color_overrides(&frame.payload)
                    .map_err(|_| "invalid Colors payload")?;
            return Ok(Some(match pending {
                PendingHostedTransition::Output(output) => {
                    HostedTransition::OutputWithColors { output, colors }
                }
                PendingHostedTransition::Resized {
                    cols,
                    rows,
                    cell_pixels,
                    replay,
                    kitty_image_aliases,
                    kitty_state,
                } => HostedTransition::ResizedWithColors {
                    cols,
                    rows,
                    cell_pixels,
                    replay,
                    kitty_image_aliases,
                    kitty_state,
                    colors,
                },
            }));
        }

        match frame.kind {
            MessageKind::Output => match frame.flags {
                0 => Ok(Some(HostedTransition::Output(frame.payload))),
                FLAG_COLORS_FOLLOW => {
                    self.pending = Some(PendingHostedTransition::Output(frame.payload));
                    Ok(None)
                }
                FLAG_INPUT_FLOW if self.input_flow => {
                    let (output, flow) = split_flow_trailer(frame.flags, &frame.payload)
                        .ok_or("short Output flow trailer")?;
                    let output = output.to_vec();
                    Ok(Some(HostedTransition::FlowOutput { output, flow, host_stages: None }))
                }
                flags if self.input_stages && flags == FLAG_INPUT_FLOW | FLAG_INPUT_STAGES => {
                    let (output, flow, written, read) = split_stages_trailer(&frame.payload)
                        .ok_or("short Output stages trailer")?;
                    let output = output.to_vec();
                    Ok(Some(HostedTransition::FlowOutput {
                        output,
                        flow,
                        host_stages: Some((written, read)),
                    }))
                }
                _ => Err("unknown Output flags"),
            },
            MessageKind::Resized => {
                let valid_smart =
                    self.smart_renderer && frame.flags == 0 && matches!(frame.payload.len(), 4 | 8);
                let valid_legacy = !self.smart_renderer
                    && frame.flags == FLAG_COLORS_FOLLOW
                    && frame.payload.len() >= 4
                    && frame.payload.len() - 4 <= VT_REPLAY_MAX_BYTES;
                if !valid_smart && !valid_legacy {
                    return Err("invalid Resized frame");
                }
                if valid_smart {
                    let (cols, rows, cell_pixels) = match *frame.payload.as_slice() {
                        [c0, c1, r0, r1] => {
                            (u16::from_le_bytes([c0, c1]), u16::from_le_bytes([r0, r1]), None)
                        }
                        [c0, c1, r0, r1, w0, w1, h0, h1] => (
                            u16::from_le_bytes([c0, c1]),
                            u16::from_le_bytes([r0, r1]),
                            Some((
                                u16::from_le_bytes([w0, w1]).max(1),
                                u16::from_le_bytes([h0, h1]).max(1),
                            )),
                        ),
                        _ => return Err("invalid Resized frame"),
                    };
                    let (cols, rows) =
                        crate::terminal_host_runtime::normalize_terminal_geometry(cols, rows)
                            .map_err(|_| "invalid Resized geometry")?;
                    return Ok(Some(HostedTransition::Resized { cols, rows, cell_pixels }));
                }
                let crate::terminal_host_runtime::DecodedHostResize {
                    cols,
                    rows,
                    cell_pixels,
                    replay,
                    kitty_image_aliases,
                    kitty_state,
                } = crate::terminal_host_runtime::decode_host_resize_payload_for_version(
                    &frame.payload,
                    self.protocol_version,
                )
                .map_err(|_| "invalid Resized geometry")?;
                self.pending = Some(PendingHostedTransition::Resized {
                    cols,
                    rows,
                    cell_pixels,
                    replay,
                    kitty_image_aliases,
                    kitty_state,
                });
                Ok(None)
            }
            MessageKind::Title | MessageKind::Pwd | MessageKind::Bell if frame.flags == 0 => {
                Ok(Some(HostedTransition::Metadata(frame.kind)))
            }
            MessageKind::Exit if frame.flags == 0 => {
                let exit = if frame.payload.is_empty() {
                    TerminalExit::unknown("terminal host omitted exit status")
                } else {
                    decode_terminal_exit(&frame.payload).map_err(|_| "invalid Exit payload")?
                };
                Ok(Some(HostedTransition::Exit(exit)))
            }
            MessageKind::ResyncRequired if frame.flags == 0 => Ok(Some(
                match crate::terminal_host_runtime::decode_resync_kitty_graphics_limits(
                    &frame.payload,
                ) {
                    Some(limits) if self.smart_renderer => {
                        HostedTransition::KittyGraphicsLimits(limits)
                    }
                    _ => HostedTransition::ResyncRequired,
                },
            )),
            MessageKind::Colors => Err("unpaired Colors frame"),
            _ if frame.flags != 0 => Err("flags are not valid for this message kind"),
            _ => Err("message kind is not valid on the live stream"),
        }
    }
}
