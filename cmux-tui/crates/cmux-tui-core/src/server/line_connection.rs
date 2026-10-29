//! The connection loop shared by the local socket and the remote entry.
//!
//! A [`FrameReader`] (cmux-ipc) cuts the bytes into JSON lines, exactly as
//! `read_line` did, and into binary frames (plans/cmux-next/chrome-parity/
//! p05-ipc.md, section 3.2). Every line is seen by the connection's
//! admission before anything parses or dispatches it. A frame skips that, so
//! it passes only on a local Unix connection whose admission admits frames
//! and whose client holds the [`IPC_FRAMES_CAPABILITY`] grant when the frame
//! comes to be handled; any other frame is a bad message.
//!
//! A connection holds no thread. The daemon's one
//! `mux-io` loop (server/mux_io.rs) reads its socket with one `recvmsg` per
//! read, bytes and descriptors together, straight into the reader's buffer,
//! as Mojo's `ChannelPosix::OnFileCanReadWithoutBlocking` reads into the
//! buffer `Channel::GetReadBuffer` lends it (chromium mojo/core/channel_posix.cc),
//! cuts each whole message and hands it to the connection's line sequence
//! on the daemon's sequenced pool, which handles them one at a time in
//! arrival order, as Mojo dispatches each message as a task on its
//! receiver's sequence (mojo/public/cpp/bindings/lib/connector.cc). The same
//! loop writes the connection's queued replies and events. No frame kind
//! carries descriptors yet, so a descriptor that arrives is a bad message:
//! it is refused where the kernel would otherwise drop it unseen.
//!
//! A bad message closes the connection, as Chrome's `ReportBadMessage`
//! (mojo/public/cpp/bindings/message.h) ends the sender: nothing after the
//! bad byte is interpreted.
//!
//! The close never waits either: the sequence finishes or closes the
//! connection's request scheduler and goes on when it settled
//! ([`ConnectionSurfaceScheduler::when_settled`]); a closed connection's
//! requests get at most [`CONNECTION_SURFACE_SHUTDOWN_TIMEOUT`] to end.
//!
//! REQUEST and CANCEL frames go to [`frame_dispatch`], and so
//! do INPUT frames, which queue on the stream they name until its opener is
//! answered ([`pending_streams`]).

use std::fmt;

use cmux_ipc::{BadMessage, Frame, FrameKind, FrameReader, Message, ReaderLimits};

use crate::diagnostics::IpcStats;
use crate::supervised::{self, Fatal, ShutdownBehavior};

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

/// Bytes of cut messages a connection's sequence may hold before the
/// mux-io loop stops reading its socket; it reads again below half.
const INBOX_BYTES: usize = 1024 * 1024;
/// Messages a connection's sequence may hold before its reads pause.
const INBOX_MESSAGES: usize = 256;
/// Messages one task of a connection's sequence handles before it lets
/// the other sequences run.
const TURN_MESSAGES: usize = 16;

pub(super) fn handle_connection_with_permit(
    mux: Arc<Mux>,
    stream: Box<dyn transport::Stream>,
    render_service: Arc<RenderService>,
    connection_permit: Option<ConnectionPermit>,
) {
    start_line_connection(LineStart {
        mux,
        stream,
        prefix: Vec::new(),
        render_service,
        permit: connection_permit,
        transport: ClientTransport::Unix,
        admission: Box::new(admission::LocalAdmission),
        frames: Box::<frame_dispatch::RequestFrames>::default(),
        on_end: None,
    });
}

/// The class a connection's lines are handled at until its client class is
/// known: it serves the app and automation alike. Once classified they run
/// at the class's reader class (connection_qos.rs, task 224).
pub(super) const CONNECTION_READER_QOS: cmux_threads::ThreadQos =
    crate::thread_qos::ThreadType::UnclassifiedClient.qos();

/// Starts connection thread `name` (the remote entry's handshake,
/// `mux-remote-conn`) at [`CONNECTION_READER_QOS`] with blocking disallowed
/// (each blocking request site is recorded, MQ-13).
pub(super) fn spawn_connection_reader(
    name: &str,
    serve: impl FnOnce() + Send + 'static,
) -> std::io::Result<supervised::SupervisedThread<()>> {
    supervised::spawn_at(
        name,
        CONNECTION_READER_QOS,
        Fatal,
        ShutdownBehavior::Continue,
        move || {
            let thread = std::thread::current();
            let _hang_watch = cmux_hang_watch::register_thread(
                cmux_hang_watch::ThreadKind::Io,
                thread.name().unwrap_or("mux-remote-conn"),
            );
            cmux_threads::disallow_blocking();
            serve();
        },
    )
}

/// Serves one JSON line per message, and frames once granted, on the
/// mux-io loop; returns at once. `prefix` holds bytes already read from
/// `stream` (the remote entry's first line). `admission` sees every line
/// before anything parses or dispatches it, and may answer it instead.
pub(super) fn serve_line_connection(
    mux: Arc<Mux>,
    stream: Box<dyn transport::Stream>,
    prefix: Vec<u8>,
    render_service: Arc<RenderService>,
    connection_permit: Option<ConnectionPermit>,
    transport: ClientTransport,
    admission: Box<dyn admission::LineAdmission + Send>,
) {
    start_line_connection(LineStart {
        mux,
        stream,
        prefix,
        render_service,
        permit: connection_permit,
        transport,
        admission,
        frames: Box::<frame_dispatch::RequestFrames>::default(),
        on_end: None,
    });
}

/// Serves a connection and waits until it ended: its requests settled, its
/// client gone and its socket closed.
#[cfg(test)]
pub(super) fn serve_connection(
    mux: Arc<Mux>,
    stream: Box<dyn transport::Stream>,
    render_service: Arc<RenderService>,
    connection_permit: Option<ConnectionPermit>,
    transport: ClientTransport,
    admission: Box<dyn admission::LineAdmission + Send>,
    frames: Box<dyn FrameLane + Send>,
) -> ConnectionEnd {
    let (ended, end) = std::sync::mpsc::sync_channel(1);
    start_line_connection(LineStart {
        mux,
        stream,
        prefix: Vec::new(),
        render_service,
        permit: connection_permit,
        transport,
        admission,
        frames,
        on_end: Some(Box::new(move |end| {
            let _ = ended.send(end);
        })),
    });
    end.recv().unwrap_or(ConnectionEnd::Dropped)
}

/// What a connection does with frames: whether it may send them yet, and
/// where each one goes.
pub(super) trait FrameLane {
    /// Whether `client` holds the frames grant now. Asked again for every
    /// frame, in order with the lines before it: a later `set-client-info`
    /// or `client-hello` can end the grant, and frame payloads
    /// are not revision-translated. Never asked on a connection that cannot
    /// carry frames (not a local Unix socket, or an admission that sees only
    /// lines).
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
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) enum ConnectionEnd {
    /// The peer closed after whole messages: accepted work drains.
    PeerClosed,
    /// A read failed, setup failed, admission refused, or a handler closed
    /// the connection.
    Dropped,
    /// The peer sent a bad message.
    BadMessage(ConnectionBadMessage),
}

/// What a connection's reader cut from its socket, in arrival order.
pub(super) enum Inbound {
    /// A JSON line with its `\n` (none on a last line cut at end of stream).
    Line { text: String, arrived: Instant },
    /// A frame; the connection may refuse it (its grant).
    Frame { frame: Frame, arrived: Instant },
    /// The read side ended: nothing follows.
    End(ConnectionEnd),
}

impl Inbound {
    /// The bytes it holds, against the sequence's inbox bound.
    fn bytes(&self) -> usize {
        match self {
            Inbound::Line { text, .. } => text.len(),
            Inbound::Frame { frame, .. } => frame.header().frame_len(),
            Inbound::End(_) => 0,
        }
    }

    /// Zeroes a line nobody will handle (lines can carry credentials).
    fn discard(self) {
        if let Inbound::Line { mut text, .. } = self {
            zeroize_string(&mut text);
        }
    }
}

/// The next whole message `reader` holds: `None` while more bytes are
/// needed. `eof` says the peer closed: the end comes once the reader holds
/// no whole message.
pub(super) fn cut_message(reader: &mut FrameReader, eof: bool, ipc: &IpcStats) -> Option<Inbound> {
    let buffered = reader.buffered_len();
    match reader.next_message() {
        Ok(Some(Message::Json(line))) => {
            // Dispatch sees the line with its `\n`, as `read_line` gave it:
            // serde's error positions in `bad request` replies name it. Only
            // a last line cut at end of stream has none.
            let mut text = String::with_capacity(line.len() + 1);
            text.push_str(line);
            if line.len() < buffered {
                text.push('\n');
            }
            ipc.line_received(text.len());
            Some(Inbound::Line { text, arrived: Instant::now() })
        }
        Ok(Some(Message::Frame(frame))) => {
            ipc.frame_received(frame.header().kind(), frame.header().frame_len());
            Some(Inbound::Frame { frame, arrived: Instant::now() })
        }
        Ok(None) if eof => Some(Inbound::End(ConnectionEnd::PeerClosed)),
        Ok(None) => None,
        Err(bad) => Some(Inbound::End(ConnectionEnd::BadMessage(ConnectionBadMessage::Wire(bad)))),
    }
}

/// Run once a connection ended and its socket closed (a test's wait).
pub(super) type EndHook = Box<dyn FnOnce(ConnectionEnd) + Send>;

/// One connection to serve.
pub(super) struct LineStart {
    pub(super) mux: Arc<Mux>,
    pub(super) stream: Box<dyn transport::Stream>,
    /// Bytes already read from `stream`, read first.
    pub(super) prefix: Vec<u8>,
    pub(super) render_service: Arc<RenderService>,
    pub(super) permit: Option<ConnectionPermit>,
    pub(super) transport: ClientTransport,
    pub(super) admission: Box<dyn admission::LineAdmission + Send>,
    pub(super) frames: Box<dyn FrameLane + Send>,
    pub(super) on_end: Option<EndHook>,
}

/// The connection's parts its line sequence opens the session from.
struct Opening {
    mux: Arc<Mux>,
    writer: MessageWriter,
    /// A clone of the socket for the peer facts the hello reads.
    peer: Box<dyn transport::Stream>,
    permit: Option<ConnectionPermit>,
    transport: ClientTransport,
    admission: Box<dyn admission::LineAdmission + Send>,
    frames: Box<dyn FrameLane + Send>,
    carries_frames: bool,
}

/// Registers the connection's client and starts reading it: its writer
/// queue, its client record, then the mux-io loop (server/mux_io.rs) or,
/// where there is none, a reader thread.
pub(super) fn start_line_connection(start: LineStart) {
    let LineStart {
        mux,
        stream,
        mut prefix,
        render_service,
        permit,
        transport,
        admission,
        frames,
        on_end,
    } = start;
    let completion = Completion::new(permit.clone(), on_end);
    let (Ok(peer), Ok(control)) = (stream.try_clone_box(), stream.try_clone_box()) else {
        zeroize_bytes(&mut prefix);
        return completion.fail();
    };
    // Producers write inline to their own handle of the socket while nothing
    // waits for its writer, the mux-io loop or the writer thread;
    // none when it cannot be cloned.
    let inline = stream.try_clone_box().ok().and_then(|socket| {
        InlineSocket::new(socket, mux.bulk_frame_max(), mux.ipc_stats().clone())
    });
    let outbound = Arc::new(BoundedOutbound::with_inline(mux.bulk_frame_max(), inline));
    let writer = MessageWriter::new_with_render_service(
        QueuedSink { outbound: outbound.clone(), control: Some(SinkControl::Unix(control)) },
        render_service,
    );
    let carries_frames = matches!(transport, ClientTransport::Unix) && admission.admits_frames();
    let mut reader = FrameReader::new(line_limits());
    reader.push(&prefix);
    zeroize_bytes(&mut prefix);
    if carries_frames {
        // Frames are cut as they come; each is checked against the grant
        // in order with the lines before it (`LineSession::frame`).
        reader.negotiate_frames();
    }
    let opening = Opening {
        mux: mux.clone(),
        writer: writer.clone(),
        peer,
        permit,
        transport,
        admission,
        frames,
        carries_frames,
    };
    let input = ConnectionInput { stream, reader, outbound };
    reading::start(&mux, opening, input, writer, completion);
}

/// The socket side the reader takes.
struct ConnectionInput {
    stream: Box<dyn transport::Stream>,
    reader: FrameReader,
    outbound: Arc<BoundedOutbound>,
}

fn zeroize_bytes(bytes: &mut [u8]) {
    use zeroize::Zeroize as _;
    bytes.zeroize();
}

#[cfg(unix)]
mod reading {
    //! The mux-io loop reads and writes the connection.

    use super::super::mux_io::{IoHandle, IoRegistration};
    use super::*;

    pub(super) fn start(
        mux: &Arc<Mux>,
        opening: Opening,
        input: ConnectionInput,
        writer: MessageWriter,
        completion: Completion,
    ) {
        let handle = match mux.mux_io.handle() {
            Ok(handle) => handle,
            Err(error) => {
                eprintln!("cmux-tui: connection not served: mux-io: {error}");
                writer.close();
                return completion.fail();
            }
        };
        let connection = LineConnection::new(mux, opening, Reads::Loop(handle.clone()), completion);
        let ConnectionInput { stream, reader, outbound } = input;
        let registration = IoRegistration {
            stream,
            reader,
            outbound,
            writer: writer.clone(),
            ipc: mux.ipc_stats().clone(),
            inbound: connection.clone(),
        };
        if let Err(error) = mux.mux_io.register(&handle, registration) {
            eprintln!("cmux-tui: connection not served: {error}");
            writer.close();
            return connection.never_served();
        }
        // Opens the session (its client record) without waiting for input.
        connection.schedule();
    }

    /// How the connection's sequence reaches its reader.
    pub(super) enum Reads {
        Loop(IoHandle),
    }

    impl Reads {
        /// The inbox reached its bound. Nothing to do here: the loop stops
        /// reading on `deliver`'s false and runs the resume, a command, on
        /// its own thread after that.
        pub(super) fn pause(&self) {}

        pub(super) fn resume(&self) {
            let Reads::Loop(handle) = self;
            handle.resume_read();
        }

        pub(super) fn stop(&self) {
            let Reads::Loop(handle) = self;
            handle.stop_read();
        }
    }

    impl mux_io::InboundSink for LineConnection {
        fn deliver(&self, message: Inbound) -> bool {
            LineConnection::deliver(self, message)
        }

        fn released(&self) {
            self.completion.io_released();
        }

        fn is_person(&self) -> bool {
            LineConnection::is_person(self)
        }

        fn deliver_here(&self, message: Inbound) -> bool {
            LineConnection::deliver_here(self, message)
        }
    }
}

#[cfg(not(unix))]
mod reading {
    //! Where the daemon has no mux-io loop (Windows: no kqueue or epoll;
    //! IOCP would be its loop), a connection keeps a reader thread that
    //! blocks in `read` and a writer thread that blocks on its queue. Its
    //! messages go to the same line sequence.

    use super::*;
    use crate::panic_free::RecoverPoison;
    use cmux_threads::sync::{Condvar, Mutex};

    pub(super) fn start(
        mux: &Arc<Mux>,
        opening: Opening,
        input: ConnectionInput,
        writer: MessageWriter,
        completion: Completion,
    ) {
        let ConnectionInput { mut stream, mut reader, outbound } = input;
        let Ok(mut write_half) = stream.try_clone_box() else {
            writer.close();
            return completion.fail();
        };
        if write_half.set_write_timeout(Some(STREAM_WRITE_TIMEOUT)).is_err() {
            writer.close();
            return completion.fail();
        }
        let gate = Arc::new(ReadGate::default());
        let connection = LineConnection::new(mux, opening, Reads::Thread(gate.clone()), completion);
        let ipc = mux.ipc_stats().clone();
        let writer_close = writer.clone();
        let writer_ipc = ipc.clone();
        let writer_connection = connection.clone();
        let wrote = crate::echo_thread::spawn("mux-line-out", move || {
            let mut batch = Vec::new();
            // mq14-allow: the writer thread waits for its own queue (a checked wait).
            while let Some(mut turn) = outbound.recv_turn(&mut batch) {
                // What an inline write left goes first.
                let rest = turn.rest.take();
                let written =
                    write_counted_turn(&mut *write_half, &writer_ipc, rest.as_deref(), &batch);
                batch.clear();
                if written.is_err() {
                    outbound.close();
                    break;
                }
            }
            writer_close.close();
            let _ = write_half.shutdown(Shutdown::Both);
            writer_connection.completion.io_released();
        });
        if wrote.is_err() {
            writer.close();
            return connection.never_served();
        }
        connection.schedule();
        // Its job is to block: in `read`, and while the sequence holds enough.
        let read = supervised::spawn_at(
            "mux-conn",
            CONNECTION_READER_QOS,
            Fatal,
            ShutdownBehavior::Continue,
            move || {
                let mut eof = false;
                loop {
                    if !gate.wait_open() {
                        break;
                    }
                    let next = cut_message(&mut reader, eof, &ipc);
                    let message = match next {
                        Some(message) => message,
                        None => match reader.read_from(&mut stream) {
                            Ok(0) => {
                                eof = true;
                                continue;
                            }
                            Ok(_) => continue,
                            Err(error) if error.kind() == std::io::ErrorKind::Interrupted => {
                                continue;
                            }
                            Err(_) => Inbound::End(ConnectionEnd::Dropped),
                        },
                    };
                    let ended = matches!(message, Inbound::End(_));
                    // At the bound, `deliver` closes the gate under the inbox
                    // lock: the next `wait_open` waits for the drain's resume.
                    connection.deliver(message);
                    if ended {
                        break;
                    }
                }
                reader.push(&[]);
            },
        );
        if read.is_err() {
            writer.close();
        }
    }

    /// The reader thread's pause: closed while the sequence holds enough.
    #[derive(Default)]
    pub(super) struct ReadGate {
        state: Mutex<GateState>,
        changed: Condvar,
    }

    #[derive(Default)]
    struct GateState {
        paused: bool,
        stopped: bool,
    }

    impl ReadGate {
        /// Waits while paused; false once reading stopped.
        fn wait_open(&self) -> bool {
            let mut state = self.state.lock().recover_poison();
            while state.paused && !state.stopped {
                state = self.changed.wait(state).recover_poison();
            }
            !state.stopped
        }
    }

    pub(super) enum Reads {
        Thread(Arc<ReadGate>),
    }

    impl Reads {
        /// The inbox reached its bound: called under the inbox lock, so a
        /// drain's resume, which follows the inbox's own resume under that
        /// lock, always comes after it.
        pub(super) fn pause(&self) {
            let Reads::Thread(gate) = self;
            gate.state.lock().recover_poison().paused = true;
        }

        pub(super) fn resume(&self) {
            let Reads::Thread(gate) = self;
            gate.state.lock().recover_poison().paused = false;
            gate.changed.notify_all();
        }

        pub(super) fn stop(&self) {
            let Reads::Thread(gate) = self;
            gate.state.lock().recover_poison().stopped = true;
            gate.changed.notify_all();
        }
    }
}

#[path = "line_session.rs"]
mod session;
#[cfg(test)]
pub(super) use session::line_classes;
use session::{Completion, LineConnection};

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
