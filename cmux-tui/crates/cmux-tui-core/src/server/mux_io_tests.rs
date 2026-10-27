//! The mux-io loop over real socket pairs: it cuts lines in order, writes
//! queued replies, pauses a connection's reads while its sink is full, and
//! closes a connection whose peer stops reading once the write timeout
//! passes.

use std::io::{BufRead, BufReader, Read, Write};
use std::os::unix::net::UnixStream;
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::mpsc::{Receiver, Sender, channel};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use cmux_ipc::{FrameReader, ReaderLimits};
use serde_json::json;

use super::{InboundSink, IoHandle, IoRegistration, MuxIo};
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
}

struct Served {
    io: MuxIo,
    handle: IoHandle,
    sink: Arc<Recording>,
    lines: Receiver<Option<String>>,
    outbound: Arc<BoundedOutbound>,
    writer: MessageWriter,
    peer: UnixStream,
}

fn serve(room: usize) -> Served {
    let (peer, ours) = UnixStream::pair().unwrap();
    let (sender, lines) = channel();
    let sink = Arc::new(Recording {
        lines: Mutex::new(sender),
        held: AtomicUsize::new(0),
        room,
        released: AtomicBool::new(false),
    });
    let control = ours.try_clone().unwrap();
    let outbound = Arc::new(BoundedOutbound::default());
    let writer = MessageWriter::new_with_render_service(
        QueuedSink {
            outbound: outbound.clone(),
            control: Some(SinkControl::Unix(Box::new(control))),
        },
        Arc::new(RenderService::new()),
    );
    let io = MuxIo::default();
    let handle = io.handle().unwrap();
    let registration = IoRegistration {
        stream: Box::new(ours),
        reader: FrameReader::new(ReaderLimits::default()),
        outbound: outbound.clone(),
        writer: writer.clone(),
        ipc: Arc::new(IpcStats::default()),
        inbound: sink.clone(),
    };
    assert!(io.register(&handle, registration).is_ok());
    Served { io, handle, sink, lines, outbound, writer, peer }
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
