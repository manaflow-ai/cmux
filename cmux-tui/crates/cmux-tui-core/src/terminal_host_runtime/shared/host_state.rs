//! Host-side state of the terminal-host runtime that does not touch the OS
//! (cx-ko2e table A): host timeouts and limits, PTY geometry, the
//! kitty-graphics ceiling check, viewer-size arbitration, the exit
//! publication claim, per-client output taps (`HostTap`, over the
//! `sys::HostStream` seam), the smart-renderer raw stream and the parser
//! command queue with its byte budget. `HostShared` follows once its OS
//! fields sit behind seams.

use crate::panic_free::RecoverPoison;
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

/// How long an explicit Terminate (closing a terminal tab) gives the
/// terminal's programs to exit after SIGHUP before it sends SIGTERM. Long
/// enough for an editor to write its swap file or an agent to flush its
/// transcript, short enough that a closed tab's processes do not linger.
const HOST_HANGUP_GRACE_MS: u64 = 2_000;
pub(crate) const HOST_HANGUP_GRACE: Duration = Duration::from_millis(HOST_HANGUP_GRACE_MS);
/// How long programs that outlived SIGHUP get after SIGTERM before SIGKILL.
const HOST_SIGTERM_GRACE_MS: u64 = 1_000;
pub(crate) const HOST_SIGTERM_GRACE: Duration = Duration::from_millis(HOST_SIGTERM_GRACE_MS);
// Match the remote PTY bridge's bounded outstanding-write precedent.
// This protects the local control-response waiter table from an unbounded
// burst of durable API input without serializing every receipt.
pub(crate) const MAX_PENDING_INPUT_ACKS: usize = 256;
// Keep the total outstanding receipted payload bounded too. Using the
// existing frame-payload ceiling preserves admission for one maximum-sized
// legal Input while preventing 256 such frames from accumulating.
pub(crate) const MAX_PENDING_INPUT_ACK_BYTES: usize = MAX_FRAME_PAYLOAD;
const HOST_KILL_WAIT_MS: u64 = 2_000;
pub(crate) const HOST_KILL_WAIT: Duration = Duration::from_millis(HOST_KILL_WAIT_MS);
const HOST_PTY_DRAIN_GRACE_MS: u64 = 250;
pub(crate) const HOST_PTY_DRAIN_GRACE: Duration = Duration::from_millis(HOST_PTY_DRAIN_GRACE_MS);
const HOST_FORCED_DRAIN_WINDOW_MS: u64 = 100;
pub(crate) const HOST_FORCED_DRAIN_WINDOW: Duration =
    Duration::from_millis(HOST_FORCED_DRAIN_WINDOW_MS);
/// The longest a host's Terminate sequence can take (`terminate_and_wait`):
/// the SIGHUP and SIGTERM graces, the session and child waits after SIGKILL,
/// and the PTY drain windows.
const HOST_TERMINATE_BOUND_MS: u64 = HOST_HANGUP_GRACE_MS
    + HOST_SIGTERM_GRACE_MS
    + 2 * HOST_KILL_WAIT_MS
    + HOST_PTY_DRAIN_GRACE_MS
    + 2 * HOST_FORCED_DRAIN_WINDOW_MS;
/// How long an owner waits for a host it asked to end: the host's whole
/// Terminate sequence plus slack for its exit receipt.
pub(crate) const HOST_TERMINATE_WAIT: Duration =
    Duration::from_millis(HOST_TERMINATE_BOUND_MS + 2_000);
pub(crate) const HOST_LAUNCH_ROLLBACK_WAIT: Duration = HOST_TERMINATE_WAIT;
pub(crate) const HOST_LAUNCH_OWNER_TIMEOUT: Duration = Duration::from_secs(5);
/// How long a host serves no client before it ends its terminal, in the
/// builds that have an orphan grace at all (cx-hostorphan, cx-t2sqm D1).
///
/// Normal installs (NIGHTLY, release, RC, a standalone release cmux-tui)
/// have NO orphan grace: a terminal lives until the user closes it, so
/// quitting or updating cmux never ends it (Lawrence 2026-10-14). Tagged DEV
/// and staging builds and debug builds (tests, local runs) give their hosts
/// this grace, so throwaway builds do not leave PTYs allocated for days. The
/// daemon decides ([`set_dev_host_orphan_grace`]) and passes the grace to
/// the hosts it spawns in [`HOST_ORPHAN_GRACE_ENV`]; a host reads only that.
pub(crate) const DEV_HOST_ORPHAN_GRACE: Duration = Duration::from_secs(10 * 60);
/// The orphan grace of a host in whole seconds (at least 1). Unset: no
/// orphan grace. An explicit value in the daemon's environment wins over the
/// daemon's build policy and reaches every host it spawns; tests use a short
/// grace.
pub(crate) const HOST_ORPHAN_GRACE_ENV: &str = "CMUX_TUI_HOST_ORPHAN_GRACE_SECS";

/// The longest accepted override (30 days), so the deadline math cannot
/// overflow `Instant`.
const HOST_ORPHAN_GRACE_MAX_SECS: u64 = 30 * 24 * 60 * 60;

/// Whether this daemon gives the hosts it spawns [`DEV_HOST_ORPHAN_GRACE`].
/// Debug builds default to yes until the daemon's build policy is installed.
static DEV_ORPHAN_GRACE: AtomicBool = AtomicBool::new(cfg!(debug_assertions));

/// The daemon's build policy, set once at daemon start before any host is
/// spawned: `true` for tagged DEV and staging builds and debug builds,
/// `false` for normal installs.
pub fn set_dev_host_orphan_grace(enabled: bool) {
    DEV_ORPHAN_GRACE.store(enabled, Ordering::Release);
}

/// The variable a spawned host gets, if any: none when the daemon's own
/// environment already sets it (the host inherits that value) or when the
/// daemon's build has no orphan grace.
pub(crate) fn host_orphan_env() -> Option<(&'static str, String)> {
    if std::env::var_os(HOST_ORPHAN_GRACE_ENV).is_some()
        || !DEV_ORPHAN_GRACE.load(Ordering::Acquire)
    {
        return None;
    }
    Some((HOST_ORPHAN_GRACE_ENV, DEV_HOST_ORPHAN_GRACE.as_secs().to_string()))
}

/// The orphan grace the terminal processes this daemon starts get: an
/// explicit [`HOST_ORPHAN_GRACE_ENV`] in its environment, else
/// [`DEV_HOST_ORPHAN_GRACE`] in builds with one, else none. The holder gets
/// it too (`cmux_holder::ORPHAN_GRACE_ENV`), so holder terminals end after
/// the same grace as hosted ones.
#[cfg(unix)]
pub(crate) fn spawned_orphan_grace() -> Option<Duration> {
    if std::env::var_os(HOST_ORPHAN_GRACE_ENV).is_some() {
        return read_host_orphan_grace();
    }
    DEV_ORPHAN_GRACE.load(Ordering::Acquire).then_some(DEV_HOST_ORPHAN_GRACE)
}

/// A `SIGTERM` ends a host only after this long with no client stream, so a
/// daemon's reconnect gap (resync, lost connection) is not an orphan.
pub(crate) const HOST_SIGTERM_ORPHAN_MIN: Duration = Duration::from_secs(2);

/// The orphan grace of this host process; `None`: the host never ends its
/// terminal for lack of a client. Read once: a Unix host reads it as its
/// first step and removes the variable, so its shell (and any daemon started
/// in that shell) never inherits a DEV build's grace.
pub(crate) fn host_orphan_grace() -> Option<Duration> {
    static GRACE: std::sync::OnceLock<Option<Duration>> = std::sync::OnceLock::new();
    *GRACE.get_or_init(read_host_orphan_grace)
}

fn read_host_orphan_grace() -> Option<Duration> {
    std::env::var(HOST_ORPHAN_GRACE_ENV)
        .ok()
        .and_then(|value| value.trim().parse::<u64>().ok())
        .filter(|seconds| *seconds > 0)
        .map(|seconds| Duration::from_secs(seconds.min(HOST_ORPHAN_GRACE_MAX_SECS)))
}

/// Since when this host process (one terminal per process) has had no
/// client stream, as the accept loop last saw it.
static ORPHAN_SINCE: Mutex<Option<Instant>> = Mutex::new(None);
/// The host ended its terminal because its owner was gone: its exit record
/// says [`crate::terminal_end::EXIT_OWNER_GONE`].
static OWNER_GONE: AtomicBool = AtomicBool::new(false);

pub(crate) fn set_orphan_since(since: Option<Instant>) {
    *ORPHAN_SINCE.lock().recover_poison() = since;
}

/// No client stream for at least `min`.
pub(crate) fn orphaned_for(min: Duration) -> bool {
    ORPHAN_SINCE.lock().recover_poison().is_some_and(|since| since.elapsed() >= min)
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

/// The winsize for a grid. The pixel fields saturate at `u16::MAX` so a
/// grid the size clamp accepts never fails on `ws_xpixel`/`ws_ypixel`.
pub(crate) fn pty_size(cols: u16, rows: u16, cell_pixels: (u16, u16)) -> PtySize {
    let pixel_width = cols.saturating_mul(cell_pixels.0);
    let pixel_height = rows.saturating_mul(cell_pixels.1);
    PtySize { rows, cols, pixel_width, pixel_height }
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
    let Some(exit) = child_exited.lock().recover_poison().clone() else {
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
    let mut viewer_sizes = viewer_sizes.lock().recover_poison();
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
        let _broadcast = self.broadcast_lock.lock().recover_poison();
        let cursor = self.source_cursor.fetch_add(1, Ordering::AcqRel) + 1;
        frame.sequence = cursor;
        self.retained.lock().recover_poison().push(frame.clone());
        self.taps.lock().recover_poison().retain(|_, tap| tap.try_send(frame.clone()));
        cursor
    }

    pub(crate) fn publish_after_targeted(
        &self,
        targeted: &HostTap,
        targeted_frame: Frame,
        mut frame: Frame,
    ) -> (u64, bool) {
        let _broadcast = self.broadcast_lock.lock().recover_poison();
        let targeted_queued = targeted.try_send(targeted_frame);
        let cursor = self.source_cursor.fetch_add(1, Ordering::AcqRel) + 1;
        frame.sequence = cursor;
        self.retained.lock().recover_poison().push(frame.clone());
        self.taps.lock().recover_poison().retain(|_, tap| tap.try_send(frame.clone()));
        (cursor, targeted_queued)
    }

    pub(crate) fn mark_applied(&self, cursor: u64) {
        let prior = self.applied_cursor.fetch_max(cursor, Ordering::AcqRel);
        debug_assert!(prior <= cursor, "smart parser cursor moved backwards");
        // A subscriber replays only frames after the applied boundary (it
        // snapshots the rest), so applied frames are never read again: drop
        // them. Before, every host kept up to 8 MiB / 4096 frames of raw
        // output it had already parsed for its whole life.
        self.retained.lock().recover_poison().drop_through(cursor.max(prior));
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
        let _broadcast = self.broadcast_lock.lock().recover_poison();
        let boundary = self.applied_cursor.load(Ordering::Acquire);
        let backlog = self.retained.lock().recover_poison().after(boundary)?;
        for frame in backlog {
            if !tap.try_send(frame) {
                return Err(SmartReplayGap::SubscriberQueueOverflow { boundary });
            }
        }
        self.taps.lock().recover_poison().insert(client, tap);
        Ok(boundary)
    }

    pub(crate) fn remove(&self, client: u64) {
        self.taps.lock().recover_poison().remove(&client);
    }

    #[cfg(test)]
    pub(crate) fn is_empty(&self) -> bool {
        self.taps.lock().recover_poison().is_empty()
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

    /// Drops the frames up to `cursor` (the applied boundary). A replay
    /// asked for from before it reports a retention gap, as for frames the
    /// bounds dropped, so a racing subscriber resnapshots instead of
    /// silently missing frames.
    pub(crate) fn drop_through(&mut self, cursor: u64) {
        while self.frames.front().is_some_and(|frame| frame.sequence <= cursor) {
            let Some(frame) = self.frames.pop_front() else { break };
            self.bytes = self.bytes.saturating_sub(retained_frame_bytes(&frame));
            self.dropped_through = self.dropped_through.max(frame.sequence);
        }
        if self.frames.is_empty() {
            self.frames.shrink_to(64);
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
        /// The PTY already holds the new size (the program got SIGWINCH
        /// when the command was queued); restore this size if the grid
        /// cannot follow.
        pty_previous: Option<PtySize>,
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
        let queued = self.queued_bytes.lock().recover_poison();
        let mut queued = self
            .available
            .wait_while(queued, |queued| queued.saturating_add(bytes) > self.max_bytes)
            .recover_poison();
        *queued += bytes;
    }

    pub(crate) fn release(&self, bytes: usize) {
        let mut queued = self.queued_bytes.lock().recover_poison();
        *queued = queued.checked_sub(bytes).unwrap_or_else(|| {
            eprintln!("cmux: terminal-host parser budget released more bytes than reserved");
            0
        });
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
    let _broadcast = broadcast_lock.lock().recover_poison();
    let mut taps = taps.lock().recover_poison();
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
