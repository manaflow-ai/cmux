//! Hosted frame staging: holds terminal host frames until their color state
//! arrives, so a renderer never sees output or a resize without its colors.

use super::*;

/// A host frame is not actionable until its wire-level atomicity contract is
/// satisfied. In particular, a renderer must never expose output or a resize
/// whose authoritative color state is still sitting in the socket.
#[cfg(unix)]
#[derive(Debug)]
pub(super) enum HostedTransition {
    Output(Vec<u8>),
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

#[cfg(unix)]
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

#[cfg(unix)]
pub(super) struct HostedFrameStager {
    protocol_version: u16,
    expected_sequence: u64,
    smart_renderer: bool,
    pending: Option<PendingHostedTransition>,
}

#[cfg(unix)]
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
            pending: None,
        }
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
                    let cols = u16::from_le_bytes([frame.payload[0], frame.payload[1]]);
                    let rows = u16::from_le_bytes([frame.payload[2], frame.payload[3]]);
                    let (cols, rows) =
                        crate::terminal_host_runtime::normalize_terminal_geometry(cols, rows)
                            .map_err(|_| "invalid Resized geometry")?;
                    let cell_pixels = (frame.payload.len() == 8).then(|| {
                        (
                            u16::from_le_bytes([frame.payload[4], frame.payload[5]]).max(1),
                            u16::from_le_bytes([frame.payload[6], frame.payload[7]]).max(1),
                        )
                    });
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
