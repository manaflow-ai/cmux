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
//! REQUEST and CANCEL frames go to [`frame_dispatch`] (p05-ipc-071).

use std::fmt;

use cmux_ipc::{BadMessage, Frame, FrameKind, FrameReader, Message, ReaderLimits};

use crate::diagnostics::{IpcTransport, JsonParseScope};

use super::connection_scheduler::connection_qos::ReaderClass;
use super::*;
use cmux_threads::checked::sync as waits;

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
    render_service: Arc<RenderService>,
    connection_permit: Option<ConnectionPermit>,
) {
    serve_line_connection(
        mux,
        stream,
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

/// Starts connection reader thread `name` at [`CONNECTION_READER_QOS`] with
/// blocking disallowed (each blocking request site is recorded, MQ-13).
pub(super) fn spawn_connection_reader(
    name: &str,
    serve: impl FnOnce() + Send + 'static,
) -> std::io::Result<JoinHandle<()>> {
    cmux_threads::spawn(name, CONNECTION_READER_QOS, move || {
        // Each frame it reads is one hang-watch scope (connection_frame.rs);
        // the read itself is outside every scope.
        let thread = std::thread::current();
        let _hang_watch = cmux_hang_watch::register_thread(
            cmux_hang_watch::ThreadKind::Io,
            thread.name().unwrap_or("mux-conn"),
        );
        cmux_threads::disallow_blocking();
        serve();
    })
}

/// One JSON line per message, and frames once granted. `admission` sees
/// every line before anything parses or dispatches it, and may answer it
/// instead (the remote entry).
pub(super) fn serve_line_connection(
    mux: Arc<Mux>,
    stream: Box<dyn transport::Stream>,
    render_service: Arc<RenderService>,
    connection_permit: Option<ConnectionPermit>,
    transport: ClientTransport,
    admission: &dyn admission::LineAdmission,
) {
    let _ = serve_connection(
        mux,
        stream,
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

pub(super) fn serve_connection(
    mux: Arc<Mux>,
    stream: Box<dyn transport::Stream>,
    render_service: Arc<RenderService>,
    connection_permit: Option<ConnectionPermit>,
    transport: ClientTransport,
    admission: &dyn admission::LineAdmission,
    frames: &mut dyn FrameLane,
) -> ConnectionEnd {
    let Ok(mut write_half) = stream.try_clone_box() else { return ConnectionEnd::Dropped };
    let Ok(control) = write_half.try_clone_box() else { return ConnectionEnd::Dropped };
    if write_half.set_write_timeout(Some(STREAM_WRITE_TIMEOUT)).is_err() {
        return ConnectionEnd::Dropped;
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
    let Ok(writer_thread) = crate::echo_thread::spawn("mux-line-out", move || {
        let _hang_watch =
            cmux_hang_watch::register_thread(cmux_hang_watch::ThreadKind::Io, "mux-line-out");
        // mq14-allow: the writer thread waits for its own queue (a checked wait).
        while let Some(item) = writer_outbound.recv() {
            // Each item's write is a 100 ms hang scope; the wait above is not.
            let _item = writer_hangs.item(WatchKind::LineOut);
            match &item {
                OutboundItem::Text(text) => writer_ipc.line_sent(text.len() + 1),
                OutboundItem::Frame(header, _) | OutboundItem::Chunk { header, .. } => {
                    writer_ipc.frame_sent(header.kind(), header.frame_len());
                }
                OutboundItem::Flush(_) => {}
            }
            // One scope per write, as long as the socket's write timeout:
            // the queue wait above is outside it.
            let write = cmux_hang_watch::watch(STREAM_WRITE_TIMEOUT);
            let written = write_line_outbound_item(&mut writer_ipc.counted(&mut *write_half), item);
            drop(write);
            if written.is_err() {
                writer_outbound.close();
                let _ = write_half.shutdown(Shutdown::Both);
                break;
            }
        }
        writer_close.close();
        let _ = write_half.shutdown(Shutdown::Both);
    }) else {
        writer.close();
        return ConnectionEnd::Dropped;
    };
    let peer_key = stream.peer_process_key();
    let peer_token = stream.peer_token();
    let peer_uid = stream.peer_uid();
    let client = mux.control_clients.register(transport, writer.clone());
    // The connection's stream 0, open until the connection ends
    // (`server-stats` `ipc`).
    let ipc = mux.ipc_stats().clone();
    let _stream = ipc.stream_opened();
    origin_gate::set_peer_identity_at_accept(&mux, client, peer_key, peer_token, peer_uid);
    if !admission.registered(&mux, client) {
        // Refused before its first frame (the remote entry's revocation
        // limits): nothing is read or dispatched.
        disconnect_client(&mux, client, false);
        let _ = waits::join(writer_thread);
        return ConnectionEnd::Dropped;
    }
    let mut hello = client_hello::HelloGate::new(transport);
    let class = mux.control_clients.connection_class(client);
    let mut reader_class = ReaderClass::new(class.clone(), mux.request_qos());
    let surface_scheduler = Arc::new(
        ConnectionSurfaceScheduler::new_inner(
            mux.surface_operation_admission.clone(),
            connection_permit.clone(),
        )
        .classed(class),
    );
    let mut input = ConnectionInput::new(stream);
    let carries_frames = matches!(transport, ClientTransport::Unix) && admission.admits_frames();
    let end = loop {
        if input.messages.next_is_frame() {
            if !(carries_frames && frames.granted(&mux, client)) {
                break ConnectionEnd::BadMessage(ConnectionBadMessage::Wire(
                    BadMessage::FramesNotNegotiated,
                ));
            }
            input.messages.negotiate_frames();
        }
        let buffered = input.messages.buffered_len();
        let mut line = match input.messages.next_message() {
            Ok(Some(Message::Json(line))) => {
                // Dispatch sees the line with its `\n`, as `read_line` gave
                // it: serde's error positions in `bad request` replies name
                // it. Only a last line cut at end of stream has none.
                let mut text = String::with_capacity(line.len() + 1);
                text.push_str(line);
                if line.len() < buffered {
                    text.push('\n');
                }
                ipc.line_received(text.len());
                text
            }
            Ok(Some(Message::Frame(frame))) => {
                ipc.frame_received(frame.header().kind(), frame.header().frame_len());
                let connection = FrameConnection {
                    mux: &mux,
                    client,
                    transport,
                    writer: &writer,
                    scheduler: &surface_scheduler,
                    arrived: Instant::now(),
                };
                match frames.route(frame, &connection) {
                    Ok(true) => continue,
                    Ok(false) => break ConnectionEnd::Dropped,
                    Err(bad) => break ConnectionEnd::BadMessage(bad),
                }
            }
            Ok(None) if input.ended => break ConnectionEnd::PeerClosed,
            Ok(None) => match input.fill() {
                Ok(()) => continue,
                Err(end) => break end,
            },
            Err(bad) => break ConnectionEnd::BadMessage(ConnectionBadMessage::Wire(bad)),
        };
        // The line's arrival, for its request span (server/request_spans.rs).
        let arrived = Instant::now();
        if line.trim().is_empty() {
            zeroize_string(&mut line);
            continue;
        }
        // Every line from here is one request of `server-stats` `ipc`: the
        // parses of its admission, hello gate and route all count toward it.
        let parses = JsonParseScope::enter(&ipc, IpcTransport::Lines);
        let keep_open = match admission.refusal(&line) {
            Some(refusal) => {
                // A refused line still counts as a line: the window closes.
                hello.close();
                writer.send_control(&refusal).is_ok()
            }
            None => {
                let peer = || client_hello::Peer {
                    key: input.stream.peer_process_key(),
                    token: input.stream.peer_token(),
                };
                match hello.observe(&mux, client, &line, peer) {
                    Some(reply) => writer.send_control(&reply).is_ok(),
                    None => {
                        reader_class.before_line(&mux, client, hello.is_closed());
                        handle_connection_frame_at(
                            &mux,
                            client,
                            transport,
                            &line,
                            &writer,
                            &surface_scheduler,
                            arrived,
                        )
                    }
                }
            }
        };
        drop(parses);
        zeroize_string(&mut line);
        if !keep_open {
            break ConnectionEnd::Dropped;
        }
    };
    input.release();
    if let ConnectionEnd::BadMessage(bad) = &end {
        ipc.bad_message();
        eprintln!("cmux-tui: client {client} closed: bad_message {}: {bad}", bad.reason());
    }
    if end == ConnectionEnd::PeerClosed {
        surface_scheduler.finish_and_wait();
    } else {
        let _ = surface_scheduler.close_and_wait(CONNECTION_SURFACE_SHUTDOWN_TIMEOUT);
    }
    disconnect_client(&mux, client, false);
    let _ = waits::join(writer_thread);
    drop(connection_permit);
    end
}

/// The read side of one connection: the socket, the reader that cuts its
/// bytes, and on a local socket the descriptor FIFO `recvmsg` fills.
struct ConnectionInput {
    stream: Box<dyn transport::Stream>,
    messages: FrameReader,
    #[cfg(unix)]
    fds: cmux_ipc::fds::FdReceiver,
    /// The peer closed its side.
    ended: bool,
}

impl ConnectionInput {
    fn new(stream: Box<dyn transport::Stream>) -> Self {
        ConnectionInput {
            stream,
            messages: FrameReader::new(line_limits()),
            #[cfg(unix)]
            fds: cmux_ipc::fds::FdReceiver::default(),
            ended: false,
        }
    }

    /// One read into the reader; at end of stream marks it ended.
    fn fill(&mut self) -> Result<(), ConnectionEnd> {
        let read = loop {
            match self.read() {
                Err(error) if error.kind() == std::io::ErrorKind::Interrupted => {}
                result => break result,
            }
        };
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

    #[cfg(unix)]
    fn descriptors_queued(&self) -> bool {
        self.fds.queued() > 0
    }

    #[cfg(not(unix))]
    fn descriptors_queued(&self) -> bool {
        false
    }

    /// Zeroes the line the reader still lends (it does so on its next call).
    fn release(&mut self) {
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
