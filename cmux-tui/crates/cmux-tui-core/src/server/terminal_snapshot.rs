//! Capability `terminal-snapshot-v1` on the raw v12 socket
//! (spec/terminal-frames.md; plans/cmux-next/ghostty-next.md sections 2, 2.1).
//!
//! `attach-surface {mode: "bytes", snapshot: "ghostsnp", snapshot_version}`
//! answers with event `snapshot {phase: "ready", generation, offset, version,
//! data}` instead of `vt-state`, then live `output` events that carry
//! `generation` and `offset`. A grid change, a backlog over
//! `viewer_backlog_bytes` and `snapshot-request` reach the viewer as a
//! new READY snapshot; the viewer is never disconnected for being slow. Two
//! seconds after output goes idle the viewer gets `digest {generation, offset,
//! version, sha256}` of the host's READY encoding.
//!
//! Capability `terminal-snapshot-history-v1`: every READY is followed by
//! `snapshot {phase: "history", generation, offset, version, compression:
//! "deflate", raw_bytes, data, done}` chunks at that READY's generation and
//! offset. Each chunk is at most [`HISTORY_CHUNK_BYTES`] of history,
//! compressed alone as raw DEFLATE (level 1) by the viewer's drain, outside
//! the terminal lock. The inflated chunks concatenated are the rest of the
//! same COMPLETE encode (HISTORY manifests, scrollback pages, FINISH), which
//! a viewer feeds to its restore after READY. History has lower priority than live
//! output: a chunk goes out only while the viewer's queue is empty, so live
//! `output` frames pass between chunks. A newer READY drops the rest of the
//! older history on the host.
//!
//! Capability `terminal-snapshot-local-history-v1`: a viewer that attaches
//! with `snapshot_local_history: true` reflows its own history. A resize
//! reaches it, while it holds every frame since its last READY, as one
//! `snapshot {phase: "ready", history: "local", generation, offset,
//! history_rows, history_digest, ...}` of the new grid taken under the
//! terminal lock at the resize: after every output frame before the resize,
//! at the resize's new generation and the offset at the resize, and never
//! followed by history. The viewer compares `history_rows` and
//! `history_digest` with its reflowed history and sends `snapshot-request`
//! on a mismatch. A viewer that is behind (a snapshot pending or deferred, an
//! overflow) or still receiving the history of an older READY gets a READY
//! with history at a later cut, as does attach, overflow and
//! `snapshot-request`.
//!
//! Capability `terminal-snapshot-images-v1`: a viewer that attaches with
//! `snapshot_images: true` gets, after the history of every READY that has
//! history, `snapshot {phase: "images", generation, offset, data, done}`
//! chunks of the libghostty-vt Kitty replay stream (at most
//! [`IMAGES_CHUNK_BYTES`] of stream per chunk, not compressed again: the
//! pixels are already zlib). The stream is encoded under the same terminal
//! lock hold as the READY, at the same cut, with at most
//! [`SNAPSHOT_IMAGES_MAX_BYTES`] of decoded pixels; the last chunk names
//! `skipped_images` when the cap left images out. Images have the priority
//! of history and a newer READY drops them too. A terminal without images
//! sends no images phase, and a local-history READY is never followed by
//! images (the viewer keeps its own).
//!
//! `snapshot-request {surface, reason?, have?, request_id?}` is the raw v12
//! form of the channel message `snapshot_request` (sync-and-transport.md):
//! requests collapse while a snapshot is pending, and a viewer gets at most
//! one requested snapshot per 500 ms (`snapshot_throttled {retry_after_ms}`).
//! A channel transport maps its message onto [`handle_request`].

use crate::panic_free::JsonFields;
use crate::panic_free::RecoverPoison;
use cmux_threads::sync::Mutex;
use std::collections::HashMap;
use std::sync::Arc;
use std::time::Instant;

use base64::Engine as _;
use serde::Deserialize;
use serde_json::{Value, json};

use super::attach_lifecycle::AttachCommit;
use super::attach_streams::checked_view_stream;
use super::render_messages::snapshot_frames::SnapshotEvent;
use super::terminal_io_wire::{AttachSurfaceParams, SnapshotRequestParams, wire_usize};
use super::{
    MarkedClientAttach, MessageWriter, OutboundStream, get_surface, handle_attach_send_error,
    mark_client_attached, require_pty, rollback_failed_attach, terminal_colors_json,
};
use crate::surface::snapshot_attach::{
    DEFAULT_VIEWER_BACKLOG_BYTES, LocalReadySnapshot, SnapshotAdmission, SnapshotImages,
    SnapshotRequestGate, TerminalSnapshotDigest, TerminalSnapshotFrame,
};
use crate::surface::{AttachFrame, AttachLifecycle};
use crate::{Mux, Surface, SurfaceId};

#[path = "snapshot_attach_out.rs"]
mod snapshot_attach_out;
use snapshot_attach_out::SnapshotWorker;

pub const TERMINAL_SNAPSHOT_CAPABILITY: &str = "terminal-snapshot-v1";
/// READY is followed by its history chunks (scrollback, then FINISH).
pub const TERMINAL_SNAPSHOT_HISTORY_CAPABILITY: &str = "terminal-snapshot-history-v1";
/// A resize reaches an opted-in viewer as a READY without history.
pub const TERMINAL_SNAPSHOT_LOCAL_HISTORY_CAPABILITY: &str = "terminal-snapshot-local-history-v1";
/// A READY with history is followed by its Kitty images.
pub const TERMINAL_SNAPSHOT_IMAGES_CAPABILITY: &str = "terminal-snapshot-images-v1";
/// Largest images chunk in bytes of the replay stream (base64 adds a third).
pub(crate) const IMAGES_CHUNK_BYTES: usize = 1 << 20;
/// Cap on the decoded pixel bytes of the images sent after one READY to one
/// viewer.
pub(crate) const SNAPSHOT_IMAGES_MAX_BYTES: u64 = 32 << 20;
/// Largest uncompressed history chunk. Its compressed base64 stays far under
/// the per-stream outbound byte cap with a live frame pending.
pub(crate) const HISTORY_CHUNK_BYTES: usize = 1 << 20;
/// The only snapshot encoding the host speaks.
pub const SNAPSHOT_ENCODING_GHOSTSNP: &str = "ghostsnp";

/// Snapshot fields of `attach-surface` (its generated
/// [`AttachSurfaceParams`]).
#[derive(Debug, Default)]
pub(crate) struct SnapshotAttachParams {
    snapshot: Option<String>,
    snapshot_version: Option<u16>,
    /// The viewer's backlog cap (default 8 MiB, no daemon setting), clamped to
    /// [`MIN_VIEWER_BACKLOG_BYTES`, `MAX_VIEWER_BACKLOG_BYTES`].
    viewer_backlog_bytes: Option<usize>,
    /// The viewer reflows its own history at a resize
    /// (`terminal-snapshot-local-history-v1`). Only meaningful with
    /// `snapshot`.
    snapshot_local_history: bool,
    /// Every READY with history is followed by its Kitty images
    /// (`terminal-snapshot-images-v1`). Only meaningful with `snapshot`.
    snapshot_images: bool,
}

pub(crate) const MIN_VIEWER_BACKLOG_BYTES: usize = 64 * 1024;
/// One merged output frame of this size stays under the per-stream outbound
/// cap after base64 even with a second frame pending.
pub(crate) const MAX_VIEWER_BACKLOG_BYTES: usize = 8 * 1024 * 1024;

impl SnapshotAttachParams {
    /// The snapshot fields of one `attach-surface` request.
    pub(crate) fn of(params: &AttachSurfaceParams) -> Self {
        Self {
            snapshot: params.snapshot.clone(),
            snapshot_version: params.snapshot_version,
            viewer_backlog_bytes: params.viewer_backlog_bytes.map(wire_usize),
            snapshot_local_history: params.snapshot_local_history,
            snapshot_images: params.snapshot_images,
        }
    }

    /// The images cap of this viewer, or `None` when it did not opt in.
    pub(crate) fn images_cap(&self) -> Option<u64> {
        self.snapshot_images.then_some(SNAPSHOT_IMAGES_MAX_BYTES)
    }

    pub(crate) fn backlog_bytes(&self) -> usize {
        self.viewer_backlog_bytes
            .unwrap_or(DEFAULT_VIEWER_BACKLOG_BYTES)
            .clamp(MIN_VIEWER_BACKLOG_BYTES, MAX_VIEWER_BACKLOG_BYTES)
    }

    /// Whether this attach gets snapshots. A viewer whose snapshot version
    /// differs from the host's gets the byte replay instead (capability
    /// fallback); an unknown encoding is an error.
    pub(crate) fn wants_snapshot(&self) -> anyhow::Result<bool> {
        match self.snapshot.as_deref() {
            None => Ok(false),
            // Version 0 means this host cannot encode snapshots: replay.
            Some(SNAPSHOT_ENCODING_GHOSTSNP) => Ok(host_snapshot_version()
                .is_some_and(|version| self.snapshot_version == Some(version))),
            Some(other) => anyhow::bail!("invalid: unsupported snapshot encoding {other:?}"),
        }
    }
}

/// What the viewer already holds (`have` in `snapshot_request`).
#[derive(Debug, Default, Deserialize)]
#[cfg_attr(test, derive(serde::Serialize))]
pub(crate) struct SnapshotHave {
    #[serde(default)]
    #[allow(dead_code)]
    generation: Option<u64>,
    #[serde(default)]
    #[allow(dead_code)]
    offset: Option<u64>,
    #[serde(default)]
    snapshot_version: Option<u16>,
}

#[derive(Clone)]
struct RegisteredViewer {
    stream: u64,
    gate: SnapshotRequestGate,
}

/// Snapshot viewers by `(client, surface)`, so `snapshot-request` reaches the
/// requesting connection's attach workers.
#[derive(Default)]
pub(crate) struct SnapshotViewers {
    viewers: Mutex<HashMap<(u64, SurfaceId), Vec<RegisteredViewer>>>,
}

impl SnapshotViewers {
    fn register(&self, client: u64, surface: SurfaceId, stream: u64, gate: SnapshotRequestGate) {
        self.viewers
            .lock()
            .recover_poison()
            .entry((client, surface))
            .or_default()
            .push(RegisteredViewer { stream, gate });
    }

    fn unregister(&self, client: u64, surface: SurfaceId, stream: u64) {
        let mut viewers = self.viewers.lock().recover_poison();
        if let Some(list) = viewers.get_mut(&(client, surface)) {
            list.retain(|viewer| viewer.stream != stream);
            if list.is_empty() {
                viewers.remove(&(client, surface));
            }
        }
    }

    /// The request gates of `client`'s viewers of `surface`: every one, or
    /// only the one on attach stream `stream`.
    fn gates(
        &self,
        client: u64,
        surface: SurfaceId,
        stream: Option<u64>,
    ) -> Vec<SnapshotRequestGate> {
        self.viewers
            .lock()
            .recover_poison()
            .get(&(client, surface))
            .map(|list| {
                list.iter()
                    .filter(|viewer| stream.is_none_or(|stream| viewer.stream == stream))
                    .map(|viewer| viewer.gate.clone())
                    .collect()
            })
            .unwrap_or_default()
    }
}

/// The host's GHOSTSNP version, or `None` when it cannot encode snapshots
/// (`snapshot_version()` reports 0 when its probe encode failed).
fn host_snapshot_version() -> Option<u16> {
    Some(ghostty_vt::snapshot_version()).filter(|version| *version != 0)
}

/// Longest accepted `request_id` in bytes.
pub(crate) const MAX_REQUEST_ID_BYTES: usize = 128;
/// The `reason` values of the channel message `snapshot_request`.
pub(crate) const SNAPSHOT_REQUEST_REASONS: [&str; 4] =
    ["digest_mismatch", "gap", "generation_mismatch", "attach"];

fn validate_request(params: &SnapshotRequestParams) -> anyhow::Result<()> {
    if let Some(reason) = params.reason.as_deref() {
        anyhow::ensure!(
            SNAPSHOT_REQUEST_REASONS.contains(&reason),
            "invalid: reason must be one of {SNAPSHOT_REQUEST_REASONS:?}"
        );
    }
    if let Some(request_id) = params.request_id.as_deref() {
        anyhow::ensure!(
            request_id.len() <= MAX_REQUEST_ID_BYTES,
            "invalid: request_id is longer than {MAX_REQUEST_ID_BYTES} bytes"
        );
    }
    Ok(())
}

/// Answer `snapshot-request`: one READY snapshot on the requester's attach
/// stream for that surface.
pub(crate) fn handle_request(
    mux: &Arc<Mux>,
    client: u64,
    writer: &MessageWriter,
    params: SnapshotRequestParams,
) -> anyhow::Result<Value> {
    validate_request(&params)?;
    let surface = get_surface(mux, params.surface)?;
    require_pty(&surface)?;
    let Some(host_version) = host_snapshot_version() else {
        anyhow::bail!("unsupported_version");
    };
    if let Some(version) = params.have.as_ref().and_then(|have| have.snapshot_version)
        && version != host_version
    {
        anyhow::bail!("unsupported_version");
    }
    // A request that names its stream asks that view only.
    let stream = params
        .stream
        .map(|stream| checked_view_stream(mux, client, writer, params.surface, stream))
        .transpose()?;
    let gates = mux.control_clients.snapshot_viewers.gates(client, params.surface, stream);
    if gates.is_empty() {
        anyhow::bail!("not_attached");
    }
    let now = Instant::now();
    let mut outcome = SnapshotAdmission::NotAttached;
    for gate in gates {
        let admission = gate.request(now);
        outcome = match (outcome, admission) {
            (SnapshotAdmission::Accepted, _) | (_, SnapshotAdmission::Accepted) => {
                SnapshotAdmission::Accepted
            }
            (SnapshotAdmission::Collapsed, _) | (_, SnapshotAdmission::Collapsed) => {
                SnapshotAdmission::Collapsed
            }
            (
                SnapshotAdmission::Throttled { retry_after_ms: a },
                SnapshotAdmission::Throttled { retry_after_ms: b },
            ) => SnapshotAdmission::Throttled { retry_after_ms: a.min(b) },
            (SnapshotAdmission::Throttled { retry_after_ms }, _)
            | (_, SnapshotAdmission::Throttled { retry_after_ms }) => {
                SnapshotAdmission::Throttled { retry_after_ms }
            }
            (SnapshotAdmission::NotAttached, SnapshotAdmission::NotAttached) => {
                SnapshotAdmission::NotAttached
            }
        };
    }
    request_reply(outcome, params.surface, params.request_id, params.reason)
}

/// The reply to one request. Every status, including `snapshot_throttled`,
/// echoes `request_id`, so a late reply names the request it answers.
fn request_reply(
    outcome: SnapshotAdmission,
    surface: SurfaceId,
    request_id: Option<String>,
    reason: Option<String>,
) -> anyhow::Result<Value> {
    let mut reply = match outcome {
        SnapshotAdmission::Accepted => json!({"status": "accepted"}),
        SnapshotAdmission::Collapsed => json!({"status": "collapsed"}),
        SnapshotAdmission::Throttled { retry_after_ms } => {
            json!({"status": "snapshot_throttled", "retry_after_ms": retry_after_ms})
        }
        SnapshotAdmission::NotAttached => anyhow::bail!("not_attached"),
    };
    reply.insert("surface", json!(surface));
    if let Some(request_id) = request_id {
        reply.insert("request_id", json!(request_id));
    }
    if let Some(reason) = reason {
        reply.insert("reason", json!(reason));
    }
    Ok(reply)
}

fn base64(bytes: &[u8]) -> String {
    base64::engine::general_purpose::STANDARD.encode(bytes)
}

/// The READY of a local-history resize: no history follows it.
fn local_ready_event(surface: SurfaceId, ready: &LocalReadySnapshot) -> SnapshotEvent<'_> {
    let mut meta = ready_meta(surface, &ready.frame);
    meta.insert("history", json!("local"));
    meta.insert("history_rows", json!(ready.history_rows));
    meta.insert("history_digest", json!(hex(&ready.history_digest)));
    SnapshotEvent::new(ready.frame.offset, meta, ready.frame.data.as_slice())
}

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|byte| format!("{byte:02x}")).collect()
}

fn ready_event(surface: SurfaceId, frame: &TerminalSnapshotFrame) -> SnapshotEvent<'_> {
    SnapshotEvent::new(frame.offset, ready_meta(surface, frame), frame.data.as_slice())
}

fn ready_meta(surface: SurfaceId, frame: &TerminalSnapshotFrame) -> Value {
    json!({
        "event": "snapshot",
        "surface": surface,
        "phase": "ready",
        "generation": frame.generation,
        "offset": frame.offset,
        "version": frame.version,
        "cols": frame.cols,
        "rows": frame.rows,
        "colors": terminal_colors_json(frame.colors, true),
        "marker_epoch": frame.marker_epoch,
        "active_top_marker": frame.active_top_marker,
    })
}

/// The history and the images of one READY still to send.
struct PendingTail {
    generation: u64,
    offset: u64,
    version: u16,
    history: Vec<u8>,
    history_sent: usize,
    history_done: bool,
    images: Option<PendingImages>,
}

impl PendingTail {
    fn of(frame: &mut TerminalSnapshotFrame) -> Self {
        Self {
            generation: frame.generation,
            offset: frame.offset,
            version: frame.version,
            history: std::mem::take(&mut frame.history),
            history_sent: 0,
            history_done: false,
            images: frame.images.take().map(PendingImages::of),
        }
    }

    /// The next chunk event and whether it ends this READY's tail; `None`
    /// when nothing is left. History goes first: a placement above the
    /// active area needs its row.
    fn next_chunk(
        &mut self,
        surface: SurfaceId,
    ) -> std::io::Result<Option<(SnapshotEvent<'_>, bool)>> {
        if !self.history_done {
            let event = self.next_history_chunk(surface)?;
            let done = self.history_done && self.images.is_none();
            return Ok(Some((event, done)));
        }
        let at = (self.generation, self.offset, self.version);
        Ok(self.images.as_mut().and_then(|images| images.next_chunk(surface, at)))
    }

    fn next_history_chunk(
        &mut self,
        surface: SurfaceId,
    ) -> std::io::Result<SnapshotEvent<'static>> {
        let end = self.history_sent.saturating_add(HISTORY_CHUNK_BYTES).min(self.history.len());
        let done = end == self.history.len();
        let raw = self.history.get(self.history_sent..end).unwrap_or_default();
        let packed = deflate(raw)?;
        let meta = json!({
            "event": "snapshot",
            "surface": surface,
            "phase": "history",
            "generation": self.generation,
            "offset": self.offset,
            "version": self.version,
            "compression": "deflate",
            "raw_bytes": raw.len(),
            "done": done,
        });
        self.history_sent = end;
        self.history_done = done;
        Ok(SnapshotEvent::new(self.offset, meta, packed))
    }
}

/// The Kitty replay stream of one READY still to send (shared with the
/// terminal's cache and other viewers).
struct PendingImages {
    data: Arc<SnapshotImages>,
    sent: usize,
    finished: bool,
    skipped_images: u64,
}

impl PendingImages {
    fn of(images: Arc<SnapshotImages>) -> Self {
        let skipped_images = images.stats.skipped_images;
        Self { data: images, sent: 0, finished: false, skipped_images }
    }

    /// The next images chunk and whether it is the last one. The stream is
    /// sent as is: its pixels are already zlib.
    /// `at`: the READY's `(generation, offset, version)`.
    fn next_chunk(
        &mut self,
        surface: SurfaceId,
        at: (u64, u64, u16),
    ) -> Option<(SnapshotEvent<'_>, bool)> {
        let (generation, offset, version) = at;
        if self.finished {
            return None;
        }
        let start = self.sent;
        let end = start.saturating_add(IMAGES_CHUNK_BYTES).min(self.data.data.len());
        let done = end == self.data.data.len();
        let mut meta = json!({
            "event": "snapshot",
            "surface": surface,
            "phase": "images",
            "generation": generation,
            "offset": offset,
            "version": version,
            "done": done,
        });
        if done && self.skipped_images > 0 {
            meta.insert("skipped_images", json!(self.skipped_images));
        }
        self.sent = end;
        self.finished = done;
        let chunk = self.data.data.get(start..end).unwrap_or_default();
        Some((SnapshotEvent::new(offset, meta, chunk), done))
    }
}

/// Raw DEFLATE (RFC 1951, no zlib or gzip framing) at level 1: about 8% of
/// the history at about 0.7 ms per MiB (the 2026-10-04 Testbox measurement).
fn deflate(raw: &[u8]) -> std::io::Result<Vec<u8>> {
    use std::io::Write as _;
    let mut encoder = flate2::write::DeflateEncoder::new(
        Vec::with_capacity(raw.len() / 8),
        flate2::Compression::new(1),
    );
    encoder.write_all(raw)?;
    encoder.finish()
}

/// One line per READY whose images the cap left out.
fn log_skipped_images(surface: SurfaceId, frame: &TerminalSnapshotFrame) {
    if let Some(images) = frame.images.as_ref().filter(|images| images.stats.skipped_images > 0) {
        eprintln!(
            "cmux-tui: surface {surface} snapshot images: {} over the {SNAPSHOT_IMAGES_MAX_BYTES}-byte cap not sent (generation {})",
            images.stats.skipped_images, frame.generation
        );
    }
}

fn digest_json(surface: SurfaceId, digest: &TerminalSnapshotDigest) -> Value {
    let sha256 = hex(&digest.sha256);
    json!({
        "event": "digest",
        "surface": surface,
        "generation": digest.generation,
        "offset": digest.offset,
        "version": digest.version,
        "sha256": sha256,
    })
}

/// The `output`/`colors-changed` event of a snapshot viewer, or `None` for a
/// frame a snapshot viewer never receives (grid changes become snapshots).
fn frame_json(
    surface: SurfaceId,
    frame: &AttachFrame,
    generation: u64,
    offset: u64,
) -> Option<Value> {
    match frame {
        AttachFrame::Output(output) | AttachFrame::FlowOutput { output, .. } => {
            Some(output_json(surface, output, generation, offset, frame.flow(), None))
        }
        AttachFrame::OutputWithColors { output, colors, flow } => {
            Some(output_json(surface, output, generation, offset, *flow, Some(colors)))
        }
        AttachFrame::ColorsChanged(colors) => {
            let mut value = terminal_colors_json(**colors, true);
            value.insert("event", json!("colors-changed"));
            value.insert("surface", json!(surface));
            Some(value)
        }
        AttachFrame::Resized { .. } | AttachFrame::ResizedWithColors { .. } => None,
    }
}

/// One `output` event; `flow` (the key press it echoes)
/// only when it is not 0.
fn output_json(
    surface: SurfaceId,
    output: &[u8],
    generation: u64,
    offset: u64,
    flow: u64,
    colors: Option<&crate::TerminalColors>,
) -> Value {
    let mut value = json!({
        "event": "output", "surface": surface, "data": base64(output),
        "generation": generation, "offset": offset,
    });
    if let Some(colors) = colors {
        value.insert("colors", terminal_colors_json(*colors, true));
    }
    if flow != 0 {
        value.insert("flow", json!(flow));
    }
    value
}

fn frame_output_len(frame: &AttachFrame) -> usize {
    frame.output().map_or(0, <[u8]>::len)
}

impl SnapshotAttachParams {
    /// The byte attach of a snapshot viewer. Mirrors the replay attach in
    /// `server.rs`: mark the client attached, register the queue under the
    /// terminal lock, send the first READY snapshot before the reply, then
    /// start the worker. The view's items go on `outbound_stream`.
    pub(crate) fn attach(
        &self,
        mux: &Arc<Mux>,
        client: u64,
        surface: Arc<Surface>,
        writer: &MessageWriter,
        initial_size: Option<(u16, u16)>,
        outbound_stream: OutboundStream,
    ) -> anyhow::Result<Value> {
        let surface_id = surface.id;
        let lifecycle = AttachLifecycle::default();
        attach(
            mux,
            client,
            surface_id,
            surface,
            writer,
            initial_size,
            lifecycle,
            outbound_stream,
            self.backlog_bytes(),
            self.snapshot_local_history,
            self.images_cap(),
        )
    }
}

#[allow(clippy::too_many_arguments)]
fn attach(
    mux: &Arc<Mux>,
    client: u64,
    surface_id: SurfaceId,
    surface: Arc<Surface>,
    writer: &MessageWriter,
    initial_size: Option<(u16, u16)>,
    lifecycle: AttachLifecycle,
    outbound_stream: OutboundStream,
    backlog: usize,
    local_history: bool,
    images_cap: Option<u64>,
) -> anyhow::Result<Value> {
    let MarkedClientAttach { lease, size_rollback, client_changed, .. } =
        mark_client_attached(mux, client, surface_id, outbound_stream.clone(), initial_size)?;
    let stream = match surface.attach_snapshot_stream(lifecycle.clone(), backlog, local_history) {
        Ok(stream) => stream,
        Err(error) => {
            lifecycle.cancel();
            rollback_failed_attach(mux, client, surface_id, outbound_stream.id, size_rollback);
            return Err(error.into());
        }
    };
    // The first snapshot goes out before the reply. When it cannot be
    // encoded yet (an unfinished escape sequence over the continuation
    // budget), the attach still succeeds and the worker sends it at the next
    // output.
    let mut tail = None;
    let (generation, offset) = match surface.take_viewer_snapshot(&stream.receiver, images_cap) {
        Ok(mut first) => {
            log_skipped_images(surface_id, &first);
            tail = Some(PendingTail::of(&mut first));
            stream.requests.sent(Instant::now());
            let initial = ready_event(surface_id, &first).into_json();
            if let Err(error) = writer.send_initial(&initial, &outbound_stream) {
                handle_attach_send_error(&lifecycle, &error);
                rollback_failed_attach(mux, client, surface_id, outbound_stream.id, size_rollback);
                return Err(error.into());
            }
            (first.generation, first.offset)
        }
        Err(_) => {
            stream.receiver.defer_snapshot();
            stream.requests.sent(Instant::now());
            surface.snapshot_stream_position().unwrap_or_default()
        }
    };
    // The viewer's drain on the sequenced pool takes the notifications too.
    mux.control_clients.snapshot_viewers.register(
        client,
        surface_id,
        outbound_stream.id,
        stream.requests.clone(),
    );
    let worker = SnapshotWorker {
        mux: mux.clone(),
        client,
        surface_id,
        surface,
        writer: writer.clone(),
        outbound_stream,
        receiver: Arc::new(stream.receiver),
        lifecycle: stream.lifecycle,
        gate: stream.requests,
        generation,
        offset,
        tail,
        images_cap,
        digest_at: None,
    };
    snapshot_attach_out::start(
        worker,
        AttachCommit { lifecycle, changed: client_changed, size_rollback },
    )?;
    Ok(super::attach_response(mux, surface_id, client, lease))
}

#[cfg(test)]
#[path = "terminal_snapshot_tests.rs"]
mod tests;

#[cfg(test)]
#[path = "snapshot_frames_tests.rs"]
mod snapshot_frames_tests;

#[cfg(all(test, unix))]
#[path = "terminal_snapshot_socket_tests.rs"]
mod socket_tests;
