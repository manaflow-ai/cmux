//! The connection loop shared by the local socket and the remote entry.
//!
//! A [`FrameReader`] (cmux-ipc) cuts the bytes into JSON lines, exactly as
//! `read_line` did, and into binary frames (plans/cmux-next/chrome-parity/
//! p05-ipc.md, section 3.2). Every line is seen by the connection's
//! admission before anything parses or dispatches it. A frame skips that, so
//! it passes only on a local Unix connection whose admission admits frames
//! and whose client holds the [`IPC_FRAMES_CAPABILITY`] grant when the frame
//! arrives; any other frame is a bad message.
//!
//! A local socket is read with one `recvmsg` per read, bytes and descriptors
//! together, straight into the reader's buffer, as Mojo's
//! `ChannelPosix::OnFileCanReadWithoutBlocking` reads into the buffer
//! `Channel::GetReadBuffer` lends it (chromium mojo/core/channel_posix.cc).
//! No frame kind carries descriptors yet, so a descriptor that arrives is a
//! bad message: it is refused where the kernel would otherwise drop it unseen.
//!
//! A bad message closes the connection, as Chrome's `ReportBadMessage`
//! (mojo/public/cpp/bindings/message.h) ends the sender: nothing after the
//! bad byte is interpreted.
//!
//! REQUEST and CANCEL frames go to [`frame_dispatch`] (p05-ipc-071), and so
//! do INPUT frames, which queue on the stream they name until its opener is
//! answered ([`pending_streams`], p05-ipc-087).
//!
//! The reading and the serving are split, as Mojo's channel reads on the IO
//! thread and dispatches each message on the sequence its endpoint is bound
//! to (chromium mojo/core/channel_posix.cc, ipc/ipc_mojo_bootstrap.cc): a
//! [`ConnectionInput`] cuts owned [`Inbound`] messages and a [`LineSession`]
//! handles them in order. A local socket is read by the daemon's one IO
//! reactor and served as tasks on the sequenced pool (io_reactor.rs,
//! p05-ipc-155); the remote entry and a stream with no socket of its own are
//! read on a thread of their own ([`serve_connection`]).

use std::fmt;

use cmux_ipc::{BadMessage, Frame, FrameKind, FrameReader, Message, ReaderLimits};

use crate::diagnostics::{IpcTransport, JsonParseScope};

use cmux_tui_platform::qos::WorkQos;

use super::connection_scheduler::connection_qos::{
    ConnectionClassCell, ReaderClass, TaskReaderClass,
};
use super::*;

/// The grant that lets a connection send frames. p05-ipc-060 decides who
/// gets it (a local Unix peer at this daemon's api_revision); this loop only
/// reads it from the client's record.
pub(super) const IPC_FRAMES_CAPABILITY: &str = "ipc-frames-v2";

/// A JSON line's payload may be `MAX_JSON_LINE_BYTES` long, its `\n`
/// excluded, as with `read_line`; frames keep the wire's 32 MiB bound.
fn line_limits() -> ReaderLimits {
    ReaderLimits { max_line: MAX_JSON_LINE_BYTES, ..ReaderLimits::default() }
}

pub(super) fn handle_connection_with_permit(
    mux: Arc<Mux>,
    stream: Box<dyn transport::Stream>,
    peer: origin_gate::AcceptedPeer,
    render_service: Arc<RenderService>,
    connection_permit: Option<ConnectionPermit>,
) {
    serve_line_connection(
        mux,
        stream,
        peer,
        render_service,
        connection_permit,
        ClientTransport::Unix,
        &admission::LocalAdmission,
    );
}

/// The class of a connection's reader thread (mux-conn, mux-remote-conn)
/// until its client class is known: it serves the app and automation alike.
/// Once classified it rests at the class's (connection_qos.rs, task 224).
pub(super) const CONNECTION_READER_QOS: cmux_threads::ThreadQos =
    crate::thread_qos::ThreadType::UnclassifiedClient.qos();

/// Starts connection reader thread `name` at [`CONNECTION_READER_QOS`]. It
/// runs `setup` first, which may block: the connection's own setup before
/// its first message (the peer's identity, [`origin_gate::AcceptedPeer`]),
/// as a terminal-host reader registers its descriptor before it serves
/// (`echo_thread::spawn_host_stream_reader`). Then it disallows blocking and
/// serves with `setup`'s value (each blocking request site is recorded, and
/// a panic in Debug, MQ-13).
pub(super) fn spawn_connection_reader<S: 'static>(
    name: &str,
    setup: impl FnOnce() -> S + Send + 'static,
    serve: impl FnOnce(S) + Send + 'static,
) -> std::io::Result<JoinHandle<()>> {
    cmux_threads::spawn(name, CONNECTION_READER_QOS, move || {
        let accepted = setup();
        // Each frame it reads is one hang-watch scope (connection_frame.rs);
        // the read itself is outside every scope.
        let thread = std::thread::current();
        let _hang_watch = cmux_hang_watch::register_thread(
            cmux_hang_watch::ThreadKind::Io,
            thread.name().unwrap_or("mux-conn"),
        );
        cmux_threads::disallow_blocking();
        serve(accepted);
    })
}

/// One JSON line per message, and frames once granted. `admission` sees
/// every line before anything parses or dispatches it, and may answer it
/// instead (the remote entry).
pub(super) fn serve_line_connection(
    mux: Arc<Mux>,
    stream: Box<dyn transport::Stream>,
    peer: origin_gate::AcceptedPeer,
    render_service: Arc<RenderService>,
    connection_permit: Option<ConnectionPermit>,
    transport: ClientTransport,
    admission: &dyn admission::LineAdmission,
) {
    let _ = serve_connection(
        mux,
        stream,
        peer,
        render_service,
        connection_permit,
        transport,
        admission,
        &mut frame_dispatch::RequestFrames::default(),
    );
}

/// What a connection does with frames: whether it may send them yet, and
/// where each one goes.
pub(super) trait FrameLane {
    /// Whether `client` holds the frames grant now. Asked again for every
    /// frame, before it is cut: a later `set-client-info` or `client-hello`
    /// can end the grant (p05-ipc-060), and frame payloads are not
    /// revision-translated. Never asked on a connection that cannot carry
    /// frames (not a local Unix socket, or an admission that sees only lines).
    fn granted(&self, mux: &Mux, client: u64) -> bool;

    /// Takes one frame. `Ok(false)` closes the connection as a line's
    /// handler does; an error closes it as a bad message.
    fn route(
        &mut self,
        frame: Frame,
        connection: &FrameConnection<'_>,
    ) -> Result<bool, ConnectionBadMessage>;
}

/// The connection a frame arrived on: what a line's dispatch gets.
pub(super) struct FrameConnection<'a> {
    pub(super) mux: &'a Arc<Mux>,
    pub(super) client: u64,
    pub(super) transport: ClientTransport,
    pub(super) writer: &'a MessageWriter,
    pub(super) scheduler: &'a Arc<ConnectionSurfaceScheduler>,
    /// When the reader cut the frame, for its request span.
    pub(super) arrived: Instant,
}

/// Why a connection was closed as a bad message.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) enum ConnectionBadMessage {
    /// The bytes broke the wire's rules (cmux-ipc reader).
    Wire(BadMessage),
    /// A valid frame of a kind this daemon does not route.
    UnroutedKind { kind: FrameKind },
    /// A stream frame (INPUT) naming a stream this connection never
    /// announced (server/pending_streams.rs).
    UnknownStream { kind: FrameKind, stream: u16 },
    /// A REQUEST or CANCEL frame that its method or the requests in flight
    /// refuse.
    Call(frame_dispatch::CallRefusal),
    /// A descriptor arrived; no frame kind carries one yet.
    UnexpectedFds,
}

impl ConnectionBadMessage {
    /// The `bad_message` reason, stable for logs and counters.
    pub(super) fn reason(&self) -> &'static str {
        match self {
            ConnectionBadMessage::Wire(bad) => bad.reason(),
            ConnectionBadMessage::UnroutedKind { .. } => "unrouted_kind",
            ConnectionBadMessage::UnknownStream { .. } => "unknown_stream",
            ConnectionBadMessage::Call(refusal) => refusal.reason(),
            ConnectionBadMessage::UnexpectedFds => "unexpected_fds",
        }
    }
}

impl fmt::Display for ConnectionBadMessage {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            ConnectionBadMessage::Wire(bad) => write!(f, "{bad}"),
            ConnectionBadMessage::UnroutedKind { kind } => {
                write!(f, "no route for {} frames", kind.name())
            }
            ConnectionBadMessage::UnknownStream { kind, stream } => {
                write!(f, "{} frame on never-announced stream {stream}", kind.name())
            }
            ConnectionBadMessage::Call(refusal) => write!(f, "{refusal}"),
            ConnectionBadMessage::UnexpectedFds => write!(f, "a file descriptor arrived"),
        }
    }
}

/// How a connection ended.
#[derive(Debug, PartialEq, Eq)]
pub(super) enum ConnectionEnd {
    /// The peer closed after whole messages: accepted work drains.
    PeerClosed,
    /// A read failed, setup failed, admission refused, or a handler closed
    /// the connection.
    Dropped,
    /// The peer sent a bad message.
    BadMessage(ConnectionBadMessage),
}

/// Serves one connection on the calling thread until it ends: the thread
/// driver of [`LineSession`] (the remote entry, a local connection when no
/// IO reactor runs or its stream is not one socket, and tests). A local
/// socket the IO reactor serves goes through the same session
/// (server/io_reactor.rs).
pub(super) fn serve_connection(
    mux: Arc<Mux>,
    stream: Box<dyn transport::Stream>,
    peer: origin_gate::AcceptedPeer,
    render_service: Arc<RenderService>,
    connection_permit: Option<ConnectionPermit>,
    transport: ClientTransport,
    admission: &dyn admission::LineAdmission,
    frames: &mut dyn FrameLane,
) -> ConnectionEnd {
    let opened = LineSession::open(
        SessionParts { mux, render_service, connection_permit, transport },
        &*stream,
        peer,
        admission,
        frames,
        ReaderClass::new,
    );
    let mut session = match opened {
        Ok(session) => session,
        Err(end) => return end,
    };
    let carries_frames = session.carries_frames();
    let mut input = ConnectionInput::new(stream);
    // A panic while serving (a handler's, or a blocking call's in the
    // detector's panic mode) still ends the connection below, then goes on
    // as the thread's panic. Before, the teardown never ran: the client
    // stayed registered with its socket open and waited forever.
    let served = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        loop {
            let item = match input.cut(carries_frames) {
                Some(item) => item,
                None => match input.fill() {
                    Ok(()) => continue,
                    Err(end) => break end,
                },
            };
            match session.handle(item) {
                Handled::Continue => {}
                Handled::FramesOpen => input.open_frames(),
                Handled::End(end) => break end,
            }
        }
    }));
    input.release();
    match served {
        Ok(end) => session.finish(end, None),
        Err(panic) => session.finish(ConnectionEnd::Dropped, Some(panic)),
    }
}

impl<T: admission::LineAdmission + ?Sized> admission::LineAdmission for &T {
    fn registered(&self, mux: &Arc<Mux>, client: u64) -> bool {
        (**self).registered(mux, client)
    }

    fn refusal(&self, line: &str) -> Option<Value> {
        (**self).refusal(line)
    }

    fn admits_frames(&self) -> bool {
        (**self).admits_frames()
    }
}

impl<T: FrameLane + ?Sized> FrameLane for &mut T {
    fn granted(&self, mux: &Mux, client: u64) -> bool {
        (**self).granted(mux, client)
    }

    fn route(
        &mut self,
        frame: Frame,
        connection: &FrameConnection<'_>,
    ) -> Result<bool, ConnectionBadMessage> {
        (**self).route(frame, connection)
    }
}

/// How a connection's lines follow its client class (task 224).
pub(super) trait ReaderFollow {
    /// Before routing a line: classifies the connection once its hello
    /// window closed, and returns the class scope the line runs in, if the
    /// thread does not already rest at it.
    fn before_line(&mut self, mux: &Mux, client: u64, hello_closed: bool) -> Option<WorkQos>;

    /// The class scope a frame routes in.
    fn before_frame(&mut self) -> Option<WorkQos> {
        None
    }
}

/// A reader thread of its own rests at its connection's class.
impl ReaderFollow for ReaderClass {
    fn before_line(&mut self, mux: &Mux, client: u64, hello_closed: bool) -> Option<WorkQos> {
        ReaderClass::before_line(self, mux, client, hello_closed);
        None
    }
}

/// A connection the IO reactor reads runs its lines and frames as tasks on
/// shared workers: each one enters the class for its own run.
impl ReaderFollow for TaskReaderClass {
    fn before_line(&mut self, mux: &Mux, client: u64, hello_closed: bool) -> Option<WorkQos> {
        self.enter(mux, client, hello_closed)
    }

    fn before_frame(&mut self) -> Option<WorkQos> {
        self.rest()
    }
}

/// One message cut from a connection, owned, in arrival order: what the
/// reader (a thread of its own or the IO reactor) hands its session.
pub(super) enum Inbound {
    /// A JSON line with its `\n` as `read_line` gave it (only a last line
    /// cut at end of stream has none). Zeroed when it drops.
    Line(InboundLine),
    Frame {
        frame: Frame,
        arrived: Instant,
    },
    /// The next message is a frame and this connection never sent one: the
    /// session decides, after every earlier message, whether it may. The
    /// reader cuts nothing more until the session answers.
    FrameGate,
    /// The bytes broke the wire's rules; `frame` when the bad message
    /// started with the frame byte.
    Bad {
        bad: BadMessage,
        frame: bool,
    },
    End(ConnectionEnd),
}

impl Inbound {
    /// The bytes it holds, against the reader's read-ahead bound.
    #[cfg(unix)]
    pub(super) fn weight(&self) -> usize {
        match self {
            Inbound::Line(line) => line.text.len(),
            Inbound::Frame { frame, .. } => frame.header().frame_len(),
            Inbound::FrameGate | Inbound::Bad { .. } | Inbound::End(_) => 0,
        }
    }

    /// Whether the reader cuts nothing after it.
    #[cfg(unix)]
    pub(super) fn is_last(&self) -> bool {
        matches!(self, Inbound::FrameGate | Inbound::Bad { .. } | Inbound::End(_))
    }
}

/// A line's text (lines can carry credentials) and when it was cut.
pub(super) struct InboundLine {
    text: String,
    arrived: Instant,
}

impl Drop for InboundLine {
    fn drop(&mut self) {
        zeroize_string(&mut self.text);
    }
}

/// What the session did with one message.
#[derive(Debug, PartialEq, Eq)]
pub(super) enum Handled {
    Continue,
    /// A [`Inbound::FrameGate`] passed: the reader may cut frames.
    FramesOpen,
    End(ConnectionEnd),
}

/// What a session is opened with, beside its stream and peer.
pub(super) struct SessionParts {
    pub(super) mux: Arc<Mux>,
    pub(super) render_service: Arc<RenderService>,
    pub(super) connection_permit: Option<ConnectionPermit>,
    pub(super) transport: ClientTransport,
}

/// One connection's served state: its client, writer, hello gate, class,
/// admission and frame lane. It handles the messages its reader cuts, in
/// order, one at a time, on whichever thread holds it. Dropped without
/// [`LineSession::finish`] (a task the pool refused) it ends the connection
/// without waiting for its requests.
pub(super) struct LineSession<A, F, R> {
    mux: Arc<Mux>,
    client: u64,
    transport: ClientTransport,
    writer: MessageWriter,
    scheduler: Arc<ConnectionSurfaceScheduler>,
    hello: client_hello::HelloGate,
    follow: R,
    admission: A,
    frames: F,
    ipc: Arc<crate::diagnostics::IpcStats>,
    /// The connection's stream 0, open until the connection ends
    /// (`server-stats` `ipc`).
    _stream: crate::diagnostics::OwnedOpenStream,
    /// A clone of the socket: the peer's identity for the hello gate.
    peer: Box<dyn transport::Stream>,
    /// Dropped, not joined: the writer holds the connection's slot until it
    /// has written its last item, and a join is a wait for another thread,
    /// which a reader that disallows blocking may not make.
    _writer_thread: JoinHandle<()>,
    _permit: Option<ConnectionPermit>,
    finished: bool,
}

impl<A, F, R> LineSession<A, F, R>
where
    A: admission::LineAdmission,
    F: FrameLane,
    R: ReaderFollow,
{
    /// Registers the connection's client and starts its writer. `follow`
    /// makes the class follower (on the thread that will hold it).
    pub(super) fn open(
        parts: SessionParts,
        stream: &dyn transport::Stream,
        peer: origin_gate::AcceptedPeer,
        admission: A,
        frames: F,
        follow: impl FnOnce(Arc<ConnectionClassCell>, crate::request_qos::RequestQos) -> R,
    ) -> Result<Self, ConnectionEnd> {
        let SessionParts { mux, render_service, connection_permit, transport } = parts;
        let Ok(mut write_half) = stream.try_clone_box() else { return Err(ConnectionEnd::Dropped) };
        let Ok(control) = write_half.try_clone_box() else { return Err(ConnectionEnd::Dropped) };
        let Ok(writer_socket) = write_half.try_clone_box() else {
            return Err(ConnectionEnd::Dropped);
        };
        let Ok(peer_stream) = write_half.try_clone_box() else {
            return Err(ConnectionEnd::Dropped);
        };
        if write_half.set_write_timeout(Some(STREAM_WRITE_TIMEOUT)).is_err() {
            return Err(ConnectionEnd::Dropped);
        }
        let outbound = Arc::new(BoundedOutbound::with_chunk_bytes(mux.bulk_frame_max()));
        let writer = MessageWriter::new_with_render_service(
            QueuedSink { outbound: outbound.clone(), control: Some(SinkControl::Unix(control)) },
            render_service,
        );
        let writer_outbound = outbound;
        let writer_close = writer.clone();
        let writer_ipc = mux.ipc_stats().clone();
        let writer_hangs = mux.echo_watch();
        let writer_permit = connection_permit.clone();
        let Ok(writer_thread) = crate::echo_thread::spawn("mux-line-out", move || {
            let _permit = writer_permit;
            // Ends the connection however the writer ends, a panic included: a
            // dead writer with an open socket left its client waiting forever.
            let _end = WriterEnd { writer: writer_close, socket: writer_socket };
            let _hang_watch =
                cmux_hang_watch::register_thread(cmux_hang_watch::ThreadKind::Io, "mux-line-out");
            // Every ready item up to 256 KiB leaves in one writev (p05-ipc-088).
            let mut batch = Vec::new();
            // mq14-allow: the writer's idle wait for its own queue (BoundedOutbound::recv_batch).
            while writer_outbound.recv_batch(&mut batch) {
                // Each batch's write is a 100 ms hang scope; the wait above is not.
                let _batch = writer_hangs.item(WatchKind::LineOut);
                // One scope per write, as long as the socket's write timeout:
                // the queue wait above is outside it.
                let write = cmux_hang_watch::watch(STREAM_WRITE_TIMEOUT);
                let written = write_counted_batch(&mut *write_half, &writer_ipc, &batch);
                drop(write);
                // The written texts go now, not when the next item arrives.
                batch.clear();
                if written.is_err() {
                    writer_outbound.close();
                    break;
                }
            }
        }) else {
            writer.close();
            return Err(ConnectionEnd::Dropped);
        };
        let client = mux.control_clients.register(transport, writer.clone());
        let ipc = mux.ipc_stats().clone();
        let stream_open = ipc.stream_opened_owned();
        origin_gate::set_peer_identity_at_accept(&mux, client, peer);
        if !admission.registered(&mux, client) {
            // Refused before its first frame (the remote entry's revocation
            // limits): nothing is read or dispatched. The writer ends on its
            // own once the disconnect closes its queue.
            disconnect_client(&mux, client, false);
            return Err(ConnectionEnd::Dropped);
        }
        let hello = client_hello::HelloGate::new(transport);
        let class = mux.control_clients.connection_class(client);
        let follow = follow(class.clone(), mux.request_qos());
        let scheduler = Arc::new(
            ConnectionSurfaceScheduler::new_inner(
                mux.surface_operation_admission.clone(),
                connection_permit.clone(),
            )
            .classed(class),
        );
        Ok(LineSession {
            mux,
            client,
            transport,
            writer,
            scheduler,
            hello,
            follow,
            admission,
            frames,
            ipc,
            _stream: stream_open,
            peer: peer_stream,
            _writer_thread: writer_thread,
            _permit: connection_permit,
            finished: false,
        })
    }

    /// Whether frames may ever arrive here: only on a local Unix connection
    /// whose admission takes them.
    pub(super) fn carries_frames(&self) -> bool {
        matches!(self.transport, ClientTransport::Unix) && self.admission.admits_frames()
    }

    /// Handles one message. Every line is seen by the admission before
    /// anything parses or dispatches it; a frame passes only while the
    /// client holds the frames grant, asked again for every frame: a later
    /// `set-client-info` or `client-hello` can end it (p05-ipc-060).
    pub(super) fn handle(&mut self, item: Inbound) -> Handled {
        match item {
            Inbound::Line(line) => self.handle_line(line),
            Inbound::FrameGate if self.frames_granted() => Handled::FramesOpen,
            Inbound::FrameGate => not_negotiated(),
            Inbound::Frame { .. } if !self.frames_granted() => not_negotiated(),
            Inbound::Frame { frame, arrived } => {
                self.ipc.frame_received(frame.header().kind(), frame.header().frame_len());
                let _class = self.follow.before_frame();
                let connection = FrameConnection {
                    mux: &self.mux,
                    client: self.client,
                    transport: self.transport,
                    writer: &self.writer,
                    scheduler: &self.scheduler,
                    arrived,
                };
                match self.frames.route(frame, &connection) {
                    Ok(true) => Handled::Continue,
                    Ok(false) => Handled::End(ConnectionEnd::Dropped),
                    Err(bad) => Handled::End(ConnectionEnd::BadMessage(bad)),
                }
            }
            Inbound::Bad { frame: true, .. } if !self.frames_granted() => not_negotiated(),
            Inbound::Bad { bad, .. } => {
                Handled::End(ConnectionEnd::BadMessage(ConnectionBadMessage::Wire(bad)))
            }
            Inbound::End(end) => Handled::End(end),
        }
    }

    fn frames_granted(&self) -> bool {
        self.carries_frames() && self.frames.granted(&self.mux, self.client)
    }

    fn handle_line(&mut self, line: InboundLine) -> Handled {
        self.ipc.line_received(line.text.len());
        if line.text.trim().is_empty() {
            return Handled::Continue;
        }
        // Every line from here is one request of `server-stats` `ipc`: the
        // parses of its admission, hello gate and route all count toward it.
        let parses = JsonParseScope::enter(&self.ipc, IpcTransport::Lines);
        let keep_open = match self.admission.refusal(&line.text) {
            Some(refusal) => {
                // A refused line still counts as a line: the window closes.
                self.hello.close();
                self.writer.send_control(&refusal).is_ok()
            }
            None => {
                let stream = &self.peer;
                let peer = || client_hello::Peer {
                    key: stream.peer_process_key(),
                    token: stream.peer_token(),
                };
                match self.hello.observe(&self.mux, self.client, &line.text, peer) {
                    Some(reply) => self.writer.send_control(&reply).is_ok(),
                    None => {
                        let _class =
                            self.follow.before_line(&self.mux, self.client, self.hello.is_closed());
                        handle_connection_frame_at(
                            &self.mux,
                            self.client,
                            self.transport,
                            &line.text,
                            &self.writer,
                            &self.scheduler,
                            line.arrived,
                        )
                    }
                }
            }
        };
        drop(parses);
        if keep_open { Handled::Continue } else { Handled::End(ConnectionEnd::Dropped) }
    }

    /// Ends the connection: a peer that closed after whole messages gets its
    /// accepted work drained, any other end closes it with a bounded wait.
    /// Then the client is disconnected, which closes the writer's queue: the
    /// writer writes what is left, shuts the socket down and releases its
    /// hold on the slot. A `panic` goes on after the teardown.
    pub(super) fn finish(
        mut self,
        end: ConnectionEnd,
        panic: Option<Box<dyn std::any::Any + Send>>,
    ) -> ConnectionEnd {
        self.finished = true;
        if panic.is_some() {
            // Close the queue first: the writer ends and shuts the socket
            // down even if the disconnect below finds a poisoned lock.
            self.writer.close();
        }
        if let ConnectionEnd::BadMessage(bad) = &end {
            self.ipc.bad_message();
            let client = self.client;
            eprintln!("cmux-tui: client {client} closed: bad_message {}: {bad}", bad.reason());
        }
        if end == ConnectionEnd::PeerClosed {
            self.scheduler.finish_and_wait();
        } else {
            let _ = self.scheduler.close_and_wait(CONNECTION_SURFACE_SHUTDOWN_TIMEOUT);
        }
        disconnect_client(&self.mux, self.client, false);
        drop(self);
        if let Some(panic) = panic {
            std::panic::resume_unwind(panic);
        }
        end
    }
}

/// A frame this connection may not send now.
fn not_negotiated() -> Handled {
    Handled::End(ConnectionEnd::BadMessage(ConnectionBadMessage::Wire(
        BadMessage::FramesNotNegotiated,
    )))
}

impl<A, F, R> Drop for LineSession<A, F, R> {
    fn drop(&mut self) {
        if self.finished {
            return;
        }
        self.writer.close();
        let _ = self.scheduler.close_and_wait(Duration::ZERO);
        disconnect_client(&self.mux, self.client, false);
    }
}

/// The end of a connection's writer, however the writer ends: its queue
/// closes and its socket shuts down, so the client reads the end of the
/// stream and the reader's next read fails. It takes only locks that
/// recover from poison, so it runs while the writer unwinds too.
struct WriterEnd {
    writer: MessageWriter,
    socket: Box<dyn transport::Stream>,
}

impl Drop for WriterEnd {
    fn drop(&mut self) {
        self.writer.close();
        let _ = self.socket.shutdown(Shutdown::Both);
    }
}

/// The read side of one connection: the socket, the reader that cuts its
/// bytes, and on a local socket the descriptor FIFO `recvmsg` fills.
pub(super) struct ConnectionInput {
    stream: Box<dyn transport::Stream>,
    messages: FrameReader,
    #[cfg(unix)]
    fds: cmux_ipc::fds::FdReceiver,
    /// The session passed a [`Inbound::FrameGate`]: frames are cut.
    frames_open: bool,
    /// The peer closed its side.
    ended: bool,
}

impl ConnectionInput {
    pub(super) fn new(stream: Box<dyn transport::Stream>) -> Self {
        ConnectionInput {
            stream,
            messages: FrameReader::new(line_limits()),
            #[cfg(unix)]
            fds: cmux_ipc::fds::FdReceiver::default(),
            frames_open: false,
            ended: false,
        }
    }

    /// The next message the bytes read so far hold, `None` when more bytes
    /// are needed. Before the session opened frames, a frame byte is a
    /// [`Inbound::FrameGate`] (or, where frames never pass, a bad message),
    /// so nothing of a frame is cut before the session allowed it. After an
    /// [`Inbound::FrameGate`], a bad message or an end it must not be called
    /// again until the session answered.
    pub(super) fn cut(&mut self, carries_frames: bool) -> Option<Inbound> {
        let frame = self.messages.next_is_frame();
        if frame && !self.frames_open {
            if carries_frames {
                return Some(Inbound::FrameGate);
            }
            return Some(Inbound::End(ConnectionEnd::BadMessage(ConnectionBadMessage::Wire(
                BadMessage::FramesNotNegotiated,
            ))));
        }
        let buffered = self.messages.buffered_len();
        match self.messages.next_message() {
            Ok(Some(Message::Json(line))) => {
                // Dispatch sees the line with its `\n`, as `read_line` gave
                // it: serde's error positions in `bad request` replies name
                // it. Only a last line cut at end of stream has none.
                let mut text = String::with_capacity(line.len() + 1);
                text.push_str(line);
                if line.len() < buffered {
                    text.push('\n');
                }
                Some(Inbound::Line(InboundLine { text, arrived: Instant::now() }))
            }
            Ok(Some(Message::Frame(frame))) => {
                Some(Inbound::Frame { frame, arrived: Instant::now() })
            }
            Ok(None) if self.ended => Some(Inbound::End(ConnectionEnd::PeerClosed)),
            Ok(None) => None,
            Err(bad) => Some(Inbound::Bad { bad, frame }),
        }
    }

    /// The session passed the frame gate: frames are cut from now on.
    pub(super) fn open_frames(&mut self) {
        self.frames_open = true;
        self.messages.negotiate_frames();
    }

    /// One read into the reader, waiting for bytes; at end of stream marks
    /// it ended.
    fn fill(&mut self) -> Result<(), ConnectionEnd> {
        let read = loop {
            match self.read() {
                Err(error) if error.kind() == std::io::ErrorKind::Interrupted => {}
                result => break result,
            }
        };
        self.after_read(read)
    }

    /// One read into the reader that never waits (the IO reactor's):
    /// `Ok(false)` when the socket has nothing to read now.
    #[cfg(unix)]
    pub(super) fn fill_ready(&mut self) -> Result<bool, ConnectionEnd> {
        let read = loop {
            match self.read_ready() {
                Err(error) if error.kind() == std::io::ErrorKind::Interrupted => {}
                result => break result,
            }
        };
        match read {
            Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => Ok(false),
            read => self.after_read(read).map(|()| true),
        }
    }

    fn after_read(&mut self, read: std::io::Result<usize>) -> Result<(), ConnectionEnd> {
        match read {
            Ok(_) if self.descriptors_queued() => {
                Err(ConnectionEnd::BadMessage(ConnectionBadMessage::UnexpectedFds))
            }
            Ok(0) => {
                self.ended = true;
                Ok(())
            }
            Ok(_) => Ok(()),
            Err(error) if is_descriptor_refusal(&error) => {
                Err(ConnectionEnd::BadMessage(ConnectionBadMessage::UnexpectedFds))
            }
            Err(_) => Err(ConnectionEnd::Dropped),
        }
    }

    /// One read straight into the reader's buffer.
    #[cfg(unix)]
    fn read(&mut self) -> std::io::Result<usize> {
        let ConnectionInput { stream, messages, fds, .. } = self;
        match stream.socket_fd() {
            Some(fd) => messages.read_with(|room| fds.recv_into(fd, room, |_| {})),
            None => messages.read_from(stream),
        }
    }

    #[cfg(not(unix))]
    fn read(&mut self) -> std::io::Result<usize> {
        self.messages.read_from(&mut self.stream)
    }

    /// One `recvmsg` with `MSG_DONTWAIT` straight into the reader's buffer.
    /// The socket stays blocking: its writer thread writes it with blocking
    /// writes, and `O_NONBLOCK` belongs to the description they share.
    #[cfg(unix)]
    fn read_ready(&mut self) -> std::io::Result<usize> {
        let ConnectionInput { stream, messages, fds, .. } = self;
        let Some(fd) = stream.socket_fd() else {
            return Err(std::io::ErrorKind::Unsupported.into());
        };
        messages.read_with(|room| fds.recv_into_nonblocking(fd, room, |_| {}))
    }

    /// The socket the IO reactor watches.
    #[cfg(unix)]
    pub(super) fn socket_fd(&self) -> Option<std::os::fd::RawFd> {
        self.stream.socket_fd()
    }

    #[cfg(unix)]
    fn descriptors_queued(&self) -> bool {
        self.fds.queued() > 0
    }

    #[cfg(not(unix))]
    fn descriptors_queued(&self) -> bool {
        false
    }

    /// Zeroes the line the reader still lends (it does so on its next call).
    pub(super) fn release(&mut self) {
        self.messages.push(&[]);
    }
}

#[cfg(unix)]
fn is_descriptor_refusal(error: &std::io::Error) -> bool {
    error.get_ref().is_some_and(|source| source.is::<cmux_ipc::fds::FdBadMessage>())
}

#[cfg(not(unix))]
fn is_descriptor_refusal(_error: &std::io::Error) -> bool {
    false
}

#[cfg(all(test, unix))]
#[path = "line_connection_tests.rs"]
mod tests;

#[cfg(all(test, unix))]
#[path = "echo_thread_rows_tests.rs"]
mod echo_thread_rows_tests;

#[cfg(all(test, unix))]
#[path = "line_connection_panic_mode_tests.rs"]
mod panic_mode_tests;

#[cfg(all(test, unix))]
#[path = "request_work_panic_mode_tests.rs"]
mod request_work_panic_mode_tests;
