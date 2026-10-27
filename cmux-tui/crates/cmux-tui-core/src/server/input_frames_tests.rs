//! INPUT frames over a real socket pair (p05-ipc-078): the bytes reach the
//! terminal in order on their stream's sequence under the connection's
//! cause, nothing answers them and nothing parses them; an ended terminal
//! gives one `input-failed` until a write reaches a terminal again or the
//! stream is opened again; INPUT obeys a line's shutdown, handoff and remote
//! gates.

use std::collections::HashMap;
use std::io::Write;
use std::net::Shutdown;
use std::os::unix::net::UnixStream;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::mpsc::{self, Receiver, Sender};
use std::sync::{Arc, Mutex};
use std::thread::JoinHandle;
use std::time::Duration;

use cmux_ipc::{
    Aux, CallAux, CallFlags, FrameHeader, FrameKind, FrameReader, Message, MethodTables,
    ReaderLimits,
};
use serde_json::{Value, json};

use super::{CallRefusal, InputStreams, RequestFrames, StreamItem, StreamPostRefusal, StreamView};
use crate::SurfaceId;
use crate::diagnostics::IpcSnapshot;
use crate::event_cause::EventCause;
use crate::mux::DaemonHandoffRequest;
use crate::remote_relay_state::LinkPeer;
use crate::server::line_connection::{ConnectionBadMessage, ConnectionEnd, serve_connection};
use crate::server::*;

/// Open streams as attach-streams opens them, run on one FIFO worker (a
/// stream sequence), with the events each stream sent.
struct TestStreams {
    views: Mutex<HashMap<u16, StreamView>>,
    opens: AtomicU64,
    queue: Mutex<Option<Sender<StreamItem>>>,
    full: AtomicBool,
    events: Mutex<Vec<(u16, Value)>>,
}

impl TestStreams {
    fn start() -> (Arc<TestStreams>, JoinHandle<()>) {
        let (queue, items) = mpsc::channel::<StreamItem>();
        let streams = Arc::new(TestStreams {
            views: Mutex::new(HashMap::new()),
            opens: AtomicU64::new(0),
            queue: Mutex::new(Some(queue)),
            full: AtomicBool::new(false),
            events: Mutex::new(Vec::new()),
        });
        let worker = std::thread::spawn(move || {
            for item in items {
                item();
            }
        });
        (streams, worker)
    }

    /// Opens `stream` on `surface`: a new view, also when the id was open.
    fn open(&self, stream: u16, surface: SurfaceId) {
        let open = self.opens.fetch_add(1, Ordering::Relaxed) + 1;
        self.views.lock().unwrap().insert(stream, StreamView { surface, open });
    }

    /// Returns once every item queued before it ran.
    fn drain(&self) {
        let (ran, done) = mpsc::channel();
        let sender = self.queue.lock().unwrap().clone().unwrap();
        sender.send(Box::new(move || ran.send(()).unwrap())).unwrap();
        done.recv_timeout(Duration::from_secs(60)).expect("the stream drained");
    }

    fn events(&self) -> Vec<(u16, Value)> {
        self.events.lock().unwrap().clone()
    }

    fn stop(&self) {
        self.queue.lock().unwrap().take();
    }
}

impl InputStreams for TestStreams {
    fn view(&self, stream: u16) -> Option<StreamView> {
        self.views.lock().unwrap().get(&stream).copied()
    }

    fn post(&self, _stream: u16, item: StreamItem) -> Result<(), StreamPostRefusal> {
        if self.full.load(Ordering::Acquire) {
            return Err(StreamPostRefusal::Full);
        }
        let queue = self.queue.lock().unwrap();
        let sender = queue.as_ref().ok_or(StreamPostRefusal::Closed)?;
        sender.send(item).map_err(|_| StreamPostRefusal::Closed)
    }

    fn send_event(&self, stream: u16, event: &Value) {
        self.events.lock().unwrap().push((stream, event.clone()));
    }
}

struct Client {
    mux: Arc<Mux>,
    socket: UnixStream,
    read_half: UnixStream,
    reader: FrameReader,
    served: JoinHandle<ConnectionEnd>,
    streams: Arc<TestStreams>,
    worker: JoinHandle<()>,
}

fn input(stream: u16, flow: u64, bytes: &[u8]) -> Vec<u8> {
    let len = u32::try_from(bytes.len()).unwrap();
    let header = FrameHeader::new(FrameKind::Input, stream, len, Aux::FlowId(flow)).unwrap();
    let mut frame = header.encode().to_vec();
    frame.extend_from_slice(bytes);
    frame
}

fn ping(request_id: u32) -> Vec<u8> {
    let tables = MethodTables::schema();
    let method = tables.v12_id("ping").and_then(|id| tables.method(id)).unwrap();
    let body = json!({"cmd": "ping"}).to_string();
    let call = CallAux {
        request_id,
        method_id: method.id.raw(),
        priority: method.priority,
        flags: CallFlags::empty(),
    };
    let len = u32::try_from(body.len()).unwrap();
    let header = FrameHeader::new(FrameKind::Request, 0, len, Aux::Call(call)).unwrap();
    let mut frame = header.encode().to_vec();
    frame.extend_from_slice(body.as_bytes());
    frame
}

/// What the daemon sent next: a line (events skipped) or a frame header.
#[derive(Debug)]
enum Got {
    Line(Value),
    Frame(FrameHeader),
}

impl Client {
    /// A same-user local peer whose `set-client-info` declared frames.
    fn granted(label: &str) -> Client {
        let mux =
            Mux::new_for_test(format!("input-frames-{label}"), crate::SurfaceOptions::default());
        let (streams, worker) = TestStreams::start();
        let (socket, server) = UnixStream::pair().unwrap();
        let served_mux = mux.clone();
        let lane_streams: Arc<dyn InputStreams> = streams.clone();
        let served = std::thread::spawn(move || {
            let stream: Box<dyn transport::Stream> = Box::new(server);
            serve_connection(
                served_mux,
                stream,
                Arc::new(RenderService::new()),
                None,
                ClientTransport::Unix,
                &admission::LocalAdmission,
                &mut RequestFrames::with_streams(lane_streams),
            )
        });
        let read_half = socket.try_clone().unwrap();
        read_half.set_read_timeout(Some(Duration::from_secs(30))).unwrap();
        let mut reader = FrameReader::new(ReaderLimits::default());
        reader.negotiate_frames();
        let mut client = Client { mux, socket, read_half, reader, served, streams, worker };
        assert_eq!(client.line_reply(&json!({"id": 99, "cmd": "ping"}))["id"], json!(99));
        let id = client.client_id();
        client.mux.control_clients.ipc_transports.bind_all_for_test();
        origin_gate::set_peer_process_for_test(
            &client.mux,
            id,
            crate::request_origin::PeerProcess::SameUser,
        );
        let (current, _) = api_revision_wire::identify_fields();
        let granted = client.line_reply(&json!({
            "id": 1,
            "cmd": "set-client-info",
            "name": "input-frames",
            "capabilities": ["ipc-frames-v2"],
            "api_revision": current,
        }));
        assert_eq!(granted["ok"], json!(true), "{granted}");
        client
    }

    fn client_id(&self) -> u64 {
        let state = self.mux.control_clients.state.lock().unwrap();
        let mut unix = state
            .clients
            .iter()
            .filter(|(_, record)| matches!(record.transport, ClientTransport::Unix))
            .map(|(client, _)| *client);
        let client = unix.next().expect("the connection's client");
        assert_eq!(unix.next(), None, "one Unix client");
        client
    }

    fn send(&mut self, bytes: &[u8]) {
        self.socket.write_all(bytes).unwrap();
    }

    fn next(&mut self) -> Option<Got> {
        loop {
            match self.reader.next_message().unwrap() {
                Some(Message::Json(line)) if line.trim().is_empty() => {}
                Some(Message::Json(line)) => {
                    let value: Value = serde_json::from_str(line).unwrap();
                    if value.get("event").is_none() {
                        return Some(Got::Line(value));
                    }
                }
                Some(Message::Frame(frame)) => return Some(Got::Frame(*frame.header())),
                None => {
                    if self.reader.read_from(&mut self.read_half).unwrap() == 0 {
                        return None;
                    }
                }
            }
        }
    }

    fn line_reply(&mut self, body: &Value) -> Value {
        self.send(format!("{body}\n").as_bytes());
        match self.next() {
            Some(Got::Line(reply)) => reply,
            other => panic!("expected a line reply to {body}: {other:?}"),
        }
    }

    /// The next thing the daemon sends is ping `request_id`'s REPLY: no
    /// reply to anything sent before it came first.
    fn ping_is_next(&mut self, request_id: u32) {
        self.send(&ping(request_id));
        match self.next() {
            Some(Got::Frame(header)) => {
                assert_eq!(header.kind(), FrameKind::Reply);
                assert_eq!(header.call().unwrap().request_id, request_id);
            }
            other => panic!("expected ping {request_id}'s REPLY: {other:?}"),
        }
    }

    /// A terminal in a new workspace whose PTY input goes to `typed`.
    fn terminal(&self) -> (Arc<crate::Surface>, Receiver<Vec<u8>>) {
        let surface = self.mux.new_workspace(None, Some((80, 24))).unwrap();
        let typed = record_input(&surface);
        (surface, typed)
    }

    /// The respawn's delay of `surface`'s slot (terminal_respawn.rs): the
    /// mux has no runtime for its SurfaceId, so its terminal ended.
    fn detach(&self, surface: &crate::Surface) -> Arc<crate::Surface> {
        let terminal = surface.terminal_public_id().cloned().expect("a terminal");
        self.mux.remove_terminal_catalog_for_test(&terminal).expect("its catalog entry");
        let runtime = self.mux.remove_surface_runtime_for_test(surface.id).expect("its runtime");
        self.mux.unregister_kitty_image_surface(&runtime).unwrap();
        assert!(self.mux.surface(surface.id).is_none(), "the slot has no runtime");
        runtime
    }

    /// The terminal `id` respawned: a new runtime under the same SurfaceId
    /// (terminal_respawn.rs keeps the slot's id), recording its PTY input.
    fn respawned(&self, id: SurfaceId) -> (Arc<crate::Surface>, Receiver<Vec<u8>>) {
        let surface = crate::Surface::spawn_for_test(
            id,
            crate::SurfaceOptions::default(),
            Arc::downgrade(&self.mux),
        )
        .unwrap();
        let typed = record_input(&surface);
        self.mux.insert_surface_runtime_for_test(surface.clone());
        (surface, typed)
    }

    fn finish(self) -> ConnectionEnd {
        let _ = self.socket.shutdown(Shutdown::Write);
        let end = self.served.join().unwrap();
        self.streams.stop();
        self.worker.join().unwrap();
        end
    }
}

fn record_input(surface: &crate::Surface) -> Receiver<Vec<u8>> {
    let (written, typed) = mpsc::channel();
    surface.replace_input_writer_for_test(Box::new(InputRecorder { written, causes: None }));
    typed
}

/// The PTY input writer of a test terminal: each write is one message, with
/// the cause in force on the thread that wrote it when `causes` is set.
struct InputRecorder {
    written: Sender<Vec<u8>>,
    causes: Option<Sender<EventCause>>,
}

impl Write for InputRecorder {
    fn write(&mut self, bytes: &[u8]) -> std::io::Result<usize> {
        if let Some(causes) = &self.causes {
            let _ = causes.send(EventCause::current());
        }
        let _ = self.written.send(bytes.to_vec());
        Ok(bytes.len())
    }

    fn flush(&mut self) -> std::io::Result<()> {
        Ok(())
    }
}

fn failed(stream: u16, reason: &str, bytes: u64) -> Value {
    json!({"event": "input-failed", "stream": stream, "reason": reason, "bytes": bytes})
}

fn input_kind(ipc: &IpcSnapshot) -> u64 {
    ipc.received.iter().find(|row| row.kind == "input").map_or(0, |row| row.messages)
}

#[test]
fn input_frames_reach_the_terminal_in_order_with_no_reply_and_no_parse() {
    const KEYS: usize = 10_000;
    let mut client = Client::granted("order");
    let (surface, typed) = client.terminal();
    client.streams.open(7, surface.id);

    // What one framed ping costs, so the INPUT frames' share is what is left.
    let before = client.mux.ipc_stats().snapshot();
    client.ping_is_next(1);
    let one_ping = client.mux.ipc_stats().snapshot();
    let ping_parses = one_ping.parses.frames.json_parses - before.parses.frames.json_parses;

    let mut expected = String::new();
    for key in 0..KEYS {
        let line = format!("k{key:05}\n");
        expected.push_str(&line);
        client.send(&input(7, key as u64 + 1, line.as_bytes()));
    }
    // The reader cut every INPUT before this ping: no reply came before its own.
    client.ping_is_next(2);
    client.streams.drain();
    let after = client.mux.ipc_stats().snapshot();
    assert_eq!(input_kind(&after) - input_kind(&one_ping), KEYS as u64);
    assert_eq!(after.parses.frames.requests - one_ping.parses.frames.requests, 1, "only the ping");
    assert_eq!(
        after.parses.frames.json_parses - one_ping.parses.frames.json_parses,
        ping_parses,
        "an INPUT frame is never parsed"
    );
    assert_eq!(after.parses.lines.requests, one_ping.parses.lines.requests);
    assert_eq!(after.bad_message, 0);
    assert_eq!(client.streams.events(), [], "nothing failed");

    let written: Vec<u8> = typed.try_iter().flatten().collect();
    assert_eq!(String::from_utf8(written).unwrap(), expected, "the keys arrived out of order");
    assert_eq!(client.finish(), ConnectionEnd::PeerClosed);
}

#[test]
fn input_frames_an_ended_terminal_fails_once() {
    let mut client = Client::granted("ended");
    let (surface, typed) = client.terminal();
    client.streams.open(9, surface.id);
    client.send(&input(9, 1, b"before\n"));
    client.ping_is_next(1);
    client.streams.drain();
    assert_eq!(client.streams.events(), []);
    assert_eq!(typed.try_iter().flatten().collect::<Vec<u8>>(), b"before\n");

    surface.mark_dead_for_test();
    for key in [b"one".as_slice(), b"two", b"three"] {
        client.send(&input(9, 0, key));
    }
    client.ping_is_next(2);
    client.streams.drain();
    assert_eq!(client.streams.events(), [(9, failed(9, "terminal_ended", 3))]);
    // Later INPUT on the stream is dropped with no second event.
    client.send(&input(9, 0, b"four"));
    client.ping_is_next(3);
    client.streams.drain();
    assert_eq!(client.streams.events().len(), 1);
    assert_eq!(typed.try_iter().count(), 0, "nothing reached the ended terminal");
    assert_eq!(client.finish(), ConnectionEnd::PeerClosed);
}

#[test]
fn input_frames_a_full_stream_reports_what_it_dropped() {
    let mut client = Client::granted("full");
    let (surface, _typed) = client.terminal();
    client.streams.open(4, surface.id);
    client.streams.full.store(true, Ordering::Release);
    client.send(&input(4, 0, b"dropped"));
    client.ping_is_next(1);
    assert_eq!(client.streams.events(), [(4, failed(4, "stream_full", 7))]);
    assert_eq!(client.finish(), ConnectionEnd::PeerClosed);
}

#[test]
fn input_frames_on_an_unopened_stream_close_with_bad_message() {
    let mut client = Client::granted("unknown");
    client.send(&input(5, 0, b"x"));
    assert!(client.next().is_none(), "the daemon answered a bad message");
    assert_eq!(
        client.finish(),
        ConnectionEnd::BadMessage(ConnectionBadMessage::Call(CallRefusal::UnknownStream {
            stream: 5
        }))
    );
}

#[test]
fn input_frames_reach_a_respawned_terminal_under_the_same_surface_id() {
    let mut client = Client::granted("respawn");
    let (surface, _typed) = client.terminal();
    let id = surface.id;
    client.streams.open(7, id);

    // The respawn's delay: the slot has no runtime, so the terminal ended.
    let ended = client.detach(&surface);
    client.send(&input(7, 0, b"lost"));
    client.send(&input(7, 0, b"lost too"));
    client.ping_is_next(1);
    client.streams.drain();
    assert_eq!(client.streams.events(), [(7, failed(7, "terminal_ended", 4))]);

    let (respawned, typed) = client.respawned(id);
    client.send(&input(7, 0, b"typed\n"));
    client.ping_is_next(2);
    client.streams.drain();
    assert_eq!(
        typed.try_iter().flatten().collect::<Vec<u8>>(),
        b"typed\n",
        "the keys went nowhere"
    );
    assert_eq!(client.streams.events().len(), 1, "a delivered write sends no event");

    // The latch reset on that write: the next end is reported again.
    respawned.mark_dead_for_test();
    client.send(&input(7, 0, b"again"));
    client.ping_is_next(3);
    client.streams.drain();
    assert_eq!(client.streams.events()[1..], [(7, failed(7, "terminal_ended", 5))]);
    drop(ended);
    assert_eq!(client.finish(), ConnectionEnd::PeerClosed);
}

#[test]
fn input_frames_a_reopened_stream_on_the_same_surface_is_a_new_view() {
    let mut client = Client::granted("reopen");
    let (surface, _typed) = client.terminal();
    let id = surface.id;
    client.streams.open(7, id);
    let removed = client.detach(&surface);
    client.send(&input(7, 0, b"one"));
    client.ping_is_next(1);
    client.streams.drain();
    assert_eq!(client.streams.events(), [(7, failed(7, "terminal_ended", 3))]);

    // Stream-end, then the client opens id 7 on the same surface again: the
    // new view hears that its terminal ended.
    client.streams.open(7, id);
    client.send(&input(7, 0, b"two!"));
    client.ping_is_next(2);
    client.streams.drain();
    assert_eq!(client.streams.events()[1..], [(7, failed(7, "terminal_ended", 4))]);

    // Back on the reopened view, a live terminal takes the bytes.
    client.mux.insert_surface_runtime_for_test(removed);
    let typed = record_input(&surface);
    client.send(&input(7, 0, b"three"));
    client.ping_is_next(3);
    client.streams.drain();
    assert_eq!(typed.try_iter().flatten().collect::<Vec<u8>>(), b"three");
    assert_eq!(client.streams.events().len(), 2);
    assert_eq!(client.finish(), ConnectionEnd::PeerClosed);
}

#[test]
fn input_frames_run_under_the_connections_cause() {
    let mut client = Client::granted("cause");
    let (surface, _typed) = client.terminal();
    let (causes_tx, causes) = mpsc::channel();
    let (written, _written) = mpsc::channel();
    surface.replace_input_writer_for_test(Box::new(InputRecorder {
        written,
        causes: Some(causes_tx),
    }));
    client.streams.open(3, surface.id);
    let (_, expected) = client.mux.frame_client(client.client_id());
    assert_ne!(expected, EventCause::Program, "the connection has a cause of its own");
    client.send(&input(3, 0, b"x"));
    client.ping_is_next(1);
    client.streams.drain();
    assert_eq!(causes.try_iter().collect::<Vec<_>>(), [expected]);
    assert_eq!(client.finish(), ConnectionEnd::PeerClosed);
}

#[test]
fn input_frames_after_shutdown_requested_close_without_writing() {
    let mut client = Client::granted("shutdown");
    let (surface, typed) = client.terminal();
    client.streams.open(2, surface.id);
    client.mux.request_daemon_shutdown();
    client.send(&input(2, 0, b"rm -rf\n"));
    assert!(client.next().is_none(), "the connection closed");
    let end = client.finish();
    assert!(!matches!(end, ConnectionEnd::BadMessage(_)), "{end:?}");
    assert_eq!(typed.try_iter().count(), 0, "no input ran after the shutdown");
}

#[test]
fn input_frames_during_a_pending_handoff_are_refused_and_the_connection_stays() {
    let mut client = Client::granted("handoff");
    let (surface, typed) = client.terminal();
    client.streams.open(6, surface.id);
    let requester = client.client_id();
    client.mux.begin_daemon_handoff(requester, DaemonHandoffRequest::unfenced(true)).unwrap();
    client.send(&input(6, 0, b"held"));
    // A line meanwhile is refused too, and its refusal comes after the
    // INPUT was read: the INPUT's refusal is already recorded.
    let refused = client.line_reply(&json!({"id": 5, "cmd": "ping"}));
    assert_eq!(refused["ok"], json!(false), "{refused}");
    client.mux.cancel_daemon_handoff(requester);
    client.streams.drain();
    assert_eq!(client.streams.events(), [(6, failed(6, "daemon_handoff", 4))]);
    assert_eq!(typed.try_iter().count(), 0, "nothing was written during the handoff");

    client.send(&input(6, 0, b"after"));
    client.ping_is_next(2);
    client.streams.drain();
    assert_eq!(typed.try_iter().flatten().collect::<Vec<u8>>(), b"after");
    assert_eq!(client.finish(), ConnectionEnd::PeerClosed);
}

#[test]
fn input_frames_from_a_remote_relay_client_close_with_bad_message() {
    let mut client = Client::granted("remote");
    let (surface, typed) = client.terminal();
    client.streams.open(8, surface.id);
    let install = "install_input_frames";
    client.mux.record_remote_check(install).unwrap();
    let peer = LinkPeer { install: install.into(), user: "user_a".into(), team: "team_a".into() };
    client.mux.bind_remote_peer(client.client_id(), &peer).unwrap();
    assert!(client.mux.frame_client(client.client_id()).0, "classified remote");
    client.send(&input(8, 0, b"remote keys"));
    assert!(client.next().is_none(), "the daemon answered a bad message");
    assert_eq!(
        client.finish(),
        ConnectionEnd::BadMessage(ConnectionBadMessage::Call(CallRefusal::RemoteInput {
            stream: 8
        }))
    );
    assert_eq!(typed.try_iter().count(), 0, "no remote input reached the terminal");
}
