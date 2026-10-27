//! The daemon's IO reactor (p05-ipc-155): one thread reads and frames every
//! local connection; no connection has a reader thread of its own.
//!
//! Chrome's browser process reads every renderer's Mojo channel on its one
//! IO thread (`BrowserThread::IO`, content/browser/browser_thread_impl.cc), a
//! message pump over epoll or kqueue (base/message_loop/message_pump_epoll.cc,
//! message_pump_kqueue.cc). `ChannelPosix::OnFileCanReadWithoutBlocking`
//! reads into the buffer the channel lends it and cuts whole messages
//! (mojo/core/channel_posix.cc, channel.cc), and each message is posted to
//! the sequence its endpoint is bound to: the IO thread runs no handler. The
//! reactor does the same:
//!
//! - **Read.** Each connection's socket is registered edge-triggered with
//!   mio (epoll on Linux, kqueue on macOS). On readiness the reactor reads
//!   with `recvmsg(MSG_DONTWAIT)` into the connection's `FrameReader` until
//!   the socket would block, at most [`READS_PER_TURN`] reads per turn so
//!   one busy client never holds the others. The socket itself stays
//!   blocking: its `mux-line-out` writer still writes it with blocking
//!   writes until the reactor flushes writes too (p05-ipc-156).
//! - **Frame and route.** The bytes are cut into owned messages
//!   (line_connection.rs [`Inbound`]) and posted, in order, to the
//!   connection's own sequence on the sequenced pool's control workers
//!   (sequenced_pool.rs). There its [`LineSession`] handles them: admission,
//!   hello gate, frame grant, then the route to the connection's control
//!   and request sequences, as the reader thread did. One task at a time per
//!   connection: the session is owned by the reactor while idle and by the
//!   task while it runs, and comes back to the reactor through its channel.
//! - **Bounded.** A connection reads ahead at most [`MAX_QUEUED_MESSAGES`]
//!   messages or [`MAX_QUEUED_BYTES`] bytes past what its session took; then
//!   the reactor stops reading it and the kernel's socket buffer holds the
//!   rest, as a reader thread busy with a line did.
//! - **Setup and teardown off the reactor.** The peer's identity
//!   (`AcceptedPeer::resolve`, which may block) and the session's start run
//!   as one System-lane `work` item per accepted connection; the teardown,
//!   which waits for the connection's requests, runs on its last task inside
//!   `request_path::will_block`, so the pool starts a worker meanwhile.
//! - **No idle wakeups.** The reactor waits in `poll` with no timeout; only
//!   socket readiness or a command (a new connection, a session coming
//!   back) wakes it.
//!
//! QoS: the reactor runs at the request class, as the accept loop does
//! (user-initiated); every key of the person passes through it, so it is the
//! candidate for a PL-qos user-interactive exception row ("IO thread every
//! key passes"), which PL-qos decides. Each message then runs at its
//! connection's class on the worker (connection_qos.rs `TaskReaderClass`).

use std::collections::{HashMap, VecDeque};
use std::io;
use std::os::fd::RawFd;
use std::panic::{AssertUnwindSafe, catch_unwind};
use std::sync::Arc;
use std::sync::atomic::{AtomicU64, AtomicUsize, Ordering};
use std::sync::mpsc;
use std::thread::JoinHandle;
use std::time::Duration;

use cmux_threads::ThreadQos;
use cmux_threads::work::{Lane, Priority, Shutdown};
use mio::unix::SourceFd;
use mio::{Events, Interest, Poll, Token, Waker};

use super::admission::LocalAdmission;
use super::connection_scheduler::REQUEST_THREAD_QOS;
use super::connection_scheduler::connection_qos::TaskReaderClass;
use super::frame_dispatch::RequestFrames;
use super::line_connection::{
    ConnectionEnd, ConnectionInput, Handled, Inbound, LineSession, SessionParts,
};
use super::sequenced_pool::{Sequence, SequencePriority};
use super::{ClientTransport, ConnectionPermit, Mux, RenderService, origin_gate, transport};

/// The reactor thread's name.
pub(super) const REACTOR_THREAD: &str = "mux-io-reactor";

/// The reactor's QoS: the request class (see the module docs).
pub(super) const REACTOR_QOS: ThreadQos = REQUEST_THREAD_QOS;

/// Reads of one connection per turn before the reactor serves the others.
const READS_PER_TURN: usize = 8;

/// Messages a connection reads ahead of its session.
pub(super) const MAX_QUEUED_MESSAGES: usize = 256;

/// Bytes a connection reads ahead of its session (lines and frames cut).
pub(super) const MAX_QUEUED_BYTES: usize = 4 * 1024 * 1024;

/// Messages one session task handles before it gives its worker back.
const MAX_BATCH: usize = 64;

/// One reactor turn (the readiness it handles, not its wait) is a hang past
/// this: the turn only reads, cuts and posts.
const REACTOR_TURN_HANG: Duration = Duration::from_millis(100);

const WAKE: Token = Token(usize::MAX);

/// Readiness events one `poll` returns at most.
const EVENTS: usize = 256;

/// The session of a connection the reactor reads: the local admission, the
/// request frame lane, and a class entered per message.
type LocalSession = LineSession<LocalAdmission, RequestFrames, TaskReaderClass>;

/// What a reactor is told through its channel.
enum Command {
    /// A connection whose session started.
    Adopt(Box<Adopted>),
    /// A session task handled its messages; the connection stays open.
    Returned { token: Token, session: Box<LocalSession>, frames_opened: bool },
    /// A session ended its connection (its teardown runs on its task).
    Ended(Token),
    /// The reactor's owner is gone: it exits once its connections ended.
    Stop,
}

struct Adopted {
    session: LocalSession,
    input: ConnectionInput,
    sequence: Sequence,
}

/// The reactor's channel and its waker.
#[derive(Clone)]
struct ReactorLink {
    commands: mpsc::Sender<Command>,
    waker: Arc<Waker>,
}

impl ReactorLink {
    /// Sends `command` and wakes the reactor; the command comes back when
    /// the reactor has exited (its contents then drop: a session's drop
    /// ends its connection).
    fn send(&self, command: Command) -> Result<(), Command> {
        self.commands.send(command).map_err(|error| error.0)?;
        // A failed wake leaves the command queued for the next readiness;
        // the waker's descriptor lives as long as the reactor.
        let _ = self.waker.wake();
        Ok(())
    }
}

/// Counters a test reads.
#[derive(Debug, Default)]
struct ReactorStats {
    /// Returns from a waiting `poll`.
    wakeups: AtomicU64,
    /// Connections registered now.
    connections: AtomicUsize,
}

/// The handle of one IO reactor. Dropping it stops the reactor once its
/// connections ended.
pub(super) struct IoReactor {
    link: ReactorLink,
    stats: Arc<ReactorStats>,
    _thread: JoinHandle<()>,
}

impl std::fmt::Debug for IoReactor {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("IoReactor").field("stats", &self.stats).finish()
    }
}

impl IoReactor {
    /// Starts the reactor thread.
    pub(super) fn start() -> io::Result<Self> {
        let poll = Poll::new()?;
        let waker = Arc::new(Waker::new(poll.registry(), WAKE)?);
        let (commands, receiver) = mpsc::channel();
        let link = ReactorLink { commands, waker };
        let stats = Arc::new(ReactorStats::default());
        let reactor = Reactor {
            poll,
            commands: receiver,
            link: link.clone(),
            entries: HashMap::new(),
            ready: VecDeque::new(),
            next_token: 0,
            stopping: false,
            stats: stats.clone(),
        };
        let thread = cmux_threads::spawn(REACTOR_THREAD, REACTOR_QOS, move || {
            let _hang_watch =
                cmux_hang_watch::register_thread(cmux_hang_watch::ThreadKind::Io, REACTOR_THREAD);
            cmux_threads::disallow_blocking();
            reactor.run();
        })?;
        Ok(Self { link, stats, _thread: thread })
    }

    /// Serves an accepted local socket: its peer's identity and its
    /// session's start run as a System-lane `work` item (they may block),
    /// then the reactor reads it. A refused item drops the stream and the
    /// permit: the client reads the end of the stream.
    pub(super) fn serve(
        &self,
        mux: Arc<Mux>,
        stream: Box<dyn transport::Stream>,
        render_service: Arc<RenderService>,
        permit: ConnectionPermit,
    ) {
        let link = self.link.clone();
        let item_mux = mux.clone();
        let start = move || {
            let mux = item_mux;
            let peer = origin_gate::AcceptedPeer::resolve(&mux, &*stream);
            let parts = SessionParts {
                mux: mux.clone(),
                render_service,
                connection_permit: Some(permit),
                transport: ClientTransport::Unix,
            };
            let Ok(session) = LineSession::open(
                parts,
                &*stream,
                peer,
                LocalAdmission,
                RequestFrames::default(),
                TaskReaderClass::new,
            ) else {
                return;
            };
            let sequence = mux.sequenced_pool.sequence(SequencePriority::Control);
            let input = ConnectionInput::new(stream);
            // A reactor that exited hands the connection back; it drops here,
            // and the session's drop ends it.
            let _ = link.send(Command::Adopt(Box::new(Adopted { session, input, sequence })));
        };
        // The person's first request waits on this item, as it waited on a
        // reader thread's start.
        let _ =
            mux.work.post(Priority::UserBlocking, Lane::System, Shutdown::SkipOnShutdown, start);
    }

    /// Returns from a waiting `poll` over the reactor's life.
    #[cfg(test)]
    pub(super) fn wakeups(&self) -> u64 {
        self.stats.wakeups.load(Ordering::Relaxed)
    }

    /// Connections the reactor reads now.
    #[cfg(test)]
    pub(super) fn connections(&self) -> usize {
        self.stats.connections.load(Ordering::Relaxed)
    }
}

impl Drop for IoReactor {
    fn drop(&mut self) {
        let _ = self.link.send(Command::Stop);
    }
}

/// One connection the reactor reads.
struct Entry {
    input: ConnectionInput,
    fd: RawFd,
    carries_frames: bool,
    sequence: Sequence,
    /// Home while no task runs it.
    session: Option<Box<LocalSession>>,
    /// Cut and not yet posted, in arrival order.
    queue: VecDeque<Inbound>,
    queued_bytes: usize,
    /// Readiness seen and the last read did not find the socket empty.
    readable: bool,
    /// A frame gate waits for the session's answer: nothing more is cut.
    gate_pending: bool,
    /// Its last message (a bad message or an end) is cut.
    stopped: bool,
    registered: bool,
    in_ready: bool,
}

impl Entry {
    fn has_room(&self) -> bool {
        self.queue.len() < MAX_QUEUED_MESSAGES && self.queued_bytes < MAX_QUEUED_BYTES
    }

    fn wants_read(&self) -> bool {
        self.readable && !self.stopped && !self.gate_pending && self.has_room()
    }

    /// Cuts what the reader holds, up to the read-ahead bound.
    fn cut(&mut self) {
        while !self.stopped && !self.gate_pending && self.has_room() {
            let Some(item) = self.input.cut(self.carries_frames) else { break };
            self.push(item);
        }
    }

    fn push(&mut self, item: Inbound) {
        if matches!(item, Inbound::FrameGate) {
            self.gate_pending = true;
        } else if item.is_last() {
            self.stopped = true;
        }
        self.queued_bytes += item.weight();
        self.queue.push_back(item);
    }
}

struct Reactor {
    poll: Poll,
    commands: mpsc::Receiver<Command>,
    /// Handed to each session task, to come back with.
    link: ReactorLink,
    entries: HashMap<Token, Entry>,
    /// Connections with work for the next turn: readable past their turn's
    /// budget, or a session that came back.
    ready: VecDeque<Token>,
    next_token: usize,
    stopping: bool,
    stats: Arc<ReactorStats>,
}

impl Reactor {
    fn run(mut self) {
        let mut events = Events::with_capacity(EVENTS);
        loop {
            // Work left from the last turn polls without waiting.
            let timeout = (!self.ready.is_empty()).then_some(Duration::ZERO);
            match self.poll.poll(&mut events, timeout) {
                Ok(()) => {}
                Err(error) if error.kind() == io::ErrorKind::Interrupted => continue,
                Err(error) => {
                    eprintln!("cmux-tui: the IO reactor stopped: {error}");
                    break;
                }
            }
            if timeout.is_none() {
                self.stats.wakeups.fetch_add(1, Ordering::Relaxed);
            }
            let _turn = cmux_hang_watch::watch(REACTOR_TURN_HANG);
            for event in events.iter() {
                let token = event.token();
                if token == WAKE {
                    continue;
                }
                if let Some(entry) = self.entries.get_mut(&token) {
                    entry.readable = true;
                    self.mark_ready(token);
                }
            }
            self.drain_commands();
            let turn = self.ready.len();
            for _ in 0..turn {
                let Some(token) = self.ready.pop_front() else { break };
                self.pump(token);
            }
            if self.stopping && self.entries.is_empty() {
                break;
            }
        }
        // Connections still here end as their sessions drop; commands still
        // queued drop with the channel the same way.
        for token in self.entries.keys().copied().collect::<Vec<_>>() {
            self.remove(token);
        }
    }

    fn mark_ready(&mut self, token: Token) {
        if let Some(entry) = self.entries.get_mut(&token)
            && !entry.in_ready
        {
            entry.in_ready = true;
            self.ready.push_back(token);
        }
    }

    fn drain_commands(&mut self) {
        while let Ok(command) = self.commands.try_recv() {
            match command {
                Command::Adopt(adopted) => self.adopt(*adopted),
                Command::Returned { token, session, frames_opened } => {
                    let Some(entry) = self.entries.get_mut(&token) else { continue };
                    entry.session = Some(session);
                    if frames_opened {
                        entry.gate_pending = false;
                        entry.input.open_frames();
                    }
                    self.mark_ready(token);
                }
                Command::Ended(token) => self.remove(token),
                Command::Stop => self.stopping = true,
            }
        }
    }

    fn adopt(&mut self, adopted: Adopted) {
        let Adopted { session, input, sequence } = adopted;
        let Some(fd) = input.socket_fd() else { return };
        let token = Token(self.next_token);
        self.next_token = self.next_token.wrapping_add(1) % WAKE.0;
        let registered =
            self.poll.registry().register(&mut SourceFd(&fd), token, Interest::READABLE);
        if let Err(error) = registered {
            eprintln!("cmux-tui: the IO reactor could not watch a connection: {error}");
            return;
        }
        let carries_frames = session.carries_frames();
        let entry = Entry {
            input,
            fd,
            carries_frames,
            sequence,
            session: Some(Box::new(session)),
            queue: VecDeque::new(),
            queued_bytes: 0,
            // Bytes may have arrived before the registration.
            readable: true,
            gate_pending: false,
            stopped: false,
            registered: true,
            in_ready: false,
        };
        self.entries.insert(token, entry);
        self.stats.connections.fetch_add(1, Ordering::Relaxed);
        self.mark_ready(token);
    }

    /// Cuts, reads within the turn's budget, and posts the next batch.
    fn pump(&mut self, token: Token) {
        let Some(entry) = self.entries.get_mut(&token) else { return };
        entry.in_ready = false;
        entry.cut();
        let mut reads = 0;
        while entry.wants_read() {
            if reads == READS_PER_TURN {
                entry.in_ready = true;
                self.ready.push_back(token);
                break;
            }
            reads += 1;
            match entry.input.fill_ready() {
                Ok(true) => entry.cut(),
                Ok(false) => entry.readable = false,
                Err(end) => entry.push(Inbound::End(end)),
            }
        }
        if entry.stopped && entry.registered {
            // Nothing more is read: no more readiness for it.
            entry.registered = false;
            let _ = self.poll.registry().deregister(&mut SourceFd(&entry.fd));
        }
        self.dispatch(token);
    }

    /// Posts the queued messages to the connection's sequence when its
    /// session is home.
    fn dispatch(&mut self, token: Token) {
        let Some(entry) = self.entries.get_mut(&token) else { return };
        if entry.queue.is_empty() {
            return;
        }
        let Some(session) = entry.session.take() else { return };
        let count = entry.queue.len().min(MAX_BATCH);
        let batch: Vec<Inbound> = entry.queue.drain(..count).collect();
        let weight: usize = batch.iter().map(Inbound::weight).sum();
        entry.queued_bytes = entry.queued_bytes.saturating_sub(weight);
        let link = self.link.clone();
        if entry.sequence.post(move || run_batch(session, batch, &link, token)).is_err() {
            // The pool shut down or could start no worker: the task dropped
            // unrun, and its session's drop ended the connection.
            self.remove(token);
        }
    }

    fn remove(&mut self, token: Token) {
        let Some(mut entry) = self.entries.remove(&token) else { return };
        if entry.registered {
            // The writer holds other descriptors of the same socket, so its
            // epoll registration outlives this one's close unless removed.
            let _ = self.poll.registry().deregister(&mut SourceFd(&entry.fd));
        }
        entry.input.release();
        self.stats.connections.fetch_sub(1, Ordering::Relaxed);
    }
}

/// One session task: handles `batch` in order, then gives the session back
/// to the reactor, or ends the connection.
fn run_batch(
    mut session: Box<LocalSession>,
    batch: Vec<Inbound>,
    link: &ReactorLink,
    token: Token,
) {
    let mut frames_opened = false;
    let mut items = batch.into_iter();
    let handled = catch_unwind(AssertUnwindSafe(|| {
        for item in items.by_ref() {
            match session.handle(item) {
                Handled::Continue => {}
                Handled::FramesOpen => frames_opened = true,
                Handled::End(end) => return Some(end),
            }
        }
        None
    }));
    // Messages after the end are never handled; their lines zero as they drop.
    drop(items);
    let (end, panic) = match handled {
        Ok(None) => {
            // A reactor that exited hands it back; it drops here, and the
            // session's drop ends the connection.
            let _ = link.send(Command::Returned { token, session, frames_opened });
            return;
        }
        Ok(Some(end)) => (end, None),
        Err(panic) => (ConnectionEnd::Dropped, Some(panic)),
    };
    let _ = link.send(Command::Ended(token));
    // The teardown waits for the connection's requests: a blocked task, so
    // the pool starts another worker meanwhile (sequenced_pool.rs).
    crate::request_path::will_block(move || {
        session.finish(end, panic);
    });
}

#[cfg(test)]
#[path = "io_reactor_tests.rs"]
mod tests;
