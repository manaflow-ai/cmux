//! One `mux-io` thread for every local daemon connection.
//!
//! A connection held a reader thread (`mux-conn`) blocked in `recvmsg` and a
//! writer thread (`mux-line-out`) blocked on its queue: 200 idle CLI
//! connections were 400 threads. Chrome serves every IPC channel of a
//! process from its one IO thread: `ChannelPosix` watches each socket with
//! the IO thread's `MessagePumpKqueue` / `MessagePumpEpoll`, reads when it is
//! readable (`OnFileCanReadWithoutBlocking`), hands each whole message to the
//! receiver's sequence, and writes queued messages when the socket has room
//! (`OnFileCanWriteWithoutBlocking`, mojo/core/channel_posix.cc). This loop
//! does the same over every connection's socket, set non-blocking:
//!
//! - **Reads.** A readable socket gets one `recvmsg` straight into its
//!   [`FrameReader`] (descriptors refused as before); every whole JSON line
//!   or frame is cut here and delivered in order to the connection's
//!   [`InboundSink`], its line sequence on the daemon's sequenced pool
//!   (server/line_connection.rs). No request runs on this thread. A sink
//!   that holds enough pauses the socket's reads until it drains
//!   ([`IoHandle::resume_read`]), so a flooding client is bounded by its
//!   kernel buffer, as when its reader thread was busy.
//! - **Writes.** A connection's [`BoundedOutbound`] rings the loop's
//!   doorbell when it queues an item. The loop takes ready items in write
//!   order and writes them with one `writev` per batch, as the writer thread
//!   did; a full socket leaves the rest for its next writable readiness.
//!   While the loop holds nothing to write, a producer on an idle
//!   connection writes its item inline instead, with a send that never
//!   waits (server/inline_write.rs), as Mojo's
//!   `ChannelPosix::Write` does; the loop gets only the tail the socket did
//!   not take, ahead of every queued item.
//! - **Write timeout.** A write that makes no progress for the queue's write
//!   timeout (2 s, the socket's `SO_SNDTIMEO` before) closes the connection
//!   as the writer thread's timed-out write did; the loop's wait has a
//!   deadline only while such a write is pending.
//! - **Close.** When the queue is closed and written, or a write fails, the
//!   socket is shut down both ways, as the writer thread did on its way out:
//!   the read side then ends. A connection leaves the loop once both sides
//!   are done, and its sink hears [`InboundSink::released`].
//!
//! - **The person first.** The person's connections ([`InboundSink::is_person`])
//!   have a loop of their own, `mux-io-input`, at the echo class: a
//!   connection moves there from `mux-io` once it is classed the person's
//!   (its socket, its reader and its write state go with it, and commands
//!   sent to the old loop are passed on). So an agent's burst of reads and
//!   writes never stands between a key and its echo: under 8 bursting
//!   agents the shared loop put the echo's p95 at 1.3-2x the per-connection
//!   threads it replaced (connection_qos_tests.rs
//!   `echo_latency_under_an_agent_burst`). Chrome keeps the person's input
//!   off the thread that serves background traffic the same way: input
//!   events reach the renderer's compositor thread, not the main thread's
//!   task queue (content/renderer/input/). There its lines are routed on
//!   the loop itself ([`InboundSink::deliver_here`]), as its reader thread
//!   routed them, with no hop to the pool first: under the burst every
//!   hop through the pool waits on the pool's one lock. Within one turn a
//!   loop still serves the person's sockets and commands first.
//!
//! `mux-io` starts with its first connection and runs at user-initiated,
//! as each connection's reader did before it is classed; `mux-io-input`
//! starts with the first connection classed the person's and runs at the
//! echo class. Both disallow blocking. A thread that cannot start leaves
//! nothing behind: the next connection tries again, and a person's
//! connection whose loop cannot start stays on `mux-io`, served first. Each
//! turn after a wait is one hang scope; the wait is in none. Nothing wakes
//! an idle loop.

use std::collections::HashMap;
use std::io;
use std::net::Shutdown;
use std::os::fd::RawFd;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, OnceLock};
use std::time::{Duration, Instant};

use cmux_ipc::FrameReader;
use cmux_threads::ThreadQos;
use cmux_threads::sync::Mutex;

use crate::thread_qos::ThreadType;

use super::line_connection::{ConnectionBadMessage, ConnectionEnd, Inbound, cut_message};
use super::{BatchPoll, BoundedOutbound, MessageWriter, OutboundItem};
use super::{count_sent, write_batch_nonblocking};
use crate::diagnostics::IpcStats;
use crate::panic_free::RecoverPoison;
use crate::platform::transport;

#[path = "mux_io_poller.rs"]
mod poller;
use poller::{Interest, Poller, Ready, WAKE_TOKEN};

#[cfg(test)]
#[path = "mux_io_tests.rs"]
mod tests;

/// The shared loop's thread name (`server-threads`, threading-model.md).
pub(super) const MUX_IO_THREAD: &str = "mux-io";

/// The shared loop's QoS: user-initiated, as a connection's reader ran
/// before its class was known (`CONNECTION_READER_QOS`). It serves
/// automation and connections not classed yet; it runs no request.
pub(super) const MUX_IO_QOS: ThreadQos = ThreadType::Interactive.qos();

/// The person's loop's thread name.
pub(super) const MUX_IO_INPUT_THREAD: &str = "mux-io-input";

/// The person's loop's QoS: the echo class, as the person's connection
/// reader and writer threads ran (Chromium's browser IO thread is
/// kDisplayCritical, content/browser/browser_thread_impl.cc).
pub(super) const MUX_IO_INPUT_QOS: ThreadQos = crate::echo_thread::ECHO_PATH_QOS;

/// Which of the two loops.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) enum LoopKind {
    /// `mux-io`: automation and connections not classed yet.
    Shared,
    /// `mux-io-input`: the person's connections.
    Person,
}

impl LoopKind {
    pub(super) const fn thread_name(self) -> &'static str {
        match self {
            LoopKind::Shared => MUX_IO_THREAD,
            LoopKind::Person => MUX_IO_INPUT_THREAD,
        }
    }

    pub(super) const fn qos(self) -> ThreadQos {
        match self {
            LoopKind::Shared => MUX_IO_QOS,
            LoopKind::Person => MUX_IO_INPUT_QOS,
        }
    }
}

/// One turn of the loop (what it does after a wait) is one hang scope.
const TURN_HANG_DEADLINE: Duration = Duration::from_millis(100);

/// Batches one connection writes per writable readiness before the loop
/// turns to the others: 1 MiB at the batch bound. Level-triggered
/// readiness brings it back at once.
const BATCHES_PER_TURN: usize = 4;

/// Where a connection's messages go: its line sequence.
pub(super) trait InboundSink: Send + Sync {
    /// Queues `message`. False when the sink holds enough: the loop stops
    /// reading the socket until [`IoHandle::resume_read`].
    fn deliver(&self, message: Inbound) -> bool;
    /// The socket is closed and out of the loop: both sides are done.
    fn released(&self);
    /// The person's connection: it moves to the person's loop.
    fn is_person(&self) -> bool;
    /// [`Self::deliver`] on the person's loop: the sink may handle the
    /// message on this thread, as the person's connection reader did
    /// (routing only: a request runs on its connection's request sequence).
    fn deliver_here(&self, message: Inbound) -> bool {
        self.deliver(message)
    }
}

/// One connection to serve.
pub(super) struct IoRegistration {
    /// The connected socket; the loop reads and writes it.
    pub(super) stream: Box<dyn transport::Stream>,
    /// Its reader: limits set, any prefix pushed, frames negotiated when
    /// the connection may carry them.
    pub(super) reader: FrameReader,
    pub(super) outbound: Arc<BoundedOutbound>,
    /// Closed with the socket when a write fails or the queue is done.
    pub(super) writer: MessageWriter,
    pub(super) ipc: Arc<IpcStats>,
    pub(super) inbound: Arc<dyn InboundSink>,
}

/// Where one connection's commands go: the loop it was registered on, or
/// the person's loop once it moved there. Weak, so a queued doorbell never
/// keeps a loop alive.
struct Route {
    token: u64,
    home: std::sync::Weak<Shared>,
    /// Set once the connection serves on the person's loop.
    moved: OnceLock<std::sync::Weak<Shared>>,
}

impl Route {
    /// Queues `op` on the loop that serves the connection now.
    fn send(self: &Arc<Self>, op: Op) {
        let target = self.moved.get().unwrap_or(&self.home);
        if let Some(shared) = target.upgrade() {
            let _ = shared.command(Command::Op(self.clone(), op));
        }
    }
}

/// A connection's way back to the loop.
#[derive(Clone)]
pub(super) struct IoHandle {
    route: Arc<Route>,
}

impl IoHandle {
    /// The sink drained: read the socket again.
    pub(super) fn resume_read(&self) {
        self.route.send(Op::ResumeRead);
    }

    /// The connection needs no more input (a handler closed it): stop
    /// reading for good.
    pub(super) fn stop_read(&self) {
        self.route.send(Op::StopRead);
    }
}

/// Starts a loop's thread with `body`, or says why it could not.
type LoopSpawner = Arc<dyn Fn(LoopKind, LoopBody) -> io::Result<()> + Send + Sync>;
type LoopBody = Box<dyn FnOnce() + Send>;

/// What both loops share: the connection tokens, and the person's loop,
/// started by the shared loop when it first moves a connection there.
struct Loops {
    next_token: AtomicU64,
    person: OnceLock<Arc<Shared>>,
    spawner: LoopSpawner,
}

impl Loops {
    /// Starts a loop of `kind`. Its `Shared` is returned only once its
    /// thread runs, so a spawn that failed (EAGAIN) leaves nothing behind.
    fn start(self: &Arc<Self>, kind: LoopKind) -> io::Result<Arc<Shared>> {
        let shared =
            Arc::new(Shared { poller: Poller::new()?, commands: Mutex::new(Commands::default()) });
        let looped = shared.clone();
        let loops = self.clone();
        (self.spawner)(
            kind,
            Box::new(move || {
                let thread = std::thread::current();
                let _hang_watch = cmux_hang_watch::register_thread(
                    cmux_hang_watch::ThreadKind::Io,
                    thread.name().unwrap_or(kind.thread_name()),
                );
                cmux_threads::disallow_blocking();
                Loop::new(looped, loops, kind).run();
            }),
        )?;
        Ok(shared)
    }

    /// The person's loop, started on first use; `None` when its thread
    /// could not start. Only the shared loop's thread calls it.
    fn person(self: &Arc<Self>) -> Option<Arc<Shared>> {
        if let Some(person) = self.person.get() {
            return Some(person.clone());
        }
        let person = match self.start(LoopKind::Person) {
            Ok(person) => person,
            Err(error) => {
                eprintln!("cmux-tui: {MUX_IO_INPUT_THREAD} did not start: {error}");
                return None;
            }
        };
        if self.person.set(person.clone()).is_err() {
            person.command(Command::Stop);
        }
        self.person.get().cloned()
    }
}

/// The daemon's connection loops: one per mux, the shared loop's thread
/// started with the first connection.
pub(crate) struct MuxIo {
    /// Set only once the shared loop's thread started.
    shared: OnceLock<Arc<Shared>>,
    loops: Arc<Loops>,
}

impl Default for MuxIo {
    fn default() -> Self {
        Self::with_spawner(Arc::new(|kind: LoopKind, body: LoopBody| {
            // Supervised: a failure of the loop itself
            // ends the process; each connection's own errors close only it.
            crate::supervised::spawn_at(
                kind.thread_name(),
                kind.qos(),
                crate::supervised::Fatal,
                crate::supervised::ShutdownBehavior::Continue,
                body,
            )
            .map(drop)
        }))
    }
}

impl std::fmt::Debug for MuxIo {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("MuxIo")
            .field("started", &self.shared.get().is_some())
            .field("person", &self.loops.person.get().is_some())
            .finish()
    }
}

impl Drop for MuxIo {
    fn drop(&mut self) {
        // Each loop ends at its next turn and closes what it still serves.
        // Not joined: the last owner of the mux may be a task a loop's own
        // close released. A connection the shared loop moves while it stops
        // finds the person's loop stopped and closes on the shared loop.
        if let Some(shared) = self.shared.get() {
            let _ = shared.command(Command::Stop);
        }
        if let Some(person) = self.loops.person.get() {
            let _ = person.command(Command::Stop);
        }
    }
}

impl MuxIo {
    fn with_spawner(spawner: LoopSpawner) -> Self {
        let loops =
            Arc::new(Loops { next_token: AtomicU64::new(1), person: OnceLock::new(), spawner });
        Self { shared: OnceLock::new(), loops }
    }

    /// A handle for a connection about to be registered: its sink may need
    /// it before [`Self::register`] returns.
    pub(super) fn handle(&self) -> io::Result<IoHandle> {
        let shared = self.started()?;
        let token = self.loops.next_token.fetch_add(1, Ordering::Relaxed);
        let route = Arc::new(Route { token, home: Arc::downgrade(shared), moved: OnceLock::new() });
        Ok(IoHandle { route })
    }

    /// Serves `registration` on the loop under `handle`. Fails, serving
    /// nothing, when the socket cannot be made non-blocking.
    pub(super) fn register(
        &self,
        handle: &IoHandle,
        registration: IoRegistration,
    ) -> Result<(), RegisterError> {
        let Some(fd) = registration.stream.socket_fd() else {
            return Err(RegisterError::NoSocket);
        };
        if let Err(error) = set_nonblocking(fd) {
            return Err(RegisterError::Socket(error));
        }
        let IoRegistration { stream, reader, outbound, writer, ipc, inbound } = registration;
        let write_signal = Arc::new(AtomicBool::new(false));
        let doorbell = {
            let route = handle.route.clone();
            let signal = write_signal.clone();
            move || {
                if signal.swap(true, Ordering::AcqRel) {
                    return;
                }
                route.send(Op::Writable);
            }
        };
        if !outbound.on_ready(doorbell) {
            // A queue serves one writer.
            return Err(RegisterError::Taken);
        }
        let connection = Connection {
            token: handle.route.token,
            route: handle.route.clone(),
            stays: false,
            here: false,
            fd,
            stream,
            reader,
            fds: cmux_ipc::fds::FdReceiver::default(),
            reading: true,
            ended_at_eof: false,
            paused: false,
            interest: Interest::NONE,
            outbound,
            writer,
            write_signal,
            batch: Vec::new(),
            rest: None,
            written: 0,
            blocked_since: None,
            stalled: false,
            write_done: false,
            ipc,
            inbound,
        };
        let Some(home) = handle.route.home.upgrade() else {
            return Err(RegisterError::Stopped);
        };
        if home.command(Command::Add(Box::new(connection))) {
            Ok(())
        } else {
            Err(RegisterError::Stopped)
        }
    }

    /// The running shared loop, its thread started first. The loop is
    /// published only once its thread runs, so a spawn that failed (EAGAIN)
    /// leaves nothing behind and the next connection tries again.
    fn started(&self) -> io::Result<&Arc<Shared>> {
        if let Some(shared) = self.shared.get() {
            return Ok(shared);
        }
        let shared = self.loops.start(LoopKind::Shared)?;
        if self.shared.set(shared.clone()).is_err() {
            // Another connection's loop started first: this one ends unused.
            shared.command(Command::Stop);
        }
        self.shared.get().ok_or_else(|| io::Error::other("mux-io lost its loop"))
    }
}

/// Why a connection was not registered (its registration closed).
pub(super) enum RegisterError {
    /// The stream is not one socket the loop can watch.
    NoSocket,
    /// `O_NONBLOCK` could not be set.
    Socket(io::Error),
    /// Another writer already serves the connection's queue.
    Taken,
    /// The loop is gone (its thread could not start, or the mux dropped).
    Stopped,
}

impl std::fmt::Display for RegisterError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            RegisterError::NoSocket => write!(f, "the stream is not one socket"),
            RegisterError::Socket(error) => write!(f, "the socket stays blocking: {error}"),
            RegisterError::Taken => write!(f, "its queue has a writer already"),
            RegisterError::Stopped => write!(f, "the mux-io loop is stopped"),
        }
    }
}

fn set_nonblocking(fd: RawFd) -> io::Result<()> {
    // SAFETY: fcntl on a descriptor the registration's stream owns.
    let flags = unsafe { libc::fcntl(fd, libc::F_GETFL) };
    if flags < 0 {
        return Err(io::Error::last_os_error());
    }
    // SAFETY: as above, setting a flag on the same descriptor.
    if unsafe { libc::fcntl(fd, libc::F_SETFL, flags | libc::O_NONBLOCK) } < 0 {
        return Err(io::Error::last_os_error());
    }
    Ok(())
}

/// What other threads ask of a loop.
enum Command {
    Add(Box<Connection>),
    /// One connection's request.
    Op(Arc<Route>, Op),
    /// The mux is gone.
    Stop,
}

/// What a connection asks of the loop that serves it.
#[derive(Clone, Copy)]
enum Op {
    /// The connection's queue rang its doorbell.
    Writable,
    ResumeRead,
    StopRead,
}

#[derive(Default)]
struct Commands {
    queue: Vec<Command>,
    /// A wake is posted and the loop has not taken the queue since.
    woken: bool,
    stopped: bool,
}

struct Shared {
    poller: Poller,
    /// Taken by the loop once per turn; a sender holds it for one push.
    commands: Mutex<Commands>,
}

impl Shared {
    /// Queues `command` for the loop; false once the loop stopped (the
    /// command is dropped).
    fn command(&self, command: Command) -> bool {
        self.try_command(command).is_ok()
    }

    /// [`Self::command`] that hands a refused command back.
    fn try_command(&self, command: Command) -> Result<(), Command> {
        let mut commands = self.commands.lock().recover_poison();
        if commands.stopped {
            return Err(command);
        }
        commands.queue.push(command);
        let wake = !std::mem::replace(&mut commands.woken, true);
        drop(commands);
        if wake && let Err(error) = self.poller.wake() {
            eprintln!("cmux-tui: mux-io wake failed: {error}");
        }
        Ok(())
    }
}

/// A connection the loop serves; only the loop's thread touches it.
struct Connection {
    token: u64,
    /// Where its commands go; moved with it.
    route: Arc<Route>,
    /// The person's loop could not take it: it stays on the shared loop.
    stays: bool,
    /// It serves on the person's loop: its messages are handled here.
    here: bool,
    fd: RawFd,
    stream: Box<dyn transport::Stream>,
    reader: FrameReader,
    fds: cmux_ipc::fds::FdReceiver,
    /// The read side has not ended.
    reading: bool,
    /// A read returned end of stream: once the reader holds no whole
    /// message, the peer closed.
    ended_at_eof: bool,
    /// The sink holds enough: no read until it resumes.
    paused: bool,
    /// What the poller watches the socket for now.
    interest: Interest,
    outbound: Arc<BoundedOutbound>,
    writer: MessageWriter,
    /// Set by the doorbell, cleared before the queue is read.
    write_signal: Arc<AtomicBool>,
    /// The turn being written: the tail an inline write left
    /// (server/inline_write.rs), then the batch, and how many of their bytes
    /// went.
    batch: Vec<OutboundItem>,
    rest: Option<Vec<u8>>,
    written: usize,
    /// Since when a write has been waiting for room with no progress.
    blocked_since: Option<Instant>,
    /// The last write found the peer's buffer full and no batch has been
    /// written whole since: one write stall (`server-stats` `ipc`).
    stalled: bool,
    /// The queue is closed and written, or a write failed: the socket is
    /// shut down.
    write_done: bool,
    ipc: Arc<IpcStats>,
    inbound: Arc<dyn InboundSink>,
}

impl Connection {
    fn wants(&self) -> Interest {
        Interest {
            read: self.reading && !self.paused,
            write: !self.write_done && self.blocked_since.is_some(),
        }
    }

    fn is_done(&self) -> bool {
        !self.reading && self.write_done
    }

    /// Cuts every whole message the reader holds and delivers it; stops
    /// when the sink is full or the read side ended.
    fn cut(&mut self) {
        while self.reading && !self.paused {
            let Some(inbound) = cut_message(&mut self.reader, self.ended_at_eof, &self.ipc) else {
                return;
            };
            self.deliver(inbound);
        }
    }

    fn deliver(&mut self, inbound: Inbound) {
        if matches!(inbound, Inbound::End(_)) {
            self.end_read();
        }
        let room = if self.here {
            self.inbound.deliver_here(inbound)
        } else {
            self.inbound.deliver(inbound)
        };
        if !room {
            self.paused = true;
        }
    }

    /// The read side ended: the reader zeroes the line it still lends.
    fn end_read(&mut self) {
        self.reading = false;
        self.reader.push(&[]);
    }

    /// One read, then every message it completed.
    fn read(&mut self) {
        if !self.reading || self.paused {
            return;
        }
        let read = loop {
            match self.recv() {
                Err(error) if error.kind() == io::ErrorKind::Interrupted => {}
                result => break result,
            }
        };
        match read {
            Err(error) if error.kind() == io::ErrorKind::WouldBlock => return,
            Ok(_) if self.fds.queued() > 0 => {
                return self.deliver(unexpected_fds());
            }
            Ok(0) => self.ended_at_eof = true,
            Ok(_) => {}
            Err(error) if is_descriptor_refusal(&error) => {
                return self.deliver(unexpected_fds());
            }
            Err(_) => return self.deliver(Inbound::End(ConnectionEnd::Dropped)),
        }
        self.cut();
    }

    /// One `recvmsg` straight into the reader's buffer, bytes and
    /// descriptors together, as Mojo's `ChannelPosix` reads into the buffer
    /// `Channel::GetReadBuffer` lends it.
    fn recv(&mut self) -> io::Result<usize> {
        let Connection { fd, reader, fds, .. } = self;
        reader.read_with(|room| fds.recv_into(*fd, room, |_| {}))
    }

    /// Writes ready batches until the queue is empty, the socket is full or
    /// this turn's share is spent.
    fn write(&mut self, now: Instant) {
        for _ in 0..BATCHES_PER_TURN {
            if self.write_done {
                return;
            }
            if self.batch.is_empty() && self.rest.is_none() {
                // Cleared before the queue is read: an item queued from
                // here on rings again.
                self.write_signal.store(false, Ordering::Release);
                match self.outbound.try_recv_turn(&mut self.batch, &mut self.rest) {
                    BatchPoll::Taken => {
                        count_sent(&self.ipc, &self.batch);
                        self.written = 0;
                    }
                    BatchPoll::Empty => {
                        self.blocked_since = None;
                        self.stalled = false;
                        return;
                    }
                    BatchPoll::Closed => return self.finish_write(),
                }
            }
            let before = self.written;
            let result = write_batch_nonblocking(
                &mut self.ipc.counted(&mut *self.stream),
                self.rest.as_deref(),
                &self.batch,
                &mut self.written,
            );
            match result {
                Ok(true) => {
                    self.batch.clear();
                    self.rest = None;
                    self.blocked_since = None;
                    self.stalled = false;
                }
                Ok(false) => {
                    // The peer's buffer is full: a write stall, as a
                    // blocking write that waited counted one.
                    if !std::mem::replace(&mut self.stalled, true) {
                        self.ipc.write_stall();
                    }
                    // A write that moved bytes restarts the timeout, as
                    // `SO_SNDTIMEO` bounds each write call.
                    if self.written > before || self.blocked_since.is_none() {
                        self.blocked_since = Some(now);
                    }
                    return;
                }
                Err(_) => return self.fail_write(),
            }
        }
        // This turn's share is spent and more may be ready: watch for room,
        // which a socket that drained reports at once.
        self.blocked_since.get_or_insert(now);
    }

    /// The queue is closed and written: close the socket, as the writer
    /// thread did on its way out.
    fn finish_write(&mut self) {
        self.write_done = true;
        self.blocked_since = None;
        self.writer.close();
        let _ = self.stream.shutdown(Shutdown::Both);
    }

    /// A write failed or timed out: the queue closes unwritten.
    fn fail_write(&mut self) {
        self.batch.clear();
        self.rest = None;
        self.outbound.close();
        self.finish_write();
    }

    /// When a blocked write times out.
    fn write_deadline(&self) -> Option<Instant> {
        let since = self.blocked_since?;
        since.checked_add(self.outbound.write_timeout())
    }
}

fn unexpected_fds() -> Inbound {
    Inbound::End(ConnectionEnd::BadMessage(ConnectionBadMessage::UnexpectedFds))
}

fn is_descriptor_refusal(error: &io::Error) -> bool {
    error.get_ref().is_some_and(|source| source.is::<cmux_ipc::fds::FdBadMessage>())
}

struct Loop {
    shared: Arc<Shared>,
    loops: Arc<Loops>,
    kind: LoopKind,
    connections: HashMap<u64, Connection>,
    /// Connections with a write waiting for room.
    blocked: usize,
    /// Automation's commands of this turn, run after the person's (kept
    /// for its capacity).
    later: Vec<Command>,
}

impl Loop {
    fn new(shared: Arc<Shared>, loops: Arc<Loops>, kind: LoopKind) -> Self {
        Self { shared, loops, kind, connections: HashMap::new(), blocked: 0, later: Vec::new() }
    }

    fn run(mut self) {
        let mut ready = Vec::new();
        let mut automation = Vec::new();
        loop {
            let timeout =
                self.next_deadline().map(|at| at.saturating_duration_since(Instant::now()));
            if let Err(error) = self.shared.poller.wait(&mut ready, timeout) {
                eprintln!("cmux-tui: mux-io wait failed: {error}");
                break;
            }
            let _turn = cmux_hang_watch::watch(TURN_HANG_DEADLINE);
            if !self.take_commands() {
                break;
            }
            let now = Instant::now();
            self.serve_ready(&mut ready, &mut automation, now);
            self.expire_writes(now);
        }
        self.close_all();
    }

    /// Runs what other threads asked, the person's connections' first;
    /// false once the loop must stop. A connection's own commands keep
    /// their order: all of them are the person's or none.
    fn take_commands(&mut self) -> bool {
        let commands = {
            let mut commands = self.shared.commands.lock().recover_poison();
            commands.woken = false;
            std::mem::take(&mut commands.queue)
        };
        let now = Instant::now();
        let mut later = std::mem::take(&mut self.later);
        let mut go_on = true;
        for command in commands {
            if !go_on {
                break;
            }
            if self.is_persons(&command) {
                go_on = self.run_command(command, now);
            } else {
                later.push(command);
            }
        }
        for command in later.drain(..) {
            go_on = go_on && self.run_command(command, now);
        }
        self.later = later;
        go_on
    }

    fn is_persons(&self, command: &Command) -> bool {
        let Command::Op(route, _) = command else { return false };
        self.connections.get(&route.token).is_some_and(|connection| connection.inbound.is_person())
    }

    /// Runs one command; false once the loop must stop.
    fn run_command(&mut self, command: Command, now: Instant) -> bool {
        match command {
            Command::Add(mut connection) => {
                let token = connection.token;
                connection.here = self.kind == LoopKind::Person;
                // A connection moved here may wait for room already.
                self.blocked += usize::from(connection.blocked_since.is_some());
                self.connections.insert(token, *connection);
                // Input that came before the loop watched the socket, the
                // prefix included, and the first queued replies.
                self.update(token, |connection| {
                    connection.cut();
                    connection.read();
                    connection.write(now);
                });
            }
            Command::Op(route, op) if !self.connections.contains_key(&route.token) => {
                // Sent here before the connection moved to the person's
                // loop: it follows the connection, behind its `Add`.
                if let Some(moved) = route.moved.get().and_then(std::sync::Weak::upgrade)
                    && !Arc::ptr_eq(&moved, &self.shared)
                {
                    let _ = moved.command(Command::Op(route, op));
                }
            }
            Command::Op(route, Op::Writable) => self.update(route.token, |connection| {
                if connection.blocked_since.is_none() {
                    connection.write(now);
                }
            }),
            Command::Op(route, Op::ResumeRead) => self.update(route.token, |connection| {
                connection.paused = false;
                connection.cut();
            }),
            Command::Op(route, Op::StopRead) => self.update(route.token, |connection| {
                if connection.reading {
                    connection.end_read();
                }
            }),
            Command::Stop => {
                self.shared.commands.lock().recover_poison().stopped = true;
                return false;
            }
        }
        true
    }

    /// Serves this turn's ready sockets, the person's connections first (on
    /// the shared loop, those not moved yet); the others keep their kernel
    /// order behind them.
    fn serve_ready(&mut self, ready: &mut Vec<Ready>, automation: &mut Vec<Ready>, now: Instant) {
        for event in ready.drain(..) {
            if event.token == WAKE_TOKEN {
                continue;
            }
            let person = self
                .connections
                .get(&event.token)
                .is_some_and(|connection| connection.inbound.is_person());
            if person {
                self.on_ready(event, now);
            } else {
                automation.push(event);
            }
        }
        for event in automation.drain(..) {
            self.on_ready(event, now);
        }
    }

    fn on_ready(&mut self, event: Ready, now: Instant) {
        // Classed the person's since its last turn: it moves before it
        // reads, so its lines are routed on the person's loop. Its reply
        // may have left inline, with no write turn here to
        // move it; the socket stays readable for that loop.
        if self.moves(event.token) {
            self.move_to_person(event.token);
            if !self.connections.contains_key(&event.token) {
                return;
            }
        }
        self.update(event.token, |connection| {
            if event.readable {
                connection.read();
            }
            if event.writable && !connection.write_done {
                connection.write(now);
            }
        });
    }

    /// Closes every connection whose blocked write is past its timeout.
    fn expire_writes(&mut self, now: Instant) {
        if self.blocked == 0 {
            return;
        }
        let expired: Vec<u64> = self
            .connections
            .values()
            .filter(|connection| connection.write_deadline().is_some_and(|at| at <= now))
            .map(|connection| connection.token)
            .collect();
        for token in expired {
            self.update(token, Connection::fail_write);
        }
    }

    fn next_deadline(&self) -> Option<Instant> {
        if self.blocked == 0 {
            return None;
        }
        self.connections.values().filter_map(Connection::write_deadline).min()
    }

    /// Runs `change` on connection `token`, then watches its socket for
    /// what it wants and lets it go once both sides are done.
    fn update(&mut self, token: u64, change: impl FnOnce(&mut Connection)) {
        let Some(connection) = self.connections.get_mut(&token) else { return };
        let was_blocked = connection.blocked_since.is_some();
        change(connection);
        let is_blocked = connection.blocked_since.is_some();
        self.blocked = (self.blocked + usize::from(is_blocked)) - usize::from(was_blocked);
        let wants = if connection.is_done() { Interest::NONE } else { connection.wants() };
        if wants != connection.interest {
            let poller = &self.shared.poller;
            if poller.update(connection.fd, token, connection.interest, wants).is_err() {
                // A socket the poller refuses cannot be served.
                connection.fail_write();
                if connection.reading {
                    connection.deliver(Inbound::End(ConnectionEnd::Dropped));
                }
                let _ = poller.update(connection.fd, token, connection.interest, Interest::NONE);
                connection.interest = Interest::NONE;
            } else {
                connection.interest = wants;
            }
        }
        if connection.is_done() {
            if let Some(connection) = self.connections.remove(&token) {
                connection.inbound.released();
            }
            return;
        }
        if self.moves(token) {
            self.move_to_person(token);
        }
    }

    /// Connection `token` is on the shared loop, now the person's, and the
    /// person's loop has not refused it.
    fn moves(&self, token: u64) -> bool {
        self.kind == LoopKind::Shared
            && self
                .connections
                .get(&token)
                .is_some_and(|connection| !connection.stays && connection.inbound.is_person())
    }

    /// Moves connection `token`, now the person's, to the person's loop:
    /// its socket leaves this poller, the connection (its reader, its
    /// partial batch, its write deadline) goes to that loop behind every
    /// command already queued there, and only then do its commands go
    /// there too. A command that reached this loop meanwhile follows it
    /// (`Command::Op` for a connection no longer here). When that loop
    /// cannot take it, it stays here.
    fn move_to_person(&mut self, token: u64) {
        let Some(person) = self.loops.person() else {
            if let Some(connection) = self.connections.get_mut(&token) {
                connection.stays = true;
            }
            return;
        };
        let Some(mut connection) = self.connections.remove(&token) else { return };
        if self
            .shared
            .poller
            .update(connection.fd, token, connection.interest, Interest::NONE)
            .is_err()
        {
            // Still watched here: it is served here.
            connection.stays = true;
            self.connections.insert(token, connection);
            return;
        }
        connection.interest = Interest::NONE;
        let was_blocked = connection.blocked_since.is_some();
        let route = connection.route.clone();
        match person.try_command(Command::Add(Box::new(connection))) {
            Ok(()) => {
                self.blocked -= usize::from(was_blocked);
                let _ = route.moved.set(Arc::downgrade(&person));
            }
            Err(Command::Add(mut connection)) => {
                // The person's loop stopped (the mux is going): it closes
                // here.
                connection.stays = true;
                self.connections.insert(token, *connection);
                self.update(token, |_| {});
            }
            Err(_) => {}
        }
    }

    /// The mux is gone: every connection closes as if its writes failed.
    fn close_all(&mut self) {
        let tokens: Vec<u64> = self.connections.keys().copied().collect();
        for token in tokens {
            self.update(token, |connection| {
                connection.fail_write();
                if connection.reading {
                    connection.deliver(Inbound::End(ConnectionEnd::Dropped));
                }
            });
        }
    }
}
