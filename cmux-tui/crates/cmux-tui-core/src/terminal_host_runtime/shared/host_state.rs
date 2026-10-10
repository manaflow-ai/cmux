//! Host-side state of the terminal-host runtime that does not touch the OS
//! (cx-ko2e table A): host timeouts and limits, PTY geometry, the
//! kitty-graphics ceiling check, viewer-size arbitration, the exit
//! publication claim, per-client output taps (`HostTap`, over the
//! `sys::HostStream` seam), the smart-renderer raw stream and the parser
//! command queue with its byte budget. `HostShared` follows once its OS
//! fields sit behind seams.

use std::collections::{HashMap, HashSet, VecDeque};
use std::sync::atomic::{AtomicBool, AtomicU64, AtomicUsize, Ordering};
use std::sync::mpsc::{Sender, SyncSender};
use std::sync::{Arc, Condvar, Mutex};
use std::time::{Duration, Instant};

use cmux_pty::PtySize;
use ghostty_vt::Terminal;

use super::super::sys::HostStream;
use super::super::*;
use super::codec::encode_hex;

pub(crate) const HOST_TERMINATE_GRACE: Duration = Duration::from_millis(250);
// Match the remote PTY bridge's bounded outstanding-write precedent.
// This protects the local control-response waiter table from an unbounded
// burst of durable API input without serializing every receipt.
pub(crate) const MAX_PENDING_INPUT_ACKS: usize = 256;
// Keep the total outstanding receipted payload bounded too. Using the
// existing frame-payload ceiling preserves admission for one maximum-sized
// legal Input while preventing 256 such frames from accumulating.
pub(crate) const MAX_PENDING_INPUT_ACK_BYTES: usize = MAX_FRAME_PAYLOAD;
pub(crate) const HOST_KILL_WAIT: Duration = Duration::from_secs(2);
pub(crate) const HOST_PTY_DRAIN_GRACE: Duration = Duration::from_millis(250);
pub(crate) const HOST_FORCED_DRAIN_WINDOW: Duration = Duration::from_millis(100);
pub(crate) const HOST_LAUNCH_ROLLBACK_WAIT: Duration = Duration::from_secs(4);
pub(crate) const HOST_LAUNCH_OWNER_TIMEOUT: Duration = Duration::from_secs(5);
/// How long a host serves no client before it ends its terminal (cx-hostorphan).
/// The owner daemon keeps a stream to every host it runs, so no stream for
/// this long means the daemon is gone and no new daemon adopted the host: a
/// quit or killed app whose PTY would otherwise stay allocated until reboot.
/// A restarted daemon adopts well inside this window.
pub(crate) const HOST_ORPHAN_GRACE: Duration = Duration::from_secs(10 * 60);
/// Overrides [`HOST_ORPHAN_GRACE`] in whole seconds (at least 1); the host
/// inherits it from the daemon that spawned it. Tests use a short grace.
pub(crate) const HOST_ORPHAN_GRACE_ENV: &str = "CMUX_TUI_HOST_ORPHAN_GRACE_SECS";

/// The longest accepted override (30 days), so the deadline math cannot
/// overflow `Instant`.
const HOST_ORPHAN_GRACE_MAX_SECS: u64 = 30 * 24 * 60 * 60;
/// A `SIGTERM` ends a host only after this long with no client stream, so a
/// daemon's reconnect gap (resync, lost connection) is not an orphan.
pub(crate) const HOST_SIGTERM_ORPHAN_MIN: Duration = Duration::from_secs(2);

/// The orphan grace of this host process.
pub(crate) fn host_orphan_grace() -> Duration {
    std::env::var(HOST_ORPHAN_GRACE_ENV)
        .ok()
        .and_then(|value| value.trim().parse::<u64>().ok())
        .filter(|seconds| *seconds > 0)
        .map_or(HOST_ORPHAN_GRACE, |seconds| {
            Duration::from_secs(seconds.min(HOST_ORPHAN_GRACE_MAX_SECS))
        })
}

/// Since when this host process (one terminal per process) has had no
/// client stream, as the accept loop last saw it.
static ORPHAN_SINCE: Mutex<Option<Instant>> = Mutex::new(None);
/// The host ended its terminal because its owner was gone: its exit record
/// says [`crate::terminal_end::EXIT_OWNER_GONE`].
static OWNER_GONE: AtomicBool = AtomicBool::new(false);

pub(crate) fn set_orphan_since(since: Option<Instant>) {
    *ORPHAN_SINCE.lock().unwrap_or_else(std::sync::PoisonError::into_inner) = since;
}

/// No client stream for at least `min`.
pub(crate) fn orphaned_for(min: Duration) -> bool {
    ORPHAN_SINCE
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner)
        .is_some_and(|since| since.elapsed() >= min)
}

/// Record that the terminal is ended because the owner is gone.
pub(crate) fn mark_owner_gone() {
    OWNER_GONE.store(true, Ordering::Release);
}

/// The exit to persist and publish: an owner-gone end is a host loss.
pub(crate) fn owner_gone_exit(exit: TerminalExit) -> TerminalExit {
    if OWNER_GONE.load(Ordering::Acquire) {
        TerminalExit::unknown(crate::terminal_end::EXIT_OWNER_GONE)
    } else {
        exit
    }
}
pub(crate) const HOST_CLIENT_WRITE_TIMEOUT: Duration = Duration::from_secs(2);
pub(crate) const HOST_HANDSHAKE_TRANSIENT_RETRIES: usize = 1;
pub(crate) const HOST_EXIT_PERSIST_RETRY_MIN: Duration = Duration::from_millis(100);
pub(crate) const HOST_EXIT_PERSIST_RETRY_MAX: Duration = Duration::from_secs(5);
pub(crate) const HOST_EXIT_PERSIST_REPORT_INTERVAL: Duration = Duration::from_secs(60);

pub(crate) fn pty_size(cols: u16, rows: u16, cell_pixels: (u16, u16)) -> anyhow::Result<PtySize> {
    let pixel_width = cols.checked_mul(cell_pixels.0).ok_or_else(|| {
        anyhow::anyhow!(
            "terminal pixel width exceeds {}: {cols} columns at {} pixels per cell",
            u16::MAX,
            cell_pixels.0
        )
    })?;
    let pixel_height = rows.checked_mul(cell_pixels.1).ok_or_else(|| {
        anyhow::anyhow!(
            "terminal pixel height exceeds {}: {rows} rows at {} pixels per cell",
            u16::MAX,
            cell_pixels.1
        )
    })?;
    Ok(PtySize { rows, cols, pixel_width, pixel_height })
}

pub(crate) fn kitty_graphics_limits_within(
    candidate: KittyGraphicsLimits,
    ceiling: KittyGraphicsLimits,
) -> bool {
    candidate.image_bytes <= ceiling.image_bytes
        && candidate.inflight_bytes <= ceiling.inflight_bytes
        && candidate.images <= ceiling.images
        && candidate.placements <= ceiling.placements
}

pub(crate) fn input_request_is_supported(selected_version: u16, request_id: u64) -> bool {
    request_id == 0 || selected_version >= PROTOCOL_VERSION
}

pub(crate) fn persist_and_claim_host_exit_after_drain(
    child_exited: &Mutex<Option<TerminalExit>>,
    pty_drained: &AtomicBool,
    exit_published: &AtomicBool,
    persist: impl FnOnce(&TerminalExit) -> anyhow::Result<()>,
) -> anyhow::Result<Option<TerminalExit>> {
    if !pty_drained.load(Ordering::Acquire) {
        return Ok(None);
    }
    let Some(exit) = child_exited.lock().unwrap().clone() else {
        return Ok(None);
    };
    if exit_published.load(Ordering::Acquire) {
        return Ok(None);
    }
    persist(&exit)?;
    Ok(exit_published
        .compare_exchange(false, true, Ordering::AcqRel, Ordering::Acquire)
        .is_ok()
        .then_some(exit))
}

/// Viewer geometry reservations and the clients that negotiated
/// `FLAG_VIEWER_SIZE_PRIORITY` for the lifetime of their connection.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub(crate) struct ViewerSizes {
    pub(crate) sizes: HashMap<u64, (u16, u16)>,
    pub(crate) preferred: HashSet<u64>,
}

impl ViewerSizes {
    /// Per-dimension minimum over preferred sizes, or over every size when
    /// no preferred client currently reports one.
    pub(crate) fn desired(&self) -> Option<(u16, u16)> {
        let minimum =
            |left: (u16, u16), right: (u16, u16)| (left.0.min(right.0), left.1.min(right.1));
        self.sizes
            .iter()
            .filter_map(|(client, size)| self.preferred.contains(client).then_some(*size))
            .reduce(minimum)
            .or_else(|| self.sizes.values().copied().reduce(minimum))
    }

    /// ReleaseViewer drops the size but keeps priority for the connection.
    pub(crate) fn release(&mut self, client: u64) {
        self.sizes.remove(&client);
    }

    pub(crate) fn remove_client(&mut self, client: u64) {
        self.sizes.remove(&client);
        self.preferred.remove(&client);
    }
}

/// Keep viewer mutation, minimum reduction, and the resulting PTY resize
/// in one critical section. If the guard were released after reduction,
/// an older large resize could run after a newer small resize and leave
/// the host at a size that no longer matches its viewer set.
pub(crate) fn mutate_viewer_sizes(
    viewer_sizes: &Mutex<ViewerSizes>,
    mutation: impl FnOnce(&mut ViewerSizes),
    apply: impl FnOnce(Option<(u16, u16)>) -> anyhow::Result<()>,
) -> anyhow::Result<()> {
    let mut viewer_sizes = viewer_sizes.lock().unwrap();
    let previous = viewer_sizes.clone();
    mutation(&mut viewer_sizes);
    if let Err(error) = apply(viewer_sizes.desired()) {
        *viewer_sizes = previous;
        return Err(error);
    }
    Ok(())
}

#[derive(Clone)]
pub(crate) struct HostTap {
    pub(crate) sender: Sender<Frame>,
    pub(crate) queued_bytes: Arc<AtomicUsize>,
    pub(crate) queued_output_bytes: Arc<AtomicUsize>,
    pub(crate) shutdown: Arc<HostStream>,
    pub(crate) max_queued_bytes: usize,
}

impl HostTap {
    pub(crate) fn new(
        sender: Sender<Frame>,
        shutdown: Arc<HostStream>,
        max_queued_bytes: usize,
    ) -> Self {
        Self {
            sender,
            queued_bytes: Arc::new(AtomicUsize::new(0)),
            queued_output_bytes: Arc::new(AtomicUsize::new(0)),
            shutdown,
            max_queued_bytes,
        }
    }

    pub(crate) fn try_reserve(counter: &AtomicUsize, retained: usize, limit: usize) -> bool {
        let mut queued = counter.load(Ordering::Acquire);
        loop {
            let Some(next) = queued.checked_add(retained) else {
                return false;
            };
            if next > limit {
                return false;
            }
            match counter.compare_exchange_weak(queued, next, Ordering::AcqRel, Ordering::Acquire) {
                Ok(_) => return true,
                Err(actual) => queued = actual,
            }
        }
    }

    pub(crate) fn try_send(&self, frame: Frame) -> bool {
        let retained =
            crate::terminal_host_protocol::HEADER_LEN.saturating_add(frame.payload.len());
        if !Self::try_reserve(&self.queued_bytes, retained, self.max_queued_bytes) {
            self.close();
            return false;
        }
        let is_output = frame.kind == MessageKind::Output;
        if is_output
            && !Self::try_reserve(
                &self.queued_output_bytes,
                retained,
                MAX_HOST_CLIENT_OUTPUT_QUEUED_BYTES,
            )
        {
            self.queued_bytes.fetch_sub(retained, Ordering::AcqRel);
            self.close();
            return false;
        }
        // The byte reservations above are the queue's single admission
        // limit. The channel itself must not add a scheduler-sensitive
        // frame-count limit that disconnects a client while most of its
        // declared byte budget is still free.
        match self.sender.send(frame) {
            Ok(()) => true,
            Err(_) => {
                self.queued_bytes.fetch_sub(retained, Ordering::AcqRel);
                if is_output {
                    self.queued_output_bytes.fetch_sub(retained, Ordering::AcqRel);
                }
                self.close();
                false
            }
        }
    }

    pub(crate) fn release(&self, frame: &Frame) {
        let retained =
            crate::terminal_host_protocol::HEADER_LEN.saturating_add(frame.payload.len());
        self.queued_bytes.fetch_sub(retained, Ordering::AcqRel);
        if frame.kind == MessageKind::Output {
            self.queued_output_bytes.fetch_sub(retained, Ordering::AcqRel);
        }
    }

    pub(crate) fn close(&self) {
        let _ = self.shutdown.shutdown(std::net::Shutdown::Both);
    }

    pub(crate) fn close_and_wake_writer(&self) {
        self.close();
        // The receiver cannot observe channel disconnection while the
        // writer's local HostTap still owns a sender. Enqueue one private
        // sentinel so an input-side EOF always releases an otherwise-idle
        // writer. Socket shutdown releases a writer blocked in write_frame.
        let wake = Frame::new(MessageKind::ResyncRequired, Vec::new());
        let retained = crate::terminal_host_protocol::HEADER_LEN;
        self.queued_bytes.fetch_add(retained, Ordering::AcqRel);
        if self.sender.send(wake).is_err() {
            self.queued_bytes.fetch_sub(retained, Ordering::AcqRel);
        }
    }

    pub(crate) fn wake_writer(&self) {
        // The source-ordered DetachAck is already queued. This private
        // sentinel closes the writer loop after it writes that receipt,
        // without shutting the socket before the receipt is drained.
        let wake = Frame::new(MessageKind::ResyncRequired, Vec::new());
        let retained = crate::terminal_host_protocol::HEADER_LEN;
        self.queued_bytes.fetch_add(retained, Ordering::AcqRel);
        if self.sender.send(wake).is_err() {
            self.queued_bytes.fetch_sub(retained, Ordering::AcqRel);
        }
    }
}

/// Source-ordered raw terminal stream used only by negotiated smart
/// renderers. Its cursor is deliberately independent of the legacy
/// parser-ordered CMTH stream: publishing raw PTY bytes must not wait for
/// the authoritative Ghostty parser, while legacy renderers keep their
/// normalized Output + coupled Colors contract unchanged.
pub(crate) struct SmartStreamState {
    pub(crate) broadcast_lock: Mutex<()>,
    pub(crate) taps: Mutex<HashMap<u64, HostTap>>,
    pub(crate) source_cursor: AtomicU64,
    pub(crate) applied_cursor: AtomicU64,
    pub(crate) retained: Mutex<SmartRetention>,
}

impl SmartStreamState {
    pub(crate) fn new() -> Self {
        Self {
            broadcast_lock: Mutex::new(()),
            taps: Mutex::new(HashMap::new()),
            source_cursor: AtomicU64::new(0),
            applied_cursor: AtomicU64::new(0),
            retained: Mutex::new(SmartRetention::default()),
        }
    }

    /// Publish before parsing. The returned source cursor is marked
    /// applied only after the authoritative parser has consumed the same
    /// transition.
    pub(crate) fn publish(&self, mut frame: Frame) -> u64 {
        let _broadcast = self.broadcast_lock.lock().unwrap();
        let cursor = self.source_cursor.fetch_add(1, Ordering::AcqRel) + 1;
        frame.sequence = cursor;
        self.retained.lock().unwrap().push(frame.clone());
        self.taps.lock().unwrap().retain(|_, tap| tap.try_send(frame.clone()));
        cursor
    }

    pub(crate) fn publish_after_targeted(
        &self,
        targeted: &HostTap,
        targeted_frame: Frame,
        mut frame: Frame,
    ) -> (u64, bool) {
        let _broadcast = self.broadcast_lock.lock().unwrap();
        let targeted_queued = targeted.try_send(targeted_frame);
        let cursor = self.source_cursor.fetch_add(1, Ordering::AcqRel) + 1;
        frame.sequence = cursor;
        self.retained.lock().unwrap().push(frame.clone());
        self.taps.lock().unwrap().retain(|_, tap| tap.try_send(frame.clone()));
        (cursor, targeted_queued)
    }

    pub(crate) fn mark_applied(&self, cursor: u64) {
        let prior = self.applied_cursor.fetch_max(cursor, Ordering::AcqRel);
        debug_assert!(prior <= cursor, "smart parser cursor moved backwards");
    }

    pub(crate) fn close_failed_transition(&self, source_cursor: Option<u64>) {
        if source_cursor.is_none() {
            return;
        }
        let cursor = self.publish(Frame::new(MessageKind::ResyncRequired, Vec::new()));
        // The failed marker is closed by an explicit applied boundary.
        // New clients snapshot after it; connected clients restart the
        // handshake instead of waiting forever for an unapplied cursor.
        self.mark_applied(cursor);
    }

    /// Called while the terminal parser lock is held. It queues retained
    /// frames before inserting the tap, all under the source publication
    /// lock, so the caller may release its parser lock and perform socket
    /// writes without opening an attach race.
    pub(crate) fn subscribe(&self, client: u64, tap: HostTap) -> Result<u64, SmartReplayGap> {
        let _broadcast = self.broadcast_lock.lock().unwrap();
        let boundary = self.applied_cursor.load(Ordering::Acquire);
        let backlog = self.retained.lock().unwrap().after(boundary)?;
        for frame in backlog {
            if !tap.try_send(frame) {
                return Err(SmartReplayGap::SubscriberQueueOverflow { boundary });
            }
        }
        self.taps.lock().unwrap().insert(client, tap);
        Ok(boundary)
    }

    pub(crate) fn remove(&self, client: u64) {
        self.taps.lock().unwrap().remove(&client);
    }

    #[cfg(test)]
    pub(crate) fn is_empty(&self) -> bool {
        self.taps.lock().unwrap().is_empty()
    }
}

#[derive(Default)]
pub(crate) struct SmartRetention {
    pub(crate) frames: VecDeque<Frame>,
    pub(crate) bytes: usize,
    pub(crate) dropped_through: u64,
}

impl SmartRetention {
    pub(crate) fn push(&mut self, frame: Frame) {
        let retained = retained_frame_bytes(&frame);
        self.bytes = self.bytes.saturating_add(retained);
        self.frames.push_back(frame);
        while self.bytes > MAX_SMART_RETAINED_BYTES || self.frames.len() > MAX_SMART_RETAINED_FRAMES
        {
            let Some(frame) = self.frames.pop_front() else { break };
            self.bytes = self.bytes.saturating_sub(retained_frame_bytes(&frame));
            self.dropped_through = frame.sequence;
        }
    }

    pub(crate) fn after(&self, cursor: u64) -> Result<Vec<Frame>, SmartReplayGap> {
        if cursor < self.dropped_through {
            return Err(SmartReplayGap::Retention {
                requested_after: cursor,
                retained_after: self.dropped_through,
            });
        }
        Ok(self.frames.iter().filter(|frame| frame.sequence > cursor).cloned().collect())
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum SmartReplayGap {
    Retention { requested_after: u64, retained_after: u64 },
    SubscriberQueueOverflow { boundary: u64 },
}

impl SmartReplayGap {
    pub(crate) fn encode(self) -> Vec<u8> {
        let (requested_after, retained_after, reason) = match self {
            Self::Retention { requested_after, retained_after } => {
                (requested_after, retained_after, 0)
            }
            Self::SubscriberQueueOverflow { boundary } => (boundary, boundary, 1),
        };
        let mut payload = Vec::with_capacity(17);
        payload.extend_from_slice(&requested_after.to_le_bytes());
        payload.extend_from_slice(&retained_after.to_le_bytes());
        payload.push(reason);
        payload
    }
}

pub(crate) fn retained_frame_bytes(frame: &Frame) -> usize {
    crate::terminal_host_protocol::HEADER_LEN.saturating_add(frame.payload.len())
}

pub(crate) enum ParserCommand {
    Output {
        bytes: Vec<u8>,
        source_cursor: u64,
        accounted_bytes: usize,
    },
    Resize {
        cols: u16,
        rows: u16,
        cell_pixels: (u16, u16),
        source_cursor: Option<u64>,
        acknowledge_with_replay: bool,
        targeted_ack: Option<(u64, HostTap)>,
        response: SyncSender<ParserResizeResult>,
    },
    SetDefaults {
        colors: Box<DefaultColors>,
        source_cursor: u64,
        response: SyncSender<()>,
    },
    ClearHistory {
        fallback_key: Option<KeyInput>,
        response: SyncSender<Result<ParserClearHistoryResult, String>>,
    },
    /// Answers one deferred clipboard read; `None` refuses it.
    ClipboardReadComplete {
        token: u64,
        text: Option<Vec<u8>>,
    },
    /// Answers once every earlier command is applied (metric_commits.rs).
    Barrier(SyncSender<()>),
    Drain,
}

#[derive(Debug, Clone)]
pub(crate) struct ParserResizeResult {
    pub(crate) acknowledgement_queued: Result<bool, String>,
    pub(crate) changed: bool,
    pub(crate) applied: (u16, u16),
}

pub(crate) enum ParserClearHistoryResult {
    Cleared(Vec<u8>),
    Blocked,
    EncodedFallback(Vec<u8>),
    Noop,
}

pub(crate) enum ClearHistoryAckDisposition {
    Pending,
    Queued,
    ConnectionClosed,
}

pub(crate) struct ParserBudget {
    pub(crate) queued_bytes: Mutex<usize>,
    pub(crate) available: Condvar,
    pub(crate) max_bytes: usize,
}

impl ParserBudget {
    pub(crate) fn new(max_bytes: usize) -> Self {
        Self { queued_bytes: Mutex::new(0), available: Condvar::new(), max_bytes }
    }

    pub(crate) fn reserve(&self, bytes: usize) {
        debug_assert!(bytes <= self.max_bytes);
        let queued = self.queued_bytes.lock().unwrap();
        let mut queued = self
            .available
            .wait_while(queued, |queued| queued.saturating_add(bytes) > self.max_bytes)
            .unwrap();
        *queued += bytes;
    }

    pub(crate) fn release(&self, bytes: usize) {
        let mut queued = self.queued_bytes.lock().unwrap();
        *queued =
            queued.checked_sub(bytes).expect("parser budget released more bytes than reserved");
        self.available.notify_all();
    }
}

pub(crate) fn enqueue_parser_output(
    parser_commands: &SyncSender<ParserCommand>,
    parser_budget: &ParserBudget,
    smart: &SmartStreamState,
    bytes: Vec<u8>,
    source_cursor: u64,
    accounted_bytes: usize,
) -> bool {
    if parser_commands.send(ParserCommand::Output { bytes, source_cursor, accounted_bytes }).is_ok()
    {
        return true;
    }

    parser_budget.release(accounted_bytes);
    smart.close_failed_transition(Some(source_cursor));
    false
}

pub(crate) fn publish_host_frames(
    broadcast_lock: &Mutex<()>,
    sequence: &AtomicU64,
    taps: &Mutex<HashMap<u64, HostTap>>,
    frames: impl IntoIterator<Item = Frame>,
) {
    let _ = publish_host_frames_and_targeted(broadcast_lock, sequence, taps, frames, None);
}

pub(crate) fn publish_host_frames_and_targeted(
    broadcast_lock: &Mutex<()>,
    sequence: &AtomicU64,
    taps: &Mutex<HashMap<u64, HostTap>>,
    frames: impl IntoIterator<Item = Frame>,
    targeted: Option<(&HostTap, Frame)>,
) -> bool {
    // Sequence allocation and publication are one critical section;
    // otherwise concurrent output/resize/exit producers could mint N
    // then publish N+1 first, split a coupled Output/Colors pair, or place
    // a targeted acknowledgement before its canonical transition.
    let _broadcast = broadcast_lock.lock().unwrap();
    let mut taps = taps.lock().unwrap();
    for mut frame in frames {
        let sequence = sequence.fetch_add(1, Ordering::AcqRel) + 1;
        frame.sequence = sequence;
        taps.retain(|_, tap| tap.try_send(frame.clone()));
    }
    drop(taps);
    targeted.is_none_or(|(tap, frame)| tap.try_send(frame))
}

pub(crate) fn changed_pwd_frame(
    last_pwd: &mut Option<String>,
    current_pwd: Option<String>,
) -> Option<Frame> {
    // Track only the parser's raw OSC 7 state. Folding in the spawn-CWD
    // fallback here would hide a Some -> None transition from live clients.
    if last_pwd.as_deref() == current_pwd.as_deref() {
        return None;
    }
    let payload = current_pwd.as_deref().unwrap_or_default().as_bytes().to_vec();
    *last_pwd = current_pwd;
    Some(Frame::new(MessageKind::Pwd, payload))
}

pub(crate) fn output_transition_frames(
    output: Vec<u8>,
    colors: Option<Vec<u8>>,
    pwd: Option<Frame>,
) -> Vec<Frame> {
    let mut frames = Vec::with_capacity(3);
    let mut output = Frame::new(MessageKind::Output, output);
    if let Some(colors) = colors {
        output.flags = FLAG_COLORS_FOLLOW;
        frames.push(output);
        frames.push(Frame::new(MessageKind::Colors, colors));
    } else {
        frames.push(output);
    }
    frames.extend(pwd);
    frames
}

/// Persist a local spawn path with host-authenticated provenance. A host
/// can outlive its daemon, so a raw OSC 7 URL here would become the next
/// surface's inherited spawn directory after reattachment.
pub(crate) fn snapshot_cwd(
    term: &Terminal,
    spawn_cwd: Option<&str>,
    owner_token: &CapabilityToken,
    protocol_version: u16,
) -> Option<String> {
    // OSC 7 is terminal-controlled metadata and cannot prove that a path
    // belongs to this host. Use only the authenticated spawn fallback.
    let _ = term;
    let path = spawn_cwd.and_then(crate::platform::spawn_cwd_to_local_path)?;
    // Only the negotiated current protocol understands authenticated
    // provenance markers. Treat legacy and unknown values as legacy wire
    // format so peers never receive a marker they cannot decode.
    if protocol_version != PROTOCOL_VERSION {
        return Some(path.to_string_lossy().into_owned());
    }
    Some(format!(
        "{}{}:{}",
        crate::platform::SNAPSHOT_SPAWN_CWD_PREFIX,
        encode_hex(owner_token.as_bytes()),
        path.to_string_lossy()
    ))
}
