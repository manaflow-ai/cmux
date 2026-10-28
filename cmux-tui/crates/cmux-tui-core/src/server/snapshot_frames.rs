//! SNAPSHOT and REPLAY frames (p05-ipc.md section 3.2): the
//! binary forms of a snapshot viewer's `snapshot` events (READY, a
//! local-history READY, history and images chunks) and of the `vt-state`
//! replay. A bulk frame's payload is
//!
//! ```text
//! meta_len u32 LE | meta: one JSON object, meta_len bytes | raw bytes
//! ```
//!
//! The meta is the JSON event without its base64 fields, plus their decoded
//! lengths: `data_len`, then `pending_len` when raw continues with the
//! replay's pending sequence. The connection's writer cuts a long frame at
//! BULK_FRAME_MAX (a SNAPSHOT continues as SNAPSHOT_MORE with the same aux;
//! every REPLAY chunk keeps the cut's offset, since its payload bytes are not
//! PTY bytes), so the reader takes the offset from the first frame and knows
//! from the meta where the event ends.
//! A history chunk's raw bytes are its raw DEFLATE, as its `data` was. The
//! bytes are copied once into the payload and never base64-encoded, as
//! Chrome moves large bytes as a `mojo_base::BigBuffer`
//! (chromium mojo/public/cpp/base/big_buffer.h).
#![cfg_attr(
    not(test),
    expect(dead_code, reason = "p05-ipc-079's stream attach worker is the first frame sender")
)]

use std::borrow::Cow;
use std::fmt;
use std::io::Write as _;

use base64::Engine as _;
use cmux_ipc::{Aux, BadMessage, Frame, FrameKind, MAX_FRAME_PAYLOAD};
use serde_json::{Value, json};

use super::super::{
    json_error_to_io, write_kitty_image_aliases_json, write_kitty_replay_state_json,
};
use super::VtStateMessage;
use crate::panic_free::JsonFields;

/// Bytes of the `meta_len` prefix of a bulk frame payload.
pub(in crate::server) const BULK_META_LEN_BYTES: usize = 4;

/// Why a bulk event has no frame form; it then goes as its JSON line.
#[derive(Debug)]
pub(in crate::server) enum BulkFrameError {
    /// The meta could not be serialized.
    Meta(std::io::Error),
    /// Prefix, meta and raw bytes together pass `MAX_FRAME_PAYLOAD`.
    Oversize { len: usize },
    /// The header was refused (stream 0 carries no stream data).
    Frame(BadMessage),
}

impl fmt::Display for BulkFrameError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            BulkFrameError::Meta(error) => write!(f, "bulk frame meta: {error}"),
            BulkFrameError::Oversize { len } => {
                write!(f, "bulk frame payload of {len} bytes is over {MAX_FRAME_PAYLOAD}")
            }
            BulkFrameError::Frame(bad) => write!(f, "bulk frame header: {}", bad.reason()),
        }
    }
}

impl std::error::Error for BulkFrameError {}

impl From<BulkFrameError> for std::io::Error {
    fn from(error: BulkFrameError) -> Self {
        std::io::Error::new(std::io::ErrorKind::InvalidData, error)
    }
}

/// One `kind` frame on `stream` at PTY `offset`: `meta_len | meta | raw`.
pub(in crate::server) fn bulk_frame(
    kind: FrameKind,
    stream: u16,
    offset: u64,
    meta: &[u8],
    raw: &[&[u8]],
) -> Result<Frame, BulkFrameError> {
    let len = raw
        .iter()
        .try_fold(BULK_META_LEN_BYTES.saturating_add(meta.len()), |len, part| {
            len.checked_add(part.len())
        })
        .unwrap_or(usize::MAX);
    if len > MAX_FRAME_PAYLOAD as usize {
        return Err(BulkFrameError::Oversize { len });
    }
    let meta_len = u32::try_from(meta.len()).map_err(|_| BulkFrameError::Oversize { len })?;
    let mut payload = Vec::with_capacity(len);
    payload.extend_from_slice(&meta_len.to_le_bytes());
    payload.extend_from_slice(meta);
    for part in raw {
        payload.extend_from_slice(part);
    }
    Frame::new(kind, stream, Aux::Offset(offset), payload.into()).map_err(BulkFrameError::Frame)
}

/// One `snapshot` event: its JSON fields but `data`, and the bytes of
/// `data`. The worker renders it as a JSON line or as a SNAPSHOT frame.
pub(in crate::server) struct SnapshotEvent<'a> {
    /// The READY's PTY offset (the event's `offset`): the frame's aux.
    offset: u64,
    meta: Value,
    data: Cow<'a, [u8]>,
}

impl<'a> SnapshotEvent<'a> {
    /// `meta` is the event without `data`.
    pub(in crate::server) fn new(offset: u64, meta: Value, data: impl Into<Cow<'a, [u8]>>) -> Self {
        Self { offset, meta, data: data.into() }
    }

    /// The JSON line: the meta with `data` in base64.
    pub(in crate::server) fn into_json(self) -> Value {
        let mut value = self.meta;
        let data = base64::engine::general_purpose::STANDARD.encode(&self.data);
        value.insert("data", json!(data));
        value
    }

    /// The SNAPSHOT frame on `stream`.
    pub(in crate::server) fn into_frame(self, stream: u16) -> Result<Frame, BulkFrameError> {
        let mut meta = self.meta;
        meta.insert("data_len", json!(self.data.len()));
        let meta = serde_json::to_vec(&meta)
            .map_err(|error| BulkFrameError::Meta(json_error_to_io(error)))?;
        bulk_frame(FrameKind::Snapshot, stream, self.offset, &meta, &[&self.data])
    }
}

impl VtStateMessage {
    /// The REPLAY frame of this `vt-state` on `stream`, cut at PTY `offset`.
    /// Its meta holds every JSON field but `data` and `pending`, whose bytes
    /// are raw in that order.
    pub(in crate::server) fn replay_frame(
        &self,
        stream: u16,
        offset: u64,
    ) -> Result<Frame, BulkFrameError> {
        let meta = self.replay_meta().map_err(BulkFrameError::Meta)?;
        let raw: [&[u8]; 2] = [&self.replay, &self.pending_sequence];
        bulk_frame(FrameKind::Replay, stream, offset, &meta, &raw)
    }

    fn replay_meta(&self) -> std::io::Result<Vec<u8>> {
        let mut meta = Vec::with_capacity(512);
        write!(
            meta,
            "{{\"event\":\"vt-state\",\"surface\":{},\"cols\":{},\"rows\":{},\"data_len\":{}",
            self.surface,
            self.cols,
            self.rows,
            self.replay.len()
        )?;
        meta.extend_from_slice(b",\"kitty_image_aliases\":");
        write_kitty_image_aliases_json(&mut meta, &self.kitty_image_aliases)?;
        meta.extend_from_slice(b",\"kitty_graphics_state\":");
        write_kitty_replay_state_json(&mut meta, self.kitty_state)?;
        meta.extend_from_slice(b",\"colors\":");
        serde_json::to_writer(&mut meta, &self.colors).map_err(json_error_to_io)?;
        if !self.pending_sequence.is_empty() {
            write!(meta, ",\"pending_len\":{}", self.pending_sequence.len())?;
        }
        meta.push(b'}');
        Ok(meta)
    }
}
