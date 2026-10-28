//! The IO reactor's thread and its poll (Unix; server/io_reactor.rs says
//! what it is for and what writes the connections it does not).
//!
//! - **Wakes.** A queue wakes the reactor through its writer hook
//!   (`BoundedOutbound::set_writer_ready`) when an item is queued or the
//!   queue closes. A connection's `scheduled` flag coalesces them: one
//!   message per turn the reactor owes it, not one per item.
//! - **Writes.** A turn takes ready items in write order
//!   (`BoundedOutbound::try_batch`) and sends them with one gathered
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
//!   failed, or whose turn panicked is dropped ([`LineOutput`]'s drop ends
//!   it). A panic in a turn or in an end is caught there and ends only that
//!   connection (the process's panic hook has logged it), as a panic in its
//!   own writer thread did.
//! - **A stop.** The reactor stops when the mux drops, or when its poll
//!   fails. Then later connections are written on threads of their own
//!   ([`Handle::adopt`] hands them back), so the daemon keeps serving.

use std::collections::{HashMap, VecDeque};
use std::io;
use std::os::fd::RawFd;
use std::panic::{AssertUnwindSafe, catch_unwind};
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, AtomicU64, AtomicUsize, Ordering};
use std::sync::mpsc::{self, Receiver, Sender, TryRecvError};
use std::thread::JoinHandle;
use std::time::{Duration, Instant};

use mio::{Events, Poll, Registry, Token, Waker};

use super::{LineOutput, write_on_own_thread};
use crate::server::bounded_outbound::{
    BatchTake, answer_flushes, count_batch_sent, write_gathered_from,
};
use crate::server::{OutboundItem, WatchKind};

/// The reactor thread's name.
pub(in crate::server) const REACTOR_THREAD: &str = "mux-io-reactor";

/// Bytes one connection writes in one turn before the reactor serves the
/// others: four full write batches.
const TURN_BYTES: usize = 1024 * 1024;

/// The waker's token; connections count from 1.
const WAKER: Token = Token(0);

/// Readiness events one poll takes.
const EVENTS_CAPACITY: usize = 256;

/// The running reactor: its inbox, its waker and its thread.
pub(super) struct Handle {
    inbox: Sender<Command>,
    wake: Arc<Wake>,
    next_token: AtomicUsize,
    _thread: JoinHandle<()>,
}

impl Handle {
    pub(super) fn start() -> io::Result<Self> {
        let poll = Poll::new()?;
        let wake = Arc::new(Wake {
            waker: Waker::new(poll.registry(), WAKER)?,
            pending: AtomicBool::new(false),
            stopped: AtomicBool::new(false),
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
            let ran =
                catch_unwind(AssertUnwindSafe(|| Reactor::new(poll).run(&commands, &thread_wake)));
            thread_wake.stopped.store(true, Ordering::SeqCst);
            match ran {
                Ok(Ok(())) => {}
                Ok(Err(error)) => eprintln!(
                    "cmux-tui: {REACTOR_THREAD} stopped, its poll failed: {error}; \
                     line connections get writer threads of their own from now on"
                ),
                Err(_) => eprintln!(
                    "cmux-tui: {REACTOR_THREAD} panicked and stopped; \
                     line connections get writer threads of their own from now on"
                ),
            }
            // Connections handed over before it saw `stopped` get theirs too.
            while let Ok(command) = commands.try_recv() {
                if let Command::Adopt(adopt) = command {
                    let _ = write_on_own_thread(adopt.output);
                }
            }
        })?;
        Ok(Self { inbox, wake, next_token: AtomicUsize::new(1), _thread: thread })
    }

    /// Hands `output` to the reactor, which writes its queue from now on;
    /// back when the reactor stopped.
    pub(super) fn adopt(&self, output: LineOutput, fd: RawFd) -> Result<(), LineOutput> {
        if self.stopped() {
            return Err(output);
        }
        let token = Token(self.next_token.fetch_add(1, Ordering::Relaxed));
        // Set until the reactor's first turn: wakes before it adopted the
        // connection send nothing, and the first turn sees their items.
        let scheduled = Arc::new(AtomicBool::new(true));
        let hook = {
            let inbox = self.inbox.clone();
            let wake = self.wake.clone();
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
            return Err(output);
        }
        let adopt = Box::new(Adopt { token, output, fd, scheduled });
        match self.inbox.send(Command::Adopt(adopt)) {
            Ok(()) => {
                self.wake.wake();
                Ok(())
            }
            // The reactor stopped meanwhile: the command comes back unsent.
            Err(mpsc::SendError(Command::Adopt(adopt))) => Err(adopt.output),
            Err(mpsc::SendError(Command::Ready(_) | Command::Stop)) => Ok(()),
        }
    }

    /// The reactor ends once no connection is left.
    pub(super) fn stop(&self) {
        if self.inbox.send(Command::Stop).is_ok() {
            self.wake.wake();
        }
    }

    /// Whether the reactor's thread stopped.
    pub(super) fn stopped(&self) -> bool {
        self.wake.stopped.load(Ordering::SeqCst)
    }

    #[cfg(test)]
    pub(super) fn wakeups(&self) -> u64 {
        self.wake.wakeups.load(Ordering::Relaxed)
    }

    #[cfg(test)]
    pub(super) fn connections(&self) -> usize {
        self.wake.connections.load(Ordering::Acquire)
    }
}

/// The reactor's waker, rung once per batch of commands, and its counts.
struct Wake {
    waker: Waker,
    /// Rung since the reactor last read its inbox.
    pending: AtomicBool,
    /// Its thread stopped: no connection is adopted any more.
    stopped: AtomicBool,
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

/// A connection handed to the reactor.
struct Adopt {
    token: Token,
    output: LineOutput,
    fd: RawFd,
    scheduled: Arc<AtomicBool>,
}

enum Command {
    Adopt(Box<Adopt>),
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

    /// Serves until asked to stop with no connection left; an error when
    /// the poll failed. Every connection it held has ended either way.
    fn run(mut self, commands: &Receiver<Command>, wake: &Wake) -> io::Result<()> {
        let mut events = Events::with_capacity(EVENTS_CAPACITY);
        let mut failed = None;
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
                    failed = Some(error);
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
        let tokens: Vec<Token> = self.connections.keys().copied().collect();
        for token in tokens {
            self.end(token);
        }
        wake.connections.store(0, Ordering::Release);
        failed.map_or(Ok(()), Err)
    }

    fn read_inbox(&mut self, commands: &Receiver<Command>) {
        loop {
            match commands.try_recv() {
                Ok(Command::Adopt(adopt)) => {
                    let token = adopt.token;
                    self.connections.insert(token, Connection::new(*adopt));
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
            Ok(TurnEnd::Done) => self.end(token),
            Err(_) => {
                eprintln!("cmux-tui: {REACTOR_THREAD}: a connection's write panicked; it ends");
                self.end(token);
            }
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

    /// Ends a connection. Its end runs the connection's close callbacks
    /// (the queue's room waiters, the writer's close): a panic in one ends
    /// only this connection, never the reactor.
    fn end(&mut self, token: Token) {
        let Some(connection) = self.connections.remove(&token) else { return };
        let registry = self.poll.registry();
        if catch_unwind(AssertUnwindSafe(|| connection.end(registry))).is_err() {
            eprintln!("cmux-tui: {REACTOR_THREAD}: a connection's end panicked");
        }
    }
}

/// One connection's write state in the reactor.
struct Connection {
    output: LineOutput,
    /// The connection's key in the reactor and in the poll.
    token: Token,
    /// The socket to send on and poll.
    fd: RawFd,
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
    fn new(adopt: Adopt) -> Self {
        let Adopt { token, output, fd, scheduled } = adopt;
        Self {
            output,
            token,
            fd,
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
            let mut socket = NonblockingSocket(self.fd);
            let result = write_gathered_from(
                &mut self.output.ipc.counted(&mut socket),
                &self.batch,
                &mut self.written,
            );
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
                        return TurnEnd::Done;
                    }
                    // The writability event schedules the next turn.
                    self.scheduled.store(true, Ordering::SeqCst);
                    return TurnEnd::Waiting;
                }
                Err(_) => return TurnEnd::Done,
            }
        }
    }

    /// When the waiting peer runs out of time.
    fn deadline(&self) -> Option<Instant> {
        let since = self.stalled_since?;
        Some(since + self.output.outbound.write_timeout()?)
    }

    /// Registers or deregisters the socket for writability: false when
    /// registering failed.
    fn set_registered(&mut self, registry: &Registry, registered: bool) -> bool {
        if self.registered == registered {
            return true;
        }
        let source = &mut mio::unix::SourceFd(&self.fd);
        let result = if registered {
            registry.register(source, self.token, mio::Interest::WRITABLE)
        } else {
            registry.deregister(source)
        };
        self.registered = registered && result.is_ok();
        result.is_ok()
    }

    /// Takes the socket out of the poll before its handle closes (epoll
    /// keeps a registration as long as any duplicate of the socket is
    /// open), then drops the output, which ends it.
    fn end(mut self, registry: &Registry) {
        self.set_registered(registry, false);
    }
}

/// A socket written with `sendmsg(MSG_DONTWAIT)`: a full send buffer is a
/// `WouldBlock` error, whatever mode the socket's other handles read in.
struct NonblockingSocket(RawFd);

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
