//! Writes to PTY masters: [`write_bounded`], one bounded write on a master
//! the daemon reads blocking (image paste, the clear-history keyboard
//! fallback), and the [`PtyWriter`] for non-blocking masters.
//!
//! The `pty-writer` thread writes the input of every terminal registered
//! with it. A request never writes such a PTY itself: it hands its bytes to
//! the terminal's [`PtyInputQueue`] and returns, so a program that stops
//! reading its input stalls only its own queue, never the request, the
//! person's next key or another terminal. The thread polls `POLLOUT` only on
//! masters with queued bytes and writes what each one takes. Chrome's IO
//! thread does the same for its pipes: one thread watches every descriptor
//! (base/message_loop/message_pump_epoll.cc, `WatchFileDescriptor`) and a
//! sender queues instead of blocking (mojo/core/channel_posix.cc,
//! `outgoing_messages_` flushed on writability).
//!
//! Keys travel in a priority lane ([`InputLane::Key`]): of the masters that
//! take bytes, the terminals whose next bytes are keys go first, and a bulk
//! queue (a paste, scripted text) gets at most [`BULK_SLICE`] bytes per
//! turn, so a key waits for at most one slice per other busy terminal, as
//! Chrome runs input ahead of normal work
//! (content/browser/scheduler/browser_task_queues.h, `kUserBlocking`). One
//! terminal's bytes keep their order: a key never overtakes a paste sent to
//! the same terminal before it.

use std::collections::VecDeque;
use std::io;
use std::os::fd::{AsRawFd, OwnedFd, RawFd};
use std::sync::Arc;
use std::sync::atomic::{AtomicI32, AtomicU64, AtomicUsize, Ordering};
use std::sync::mpsc::{self, Receiver, Sender, TryRecvError};
use std::time::{Duration, Instant};

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

/// Which lane bytes travel in to their terminal ([`PtyWriter`]).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum InputLane {
    /// Keys, clicks and other interactive input: served before bulk bytes.
    Key,
    /// Pastes and scripted text: written a slice per turn.
    Bulk,
}

/// The most bytes one terminal's queue holds before bulk input is refused:
/// a program that reads nothing keeps at most this much.
const QUEUE_LIMIT_BYTES: usize = 16 * 1024 * 1024;
/// What keys may add past [`QUEUE_LIMIT_BYTES`], so a key still goes in
/// behind a paste that filled the queue.
const KEY_HEADROOM_BYTES: usize = 64 * 1024;
/// The most bytes of one bulk queue written per turn.
const BULK_SLICE: usize = 16 * 1024;
/// `QueueState::failure` while the terminal takes input.
const NO_FAILURE: i32 = 0;
/// `QueueState::failure` once the master hung up without an OS error.
const HUNG_UP: i32 = -1;

/// The `pty-writer` thread and the handle that registers terminals with it.
/// The thread ends once this and every [`PtyInputQueue`] are dropped.
pub(crate) struct PtyWriter {
    commands: Option<Sender<Command>>,
    bell: Arc<Doorbell>,
    next_id: AtomicU64,
}

impl PtyWriter {
    /// Starts the `pty-writer` thread (USER_INITIATED).
    pub(crate) fn start() -> io::Result<Self> {
        let bell = Arc::new(Doorbell::new()?);
        let (commands, inbox) = mpsc::channel();
        let thread_bell = bell.clone();
        cmux_threads::spawn(
            "pty-writer",
            crate::thread_qos::ThreadType::Interactive.qos(),
            move || run(&inbox, &thread_bell),
        )?;
        Ok(Self { commands: Some(commands), bell, next_id: AtomicU64::new(1) })
    }

    /// Takes `master` (a dup the writer closes when the queue goes) and
    /// makes it non-blocking. Only for a master nobody reads blocking:
    /// `O_NONBLOCK` belongs to the open file description every dup shares.
    pub(crate) fn register(&self, master: OwnedFd) -> io::Result<PtyInputQueue> {
        set_nonblocking(master.as_raw_fd())?;
        let commands = self.commands.clone().ok_or_else(writer_stopped)?;
        let id = self.next_id.fetch_add(1, Ordering::Relaxed);
        let state = Arc::new(QueueState::default());
        commands
            .send(Command::Open { id, master, state: state.clone() })
            .map_err(|_| writer_stopped())?;
        self.bell.ring();
        Ok(PtyInputQueue(Arc::new(QueueHandle {
            id,
            state,
            commands: Some(commands),
            bell: self.bell.clone(),
        })))
    }
}

impl Drop for PtyWriter {
    fn drop(&mut self) {
        // The sender goes before the ring, so the wake sees it gone.
        drop(self.commands.take());
        self.bell.ring();
    }
}

/// One terminal's input queue on the [`PtyWriter`]. Clones share it; the
/// last one dropped closes it, and bytes still queued then go with the
/// terminal.
#[derive(Clone)]
pub(crate) struct PtyInputQueue(Arc<QueueHandle>);

struct QueueHandle {
    id: u64,
    state: Arc<QueueState>,
    commands: Option<Sender<Command>>,
    bell: Arc<Doorbell>,
}

impl PtyInputQueue {
    /// Queues `bytes` for the terminal's program and returns at once. Fails,
    /// with nothing of `bytes` queued, when the master failed or hung up or
    /// when the queue is full (its program reads nothing).
    pub(crate) fn send(&self, bytes: &[u8], lane: InputLane) -> io::Result<()> {
        let handle = &*self.0;
        handle.state.check()?;
        if bytes.is_empty() {
            return Ok(());
        }
        let limit = match lane {
            InputLane::Key => QUEUE_LIMIT_BYTES + KEY_HEADROOM_BYTES,
            InputLane::Bulk => QUEUE_LIMIT_BYTES,
        };
        handle
            .state
            .pending
            .fetch_update(Ordering::AcqRel, Ordering::Acquire, |pending| {
                pending.checked_add(bytes.len()).filter(|total| *total <= limit)
            })
            .map_err(|_| {
                io::Error::new(
                    io::ErrorKind::WouldBlock,
                    "the terminal's input queue is full: its program does not read its input",
                )
            })?;
        let command = Command::Write { id: handle.id, lane, bytes: bytes.to_vec() };
        if handle.commands.as_ref().is_none_or(|commands| commands.send(command).is_err()) {
            handle.state.pending.fetch_sub(bytes.len(), Ordering::AcqRel);
            return Err(writer_stopped());
        }
        handle.bell.ring();
        Ok(())
    }

    /// Bytes queued that the master has not taken yet.
    pub(crate) fn pending(&self) -> usize {
        self.0.state.pending.load(Ordering::Acquire)
    }
}

impl Drop for QueueHandle {
    fn drop(&mut self) {
        if let Some(commands) = self.commands.take() {
            let _ = commands.send(Command::Close { id: self.id });
        }
        self.bell.ring();
    }
}

/// What a queue's senders and the writer share.
#[derive(Default)]
struct QueueState {
    /// Bytes sent and not yet written or dropped.
    pending: AtomicUsize,
    /// [`NO_FAILURE`], [`HUNG_UP`] or the OS error that ended the master.
    failure: AtomicI32,
}

impl QueueState {
    fn check(&self) -> io::Result<()> {
        match self.failure.load(Ordering::Acquire) {
            NO_FAILURE => Ok(()),
            HUNG_UP => Err(io::Error::new(io::ErrorKind::BrokenPipe, "the terminal's PTY closed")),
            code => Err(io::Error::from_raw_os_error(code)),
        }
    }
}

fn writer_stopped() -> io::Error {
    io::Error::new(io::ErrorKind::BrokenPipe, "the PTY writer stopped")
}

enum Command {
    Open { id: u64, master: OwnedFd, state: Arc<QueueState> },
    Write { id: u64, lane: InputLane, bytes: Vec<u8> },
    Close { id: u64 },
}

/// Wakes the writer: a non-blocking pipe it polls beside the masters. Every
/// command rings after it is sent and the writer drains the pipe before the
/// commands, so no command waits for a later wake.
struct Doorbell {
    read: OwnedFd,
    write: OwnedFd,
}

impl Doorbell {
    fn new() -> io::Result<Self> {
        let (read, write) = io::pipe()?;
        let (read, write) = (OwnedFd::from(read), OwnedFd::from(write));
        set_nonblocking(read.as_raw_fd())?;
        set_nonblocking(write.as_raw_fd())?;
        Ok(Self { read, write })
    }

    /// A full pipe already wakes the writer, so a refused byte is fine.
    fn ring(&self) {
        let byte = [1u8];
        loop {
            // SAFETY: `write` is this doorbell's open pipe end; one byte from
            // a live local array.
            let written = unsafe { libc::write(self.write.as_raw_fd(), byte.as_ptr().cast(), 1) };
            if written >= 0 || io::Error::last_os_error().kind() != io::ErrorKind::Interrupted {
                return;
            }
        }
    }

    fn drain(&self) {
        let mut buffer = [0u8; 256];
        loop {
            // SAFETY: `read` is this doorbell's open pipe end; the buffer is
            // a live, exclusively borrowed local array of that length.
            let read = unsafe {
                libc::read(self.read.as_raw_fd(), buffer.as_mut_ptr().cast(), buffer.len())
            };
            if read < 0 && io::Error::last_os_error().kind() == io::ErrorKind::Interrupted {
                continue;
            }
            if read <= 0 || (read as usize) < buffer.len() {
                return;
            }
        }
    }
}

/// The `pty-writer` loop: apply the commands, wait until a master with
/// queued bytes takes input or the doorbell rings, write. No timer: idle,
/// it sleeps in `poll` until a command comes.
fn run(inbox: &Receiver<Command>, bell: &Doorbell) {
    let mut terminals: Vec<Terminal> = Vec::new();
    let mut turn = 0usize;
    loop {
        bell.drain();
        let connected = take_commands(inbox, &mut terminals);
        if !connected && terminals.is_empty() {
            return;
        }
        let ready = wait_writable(bell, &mut terminals);
        serve(&mut terminals, &ready, turn);
        turn = turn.wrapping_add(1);
    }
}

/// Applies every command sent so far; false once every sender is gone.
fn take_commands(inbox: &Receiver<Command>, terminals: &mut Vec<Terminal>) -> bool {
    loop {
        match inbox.try_recv() {
            Ok(Command::Open { id, master, state }) => {
                terminals.push(Terminal { id, master, state, chunks: VecDeque::new() });
            }
            Ok(Command::Write { id, lane, bytes }) => {
                if let Some(terminal) = terminals.iter_mut().find(|terminal| terminal.id == id) {
                    terminal.push(lane, bytes);
                }
            }
            Ok(Command::Close { id }) => {
                if let Some(index) = terminals.iter().position(|terminal| terminal.id == id) {
                    terminals.swap_remove(index).drop_queued();
                }
            }
            Err(TryRecvError::Empty) => return true,
            Err(TryRecvError::Disconnected) => return false,
        }
    }
}

/// Waits for the doorbell or a master with queued bytes that takes input.
/// Returns the indexes of the masters that take input; one that hung up
/// fails its queue.
fn wait_writable(bell: &Doorbell, terminals: &mut [Terminal]) -> Vec<usize> {
    let mut polled = Vec::new();
    let mut fds =
        vec![libc::pollfd { fd: bell.read.as_raw_fd(), events: libc::POLLIN, revents: 0 }];
    for (index, terminal) in terminals.iter().enumerate() {
        if !terminal.chunks.is_empty() {
            polled.push(index);
            fds.push(libc::pollfd {
                fd: terminal.master.as_raw_fd(),
                events: libc::POLLOUT,
                revents: 0,
            });
        }
    }
    loop {
        // SAFETY: `fds` is a live, exclusively borrowed array of
        // `fds.len()` pollfds over descriptors this thread owns.
        let ready = unsafe { libc::poll(fds.as_mut_ptr(), fds.len() as libc::nfds_t, -1) };
        if ready >= 0 || io::Error::last_os_error().kind() != io::ErrorKind::Interrupted {
            break;
        }
    }
    let mut writable = Vec::new();
    for (index, fd) in polled.into_iter().zip(fds.iter().skip(1)) {
        let Some(terminal) = terminals.get_mut(index) else { continue };
        if fd.revents & libc::POLLOUT != 0 {
            writable.push(index);
        } else if fd.revents & (libc::POLLHUP | libc::POLLERR | libc::POLLNVAL) != 0 {
            terminal.fail(HUNG_UP);
        }
    }
    writable
}

/// The order bulk queues of `ready` masters are served in on `turn`: one
/// later each turn, so no bulk queue always goes first.
fn serve_order(ready: usize, turn: usize) -> impl Iterator<Item = usize> {
    (0..ready).map(move |step| (turn.wrapping_add(step)) % ready.max(1))
}

/// One turn over the masters that take input: every key lane first, then at
/// most [`BULK_SLICE`] of each bulk queue that is not full.
fn serve(terminals: &mut [Terminal], ready: &[usize], turn: usize) {
    let mut full = vec![false; ready.len()];
    for (slot, index) in ready.iter().enumerate() {
        if let (Some(terminal), Some(full)) = (terminals.get_mut(*index), full.get_mut(slot)) {
            *full = !terminal.write_lane(InputLane::Key, usize::MAX);
        }
    }
    for slot in serve_order(ready.len(), turn) {
        if full.get(slot).copied().unwrap_or(true) {
            continue;
        }
        if let Some(terminal) = ready.get(slot).and_then(|index| terminals.get_mut(*index)) {
            terminal.write_lane(InputLane::Bulk, BULK_SLICE);
        }
    }
}

/// A terminal on the writer thread: its master and the bytes it has not
/// taken yet, in order.
struct Terminal {
    id: u64,
    master: OwnedFd,
    state: Arc<QueueState>,
    chunks: VecDeque<Chunk>,
}

struct Chunk {
    lane: InputLane,
    bytes: Vec<u8>,
    written: usize,
}

impl Terminal {
    fn push(&mut self, lane: InputLane, bytes: Vec<u8>) {
        if self.state.failure.load(Ordering::Acquire) != NO_FAILURE {
            self.state.pending.fetch_sub(bytes.len(), Ordering::AcqRel);
            return;
        }
        // Keys typed in a burst go out in one write.
        if let Some(last) = self.chunks.back_mut()
            && last.lane == lane
            && last.bytes.len() < BULK_SLICE
        {
            last.bytes.extend_from_slice(&bytes);
            return;
        }
        self.chunks.push_back(Chunk { lane, bytes, written: 0 });
    }

    /// Writes the queued bytes while the next ones are in `lane`, at most
    /// `budget`. False when the master took less than it was offered (it is
    /// full) or failed.
    fn write_lane(&mut self, lane: InputLane, budget: usize) -> bool {
        let mut left = budget;
        while left > 0 {
            let Some(chunk) = self.chunks.front_mut().filter(|chunk| chunk.lane == lane) else {
                return true;
            };
            let rest = chunk.bytes.get(chunk.written..).unwrap_or_default();
            let offered = rest.get(..rest.len().min(left)).unwrap_or_default();
            let offered_len = offered.len();
            match write_some(self.master.as_raw_fd(), offered) {
                Ok(written) => {
                    chunk.written += written;
                    left -= written;
                    let finished = chunk.written >= chunk.bytes.len();
                    self.state.pending.fetch_sub(written, Ordering::AcqRel);
                    if finished {
                        self.chunks.pop_front();
                    }
                    if written < offered_len {
                        return false;
                    }
                }
                Err(error) if error.kind() == io::ErrorKind::WouldBlock => return false,
                Err(error) => {
                    self.fail(
                        error.raw_os_error().filter(|code| *code != NO_FAILURE).unwrap_or(HUNG_UP),
                    );
                    return false;
                }
            }
        }
        true
    }

    /// The master failed: what is queued is dropped and every later send
    /// fails with `code`.
    fn fail(&mut self, code: i32) {
        self.state.failure.store(code, Ordering::Release);
        self.drop_queued();
    }

    fn drop_queued(&mut self) {
        let queued: usize = self
            .chunks
            .drain(..)
            .map(|chunk| chunk.bytes.len().saturating_sub(chunk.written))
            .sum();
        self.state.pending.fetch_sub(queued, Ordering::AcqRel);
    }
}

/// One `write(2)` of `bytes` (not empty) on the non-blocking `fd`.
fn write_some(fd: RawFd, bytes: &[u8]) -> io::Result<usize> {
    loop {
        // SAFETY: the writer thread owns `fd` (a registered master); the
        // pointer and length come from the live `bytes` slice.
        let written = unsafe { libc::write(fd, bytes.as_ptr().cast(), bytes.len()) };
        if written > 0 {
            return Ok(written as usize);
        }
        if written == 0 {
            return Err(io::Error::new(io::ErrorKind::WriteZero, "PTY write returned zero"));
        }
        let error = io::Error::last_os_error();
        if error.kind() != io::ErrorKind::Interrupted {
            return Err(error);
        }
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

#[cfg(test)]
#[path = "pty_write_tests.rs"]
mod tests;
