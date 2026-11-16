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
//! Kitty images are part of the snapshot itself: since the ghostty-next sync
//! of #35478 (upstream c7f68a7f4), GHOSTSNP carries each screen's images and
//! placements (KITTY_IMAGE_STORAGE, before READY), their pixels
//! (KITTY_IMAGE_PAYLOAD, after READY) and the placements pinned to history
//! pages (KITTY_IMAGE_PAGE_PLACEMENTS), so READY plus its history restores
//! them and the pixels have the priority of history. The images phase of the
//! former `terminal-snapshot-images-v1` sent the same image a second time and
//! is gone; the host no longer advertises it, and `snapshot_images` from an
//! older viewer is accepted and ignored.
//!
//! `snapshot-request {surface, reason?, have?, request_id?}` is the raw v12
//! form of the channel message `snapshot_request` (sync-and-transport.md):
//! requests collapse while a snapshot is pending, and a viewer gets at most
//! one requested snapshot per 500 ms (`snapshot_throttled {retry_after_ms}`;
//! the throttled request still gets its READY when the interval ends).
//! A channel transport maps its message onto [`handle_request`].

use crate::panic_free::JsonFields;
use crate::panic_free::RecoverPoison;
use std::collections::HashMap;
use std::sync::{Arc, Mutex};
use std::time::Instant;

use base64::Engine as _;
use serde::Deserialize;
use serde_json::{Value, json};

use super::{
    AttachWorkerCommit, MarkedClientAttach, MessageWriter, OutboundStream,
    commit_client_attach_and_start_worker, detach_committed_attach, get_surface,
    mark_client_attached, require_pty, rollback_failed_attach,
    spawn_attach_notification_stream_gated, terminal_colors_json,
};
use crate::stream_interrupt::StreamInterrupt;
use crate::surface::snapshot_attach::{
    DEFAULT_VIEWER_BACKLOG_BYTES, LocalReadySnapshot, SNAPSHOT_DIGEST_IDLE, SnapshotAdmission,
    SnapshotRequestGate, TerminalSnapshotDigest, TerminalSnapshotFrame,
};
use crate::surface::{AttachFrame, AttachFrameReceiver, AttachLifecycle, ViewerEvent};
use crate::{Mux, Surface, SurfaceId};

pub const TERMINAL_SNAPSHOT_CAPABILITY: &str = "terminal-snapshot-v1";
/// `set-attach-visibility`: a snapshot viewer that does not show its terminal gets output once per wall-clock second.
pub const ATTACH_VISIBILITY_CAPABILITY: &str = "attach-visibility-v1";
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
    /// Wire field of the former `terminal-snapshot-images-v1`, kept so the
    /// request schema stays the same (removing a member needs an api-compat
    /// revision). Ignored: GHOSTSNP carries the Kitty images itself.
    #[serde(default)]
    #[allow(dead_code)]
    snapshot_images: bool,
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

/// `set-attach-visibility` (`attach-visibility-v1`): the caller's snapshot attach of `surface` shows the terminal
/// (`visible`) or not. A hidden viewer gets its output once per wall-clock second (all hidden viewers of the daemon on
/// the same second, as Chrome aligns a hidden page's timers), at once past a byte cap, before any snapshot, and at once
/// when it is shown again.
#[derive(Debug, Deserialize)]
pub(crate) struct AttachVisibilityParams {
    pub(super) surface: SurfaceId,
    pub(super) visible: bool,
}

/// `set-attach-visibility`: `{viewers}` reached; 0 when the caller has no snapshot attach of the surface.
pub(crate) fn set_visibility(
    mux: &Arc<Mux>,
    client: u64,
    params: AttachVisibilityParams,
) -> anyhow::Result<Value> {
    let viewers =
        mux.control_clients.snapshot_viewers.set_visible(client, params.surface, params.visible);
    Ok(json!({"viewers": viewers}))
}

/// `snapshot-request` (raw v12) and channel `snapshot_request`.
#[derive(Debug, Deserialize)]
pub(crate) struct SnapshotRequestParams {
    pub(super) surface: SurfaceId,
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

    /// `set-attach-visibility`: every snapshot viewer of `surface` on `client` shows the terminal or not. Returns how
    /// many viewers it reached.
    pub(super) fn set_visible(&self, client: u64, surface: SurfaceId, visible: bool) -> usize {
        self.gates(client, surface).iter().filter(|gate| gate.set_visible(visible)).count()
    }

    fn gates(&self, client: u64, surface: SurfaceId) -> Vec<SnapshotRequestGate> {
        self.viewers
            .lock()
            .recover_poison()
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
fn local_snapshot_json(surface: SurfaceId, ready: &LocalReadySnapshot) -> Value {
    let mut value = snapshot_json(surface, &ready.frame);
    value.insert("history", json!("local"));
    value.insert("history_rows", json!(ready.history_rows));
    value.insert("history_digest", json!(hex(&ready.history_digest)));
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
struct PendingTail {
    generation: u64,
    offset: u64,
    version: u16,
    history: Vec<u8>,
    history_sent: usize,
    history_done: bool,
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
        }
    }

    /// The next chunk event and whether it ends this READY's tail; `None`
    /// when nothing is left.
    fn next_chunk(&mut self, surface: SurfaceId) -> std::io::Result<Option<(Value, bool)>> {
        if self.history_done {
            return Ok(None);
        }
        let value = self.next_history_chunk(surface)?;
        Ok(Some((value, self.history_done)))
    }

    fn next_history_chunk(&mut self, surface: SurfaceId) -> std::io::Result<Value> {
        let end = self.history_sent.saturating_add(HISTORY_CHUNK_BYTES).min(self.history.len());
        let done = end == self.history.len();
        let raw = self.history.get(self.history_sent..end).unwrap_or_default();
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
        self.history_sent = end;
        self.history_done = done;
        Ok(value)
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
    tail: Option<PendingTail>,
    /// Output held while the viewer is hidden (`set-attach-visibility`), sent as one `output` event.
    hidden_batch: Vec<u8>,
}

/// A hidden viewer's batch goes out at once past this many bytes (a hidden `yes` stays bounded).
const HIDDEN_BATCH_MAX_BYTES: usize = 256 << 10;

/// The next whole wall-clock second as an `Instant`: every hidden viewer of the daemon flushes on the same second, as
/// Chrome aligns a hidden page's timers to whole seconds, so their wakeups coalesce.
fn next_aligned_second() -> Instant {
    let into = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|since| since.subsec_nanos())
        .unwrap_or(0);
    Instant::now() + std::time::Duration::from_nanos(1_000_000_000 - u64::from(into))
}

impl SnapshotWorker {
    /// Sends the hidden batch as one `output` event (its offset is the position after its last byte).
    fn flush_hidden_batch(&mut self) -> bool {
        if self.hidden_batch.is_empty() {
            return true;
        }
        let bytes = std::mem::take(&mut self.hidden_batch);
        self.send_output(&bytes, None)
    }

    /// Send one `output` event at the viewer's position.
    fn send_output(&self, output: &[u8], colors: Option<&Value>) -> bool {
        match self.writer.send_snapshot_output_backpressured(
            self.surface_id,
            output,
            (self.generation, self.offset),
            colors,
            &self.outbound_stream,
        ) {
            Ok(()) => true,
            Err(error) => {
                handle_attach_send_error(&self.lifecycle, &error);
                false
            }
        }
    }

    /// Send `frame` as the event a snapshot viewer gets for it (none for a
    /// grid change, which becomes a snapshot).
    fn send_frame(&self, frame: &AttachFrame) -> bool {
        match frame {
            AttachFrame::Output(output) => self.send_output(output, None),
            AttachFrame::OutputWithColors { output, colors } => {
                self.send_output(output, Some(&terminal_colors_json(**colors, true)))
            }
            AttachFrame::ColorsChanged(colors) => {
                let mut value = terminal_colors_json(**colors, true);
                value.insert("event", json!("colors-changed"));
                value.insert("surface", json!(self.surface_id));
                self.send(&value)
            }
            AttachFrame::Resized { .. } | AttachFrame::ResizedWithColors { .. } => true,
        }
    }

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
                // The older READY's history no longer applies.
                self.tail = Some(PendingTail::of(&mut frame));
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
        // A viewer still owed the history of an older READY has none to reflow.
        if self.tail.is_some() || self.offset != ready.frame.offset {
            return self.send_snapshot();
        }
        self.generation = ready.frame.generation;
        self.send(&local_snapshot_json(self.surface_id, ready))
    }

    /// One history chunk; the last one ends the pending tail. A history
    /// chunk that cannot be compressed ends this READY's tail; the viewer
    /// stays attached and its next READY brings a complete history.
    fn send_tail_chunk(&mut self) -> bool {
        let Some(tail) = self.tail.as_mut() else { return true };
        match tail.next_chunk(self.surface_id) {
            Ok(Some((value, done))) => {
                if done {
                    self.tail = None;
                }
                self.send(&value)
            }
            Ok(None) => {
                self.tail = None;
                true
            }
            Err(error) => {
                eprintln!(
                    "cmux-tui: surface {} snapshot history not sent (generation {}): {error}",
                    self.surface_id, tail.generation
                );
                self.tail = None;
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
        // The aligned second a hidden batch goes out at (`set-attach-visibility`).
        let mut batch_at: Option<Instant> = None;
        while self.writer.is_open()
            && self.outbound_stream.is_open()
            && !self.lifecycle.is_canceled()
        {
            // Shown again, or the second is up: what waits goes out now.
            let due = batch_at.is_some_and(|at| Instant::now() >= at);
            if !self.hidden_batch.is_empty() && (due || !self.gate.is_hidden()) {
                batch_at = None;
                if !self.flush_hidden_batch() {
                    break;
                }
                digest_at = Some(Instant::now() + SNAPSHOT_DIGEST_IDLE);
            }
            // A throttled snapshot request whose interval ended: its READY is
            // the next event (``SnapshotRequestGate::fire_deferred``).
            self.gate.fire_deferred(Instant::now());
            // A hidden viewer's digest waits for the batch it would describe.
            let digest = if self.hidden_batch.is_empty() { digest_at } else { None };
            let deadline = if self.tail.is_some() {
                Some(Instant::now())
            } else {
                [digest, batch_at, self.gate.deferred_at()].into_iter().flatten().min()
            };
            let event = self.receiver.recv_viewer_event(&interrupt, deadline);
            let sent = match event {
                // A snapshot or a READY follows every byte before it: the batch goes first.
                Ok(ViewerEvent::Snapshot) => {
                    digest_at = None;
                    batch_at = None;
                    self.flush_hidden_batch() && self.send_snapshot()
                }
                Ok(ViewerEvent::LocalReady(ready)) => {
                    digest_at = None;
                    batch_at = None;
                    self.flush_hidden_batch() && self.send_local_ready(&ready)
                }
                Ok(ViewerEvent::Frame(AttachFrame::Output(output))) if self.gate.is_hidden() => {
                    // Hidden: the bytes join the batch, which goes out on the aligned second or past its cap.
                    // The idle digest follows them whichever flush sends them (it waits while bytes are batched).
                    self.offset += output.len() as u64;
                    self.hidden_batch.extend_from_slice(&output);
                    if !output.is_empty() {
                        digest_at = Some(Instant::now() + SNAPSHOT_DIGEST_IDLE);
                    }
                    if self.hidden_batch.len() >= HIDDEN_BATCH_MAX_BYTES {
                        batch_at = None;
                        self.flush_hidden_batch()
                    } else {
                        batch_at.get_or_insert_with(next_aligned_second);
                        true
                    }
                }
                Ok(ViewerEvent::Frame(frame)) => {
                    // Any other frame keeps stream order: the batch goes first.
                    batch_at = None;
                    let flushed = self.flush_hidden_batch();
                    self.offset += frame_output_len(&frame) as u64;
                    if frame_output_len(&frame) > 0 {
                        digest_at = Some(Instant::now() + SNAPSHOT_DIGEST_IDLE);
                    }
                    flushed && self.send_frame(&frame)
                }
                Err(std::sync::mpsc::RecvTimeoutError::Timeout) if self.tail.is_some() => {
                    self.send_tail_chunk()
                }
                Err(std::sync::mpsc::RecvTimeoutError::Timeout) => {
                    // A digest names the viewer's position: never one past bytes still in its batch.
                    if self.hidden_batch.is_empty()
                        && digest_at.is_some_and(|deadline| Instant::now() >= deadline)
                    {
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
                    // The terminal's last output reaches the viewer before its end.
                    let _ = self.flush_hidden_batch();
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
    let mut tail = None;
    let (generation, offset) = match surface.take_viewer_snapshot(&stream.receiver) {
        Ok(mut first) => {
            tail = Some(PendingTail::of(&mut first));
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
    if let Err(error) = spawn_attach_notification_stream_gated(
        mux.clone(),
        surface_id,
        writer.clone(),
        lifecycle.clone(),
        outbound_stream.clone(),
        Some(stream.requests.clone()),
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
        tail,
        hidden_batch: Vec::new(),
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

    /// The JSON value the worker built for each event before it wrote
    /// `output` events straight into the outbound buffer.
    fn frame_json_reference(
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
                value.insert("event", json!("colors-changed"));
                value.insert("surface", json!(surface));
                Some(value)
            }
            AttachFrame::Resized { .. } | AttachFrame::ResizedWithColors { .. } => None,
        }
    }

    /// Serializing one 64 KiB `output` event: the value path against the
    /// direct writer. Run on the fleet:
    /// `cargo test -p cmux-tui-core --release --lib snapshot_output_event_bench -- --ignored --nocapture`
    #[test]
    #[ignore = "bench"]
    fn snapshot_output_event_bench() {
        let service = crate::server::RenderService::new();
        let output: Vec<u8> = (0..64 * 1024).map(|index| (index % 251) as u8).collect();
        let frame = AttachFrame::Output(output.clone());
        let rounds = 2_000u32;
        let start = Instant::now();
        for round in 0..rounds {
            let value = frame_json_reference(1, &frame, 1, u64::from(round)).unwrap();
            std::hint::black_box(service.serialize(&value).unwrap());
        }
        let value_path = start.elapsed() / rounds;
        let start = Instant::now();
        for round in 0..rounds {
            std::hint::black_box(
                service.serialize_snapshot_output(1, &output, 1, u64::from(round), None).unwrap(),
            );
        }
        let direct = start.elapsed() / rounds;
        println!("SNAPSHOT-OUTPUT-BENCH 64KiB value_path={value_path:?} direct={direct:?}");
    }

    /// A snapshot viewer's `output` event is byte-identical to the line the
    /// worker serialized from a JSON value: every base64 padding length,
    /// binary bytes, an empty chunk, large offsets, with and without colors.
    #[test]
    fn snapshot_output_events_match_the_value_serialization() {
        let service = crate::server::RenderService::new();
        let colors = crate::TerminalColors {
            fg_override: Some(ghostty_vt::Rgb { r: 1, g: 2, b: 3 }),
            ..crate::TerminalColors::default()
        };
        let outputs: Vec<Vec<u8>> = vec![
            Vec::new(),
            b"a".to_vec(),
            b"ab".to_vec(),
            b"abc".to_vec(),
            (0..=255u8).collect(),
            b"\x1b[31m\"quoted\" \\ back\x1b[0m\r\n".repeat(400),
        ];
        for output in outputs {
            for (generation, offset) in [(0, 0), (7, 1 << 40), (u64::MAX, u64::MAX)] {
                let frames = [
                    AttachFrame::Output(output.clone()),
                    AttachFrame::OutputWithColors {
                        output: output.clone(),
                        colors: Box::new(colors),
                    },
                ];
                for frame in frames {
                    let value = frame_json_reference(42, &frame, generation, offset).unwrap();
                    let expected = service.serialize(&value).unwrap();
                    let with_colors = match &frame {
                        AttachFrame::OutputWithColors { colors, .. } => {
                            Some(terminal_colors_json(**colors, true))
                        }
                        _ => None,
                    };
                    let written = service
                        .serialize_snapshot_output(
                            42,
                            &output,
                            generation,
                            offset,
                            with_colors.as_ref(),
                        )
                        .unwrap();
                    assert_eq!(written.as_bytes(), expected.as_bytes());
                }
            }
        }
    }

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
        let older: SnapshotAttachParams = serde_json::from_value(
            json!({"snapshot": "ghostsnp", "snapshot_version": ours, "snapshot_images": true}),
        )
        .unwrap();
        assert!(older.wants_snapshot().unwrap(), "an older viewer's snapshot_images still parses");
    }
}

#[cfg(all(test, unix))]
#[path = "terminal_snapshot_socket_tests.rs"]
mod socket_tests;
