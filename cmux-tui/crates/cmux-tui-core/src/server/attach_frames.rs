//! Attach output as frames on a stream granted `attach-frames-v1`
//! (plans/cmux-next/chrome-parity/p05-ipc.md 3.2, task 076;
//! spec/transports.md "Attach frames").
//!
//! One [`AttachFrameEncoder`] per attach stream turns each [`AttachFrame`] the
//! viewer's tap delivers into frames whose aux is an absolute PTY offset:
//!
//! - output: one OUTPUT frame whose payload is the PTY bytes themselves, the
//!   tap's shared chunk handed over without a copy, aux the offset of its first
//!   byte. Colors replaced by the same parser transition, or the key press
//!   the bytes echo, follow as an `output` sidecar EVENT whose aux is that
//!   same offset: the JSON `output` event without `data`.
//! - a grid replacement (`resized`): one GRID frame at the current offset,
//!   `meta_len u32 | JSON meta | replay | pending`, the JSON meta being the
//!   `resized` event without `replay` and `pending`, plus `pending_len`.
//! - any other attach event: one EVENT frame at the current offset whose
//!   payload is the event's JSON line text.
//!
//! The offsets of consecutive OUTPUT frames are contiguous, so a reader that
//! sees a gap knows it lost bytes (Chrome's cc::BeginFrameArgs carry a
//! sequence number for the same reason, cc/scheduler/begin_frame_source.cc).
//! An attach frame the outbound budget refuses comes back whole in a
//! [`RefusedAttachFrame`] with the offset unchanged, so the writer waits and
//! encodes it again at the same offset, as it retries a JSON line.
//! Long payloads are cut by the connection's `LaneWriter`, which keeps the
//! OUTPUT offsets contiguous across chunks (cmux-ipc/src/lane_writer.rs).
//! Decoding the frames gives back the JSON events byte for byte; only the
//! base64 is gone.

use super::AttachWireShape;
use super::render_service::{
    BudgetedJsonWriter, OutboundByteBudget, json_error_to_io, write_colors_changed_json,
    write_output_sidecar_fields, write_resized_state_fields,
};
use crate::AttachFrame;
use crate::SurfaceId;
use crate::TerminalColors;
use crate::surface::AttachResize;
use cmux_ipc::{Aux, BadMessage, FrameHeader, FrameKind, MAX_FRAME_PAYLOAD};
use serde::Serialize;
use std::io::Write;
use std::sync::Arc;

/// Bytes of the little-endian `meta_len` that opens a GRID payload.
pub(super) const GRID_META_LEN_BYTES: usize = 4;

/// Why an attach frame could not be encoded.
#[derive(Debug)]
pub(super) enum AttachFrameError {
    /// Attach frames ride a client-minted stream, never the control stream 0.
    ControlStream,
    /// Writing the payload failed: the outbound byte budget is full
    /// (`WouldBlock`, as for a JSON line) or the JSON did not serialize.
    Write(std::io::Error),
    /// The payload does not fit one frame.
    Frame(BadMessage),
}

impl std::fmt::Display for AttachFrameError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::ControlStream => write!(f, "attach frames need a stream other than 0"),
            Self::Write(error) => write!(f, "attach frame payload: {error}"),
            Self::Frame(error) => write!(f, "attach frame: {error}"),
        }
    }
}

impl std::error::Error for AttachFrameError {}

impl From<std::io::Error> for AttachFrameError {
    fn from(error: std::io::Error) -> Self {
        Self::Write(error)
    }
}

impl From<BadMessage> for AttachFrameError {
    fn from(error: BadMessage) -> Self {
        Self::Frame(error)
    }
}

/// An [`AttachFrame`] that was not encoded, handed back so the writer can
/// encode it again once the budget has room: the offset did not move.
#[derive(Debug)]
pub(super) struct RefusedAttachFrame {
    pub(super) frame: Box<AttachFrame>,
    pub(super) error: AttachFrameError,
}

impl std::fmt::Display for RefusedAttachFrame {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        self.error.fmt(f)
    }
}

impl std::error::Error for RefusedAttachFrame {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        Some(&self.error)
    }
}

impl From<RefusedAttachFrame> for std::io::Error {
    fn from(refused: RefusedAttachFrame) -> Self {
        refused.error.into()
    }
}

impl From<AttachFrameError> for std::io::Error {
    fn from(error: AttachFrameError) -> Self {
        match error {
            AttachFrameError::Write(error) => error,
            AttachFrameError::ControlStream => {
                std::io::Error::new(std::io::ErrorKind::InvalidInput, error.to_string())
            }
            AttachFrameError::Frame(_) => {
                std::io::Error::new(std::io::ErrorKind::InvalidData, error.to_string())
            }
        }
    }
}

/// A frame payload charged to an outbound byte budget until it drops, as a
/// `BudgetedText` is for a JSON line: a payload it wrote by the capacity of
/// its allocation, a shared PTY output chunk by its length.
pub(super) struct BudgetedBytes {
    bytes: bytes::Bytes,
    retained_bytes: usize,
    budget: Arc<OutboundByteBudget>,
}

impl BudgetedBytes {
    /// Shares a buffer that already exists (a PTY output chunk, not copied)
    /// once its length is charged, as the viewer queue counts it
    /// (surface/attach_tap.rs); a refused chunk is not taken.
    fn share(bytes: &bytes::Bytes, budget: &Arc<OutboundByteBudget>) -> std::io::Result<Self> {
        let retained_bytes = bytes.len();
        if !budget.try_retain(retained_bytes) {
            return Err(budget_overflow());
        }
        Ok(Self { bytes: bytes.clone(), retained_bytes, budget: budget.clone() })
    }

    /// The bytes `writer` wrote, as one shared buffer.
    fn finish(mut writer: BudgetedJsonWriter) -> Self {
        let bytes = std::mem::take(&mut writer.bytes);
        let retained_bytes = bytes.capacity();
        if retained_bytes < writer.retained_bytes {
            writer.budget.release(writer.retained_bytes - retained_bytes);
        }
        // The writer's drop releases nothing more: the payload owns the charge.
        writer.retained_bytes = 0;
        writer.reservation_bytes = 0;
        Self { bytes: bytes.into(), retained_bytes, budget: writer.budget.clone() }
    }
}

impl Drop for BudgetedBytes {
    fn drop(&mut self) {
        self.budget.release(self.retained_bytes);
    }
}

fn budget_overflow() -> std::io::Error {
    std::io::Error::new(std::io::ErrorKind::WouldBlock, "global outbound byte budget overflowed")
}

/// A writer that holds exactly `capacity` bytes, charged before it
/// allocates: a frame payload whose length is known up front.
fn exact_writer(
    budget: &Arc<OutboundByteBudget>,
    capacity: usize,
) -> std::io::Result<BudgetedJsonWriter> {
    let mut writer = BudgetedJsonWriter::with_reservation(budget.clone(), capacity)?;
    writer.bytes.try_reserve_exact(capacity).map_err(std::io::Error::other)?;
    // The allocator may round the capacity up; charge what it gave.
    let extra = writer.bytes.capacity().saturating_sub(writer.retained_bytes);
    if extra > 0 {
        if !budget.try_retain(extra) {
            return Err(budget_overflow());
        }
        writer.retained_bytes += extra;
    }
    Ok(writer)
}

/// One frame and its payload, charged to the outbound budget until it drops.
pub(super) struct BudgetedFrame {
    header: FrameHeader,
    payload: BudgetedBytes,
}

impl BudgetedFrame {
    fn new(header: FrameHeader, payload: BudgetedBytes) -> Result<Self, AttachFrameError> {
        let len = usize::try_from(header.len()).unwrap_or(usize::MAX);
        if payload.bytes.len() != len {
            return Err(BadMessage::Truncated { have: payload.bytes.len(), need: len }.into());
        }
        Ok(Self { header, payload })
    }

    pub(super) fn header(&self) -> &FrameHeader {
        &self.header
    }

    pub(super) fn payload(&self) -> &bytes::Bytes {
        &self.payload.bytes
    }

    /// The PTY offset in the header's aux (every attach frame kind has one).
    pub(super) fn offset(&self) -> Option<u64> {
        match self.header.aux() {
            Aux::Offset(offset) => Some(offset),
            Aux::FlowId(_) | Aux::SharedBufferSize(_) | Aux::Call(_) => None,
        }
    }
}

/// The frames of one [`AttachFrame`]: the frame itself and, for output that
/// carries colors or a flow, its sidecar EVENT. Written in this order.
pub(super) struct EncodedAttachFrame {
    pub(super) frame: BudgetedFrame,
    pub(super) sidecar: Option<BudgetedFrame>,
}

impl EncodedAttachFrame {
    fn single(frame: BudgetedFrame) -> Self {
        Self { frame, sidecar: None }
    }

    /// Every frame, in write order.
    pub(super) fn frames(&self) -> impl Iterator<Item = &BudgetedFrame> {
        std::iter::once(&self.frame).chain(self.sidecar.as_ref())
    }
}

/// Encodes one attach stream's frames and keeps its absolute PTY offset.
pub(super) struct AttachFrameEncoder {
    stream: u16,
    surface: SurfaceId,
    shape: AttachWireShape,
    /// Offset of the next output byte.
    offset: u64,
}

impl AttachFrameEncoder {
    /// An encoder for `stream` whose first output byte is at `offset`
    /// (`AttachStream::offset`, taken with the replay).
    pub(super) fn new(
        stream: u16,
        surface: SurfaceId,
        shape: AttachWireShape,
        offset: u64,
    ) -> Result<Self, AttachFrameError> {
        if stream == 0 {
            return Err(AttachFrameError::ControlStream);
        }
        Ok(Self { stream, surface, shape, offset })
    }

    /// Offset of the next output byte.
    pub(super) fn offset(&self) -> u64 {
        self.offset
    }

    /// The frames of `frame`. The offset advances only when every frame of
    /// it was encoded; a refused frame comes back whole, to be encoded again
    /// at the same offset, so the reader never sees a gap over lost bytes.
    pub(super) fn encode(
        &mut self,
        mut frame: AttachFrame,
        budget: &Arc<OutboundByteBudget>,
    ) -> Result<EncodedAttachFrame, RefusedAttachFrame> {
        let encoded = match &mut frame {
            AttachFrame::Output(output) => self.output(output, None, 0, budget),
            AttachFrame::FlowOutput { output, flow } => self.output(output, None, *flow, budget),
            AttachFrame::OutputWithColors { output, colors, flow } => {
                self.output(output, Some(colors), *flow, budget)
            }
            AttachFrame::ColorsChanged(colors) => {
                let (surface, shape) = (self.surface, self.shape);
                self.json_event(self.offset, budget, |writer| {
                    write_colors_changed_json(writer, surface, colors, shape)
                })
                .map(EncodedAttachFrame::single)
            }
            AttachFrame::Resized {
                cols,
                rows,
                replay,
                kitty_image_aliases,
                kitty_state,
                pending_sequence,
            } => self
                .grid(
                    &AttachResize {
                        cols: *cols,
                        rows: *rows,
                        replay,
                        kitty_image_aliases,
                        kitty_state: *kitty_state,
                        colors: None,
                        pending_sequence,
                    },
                    budget,
                )
                .map(EncodedAttachFrame::single),
            AttachFrame::ResizedWithColors {
                cols,
                rows,
                replay,
                kitty_image_aliases,
                kitty_state,
                colors,
                pending_sequence,
            } => self
                .grid(
                    &AttachResize {
                        cols: *cols,
                        rows: *rows,
                        replay,
                        kitty_image_aliases,
                        kitty_state: *kitty_state,
                        colors: Some(colors),
                        pending_sequence,
                    },
                    budget,
                )
                .map(EncodedAttachFrame::single),
        };
        encoded.map_err(|error| RefusedAttachFrame { frame: Box::new(frame), error })
    }

    /// Another attach event (`detached`, `overflow`) as an EVENT frame at
    /// the current offset.
    pub(super) fn event<T: Serialize + ?Sized>(
        &self,
        value: &T,
        budget: &Arc<OutboundByteBudget>,
    ) -> Result<BudgetedFrame, AttachFrameError> {
        self.json_event(self.offset, budget, |writer| {
            serde_json::to_writer(writer, value).map_err(json_error_to_io)
        })
    }

    /// Shares the tap's chunk only once every frame of it is encoded; on an
    /// error nothing of it is charged.
    fn output(
        &mut self,
        output: &bytes::Bytes,
        colors: Option<&TerminalColors>,
        flow: u64,
        budget: &Arc<OutboundByteBudget>,
    ) -> Result<EncodedAttachFrame, AttachFrameError> {
        let start = self.offset;
        let len = output.len();
        let header = self.header(FrameKind::Output, len, start)?;
        let sidecar = if colors.is_some() || flow != 0 {
            let (surface, shape) = (self.surface, self.shape);
            Some(self.json_event(start, budget, |writer| {
                write!(writer, "{{\"event\":\"output\",\"surface\":{surface}")?;
                write_output_sidecar_fields(writer, colors, flow, shape)?;
                writer.write_all(b"}")
            })?)
        } else {
            None
        };
        // The header was made from `len`, so the frame is complete.
        let frame = BudgetedFrame { header, payload: BudgetedBytes::share(output, budget)? };
        self.offset = start.saturating_add(u64::try_from(len).unwrap_or(u64::MAX));
        Ok(EncodedAttachFrame { frame, sidecar })
    }

    /// `meta_len | meta | replay | pending`. A viewer without
    /// `terminal-pending-sequence-v1` gets no `pending_len`, so the pending
    /// bytes end its replay, as in its JSON `resized` event.
    fn grid(
        &self,
        resize: &AttachResize<'_>,
        budget: &Arc<OutboundByteBudget>,
    ) -> Result<BudgetedFrame, AttachFrameError> {
        let mut meta = BudgetedJsonWriter::new(budget.clone());
        write!(
            meta,
            "{{\"event\":\"resized\",\"surface\":{},\"cols\":{},\"rows\":{}",
            self.surface, resize.cols, resize.rows
        )?;
        write_resized_state_fields(&mut meta, resize, self.shape)?;
        if self.shape.pending_sequence && !resize.pending_sequence.is_empty() {
            write!(meta, ",\"pending_len\":{}", resize.pending_sequence.len())?;
        }
        meta.write_all(b"}")?;
        let meta = BudgetedBytes::finish(meta);
        let meta_len = u32::try_from(meta.bytes.len())
            .map_err(|_| BadMessage::Oversize { len: u32::MAX, max: MAX_FRAME_PAYLOAD })?;
        let len = GRID_META_LEN_BYTES
            .saturating_add(meta.bytes.len())
            .saturating_add(resize.replay.len())
            .saturating_add(resize.pending_sequence.len());
        // Validate the length before the payload is allocated.
        let header = self.header(FrameKind::Grid, len, self.offset)?;
        let mut payload = exact_writer(budget, len)?;
        payload.write_all(&meta_len.to_le_bytes())?;
        payload.write_all(&meta.bytes)?;
        payload.write_all(resize.replay)?;
        payload.write_all(resize.pending_sequence)?;
        drop(meta);
        BudgetedFrame::new(header, BudgetedBytes::finish(payload))
    }

    fn json_event(
        &self,
        offset: u64,
        budget: &Arc<OutboundByteBudget>,
        write: impl FnOnce(&mut BudgetedJsonWriter) -> std::io::Result<()>,
    ) -> Result<BudgetedFrame, AttachFrameError> {
        let mut writer = BudgetedJsonWriter::new(budget.clone());
        write(&mut writer)?;
        let payload = BudgetedBytes::finish(writer);
        let header = self.header(FrameKind::Event, payload.bytes.len(), offset)?;
        BudgetedFrame::new(header, payload)
    }

    fn header(
        &self,
        kind: FrameKind,
        len: usize,
        offset: u64,
    ) -> Result<FrameHeader, AttachFrameError> {
        let len = u32::try_from(len)
            .map_err(|_| BadMessage::Oversize { len: u32::MAX, max: MAX_FRAME_PAYLOAD })?;
        Ok(FrameHeader::new(kind, self.stream, len, Aux::Offset(offset))?)
    }
}

#[cfg(test)]
#[path = "attach_frames_tests.rs"]
mod tests;
