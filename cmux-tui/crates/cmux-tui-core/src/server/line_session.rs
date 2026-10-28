//! A connection's line sequence: the messages its reader
//! cut wait in an inbox and are handled one at a time, in arrival order, by
//! the connection's session on a sequence of the daemon's sequenced pool.
//! The person's connection drains on the pool's input workers, every other
//! on its control workers, so an agent's burst of lines never queues ahead
//! of a key (Chrome runs the browser's UI IPC at a higher priority than
//! background work; base/task/thread_pool/thread_group_impl.cc keeps each
//! priority its own workers). The session's close never waits: it goes on
//! once the connection's request scheduler settled, and the connection is
//! done once both the session and the reader let it go ([`Completion`]).

use std::collections::VecDeque;
use std::sync::{OnceLock, Weak};

use cmux_ipc::{BadMessage, Frame};

use super::super::connection_scheduler::connection_qos::{
    ConnectionClass, ConnectionClassCell, ConnectionThread,
};
use super::super::sequenced_pool::{Sequence, SequencePriority};
use super::super::*;
use super::reading::Reads;
use super::{
    ConnectionBadMessage, ConnectionEnd, EndHook, FrameConnection, FrameLane, INBOX_BYTES,
    INBOX_MESSAGES, Inbound, Opening, TURN_MESSAGES,
};
use crate::diagnostics::{IpcStats, IpcTransport, JsonParseScope, OwnedOpenStream};
use crate::panic_free::RecoverPoison;
use cmux_threads::sync::Mutex;
use cmux_threads::work::{Lane, Priority, Shutdown};

/// A connection's line sequence: the messages its reader cut, and the
/// session that handles them one at a time, in order, on the pool's input
/// workers for the person's connection and its control workers for every
/// other.
pub(in crate::server) struct LineConnection {
    me: Weak<LineConnection>,
    /// The open, the close and every drain until the connection is the
    /// person's.
    sequence: Sequence,
    /// The drains once the connection is the person's.
    input: Sequence,
    /// The connection's class, known once its session opened.
    class: OnceLock<Arc<ConnectionClassCell>>,
    inbox: Mutex<Inbox>,
    /// Taken by the one drain task that exists at a time (`Inbox::scheduled`)
    /// and by the open, so only the open's hand-off can meet a drain
    /// (Chrome's `SequenceBound`).
    session: Mutex<SessionSlot>,
    reads: Reads,
    pub(super) completion: Completion,
}

#[derive(Default)]
struct Inbox {
    messages: VecDeque<Inbound>,
    bytes: usize,
    /// A drain task is posted and has not taken the inbox empty since.
    scheduled: bool,
    /// The reader stopped at the bound and waits for a resume.
    paused: bool,
}

enum SessionSlot {
    Opening(Box<Opening>),
    /// A work item reads the peer's identity; messages wait.
    Identifying,
    Open(Box<LineSession>),
    Ended,
}

impl LineConnection {
    pub(super) fn new(
        mux: &Arc<Mux>,
        opening: Opening,
        reads: Reads,
        completion: Completion,
    ) -> Arc<Self> {
        Arc::new_cyclic(|me| LineConnection {
            me: me.clone(),
            sequence: mux.sequenced_pool.sequence(SequencePriority::Control),
            input: mux.sequenced_pool.sequence(SequencePriority::Input),
            class: OnceLock::new(),
            inbox: Mutex::new(Inbox::default()),
            session: Mutex::new(SessionSlot::Opening(Box::new(opening))),
            reads,
            completion,
        })
    }

    /// Queues `message` for the sequence. False when the inbox is at its
    /// bound: the reader pauses until the sequence drains it. The pause is
    /// taken under the inbox lock, so the drain's resume cannot pass it.
    pub(super) fn deliver(&self, message: Inbound) -> bool {
        let mut inbox = self.inbox.lock().recover_poison();
        inbox.bytes += message.bytes();
        inbox.messages.push_back(message);
        let room = inbox.bytes < INBOX_BYTES && inbox.messages.len() < INBOX_MESSAGES;
        if !room {
            inbox.paused = true;
            self.reads.pause();
        }
        let post = !std::mem::replace(&mut inbox.scheduled, true);
        drop(inbox);
        if post {
            self.post_drain();
        }
        room
    }

    /// [`Self::deliver`] on the person's IO loop (server/mux_io.rs): with no
    /// drain posted or running, the loop handles the message itself, as the
    /// person's reader thread routed its lines. A line's handler only routes
    /// (admission, hello, `handle_connection_frame_at` queues its request on
    /// the connection's request sequence) and never blocks, so the loop does
    /// not wait on it; a drain already queued keeps the order, and what one
    /// turn leaves goes to the input workers.
    pub(super) fn deliver_here(&self, message: Inbound) -> bool {
        let mut inbox = self.inbox.lock().recover_poison();
        inbox.bytes += message.bytes();
        inbox.messages.push_back(message);
        let room = inbox.bytes < INBOX_BYTES && inbox.messages.len() < INBOX_MESSAGES;
        if !room {
            inbox.paused = true;
            self.reads.pause();
        }
        let run = !std::mem::replace(&mut inbox.scheduled, true);
        drop(inbox);
        if run {
            // A handler's panic ends this connection (`EndOnUnwind`), not
            // the loop that serves the person's other connections.
            let drained = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| self.drain()));
            if drained.is_err() {
                eprintln!("cmux-tui: a connection's handler panicked on the person's IO loop");
            }
        }
        room
    }

    /// Runs the sequence even with nothing queued: the session opens.
    pub(super) fn schedule(&self) {
        let post = !std::mem::replace(&mut self.inbox.lock().recover_poison().scheduled, true);
        if post {
            self.post_drain();
        }
    }

    /// Whether the connection is the person's: its socket is served first
    /// and its lines drain on the input workers.
    pub(super) fn is_person(&self) -> bool {
        self.class.get().is_some_and(|class| class.get() == ConnectionClass::Person)
    }

    /// Where the next drain runs. One drain exists at a time, so moving the
    /// person's to the input sequence keeps the messages in order.
    fn drain_sequence(&self) -> &Sequence {
        if self.is_person() { &self.input } else { &self.sequence }
    }

    fn post_drain(&self) {
        let Some(connection) = self.me.upgrade() else { return };
        let posted = self.drain_sequence().post(move || connection.drain());
        if let Err(error) = posted {
            // The pool shut down (the daemon is exiting): nothing will
            // handle this connection's messages.
            eprintln!("cmux-tui: connection closed: its sequence refused work: {error}");
            self.abandon();
        }
    }

    /// One task of the sequence: opens the session first, then handles up
    /// to [`TURN_MESSAGES`] messages and yields to the other sequences.
    fn drain(&self) {
        // Declared before the slot's guard, so it runs after that guard is
        // released when a handler panics.
        let _unwind = EndOnUnwind(self);
        let mut slot = self.session.lock().recover_poison();
        match &*slot {
            SessionSlot::Opening(_) => {
                let SessionSlot::Opening(opening) =
                    std::mem::replace(&mut *slot, SessionSlot::Identifying)
                else {
                    return;
                };
                drop(slot);
                self.identify(opening);
                return self.idle_until_identified();
            }
            SessionSlot::Identifying => return self.idle_until_identified(),
            SessionSlot::Open(_) | SessionSlot::Ended => {}
        }
        for _ in 0..TURN_MESSAGES {
            let Some(message) = self.take_message() else { return };
            let SessionSlot::Open(session) = &mut *slot else {
                message.discard();
                continue;
            };
            if let Some(end) = session.handle(message) {
                let SessionSlot::Open(session) = std::mem::replace(&mut *slot, SessionSlot::Ended)
                else {
                    continue;
                };
                session.close(end, self);
            }
        }
        drop(slot);
        // The turn's share is spent: the next one runs behind the other
        // sequences of the pool.
        self.post_drain();
    }

    /// Messages wait for the session; the identity's arrival drains them.
    fn idle_until_identified(&self) {
        self.inbox.lock().recover_poison().scheduled = false;
    }

    /// Reads the peer's identity on a Files work item (it reads the peer's
    /// process files, which the request path must not wait for), then opens
    /// the session on the sequence.
    fn identify(&self, opening: Box<Opening>) {
        let Some(connection) = self.me.upgrade() else { return };
        let work = opening.mux.work.clone();
        let mut identify = Identify { connection, opening: Some(opening) };
        // A refused item drops `identify`, which abandons the connection.
        let _ = work.post(Priority::UserBlocking, Lane::Files, Shutdown::SkipOnShutdown, {
            move || {
                let Some(opening) = identify.opening.take() else { return };
                let peer = origin_gate::AcceptedPeer::resolve(&opening.mux, &*opening.peer);
                let connection = identify.connection.clone();
                let (task, writer) = (connection.clone(), opening.writer.clone());
                let opened = connection.sequence.post(move || task.opened(*opening, peer));
                if opened.is_err() {
                    writer.close();
                    connection.abandon();
                }
            }
        });
    }

    /// The peer is identified: the session opens and handles what queued.
    fn opened(&self, opening: Opening, peer: origin_gate::AcceptedPeer) {
        let mut slot = self.session.lock().recover_poison();
        if !matches!(*slot, SessionSlot::Identifying) {
            opening.writer.close();
            return;
        }
        *slot = match LineSession::open(opening, peer) {
            Ok(session) => {
                let _ = self.class.set(session.class.clone());
                SessionSlot::Open(Box::new(session))
            }
            Err(end) => {
                self.reads.stop();
                self.completion.session_done(end);
                SessionSlot::Ended
            }
        };
        drop(slot);
        let post = !std::mem::replace(&mut self.inbox.lock().recover_poison().scheduled, true);
        if post {
            self.drain();
        }
    }

    /// The next queued message, resuming a paused reader below half the
    /// bound; `None` clears `scheduled`.
    fn take_message(&self) -> Option<Inbound> {
        let mut inbox = self.inbox.lock().recover_poison();
        let Some(message) = inbox.messages.pop_front() else {
            inbox.scheduled = false;
            return None;
        };
        inbox.bytes = inbox.bytes.saturating_sub(message.bytes());
        let resume = inbox.paused
            && inbox.bytes <= INBOX_BYTES / 2
            && inbox.messages.len() <= INBOX_MESSAGES / 2;
        if resume {
            inbox.paused = false;
        }
        drop(inbox);
        if resume {
            self.reads.resume();
        }
        Some(message)
    }

    /// The connection could not be served: nothing was registered.
    pub(super) fn never_served(&self) {
        *self.session.lock().recover_poison() = SessionSlot::Ended;
        self.completion.session_done(ConnectionEnd::Dropped);
        self.completion.io_released();
    }

    /// The sequence refused work: close what is open without it.
    fn abandon(&self) {
        let slot =
            std::mem::replace(&mut *self.session.lock().recover_poison(), SessionSlot::Ended);
        self.reads.stop();
        match slot {
            SessionSlot::Opening(opening) => {
                opening.writer.close();
                self.completion.session_done(ConnectionEnd::Dropped);
            }
            SessionSlot::Identifying => {
                // The identity's task finds the slot ended and closes the
                // writer; the session never opened.
                self.completion.session_done(ConnectionEnd::Dropped);
            }
            SessionSlot::Open(session) => {
                session.scheduler.close();
                session.finish(ConnectionEnd::Dropped, &self.completion);
            }
            SessionSlot::Ended => {}
        }
        let messages = std::mem::take(&mut self.inbox.lock().recover_poison().messages);
        messages.into_iter().for_each(Inbound::discard);
    }
}

/// Ends the connection when a handler panics on its sequence: the pool's
/// worker survives the panic (server/sequenced_pool.rs), so without it the
/// connection would keep its client and its socket and never drain again,
/// and its client would wait forever. Its teardown takes only locks that
/// recover from poison.
struct EndOnUnwind<'a>(&'a LineConnection);

impl Drop for EndOnUnwind<'_> {
    fn drop(&mut self) {
        if std::thread::panicking() {
            self.0.abandon();
        }
    }
}

/// The peer identity's work item. Dropped unrun (a refused post, a queued
/// item dropped at shutdown), it abandons the connection.
struct Identify {
    connection: Arc<LineConnection>,
    opening: Option<Box<Opening>>,
}

impl Drop for Identify {
    fn drop(&mut self) {
        if let Some(opening) = self.opening.take() {
            opening.writer.close();
            self.connection.abandon();
        }
    }
}

/// A connection's client and the state its lines are handled with.
struct LineSession {
    mux: Arc<Mux>,
    client: u64,
    transport: ClientTransport,
    writer: MessageWriter,
    scheduler: Arc<ConnectionSurfaceScheduler>,
    hello: client_hello::HelloGate,
    class: Arc<ConnectionClassCell>,
    classified_at_hello: bool,
    admission: Box<dyn admission::LineAdmission + Send>,
    frames: Box<dyn FrameLane + Send>,
    /// What the kernel said about the peer at accept; the hello reads it.
    peer_key: Option<String>,
    peer_token: Option<cmux_link::app_caller::PeerToken>,
    carries_frames: bool,
    ipc: Arc<IpcStats>,
    /// The connection's stream 0, open until the connection ends
    /// (`server-stats` `ipc`).
    _stream: OwnedOpenStream,
}

impl LineSession {
    /// Registers the client. An admission that refuses it closes the
    /// connection before its first message.
    fn open(opening: Opening, peer: origin_gate::AcceptedPeer) -> Result<Self, ConnectionEnd> {
        let Opening { mux, writer, permit, transport, admission, frames, carries_frames, .. } =
            opening;
        let client = mux.control_clients.register(transport, writer.clone());
        let ipc = mux.ipc_stats().clone();
        let stream = ipc.stream_opened_owned();
        origin_gate::set_peer_identity_at_accept(&mux, client, &peer);
        if !admission.registered(&mux, client) {
            // Refused before its first frame (the remote entry's revocation
            // limits): nothing is read or dispatched.
            disconnect_client(&mux, client, false);
            return Err(ConnectionEnd::Dropped);
        }
        let class = mux.control_clients.connection_class(client);
        let scheduler = Arc::new(
            ConnectionSurfaceScheduler::new_inner(mux.surface_operation_admission.clone(), permit)
                .classed(class.clone()),
        );
        Ok(LineSession {
            mux,
            client,
            transport,
            writer,
            scheduler,
            hello: client_hello::HelloGate::new(transport),
            class,
            classified_at_hello: false,
            admission,
            frames,
            peer_key: peer.key,
            peer_token: peer.token,
            carries_frames,
            ipc,
            _stream: stream,
        })
    }

    /// Handles one message at the connection's class (a person's lines at
    /// the echo class, automation's at utility, under `daemonRequestQos`);
    /// `Some` ends the connection.
    fn handle(&mut self, message: Inbound) -> Option<ConnectionEnd> {
        match message {
            Inbound::End(end) => Some(end),
            Inbound::Frame { frame, arrived } => {
                let _class = self.enter_class();
                self.frame(frame, arrived)
            }
            Inbound::Line { mut text, arrived } => {
                let keep_open = self.line(&text, arrived);
                zeroize_string(&mut text);
                (!keep_open).then_some(ConnectionEnd::Dropped)
            }
        }
    }

    fn frame(&mut self, frame: Frame, arrived: Instant) -> Option<ConnectionEnd> {
        if !(self.carries_frames && self.frames.granted(&self.mux, self.client)) {
            return Some(ConnectionEnd::BadMessage(ConnectionBadMessage::Wire(
                BadMessage::FramesNotNegotiated,
            )));
        }
        let connection = FrameConnection {
            mux: &self.mux,
            client: self.client,
            transport: self.transport,
            writer: &self.writer,
            scheduler: &self.scheduler,
            arrived,
        };
        match self.frames.route(frame, &connection) {
            Ok(true) => None,
            Ok(false) => Some(ConnectionEnd::Dropped),
            Err(bad) => Some(ConnectionEnd::BadMessage(bad)),
        }
    }

    /// Runs this thread at the connection's reader class until the scope
    /// drops, under `daemonRequestQos`.
    fn enter_class(&self) -> Option<cmux_tui_platform::qos::WorkQos> {
        let qos = self.class.get().qos(ConnectionThread::Reader);
        let request_qos = self.mux.request_qos();
        #[cfg(test)]
        if request_qos.enabled() {
            line_classes::note(&self.mux, self.client, qos);
        }
        request_qos.enter_class(qos)
    }

    /// One line through admission, the hello gate and dispatch; false
    /// closes the connection.
    fn line(&mut self, line: &str, arrived: Instant) -> bool {
        if line.trim().is_empty() {
            return true;
        }
        let _class = self.enter_class();
        // Every line from here is one request of `server-stats` `ipc`: the
        // parses of its admission, hello gate and route all count toward it.
        let _parses = JsonParseScope::enter(&self.ipc, IpcTransport::Lines);
        if let Some(refusal) = self.admission.refusal(line) {
            // A refused line still counts as a line: the window closes.
            self.hello.close();
            return self.writer.send_control(&refusal).is_ok();
        }
        let peer = || client_hello::Peer { key: self.peer_key.clone(), token: self.peer_token };
        if let Some(reply) = self.hello.observe(&self.mux, self.client, line, peer) {
            return self.writer.send_control(&reply).is_ok();
        }
        if self.hello.is_closed() && !self.classified_at_hello {
            // No later line can change its origin (connection_qos.rs).
            self.classified_at_hello = true;
            self.mux.control_clients.classify_connection(self.client);
        }
        // The line runs at the class it was just given, if any.
        let _classed = self.enter_class();
        handle_connection_frame_at(
            &self.mux,
            self.client,
            self.transport,
            line,
            &self.writer,
            &self.scheduler,
            arrived,
        )
    }

    /// The connection ended: no message is read from here. Its queued
    /// requests drain (the peer closed) or are cancelled, and once the
    /// scheduler settled the sequence finishes the close.
    fn close(self: Box<Self>, end: ConnectionEnd, connection: &LineConnection) {
        connection.reads.stop();
        if let ConnectionEnd::BadMessage(bad) = &end {
            // Nothing answers the sender of a bad message from here: what is
            // queued is written, then the socket closes (Chrome's
            // `ReportBadMessage` closes the pipe). A request cancelled by
            // this close sends no "request cancelled" after it.
            self.writer.close();
            self.ipc.bad_message();
            eprintln!(
                "cmux-tui: client {} closed: bad_message {}: {bad}",
                self.client,
                bad.reason()
            );
        }
        let scheduler = self.scheduler.clone();
        let graceful = end == ConnectionEnd::PeerClosed;
        if graceful {
            scheduler.finish();
        } else {
            scheduler.close();
        }
        let Some(me) = connection.me.upgrade() else { return };
        let closing = Arc::new(Closing { session: Mutex::new(Some((self, end))), connection: me });
        if !graceful {
            // A closed connection's running request gets this long to end.
            let deadline = closing.clone();
            let posted = connection
                .sequence
                .post_delayed(CONNECTION_SURFACE_SHUTDOWN_TIMEOUT, move || deadline.finish());
            if posted.is_err() {
                closing.finish();
            }
        }
        scheduler.when_settled(Box::new(move || closing.post_finish()));
    }

    /// Ends the client: its views detach and its writer closes; the mux-io
    /// loop then writes what is queued and closes the socket.
    fn finish(self: Box<Self>, end: ConnectionEnd, completion: &Completion) {
        disconnect_client(&self.mux, self.client, false);
        drop(self);
        completion.session_done(end);
    }
}

/// A closing session, finished once: when its scheduler settled or its
/// deadline passed, whichever comes first.
struct Closing {
    session: Mutex<Option<(Box<LineSession>, ConnectionEnd)>>,
    connection: Arc<LineConnection>,
}

impl Closing {
    /// Finishes on the connection's sequence (the settle may come on any
    /// worker).
    fn post_finish(self: Arc<Self>) {
        let sequence = &self.connection.sequence;
        let task = self.clone();
        if sequence.post(move || task.finish()).is_err() {
            self.finish();
        }
    }

    fn finish(&self) {
        let Some((session, end)) = self.session.lock().recover_poison().take() else { return };
        session.finish(end, &self.connection.completion);
    }
}

/// A connection is done when its session finished and its socket left the
/// reader: then its permit is released and its end reported.
pub(super) struct Completion {
    state: Mutex<CompletionState>,
}

struct CompletionState {
    io_released: bool,
    end: Option<ConnectionEnd>,
    permit: Option<ConnectionPermit>,
    on_end: Option<EndHook>,
}

impl Completion {
    pub(super) fn new(permit: Option<ConnectionPermit>, on_end: Option<EndHook>) -> Self {
        Self {
            state: Mutex::new(CompletionState { io_released: false, end: None, permit, on_end }),
        }
    }

    /// Setup failed before the connection was served.
    pub(super) fn fail(self) {
        self.session_done(ConnectionEnd::Dropped);
        self.io_released();
    }

    pub(super) fn session_done(&self, end: ConnectionEnd) {
        let mut state = self.state.lock().recover_poison();
        state.end.get_or_insert(end);
        self.settle(state);
    }

    pub(super) fn io_released(&self) {
        let mut state = self.state.lock().recover_poison();
        state.io_released = true;
        self.settle(state);
    }

    fn settle(&self, mut state: std::sync::MutexGuard<'_, CompletionState>) {
        let Some(end) = state.end.filter(|_| state.io_released) else { return };
        let permit = state.permit.take();
        let on_end = state.on_end.take();
        drop(state);
        drop(permit);
        if let Some(on_end) = on_end {
            on_end(end);
        }
    }
}

/// The reader class each line entered and the pool worker it ran on, by
/// mux session and client, so a test sees the class a line ran at on the
/// worker that ran it (also where the platform refuses the change: Linux
/// without `RLIMIT_NICE`).
#[cfg(test)]
pub(in crate::server) mod line_classes {
    use std::collections::HashMap;
    use std::sync::{Mutex, OnceLock};

    use cmux_threads::ThreadQos;

    use crate::Mux;

    type Key = (String, u64);
    /// Each line's class and the name of the thread it ran on.
    type Entered = Mutex<HashMap<Key, Vec<(ThreadQos, String)>>>;

    fn entered() -> &'static Entered {
        static ENTERED: OnceLock<Entered> = OnceLock::new();
        ENTERED.get_or_init(Mutex::default)
    }

    pub(super) fn note(mux: &Mux, client: u64, qos: ThreadQos) {
        let thread = std::thread::current().name().unwrap_or_default().to_owned();
        let mut entered = entered().lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        entered.entry((mux.session.clone(), client)).or_default().push((qos, thread));
    }

    /// The classes `client` of `mux` entered since the last call, in order,
    /// each with the name of the thread it ran on.
    pub(in crate::server) fn take(mux: &Mux, client: u64) -> Vec<(ThreadQos, String)> {
        let mut entered = entered().lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        entered.remove(&(mux.session.clone(), client)).unwrap_or_default()
    }
}
