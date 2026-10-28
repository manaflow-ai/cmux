//! The IO reactor's frame path over real accepted sockets (p05-ipc-155):
//! a granted connection's frames are routed in order, on the reactor for
//! the person's connection and on the session's task for automation; a
//! frame gate behind more than one batch of lines opens frames; a panicking
//! handler ends only its own connection; the person's keys reach their
//! stream while every control worker is busy; and once the reactor thread
//! ended, new connections are served on threads of their own.

use std::io::Write;
use std::net::Shutdown;
use std::os::unix::net::UnixStream;
use std::sync::mpsc;
use std::time::{Duration, Instant};

use cmux_ipc::{
    Aux, CallAux, CallFlags, FrameHeader, FrameKind, FrameReader, Message, ReaderLimits,
};
use serde_json::{Value, json};

use super::tests::{Client, Served, mux_conn_threads, ping, threads_named};
use super::{IoReactor, MAX_BATCH};
use crate::server::VIEW_ATTACHMENT_LEASE_CAPABILITY;
use crate::server::connection_scheduler::connection_qos::ConnectionClass;
use crate::server::frame_dispatch::RequestFrames;
use crate::server::frame_dispatch::tests::{method, request};
use crate::server::sequenced_pool::SequencePriority;
use crate::server::*;
use crate::surface::PtyInputCapture;

const WAIT: Duration = Duration::from_secs(10);

/// What a framed client reads: a reply line, or the REPLY or ERROR frame of
/// a request. Events and other frames (attach output) are skipped.
#[derive(Debug)]
enum Answer {
    Line(Value),
    Call { kind: FrameKind, stream: u16, request_id: u32, body: Value },
}

impl Answer {
    fn request_id(&self) -> Option<u32> {
        match self {
            Answer::Call { request_id, .. } => Some(*request_id),
            Answer::Line(_) => None,
        }
    }
}

/// A connection served by the reactor whose `set-client-info` was granted
/// frames.
struct FramedClient {
    socket: UnixStream,
    read_half: UnixStream,
    reader: FrameReader,
    client: u64,
}

impl FramedClient {
    fn send(&mut self, bytes: &[u8]) {
        self.socket.write_all(bytes).unwrap();
    }

    fn line(&mut self, value: &Value) {
        self.send(format!("{value}\n").as_bytes());
    }

    /// The next answer; `None` once the daemon closed.
    fn answer(&mut self) -> Option<Answer> {
        loop {
            match self.reader.next_message().unwrap() {
                Some(Message::Json(line)) if line.trim().is_empty() => {}
                Some(Message::Json(line)) => {
                    let value: Value = serde_json::from_str(line).unwrap();
                    if value.get("event").is_none() {
                        return Some(Answer::Line(value));
                    }
                }
                Some(Message::Frame(frame)) => {
                    let header = *frame.header();
                    if let Some(call) = header.call() {
                        return Some(Answer::Call {
                            kind: header.kind(),
                            stream: header.stream(),
                            request_id: call.request_id,
                            body: serde_json::from_slice(frame.payload()).unwrap(),
                        });
                    }
                }
                None => match self.reader.read_from(&mut self.read_half) {
                    Ok(0) | Err(_) => return None,
                    Ok(_) => {}
                },
            }
        }
    }

    /// Every answer up to the last of `request_ids`, in arrival order.
    fn until(&mut self, request_ids: &[u32]) -> Vec<Answer> {
        let mut answers = Vec::new();
        let mut left: Vec<u32> = request_ids.to_vec();
        while !left.is_empty() {
            let answer = self.answer().expect("the daemon closed before every answer");
            left.retain(|id| Some(*id) != answer.request_id());
            answers.push(answer);
        }
        answers
    }

    /// The daemon closed the connection: nothing more is read.
    fn closed(&mut self) -> bool {
        let deadline = Instant::now() + WAIT;
        while Instant::now() < deadline {
            if self.answer().is_none() {
                return true;
            }
        }
        false
    }
}

impl Served {
    /// A session whose reactor routes frames with `frames`' lanes.
    fn with_frames(label: &str, frames: fn() -> RequestFrames) -> Self {
        let mut served = Served::new(label);
        served.session.reactor = Some(Arc::new(IoReactor::start_with(frames).unwrap()));
        served
    }

    /// A connection granted frames, put in `class` (as the hello or
    /// `set-client-info` of the app or of the CLI puts it).
    fn framed(&self, class: ConnectionClass) -> FramedClient {
        let known = self.mux.control_clients.client_ids();
        let socket = UnixStream::connect(&self.path).unwrap();
        self.session.serve(self.listener.accept().unwrap());
        let read_half = socket.try_clone().unwrap();
        read_half.set_read_timeout(Some(WAIT)).unwrap();
        let mut reader = FrameReader::new(ReaderLimits::default());
        reader.negotiate_frames();
        let mut client = FramedClient { socket, read_half, reader, client: 0 };
        client.line(&json!({"id": 99, "cmd": "ping"}));
        assert!(matches!(client.answer(), Some(Answer::Line(reply)) if reply["id"] == json!(99)));
        client.client = self
            .mux
            .control_clients
            .client_ids()
            .into_iter()
            .find(|id| !known.contains(id))
            .expect("the connection's client");
        self.mux.control_clients.ipc_transports.bind_all_for_test();
        origin_gate::set_peer_process_for_test(
            &self.mux,
            client.client,
            crate::request_origin::PeerProcess::SameUser,
        );
        let (current, _) = api_revision_wire::identify_fields();
        client.line(&json!({
            "id": 1,
            "cmd": "set-client-info",
            "name": "frames",
            "capabilities": ["ipc-frames-v2", VIEW_ATTACHMENT_LEASE_CAPABILITY],
            "api_revision": current,
        }));
        match client.answer() {
            Some(Answer::Line(reply)) => assert_eq!(reply["ok"], json!(true), "{reply}"),
            other => panic!("set-client-info: {other:?}"),
        }
        self.mux.control_clients.connection_class(client.client).set(class);
        client
    }

    /// Waits until `client` left the registry.
    fn wait_disconnected(&self, client: u64) {
        let deadline = Instant::now() + WAIT;
        while self.mux.control_clients.client_ids().contains(&client) {
            assert!(Instant::now() < deadline, "client {client} was never disconnected");
            std::thread::sleep(Duration::from_millis(5));
        }
    }
}

/// A REQUEST frame for `body` on `stream`.
fn stream_request(stream: u16, request_id: u32, body: &Value) -> Vec<u8> {
    let method = method(body["cmd"].as_str().unwrap());
    let payload = body.to_string();
    let aux = Aux::Call(CallAux {
        request_id,
        method_id: method.id.raw(),
        priority: method.priority,
        flags: CallFlags::empty(),
    });
    let header =
        FrameHeader::new(FrameKind::Request, stream, u32::try_from(payload.len()).unwrap(), aux)
            .unwrap();
    let mut bytes = header.encode().to_vec();
    bytes.extend_from_slice(payload.as_bytes());
    bytes
}

/// An INPUT frame of `payload` on `stream`.
fn input(stream: u16, payload: &[u8]) -> Vec<u8> {
    let header = FrameHeader::new(
        FrameKind::Input,
        stream,
        u32::try_from(payload.len()).unwrap(),
        Aux::FlowId(0),
    )
    .unwrap();
    let mut bytes = header.encode().to_vec();
    bytes.extend_from_slice(payload);
    bytes
}

fn attach(surface: u64) -> Value {
    json!({"cmd": "attach-surface", "surface": surface})
}

fn written(capture: &PtyInputCapture) -> String {
    String::from_utf8(capture.written()).unwrap()
}

fn position(answers: &[Answer], request_id: u32) -> usize {
    answers
        .iter()
        .position(|answer| answer.request_id() == Some(request_id))
        .unwrap_or_else(|| panic!("no answer to {request_id}: {answers:?}"))
}

/// REQUEST frames on stream 0 and on a stream the connection opens, and
/// INPUT frames on that stream, all in one write right after the grant:
/// every request is answered as a REPLY on its stream, in order, and the
/// stream's input reaches the PTY in order with its requests.
fn granted_frames_are_routed_in_order(label: &str, class: ConnectionClass) {
    let served = Served::new(label);
    let mut client = served.framed(class);
    let surface = served.mux.new_workspace(None, Some((80, 24))).unwrap();
    let capture = surface.capture_pty_input_for_test();
    let mut bytes = request(2, &json!({"cmd": "ping"}));
    bytes.extend(stream_request(7, 10, &attach(surface.id)));
    bytes.extend(input(7, b"alpha\r"));
    bytes.extend(stream_request(
        7,
        11,
        &json!({"cmd": "send", "surface": surface.id, "text": "bravo\r"}),
    ));
    bytes.extend(input(7, b"charlie\r"));
    bytes.extend(stream_request(7, 12, &json!({"cmd": "send", "surface": surface.id, "text": ""})));
    bytes.extend(request(3, &json!({"cmd": "ping"})));
    client.send(&bytes);

    let answers = client.until(&[2, 3, 10, 11, 12]);
    for (request_id, expected_stream) in [(2, 0), (3, 0), (10, 7), (11, 7), (12, 7)] {
        let answer = &answers[position(&answers, request_id)];
        assert!(
            matches!(answer, Answer::Call { kind: FrameKind::Reply, stream, body, .. }
                if *stream == expected_stream && body["ok"] == json!(true)),
            "{answer:?}"
        );
    }
    assert!(position(&answers, 2) < position(&answers, 3), "{answers:?}");
    assert!(position(&answers, 10) < position(&answers, 11), "{answers:?}");
    assert!(position(&answers, 11) < position(&answers, 12), "{answers:?}");
    assert_eq!(written(&capture), "alpha\rbravo\rcharlie\r");
    assert_eq!(served.mux.ipc_stats().snapshot().bad_message, 0);
}

/// The person's connection: the reactor routes its frames.
#[test]
fn io_reactor_routes_a_person_connections_frames_in_order() {
    granted_frames_are_routed_in_order("frames-person", ConnectionClass::Person);
}

/// An automation connection: its frames route on its session's task.
#[test]
fn io_reactor_routes_an_automation_connections_frames_in_order() {
    granted_frames_are_routed_in_order("frames-automation", ConnectionClass::Automation);
}

/// More lines than one session task takes, then the connection's first
/// frame: the frame gate comes in a later batch than the first, the
/// session opens frames there, and the frames and lines after it are cut
/// and answered in order.
fn a_frame_gate_behind_a_batch_of_lines_opens_frames(label: &str, class: ConnectionClass) {
    let served = Served::new(label);
    let mut client = served.framed(class);
    let lines = MAX_BATCH as u64 + 36;
    let mut bytes = Vec::new();
    for id in 0..lines {
        bytes.extend(ping(100 + id));
    }
    bytes.extend(request(5, &json!({"cmd": "ping"})));
    bytes.extend(ping(500));
    bytes.extend(request(6, &json!({"cmd": "ping"})));
    client.send(&bytes);
    for id in 0..lines {
        match client.answer() {
            Some(Answer::Line(reply)) => assert_eq!(reply["id"], json!(100 + id), "{reply}"),
            other => panic!("line {id}: {other:?}"),
        }
    }
    let next = client.answer();
    assert!(matches!(next, Some(Answer::Call { request_id: 5, .. })), "{next:?}");
    let next = client.answer();
    assert!(matches!(&next, Some(Answer::Line(reply)) if reply["id"] == json!(500)), "{next:?}");
    let next = client.answer();
    assert!(matches!(next, Some(Answer::Call { request_id: 6, .. })), "{next:?}");
    assert_eq!(served.mux.ipc_stats().snapshot().bad_message, 0);
}

#[test]
fn io_reactor_a_frame_gate_behind_a_batch_of_lines_opens_frames_on_the_task() {
    a_frame_gate_behind_a_batch_of_lines_opens_frames(
        "gate-automation",
        ConnectionClass::Automation,
    );
}

#[test]
fn io_reactor_a_frame_gate_behind_a_batch_of_lines_opens_frames_for_the_person() {
    a_frame_gate_behind_a_batch_of_lines_opens_frames("gate-person", ConnectionClass::Person);
}

/// A frame handler that panics ends only its own connection: the client
/// reads the end of the stream and is disconnected, while the other
/// connections and a new one are still served by the reactor.
fn a_panicking_handler_ends_only_its_connection(label: &str, class: ConnectionClass) {
    let served = Served::with_frames(label, RequestFrames::panicking);
    let mut other = served.connect();
    other.ping(1);
    let mut victim = served.framed(class);
    served.wait_connections(2);
    victim.send(&request(7, &json!({"cmd": "ping"})));
    assert!(victim.closed(), "the panicked connection closes");
    served.wait_disconnected(victim.client);
    served.wait_connections(1);
    other.ping(2);
    let mut late = served.connect();
    late.ping(3);
    assert!(served.reactor().is_alive(), "the reactor runs on");
    served.wait_connections(2);
}

/// The panic is on the reactor: it routes the person's frames.
#[test]
fn io_reactor_a_handler_panic_on_the_reactor_ends_only_its_connection() {
    a_panicking_handler_ends_only_its_connection("panic-reactor", ConnectionClass::Person);
}

/// The panic is on the connection's session task.
#[test]
fn io_reactor_a_handler_panic_on_a_session_task_ends_only_its_connection() {
    a_panicking_handler_ends_only_its_connection("panic-task", ConnectionClass::Automation);
}

/// A key reaches its stream while every control worker of the pool is busy
/// (automation's requests, here tasks that wait for the test): no control
/// worker is on its path. A key that waited on the connection's control
/// sequence reached the PTY only once a control worker was free.
fn a_key_reaches_its_stream_while_every_control_worker_is_busy(
    label: &str,
    class: ConnectionClass,
) {
    let served = Served::new(label);
    let mut client = served.framed(class);
    let surface = served.mux.new_workspace(None, Some((80, 24))).unwrap();
    let capture = surface.capture_pty_input_for_test();
    client.send(&stream_request(7, 10, &attach(surface.id)));
    client.until(&[10]);

    let pool = &served.mux.sequenced_pool;
    let workers = pool.config().workers(SequencePriority::Control);
    let (started_tx, started_rx) = mpsc::channel();
    let mut releases = Vec::new();
    let mut busy = Vec::new();
    for _ in 0..workers {
        let sequence = pool.sequence(SequencePriority::Control);
        let (release_tx, release_rx) = mpsc::channel::<()>();
        let started = started_tx.clone();
        sequence
            .post(move || {
                started.send(()).unwrap();
                let _ = release_rx.recv();
            })
            .unwrap();
        releases.push(release_tx);
        busy.push(sequence);
    }
    for _ in 0..workers {
        started_rx.recv_timeout(WAIT).expect("every control worker runs a task");
    }

    let sent = Instant::now();
    client.send(&input(7, b"key\r"));
    let deadline = sent + Duration::from_secs(2);
    while written(&capture) != "key\r" {
        assert!(Instant::now() < deadline, "the key waited for a control worker");
        std::thread::sleep(Duration::from_millis(1));
    }
    let latency = sent.elapsed();
    drop(releases);
    client.send(&request(4, &json!({"cmd": "ping"})));
    client.until(&[4]);
    assert!(latency < Duration::from_secs(2), "{latency:?}");
}

/// The person's connection: the reactor routes the key, and the
/// connection's own tasks run on the input workers.
#[test]
fn io_reactor_routes_the_persons_key_while_every_control_worker_is_busy() {
    a_key_reaches_its_stream_while_every_control_worker_is_busy(
        "key-busy-person",
        ConnectionClass::Person,
    );
}

/// A connection not classed yet (the app's before its hello): its tasks
/// run on the control workers, so only the reactor's route gets the key
/// through.
#[test]
fn io_reactor_routes_an_unclassed_connections_key_while_every_control_worker_is_busy() {
    a_key_reaches_its_stream_while_every_control_worker_is_busy(
        "key-busy-unclassed",
        ConnectionClass::Unclassified,
    );
}

/// Once the reactor thread ended (here a panic outside any connection), its
/// connections close and every new connection is served on a reader thread
/// of its own: one the session accepts after, and one whose start found the
/// reactor gone.
#[test]
fn io_reactor_a_reactor_that_ended_hands_new_connections_to_threads() {
    let _threads = mux_conn_threads();
    let served = Served::new("ended");
    let mut held = served.connect();
    held.ping(1);
    served.reactor().panic_for_test();
    let deadline = Instant::now() + WAIT;
    while served.reactor().is_alive() {
        assert!(Instant::now() < deadline, "the reactor thread never ended");
        std::thread::sleep(Duration::from_millis(5));
    }
    assert_eq!(held.reply(), None, "the reactor's connections close with it");

    let mut late = served.connect();
    late.ping(2);
    assert!(threads_named("mux-conn") >= 1, "a reader thread serves it");

    let socket = UnixStream::connect(&served.path).unwrap();
    let permit = claim_connection(served.mux.connection_stats()).expect("a connection slot");
    served.reactor().serve(
        served.mux.clone(),
        served.listener.accept().unwrap(),
        Arc::new(RenderService::new()),
        permit,
    );
    let mut raced = Client::over(socket);
    raced.ping(3);
    late.ping(4);
    for client in [&late, &raced] {
        client.socket.shutdown(Shutdown::Both).unwrap();
    }
}
