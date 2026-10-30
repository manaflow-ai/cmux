//! The dual reader over a real socket pair: JSON lines get the replies they
//! got from `read_line`, frames pass only while the grant holds on a
//! connection that may carry them, and a frame or a descriptor the
//! connection may not take closes it with `bad_message`.

use std::io::{BufRead, BufReader, Write};
use std::net::Shutdown;
use std::os::fd::AsRawFd;
use std::os::unix::net::UnixStream;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::thread::JoinHandle;
use std::time::{Duration, Instant};

use cmux_ipc::{Aux, BadMessage, CallAux, CallFlags, FrameHeader, FrameKind, PriorityHint};
use serde_json::{Value, json};

use super::{
    ConnectionBadMessage, ConnectionEnd, FrameConnection, FrameLane, LineStart, serve_connection,
    start_line_connection,
};
use crate::server::frame_dispatch::{CallRefusal, RequestFrames};
use crate::server::*;

type Seen = Arc<Mutex<Vec<(FrameKind, u32, Vec<u8>)>>>;

/// A lane whose grant the test flips and that records every frame.
struct RecordingFrames {
    grant: Arc<AtomicBool>,
    seen: Seen,
}

impl FrameLane for RecordingFrames {
    fn granted(&self, _mux: &Mux, _client: u64) -> bool {
        self.grant.load(Ordering::SeqCst)
    }

    fn route(
        &mut self,
        frame: cmux_ipc::Frame,
        _connection: &FrameConnection<'_>,
    ) -> Result<bool, ConnectionBadMessage> {
        let request = frame.header().call().map_or(0, |call| call.request_id);
        self.seen.lock().unwrap().push((frame.header().kind(), request, frame.payload().to_vec()));
        Ok(true)
    }
}

struct Peer {
    mux: Arc<Mux>,
    socket: UnixStream,
    replies: BufReader<UnixStream>,
    served: JoinHandle<ConnectionEnd>,
}

/// An admission that admits every line but, like the remote entry's, sees
/// only lines.
struct LinesOnly;

impl admission::LineAdmission for LinesOnly {
    fn refusal(&self, _line: &str) -> Option<Value> {
        None
    }
}

fn connect(label: &str, lane: Option<RecordingFrames>) -> Peer {
    connect_with(label, lane, ClientTransport::Unix, Box::new(admission::LocalAdmission))
}

fn connect_with(
    label: &str,
    lane: Option<RecordingFrames>,
    transport: ClientTransport,
    admission: Box<dyn admission::LineAdmission + Send>,
) -> Peer {
    let mux = Mux::new_for_test(format!("line-conn-{label}"), crate::SurfaceOptions::default());
    let (socket, server) = UnixStream::pair().unwrap();
    let served_mux = mux.clone();
    let served = std::thread::spawn(move || {
        let mux = served_mux;
        let stream: Box<dyn transport::Stream> = Box::new(server);
        let render = Arc::new(RenderService::new());
        match lane {
            Some(lane) => {
                serve_connection(mux, stream, render, None, transport, admission, Box::new(lane))
            }
            None => serve_connection(
                mux,
                stream,
                render,
                None,
                transport,
                admission,
                Box::<RequestFrames>::default(),
            ),
        }
    });
    let read_half = socket.try_clone().unwrap();
    read_half.set_read_timeout(Some(Duration::from_secs(10))).unwrap();
    Peer { mux, socket, replies: BufReader::new(read_half), served }
}

impl Peer {
    fn send(&mut self, bytes: &[u8]) {
        self.socket.write_all(bytes).unwrap();
    }

    /// The next reply (events skipped); `None` once the daemon closed.
    fn reply(&mut self) -> Option<Value> {
        loop {
            let mut line = String::new();
            if self.replies.read_line(&mut line).unwrap() == 0 {
                return None;
            }
            let value: Value = serde_json::from_str(&line).unwrap();
            if value.get("event").is_none() {
                return Some(value);
            }
        }
    }

    fn finish(self) -> ConnectionEnd {
        let _ = self.socket.shutdown(Shutdown::Write);
        self.served.join().unwrap()
    }
}

fn ping(id: u64) -> Vec<u8> {
    format!("{}\n", json!({"id": id, "cmd": "ping"})).into_bytes()
}

fn request_frame(request_id: u32, payload: &[u8]) -> Vec<u8> {
    let aux = Aux::Call(CallAux {
        request_id,
        method_id: 0x0101,
        priority: PriorityHint::Control,
        flags: CallFlags::empty(),
    });
    let header =
        FrameHeader::new(FrameKind::Request, 0, u32::try_from(payload.len()).unwrap(), aux)
            .unwrap();
    let mut bytes = header.encode().to_vec();
    bytes.extend_from_slice(payload);
    bytes
}

fn recording(granted: bool) -> (RecordingFrames, Arc<AtomicBool>, Seen) {
    let grant = Arc::new(AtomicBool::new(granted));
    let seen = Seen::default();
    (RecordingFrames { grant: grant.clone(), seen: seen.clone() }, grant, seen)
}

#[test]
fn line_connection_lines_get_the_replies_read_line_gave() {
    let mut peer = connect("lines", None);
    peer.send(&ping(1));
    let reply = peer.reply().unwrap();
    assert_eq!((reply["id"].clone(), reply["ok"].clone()), (json!(1), json!(true)), "{reply}");
    // Whitespace-only lines are skipped, as before.
    peer.send(b"  \n\n");
    // The line reaches dispatch with its `\n`: serde places the end on line 2.
    peer.send(b"{\"id\":2,\"cmd\":\"ping\"\n");
    let refused = peer.reply().unwrap();
    let error = refused.to_string();
    assert!(error.contains("bad request") && error.contains("line 2 column 0"), "{refused}");
    peer.send(&ping(3));
    assert_eq!(peer.reply().unwrap()["id"], json!(3));
    assert_eq!(peer.finish(), ConnectionEnd::PeerClosed);
}

#[test]
fn line_connection_an_unterminated_last_line_is_dispatched_at_eof() {
    let mut peer = connect("eof", None);
    peer.send(b"{\"id\":4,\"cmd\":\"ping\"}");
    peer.socket.shutdown(Shutdown::Write).unwrap();
    assert_eq!(peer.reply().unwrap()["id"], json!(4));
    assert_eq!(peer.served.join().unwrap(), ConnectionEnd::PeerClosed);
}

#[test]
fn line_connection_a_frame_before_negotiation_closes_with_bad_message() {
    let mut peer = connect("ungranted", None);
    peer.send(&ping(1));
    assert_eq!(peer.reply().unwrap()["id"], json!(1));
    let mut bytes = request_frame(7, b"{}");
    bytes.extend(ping(2));
    peer.send(&bytes);
    assert_eq!(peer.reply(), None, "nothing after the frame is read");
    assert_eq!(
        peer.finish(),
        ConnectionEnd::BadMessage(ConnectionBadMessage::Wire(BadMessage::FramesNotNegotiated))
    );
}

#[test]
fn line_connection_a_lane_without_the_grant_sees_no_frame() {
    let (lane, _grant, seen) = recording(false);
    let mut peer = connect("refused-lane", Some(lane));
    peer.send(&ping(1));
    assert_eq!(peer.reply().unwrap()["id"], json!(1));
    peer.send(&request_frame(7, b"{}"));
    assert_eq!(peer.reply(), None);
    assert_eq!(
        peer.finish(),
        ConnectionEnd::BadMessage(ConnectionBadMessage::Wire(BadMessage::FramesNotNegotiated))
    );
    assert!(seen.lock().unwrap().is_empty());
}

#[test]
fn line_connection_interleaved_lines_and_frames_keep_their_order() {
    let (lane, _grant, seen) = recording(true);
    let mut peer = connect("interleaved", Some(lane));
    let mut bytes = ping(1);
    bytes.extend(request_frame(10, b"{\"a\":1}"));
    bytes.extend(ping(2));
    bytes.extend(request_frame(11, b""));
    bytes.extend(request_frame(12, &[0xFF; 40]));
    bytes.extend(ping(3));
    // One byte per write: every message boundary falls inside a read.
    for byte in &bytes {
        peer.send(std::slice::from_ref(byte));
    }
    for id in 1..=3 {
        assert_eq!(peer.reply().unwrap()["id"], json!(id));
    }
    assert_eq!(peer.finish(), ConnectionEnd::PeerClosed);
    assert_eq!(
        *seen.lock().unwrap(),
        vec![
            (FrameKind::Request, 10, b"{\"a\":1}".to_vec()),
            (FrameKind::Request, 11, Vec::new()),
            (FrameKind::Request, 12, vec![0xFF; 40]),
        ]
    );
}

#[test]
fn line_connection_frames_follow_a_grant_given_after_the_first_lines() {
    let (lane, grant, seen) = recording(false);
    let mut peer = connect("late-grant", Some(lane));
    peer.send(&ping(1));
    assert_eq!(peer.reply().unwrap()["id"], json!(1));
    grant.store(true, Ordering::SeqCst);
    let mut bytes = request_frame(20, b"x");
    bytes.extend(ping(2));
    peer.send(&bytes);
    assert_eq!(peer.reply().unwrap()["id"], json!(2));
    assert_eq!(peer.finish(), ConnectionEnd::PeerClosed);
    assert_eq!(*seen.lock().unwrap(), vec![(FrameKind::Request, 20, b"x".to_vec())]);
}

#[test]
fn line_connection_a_descriptor_closes_with_bad_message() {
    let mut peer = connect("descriptor", None);
    peer.send(&ping(1));
    assert_eq!(peer.reply().unwrap()["id"], json!(1));
    let passed = std::fs::File::open("/dev/null").unwrap();
    cmux_ipc::fds::send_all(peer.socket.as_raw_fd(), &ping(2), &[passed.as_raw_fd()]).unwrap();
    assert_eq!(peer.reply(), None, "the line that brought a descriptor is not served");
    assert_eq!(peer.finish(), ConnectionEnd::BadMessage(ConnectionBadMessage::UnexpectedFds));
}

#[test]
fn line_connection_an_oversized_line_still_closes() {
    let mut peer = connect("oversized", None);
    let mut line = vec![b' '; MAX_JSON_LINE_BYTES + 1];
    line.push(b'\n');
    // The daemon closes before the last bytes; their write may fail.
    let _ = peer.socket.write_all(&line);
    assert_eq!(peer.reply(), None);
    assert_eq!(
        peer.finish(),
        ConnectionEnd::BadMessage(ConnectionBadMessage::Wire(BadMessage::LineTooLong {
            max: MAX_JSON_LINE_BYTES
        }))
    );
}

/// The payload limit excludes the `\n`, as with `read_line`: a line of
/// exactly the limit plus its delimiter is served.
#[test]
fn line_connection_a_line_of_exactly_the_limit_is_served() {
    let mut peer = connect("exact-limit", None);
    let mut line = json!({"id": 5, "cmd": "ping"}).to_string().into_bytes();
    line.resize(MAX_JSON_LINE_BYTES, b' ');
    line.push(b'\n');
    peer.send(&line);
    assert_eq!(peer.reply().unwrap()["id"], json!(5));
    assert_eq!(peer.finish(), ConnectionEnd::PeerClosed);
}

#[test]
fn line_connection_a_revoked_grant_closes_at_the_next_frame() {
    let (lane, grant, seen) = recording(true);
    let mut peer = connect("revoked", Some(lane));
    let mut bytes = request_frame(30, b"a");
    bytes.extend(ping(1));
    peer.send(&bytes);
    assert_eq!(peer.reply().unwrap()["id"], json!(1));
    grant.store(false, Ordering::SeqCst);
    let mut bytes = request_frame(31, b"b");
    bytes.extend(ping(2));
    peer.send(&bytes);
    assert_eq!(peer.reply(), None, "nothing after the refused frame is read");
    assert_eq!(
        peer.finish(),
        ConnectionEnd::BadMessage(ConnectionBadMessage::Wire(BadMessage::FramesNotNegotiated))
    );
    assert_eq!(*seen.lock().unwrap(), vec![(FrameKind::Request, 30, b"a".to_vec())]);
}

/// Frames skip line admission, so a connection that is not a local Unix
/// socket, or whose admission sees only lines, takes none, whatever the
/// client's record says.
#[test]
fn line_connection_frames_need_a_local_socket_and_an_admission_that_takes_them() {
    let cases: [(&str, ClientTransport, Box<dyn admission::LineAdmission + Send>); 3] = [
        ("remote-transport", ClientTransport::Remote, Box::new(admission::LocalAdmission)),
        ("websocket-transport", ClientTransport::WebSocket, Box::new(admission::LocalAdmission)),
        ("lines-only-admission", ClientTransport::Unix, Box::new(LinesOnly)),
    ];
    for (label, transport, admission) in cases {
        let (lane, _grant, seen) = recording(true);
        let mut peer = connect_with(label, Some(lane), transport, admission);
        peer.send(&ping(1));
        assert_eq!(peer.reply().unwrap()["id"], json!(1), "{label}");
        peer.send(&request_frame(7, b"{}"));
        assert_eq!(peer.reply(), None, "{label}");
        assert_eq!(
            peer.finish(),
            ConnectionEnd::BadMessage(ConnectionBadMessage::Wire(BadMessage::FramesNotNegotiated)),
            "{label}"
        );
        assert!(seen.lock().unwrap().is_empty(), "{label}");
    }
}

/// The client this test's connection registered (a fresh test mux has no
/// other Unix client).
fn served_client(peer: &mut Peer) -> u64 {
    peer.send(&ping(99));
    assert_eq!(peer.reply().unwrap()["id"], json!(99));
    let state = peer.mux.control_clients.state.lock().unwrap();
    let mut unix = state
        .clients
        .iter()
        .filter(|(_, record)| matches!(record.transport, ClientTransport::Unix))
        .map(|(client, _)| *client);
    let client = unix.next().expect("the connection's client");
    assert_eq!(unix.next(), None, "one Unix client");
    client
}

/// A connection the production lane serves, from a direct same-user peer
/// with every framed IPC transport bound (p05-ipc-060's test seams: this
/// in-process peer is the daemon's own binary, which accept classifies as a
/// byte bridge, and this build binds no transport yet).
fn same_user_peer(label: &str) -> Peer {
    let mut peer = connect(label, None);
    let client = served_client(&mut peer);
    peer.mux.control_clients.ipc_transports.bind_all_for_test();
    origin_gate::set_peer_process_for_test(
        &peer.mux,
        client,
        crate::request_origin::PeerProcess::SameUser,
    );
    peer
}

/// The production lane: `ipc-frames-v2`, declared in a real `set-client-info`
/// at this daemon's revision, is the grant: the frame reaches the request
/// router (frame_dispatch_tests covers what it answers), whose check of
/// the `{}` body against `ping` closes the connection.
#[test]
fn line_connection_the_declared_capability_negotiates_frames() {
    let (current, _) = api_revision_wire::identify_fields();
    let mut peer = same_user_peer("declared");
    let declare = json!({
        "id": 1,
        "cmd": "set-client-info",
        "name": "frames",
        "capabilities": ["ipc-frames-v2"],
        "api_revision": current,
    });
    peer.send(format!("{declare}\n").as_bytes());
    let reply = peer.reply().unwrap();
    assert_eq!((reply["id"].clone(), reply["ok"].clone()), (json!(1), json!(true)), "{reply}");
    peer.send(&request_frame(40, b"{}"));
    assert_eq!(peer.reply(), None);
    assert_eq!(
        peer.finish(),
        ConnectionEnd::BadMessage(ConnectionBadMessage::Call(CallRefusal::MethodMismatch {
            method_id: 0x0101
        }))
    );

    let mut peer = same_user_peer("undeclared");
    let undeclared =
        json!({"id": 1, "cmd": "set-client-info", "name": "lines", "api_revision": current});
    peer.send(format!("{undeclared}\n").as_bytes());
    assert_eq!(peer.reply().unwrap()["ok"], json!(true));
    peer.send(&request_frame(41, b"{}"));
    assert_eq!(peer.reply(), None);
    assert_eq!(
        peer.finish(),
        ConnectionEnd::BadMessage(ConnectionBadMessage::Wire(BadMessage::FramesNotNegotiated))
    );
}

/// A connection's stream that is not one socket the mux-io loop can watch
/// (`socket_fd` is `None`).
struct NotASocket {
    inner: UnixStream,
}

impl Read for NotASocket {
    fn read(&mut self, buf: &mut [u8]) -> std::io::Result<usize> {
        self.inner.read(buf)
    }
}

impl Write for NotASocket {
    fn write(&mut self, buf: &[u8]) -> std::io::Result<usize> {
        self.inner.write(buf)
    }

    fn flush(&mut self) -> std::io::Result<()> {
        self.inner.flush()
    }
}

impl transport::Stream for NotASocket {
    fn try_clone_box(&self) -> std::io::Result<Box<dyn transport::Stream>> {
        Ok(Box::new(Self { inner: self.inner.try_clone()? }))
    }
    fn set_read_timeout(&self, timeout: Option<Duration>) -> std::io::Result<()> {
        self.inner.set_read_timeout(timeout)
    }
    fn set_write_timeout(&self, timeout: Option<Duration>) -> std::io::Result<()> {
        self.inner.set_write_timeout(timeout)
    }
    fn shutdown(&self, how: Shutdown) -> std::io::Result<()> {
        self.inner.shutdown(how)
    }
}

/// The request watchdog's wakeups once they stop changing (it disarmed).
fn settled_wakeups(mux: &Mux) -> u64 {
    let wakeups = || mux.request_watchdog.snapshot().watchdog_wakeups;
    let deadline = Instant::now() + Duration::from_secs(10);
    let mut last = wakeups();
    loop {
        std::thread::sleep(Duration::from_millis(600));
        let now = wakeups();
        if now == last {
            return now;
        }
        assert!(Instant::now() < deadline, "the watchdog never settled");
        last = now;
    }
}

/// A connection's stream whose next write, once `stall` is set, takes
/// 150 ms: an injected stall of the write that sends its replies (the
/// mux-io loop's, once `mux-line-out`'s).
struct StallingStream {
    inner: UnixStream,
    stall: Arc<AtomicBool>,
}

impl Read for StallingStream {
    fn read(&mut self, buf: &mut [u8]) -> std::io::Result<usize> {
        self.inner.read(buf)
    }
}

impl Write for StallingStream {
    fn write(&mut self, buf: &[u8]) -> std::io::Result<usize> {
        if self.stall.swap(false, Ordering::SeqCst) {
            std::thread::sleep(Duration::from_millis(150));
        }
        self.inner.write(buf)
    }

    fn flush(&mut self) -> std::io::Result<()> {
        self.inner.flush()
    }
}

impl transport::Stream for StallingStream {
    fn try_clone_box(&self) -> std::io::Result<Box<dyn transport::Stream>> {
        Ok(Box::new(Self { inner: self.inner.try_clone()?, stall: self.stall.clone() }))
    }
    fn set_read_timeout(&self, timeout: Option<Duration>) -> std::io::Result<()> {
        self.inner.set_read_timeout(timeout)
    }
    fn set_write_timeout(&self, timeout: Option<Duration>) -> std::io::Result<()> {
        self.inner.set_write_timeout(timeout)
    }
    fn shutdown(&self, how: Shutdown) -> std::io::Result<()> {
        self.inner.shutdown(how)
    }
    // One socket the mux-io loop serves (its writes still go through `write`).
    fn socket_fd(&self) -> Option<std::os::fd::RawFd> {
        Some(self.inner.as_raw_fd())
    }
}

/// Each batch of replies the connection's writer (now the mux-io loop)
/// writes is watched. A reply whose write stalls 150 ms is one hang of the
/// mux's watchdog (`slow_requests.hangs`; the request watchdog tests check
/// the row names `mux-line-out`), the replies before and after it none, and
/// the idle connection then wakes the watchdog 0 times. The stalled reply is
/// bigger than an inline write takes (`bulk_frame_max`), so the loop writes it.
#[test]
fn line_connection_a_stalled_write_is_one_line_out_hang_and_idle_wakes_nothing() {
    let mux = Mux::new_for_test("line-conn-stall", crate::SurfaceOptions::default());
    let (socket, server) = UnixStream::pair().unwrap();
    let stall = Arc::new(AtomicBool::new(false));
    let stream = StallingStream { inner: server, stall: stall.clone() };
    let served_mux = mux.clone();
    let served = std::thread::spawn(move || {
        let render = Arc::new(RenderService::new());
        let lane = Box::<RequestFrames>::default();
        let stream: Box<dyn transport::Stream> = Box::new(stream);
        let transport = ClientTransport::Unix;
        serve_connection(served_mux, stream, render, None, transport, Box::new(LinesOnly), lane)
    });
    let read_half = socket.try_clone().unwrap();
    read_half.set_read_timeout(Some(Duration::from_secs(10))).unwrap();
    let mut peer = Peer { mux, socket, replies: BufReader::new(read_half), served };

    peer.send(&ping(1));
    assert_eq!(peer.reply().unwrap()["ok"], json!(true));
    settled_wakeups(&peer.mux);
    assert_eq!(peer.mux.request_watchdog.snapshot().hangs, 0, "a prompt reply is no hang");

    stall.store(true, Ordering::SeqCst);
    let big_id = "x".repeat(peer.mux.bulk_frame_max() + 1);
    peer.send(format!("{}\n", json!({"id": &big_id, "cmd": "ping"})).as_bytes());
    let reply = peer.reply().unwrap();
    assert_eq!(reply["ok"], json!(true));
    assert_eq!(reply["id"], json!(big_id));
    assert!(!stall.load(Ordering::SeqCst), "the reply's write stalled");
    peer.send(&ping(3));
    assert_eq!(peer.reply().unwrap()["ok"], json!(true));
    let idle = settled_wakeups(&peer.mux);
    assert_eq!(peer.mux.request_watchdog.snapshot().hangs, 1, "one stalled write, one hang");

    std::thread::sleep(Duration::from_secs(1));
    assert_eq!(settled_wakeups(&peer.mux), idle, "an idle connection wakes the watchdog 0 times");
    peer.finish();
}

/// A connection holds no thread. Its replies leave on the
/// mux-io loop, its requests run on the pool, and once idle it wakes the
/// request watchdog 0 times and records no hang.
#[test]
fn line_connection_an_idle_connection_wakes_nothing_and_records_no_hang() {
    let mut peer = connect("idle", None);
    for id in 1..=3 {
        peer.send(&ping(id));
        assert_eq!(peer.reply().unwrap()["ok"], json!(true));
    }
    let idle = settled_wakeups(&peer.mux);
    std::thread::sleep(Duration::from_secs(1));
    assert_eq!(settled_wakeups(&peer.mux), idle, "an idle connection wakes the watchdog 0 times");
    assert_eq!(peer.mux.request_watchdog.snapshot().hangs, 0);
    assert_eq!(peer.finish(), ConnectionEnd::PeerClosed);
}

/// A stream the loop cannot watch is not served: the connection ends at
/// once and its peer reads the close.
#[test]
fn line_connection_a_stream_that_is_not_a_socket_is_dropped() {
    let mux = Mux::new_for_test("line-conn-no-socket", crate::SurfaceOptions::default());
    let (mut socket, server) = UnixStream::pair().unwrap();
    let stream: Box<dyn transport::Stream> = Box::new(NotASocket { inner: server });
    let end = serve_connection(
        mux,
        stream,
        Arc::new(RenderService::new()),
        None,
        ClientTransport::Unix,
        Box::new(LinesOnly),
        Box::<RequestFrames>::default(),
    );
    assert_eq!(end, ConnectionEnd::Dropped);
    socket.set_read_timeout(Some(Duration::from_secs(10))).unwrap();
    let mut rest = Vec::new();
    assert_eq!(socket.read_to_end(&mut rest).unwrap(), 0, "the peer reads the close");
}

fn clear_history(id: u64, surface: SurfaceId) -> Vec<u8> {
    format!("{}\n", json!({"id": id, "cmd": "clear-history", "surface": surface})).into_bytes()
}

/// Waits until a clear-history item runs on the System lane.
fn wait_for_clear_to_run(mux: &Mux) {
    let deadline = Instant::now() + Duration::from_secs(10);
    while mux.work.stats()[cmux_threads::work::Lane::System as usize].running == 0 {
        assert!(Instant::now() < deadline, "the clear-history item never started");
        std::thread::yield_now();
    }
}

/// A connection closed by a bad message while one of its requests is
/// blocked does not wait for that request: after
/// `CONNECTION_SURFACE_SHUTDOWN_TIMEOUT` its client is gone, its socket
/// closed and its connection permit released, with the request still
/// blocked (the close is a delayed task on the line
/// sequence, not a wait).
#[test]
fn line_connection_a_dropped_connection_ends_after_the_shutdown_timeout() {
    let mux = Mux::new_for_test("line-conn-close-deadline", crate::SurfaceOptions::default());
    let surface = mux.new_workspace(None, Some((80, 24))).unwrap();
    let permit = claim_connection(mux.connection_stats()).expect("a connection permit");
    assert_eq!(mux.connection_stats().active(), 1);
    let (mut socket, server) = UnixStream::pair().unwrap();
    socket.set_read_timeout(Some(Duration::from_secs(10))).unwrap();
    let (ended, end) = std::sync::mpsc::channel();
    start_line_connection(LineStart {
        mux: mux.clone(),
        stream: Box::new(server),
        prefix: Vec::new(),
        render_service: Arc::new(RenderService::new()),
        permit: Some(permit),
        transport: ClientTransport::Unix,
        admission: Box::new(admission::LocalAdmission),
        frames: Box::<RequestFrames>::default(),
        on_end: Some(Box::new(move |end| {
            let _ = ended.send((end, Instant::now()));
        })),
    });
    let mut replies = BufReader::new(socket.try_clone().unwrap());
    socket.write_all(&ping(1)).unwrap();
    let mut line = String::new();
    replies.read_line(&mut line).unwrap();
    let client = *mux.control_clients.client_ids().first().expect("the connection's client");
    // The clear waits for the terminal lock held here for the whole test.
    let held = surface.with_terminal(|_| {
        socket.write_all(&clear_history(2, surface.id)).unwrap();
        wait_for_clear_to_run(&mux);
        // A frame on a connection without the grant: a bad message.
        socket.write_all(&request_frame(7, b"{}")).unwrap();
        let closed_at = Instant::now();
        let (end, at) = end.recv_timeout(Duration::from_secs(10)).expect("the connection ends");
        assert_eq!(
            end,
            ConnectionEnd::BadMessage(ConnectionBadMessage::Wire(BadMessage::FramesNotNegotiated))
        );
        let waited = at.duration_since(closed_at);
        assert!(
            waited + Duration::from_millis(100) >= CONNECTION_SURFACE_SHUTDOWN_TIMEOUT
                && waited < CONNECTION_SURFACE_SHUTDOWN_TIMEOUT + Duration::from_secs(2),
            "ended after {waited:?}"
        );
        assert_eq!(mux.connection_stats().active(), 0, "the permit is released");
        assert!(!mux.control_clients.client_ids().contains(&client), "the client is gone");
        let mut rest = Vec::new();
        replies.read_to_end(&mut rest).unwrap();
        assert!(
            mux.work.stats()[cmux_threads::work::Lane::System as usize].running > 0,
            "the clear is still blocked"
        );
    });
    assert!(held.is_some(), "a PTY surface");
    mux.close_surface(surface.id).unwrap();
}

/// A peer that closes after its requests gets every reply: the queued
/// requests drain first, then the connection ends as `PeerClosed`.
#[test]
fn line_connection_a_peer_close_drains_queued_requests_first() {
    let mut peer = connect("close-drains", None);
    let surface = peer.mux.new_workspace(None, Some((80, 24))).unwrap();
    peer.send(&ping(1));
    assert_eq!(peer.reply().unwrap()["id"], json!(1));
    let mux = peer.mux.clone();
    let held = surface.with_terminal(|_| {
        // Held on the terminal lock, the clear keeps the connection's
        // requests from settling; the pings after it queue.
        peer.send(&clear_history(2, surface.id));
        wait_for_clear_to_run(&mux);
        peer.send(&[ping(3), ping(4), ping(5)].concat());
        peer.socket.shutdown(Shutdown::Write).unwrap();
        std::thread::sleep(Duration::from_millis(300));
        assert!(!peer.served.is_finished(), "the close waits for the clear");
    });
    assert!(held.is_some(), "a PTY surface");
    let mut ids = Vec::new();
    while let Some(reply) = peer.reply() {
        ids.push(reply["id"].as_u64().expect("a reply id"));
    }
    ids.sort_unstable();
    assert_eq!(ids, [2, 3, 4, 5], "every queued request answered before the close");
    assert_eq!(peer.served.join().unwrap(), ConnectionEnd::PeerClosed);
    mux.close_surface(surface.id).unwrap();
}
