//! The daemon's IO reactor, its write side (plans/cmux-next/chrome-parity/
//! p05-ipc.md, task p05-ipc-156): one thread flushes the outbound queue of
//! every line connection, so an open connection holds no writer thread.
//!
//! This is Mojo's write path on Chrome's IO thread. `ChannelPosix::Write`
//! (mojo/core/channel_posix.cc) writes what the socket takes now; when the
//! socket would block it keeps the rest and waits for writability
//! (`WaitForWriteOnIOThread`), and `OnFileCanWriteWithoutBlocking` resumes
//! at the byte it stopped. One message pump (base/message_loop/
//! message_pump_epoll.cc, message_pump_kqueue.cc) serves every channel.
//!
//! - **Wakes.** A queue wakes the reactor through its writer hook
//!   ([`BoundedOutbound::set_writer_ready`]) when an item is queued or the
//!   queue closes. A connection's `scheduled` flag coalesces them: one
//!   message per turn the reactor owes it, not one per item.
//! - **Writes.** A turn takes ready items in write order
//!   ([`BoundedOutbound::try_batch`]) and sends them with one gathered
//!   `sendmsg` with `MSG_DONTWAIT`, which never waits even though the
//!   connection's reader reads the same socket blocking. Each turn writes at
//!   most [`TURN_BYTES`], then the other connections get theirs.
//! - **Writability.** A write the socket would block registers the socket
//!   for writability; the reactor resumes it on the event and deregisters it
//!   once its queue is empty. An idle connection is registered for nothing,
//!   so an idle daemon has 0 reactor wakeups.
//! - **Stalls.** A peer that takes no byte for the queue's write timeout
//!   (2 s, the old writer's `SO_SNDTIMEO`) ends its connection: the reactor
//!   polls with the earliest such deadline, and with none while no write
//!   waits.
//! - **The end.** A connection whose queue closed and drained, whose write
//!   failed, or whose turn panicked is shut down: its queue closes, its
//!   socket shuts down (the client reads the end and the connection's
//!   reader stops) and its end guard drops (its writer closes, its slot is
//!   free).
//!
//! A stream with no socket to poll (a test double) is written blocking in
//! its turn, under the socket's own write timeout.

use std::collections::{HashMap, VecDeque};
use std::io;
use std::net::Shutdown;
use std::panic::{AssertUnwindSafe, catch_unwind};
use std::sync::atomic::{AtomicBool, AtomicU64, AtomicUsize, Ordering};
use std::sync::mpsc::{self, Receiver, Sender, TryRecvError};
use std::sync::{Arc, OnceLock};
use std::thread::JoinHandle;
use std::time::{Duration, Instant};

use mio::{Events, Poll, Registry, Token, Waker};

use super::bounded_outbound::{BatchTake, answer_flushes, count_batch_sent, write_gathered_from};
use super::{BoundedOutbound, EchoWatch, OutboundItem, STREAM_WRITE_TIMEOUT, WatchKind};
use crate::diagnostics::IpcStats;
use crate::platform::transport;

/// The reactor thread's name.
pub(super) const REACTOR_THREAD: &str = "mux-io-reactor";

/// Bytes one connection writes in one turn before the reactor serves the
/// others: four full write batches.
pub(super) const TURN_BYTES: usize = 1024 * 1024;

/// The waker's token; connections count from 1.
const WAKER: Token = Token(0);

/// Readiness events one poll takes.
const EVENTS_CAPACITY: usize = 256;

/// The write side of one line connection, handed to the reactor.
pub(super) struct LineOutput {
    pub(super) outbound: Arc<BoundedOutbound>,
    /// A handle on the connection's socket the reactor writes and, at the
    /// end, shuts down.
    pub(super) socket: Box<dyn transport::Stream>,
    pub(super) ipc: Arc<IpcStats>,
    /// Each turn is one 100 ms hang scope of the mux's watchdog.
    pub(super) hangs: EchoWatch,
    /// Dropped once the connection's output ended, after its socket shut
    /// down: it closes the connection's writer and frees its slot.
    pub(super) _end: Box<dyn Send>,
}

/// The reactor of one mux: started by its first connection, stopped when
/// the mux drops and its last connection ended.
#[derive(Default)]
pub(crate) struct IoReactor {
    started: OnceLock<Handle>,
}

impl std::fmt::Debug for IoReactor {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("IoReactor").field("started", &self.started.get().is_some()).finish()
    }
}

impl IoReactor {
    /// Hands `output` to the reactor, which writes its queue from now on.
    /// An error (the reactor could not start, or it stopped) leaves the
    /// connection to its caller, which drops it.
    pub(super) fn adopt(&self, output: LineOutput) -> io::Result<()> {
        let handle = self.handle()?;
        let token = Token(handle.next_token.fetch_add(1, Ordering::Relaxed));
        // Set until the reactor's first turn: wakes before it adopted the
        // connection send nothing, and the first turn sees their items.
        let scheduled = Arc::new(AtomicBool::new(true));
        let hook = {
            let inbox = handle.inbox.clone();
            let wake = handle.wake.clone();
            let scheduled = scheduled.clone();
            move || {
                if !scheduled.swap(true, Ordering::AcqRel)
                    && inbox.send(Command::Ready(token)).is_ok()
                {
                    wake.wake();
                }
            }
        };
        if !output.outbound.set_writer_ready(hook) {
            return Err(io::Error::new(io::ErrorKind::AlreadyExists, "the queue has a writer"));
        }
        let connection = Connection::new(output, token, scheduled);
        handle
            .inbox
            .send(Command::Adopt(token, Box::new(connection)))
            .map_err(|_| io::Error::new(io::ErrorKind::BrokenPipe, "the IO reactor stopped"))?;
        handle.wake.wake();
        Ok(())
    }

    /// Times the reactor's poll returned since it started: an idle daemon
    /// adds none.
    #[cfg(test)]
    pub(super) fn wakeups(&self) -> u64 {
        self.started.get().map_or(0, |handle| handle.wake.wakeups.load(Ordering::Relaxed))
    }

    /// Connections whose output the reactor writes now.
    #[cfg(test)]
    pub(super) fn connections(&self) -> usize {
        self.started.get().map_or(0, |handle| handle.wake.connections.load(Ordering::Acquire))
    }

    fn handle(&self) -> io::Result<&Handle> {
        if let Some(handle) = self.started.get() {
            return Ok(handle);
        }
        // Two first connections may both start one; the second stops its own.
        if let Err(lost) = self.started.set(Handle::start()?) {
            lost.stop();
        }
        self.started
            .get()
            .ok_or_else(|| io::Error::new(io::ErrorKind::BrokenPipe, "the IO reactor stopped"))
    }
}

impl Drop for IoReactor {
    fn drop(&mut self) {
        if let Some(handle) = self.started.get() {
            handle.stop();
        }
    }
}

/// The running reactor: its inbox, its waker and its thread.
struct Handle {
    inbox: Sender<Command>,
    wake: Arc<Wake>,
    next_token: AtomicUsize,
    _thread: JoinHandle<()>,
}

impl Handle {
    fn start() -> io::Result<Self> {
        let poll = Poll::new()?;
        let wake = Arc::new(Wake {
            waker: Waker::new(poll.registry(), WAKER)?,
            pending: AtomicBool::new(false),
            wakeups: AtomicU64::new(0),
            connections: AtomicUsize::new(0),
        });
        let (inbox, commands) = mpsc::channel();
        let thread_wake = wake.clone();
        // The echo path's class: it writes the app's key echo. It never
        // blocks; its only wait is the poll, an idle wait.
        let thread = crate::echo_thread::spawn(REACTOR_THREAD, move || {
            let _hang_watch =
                cmux_hang_watch::register_thread(cmux_hang_watch::ThreadKind::Io, REACTOR_THREAD);
            Reactor::new(poll).run(&commands, &thread_wake);
        })?;
        Ok(Self { inbox, wake, next_token: AtomicUsize::new(1), _thread: thread })
    }

    /// The reactor ends once no connection is left.
    fn stop(&self) {
        if self.inbox.send(Command::Stop).is_ok() {
            self.wake.wake();
        }
    }
}

/// The reactor's waker, rung once per batch of commands, and its counts.
struct Wake {
    waker: Waker,
    /// Rung since the reactor last read its inbox.
    pending: AtomicBool,
    /// Polls that returned: the reactor's wakeups.
    wakeups: AtomicU64,
    /// Connections it writes now.
    connections: AtomicUsize,
}

impl Wake {
    fn wake(&self) {
        if !self.pending.swap(true, Ordering::AcqRel) {
            // A failed wake leaves the inbox for the next event; the eventfd
            // or kqueue write fails only when the reactor is gone.
            let _ = self.waker.wake();
        }
    }
}

enum Command {
    Adopt(Token, Box<Connection>),
    /// The connection's queue changed.
    Ready(Token),
    Stop,
}

/// How a connection's turn ended.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum TurnEnd {
    /// Its queue is empty.
    Idle,
    /// Its socket would block: it waits for writability.
    Waiting,
    /// Its turn's bytes are spent; it has more.
    More,
    /// Its queue closed and drained, or a write failed.
    Done,
}

struct Reactor {
    poll: Poll,
    connections: HashMap<Token, Connection>,
    /// Connections owed a turn, in order.
    run: VecDeque<Token>,
    stopping: bool,
}

impl Reactor {
    fn new(poll: Poll) -> Self {
        Self { poll, connections: HashMap::new(), run: VecDeque::new(), stopping: false }
    }

    fn run(mut self, commands: &Receiver<Command>, wake: &Wake) {
        let mut events = Events::with_capacity(EVENTS_CAPACITY);
        loop {
            let timeout = if self.run.is_empty() {
                self.next_deadline().map(|at| at.saturating_duration_since(Instant::now()))
            } else {
                Some(Duration::ZERO)
            };
            let polled = self.poll.poll(&mut events, timeout);
            wake.wakeups.fetch_add(1, Ordering::Relaxed);
            match polled {
                Ok(()) => {}
                Err(error) if error.kind() == io::ErrorKind::Interrupted => continue,
                Err(error) => {
                    eprintln!("cmux-tui: {REACTOR_THREAD} stopped: poll failed: {error}");
                    break;
                }
            }
            for event in &events {
                let token = event.token();
                if token != WAKER && self.connections.contains_key(&token) {
                    self.run.push_back(token);
                }
            }
            wake.pending.store(false, Ordering::SeqCst);
            self.read_inbox(commands);
            for _ in 0..self.run.len() {
                let Some(token) = self.run.pop_front() else { break };
                self.turn(token);
            }
            self.end_stalled(Instant::now());
            wake.connections.store(self.connections.len(), Ordering::Release);
            if self.stopping && self.connections.is_empty() {
                break;
            }
        }
        for (_, connection) in self.connections.drain() {
            connection.deregister(self.poll.registry());
        }
        wake.connections.store(0, Ordering::Release);
    }

    fn read_inbox(&mut self, commands: &Receiver<Command>) {
        loop {
            match commands.try_recv() {
                Ok(Command::Adopt(token, connection)) => {
                    self.connections.insert(token, *connection);
                    self.run.push_back(token);
                }
                Ok(Command::Ready(token)) => {
                    // A connection that waits for writability goes on its event.
                    if self.connections.get(&token).is_some_and(|c| !c.registered) {
                        self.run.push_back(token);
                    }
                }
                Ok(Command::Stop) | Err(TryRecvError::Disconnected) => {
                    self.stopping = true;
                    return;
                }
                Err(TryRecvError::Empty) => return,
            }
        }
    }

    fn turn(&mut self, token: Token) {
        let registry = self.poll.registry();
        let Some(connection) = self.connections.get_mut(&token) else { return };
        let end = catch_unwind(AssertUnwindSafe(|| connection.turn(registry)));
        match end {
            Ok(TurnEnd::Idle | TurnEnd::Waiting) => {}
            Ok(TurnEnd::More) => self.run.push_back(token),
            Ok(TurnEnd::Done) | Err(_) => self.end(token),
        }
    }

    /// The earliest moment a waiting connection's peer runs out of time.
    fn next_deadline(&self) -> Option<Instant> {
        self.connections.values().filter_map(Connection::deadline).min()
    }

    fn end_stalled(&mut self, now: Instant) {
        let stalled: Vec<Token> = self
            .connections
            .iter()
            .filter(|(_, connection)| connection.deadline().is_some_and(|at| at <= now))
            .map(|(token, _)| *token)
            .collect();
        for token in stalled {
            self.end(token);
        }
    }

    fn end(&mut self, token: Token) {
        if let Some(connection) = self.connections.remove(&token) {
            connection.deregister(self.poll.registry());
        }
    }
}

/// One connection's write state in the reactor.
struct Connection {
    output: LineOutput,
    /// The connection's key in the reactor and in the poll.
    token: Token,
    /// The socket to send on and poll, when the stream has one.
    #[cfg(unix)]
    fd: Option<std::os::fd::RawFd>,
    scheduled: Arc<AtomicBool>,
    /// The batch being written, and how many of its bytes went.
    batch: Vec<OutboundItem>,
    written: usize,
    /// Registered for writability.
    registered: bool,
    /// Since when a write waits with no byte taken.
    stalled_since: Option<Instant>,
}

impl Connection {
    fn new(output: LineOutput, token: Token, scheduled: Arc<AtomicBool>) -> Self {
        Self {
            token,
            #[cfg(unix)]
            fd: output.socket.socket_fd(),
            output,
            scheduled,
            batch: Vec::new(),
            written: 0,
            registered: false,
            stalled_since: None,
        }
    }

    /// Writes ready items until the queue is empty, the socket would
    /// block, or the turn's bytes are spent.
    fn turn(&mut self, registry: &Registry) -> TurnEnd {
        let hangs = self.output.hangs.clone();
        let _item = hangs.item(WatchKind::LineOut);
        // Cleared before the queue is read: an item queued from here on
        // schedules another turn.
        self.scheduled.store(false, Ordering::SeqCst);
        let mut spent = 0;
        loop {
            if self.batch.is_empty() {
                match self.output.outbound.try_batch(&mut self.batch) {
                    BatchTake::Taken => {
                        count_batch_sent(&self.output.ipc, &self.batch);
                        self.written = 0;
                    }
                    BatchTake::Empty => {
                        self.stalled_since = None;
                        self.set_registered(registry, false);
                        return TurnEnd::Idle;
                    }
                    BatchTake::Ended => return TurnEnd::Done,
                }
            }
            let before = self.written;
            let result = self.write();
            spent += self.written - before;
            match result {
                Ok(()) => {
                    answer_flushes(&mut self.batch);
                    self.written = 0;
                    self.stalled_since = None;
                    if spent >= TURN_BYTES {
                        self.scheduled.store(true, Ordering::SeqCst);
                        return TurnEnd::More;
                    }
                }
                Err(error) if error.kind() == io::ErrorKind::WouldBlock => {
                    self.output.ipc.write_would_block();
                    if self.written > before || self.stalled_since.is_none() {
                        self.stalled_since = Some(Instant::now());
                    }
                    if !self.set_registered(registry, true) {
                        self.output.outbound.close();
                        return TurnEnd::Done;
                    }
                    // The writability event schedules the next turn.
                    self.scheduled.store(true, Ordering::SeqCst);
                    return TurnEnd::Waiting;
                }
                Err(_) => {
                    self.output.outbound.close();
                    return TurnEnd::Done;
                }
            }
        }
    }

    /// Writes the rest of the batch: never waits on a socket it can poll.
    fn write(&mut self) -> io::Result<()> {
        let LineOutput { outbound, socket, ipc, .. } = &mut self.output;
        #[cfg(unix)]
        if let Some(fd) = self.fd {
            let mut socket = NonblockingSocket(fd);
            return write_gathered_from(
                &mut ipc.counted(&mut socket),
                &self.batch,
                &mut self.written,
            );
        }
        let deadline = outbound.write_timeout().unwrap_or(STREAM_WRITE_TIMEOUT);
        let _write = cmux_hang_watch::watch(deadline);
        write_gathered_from(&mut ipc.counted(&mut **socket), &self.batch, &mut self.written)?;
        io::Write::flush(socket)
    }

    /// When the waiting peer runs out of time.
    fn deadline(&self) -> Option<Instant> {
        let since = self.stalled_since?;
        Some(since + self.output.outbound.write_timeout()?)
    }

    /// Registers or deregisters the socket for writability: false when
    /// registering failed.
    #[cfg(unix)]
    fn set_registered(&mut self, registry: &Registry, registered: bool) -> bool {
        let Some(fd) = self.fd else { return !registered };
        if self.registered == registered {
            return true;
        }
        let source = &mut mio::unix::SourceFd(&fd);
        let result = if registered {
            registry.register(source, self.token, mio::Interest::WRITABLE)
        } else {
            registry.deregister(source)
        };
        self.registered = registered && result.is_ok();
        result.is_ok()
    }

    #[cfg(not(unix))]
    fn set_registered(&mut self, _registry: &Registry, registered: bool) -> bool {
        !registered
    }

    /// Takes the socket out of the poll before its handle closes: epoll
    /// keeps a registration as long as any duplicate of the socket is open.
    fn deregister(mut self, registry: &Registry) {
        self.set_registered(registry, false);
    }
}

impl Drop for Connection {
    fn drop(&mut self) {
        self.output.outbound.close();
        let _ = self.output.socket.shutdown(Shutdown::Both);
        // `output._end` drops after this: the writer closes, the slot frees.
    }
}

/// A socket written with `sendmsg(MSG_DONTWAIT)`: a full send buffer is a
/// `WouldBlock` error, whatever mode the socket's other handles read in.
#[cfg(unix)]
struct NonblockingSocket(std::os::fd::RawFd);

#[cfg(unix)]
impl io::Write for NonblockingSocket {
    fn write(&mut self, buf: &[u8]) -> io::Result<usize> {
        self.write_vectored(&[io::IoSlice::new(buf)])
    }

    fn write_vectored(&mut self, bufs: &[io::IoSlice<'_>]) -> io::Result<usize> {
        cmux_ipc::fds::send_vectored_nonblocking(self.0, bufs)
    }

    fn flush(&mut self) -> io::Result<()> {
        Ok(())
    }
}

#[cfg(all(test, unix))]
#[path = "io_reactor_tests.rs"]
mod tests;
