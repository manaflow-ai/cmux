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
//! - A lost host connection is retried as `write_bytes` did (cx-6so.49): the writer waits for the reader's next
//!   stream change and writes to the new host, until `HOST_INPUT_RECONNECT_WAIT`.
//! - A full port refuses at once with a typed error: nothing is dropped silently and nothing waits. Each queued
//!   frame counts its bookkeeping too ([`PORT_FRAME_COST`]), so many tiny frames cannot grow the queue without bound.
//! - A connection the reader shut down (`Failed`, it keeps retrying: [`InputRoute::Failed`]) or a reader that ended
//!   takes no input: the write is refused at once, as the old path's write failed then
//!   (`Surface::enqueue_on_input_port`). A replacement's route is accepted as soon as it is installed. While a lost
//!   connection is still `Reconnecting`, input is accepted and the writer waits for the reconnect.
//! - Input the port took and then could not write (the host is gone and no new one came) is lost, as a failed write
//!   was before; the request had already been answered, so the port logs it.
//! - Stage S1 step 6b, before the default flip: every other frame of the connection (viewer size, cell pixels,
//!   receipted input, clear history, Kitty limits, clipboard replies, terminate) still writes directly, so while the
//!   port is behind such a frame can go before a key the port still holds.

use std::collections::VecDeque;
use std::sync::atomic::Ordering;
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
pub(crate) type FrameDone = std::sync::mpsc::SyncSender<std::io::Result<()>>;

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
    /// The waiting writer of an [`InputReply::Written`] write; dropped unanswered when the frame is dropped.
    done: Option<FrameDone>,
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
    /// Tests: the writer waits here before it writes each frame.
    #[cfg(test)]
    paused: Option<std::sync::mpsc::Receiver<()>>,
}

#[derive(Default)]
struct PortShared {
    state: Mutex<PortState>,
    changed: Condvar,
    /// Signalled when `finished` moves, the writer starts waiting for a reconnect, or the port closes.
    finished_changed: Condvar,
}

/// The order of one terminal's input port for the other writers of its host connection (DESIGN 2.6.1, S1.6b): a
/// viewer size, a cell-pixel size, receipted input, a clear history, Kitty limits, a clipboard reply or a terminate
/// issued after a key the port took reaches the host after that key.
#[derive(Clone)]
pub(crate) struct PortOrder(Arc<PortShared>);

impl PortOrder {
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
    /// Takes `bytes` for `terminal`'s current host connection and returns at once; the terminal's writer thread
    /// writes them after every earlier write of the port.
    pub(crate) fn enqueue(
        &self,
        terminal: &Arc<PtyTerminalRuntime>,
        kind: MessageKind,
        bytes: &[u8],
        done: Option<FrameDone>,
    ) -> Result<(), InputRefused> {
        if bytes.len() > MAX_FRAME_PAYLOAD {
            return Err(InputRefused::TooLarge);
        }
        // Copied before the lock, so another write to this terminal never waits for this one's copy.
        let frame = PortFrame { kind, bytes: bytes.to_vec(), done };
        let mut state = self.shared.state.lock().unwrap_or_else(PoisonError::into_inner);
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
    // One reconnect wait for the queue: set by the first frame that finds the connection lost, cleared by the next
    // write that succeeds, so frames queued behind a host that never comes back fail together, not 5 s each.
    let mut reconnect_until = None;
    while let Some(frame) = next_frame(shared) {
        #[cfg(test)]
        {
            let paused = shared.state.lock().unwrap_or_else(PoisonError::into_inner).paused.take();
            if let Some(paused) = paused {
                let _ = paused.recv();
                shared.state.lock().unwrap_or_else(PoisonError::into_inner).paused = Some(paused);
            }
        }
        // The terminal is gone: its port closed, and nothing is left to write to.
        let Some(runtime) = terminal.upgrade() else {
            finish_frames(shared, 1);
            return;
        };
        let written =
            write_with_reconnect(shared, &runtime, frame.kind, &frame.bytes, &mut reconnect_until);
        finish_frames(shared, 1);
        match (written, frame.done) {
            // The waiting writer answers its request with the result.
            (written, Some(done)) => {
                let _ = done.send(written);
            }
            (Err(error), None) => eprintln!(
                "cmux-tui: terminal input not written ({} bytes, already accepted): {error}",
                frame.bytes.len()
            ),
            (Ok(()), None) => {}
        }
    }
}

/// Marks the writer waiting for a reconnect while it lives, so barriers do not wait for it meanwhile.
struct Reconnecting<'a>(&'a PortShared);

impl<'a> Reconnecting<'a> {
    fn start(shared: &'a PortShared) -> Self {
        shared.state.lock().unwrap_or_else(PoisonError::into_inner).reconnecting = true;
        shared.finished_changed.notify_all();
        Self(shared)
    }
}

impl Drop for Reconnecting<'_> {
    fn drop(&mut self) {
        self.0.state.lock().unwrap_or_else(PoisonError::into_inner).reconnecting = false;
    }
}

/// One frame on the terminal's current host connection, across a lost connection: the rule of
/// `Surface::send_hosted_input`, on the port's thread, reading the published route instead of the runtime lock.
fn write_with_reconnect(
    shared: &PortShared,
    runtime: &PtyTerminalRuntime,
    kind: MessageKind,
    bytes: &[u8],
    reconnect_until: &mut Option<Instant>,
) -> std::io::Result<()> {
    let mut first_error = None;
    loop {
        // Read the revision before the send: an install after it wakes the wait below, so no reconnect is missed.
        let observed = runtime.stream_progress.revision();
        let route = runtime.input_route.load_full();
        let sent = match route.as_deref() {
            Some(InputRoute::Hosted(route)) => route.send(kind, bytes),
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
            Ok(()) => {
                *reconnect_until = None;
                return Ok(());
            }
            Err(error) if super::input::host_connection_lost(&error) => error,
            Err(error) => return Err(error),
        };
        let error = first_error.take().unwrap_or(error);
        let deadline = *reconnect_until.get_or_insert_with(|| {
            Instant::now().checked_add(HOST_INPUT_RECONNECT_WAIT).unwrap_or_else(Instant::now)
        });
        let state = TerminalHostConnectionState::from_u8(
            runtime.host_connection_state.load(Ordering::Acquire),
        );
        if matches!(
            state,
            TerminalHostConnectionState::Failed | TerminalHostConnectionState::Exited
        ) || runtime.reader_completion.is_complete()
            || runtime.owner_detaching.load(Ordering::Acquire)
            || Instant::now() >= deadline
            || {
                let _reconnecting = Reconnecting::start(shared);
                runtime.stream_progress.wait_for_change(observed, deadline).is_none()
            }
        {
            return Err(error);
        }
        first_error = Some(error);
    }
}
