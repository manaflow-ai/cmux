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
//! compressed alone as raw DEFLATE (level 1) on the worker thread, outside
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
//! `snapshot-request {surface, reason?, have?, request_id?}` is the raw v12
//! form of the channel message `snapshot_request` (sync-and-transport.md):
//! requests collapse while a snapshot is pending, and a viewer gets at most
//! one requested snapshot per 500 ms (`snapshot_throttled {retry_after_ms}`).
//! A channel transport maps its message onto [`handle_request`].

use std::collections::HashMap;
use std::sync::{Arc, Mutex};
use std::time::Instant;

use base64::Engine as _;
use serde::Deserialize;
use serde_json::{Value, json};

use super::{
    AttachWorkerCommit, MarkedClientAttach, MessageWriter, OutboundStream,
    commit_client_attach_and_start_worker, detach_committed_attach, get_surface,
    mark_client_attached, require_pty, rollback_failed_attach, spawn_attach_notification_stream,
    terminal_colors_json,
};
use crate::stream_interrupt::StreamInterrupt;
use crate::surface::snapshot_attach::{
    DEFAULT_VIEWER_BACKLOG_BYTES, LocalReadySnapshot, SNAPSHOT_DIGEST_IDLE, SnapshotAdmission,
    SnapshotRequestGate, TerminalSnapshotDigest, TerminalSnapshotFrame,
};
use crate::surface::{AttachFrame, AttachFrameReceiver, AttachLifecycle, ViewerEvent};
use crate::{Mux, Surface, SurfaceId};

pub const TERMINAL_SNAPSHOT_CAPABILITY: &str = "terminal-snapshot-v1";
/// READY is followed by its history chunks (scrollback, then FINISH).
pub const TERMINAL_SNAPSHOT_HISTORY_CAPABILITY: &str = "terminal-snapshot-history-v1";
/// A resize reaches an opted-in viewer as a READY without history.
pub const TERMINAL_SNAPSHOT_LOCAL_HISTORY_CAPABILITY: &str = "terminal-snapshot-local-history-v1";
/// Largest uncompressed history chunk. Its compressed base64 stays far under
/// the per-stream outbound byte cap with a live frame pending.
pub(crate) const HISTORY_CHUNK_BYTES: usize = 1 << 20;
/// The only snapshot encoding the host speaks.
pub const SNAPSHOT_ENCODING_GHOSTSNP: &str = "ghostsnp";

/// Snapshot fields of `attach-surface`.
#[derive(Debug, Default, Deserialize)]
pub(crate) struct SnapshotAttachParams {
    #[serde(default)]
    snapshot: Option<String>,
    #[serde(default)]
    snapshot_version: Option<u16>,
    /// The viewer's backlog cap (default 8 MiB, no daemon setting), clamped to
    /// [`MIN_VIEWER_BACKLOG_BYTES`, `MAX_VIEWER_BACKLOG_BYTES`].
    #[serde(default)]
    viewer_backlog_bytes: Option<usize>,
    /// The viewer reflows its own history at a resize
    /// (`terminal-snapshot-local-history-v1`). Only meaningful with
    /// `snapshot`.
    #[serde(default)]
    snapshot_local_history: bool,
}

pub(crate) const MIN_VIEWER_BACKLOG_BYTES: usize = 64 * 1024;
/// One merged output frame of this size stays under the per-stream outbound
/// cap after base64 even with a second frame pending.
pub(crate) const MAX_VIEWER_BACKLOG_BYTES: usize = 8 * 1024 * 1024;

impl SnapshotAttachParams {
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

/// `snapshot-request` (raw v12) and channel `snapshot_request`.
#[derive(Debug, Deserialize)]
pub(crate) struct SnapshotRequestParams {
    surface: SurfaceId,
    /// `digest_mismatch | gap | generation_mismatch | attach`; informational.
    #[serde(default)]
    reason: Option<String>,
    #[serde(default)]
    have: Option<SnapshotHave>,
    /// Idempotency per viewer connection: a repeat while a snapshot is
    /// pending collapses into it.
    #[serde(default)]
    request_id: Option<String>,
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
            .unwrap()
            .entry((client, surface))
            .or_default()
            .push(RegisteredViewer { stream, gate });
    }

    fn unregister(&self, client: u64, surface: SurfaceId, stream: u64) {
        let mut viewers = self.viewers.lock().unwrap();
        if let Some(list) = viewers.get_mut(&(client, surface)) {
            list.retain(|viewer| viewer.stream != stream);
            if list.is_empty() {
                viewers.remove(&(client, surface));
            }
        }
    }

    fn gates(&self, client: u64, surface: SurfaceId) -> Vec<SnapshotRequestGate> {
        self.viewers
            .lock()
            .unwrap()
            .get(&(client, surface))
            .map(|list| list.iter().map(|viewer| viewer.gate.clone()).collect())
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
    let gates = mux.control_clients.snapshot_viewers.gates(client, params.surface);
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
    reply["surface"] = json!(surface);
    if let Some(request_id) = request_id {
        reply["request_id"] = json!(request_id);
    }
    if let Some(reason) = reason {
        reply["reason"] = json!(reason);
    }
    Ok(reply)
}

fn base64(bytes: &[u8]) -> String {
    base64::engine::general_purpose::STANDARD.encode(bytes)
}

/// The READY of a local-history resize: no history follows it.
fn local_snapshot_json(surface: SurfaceId, ready: &LocalReadySnapshot) -> Value {
    let mut value = snapshot_json(surface, &ready.frame);
    value["history"] = json!("local");
    value["history_rows"] = json!(ready.history_rows);
    value["history_digest"] = json!(hex(&ready.history_digest));
    value
}

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|byte| format!("{byte:02x}")).collect()
}

fn snapshot_json(surface: SurfaceId, frame: &TerminalSnapshotFrame) -> Value {
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
        "data": base64(&frame.data),
    })
}

/// The history of one READY still to send.
struct PendingHistory {
    generation: u64,
    offset: u64,
    version: u16,
    data: Vec<u8>,
    sent: usize,
}

impl PendingHistory {
    fn of(frame: &mut TerminalSnapshotFrame) -> Self {
        Self {
            generation: frame.generation,
            offset: frame.offset,
            version: frame.version,
            data: std::mem::take(&mut frame.history),
            sent: 0,
        }
    }

    /// The next chunk event, and whether it is the last one.
    fn next_chunk(&mut self, surface: SurfaceId) -> std::io::Result<(Value, bool)> {
        let end = (self.sent + HISTORY_CHUNK_BYTES).min(self.data.len());
        let done = end == self.data.len();
        let raw = &self.data[self.sent..end];
        let packed = deflate(raw)?;
        let value = json!({
            "event": "snapshot",
            "surface": surface,
            "phase": "history",
            "generation": self.generation,
            "offset": self.offset,
            "version": self.version,
            "compression": "deflate",
            "raw_bytes": raw.len(),
            "data": base64(&packed),
            "done": done,
        });
        self.sent = end;
        Ok((value, done))
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
        AttachFrame::Output(output) => Some(json!({
            "event": "output", "surface": surface, "data": base64(output),
            "generation": generation, "offset": offset,
        })),
        AttachFrame::OutputWithColors { output, colors } => Some(json!({
            "event": "output", "surface": surface, "data": base64(output),
            "generation": generation, "offset": offset,
            "colors": terminal_colors_json(**colors, true),
        })),
        AttachFrame::ColorsChanged(colors) => {
            let mut value = terminal_colors_json(**colors, true);
            value["event"] = json!("colors-changed");
            value["surface"] = json!(surface);
            Some(value)
        }
        AttachFrame::Resized { .. } | AttachFrame::ResizedWithColors { .. } => None,
    }
}

fn frame_output_len(frame: &AttachFrame) -> usize {
    match frame {
        AttachFrame::Output(output) | AttachFrame::OutputWithColors { output, .. } => output.len(),
        _ => 0,
    }
}

/// Everything the attach worker needs.
struct SnapshotWorker {
    mux: Arc<Mux>,
    client: u64,
    surface_id: SurfaceId,
    surface: Arc<Surface>,
    writer: MessageWriter,
    outbound_stream: OutboundStream,
    receiver: AttachFrameReceiver,
    lifecycle: AttachLifecycle,
    gate: SnapshotRequestGate,
    generation: u64,
    offset: u64,
    /// History of the last READY not yet sent; a newer READY replaces it.
    history: Option<PendingHistory>,
}

impl SnapshotWorker {
    fn send(&self, value: &Value) -> bool {
        match self.writer.send_stream_backpressured(value, &self.outbound_stream) {
            Ok(()) => true,
            Err(error) => {
                handle_attach_send_error(&self.lifecycle, &error);
                false
            }
        }
    }

    fn send_snapshot(&mut self) -> bool {
        match self.surface.take_viewer_snapshot(&self.receiver) {
            Ok(mut frame) => {
                self.gate.sent(Instant::now());
                self.generation = frame.generation;
                self.offset = frame.offset;
                // The older READY's history no longer applies: drop it.
                self.history = Some(PendingHistory::of(&mut frame));
                self.send(&snapshot_json(self.surface_id, &frame))
            }
            Err(_) => {
                // The unfinished escape sequence is longer than the snapshot
                // continuation budget: retry at the next output; the viewer
                // stays attached.
                self.receiver.defer_snapshot();
                self.gate.sent(Instant::now());
                true
            }
        }
    }

    /// A local-history READY at a resize cut. It continues the viewer's
    /// stream only when the viewer holds a complete history to reflow and
    /// every byte before the cut; otherwise the viewer gets a READY with
    /// history at a new cut.
    fn send_local_ready(&mut self, ready: &LocalReadySnapshot) -> bool {
        if self.history.is_some() || self.offset != ready.frame.offset {
            return self.send_snapshot();
        }
        self.generation = ready.frame.generation;
        self.send(&local_snapshot_json(self.surface_id, ready))
    }

    /// One history chunk; the last one ends the pending history. A chunk
    /// that cannot be compressed ends this READY's history; the viewer stays
    /// attached and its next READY brings a complete history.
    fn send_history_chunk(&mut self) -> bool {
        let Some(history) = self.history.as_mut() else { return true };
        match history.next_chunk(self.surface_id) {
            Ok((value, done)) => {
                if done {
                    self.history = None;
                }
                self.send(&value)
            }
            Err(error) => {
                eprintln!(
                    "cmux-tui: surface {} snapshot history not sent (generation {}): {error}",
                    self.surface_id, history.generation
                );
                self.history = None;
                true
            }
        }
    }

    /// Block on the viewer's queue; the only timed wait is the one-shot idle
    /// digest deadline set by the last output. While history is pending the
    /// queue is only polled: a queued event goes first, else one chunk.
    fn run(mut self) {
        let interrupt = StreamInterrupt::new();
        self.writer.register_interrupt(&interrupt);
        self.outbound_stream.register_interrupt(&interrupt);
        self.lifecycle.register_interrupt(&interrupt);
        self.receiver.wake_on(&interrupt);
        let mut digest_at: Option<Instant> = None;
        while self.writer.is_open()
            && self.outbound_stream.is_open()
            && !self.lifecycle.is_canceled()
        {
            let deadline = if self.history.is_some() { Some(Instant::now()) } else { digest_at };
            let event = self.receiver.recv_viewer_event(&interrupt, deadline);
            let sent = match event {
                Ok(ViewerEvent::Snapshot) => {
                    digest_at = None;
                    self.send_snapshot()
                }
                Ok(ViewerEvent::LocalReady(ready)) => {
                    digest_at = None;
                    self.send_local_ready(&ready)
                }
                Ok(ViewerEvent::Frame(frame)) => {
                    self.offset += frame_output_len(&frame) as u64;
                    if frame_output_len(&frame) > 0 {
                        digest_at = Some(Instant::now() + SNAPSHOT_DIGEST_IDLE);
                    }
                    match frame_json(self.surface_id, &frame, self.generation, self.offset) {
                        Some(value) => self.send(&value),
                        None => true,
                    }
                }
                Err(std::sync::mpsc::RecvTimeoutError::Timeout) if self.history.is_some() => {
                    self.send_history_chunk()
                }
                Err(std::sync::mpsc::RecvTimeoutError::Timeout) => {
                    if digest_at.is_some_and(|deadline| Instant::now() >= deadline) {
                        digest_at = None;
                        match self.surface.snapshot_digest() {
                            // Output that arrived after the queue emptied
                            // reaches this viewer next; a digest at an offset
                            // it has not reached would be a false mismatch.
                            Ok(digest)
                                if (digest.generation, digest.offset)
                                    == (self.generation, self.offset) =>
                            {
                                self.send(&digest_json(self.surface_id, &digest))
                            }
                            Ok(_) | Err(_) => true,
                        }
                    } else {
                        true
                    }
                }
                Err(std::sync::mpsc::RecvTimeoutError::Disconnected) => {
                    self.lifecycle.cancel();
                    if self.writer.is_open() {
                        let _ = self.writer.send_stream_backpressured(
                            &json!({"event": "detached", "surface": self.surface_id}),
                            &self.outbound_stream,
                        );
                    }
                    break;
                }
            };
            if !sent {
                break;
            }
        }
        report_attach_overflow(
            &self.writer,
            self.surface_id,
            &self.lifecycle,
            &self.outbound_stream,
        );
        self.mux.control_clients.snapshot_viewers.unregister(
            self.client,
            self.surface_id,
            self.outbound_stream.id,
        );
        detach_committed_attach(&self.mux, self.client, self.surface_id, self.outbound_stream.id);
    }
}

impl SnapshotAttachParams {
    /// The byte attach of a snapshot viewer. Mirrors the replay attach in
    /// `server.rs`: mark the client attached, register the queue under the
    /// terminal lock, send the first READY snapshot before the reply, then
    /// start the worker.
    pub(crate) fn attach(
        &self,
        mux: &Arc<Mux>,
        client: u64,
        surface: Arc<Surface>,
        writer: &MessageWriter,
        initial_size: Option<(u16, u16)>,
    ) -> anyhow::Result<Value> {
        let surface_id = surface.id;
        let lifecycle = AttachLifecycle::default();
        let outbound_stream = writer.start_stream(&attach_overflow_json(surface_id))?;
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
    let mut history = None;
    let (generation, offset) = match surface.take_viewer_snapshot(&stream.receiver) {
        Ok(mut first) => {
            history = Some(PendingHistory::of(&mut first));
            stream.requests.sent(Instant::now());
            let initial = snapshot_json(surface_id, &first);
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
    if let Err(error) = spawn_attach_notification_stream(
        mux.clone(),
        surface_id,
        writer.clone(),
        lifecycle.clone(),
        outbound_stream.clone(),
    ) {
        lifecycle.cancel();
        rollback_failed_attach(mux, client, surface_id, outbound_stream.id, size_rollback);
        return Err(error.into());
    }
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
        outbound_stream: outbound_stream.clone(),
        receiver: stream.receiver,
        lifecycle: stream.lifecycle,
        gate: stream.requests,
        generation,
        offset,
        history,
    };
    let (worker_start, worker_committed) = std::sync::mpsc::sync_channel(1);
    let spawned =
        std::thread::Builder::new().name("mux-snapshot-attach-out".into()).spawn(move || {
            if worker_committed.recv().is_ok() {
                worker.run();
            } else {
                worker.mux.control_clients.snapshot_viewers.unregister(
                    worker.client,
                    worker.surface_id,
                    worker.outbound_stream.id,
                );
            }
        });
    if let Err(error) = spawned {
        lifecycle.cancel();
        mux.control_clients.snapshot_viewers.unregister(client, surface_id, outbound_stream.id);
        rollback_failed_attach(mux, client, surface_id, outbound_stream.id, size_rollback);
        return Err(error.into());
    }
    commit_client_attach_and_start_worker(
        mux,
        client,
        surface_id,
        outbound_stream.id,
        AttachWorkerCommit {
            start: worker_start,
            lifecycle,
            changed: client_changed,
            size_rollback,
        },
    )?;
    Ok(super::attach_response(mux, surface_id, client, lease))
}

pub(super) fn report_attach_overflow(
    writer: &MessageWriter,
    surface_id: SurfaceId,
    lifecycle: &AttachLifecycle,
    outbound_stream: &OutboundStream,
) {
    if lifecycle.claim_overflow_report() {
        let _ = writer.send_terminal(&attach_overflow_json(surface_id), outbound_stream);
    }
}

pub(super) fn handle_attach_send_error(lifecycle: &AttachLifecycle, error: &std::io::Error) {
    if error.kind() == std::io::ErrorKind::WouldBlock {
        lifecycle.mark_overflow();
    } else {
        lifecycle.cancel();
    }
}

pub(super) fn attach_overflow_json(surface: SurfaceId) -> Value {
    json!({
        "event": "overflow",
        "scope": "surface",
        "surface": surface,
        "error": "surface stream fell behind; reattach the surface",
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn snapshot_throttled_reply_names_its_request() {
        let reply = request_reply(
            SnapshotAdmission::Throttled { retry_after_ms: 120 },
            7,
            Some("req-42".into()),
            Some("digest_mismatch".into()),
        )
        .unwrap();
        assert_eq!(
            reply,
            json!({
                "status": "snapshot_throttled",
                "retry_after_ms": 120,
                "surface": 7,
                "request_id": "req-42",
                "reason": "digest_mismatch",
            })
        );
        let collapsed =
            request_reply(SnapshotAdmission::Collapsed, 7, Some("req-43".into()), None).unwrap();
        assert_eq!(collapsed["request_id"], "req-43");
        assert!(request_reply(SnapshotAdmission::NotAttached, 7, None, None).is_err());
    }

    #[test]
    fn snapshot_request_accepts_only_spec_reasons_and_bounded_ids() {
        let request =
            |value: Value| -> SnapshotRequestParams { serde_json::from_value(value).unwrap() };
        assert!(validate_request(&request(json!({"surface": 1}))).is_ok());
        for reason in SNAPSHOT_REQUEST_REASONS {
            assert!(validate_request(&request(json!({"surface": 1, "reason": reason}))).is_ok());
        }
        assert!(validate_request(&request(json!({"surface": 1, "reason": "because"}))).is_err());
        let long = "x".repeat(MAX_REQUEST_ID_BYTES + 1);
        assert!(validate_request(&request(json!({"surface": 1, "request_id": long}))).is_err());
        let ok = "x".repeat(MAX_REQUEST_ID_BYTES);
        assert!(validate_request(&request(json!({"surface": 1, "request_id": ok}))).is_ok());
    }

    #[test]
    fn snapshot_attach_params_fall_back_on_another_version() {
        let ours = ghostty_vt::snapshot_version();
        let params: SnapshotAttachParams =
            serde_json::from_value(json!({"snapshot": "ghostsnp", "snapshot_version": ours}))
                .unwrap();
        assert!(params.wants_snapshot().unwrap());
        assert_eq!(params.backlog_bytes(), DEFAULT_VIEWER_BACKLOG_BYTES);
        let other: SnapshotAttachParams = serde_json::from_value(
            json!({"snapshot": "ghostsnp", "snapshot_version": ours.wrapping_add(1)}),
        )
        .unwrap();
        assert!(!other.wants_snapshot().unwrap());
        let unknown: SnapshotAttachParams =
            serde_json::from_value(json!({"snapshot": "png"})).unwrap();
        assert!(unknown.wants_snapshot().is_err());
        let tiny: SnapshotAttachParams =
            serde_json::from_value(json!({"viewer_backlog_bytes": 1})).unwrap();
        assert_eq!(tiny.backlog_bytes(), MIN_VIEWER_BACKLOG_BYTES);
    }
}

#[cfg(all(test, unix))]
#[path = "terminal_snapshot_socket_tests.rs"]
mod socket_tests;
