//! Entry points of the cmux-tui/fuzz targets (plans/cmux-next/chrome-parity/
//! p10-stability.md, task 020): the terminal-host payload codecs, the session
//! journal's stored-row and archived-segment decoders, the output store's
//! snapshot and segment files, and the page listener's request head.
//!
//! Built only with the `fuzz` feature, which only the fuzz workspace turns
//! on. Each entry calls the decoder the daemon calls; none adds its own
//! parsing. A codec entry answers [`Decoded`]: a decoder must refuse bad
//! bytes with an error, and what it accepts must encode again (the
//! canonical bytes the target feeds back in).

use std::io::{Read, Write};

use crate::SessionJournalRecord;
use crate::terminal_host_runtime as host;
use crate::workspace_registry::session_journal;

/// What one codec made of one input.
#[derive(Debug)]
pub enum Decoded {
    /// The decoder refused the input: the only allowed outcome for bad bytes.
    Rejected(anyhow::Error),
    /// The decoder accepted the input; the value's encoding.
    Accepted(Vec<u8>),
    /// The decoder accepted a value its own encoder refuses.
    Unencodable(anyhow::Error),
}

impl Decoded {
    fn of<T>(
        decoded: anyhow::Result<T>,
        encode: impl FnOnce(T) -> anyhow::Result<Vec<u8>>,
    ) -> Self {
        match decoded {
            Err(error) => Self::Rejected(error),
            Ok(value) => match encode(value) {
                Ok(bytes) => Self::Accepted(bytes),
                Err(error) => Self::Unencodable(error),
            },
        }
    }
}

/// The negotiated tails of a host snapshot payload.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct SnapshotTails {
    pub terminal_metadata: bool,
    pub shell_activity: bool,
    pub program_status: bool,
}

/// A host snapshot payload of `protocol_version` with `tails`. Accepted
/// holds the current-version encoding with the same tails.
pub fn host_snapshot(payload: &[u8], protocol_version: u16, tails: SnapshotTails) -> Decoded {
    Decoded::of(
        host::decode_snapshot_with_program_status(
            payload,
            protocol_version,
            tails.terminal_metadata,
            tails.shell_activity,
            tails.program_status,
        ),
        |snapshot| {
            host::encode_snapshot_for_version(
                &snapshot,
                crate::terminal_host_protocol::PROTOCOL_VERSION,
                tails.terminal_metadata,
            )
        },
    )
}

/// A host resize payload of `protocol_version`. Accepted holds the
/// current-version encoding.
pub fn host_resize(payload: &[u8], protocol_version: u16) -> Decoded {
    Decoded::of(host::decode_host_resize_payload_for_version(payload, protocol_version), |resize| {
        host::encode_resize(
            resize.cols,
            resize.rows,
            &resize.replay,
            &resize.kitty_image_aliases,
            resize.cell_pixels,
            resize.kitty_state,
        )
    })
}

/// A host launch payload (the daemon's spawn request to a terminal host).
pub fn host_launch(payload: &[u8]) -> Decoded {
    Decoded::of(host::HostLaunch::decode(payload), |launch| launch.encode())
}

/// A default-colors payload.
pub fn host_default_colors(payload: &[u8]) -> Decoded {
    Decoded::of(host::decode_default_colors_payload(payload), |colors| {
        Ok(host::encode_default_colors_payload(colors))
    })
}

/// The Kitty limits of a smart host's `ResyncRequired`.
pub fn host_resync_kitty_limits(payload: &[u8]) -> Decoded {
    let limits = host::decode_resync_kitty_graphics_limits(payload)
        .ok_or_else(|| anyhow::anyhow!("not a Kitty limits payload"));
    Decoded::of(limits, |limits| {
        let mut output = Vec::new();
        host::encode_kitty_graphics_limits(&mut output, limits)?;
        Ok(output)
    })
}

/// A host record's hex identity: 16 bytes for 32 characters, else 32 bytes
/// (the owner token). `lowercase_only` is the canonical-record decoder.
/// Accepted holds the identity's hex text.
pub fn host_identity_hex(text: &str, lowercase_only: bool) -> Decoded {
    fn decode<const N: usize>(text: &str, lowercase_only: bool) -> anyhow::Result<Vec<u8>> {
        let bytes: [u8; N] = if lowercase_only {
            host::decode_lower_hex_array(text, "identity")?
        } else {
            host::decode_hex_array(text)?
        };
        Ok(bytes.to_vec())
    }
    let decoded = if text.len() == 32 {
        decode::<16>(text, lowercase_only)
    } else {
        decode::<{ crate::terminal_host::CAPABILITY_TOKEN_LEN }>(text, lowercase_only)
    };
    Decoded::of(decoded, |bytes| Ok(host::encode_hex(&bytes).into_bytes()))
}

/// One stored `session_journal` row, the columns `decode_record` reads.
#[derive(Debug, Clone, Default)]
pub struct JournalRow {
    pub sequence: i64,
    pub event_id: String,
    pub schema_version: i64,
    pub kind: String,
    pub class: String,
    pub replay: String,
    pub occurred_at_ms: i64,
    pub committed_at_ms: i64,
    pub producer: String,
    pub authority: Option<String>,
    pub causation_id: Option<String>,
    pub correlation_id: Option<String>,
    pub causation_depth: i64,
    pub subjects: String,
    pub sensitivity: String,
    pub payload: String,
    pub content: Option<Vec<u8>>,
    pub resource_revision: Option<i64>,
    pub previous_resource_revision: Option<i64>,
}

/// A stored journal row as the reader decodes it.
pub fn journal_record(row: JournalRow) -> anyhow::Result<SessionJournalRecord> {
    session_journal::decode_record((
        row.sequence,
        row.event_id,
        row.schema_version,
        row.kind,
        row.class,
        row.replay,
        row.occurred_at_ms,
        row.committed_at_ms,
        row.producer,
        row.authority,
        row.causation_id,
        row.correlation_id,
        row.causation_depth,
        row.subjects,
        row.sensitivity,
        row.payload,
        row.content,
        row.resource_revision,
        row.previous_resource_revision,
    ))
}

/// The form a record takes in a sealed segment (terminal output inline).
pub fn journal_record_for_archive(record: &SessionJournalRecord) -> SessionJournalRecord {
    session_journal::journal_record_for_archive(record)
}

/// One stored `journal_segments` row, the columns the segment decoder reads.
#[derive(Debug, Clone, Default)]
pub struct JournalSegmentRow {
    pub segment_id: String,
    pub start_sequence: i64,
    pub end_sequence: i64,
    pub record_count: i64,
    pub codec: String,
    pub compressed: Vec<u8>,
    pub uncompressed_bytes: i64,
    pub sha256: Vec<u8>,
}

/// A sealed journal segment's records as the reader decodes them.
pub fn journal_segment(row: JournalSegmentRow) -> anyhow::Result<Vec<SessionJournalRecord>> {
    session_journal::decode_journal_segment((
        row.segment_id,
        row.start_sequence,
        row.end_sequence,
        row.record_count,
        row.codec,
        row.compressed,
        row.uncompressed_bytes,
        row.sha256,
    ))
    .map(|segment| segment.records)
}

/// What the output store reads back from a snapshot file.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct OutputSnapshot {
    pub generation: String,
    pub cols: u16,
    pub rows: u16,
    pub replay: Vec<u8>,
}

/// An output store snapshot file's contents, `None` when it is unreadable.
pub fn output_snapshot(contents: &[u8]) -> Option<OutputSnapshot> {
    crate::output_store::snapshot::decode(contents).map(|(replay, generation)| OutputSnapshot {
        generation,
        cols: replay.cols,
        rows: replay.rows,
        replay: replay.bytes,
    })
}

/// The snapshot file the output store writes for these values.
pub fn encode_output_snapshot(
    snapshot: &OutputSnapshot,
    stream_end: u64,
    written_at_ms: u64,
) -> anyhow::Result<Vec<u8>> {
    let mut output = Vec::new();
    crate::output_store::snapshot::encode(
        &mut output,
        &crate::output_store::snapshot::SnapshotHeader {
            generation: &snapshot.generation,
            stream_end,
            cols: snapshot.cols,
            rows: snapshot.rows,
            written_at_ms,
        },
        &snapshot.replay,
    )?;
    Ok(output)
}

/// An output store segment file's frames: (start offset, raw bytes), up to
/// the first cut or corrupt frame.
pub fn output_segment_frames(contents: &[u8]) -> Vec<(u64, Vec<u8>)> {
    crate::output_store::segments::decode_frames(contents)
}

/// The segment frame the output store appends for `bytes` at `start`.
pub fn encode_output_segment_frame(start: u64, bytes: &[u8]) -> anyhow::Result<Vec<u8>> {
    crate::output_store::segments::encode_frame(start, bytes)
}

/// The page listener's view of one request head.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PageRequestHead {
    pub method: String,
    pub target: String,
    pub header_names: Vec<String>,
    pub websocket_upgrade: bool,
    pub host: Vec<String>,
    pub origin: Vec<String>,
}

/// The request head the daemon's WebSocket listener reads from `stream`,
/// with every byte it read; `None` for a closed, oversized (past `max_bytes`,
/// [`PAGE_REQUEST_HEAD_MAX_BYTES`] in the daemon) or malformed one.
pub fn page_request_head(
    stream: &mut (impl Read + Write),
    max_bytes: usize,
) -> Option<(Vec<u8>, PageRequestHead)> {
    let (bytes, head) = crate::server::page_files::read_request_head_within(stream, max_bytes)?;
    let owned = |values: Vec<&str>| values.into_iter().map(str::to_owned).collect();
    let summary = PageRequestHead {
        websocket_upgrade: head.is_websocket_upgrade(),
        host: owned(head.values("host")),
        origin: owned(head.values("origin")),
        header_names: head.names().map(str::to_owned).collect(),
        method: head.method,
        target: head.target,
    };
    Some((bytes, summary))
}

/// The largest request head the listener reads before it answers 431.
pub const PAGE_REQUEST_HEAD_MAX_BYTES: usize = crate::server::page_files::REQUEST_HEAD_MAX_BYTES;

/// The stateful request fuzzer (task 176): request sequences from the SDK
/// schema against an in-memory daemon (server/test_harness.rs).
pub mod requests {
    pub use crate::mux::fuzz_support::LiveIds;
    pub use crate::server::test_harness::{
        Choices, Finding, HOST_EFFECTS, RequestCatalog, RequestHarness, RunSummary,
        record_request_thread_blocking, run,
    };
}
