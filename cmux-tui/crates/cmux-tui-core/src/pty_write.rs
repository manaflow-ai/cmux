//! Writes to a terminal's PTY: the asynchronous input sink every input
//! goes through (p05-ipc-157), and the bounded write left for the callers
//! that must know what reached the PTY now (clear-history fallback keys).
//!
//! The sink makes one nonblocking try. What the child does not take now
//! waits in a bounded per-terminal backlog, in order, and the terminal read
//! loop (`mux::terminal_work::read_loop`, the daemon's IO reactor for PTYs)
//! writes it out when the PTY has room. No input caller waits for the child
//! to read: a full backlog refuses the whole payload, and a PTY that fails
//! tells each sender of the bytes it will never write once
//! ([`InputReceipt::failed`]). This is Chrome's mojo data pipe producer
//! (mojo/core/data_pipe_producer_dispatcher.cc): `WriteData` never blocks,
//! it takes what fits the pipe's capacity or fails with
//! `MOJO_RESULT_SHOULD_WAIT`, and the IO thread moves the bytes on as the
//! consumer drains them (mojo/core/channel_posix.cc, `WriteNoLock` queues
//! the unwritten rest and `OnFileCanWriteWithoutBlocking` flushes it).

use std::collections::VecDeque;
use std::io;
use std::os::fd::{AsRawFd, BorrowedFd, OwnedFd, RawFd};
use std::sync::{Arc, Weak};
use std::time::{Duration, Instant};

use crate::Mux;
use crate::mux::terminal_work::read_loop::{ReadFlow, ReadKick, ReadSource, TerminalReads};
use crate::panic_free::RecoverPoison;
use cmux_threads::sync::Mutex;

/// Input bytes one terminal's sink holds while its child does not read: a
/// large paste fits whole, and a child that never reads costs at most this.
pub(crate) const INPUT_SINK_CAPACITY: usize = 4 << 20;

/// Why queued input never reached the PTY (`input-failed.reason`).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum InputFailure {
    /// The backlog was full: nothing of the payload was written.
    Overflow,
    /// The PTY failed or its terminal closed.
    WriteFailed,
}

impl InputFailure {
    pub(crate) fn as_str(self) -> &'static str {
        match self {
            InputFailure::Overflow => "overflow",
            InputFailure::WriteFailed => "write_failed",
        }
    }
}

/// Told what became of input a sender queued. A sender's queued chunks are
/// reported together: a PTY that fails with 10k queued keys of one stream
/// tells that stream once.
pub(crate) trait InputReceipt: Send + Sync {
    /// `bytes` of this sender's queued input will never reach the PTY.
    fn failed(&self, reason: InputFailure, bytes: usize);

    /// The last byte of one of this sender's queued chunks reached the PTY.
    fn written(&self) {}
}

/// What [`PtyInputSink::submit`] did with a payload it took.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum Submitted {
    /// The PTY took all of it now.
    Written,
    /// Some or all of it waits in the backlog; the receipt hears the rest.
    Queued,
}

/// A refused input payload: nothing of it was written or queued.
#[derive(Debug)]
pub(crate) enum InputSinkError {
    /// The backlog holds `queued` bytes and `len` more would pass
    /// [`INPUT_SINK_CAPACITY`].
    Overflow { queued: usize, len: usize },
    /// The PTY failed earlier, or the terminal closed.
    Closed(io::ErrorKind),
}

impl InputSinkError {
    pub(crate) fn failure(&self) -> InputFailure {
        match self {
            InputSinkError::Overflow { .. } => InputFailure::Overflow,
            InputSinkError::Closed(_) => InputFailure::WriteFailed,
        }
    }
}

impl std::fmt::Display for InputSinkError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            InputSinkError::Overflow { queued, len } => write!(
                f,
                "terminal input backlog is full ({queued} bytes queued, {len} more refused)"
            ),
            InputSinkError::Closed(kind) => write!(f, "terminal input is closed: {kind}"),
        }
    }
}

impl std::error::Error for InputSinkError {}

impl From<InputSinkError> for io::Error {
    fn from(error: InputSinkError) -> io::Error {
        let kind = match &error {
            InputSinkError::Overflow { .. } => io::ErrorKind::WouldBlock,
            InputSinkError::Closed(kind) => *kind,
        };
        io::Error::new(kind, error)
    }
}

/// One payload's unwritten rest and who sent it.
struct Chunk {
    bytes: Vec<u8>,
    written: usize,
    receipt: Option<Arc<dyn InputReceipt>>,
}

/// Queued input in arrival order, at most [`INPUT_SINK_CAPACITY`] bytes.
#[derive(Default)]
struct InputBacklog {
    chunks: VecDeque<Chunk>,
    bytes: usize,
}

/// Each sender of failed input with its byte count, in first-queued order.
type FailedInput = Vec<(Arc<dyn InputReceipt>, usize)>;

impl InputBacklog {
    fn is_empty(&self) -> bool {
        self.chunks.is_empty()
    }

    fn admits(&self, len: usize) -> bool {
        self.bytes.saturating_add(len) <= INPUT_SINK_CAPACITY
    }

    /// Queues `bytes` behind what is queued; the caller checked [`Self::admits`].
    fn push(&mut self, bytes: &[u8], receipt: Option<Arc<dyn InputReceipt>>) {
        if !bytes.is_empty() {
            self.bytes += bytes.len();
            self.chunks.push_back(Chunk { bytes: bytes.to_vec(), written: 0, receipt });
        }
    }

    /// Writes from the front to `fd` until the PTY takes nothing more or
    /// the backlog is empty. The senders of chunks written whole go to `done`.
    fn write_out(&mut self, fd: RawFd, done: &mut Vec<Arc<dyn InputReceipt>>) -> io::Result<()> {
        while let Some(chunk) = self.chunks.front_mut() {
            let rest = chunk.bytes.get(chunk.written..).unwrap_or_default();
            let count = write_now(fd, rest)?;
            chunk.written += count;
            self.bytes -= count;
            if chunk.written < chunk.bytes.len() {
                return Ok(());
            }
            if let Some(chunk) = self.chunks.pop_front()
                && let Some(receipt) = chunk.receipt
            {
                done.push(receipt);
            }
        }
        Ok(())
    }

    /// Drops every queued byte and returns each sender with its count.
    fn fail_all(&mut self) -> FailedInput {
        let mut failed: FailedInput = Vec::new();
        for chunk in self.chunks.drain(..) {
            let Some(receipt) = chunk.receipt else { continue };
            let unwritten = chunk.bytes.len() - chunk.written;
            match failed.iter_mut().find(|(seen, _)| Arc::ptr_eq(seen, &receipt)) {
                Some((_, bytes)) => *bytes += unwritten,
                None => failed.push((receipt, unwritten)),
            }
        }
        self.bytes = 0;
        failed
    }
}

fn report_failed(failed: FailedInput, reason: InputFailure) {
    for (receipt, bytes) in failed {
        receipt.failed(reason, bytes);
    }
}

/// Writes what the nonblocking `fd` takes of `bytes` now: 0 when the PTY's
/// input queue is full.
fn write_now(fd: RawFd, bytes: &[u8]) -> io::Result<usize> {
    let mut written = 0;
    while let Some(rest) = bytes.get(written..).filter(|rest| !rest.is_empty()) {
        // SAFETY: the sink owns `fd` (its duplicate of the master) for its
        // whole life; the pointer and length come from the live `rest` slice.
        let count = unsafe { libc::write(fd, rest.as_ptr().cast(), rest.len()) };
        if count > 0 {
            written += (count as usize).min(rest.len());
            continue;
        }
        if count == 0 {
            return Err(io::Error::new(io::ErrorKind::WriteZero, "PTY took no input"));
        }
        let error = io::Error::last_os_error();
        match error.kind() {
            io::ErrorKind::Interrupted => {}
            io::ErrorKind::WouldBlock => break,
            _ => return Err(error),
        }
    }
    Ok(written)
}

/// A local terminal's input sink: its own nonblocking descriptor of the
/// PTY master, the backlog, and the read-loop registration that drains it.
pub(crate) struct PtyInputSink {
    /// Lock carve-out: held to write what the PTY takes without waiting
    /// (the descriptor is nonblocking), to queue, and to keep the drain's
    /// registration; never across a wait, and receipts are told after it
    /// is released. A submit takes it under the PTY runtime lock, a drain
    /// with no other lock held; nothing holding it takes a ranked lock.
    state: Mutex<SinkState>,
    /// A duplicate of the master: the file is nonblocking, and the read
    /// loop watches this descriptor for room to write.
    fd: OwnedFd,
    /// The owner whose read loop drains the backlog.
    owner: Weak<Mux>,
}

#[derive(Default)]
struct SinkState {
    backlog: InputBacklog,
    /// Why nothing more is written: the PTY failed or the terminal closed.
    closed: Option<io::ErrorKind>,
    /// The drain's registration, from the first backlog on.
    drain: Option<ReadKick>,
}

impl PtyInputSink {
    /// The sink of the PTY master `master_fd`. The master's open file is
    /// switched to nonblocking mode: its reader already reads only after
    /// readiness and takes `WouldBlock` as nothing to read, and every input
    /// write goes through this sink.
    pub(crate) fn new(master_fd: RawFd, owner: Weak<Mux>) -> io::Result<Arc<Self>> {
        // SAFETY: the caller's master keeps `master_fd` open for the call;
        // the duplicate is a new descriptor the sink owns.
        let fd = unsafe { BorrowedFd::borrow_raw(master_fd) }.try_clone_to_owned()?;
        set_nonblocking(fd.as_raw_fd())?;
        Ok(Arc::new(Self { state: Mutex::new(SinkState::default()), fd, owner }))
    }

    /// Writes `bytes` behind every earlier input without waiting: what the
    /// PTY takes now is written, the rest is queued for the read loop.
    /// Refused whole when the backlog cannot hold it or the PTY failed.
    /// `receipt` hears if queued bytes later reach the PTY or never do.
    pub(crate) fn submit(
        self: &Arc<Self>,
        bytes: &[u8],
        receipt: Option<Arc<dyn InputReceipt>>,
    ) -> Result<Submitted, InputSinkError> {
        let mut state = self.state.lock().recover_poison();
        if let Some(kind) = state.closed {
            return Err(InputSinkError::Closed(kind));
        }
        if !state.backlog.admits(bytes.len()) {
            let queued = state.backlog.bytes;
            return Err(InputSinkError::Overflow { queued, len: bytes.len() });
        }
        if !state.backlog.is_empty() {
            // The drain is armed or running: it writes these after the rest.
            state.backlog.push(bytes, receipt);
            return Ok(Submitted::Queued);
        }
        let taken = match write_now(self.fd.as_raw_fd(), bytes) {
            Ok(taken) => taken,
            Err(error) => {
                state.closed = Some(error.kind());
                return Err(InputSinkError::Closed(error.kind()));
            }
        };
        let Some(rest) = bytes.get(taken..).filter(|rest| !rest.is_empty()) else {
            return Ok(Submitted::Written);
        };
        state.backlog.push(rest, receipt);
        if let Some(drain) = state.drain.as_ref() {
            drain.kick();
            return Ok(Submitted::Queued);
        }
        match self.register_drain() {
            Some(drain) => state.drain = Some(drain),
            None => {
                // Nothing would ever write the backlog: fail it now.
                state.closed = Some(io::ErrorKind::BrokenPipe);
                let failed = state.backlog.fail_all();
                drop(state);
                report_failed(failed, InputFailure::WriteFailed);
            }
        }
        Ok(Submitted::Queued)
    }

    /// Unwritten queued bytes.
    pub(crate) fn backlog_bytes(&self) -> usize {
        self.state.lock().recover_poison().backlog.bytes
    }

    /// Fails what is queued and refuses later input: the terminal ended.
    pub(crate) fn close(&self) {
        let mut state = self.state.lock().recover_poison();
        if state.closed.is_some() {
            return;
        }
        state.closed = Some(io::ErrorKind::BrokenPipe);
        let failed = state.backlog.fail_all();
        let drain = state.drain.take();
        drop(state);
        report_failed(failed, InputFailure::WriteFailed);
        // Its next run sees the close and leaves the loop.
        if let Some(drain) = drain {
            drain.kick();
        }
    }

    fn register_drain(self: &Arc<Self>) -> Option<ReadKick> {
        let source = Box::new(PtyInputDrain { sink: self.clone() });
        let fd = self.fd.as_raw_fd();
        let registered = match self.owner.upgrade() {
            Some(owner) => owner.terminal_reads().register_writable(fd, source),
            // Dropped at once: its loop ends after this sink's drain does.
            None => TerminalReads::new().register_writable(fd, source),
        };
        registered.ok()
    }

    /// One drain run: writes what the PTY takes now.
    fn drain(&self) -> ReadFlow {
        let mut done = Vec::new();
        let mut state = self.state.lock().recover_poison();
        if state.closed.is_some() {
            return ReadFlow::Finished;
        }
        let (flow, failed) = match state.backlog.write_out(self.fd.as_raw_fd(), &mut done) {
            Ok(()) if state.backlog.is_empty() => (ReadFlow::Park, Vec::new()),
            Ok(()) => (ReadFlow::Continue, Vec::new()),
            Err(error) => {
                state.closed = Some(error.kind());
                state.drain = None;
                (ReadFlow::Finished, state.backlog.fail_all())
            }
        };
        drop(state);
        for receipt in done {
            receipt.written();
        }
        report_failed(failed, InputFailure::WriteFailed);
        flow
    }
}

fn set_nonblocking(fd: RawFd) -> io::Result<()> {
    // SAFETY: the caller owns `fd`; F_GETFL touches no memory.
    let flags = unsafe { libc::fcntl(fd, libc::F_GETFL) };
    if flags < 0 {
        return Err(io::Error::last_os_error());
    }
    // SAFETY: as above; F_SETFL only adds O_NONBLOCK to the flags just read.
    if flags & libc::O_NONBLOCK == 0
        && unsafe { libc::fcntl(fd, libc::F_SETFL, flags | libc::O_NONBLOCK) } < 0
    {
        return Err(io::Error::last_os_error());
    }
    Ok(())
}

/// The sink's drain on the read loop: runs when the PTY has room or the
/// sink kicked it, parks once the backlog is empty, and leaves the loop
/// when the PTY failed or the terminal closed.
struct PtyInputDrain {
    sink: Arc<PtyInputSink>,
}

impl ReadSource for PtyInputDrain {
    fn run(&mut self) -> ReadFlow {
        self.sink.drain()
    }

    fn finish(self: Box<Self>) {}
}

/// The PTY runtime's handle on its sink: the runtime's end closes it, so a
/// parked drain leaves the read loop and the duplicate descriptor closes.
pub(crate) struct LocalInput(Arc<PtyInputSink>);

impl LocalInput {
    pub(crate) fn new(sink: Arc<PtyInputSink>) -> Self {
        Self(sink)
    }

    pub(crate) fn sink(&self) -> &Arc<PtyInputSink> {
        &self.0
    }
}

impl Drop for LocalInput {
    fn drop(&mut self) {
        self.0.close();
    }
}

#[derive(Debug)]
pub(crate) struct BoundedWriteFailure {
    pub error: io::Error,
    pub delivered: usize,
}

/// Writes directly to a PTY descriptor and restores its original status flags.
/// The caller must keep the descriptor alive and serialize writes for its lifetime.
/// No buffered writer flush is needed: every byte is written through the descriptor.
pub(crate) fn write_bounded(
    fd: RawFd,
    bytes: &[u8],
    timeout: Duration,
    timeout_message: &'static str,
) -> Result<(), BoundedWriteFailure> {
    let mut delivered = 0;
    let result = (|| {
        let mut nonblocking = NonblockingFdGuard::install(fd)?;
        // A timeout too large to represent never expires.
        let deadline = Instant::now().checked_add(timeout);
        while delivered < bytes.len() {
            if deadline.is_some_and(|deadline| Instant::now() >= deadline) {
                return Err(io::Error::new(io::ErrorKind::TimedOut, timeout_message));
            }
            let Some(remaining) = bytes.get(delivered..) else { break };
            // SAFETY: the caller keeps `fd` open (this function's contract);
            // the pointer and length come from the live `remaining` slice.
            let written = unsafe { libc::write(fd, remaining.as_ptr().cast(), remaining.len()) };
            if written > 0 {
                delivered += written as usize;
                continue;
            }
            if written == 0 {
                return Err(io::Error::new(io::ErrorKind::WriteZero, "PTY write returned zero"));
            }
            let error = io::Error::last_os_error();
            if error.kind() == io::ErrorKind::Interrupted {
                continue;
            }
            if error.kind() != io::ErrorKind::WouldBlock {
                return Err(error);
            }
            let wait = deadline
                .map_or(timeout, |deadline| deadline.saturating_duration_since(Instant::now()));
            if wait.is_zero() {
                return Err(io::Error::new(io::ErrorKind::TimedOut, timeout_message));
            }
            let millis = wait.as_nanos().saturating_add(999_999) / 1_000_000;
            let mut poll_fd = libc::pollfd { fd, events: libc::POLLOUT, revents: 0 };
            // SAFETY: `poll_fd` is one valid, exclusively borrowed pollfd and the
            // count is 1, so poll writes only its `revents`.
            let ready =
                unsafe { libc::poll(&mut poll_fd, 1, millis.clamp(1, i32::MAX as u128) as i32) };
            if ready == 0 {
                return Err(io::Error::new(io::ErrorKind::TimedOut, timeout_message));
            }
            if ready < 0 {
                let error = io::Error::last_os_error();
                if error.kind() != io::ErrorKind::Interrupted {
                    return Err(error);
                }
            } else if poll_fd.revents & libc::POLLNVAL != 0 {
                return Err(io::Error::new(io::ErrorKind::BrokenPipe, "PTY fd is invalid"));
            }
        }
        nonblocking.restore()
    })();
    result.map_err(|error| BoundedWriteFailure { error, delivered })
}

struct NonblockingFdGuard {
    fd: RawFd,
    original_flags: libc::c_int,
    restored: bool,
}

impl NonblockingFdGuard {
    fn install(fd: RawFd) -> io::Result<Self> {
        // SAFETY: `write_bounded`'s caller keeps `fd` open; F_GETFL touches no memory.
        let original_flags = unsafe { libc::fcntl(fd, libc::F_GETFL) };
        if original_flags < 0 {
            return Err(io::Error::last_os_error());
        }
        // SAFETY: as above; F_SETFL only adds O_NONBLOCK to the flags just read.
        if unsafe { libc::fcntl(fd, libc::F_SETFL, original_flags | libc::O_NONBLOCK) } < 0 {
            return Err(io::Error::last_os_error());
        }
        Ok(Self { fd, original_flags, restored: false })
    }

    fn restore(&mut self) -> io::Result<()> {
        if !self.restored {
            // SAFETY: the guard lives inside `write_bounded`, whose caller keeps
            // `fd` open; F_SETFL restores the flags read at install.
            if unsafe { libc::fcntl(self.fd, libc::F_SETFL, self.original_flags) } < 0 {
                return Err(io::Error::last_os_error());
            }
            self.restored = true;
        }
        Ok(())
    }
}

impl Drop for NonblockingFdGuard {
    fn drop(&mut self) {
        let _ = self.restore();
    }
}

#[cfg(test)]
#[path = "pty_write_tests.rs"]
mod tests;
