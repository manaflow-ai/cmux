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
//! - A full port refuses at once with a typed error: nothing is dropped silently and nothing waits.
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

/// The most bytes one terminal's port holds; more is refused (`terminal.input_busy`). Two of the largest frames.
const INPUT_PORT_BYTE_CAPACITY: usize = 2 * MAX_FRAME_PAYLOAD;
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

struct PortFrame {
    kind: MessageKind,
    bytes: Vec<u8>,
}

#[derive(Default)]
struct PortState {
    frames: VecDeque<PortFrame>,
    queued_bytes: usize,
    writer_running: bool,
    closed: bool,
}

#[derive(Default)]
struct PortShared {
    state: Mutex<PortState>,
    changed: Condvar,
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
    ) -> Result<(), InputRefused> {
        if bytes.len() > MAX_FRAME_PAYLOAD {
            return Err(InputRefused::TooLarge);
        }
        let mut state = self.shared.state.lock().unwrap_or_else(PoisonError::into_inner);
        let total = state.queued_bytes.checked_add(bytes.len());
        if total.is_none_or(|total| total > INPUT_PORT_BYTE_CAPACITY) {
            return Err(InputRefused::Busy);
        }
        if !state.writer_running {
            let shared = Arc::clone(&self.shared);
            let terminal = Arc::downgrade(terminal);
            std::thread::Builder::new()
                .name("terminal-input-port".into())
                .stack_size(INPUT_PORT_STACK_BYTES)
                .spawn(move || run_writer(&shared, &terminal))
                .map_err(InputRefused::NoWriter)?;
            state.writer_running = true;
        }
        state.queued_bytes = total.unwrap_or(state.queued_bytes);
        state.frames.push_back(PortFrame { kind, bytes: bytes.to_vec() });
        drop(state);
        self.shared.changed.notify_one();
        Ok(())
    }
}

/// The writer: the next frame in order, or `None` when the port closed or stayed idle for
/// [`INPUT_PORT_IDLE_EXIT`] (it then marks itself stopped, under the lock, so the next input starts a new one).
fn next_frame(shared: &PortShared) -> Option<PortFrame> {
    let mut state = shared.state.lock().unwrap_or_else(PoisonError::into_inner);
    let idle_until = Instant::now() + INPUT_PORT_IDLE_EXIT;
    loop {
        if let Some(frame) = state.frames.pop_front() {
            state.queued_bytes = state.queued_bytes.saturating_sub(frame.bytes.len());
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

fn run_writer(shared: &PortShared, terminal: &Weak<PtyTerminalRuntime>) {
    while let Some(frame) = next_frame(shared) {
        // The terminal is gone: its port closed, and nothing is left to write to.
        let Some(runtime) = terminal.upgrade() else { return };
        if let Err(error) = write_with_reconnect(&runtime, frame.kind, &frame.bytes) {
            eprintln!(
                "cmux-tui: terminal input not written ({} bytes, already accepted): {error}",
                frame.bytes.len()
            );
        }
    }
}

/// One frame on the terminal's current host connection, across a lost connection: the rule of
/// `Surface::send_hosted_input`, on the port's thread, reading the published route instead of the runtime lock.
fn write_with_reconnect(
    runtime: &PtyTerminalRuntime,
    kind: MessageKind,
    bytes: &[u8],
) -> std::io::Result<()> {
    let deadline = Instant::now() + HOST_INPUT_RECONNECT_WAIT;
    let mut first_error = None;
    loop {
        // Read the revision before the send: an install after it wakes the wait below, so no reconnect is missed.
        let observed = runtime.stream_progress.revision();
        let route = runtime.input_route.load_full();
        let sent = match route.as_deref() {
            Some(InputRoute::Hosted(route)) => route.send(kind, bytes),
            // Keep-on-exit: the final screen drops input; input that already failed keeps its error.
            Some(InputRoute::Exited) => return first_error.map_or(Ok(()), Err),
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
            || Instant::now() >= deadline
            || runtime.stream_progress.wait_for_change(observed, deadline).is_none()
        {
            return Err(error);
        }
        first_error = Some(error);
    }
}
