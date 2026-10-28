//! The daemon's IO reactor (p05-ipc-155): one thread reads and frames every
//! local connection; no connection has a reader thread of its own.
//!
//! Chrome's browser process reads every renderer's Mojo channel on its one
//! IO thread (`BrowserThread::IO`, content/browser/browser_thread_impl.cc), a
//! message pump over epoll or kqueue (base/message_loop/message_pump_epoll.cc,
//! message_pump_kqueue.cc). `ChannelPosix::OnFileCanReadWithoutBlocking`
//! reads into the buffer the channel lends it and cuts whole messages
//! (mojo/core/channel_posix.cc, channel.cc), and the IO thread routes each
//! one to the sequence its endpoint is bound to
//! (ipc/ipc_mojo_bootstrap.cc `ChannelAssociatedGroupController::Accept`):
//! it runs no handler. The reactor does the same:
//!
//! - **Read.** Each connection's socket is registered edge-triggered with
//!   mio (epoll on Linux, kqueue on macOS). On readiness the reactor reads
//!   with `recvmsg(MSG_DONTWAIT)` into the connection's `FrameReader` until
//!   the socket would block, at most [`READS_PER_TURN`] reads per turn so
//!   one busy client never holds the others. The socket itself stays
//!   blocking: its `mux-line-out` writer still writes it with blocking
//!   writes until the reactor flushes writes too (p05-ipc-156).
//! - **Route frames here.** The bytes are cut into owned messages
//!   (line_connection.rs [`Inbound`]). While nothing of the connection is
//!   queued or running before them, its frames are routed on the reactor:
//!   the frame gate and each frame's grant are checked, an INPUT frame goes
//!   to its stream's sequence, a REQUEST or CANCEL to its request or stream
//!   sequence (frame_dispatch.rs). The person's keys never wait for a pool
//!   worker before they reach their stream. An automation connection's
//!   frames are not routed here: their parse and route run on its own
//!   sequence, so a burst of them never delays the reactor's next read.
//! - **Post lines.** Lines (and frames queued behind a line) go, in order,
//!   to the connection's own sequence on the sequenced pool
//!   (sequenced_pool.rs), where its [`LineSession`] handles them:
//!   admission, hello gate, frame grant, route. A person connection's
//!   sequence runs on the input workers, ahead of every automation
//!   connection's control work (p05-ipc.md section 3.4); the others run on
//!   the control workers. One task at a time per connection: the session is
//!   owned by the reactor while idle and by the task while it runs, and
//!   comes back to the reactor through its channel.
//! - **Bounded.** A connection reads ahead at most [`MAX_QUEUED_MESSAGES`]
//!   messages or [`MAX_QUEUED_BYTES`] bytes past what its session took; then
//!   the reactor stops reading it and the kernel's socket buffer holds the
//!   rest, as a reader thread busy with a line did.
//! - **Setup and teardown off the reactor.** The peer's identity
//!   (`AcceptedPeer::resolve`, which may block) and the session's start run
//!   as one System-lane `work` item per accepted connection; the teardown,
//!   which waits for the connection's requests, runs as the connection's
//!   last task inside `request_path::will_block`, so the pool starts a
//!   worker meanwhile. A session the reactor's side drops unfinished ends
//!   its connection on a `work` item ([`HeldSession`]): the reactor never
//!   takes the client registry's or the store's locks for an end.
//! - **One connection's fault ends one connection.** A panic while a
//!   connection is read, cut or routed ends that connection only, as a
//!   Mojo channel error closes that channel only (mojo/core/channel.cc
//!   `OnError`). When the reactor thread itself ends (a poll error, a
//!   panic), [`IoReactor::is_alive`] turns false and the session serves
//!   every later connection on a reader thread of its own, as where no
//!   reactor started.
//! - **No idle wakeups.** The reactor waits in `poll` with no timeout; only
//!   socket readiness or a command (a new connection, a session coming
//!   back) wakes it.
//!
//! QoS: the reactor runs at the request class, as the accept loop does
//! (user-initiated); every key of the person passes through it, so it is the
//! candidate for a PL-qos user-interactive exception row ("IO thread every
//! key passes"), which PL-qos decides. A frame it routes runs at its own
//! class; every message a session task runs, at its connection's class
//! (connection_qos.rs `TaskReaderClass`).

use std::any::Any;
use std::collections::{HashMap, VecDeque};
use std::io;
use std::os::fd::RawFd;
use std::panic::{AssertUnwindSafe, catch_unwind};
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, AtomicU64, AtomicUsize, Ordering};
use std::sync::mpsc;
use std::thread::JoinHandle;
use std::time::Duration;

use cmux_threads::ThreadQos;
use cmux_threads::work::{Lane, Priority, Shutdown};
use mio::unix::SourceFd;
use mio::{Events, Interest, Poll, Token, Waker};

use super::admission::LocalAdmission;
use super::connection_scheduler::REQUEST_THREAD_QOS;
use super::connection_scheduler::connection_qos::{ConnectionClass, TaskReaderClass};
use super::frame_dispatch::RequestFrames;
use super::line_connection::{
    ConnectionEnd, ConnectionInput, Handled, Inbound, LineSession, SessionParts, drive,
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

/// Messages one session task handles before it gives its worker back, and
/// frames the reactor routes for one connection per turn.
pub(super) const MAX_BATCH: usize = 64;

/// One reactor turn (the readiness it handles, not its wait) is a hang past
/// this: the turn only reads, cuts and routes.
const REACTOR_TURN_HANG: Duration = Duration::from_millis(100);

const WAKE: Token = Token(usize::MAX);

/// Readiness events one `poll` returns at most.
const EVENTS: usize = 256;

/// The session of a connection the reactor reads: the local admission, the
/// request frame lane, and a class entered per message.
type LocalSession = LineSession<LocalAdmission, RequestFrames, TaskReaderClass>;

/// A connection's session while the reactor's side holds it: in its entry,
/// in a command, or in its task. Dropped unfinished (a task the pool
/// refused, a reactor that exited, a connection the reactor could not
/// watch), it ends its connection on a System-lane `work` item: the end
/// takes the client registry's and the store's locks, which the reactor
/// never waits for.
struct HeldSession(Option<Box<LocalSession>>);

impl HeldSession {
    fn new(session: LocalSession) -> Self {
        Self(Some(Box::new(session)))
    }

    fn handle(&mut self, item: Inbound) -> Handled {
        match &mut self.0 {
            Some(session) => session.handle(item),
            None => Handled::End(ConnectionEnd::Dropped),
        }
    }

    fn handle_on_reactor(&mut self, item: Inbound) -> Handled {
        match &mut self.0 {
            Some(session) => session.handle_on_reactor(item),
            None => Handled::End(ConnectionEnd::Dropped),
        }
    }

    fn class(&self) -> ConnectionClass {
        self.0.as_ref().map_or(ConnectionClass::Unclassified, |session| session.connection_class())
    }

    /// Whether the reactor routes its frames: every connection but an
    /// automation one (see the module docs).
    fn routes_on_reactor(&self) -> bool {
        self.class() != ConnectionClass::Automation
    }

    /// The priority its tasks run at: the person's connections on the
    /// input workers, the others on the control workers.
    fn priority(&self) -> SequencePriority {
        match self.class() {
            ConnectionClass::Person => SequencePriority::Input,
            ConnectionClass::Unclassified | ConnectionClass::Automation => {
                SequencePriority::Control
            }
        }
    }

    /// A new sequence at its priority.
    fn sequence(&self) -> Option<Sequence> {
        let session = self.0.as_ref()?;
        Some(session.mux().sequenced_pool.sequence(self.priority()))
    }

    /// The session, which then ends only as its taker ends it.
    fn take(mut self) -> Option<Box<LocalSession>> {
        self.0.take()
    }
}

impl Drop for HeldSession {
    fn drop(&mut self) {
        let Some(session) = self.0.take() else { return };
        let mux = session.mux().clone();
        // Refused only while the daemon shuts down: the item drops here, and
        // the session's own drop ends the connection on this thread.
        let _ = mux.work.post(
            Priority::UserBlocking,
            Lane::System,
            Shutdown::SkipOnShutdown,
            move || drop(session),
        );
    }
}

/// What a reactor is told through its channel.
enum Command {
    /// A connection whose session started.
    Adopt(Box<Adopted>),
    /// A session task handled its messages; the connection stays open.
    Returned { token: Token, session: HeldSession, frames_opened: bool },
    /// A session ended its connection (its teardown runs on its task).
    Ended(Token),
    /// The reactor's owner is gone: it exits once its connections ended.
    Stop,
    /// The reactor thread panics, as a fault outside any one connection.
    #[cfg(test)]
    Panic,
}

struct Adopted {
    session: HeldSession,
    input: ConnectionInput,
}

/// The reactor's channel and its waker.
#[derive(Clone)]
struct ReactorLink {
    commands: mpsc::Sender<Command>,
    waker: Arc<Waker>,
}

impl ReactorLink {
    /// Sends `command` and wakes the reactor; the command comes back when
    /// the reactor has exited.
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

/// Clears the reactor's live flag however its thread ends.
struct LiveFlag(Arc<AtomicBool>);

impl Drop for LiveFlag {
    fn drop(&mut self) {
        self.0.store(false, Ordering::Release);
    }
}

/// The handle of one IO reactor. Dropping it stops the reactor once its
/// connections ended.
pub(super) struct IoReactor {
    link: ReactorLink,
    live: Arc<AtomicBool>,
    stats: Arc<ReactorStats>,
    /// Makes each connection's frame lane.
    frames: fn() -> RequestFrames,
    _thread: JoinHandle<()>,
}

impl std::fmt::Debug for IoReactor {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("IoReactor")
            .field("live", &self.is_alive())
            .field("stats", &self.stats)
            .finish()
    }
}

impl IoReactor {
    /// Starts the reactor thread.
    pub(super) fn start() -> io::Result<Self> {
        Self::start_with(RequestFrames::default)
    }

    /// [`Self::start`] whose connections route frames with `frames`' lanes.
    fn start_with(frames: fn() -> RequestFrames) -> io::Result<Self> {
        let poll = Poll::new()?;
        let waker = Arc::new(Waker::new(poll.registry(), WAKE)?);
        let (commands, receiver) = mpsc::channel();
        let link = ReactorLink { commands, waker };
        let stats = Arc::new(ReactorStats::default());
        let live = Arc::new(AtomicBool::new(true));
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
        let thread_live = LiveFlag(live.clone());
        let thread = cmux_threads::spawn(REACTOR_THREAD, REACTOR_QOS, move || {
            let _live = thread_live;
            let _hang_watch =
                cmux_hang_watch::register_thread(cmux_hang_watch::ThreadKind::Io, REACTOR_THREAD);
            cmux_threads::disallow_blocking();
            reactor.run();
        })?;
        Ok(Self { link, live, stats, frames, _thread: thread })
    }

    /// Whether the reactor thread runs: once it ended, the session serves
    /// each new connection on a thread of its own (listen.rs).
    pub(super) fn is_alive(&self) -> bool {
        self.live.load(Ordering::Acquire)
    }

    /// Serves an accepted local socket: its peer's identity and its
    /// session's start run as a System-lane `work` item (they may block),
    /// then the reactor reads it; a reactor that ended meanwhile hands it to
    /// a reader thread of its own. A refused item drops the stream and the
    /// permit: the client reads the end of the stream.
    pub(super) fn serve(
        &self,
        mux: Arc<Mux>,
        stream: Box<dyn transport::Stream>,
        render_service: Arc<RenderService>,
        permit: ConnectionPermit,
    ) {
        let link = self.link.clone();
        let frames = self.frames;
        let item_mux = mux.clone();
        let start = move || {
            let mux = item_mux;
            let peer = origin_gate::AcceptedPeer::resolve(&mux, &*stream);
            let parts = SessionParts {
                mux,
                render_service,
                connection_permit: Some(permit),
                transport: ClientTransport::Unix,
            };
            let Ok(session) = LineSession::open(
                parts,
                &*stream,
                peer,
                LocalAdmission,
                frames(),
                TaskReaderClass::new,
            ) else {
                return;
            };
            let adopted =
                Adopted { session: HeldSession::new(session), input: ConnectionInput::new(stream) };
            if let Err(Command::Adopt(adopted)) = link.send(Command::Adopt(Box::new(adopted))) {
                serve_on_thread(*adopted);
            }
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

    /// Makes the reactor thread panic.
    #[cfg(test)]
    pub(super) fn panic_for_test(&self) {
        let _ = self.link.send(Command::Panic);
    }
}

impl Drop for IoReactor {
    fn drop(&mut self) {
        let _ = self.link.send(Command::Stop);
    }
}

/// Serves a connection the reactor could not take (it ended) on a reader
/// thread of its own, as where no reactor started. A thread that cannot
/// start drops the session, which ends the connection.
fn serve_on_thread(adopted: Adopted) {
    let Adopted { session, input } = adopted;
    let _ = super::spawn_connection_reader(
        "mux-conn",
        move || (session, input),
        |(session, input)| {
            if let Some(session) = session.take() {
                drive(*session, input);
            }
        },
    );
}

/// One connection the reactor reads.
struct Entry {
    input: ConnectionInput,
    fd: RawFd,
    carries_frames: bool,
    /// Where its session's tasks run; picked again while the session is
    /// home when its class moved it to another priority.
    sequence: Sequence,
    /// Home while no task runs it.
    session: Option<HeldSession>,
    /// Cut and not yet routed or posted, in arrival order.
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

/// What the reactor did with the frames at the front of a connection's
/// queue.
enum Routed {
    /// The front is not a frame it routes: the queue goes to the session's
    /// sequence.
    Posted,
    /// It routed frames and more may be read or routed: another turn.
    More,
    /// A frame ended the connection.
    Ended(ConnectionEnd),
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

    /// Routes the frames at the front of the queue on the reactor, while
    /// the session is home (no message before them waits for it or runs),
    /// at most [`MAX_BATCH`] of them.
    fn route_frames(&mut self) -> Routed {
        let mut routed = 0;
        let mut more = false;
        while let Some(session) = self.session.as_mut()
            && session.routes_on_reactor()
            && matches!(self.queue.front(), Some(Inbound::Frame { .. } | Inbound::FrameGate))
        {
            if routed == MAX_BATCH {
                return Routed::More;
            }
            let Some(item) = self.queue.pop_front() else { break };
            self.queued_bytes = self.queued_bytes.saturating_sub(item.weight());
            routed += 1;
            match session.handle_on_reactor(item) {
                Handled::Continue => {}
                Handled::FramesOpen => {
                    self.gate_pending = false;
                    self.input.open_frames();
                    self.cut();
                    more = true;
                }
                Handled::End(end) => return Routed::Ended(end),
            }
        }
        if more { Routed::More } else { Routed::Posted }
    }

    /// Ends the connection as its last task: the teardown waits for the
    /// connection's requests. A refused task drops its session, which ends
    /// the connection on a `work` item.
    fn end(self, end: ConnectionEnd) {
        let Entry { session, sequence, .. } = self;
        let Some(session) = session else { return };
        let _ = sequence.post(move || end_session(session, end, None));
    }
}

struct Reactor {
    poll: Poll,
    commands: mpsc::Receiver<Command>,
    /// Handed to each session task, to come back with.
    link: ReactorLink,
    entries: HashMap<Token, Entry>,
    /// Connections with work for the next turn: readable past their turn's
    /// budget, frames left to route, or a session that came back.
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
                // A panic while this connection is read, cut or routed ends
                // this connection only.
                if catch_unwind(AssertUnwindSafe(|| self.pump(token))).is_err() {
                    eprintln!("cmux-tui: the IO reactor closed a connection after a panic");
                    self.remove(token);
                }
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
                Command::Ended(token) => {
                    self.remove(token);
                }
                Command::Stop => self.stopping = true,
                #[cfg(test)]
                Command::Panic => panic!("the IO reactor panicked"),
            }
        }
    }

    fn adopt(&mut self, adopted: Adopted) {
        let Adopted { session, input } = adopted;
        let Some(fd) = input.socket_fd() else { return };
        let Some(sequence) = session.sequence() else { return };
        let token = Token(self.next_token);
        self.next_token = self.next_token.wrapping_add(1) % WAKE.0;
        let registered =
            self.poll.registry().register(&mut SourceFd(&fd), token, Interest::READABLE);
        if let Err(error) = registered {
            eprintln!("cmux-tui: the IO reactor could not watch a connection: {error}");
            return;
        }
        let entry = Entry {
            input,
            fd,
            carries_frames: session.0.as_ref().is_some_and(|session| session.carries_frames()),
            sequence,
            session: Some(session),
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

    /// Cuts, reads within the turn's budget, routes the front frames, and
    /// posts the next batch.
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
        match entry.route_frames() {
            Routed::Posted => self.dispatch(token),
            Routed::More => self.mark_ready(token),
            Routed::Ended(end) => {
                if let Some(entry) = self.remove(token) {
                    entry.end(end);
                }
            }
        }
    }

    /// Posts the queued messages to the connection's sequence when its
    /// session is home.
    fn dispatch(&mut self, token: Token) {
        let Some(entry) = self.entries.get_mut(&token) else { return };
        if entry.queue.is_empty() {
            return;
        }
        let Some(session) = entry.session.take() else { return };
        if entry.sequence.priority() != session.priority()
            && let Some(sequence) = session.sequence()
        {
            // No task of the connection runs while its session is home, so
            // its order holds across the move.
            entry.sequence = sequence;
        }
        let count = entry.queue.len().min(MAX_BATCH);
        let batch: Vec<Inbound> = entry.queue.drain(..count).collect();
        let weight: usize = batch.iter().map(Inbound::weight).sum();
        entry.queued_bytes = entry.queued_bytes.saturating_sub(weight);
        let link = self.link.clone();
        if entry.sequence.post(move || run_batch(session, batch, &link, token)).is_err() {
            // The pool shut down or could start no worker: the task dropped
            // unrun, and its session ends the connection on a `work` item.
            self.remove(token);
        }
    }

    /// Stops reading `token`'s connection; its entry comes back.
    fn remove(&mut self, token: Token) -> Option<Entry> {
        let mut entry = self.entries.remove(&token)?;
        if entry.registered {
            // The writer holds other descriptors of the same socket, so its
            // epoll registration outlives this one's close unless removed.
            entry.registered = false;
            let _ = self.poll.registry().deregister(&mut SourceFd(&entry.fd));
        }
        entry.input.release();
        self.stats.connections.fetch_sub(1, Ordering::Relaxed);
        Some(entry)
    }
}

/// One session task: handles `batch` in order, then gives the session back
/// to the reactor, or ends the connection.
fn run_batch(mut session: HeldSession, batch: Vec<Inbound>, link: &ReactorLink, token: Token) {
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
            // session ends the connection on a `work` item.
            let _ = link.send(Command::Returned { token, session, frames_opened });
            return;
        }
        Ok(Some(end)) => (end, None),
        Err(panic) => (ConnectionEnd::Dropped, Some(panic)),
    };
    let _ = link.send(Command::Ended(token));
    end_session(session, end, panic);
}

/// Ends the connection on the calling pool worker. The teardown waits for
/// the connection's requests: a blocked task, so the pool starts another
/// worker meanwhile (sequenced_pool.rs). A `panic` goes on after it.
fn end_session(session: HeldSession, end: ConnectionEnd, panic: Option<Box<dyn Any + Send>>) {
    let Some(session) = session.take() else { return };
    crate::request_path::will_block(move || {
        session.finish(end, panic);
    });
}

#[cfg(test)]
#[path = "io_reactor_tests.rs"]
mod tests;

#[cfg(test)]
#[path = "io_reactor_frames_tests.rs"]
mod frames_tests;
