//! The terminal's own input port (R-DAEMON-STATE stage S1 step 6, handoff/rewrites/R-DAEMON-STATE/DESIGN.md
//! section 2.6.1).
//!
//! A person's key to a hosted terminal was written to the host socket on the request thread, under the terminal's
//! runtime lock and the host connection's writer. Another writer of the same terminal (a large paste, receipted
//! input, a cell-pixel change waiting for its acknowledgement) held both for its whole write, so the key waited
//! behind it, and a host that did not read its socket stalled the connection's dispatcher.
//!
//! With the stage switch on (`CMUX_TUI_RDS_INPUT`), interactive input to a hosted terminal (keys and pastes:
//! `Surface::write_bytes`, `Surface::write_paste`) goes to the terminal's port instead: one queue per terminal,
//! drained in order by the terminal's own writer thread. The request returns once the port took the bytes; it takes
//! neither the runtime lock nor the host writer.
//!
//! - The writer writes on the route of the terminal's current host connection, which the terminal publishes each
//!   time the connection changes (`PtyTerminalRuntime::replace_runtime`), so it never takes the runtime lock either.
//! - A person's key (at most 1 KB) to an idle port, with nothing queued or in flight and no reconnect wait, is written
//!   on the request's own turn when the connection's writer is free and the host socket takes it whole now
//!   (`InputPort::try_write_now`, a non-blocking send under the port lock): no thread hand-off, which cost each key a
//!   wake under load (#35413 A/B). Anything else (a busy writer, a full socket, an error, a frame ahead) goes to the
//!   port as below, so a key still never waits for another writer or a host that stopped reading.
//! - Once the writer takes a person's key it runs at user-interactive QoS for its life, as the connection threads
//!   that carried the key do (server/input_qos.rs); a port only automation writes to keeps the default QoS.
//! - A lost host connection is retried as `write_bytes` did (cx-6so.49): the writer waits until the terminal
//!   publishes another route ([`InputPort::route_changed`]) and writes to it, until the frame's own deadline,
//!   `HOST_INPUT_RECONNECT_WAIT` after the port took it. The old path's deadline started at the write call, so writes
//!   queued behind a host that does not come back fail together, and a later loss gives its writes their own wait.
//!   When no route will come (the reader ended or gave the host up, or the owner detaches the terminal),
//!   [`InputPort::reconnect_ended`] ends the wait at once and the frame fails then, as the old path's write did.
//! - The port lock is a leaf: no holder of it waits for another lock. So the runtime lock's holders (a route
//!   publication, a detach, the order barrier's callers) may take it.
//! - A full port refuses at once with a typed error: nothing is dropped silently and nothing waits. Each queued
//!   frame counts its bookkeeping too ([`PORT_FRAME_COST`]), so many tiny frames cannot grow the queue without bound.
//! - A connection the reader shut down (`Failed`, it keeps retrying: [`InputRoute::Failed`]) or a reader that ended
//!   takes no input: the write is refused at once, as the old path's write failed then
//!   (`Surface::enqueue_on_input_port`). A replacement's route is accepted as soon as it is installed. While a lost
//!   connection is still `Reconnecting`, input is accepted and the writer waits for the reconnect.
//! - Only the person's keys answer when the port took them ([`InputReply::Accepted`]); a key the port then could not
//!   write (the host is gone and no new one came) is lost, as a failed write was before, and the port logs it. Every
//!   other write waits for its frame's result ([`InputPort::write`]), at most [`INPUT_WRITE_REPLY_WAIT`]: a wait that
//!   ends before the writer took the frame cancels it, and one that ends during its write answers
//!   [`InputMayBeWritten`].
//! - Every other frame of the connection (viewer size, cell pixels, receipted input, clear history, Kitty limits,
//!   clipboard replies, terminate) first waits for the frames the port took before it ([`PortOrder::barrier`], at most
//!   2 s or its caller's sooner deadline). Order holds while the port drains within that bound: a frame still in its
//!   write after it (a large paste to a host that reads slowly) lets the waiting frame go. The barrier does not wait
//!   while the writer waits for a reconnect: the connection that frame goes to is gone, and the replacement is
//!   installed under the runtime lock that frame's writer may hold. The install ends the writer's wait at once.

use std::collections::VecDeque;
use std::sync::atomic::{AtomicU8, Ordering};
use std::sync::{Arc, Condvar, Mutex, PoisonError, Weak};
use std::time::{Duration, Instant};

use super::input::HOST_INPUT_RECONNECT_WAIT;
use super::{PtyTerminalRuntime, TerminalHostConnectionState};
use crate::terminal_host_protocol::{MAX_FRAME_PAYLOAD, MessageKind};
use crate::terminal_host_runtime::HostInputRoute;

/// What one queued frame costs beyond its bytes (its header and allocation), counted against the capacity.
const PORT_FRAME_COST: usize = 64;
/// The most one terminal's port holds; more is refused (`terminal.input_busy`). Two of the largest frames, with
/// their cost.
const INPUT_PORT_BYTE_CAPACITY: usize = 2 * (MAX_FRAME_PAYLOAD + PORT_FRAME_COST);
/// A port writer with nothing to write for this long ends; the next input starts a new one.
const INPUT_PORT_IDLE_EXIT: Duration = Duration::from_secs(30);
/// The writer's stack: it formats and writes one frame at a time.
const INPUT_PORT_STACK_BYTES: usize = 256 * 1024;
/// The longest a write that waits for its frame ([`InputReply::Written`]) waits for the terminal's input port: one
/// reconnect wait for the queue ahead of it, a few blocked socket writes, and slack.
pub(super) const INPUT_WRITE_REPLY_WAIT: Duration = Duration::from_secs(15);

/// The error inside a write's error when its wait ended while the port's writer was writing it: the bytes may still
/// reach the program, so a caller that gives input back must not give these back.
#[derive(Debug)]
pub(crate) struct InputMayBeWritten;

impl std::fmt::Display for InputMayBeWritten {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str(
            "terminal input may have been written: the wait ended during its write to the terminal's host",
        )
    }
}

impl std::error::Error for InputMayBeWritten {}

/// Whether `error` is the error of a write that may still reach the program ([`InputMayBeWritten`]).
pub(crate) fn input_may_be_written(error: &std::io::Error) -> bool {
    error.get_ref().is_some_and(|inner| inner.is::<InputMayBeWritten>())
}

/// Where a hosted terminal's interactive input goes, published without the runtime lock.
pub(crate) enum InputRoute {
    /// The current host connection.
    Hosted(HostInputRoute),
    /// The host exited and the terminal keeps its final screen: input is dropped, as `write_bytes` drops it.
    Exited,
    /// The reader shut the host connection down and keeps retrying (`Failed`): input is refused until a
    /// replacement is installed, as the old path's write to the shut connection failed.
    Failed,
}

/// Why the port did not take a write.
#[derive(Debug)]
pub(crate) enum InputRefused {
    /// The port already holds [`INPUT_PORT_BYTE_CAPACITY`] bytes (retryable).
    Busy,
    /// One write larger than a host frame.
    TooLarge,
    /// No writer thread could start.
    NoWriter(std::io::Error),
}

impl From<InputRefused> for std::io::Error {
    fn from(refused: InputRefused) -> Self {
        match refused {
            InputRefused::Busy => std::io::Error::new(
                std::io::ErrorKind::WouldBlock,
                "terminal.input_busy: the terminal's input port is full",
            ),
            InputRefused::TooLarge => std::io::Error::new(
                std::io::ErrorKind::InvalidInput,
                "terminal input is larger than one host frame",
            ),
            InputRefused::NoWriter(error) => error,
        }
    }
}

/// Where the port reports one frame's write to a writer that waits for it ([`InputReply::Written`]).
type FrameDone = std::sync::mpsc::SyncSender<std::io::Result<()>>;

/// A waited-for frame is still queued, taken by the writer to write, or cancelled by its waiter.
const FRAME_QUEUED: u8 = 0;
const FRAME_TAKEN: u8 = 1;
const FRAME_CANCELLED: u8 = 2;

/// The writer waiting for one frame's result ([`InputPort::write`]).
struct FrameWaiter {
    done: FrameDone,
    /// [`FRAME_QUEUED`], then [`FRAME_TAKEN`] (the port's writer) or [`FRAME_CANCELLED`] (the waiter gave up first).
    state: Arc<AtomicU8>,
}

impl FrameWaiter {
    /// The port's writer takes the frame to write it; false when its waiter already gave up on it.
    fn take(&self) -> bool {
        self.state
            .compare_exchange(FRAME_QUEUED, FRAME_TAKEN, Ordering::AcqRel, Ordering::Acquire)
            .is_ok()
    }
}

/// What a write to a hosted terminal's input port answers (S1.6b): the person's keys return when the port took them;
/// every other writer (a script's `send`, a resource input effect, the creating-input flush, an image paste) waits
/// for its frame's write, so its error reaches it as on the old path.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum InputReply {
    /// The port took the bytes; nothing waits (the person's keys).
    Accepted,
    /// The port wrote the bytes, or the write's error.
    Written,
}

struct PortFrame {
    kind: MessageKind,
    bytes: Vec<u8>,
    /// The end of this frame's wait for a lost connection to come back: `HOST_INPUT_RECONNECT_WAIT` after the port
    /// took it, as the old path's write waited from its call.
    reconnect_by: Instant,
    /// The waiting writer of an [`InputReply::Written`] write; dropped unanswered when the frame is dropped.
    waiter: Option<FrameWaiter>,
    /// A viewer-size control frame another writer of the connection queued behind the port's frames
    /// ([`PortOrder::enqueue_after_pending`]): only its newest state matters, so a newer one replaces it while it
    /// is the last frame queued.
    control: bool,
}

impl PortFrame {
    /// What the frame counts against [`INPUT_PORT_BYTE_CAPACITY`]: its bytes and [`PORT_FRAME_COST`].
    fn cost(&self) -> usize {
        self.bytes.len().saturating_add(PORT_FRAME_COST)
    }
}

#[derive(Default)]
struct PortState {
    frames: VecDeque<PortFrame>,
    queued_bytes: usize,
    writer_running: bool,
    closed: bool,
    /// Frames the port took, and frames it finished (written, failed or dropped): a direct writer of the host
    /// connection waits until `finished` reaches `accepted` as it read it ([`PortOrder::barrier`], S1.6b).
    accepted: u64,
    finished: u64,
    /// The writer waits for a reconnect: a barrier does not wait then; the connection it would write to is gone, and
    /// the install it waits for may need the runtime lock that barrier's caller holds.
    reconnecting: bool,
    /// Moves each time the terminal publishes a route ([`InputPort::route_changed`]) or will install none
    /// ([`InputPort::reconnect_ended`]): ends the writer's reconnect wait.
    route_epoch: u64,
    /// Tests: the writer waits here before it writes each frame.
    #[cfg(test)]
    paused: Option<std::sync::mpsc::Receiver<()>>,
    /// Tests: [`INPUT_WRITE_REPLY_WAIT`] and [`HOST_INPUT_RECONNECT_WAIT`] for this port.
    #[cfg(test)]
    reply_wait: Option<Duration>,
    #[cfg(test)]
    reconnect_wait: Option<Duration>,
    /// Tests: the writer panics after it took its next frame (a writer lost during a write).
    #[cfg(test)]
    panic_after_take: bool,
    /// Tests: no inline write ([`InputPort::queue_every_write_for_test`]).
    #[cfg(all(test, unix))]
    inline_off: bool,
    /// Tests (macOS, where a thread has a QoS class): the writer thread's QoS class when it last took a frame.
    #[cfg(all(test, target_os = "macos"))]
    writer_qos: Option<u32>,
}

#[derive(Default)]
struct PortShared {
    state: Mutex<PortState>,
    changed: Condvar,
    /// Signalled when `finished` moves, the writer starts waiting for a reconnect, or the port closes.
    finished_changed: Condvar,
}

impl PortShared {
    fn route_epoch(&self) -> u64 {
        self.state.lock().unwrap_or_else(PoisonError::into_inner).route_epoch
    }
}

/// The order of one terminal's input port for the other writers of its host connection (DESIGN 2.6.1, S1.6b): a
/// viewer size, a cell-pixel size, receipted input, a clear history, Kitty limits, a clipboard reply or a terminate
/// issued after a key the port took reaches the host after that key.
#[derive(Clone)]
pub(crate) struct PortOrder(Arc<PortShared>);

impl PortOrder {
    /// Queues the viewer-size frame `kind` (`ViewerSize`, `ReleaseViewer`) behind the frames the port holds and
    /// returns true; false when the port holds none or closed: the caller writes it directly then, as no frame of the
    /// port is ahead of it. Nothing waits, so a size sent on a key's turn under the sizing lock never waits for the
    /// port (#35082 review 1, item 4). A newer size replaces a queued one that is still the last frame (nothing
    /// between them), so sizes cannot pile up behind a stalled port.
    ///
    /// It queues while the writer waits for a reconnect too (#35375 review): the port's frames, a size queued before
    /// the loss among them, go to the new connection after the install, so a size written directly instead would go
    /// to the lost connection and the stale queued one would be the new host's last. Queued, the newest size (or
    /// release) is the last size frame the new host reads. The order barrier skips during that wait because its
    /// callers hold the runtime lock the install needs; this never waits, so that reason does not apply.
    pub(crate) fn enqueue_after_pending(&self, kind: MessageKind, bytes: &[u8]) -> bool {
        let mut state = self.0.state.lock().unwrap_or_else(PoisonError::into_inner);
        // Frames pending means the writer runs: it took a frame it has not finished (it may wait for a reconnect),
        // or one is queued.
        if state.closed || state.finished >= state.accepted {
            return false;
        }
        if let Some(last) = state.frames.back_mut().filter(|frame| frame.control) {
            let before = last.cost();
            last.kind = kind;
            last.bytes = bytes.to_vec();
            let after = last.cost();
            state.queued_bytes = state.queued_bytes.saturating_sub(before).saturating_add(after);
            return true;
        }
        let reconnect_by =
            Instant::now().checked_add(reconnect_wait(&state)).unwrap_or_else(Instant::now);
        let frame =
            PortFrame { kind, bytes: bytes.to_vec(), reconnect_by, waiter: None, control: true };
        // Not counted against the capacity: one control frame per run of other frames, a few bytes each.
        state.queued_bytes = state.queued_bytes.saturating_add(frame.cost());
        state.accepted = state.accepted.saturating_add(1);
        state.frames.push_back(frame);
        drop(state);
        self.0.changed.notify_one();
        true
    }

    /// Waits until the port finished every frame it took before this call. Returns at once while the port's writer
    /// waits for a reconnect or when the port closed, and at `deadline`. Frames taken after the call do not extend
    /// the wait.
    pub(crate) fn barrier(&self, deadline: Instant) {
        let mut state = self.0.state.lock().unwrap_or_else(PoisonError::into_inner);
        let target = state.accepted;
        while state.finished < target && !state.reconnecting && !state.closed {
            let now = Instant::now();
            if now >= deadline {
                return;
            }
            state = self
                .0
                .finished_changed
                .wait_timeout(state, deadline.saturating_duration_since(now))
                .unwrap_or_else(PoisonError::into_inner)
                .0;
        }
    }
}

/// One terminal's input port (see the module docs). Closed when the terminal drops.
#[derive(Default)]
pub(crate) struct InputPort {
    shared: Arc<PortShared>,
}

impl Drop for InputPort {
    fn drop(&mut self) {
        self.shared.state.lock().unwrap_or_else(PoisonError::into_inner).closed = true;
        self.shared.changed.notify_all();
        self.shared.finished_changed.notify_all();
    }
}

impl InputPort {
    /// Takes `bytes` for `terminal`'s current host connection and returns at once ([`InputReply::Accepted`]): written
    /// on this turn when the port is idle and the connection takes them now (`try_write_now`), else by the terminal's
    /// writer thread after every earlier write of the port.
    pub(crate) fn enqueue(
        &self,
        terminal: &Arc<PtyTerminalRuntime>,
        kind: MessageKind,
        bytes: &[u8],
    ) -> Result<(), InputRefused> {
        self.enqueue_frame(terminal, kind, bytes, None)
    }

    /// [`Self::enqueue`] for a writer that waits for its frame's result ([`InputReply::Written`]), as the old path's
    /// caller waited for its write, at most [`Self::reply_wait`]. A wait that ends before the port's writer took the
    /// frame cancels it: the error says not written, and it never is. One that ends during its write answers the
    /// write's result if it ended meanwhile, else [`InputMayBeWritten`].
    pub(crate) fn write(
        &self,
        terminal: &Arc<PtyTerminalRuntime>,
        kind: MessageKind,
        bytes: &[u8],
    ) -> std::io::Result<()> {
        let (done, written) = std::sync::mpsc::sync_channel(1);
        let state = Arc::new(AtomicU8::new(FRAME_QUEUED));
        let waiter = FrameWaiter { done, state: Arc::clone(&state) };
        self.enqueue_frame(terminal, kind, bytes, Some(waiter))?;
        match written.recv_timeout(self.reply_wait()) {
            Ok(result) => result,
            // The waiter's sender dropped unanswered: the writer stopped. A frame it had taken may be partly written.
            Err(std::sync::mpsc::RecvTimeoutError::Disconnected) => {
                if state.load(Ordering::Acquire) == FRAME_TAKEN {
                    Err(std::io::Error::new(std::io::ErrorKind::BrokenPipe, InputMayBeWritten))
                } else {
                    Err(std::io::Error::new(
                        std::io::ErrorKind::BrokenPipe,
                        "the terminal's input port stopped before it wrote the input",
                    ))
                }
            }
            Err(std::sync::mpsc::RecvTimeoutError::Timeout) => {
                if state
                    .compare_exchange(
                        FRAME_QUEUED,
                        FRAME_CANCELLED,
                        Ordering::AcqRel,
                        Ordering::Acquire,
                    )
                    .is_ok()
                {
                    return Err(std::io::Error::new(
                        std::io::ErrorKind::TimedOut,
                        "terminal input not written: the terminal's input port did not reach it in time",
                    ));
                }
                written.try_recv().unwrap_or_else(|_| {
                    Err(std::io::Error::new(std::io::ErrorKind::TimedOut, InputMayBeWritten))
                })
            }
        }
    }

    /// The terminal published a new input route (a replacement connection, a failed link, an exited host; the caller
    /// holds the runtime lock): a writer waiting for a reconnect tries the new route at once, and a frame of another
    /// writer waits for the port again, whose next write goes to the new connection ahead of it.
    pub(crate) fn route_changed(&self) {
        let mut state = self.shared.state.lock().unwrap_or_else(PoisonError::into_inner);
        state.route_epoch = state.route_epoch.wrapping_add(1);
        state.reconnecting = false;
        drop(state);
        self.shared.changed.notify_all();
    }

    /// The terminal will install no host connection for now (its reader ended or gave the host up, or its owner
    /// detaches it): a writer waiting for a reconnect checks again at once and fails its frame, as the old path's
    /// write failed then (#35082 review 2).
    pub(crate) fn reconnect_ended(&self) {
        let mut state = self.shared.state.lock().unwrap_or_else(PoisonError::into_inner);
        state.route_epoch = state.route_epoch.wrapping_add(1);
        state.reconnecting = false;
        drop(state);
        self.shared.changed.notify_all();
    }

    fn enqueue_frame(
        &self,
        terminal: &Arc<PtyTerminalRuntime>,
        kind: MessageKind,
        bytes: &[u8],
        waiter: Option<FrameWaiter>,
    ) -> Result<(), InputRefused> {
        if bytes.len() > MAX_FRAME_PAYLOAD {
            return Err(InputRefused::TooLarge);
        }
        // A person's key with nothing ahead of it is written on this turn: no thread hand-off (#35413 A/B).
        #[cfg(unix)]
        if waiter.is_none() && self.try_write_now(terminal, kind, bytes) {
            return Ok(());
        }
        // Copied before the lock, so another write to this terminal never waits for this one's copy.
        let bytes = bytes.to_vec();
        let mut state = self.shared.state.lock().unwrap_or_else(PoisonError::into_inner);
        let reconnect_by =
            Instant::now().checked_add(reconnect_wait(&state)).unwrap_or_else(Instant::now);
        let frame = PortFrame { kind, bytes, reconnect_by, waiter, control: false };
        let Some(total) = state
            .queued_bytes
            .checked_add(frame.cost())
            .filter(|total| *total <= INPUT_PORT_BYTE_CAPACITY)
        else {
            return Err(InputRefused::Busy);
        };
        if !state.writer_running {
            let shared = Arc::clone(&self.shared);
            let terminal = Arc::downgrade(terminal);
            std::thread::Builder::new()
                // At most 15 bytes: the length Linux keeps.
                .name("term-input-port".into())
                .stack_size(INPUT_PORT_STACK_BYTES)
                .spawn(move || run_writer(&shared, &terminal))
                .map_err(InputRefused::NoWriter)?;
            state.writer_running = true;
        }
        state.queued_bytes = total;
        state.accepted = state.accepted.saturating_add(1);
        state.frames.push_back(frame);
        drop(state);
        self.shared.changed.notify_one();
        Ok(())
    }

    /// A person's key to an idle port, written on the caller's turn (#35413 A/B: the hand-off to the port's writer
    /// thread cost each key its wake, +0.17 ms at p95 and +0.53 ms at p99 under the L6 load). Only when nothing can
    /// make it wait or pass another frame: the port holds no frame and is not writing one (the writer may run, idle),
    /// no reconnect wait is under way, and [`HostInputRoute::try_send_now`] can write it now (the connection's writer
    /// is free and the socket takes it whole). The check and the write are under the port lock, so no frame the port
    /// takes meanwhile can go first: frames taken later queue behind it, in order. A barrier waiting for frames the
    /// port took earlier is unaffected: there are none. True when it was written and counted as one of the port's
    /// frames; false leaves everything to the port, as before.
    #[cfg(unix)]
    fn try_write_now(
        &self,
        terminal: &Arc<PtyTerminalRuntime>,
        kind: MessageKind,
        bytes: &[u8],
    ) -> bool {
        if bytes.len() > crate::terminal_host_runtime::INLINE_FRAME_MAX {
            return false;
        }
        let mut state = self.shared.state.lock().unwrap_or_else(PoisonError::into_inner);
        if state.closed || state.reconnecting || state.finished < state.accepted {
            return false;
        }
        #[cfg(test)]
        if state.inline_off {
            return false;
        }
        let route = terminal.input_route.load();
        let Some(InputRoute::Hosted(route)) = route.as_deref() else { return false };
        if !route.try_send_now(kind, bytes) {
            return false;
        }
        // Counted as taken and finished at once: no barrier waits for it (none can: the port was idle).
        state.accepted = state.accepted.saturating_add(1);
        state.finished = state.finished.saturating_add(1);
        true
    }

    /// Tests: every write goes through the port's writer thread, as before the inline write (a test of the writer
    /// itself: its order, reconnect and QoS).
    #[cfg(all(test, unix))]
    pub(crate) fn queue_every_write_for_test(&self) {
        self.shared.state.lock().unwrap_or_else(PoisonError::into_inner).inline_off = true;
    }

    /// The port's order for the other writers of the terminal's host connection.
    pub(crate) fn order(&self) -> PortOrder {
        PortOrder(Arc::clone(&self.shared))
    }

    /// Tests: the writer waits for one message on the returned sender before it writes each frame.
    #[cfg(test)]
    pub(crate) fn pause_writes_for_test(&self) -> std::sync::mpsc::Sender<()> {
        let (resume, paused) = std::sync::mpsc::channel();
        self.shared.state.lock().unwrap_or_else(PoisonError::into_inner).paused = Some(paused);
        resume
    }

    /// How long a write that waits for its frame waits ([`INPUT_WRITE_REPLY_WAIT`]).
    pub(crate) fn reply_wait(&self) -> Duration {
        #[cfg(test)]
        if let Some(wait) =
            self.shared.state.lock().unwrap_or_else(PoisonError::into_inner).reply_wait
        {
            return wait;
        }
        INPUT_WRITE_REPLY_WAIT
    }

    /// Tests: [`Self::reply_wait`] for this port.
    #[cfg(test)]
    pub(crate) fn set_reply_wait_for_test(&self, wait: Duration) {
        self.shared.state.lock().unwrap_or_else(PoisonError::into_inner).reply_wait = Some(wait);
    }

    /// Tests: the reconnect wait ([`HOST_INPUT_RECONNECT_WAIT`]) for this port.
    #[cfg(test)]
    pub(crate) fn set_reconnect_wait_for_test(&self, wait: Duration) {
        self.shared.state.lock().unwrap_or_else(PoisonError::into_inner).reconnect_wait =
            Some(wait);
    }

    /// Tests (macOS): the writer thread's QoS class when it last took a frame.
    #[cfg(all(test, target_os = "macos"))]
    pub(crate) fn writer_qos_for_test(&self) -> Option<u32> {
        self.shared.state.lock().unwrap_or_else(PoisonError::into_inner).writer_qos
    }

    /// Tests: the writer panics after it takes its next frame.
    #[cfg(test)]
    pub(crate) fn panic_after_take_for_test(&self) {
        self.shared.state.lock().unwrap_or_else(PoisonError::into_inner).panic_after_take = true;
    }

    /// Tests: whether the writer waits for a reconnect now.
    #[cfg(test)]
    pub(crate) fn reconnecting_for_test(&self) -> bool {
        self.shared.state.lock().unwrap_or_else(PoisonError::into_inner).reconnecting
    }

    /// Tests: the frames the port took so far.
    #[cfg(test)]
    pub(crate) fn accepted_for_test(&self) -> u64 {
        self.shared.state.lock().unwrap_or_else(PoisonError::into_inner).accepted
    }

    /// Tests: the frames still queued (not yet taken by the writer).
    #[cfg(test)]
    pub(crate) fn queued_frames_for_test(&self) -> usize {
        self.shared.state.lock().unwrap_or_else(PoisonError::into_inner).frames.len()
    }

    /// Tests: the port holds no frame and is writing none (the next key may go inline).
    #[cfg(test)]
    pub(crate) fn idle_for_test(&self) -> bool {
        let state = self.shared.state.lock().unwrap_or_else(PoisonError::into_inner);
        state.frames.is_empty() && state.finished >= state.accepted
    }
}

/// The reconnect wait of the port whose locked `state` the caller holds ([`HOST_INPUT_RECONNECT_WAIT`] unless a test
/// set one). It reads the caller's guard and never takes the port lock itself: a second lock of the same mutex on one
/// thread deadlocks, as `PortOrder::enqueue_after_pending` did in test builds.
fn reconnect_wait(state: &PortState) -> Duration {
    #[cfg(test)]
    if let Some(wait) = state.reconnect_wait {
        return wait;
    }
    let _ = state;
    HOST_INPUT_RECONNECT_WAIT
}

/// One frame of the port finished (written, failed or dropped): barriers waiting for it may go.
fn finish_frames(shared: &PortShared, count: u64) {
    let mut state = shared.state.lock().unwrap_or_else(PoisonError::into_inner);
    state.finished = state.finished.saturating_add(count).min(state.accepted);
    drop(state);
    shared.finished_changed.notify_all();
}

/// The writer: the next frame in order, or `None` when the port closed or stayed idle for
/// [`INPUT_PORT_IDLE_EXIT`] (it then marks itself stopped, under the lock, so the next input starts a new one).
fn next_frame(shared: &PortShared) -> Option<PortFrame> {
    let mut state = shared.state.lock().unwrap_or_else(PoisonError::into_inner);
    let idle_until = Instant::now().checked_add(INPUT_PORT_IDLE_EXIT).unwrap_or_else(Instant::now);
    loop {
        if let Some(frame) = state.frames.pop_front() {
            state.queued_bytes = state.queued_bytes.saturating_sub(frame.cost());
            return Some(frame);
        }
        let now = Instant::now();
        if state.closed || now >= idle_until {
            state.writer_running = false;
            return None;
        }
        state = shared
            .changed
            .wait_timeout(state, idle_until.saturating_duration_since(now))
            .unwrap_or_else(PoisonError::into_inner)
            .0;
    }
}

/// Stops the port cleanly when its writer unwinds: the frame it was writing is lost, so the frames after it are
/// dropped too (a paste without its start, keys without the ones before them) and logged, and the writer is marked
/// stopped, so the next input starts a new one instead of queueing behind a writer that is gone. Only on unwind: a
/// normal exit marks the writer stopped under the lock in [`next_frame`], and a newer writer may run by then.
struct WriterUnwind<'a>(&'a PortShared);

impl Drop for WriterUnwind<'_> {
    fn drop(&mut self) {
        if !std::thread::panicking() {
            return;
        }
        let mut state = self.0.state.lock().unwrap_or_else(PoisonError::into_inner);
        let dropped = state.frames.len();
        state.frames.clear();
        state.queued_bytes = 0;
        state.writer_running = false;
        // Dropped frames and the one it lost are finished: no barrier waits for them.
        state.finished = state.accepted;
        state.reconnecting = false;
        drop(state);
        self.0.finished_changed.notify_all();
        eprintln!(
            "cmux-tui: terminal input port writer stopped by a panic; {dropped} queued writes dropped"
        );
    }
}

fn run_writer(shared: &PortShared, terminal: &Weak<PtyTerminalRuntime>) {
    let _unwind = WriterUnwind(shared);
    while let Some(frame) = next_frame(shared) {
        // Its waiter gave up before the writer reached it (`InputPort::write`): it answered "not written", so the
        // frame is not written.
        if frame.waiter.as_ref().is_some_and(|waiter| !waiter.take()) {
            finish_frames(shared, 1);
            continue;
        }
        // A frame with no waiter that is not a viewer size is the person's key (`InputPort::enqueue`, only for
        // `InputReply::Accepted`): from then on this writer runs at user-interactive QoS, as the connection threads
        // that carried the key do (server/input_qos.rs; DESIGN 2.6.1). Under full CPU a default-QoS writer waited for
        // a CPU between the key's acceptance and its write to the host. A port only automation writes to keeps the
        // default QoS. Once per thread; a writer that exits idle starts again at the default.
        if frame.waiter.is_none() && !frame.control {
            crate::server::raise_input_thread_qos();
        }
        #[cfg(test)]
        {
            let paused = shared.state.lock().unwrap_or_else(PoisonError::into_inner).paused.take();
            if let Some(paused) = paused {
                let _ = paused.recv();
                shared.state.lock().unwrap_or_else(PoisonError::into_inner).paused = Some(paused);
            }
            #[cfg(target_os = "macos")]
            {
                shared.state.lock().unwrap_or_else(PoisonError::into_inner).writer_qos =
                    Some(crate::server::current_input_thread_qos());
            }
            let lost = std::mem::take(
                &mut shared.state.lock().unwrap_or_else(PoisonError::into_inner).panic_after_take,
            );
            // crash-allow: test-only panic, a writer lost after it took its frame.
            assert!(!lost, "test: the input port's writer is lost after it took its frame");
        }
        // The terminal is gone: its port closed, and nothing is left to write to.
        let Some(runtime) = terminal.upgrade() else {
            finish_frames(shared, 1);
            return;
        };
        let written = write_with_reconnect(shared, &runtime, &frame);
        finish_frames(shared, 1);
        match (written, frame.waiter) {
            // The waiting writer answers its request with the result.
            (written, Some(waiter)) => {
                let _ = waiter.done.send(written);
            }
            (Err(error), None) if frame.control => {
                eprintln!("cmux-tui: terminal host {:?} frame not written: {error}", frame.kind);
            }
            (Err(error), None) => eprintln!(
                "cmux-tui: terminal input not written ({} bytes, already accepted): {error}",
                frame.bytes.len()
            ),
            (Ok(()), None) => {}
        }
    }
}

/// Waits until the terminal publishes a route after the one seen at epoch `observed` ([`InputPort::route_changed`])
/// or ends its reconnect ([`InputPort::reconnect_ended`]), until the port closes or until `deadline`; true when the
/// epoch moved (the caller checks the route and the terminal's state again). Marks the writer waiting for a reconnect
/// meanwhile, so barriers do not wait for it (a new route clears the mark at once).
fn wait_for_route(shared: &PortShared, observed: u64, deadline: Instant) -> bool {
    let mut state = shared.state.lock().unwrap_or_else(PoisonError::into_inner);
    if state.route_epoch != observed {
        return true;
    }
    if state.closed || Instant::now() >= deadline {
        return false;
    }
    state.reconnecting = true;
    shared.finished_changed.notify_all();
    let published = loop {
        if state.route_epoch != observed {
            break true;
        }
        let now = Instant::now();
        if state.closed || now >= deadline {
            break false;
        }
        state = shared
            .changed
            .wait_timeout(state, deadline.saturating_duration_since(now))
            .unwrap_or_else(PoisonError::into_inner)
            .0;
    };
    state.reconnecting = false;
    published
}

/// One frame on the terminal's current host connection, across a lost connection: the rule of
/// `Surface::send_hosted_input`, on the port's thread, reading the published route instead of the runtime lock. The
/// frame waits for a reconnect until its own deadline (`PortFrame::reconnect_by`).
fn write_with_reconnect(
    shared: &PortShared,
    runtime: &PtyTerminalRuntime,
    frame: &PortFrame,
) -> std::io::Result<()> {
    let mut first_error = None;
    loop {
        // Read the route epoch before the route: a route published after it ends the wait below, so no reconnect is
        // missed (`PtyTerminalRuntime::replace_runtime` stores the route, then moves the epoch).
        let observed = shared.route_epoch();
        let route = runtime.input_route.load_full();
        let sent = match route.as_deref() {
            Some(InputRoute::Hosted(route)) => route.send(frame.kind, &frame.bytes),
            // Keep-on-exit: the final screen drops input; input that already failed keeps its error.
            Some(InputRoute::Exited) => return first_error.map_or(Ok(()), Err),
            Some(InputRoute::Failed) => {
                return Err(first_error.unwrap_or_else(|| {
                    std::io::Error::new(
                        std::io::ErrorKind::NotConnected,
                        "the terminal's host connection failed; input not written",
                    )
                }));
            }
            None => {
                return Err(first_error.unwrap_or_else(|| {
                    std::io::Error::new(
                        std::io::ErrorKind::NotConnected,
                        "terminal has no host connection for its input port",
                    )
                }));
            }
        };
        let error = match sent {
            Ok(()) => return Ok(()),
            Err(error) if super::input::host_connection_lost(&error) => error,
            Err(error) => return Err(error),
        };
        let error = first_error.take().unwrap_or(error);
        let state = TerminalHostConnectionState::from_u8(
            runtime.host_connection_state.load(Ordering::Acquire),
        );
        if matches!(
            state,
            TerminalHostConnectionState::Failed | TerminalHostConnectionState::Exited
        ) || runtime.reader_completion.is_complete()
            || runtime.owner_detaching.load(Ordering::Acquire)
            || !wait_for_route(shared, observed, frame.reconnect_by)
        {
            return Err(error);
        }
        first_error = Some(error);
    }
}
