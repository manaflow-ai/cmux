//! Snapshot attach for byte viewers (capability `terminal-snapshot-v1`,
//! spec/terminal-frames.md).
//!
//! A snapshot viewer gets a GHOSTSNP READY snapshot instead of the VT replay,
//! then live output tagged with the grid `generation` and the published byte
//! `offset`. A grid change, a backlog overflow and a `snapshot-request` all
//! reach the viewer as a new READY snapshot taken under the terminal lock, so
//! the snapshot and the live bytes after it never overlap or leave a gap.

use std::sync::atomic::AtomicU64;

use ghostty_vt::SnapshotPhase;
use sha2::{Digest, Sha256};

use super::attach_tap::SnapshotRequestHandle;
use super::*;

/// Default `viewer_backlog_bytes` (spec/terminal-frames.md: 8 MiB, set per
/// attach by the viewer, no daemon setting): unacknowledged output kept for one
/// snapshot viewer before its backlog is replaced by a snapshot.
pub(crate) const DEFAULT_VIEWER_BACKLOG_BYTES: usize = 8_388_608;
/// Output idle time before a snapshot viewer gets a digest of the screen.
pub(crate) const SNAPSHOT_DIGEST_IDLE: Duration = Duration::from_secs(2);
/// At most one requested snapshot per viewer in this interval.
pub(crate) const SNAPSHOT_REQUEST_MIN_INTERVAL: Duration = Duration::from_millis(500);

/// Published byte offset and grid generation of one terminal. Written only by
/// the attach broadcasts, which run under the terminal lock; read under the
/// same lock when a snapshot is taken.
#[derive(Default)]
pub(crate) struct SnapshotStreamPosition {
    offset: AtomicU64,
    generation: AtomicU64,
}

impl SnapshotStreamPosition {
    pub(super) fn add_output(&self, len: usize) {
        self.offset.fetch_add(len as u64, Ordering::AcqRel);
    }

    /// Account one broadcast frame: output advances the offset, a replacement
    /// of the grid (resize, host replay) starts a new generation.
    pub(super) fn observe_frame(&self, frame: &AttachFrame) {
        match frame {
            AttachFrame::Output(output) | AttachFrame::OutputWithColors { output, .. } => {
                self.add_output(output.len());
            }
            AttachFrame::Resized { .. } | AttachFrame::ResizedWithColors { .. } => {
                self.generation.fetch_add(1, Ordering::AcqRel);
            }
            AttachFrame::ColorsChanged(_) => {}
        }
    }

    pub(super) fn bump_generation(&self) {
        self.generation.fetch_add(1, Ordering::AcqRel);
    }

    /// `(generation, offset)`.
    pub(crate) fn load(&self) -> (u64, u64) {
        (self.generation.load(Ordering::Acquire), self.offset.load(Ordering::Acquire))
    }
}

/// One READY snapshot for a viewer.
#[derive(Debug, Clone)]
pub(crate) struct TerminalSnapshotFrame {
    pub generation: u64,
    /// Offset of the published output stream this snapshot reflects.
    pub offset: u64,
    pub version: u16,
    pub cols: u16,
    pub rows: u16,
    /// The READY prefix: envelope through the READY record.
    pub data: Vec<u8>,
    /// The rest of the same COMPLETE encode: HISTORY manifests, scrollback
    /// PAGE records and FINISH (`terminal-snapshot-history-v1`). READY plus
    /// this is one complete snapshot taken at one cut.
    pub history: Vec<u8>,
    pub colors: TerminalColors,
    /// Row-marker epoch and the marker of the active area's top row at the
    /// snapshot, so `terminal-history` pages line up with this READY.
    pub marker_epoch: u64,
    pub active_top_marker: u64,
    /// The Kitty image replay at the same cut (`terminal-snapshot-images-v1`),
    /// or `None` when the viewer did not opt in or the terminal has no images.
    pub images: Option<SnapshotImages>,
}

/// The Kitty image replay stream of one READY and what it holds.
#[derive(Debug, Clone)]
pub(crate) struct SnapshotImages {
    pub data: Vec<u8>,
    pub stats: ghostty_vt::KittyReplayStats,
}

/// The Kitty replay of `term` with at most `max_image_bytes` of decoded
/// pixels, or `None` when the terminal has no images (nothing is encoded
/// while the image storage never changed). The caller holds the terminal
/// lock of the READY encode it belongs to.
fn encode_snapshot_images_locked(
    term: &Terminal,
    max_image_bytes: u64,
    surface: SurfaceId,
) -> Option<SnapshotImages> {
    match term.kitty_image_generation() {
        // NoValue: Kitty graphics are not built in.
        Ok(0) | Err(_) => return None,
        Ok(_) => {}
    }
    match term.encode_kitty_replay(max_image_bytes) {
        Ok((data, stats)) if !stats.is_empty() => Some(SnapshotImages { data, stats }),
        Ok(_) => None,
        Err(error) => {
            eprintln!("cmux-tui: surface {surface} snapshot images not encoded: {error}");
            None
        }
    }
}

/// A READY taken exactly at a resize cut for a viewer that reflows its own
/// history (`terminal-snapshot-local-history-v1`). No history follows it; the
/// viewer checks its reflowed history against `history_rows` and
/// `history_digest`. Encoded once per resize and shared by every viewer of
/// the surface that gets it.
#[derive(Debug)]
pub(crate) struct LocalReadySnapshot {
    /// `history` is empty.
    pub frame: TerminalSnapshotFrame,
    pub history_rows: u64,
    pub history_digest: Vec<u8>,
}

/// The idle digest: sha256 of [`ghostty_vt::snapshot_digest_input`] of the
/// host's READY encoding.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct TerminalSnapshotDigest {
    pub generation: u64,
    pub offset: u64,
    pub version: u16,
    pub sha256: [u8; 32],
}

/// A snapshot viewer's live queue plus the handle that requests a resync.
pub(crate) struct SnapshotAttachStream {
    pub receiver: AttachFrameReceiver,
    pub lifecycle: AttachLifecycle,
    pub requests: SnapshotRequestGate,
}

/// Outcome of a `snapshot-request` / channel `snapshot_request`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum SnapshotAdmission {
    /// A snapshot is queued; the viewer's next event is `snapshot`.
    Accepted,
    /// A snapshot is already pending; this request is answered by it.
    Collapsed,
    /// Refused: the viewer got a snapshot less than 500 ms ago.
    Throttled { retry_after_ms: u64 },
    /// The viewer is gone.
    NotAttached,
}

#[derive(Default)]
struct GateState {
    last_snapshot_at: Option<Instant>,
    pending: bool,
}

/// Collapses duplicate snapshot requests and rate-limits them per viewer.
/// The attach worker records every snapshot it sends ([`Self::sent`]), so a
/// backlog or grid-change snapshot also counts toward the interval.
#[derive(Clone)]
pub(crate) struct SnapshotRequestGate {
    handle: SnapshotRequestHandle,
    state: Arc<Mutex<GateState>>,
}

impl SnapshotRequestGate {
    pub(super) fn new(handle: SnapshotRequestHandle) -> Self {
        // The first snapshot is already pending at attach.
        Self {
            handle,
            state: Arc::new(Mutex::new(GateState { pending: true, ..Default::default() })),
        }
    }

    pub(crate) fn request(&self, now: Instant) -> SnapshotAdmission {
        let mut state = self.state.lock().unwrap();
        if state.pending {
            return SnapshotAdmission::Collapsed;
        }
        if let Some(last) = state.last_snapshot_at {
            let next = last + SNAPSHOT_REQUEST_MIN_INTERVAL;
            if now < next {
                let wait = next - now;
                return SnapshotAdmission::Throttled {
                    retry_after_ms: wait.as_millis().max(1) as u64,
                };
            }
        }
        if !self.handle.request() {
            return SnapshotAdmission::NotAttached;
        }
        state.pending = true;
        SnapshotAdmission::Accepted
    }

    /// The worker sent a snapshot at `now`, or tried and deferred it (a
    /// deferred snapshot is not pending: a later request asks again).
    pub(crate) fn sent(&self, now: Instant) {
        let mut state = self.state.lock().unwrap();
        // A request that arrived after the snapshot was taken still waits for
        // its own snapshot, so it stays pending (later requests collapse).
        state.pending = self.handle.snapshot_pending();
        state.last_snapshot_at = Some(now);
    }
}

impl Surface {
    /// Register a snapshot viewer. Its first event is a READY snapshot.
    /// `local_history`: the viewer reflows its own history, so a resize
    /// reaches it as a local-history READY at the resize cut.
    pub(crate) fn attach_snapshot_stream(
        &self,
        lifecycle: AttachLifecycle,
        backlog_bytes: usize,
        local_history: bool,
    ) -> ghostty_vt::Result<SnapshotAttachStream> {
        let Some(pty) = self.as_pty() else {
            return Err(ghostty_vt::Error::InvalidValue);
        };
        let _term = pty.term.lock().unwrap();
        let dead = pty.dead.load(Ordering::Acquire);
        let exited = dead
            && pty.host_connection_state.load(Ordering::Acquire)
                == TerminalHostConnectionState::Exited as u8;
        if dead && !exited {
            return Err(ghostty_vt::Error::NoValue);
        }
        let (tap, receiver) =
            AttachTap::snapshot_pair(lifecycle.clone(), ATTACH_STREAM_CAPACITY, backlog_bytes);
        receiver.set_local_history(local_history);
        if exited {
            // The final screen is still served once; then the stream ends.
            drop(tap);
        } else {
            pty.taps.lock().unwrap().push(tap);
        }
        let requests = SnapshotRequestGate::new(receiver.snapshot_request_handle());
        Ok(SnapshotAttachStream { receiver, lifecycle, requests })
    }

    /// Take the snapshot a viewer's worker owes it and drop the queued
    /// frames it supersedes, both under the terminal lock. One COMPLETE
    /// encode at one cut gives the READY prefix and the history after it, so
    /// the history always continues exactly that READY. `images_cap`: the
    /// viewer gets the Kitty images too, encoded in the same lock hold (they
    /// can change right after), with at most that many decoded pixel bytes.
    pub(crate) fn take_viewer_snapshot(
        &self,
        receiver: &AttachFrameReceiver,
        images_cap: Option<u64>,
    ) -> ghostty_vt::Result<TerminalSnapshotFrame> {
        let Some(pty) = self.as_pty() else {
            return Err(ghostty_vt::Error::InvalidValue);
        };
        let term = pty.term.lock().unwrap();
        let mut data = term.encode_snapshot(SnapshotPhase::Complete)?;
        let images =
            images_cap.and_then(|cap| encode_snapshot_images_locked(&term, cap, self.id));
        let (generation, offset) = pty.snapshot_position.load();
        let defaults = pty.mux.upgrade().map(|mux| mux.default_colors()).unwrap_or_default();
        let colors = pty.terminal_colors_locked(&term, defaults);
        let (cols, rows) = (term.cols(), term.rows());
        let (marker_epoch, active_top_marker) =
            (term.history_marker_epoch(), term.active_top_marker());
        receiver.finish_snapshot_locked();
        drop(term);
        let ready_len =
            ghostty_vt::snapshot_ready_len(&data).ok_or(ghostty_vt::Error::InvalidValue)?;
        let history = data.split_off(ready_len);
        Ok(TerminalSnapshotFrame {
            generation,
            offset,
            version: ghostty_vt::snapshot_version(),
            cols,
            rows,
            data,
            history,
            colors,
            marker_epoch,
            active_top_marker,
            images,
        })
    }

    /// The idle digest of the current screen.
    pub(crate) fn snapshot_digest(&self) -> ghostty_vt::Result<TerminalSnapshotDigest> {
        let Some(pty) = self.as_pty() else {
            return Err(ghostty_vt::Error::InvalidValue);
        };
        let term = pty.term.lock().unwrap();
        let ready = term.encode_snapshot(SnapshotPhase::Ready)?;
        let (generation, offset) = pty.snapshot_position.load();
        drop(term);
        Ok(TerminalSnapshotDigest {
            generation,
            offset,
            version: ghostty_vt::snapshot_version(),
            sha256: Sha256::digest(ghostty_vt::snapshot_digest_input(&ready)).into(),
        })
    }

    /// Encode a snapshot of this terminal (tests compare it with a viewer's).
    #[cfg(test)]
    pub(crate) fn encode_terminal_snapshot(
        &self,
        phase: SnapshotPhase,
    ) -> ghostty_vt::Result<Vec<u8>> {
        let Some(pty) = self.as_pty() else {
            return Err(ghostty_vt::Error::InvalidValue);
        };
        pty.term.lock().unwrap().encode_snapshot(phase)
    }

    /// The Kitty replay of this terminal now (tests compare it with a
    /// viewer's images chunks).
    #[cfg(test)]
    pub(crate) fn encode_kitty_replay_for_test(
        &self,
        max_image_bytes: u64,
    ) -> ghostty_vt::Result<(Vec<u8>, ghostty_vt::KittyReplayStats)> {
        let Some(pty) = self.as_pty() else {
            return Err(ghostty_vt::Error::InvalidValue);
        };
        pty.term.lock().unwrap().encode_kitty_replay(max_image_bytes)
    }

    /// The host terminal's history check now (tests compare it with a
    /// local-history READY's).
    #[cfg(test)]
    pub(crate) fn terminal_history_digest(&self) -> Option<ghostty_vt::HistoryDigest> {
        let term = self.as_pty()?.term.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        // The same order as the host: READY encode, then the digest.
        term.encode_snapshot(SnapshotPhase::Ready).ok()?;
        term.history_digest()
    }

    /// `terminal.history`: GHOSTSNP HISTORY pages above `before`.
    pub(crate) fn history_pages(
        &self,
        epoch: Option<u64>,
        before: Option<u64>,
        max_bytes: usize,
    ) -> Result<ghostty_vt::HistoryPages, ghostty_vt::MarkerError> {
        let Some(pty) = self.as_pty() else {
            return Err(ghostty_vt::MarkerError::Invalid);
        };
        // Encode under the terminal lock; split and copy pages after it.
        let snapshot = pty.term.lock().unwrap().history_snapshot(epoch, before)?;
        snapshot.pages(max_bytes)
    }

    /// `terminal.read_range`: text or VT of a marker range.
    pub(crate) fn read_marker_range(
        &self,
        epoch: Option<u64>,
        from: (u64, u16),
        to: (u64, u16),
        vt: bool,
    ) -> Result<String, ghostty_vt::MarkerError> {
        let Some(pty) = self.as_pty() else {
            return Err(ghostty_vt::MarkerError::Invalid);
        };
        pty.term.lock().unwrap().read_marker_range(epoch, from, to, vt)
    }

    /// Apply `bytes` as PTY output the way the reader does (parse, then
    /// broadcast, under the terminal lock).
    #[cfg(test)]
    pub(crate) fn inject_output_for_test(&self, bytes: &[u8]) {
        let pty = self.as_pty().expect("a PTY surface");
        let mut term = pty.term.lock().unwrap();
        let normalized = term.vt_write_with_normalized(bytes).into_owned();
        pty.broadcast_attach_output(&normalized);
    }

    /// `(generation, offset)` of the published stream.
    pub(crate) fn snapshot_stream_position(&self) -> Option<(u64, u64)> {
        self.as_pty().map(|pty| pty.snapshot_position.load())
    }
}

impl PtySurface {
    /// Publish a grid change of a resize to the attach viewers. The caller
    /// holds the terminal lock and has just resized `term`. `frame` is the
    /// replay for replay viewers, or `None` when only snapshot viewers are
    /// attached.
    ///
    /// The grid change starts a new generation. A snapshot viewer that
    /// reflows its own history and is not behind gets one READY of the new
    /// grid queued after every frame before the resize, at the resize's
    /// generation and offset; every other snapshot viewer gets a READY with
    /// history at a later cut, as before.
    pub(super) fn publish_resize_locked(&self, term: &Terminal, frame: Option<AttachFrame>) {
        match &frame {
            Some(frame) => self.snapshot_position.observe_frame(frame),
            None => self.snapshot_position.bump_generation(),
        }
        // Only the terminal lock (held) moves a viewer from behind to caught
        // up, so a viewer that is behind now stays behind until the sends
        // below: the encode is skipped when no viewer can use it.
        let wanted = self
            .taps
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .iter()
            .any(AttachTap::wants_local_ready);
        let local = if wanted { self.encode_local_ready_locked(term) } else { None };
        let mut taps = self.taps.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        match frame {
            Some(frame) => taps.retain(|tap| tap.try_send_resize(frame.clone(), local.as_ref())),
            None => {
                for tap in &*taps {
                    tap.resync_snapshot_at_cut(local.as_ref());
                }
            }
        }
    }

    /// The local-history READY of `term` at the current stream position, or
    /// `None` when it cannot be encoded now or the history check is not
    /// available (those viewers get a READY with history instead).
    fn encode_local_ready_locked(&self, term: &Terminal) -> Option<Arc<LocalReadySnapshot>> {
        // The digest covers the history rows directly above this READY's
        // seam in the terminal's page layout, so it is computed directly
        // after the encode, on the same terminal under the same lock hold.
        let data = term.encode_snapshot(SnapshotPhase::Ready).ok()?;
        let check = term.history_digest()?;
        let (generation, offset) = self.snapshot_position.load();
        let defaults = self.mux.upgrade().map(|mux| mux.default_colors()).unwrap_or_default();
        Some(Arc::new(LocalReadySnapshot {
            frame: TerminalSnapshotFrame {
                generation,
                offset,
                version: ghostty_vt::snapshot_version(),
                cols: term.cols(),
                rows: term.rows(),
                data,
                history: Vec::new(),
                colors: self.terminal_colors_locked(term, defaults),
                marker_epoch: term.history_marker_epoch(),
                active_top_marker: term.active_top_marker(),
                images: None,
            },
            history_rows: check.rows,
            history_digest: check.digest,
        }))
    }
}

#[cfg(test)]
#[path = "tests/snapshot_attach.rs"]
mod tests;
