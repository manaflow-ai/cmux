//! The mux-io loop over real socket pairs: it cuts lines in order, writes
//! queued replies, pauses a connection's reads while its sink is full,
//! counts a write stall when a peer's buffer is full, closes a connection
//! whose peer stops reading once the write timeout passes, serves the
//! person's connection first, and starts its thread again after a failed
//! start.

use std::io::{self, BufRead, BufReader, Read, Write};
use std::os::unix::net::UnixStream;
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::mpsc::{Receiver, Sender, channel};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use cmux_ipc::{FrameReader, ReaderLimits};
use serde_json::json;

use super::{InboundSink, IoHandle, IoRegistration, LoopBody, MUX_IO_QOS, MUX_IO_THREAD, MuxIo};
use crate::diagnostics::IpcStats;
use crate::server::line_connection::{ConnectionEnd, Inbound};
use crate::server::{BoundedOutbound, MessageWriter, QueuedSink, RenderService, SinkControl};

/// A sink that records what it got and holds `room` messages at most.
struct Recording {
    lines: Mutex<Sender<Option<String>>>,
    held: AtomicUsize,
    room: usize,
    released: AtomicBool,
}

impl InboundSink for Recording {
    fn deliver(&self, message: Inbound) -> bool {
        let line = match message {
            Inbound::Line { text, .. } => Some(text),
            Inbound::Frame { .. } => Some("<frame>".to_owned()),
            Inbound::End(end) => {
                assert_eq!(end, ConnectionEnd::PeerClosed);
                None
            }
        };
        let _ = self.lines.lock().unwrap().send(line);
        self.held.fetch_add(1, Ordering::SeqCst) + 1 < self.room
    }

    fn released(&self) {
        self.released.store(true, Ordering::SeqCst);
    }

    fn is_person(&self) -> bool {
        false
    }
}

struct Served {
    io: MuxIo,
    handle: IoHandle,
    sink: Arc<Recording>,
    lines: Receiver<Option<String>>,
    outbound: Arc<BoundedOutbound>,
    writer: MessageWriter,
    ipc: Arc<IpcStats>,
    peer: UnixStream,
}

fn serve(room: usize) -> Served {
    serve_on(MuxIo::default(), room)
}

fn serve_on(io: MuxIo, room: usize) -> Served {
    let (sender, lines) = channel();
    let sink = Arc::new(Recording {
        lines: Mutex::new(sender),
        held: AtomicUsize::new(0),
        room,
        released: AtomicBool::new(false),
    });
    let Connected { handle, outbound, writer, ipc, peer } = connect(&io, sink.clone());
    Served { io, handle, sink, lines, outbound, writer, ipc, peer }
}

struct Connected {
    handle: IoHandle,
    outbound: Arc<BoundedOutbound>,
    writer: MessageWriter,
    ipc: Arc<IpcStats>,
    peer: UnixStream,
}

/// Serves a new socket pair's end on `io` into `sink`.
fn connect(io: &MuxIo, sink: Arc<dyn InboundSink>) -> Connected {
    let (peer, ours) = UnixStream::pair().unwrap();
    let control = ours.try_clone().unwrap();
    let outbound = Arc::new(BoundedOutbound::default());
    let writer = MessageWriter::new_with_render_service(
        QueuedSink {
            outbound: outbound.clone(),
            control: Some(SinkControl::Unix(Box::new(control))),
        },
        Arc::new(RenderService::new()),
    );
    let ipc = Arc::new(IpcStats::default());
    let handle = io.handle().unwrap();
    let registration = IoRegistration {
        stream: Box::new(ours),
        reader: FrameReader::new(ReaderLimits::default()),
        outbound: outbound.clone(),
        writer: writer.clone(),
        ipc: ipc.clone(),
        inbound: sink,
    };
    assert!(io.register(&handle, registration).is_ok());
    Connected { handle, outbound, writer, ipc, peer }
}

fn next_line(lines: &Receiver<Option<String>>) -> Option<String> {
    lines.recv_timeout(Duration::from_secs(10)).expect("a message within 10 s")
}

fn wait_until(what: &str, done: impl Fn() -> bool) {
    let deadline = Instant::now() + Duration::from_secs(10);
    while !done() {
        assert!(Instant::now() < deadline, "{what}");
        std::thread::sleep(Duration::from_millis(5));
    }
}

#[test]
fn lines_are_cut_in_order_and_replies_written() {
    let mut served = serve(usize::MAX);
    served.peer.write_all(b"{\"a\":1}\n{\"b\"").unwrap();
    assert_eq!(next_line(&served.lines).as_deref(), Some("{\"a\":1}\n"));
    served.peer.write_all(b":2}\n").unwrap();
    assert_eq!(next_line(&served.lines).as_deref(), Some("{\"b\":2}\n"));

    served.writer.send_control(&json!({"ok": true})).unwrap();
    let mut reader = BufReader::new(served.peer.try_clone().unwrap());
    reader.get_ref().set_read_timeout(Some(Duration::from_secs(10))).unwrap();
    let mut reply = String::new();
    reader.read_line(&mut reply).unwrap();
    assert_eq!(reply, "{\"ok\":true}\n");

    // The peer's close is the read side's end; the closed queue then
    // closes the socket and releases the connection.
    served.peer.shutdown(std::net::Shutdown::Write).unwrap();
    assert_eq!(next_line(&served.lines), None);
    assert!(!served.sink.released.load(Ordering::SeqCst), "the queue is still open");
    served.writer.close();
    wait_until("the connection is released", || served.sink.released.load(Ordering::SeqCst));
    let mut rest = Vec::new();
    reader.read_to_end(&mut rest).unwrap();
    assert!(rest.is_empty());
    drop(served.io);
}

#[test]
fn a_full_sink_pauses_reads_until_it_resumes() {
    let mut served = serve(2);
    served.peer.write_all(b"1\n2\n3\n").unwrap();
    assert_eq!(next_line(&served.lines).as_deref(), Some("1\n"));
    assert_eq!(next_line(&served.lines).as_deref(), Some("2\n"));
    assert!(
        served.lines.recv_timeout(Duration::from_millis(200)).is_err(),
        "the third line waits while the sink is full"
    );
    served.handle.resume_read();
    assert_eq!(next_line(&served.lines).as_deref(), Some("3\n"));
}

#[test]
fn a_peer_that_stops_reading_is_closed_after_the_write_timeout() {
    let served = serve(usize::MAX);
    served.outbound.set_write_timeout(Some(Duration::from_millis(100)));
    // Replies until the socket and its buffers are full; the peer reads
    // none of them.
    let text = "x".repeat(64 * 1024);
    let started = Instant::now();
    while served.writer.send_control(&json!({"fill": text})).is_ok() {
        assert!(started.elapsed() < Duration::from_secs(10), "the queue never filled");
        if !served.outbound.is_open() {
            break;
        }
    }
    wait_until("the stuck writer closes", || !served.writer.is_open());
    assert!(!served.outbound.is_open());
    // Its socket is shut down: the read side ends, and the connection is
    // released.
    assert_eq!(next_line(&served.lines), None);
    wait_until("the connection is released", || served.sink.released.load(Ordering::SeqCst));
}

/// Sends replies until the loop has written `stalls` write stalls; the peer
/// reads none of them.
fn fill_until_stalls(served: &Served, stalls: u64) {
    let text = "x".repeat(64 * 1024);
    let started = Instant::now();
    while served.ipc.snapshot().writes.stalls < stalls {
        assert!(started.elapsed() < Duration::from_secs(10), "no stall {stalls} counted");
        if served.writer.send_control(&json!({"fill": text})).is_err() {
            std::thread::sleep(Duration::from_millis(5));
        }
    }
}

#[test]
fn a_full_peer_buffer_counts_one_write_stall_per_wait() {
    let served = serve(usize::MAX);
    assert_eq!(served.ipc.snapshot().writes.stalls, 0);
    fill_until_stalls(&served, 1);
    // One wait for room is one stall, however many writes it holds back.
    std::thread::sleep(Duration::from_millis(100));
    assert_eq!(served.ipc.snapshot().writes.stalls, 1);
    // Once the peer drained it, a buffer that fills again is a new stall.
    let mut peer = served.peer.try_clone().unwrap();
    peer.set_nonblocking(true).unwrap();
    let mut buffer = vec![0; 1 << 20];
    let mut quiet_since = Instant::now();
    while quiet_since.elapsed() < Duration::from_millis(200) {
        match peer.read(&mut buffer) {
            Ok(read) if read > 0 => quiet_since = Instant::now(),
            _ => std::thread::sleep(Duration::from_millis(5)),
        }
    }
    fill_until_stalls(&served, 2);
}

/// Delivers each message by reporting its sink's name. A sink with a hold
/// reports `entered` at its first delivery, then waits for the hold.
struct Named {
    name: &'static str,
    person: bool,
    order: Mutex<Sender<&'static str>>,
    hold: Mutex<Option<Receiver<()>>>,
}

impl Named {
    fn new(name: &'static str, person: bool, order: &Sender<&'static str>) -> Arc<Self> {
        Arc::new(Named { name, person, order: Mutex::new(order.clone()), hold: Mutex::new(None) })
    }
}

impl InboundSink for Named {
    fn deliver(&self, _message: Inbound) -> bool {
        let hold = self.hold.lock().unwrap().take();
        if let Some(hold) = hold {
            let _ = self.order.lock().unwrap().send("entered");
            hold.recv_timeout(Duration::from_secs(10)).expect("the hold's signal");
        }
        let _ = self.order.lock().unwrap().send(self.name);
        true
    }

    fn released(&self) {}

    fn is_person(&self) -> bool {
        self.person
    }
}

/// The loop watches the connection once a reply it wrote comes back.
fn round_trip(connected: &Connected) {
    connected.writer.send_control(&json!({"ready": true})).unwrap();
    let mut reader = BufReader::new(connected.peer.try_clone().unwrap());
    reader.get_ref().set_read_timeout(Some(Duration::from_secs(10))).unwrap();
    let mut reply = String::new();
    reader.read_line(&mut reply).unwrap();
    assert_eq!(reply, "{\"ready\":true}\n");
}

/// Two sockets ready in one turn: the person's is read first, though
/// automation's became ready first.
#[test]
fn the_persons_connection_is_served_first_in_a_turn() {
    let io = MuxIo::default();
    let (order, names) = channel();
    let blocker = Named::new("blocker", false, &order);
    let (release, hold) = channel();
    *blocker.hold.lock().unwrap() = Some(hold);
    let mut blocking = connect(&io, blocker);
    let mut automation = connect(&io, Named::new("automation", false, &order));
    let mut person = connect(&io, Named::new("person", true, &order));
    for connected in [&blocking, &automation, &person] {
        round_trip(connected);
    }
    // The loop is held inside the blocker's delivery while both sockets
    // become ready, automation's first.
    blocking.peer.write_all(b"1\n").unwrap();
    let next = || names.recv_timeout(Duration::from_secs(10)).expect("a delivery");
    assert_eq!(next(), "entered");
    automation.peer.write_all(b"2\n").unwrap();
    person.peer.write_all(b"3\n").unwrap();
    std::thread::sleep(Duration::from_millis(50));
    release.send(()).unwrap();
    assert_eq!(next(), "blocker");
    assert_eq!([next(), next()], ["person", "automation"]);
}

/// A loop thread that could not start (EAGAIN) leaves nothing behind: the
/// next connection starts it and is served.
#[test]
fn a_loop_thread_that_failed_to_start_is_started_by_the_next_connection() {
    let attempts = Arc::new(AtomicUsize::new(0));
    let spawner = {
        let attempts = attempts.clone();
        Arc::new(move |body: LoopBody| {
            if attempts.fetch_add(1, Ordering::SeqCst) == 0 {
                return Err(io::Error::from(io::ErrorKind::WouldBlock));
            }
            cmux_threads::spawn(MUX_IO_THREAD, MUX_IO_QOS, body).map(drop)
        })
    };
    let io = MuxIo::with_spawner(spawner);
    assert!(io.handle().is_err(), "the first start fails");
    let mut served = serve_on(io, usize::MAX);
    served.peer.write_all(b"{\"a\":1}\n").unwrap();
    assert_eq!(next_line(&served.lines).as_deref(), Some("{\"a\":1}\n"));
    assert_eq!(attempts.load(Ordering::SeqCst), 2, "one more start");
    let _again = served.io.handle().unwrap();
    assert_eq!(attempts.load(Ordering::SeqCst), 2, "a running loop starts no other");
}
