//! Capability bits (pty-holder.md section 2.1): TRACE_CONTROL, WRITE_FLOW
//! and HANG_REPORT, granted in WELCOME, wire version still 5.
//!
//! The conformance corpus below is the byte-exact form of every exchange
//! the bits add (tests/hang_report.rs covers HANG_REPORT's grant). A holder whose tracer records answers the recorded
//! HELLO with the recorded WELCOME, one without a tracer grants only
//! WRITE_FLOW; a daemon that asks for nothing (an older build) is granted
//! nothing, and a frame of a capability a link was not granted is an
//! unknown kind to it, as to a holder that predates the bit.

#![cfg(unix)]

use std::io::Write;
use std::os::fd::AsRawFd;
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::Path;
use std::sync::mpsc::{Sender, channel};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use cmux_holder::client::{HolderClient, launch, launch_with};
use cmux_holder::holder::{Holder, ProcessTrace, TraceControl, error_code};
use cmux_holder::link::{HolderLink, TerminalSink, TraceForward};
use cmux_holder::wire::{self, In, Kind, Out, TraceStart, capability};
use cmux_holder::{ExitStatus, SpawnRequest};

mod support;

const TOKEN: [u8; 32] = [0x11; 32];

fn holder_binary() -> &'static Path {
    Path::new(env!("CARGO_BIN_EXE_cmux-holder"))
}

fn hex(text: &str) -> Vec<u8> {
    let digits: Vec<u8> = text.bytes().filter(u8::is_ascii_hexdigit).collect();
    digits
        .chunks(2)
        .map(|pair| u8::from_str_radix(std::str::from_utf8(pair).unwrap(), 16).unwrap())
        .collect()
}

/// HELLO, version 5, token `11` x 32, wanted TRACE_CONTROL | WRITE_FLOW.
fn corpus_hello() -> Vec<u8> {
    let mut bytes = hex("434d4858 0100 0000 00000000 26000000 0500");
    bytes.extend_from_slice(&TOKEN);
    bytes.extend_from_slice(&hex("03000000"));
    bytes
}
/// WELCOME, version 5, no terminal, granted TRACE_CONTROL | WRITE_FLOW.
const CORPUS_WELCOME: &str = "434d4858 0200 0000 00000000 0a000000 0500 00000000 03000000";
/// WELCOME of a holder whose tracer does not run: granted WRITE_FLOW only.
const CORPUS_WELCOME_UNTRACED: &str = "434d4858 0200 0000 00000000 0a000000 0500 00000000 02000000";
/// WELCOME to a daemon that asked for nothing: granted 0.
const CORPUS_WELCOME_NONE: &str = "434d4858 0200 0000 00000000 0a000000 0500 00000000 00000000";
/// TRACE_START: categories 0x4400 (FRAME | INPUT), a budget of 16 MiB of
/// ring bytes (room for the holder's recording ring).
const CORPUS_TRACE_START: &str =
    "434d4858 1600 0000 00000000 10000000 0044000000000000 0000000100000000";
const CORPUS_BUDGET: u64 = 16 << 20;
/// TRACE_STOP.
const CORPUS_TRACE_STOP: &str = "434d4858 1700 0000 00000000 00000000";
/// WRITE with FLAG_FLOW on channel 7: `ls\r`, then flow 42.
const CORPUS_WRITE_FLOW: &str = "434d4858 0900 0400 07000000 0b000000 6c730d 2a00000000000000";
/// WRITE with FLAG_FLOW and no input: a flow mark for input written on the
/// daemon's custody master.
const CORPUS_FLOW_MARK: &str = "434d4858 0900 0400 07000000 08000000 2a00000000000000";
/// HANG (HANG_REPORT): a `holder-loop` pass busy 153 ms past its 100 ms.
const CORPUS_HANG: &str =
    "434d4858 1800 0000 00000000 1b000000 6400000000000000 9900000000000000 686f6c6465722d6c6f6f70";

#[test]
fn the_corpus_is_what_this_build_encodes() {
    assert_eq!(
        wire::encode(Kind::Hello, 0, &Out::default().u16(5).bytes(&TOKEN).u32(3).0),
        corpus_hello()
    );
    assert_eq!(
        wire::encode(Kind::Welcome, 0, &Out::default().u16(5).u32(0).u32(3).0),
        hex(CORPUS_WELCOME)
    );
    let start = TraceStart { categories: 0x4400, budget_bytes: CORPUS_BUDGET };
    assert_eq!(wire::encode(Kind::TraceStart, 0, &start.encode()), hex(CORPUS_TRACE_START));
    assert!(
        ProcessTrace::recording_bytes() <= CORPUS_BUDGET,
        "a real holder takes the corpus budget: its ring is {} bytes",
        ProcessTrace::recording_bytes()
    );
    assert_eq!(TraceStart::decode(&start.encode()).unwrap(), start);
    assert_eq!(wire::encode(Kind::TraceStop, 0, &[]), hex(CORPUS_TRACE_STOP));
    let write = wire::write_flow_payload(b"ls\r", 42);
    assert_eq!(
        wire::encode_flagged(Kind::Write, wire::FLAG_FLOW, 7, &write),
        hex(CORPUS_WRITE_FLOW)
    );
    assert_eq!(wire::split_write(wire::FLAG_FLOW, &write).unwrap(), (&b"ls\r"[..], Some(42)));
    let mark = wire::write_flow_payload(b"", 42);
    assert_eq!(wire::encode_flagged(Kind::Write, wire::FLAG_FLOW, 7, &mark), hex(CORPUS_FLOW_MARK));
    // Without the flag the 8 bytes are input; a flagged payload shorter
    // than the trailer is malformed.
    assert_eq!(wire::split_write(0, &write).unwrap(), (&write[..], None));
    assert!(wire::split_write(wire::FLAG_FLOW, b"short").is_err());
    let hang = wire::HangReport { deadline_ms: 100, busy_ms: 153, site: "holder-loop".into() };
    assert_eq!(wire::encode(Kind::Hang, 0, &hang.encode()), hex(CORPUS_HANG));
    // The values are frozen.
    assert_eq!((capability::TRACE_CONTROL, capability::WRITE_FLOW), (1, 2));
    assert_eq!((capability::HANG_REPORT, Kind::Hang as u16), (4, 24));
    assert_eq!((Kind::TraceStart as u16, Kind::TraceStop as u16, wire::FLAG_FLOW), (22, 23, 4));
    assert_eq!(wire::VERSION, 5, "capability bits need no new wire version");
}

/// Read one frame from a raw daemon socket, failing after 10 s.
fn read_frame(stream: &UnixStream, reader: &mut wire::Reader) -> wire::Frame {
    let deadline = Instant::now() + Duration::from_secs(10);
    stream.set_read_timeout(Some(Duration::from_secs(10))).unwrap();
    loop {
        if let Some(frame) = reader.next_frame().unwrap() {
            return frame;
        }
        assert!(Instant::now() < deadline, "the holder sent nothing");
        assert!(reader.fill(stream.as_raw_fd()).unwrap(), "the holder closed the link");
    }
}

fn raw_frame(frame: &wire::Frame) -> Vec<u8> {
    let kind = Kind::from_u16(frame.kind).unwrap();
    wire::encode_flagged(kind, frame.flags, frame.chan, &frame.payload)
}

/// The ERROR a frame got: (request kind, code).
fn refused(stream: &UnixStream, reader: &mut wire::Reader) -> (u16, u16) {
    let error = read_frame(stream, reader);
    assert_eq!(error.kind, Kind::Error as u16);
    let mut input = In(&error.payload);
    (input.u16().unwrap(), input.u16().unwrap())
}

/// The shipped holder binary starts its black box,
/// so it answers the corpus HELLO granting both bits and takes the corpus
/// TRACE_START and TRACE_STOP. The HELLO of a daemon older than the bits
/// (no `wanted` field) is granted nothing: a TRACE_START there is an
/// unknown kind.
#[test]
fn the_holder_grants_what_was_asked_and_an_older_daemon_gets_nothing() {
    let dir = support::unique_dir("cmhc");
    let socket = dir.join("h.sock");
    let mut holder = launch(holder_binary(), &socket, &TOKEN).unwrap();

    let asking = UnixStream::connect(&socket).unwrap();
    let mut reader = wire::Reader::default();
    wire::send_all(asking.as_raw_fd(), &corpus_hello(), &[]).unwrap();
    assert_eq!(raw_frame(&read_frame(&asking, &mut reader)), hex(CORPUS_WELCOME));
    wire::send_all(asking.as_raw_fd(), &hex(CORPUS_TRACE_START), &[]).unwrap();
    wire::send_all(asking.as_raw_fd(), &hex(CORPUS_TRACE_STOP), &[]).unwrap();
    // A PING behind them: its PONG comes with no ERROR before it only when
    // the holder took both.
    let ping = wire::encode(Kind::Ping, 0, b"after-trace");
    wire::send_all(asking.as_raw_fd(), &ping, &[]).unwrap();
    let answer = read_frame(&asking, &mut reader);
    assert_eq!(
        (answer.kind, answer.payload.as_slice()),
        (Kind::Pong as u16, &b"after-trace"[..]),
        "the holder refused its granted trace control: {answer:?}"
    );
    drop(asking);

    let older = UnixStream::connect(&socket).unwrap();
    let mut reader = wire::Reader::default();
    let hello = wire::encode(Kind::Hello, 0, &Out::default().u16(5).bytes(&TOKEN).0);
    wire::send_all(older.as_raw_fd(), &hello, &[]).unwrap();
    assert_eq!(raw_frame(&read_frame(&older, &mut reader)), hex(CORPUS_WELCOME_NONE));
    wire::send_all(older.as_raw_fd(), &hex(CORPUS_TRACE_START), &[]).unwrap();
    assert_eq!(
        refused(&older, &mut reader),
        (Kind::TraceStart as u16, error_code::UNKNOWN_KIND),
        "an ungranted TRACE_START is an unknown kind"
    );
    drop(older);

    // The client of this build asks for every bit and gets what this
    // holder serves; one that offers an older daemon's HELLO gets none.
    let (client, _) = HolderClient::connect(&socket, &TOKEN).unwrap();
    assert_eq!(client.granted(), capability::SUPPORTED);
    drop(client);
    let (client, _) = HolderClient::connect_as(&socket, &TOKEN, 5).unwrap();
    assert_eq!(client.granted(), 0);
    drop(client);

    let _ = holder.kill();
    let _ = holder.wait();
    let _ = std::fs::remove_dir_all(&dir);
}

#[derive(Debug, PartialEq, Eq)]
enum TraceCall {
    Start(TraceStart),
    Stop,
}

struct FakeTrace {
    calls: Sender<TraceCall>,
    /// Whether the fake tracer runs.
    available: bool,
}

impl TraceControl for FakeTrace {
    fn available(&self) -> bool {
        self.available
    }
    fn start(&mut self, request: TraceStart) -> Result<(), String> {
        let _ = self.calls.send(TraceCall::Start(request));
        if request.budget_bytes == 1 { Err("no room".to_string()) } else { Ok(()) }
    }
    fn stop(&mut self) -> Result<(), String> {
        let _ = self.calls.send(TraceCall::Stop);
        Ok(())
    }
}

fn wait_for(what: &str, mut done: impl FnMut() -> bool) {
    let deadline = Instant::now() + Duration::from_secs(20);
    while !done() {
        assert!(Instant::now() < deadline, "timed out waiting for {what}");
        std::thread::sleep(Duration::from_millis(10));
    }
}

/// A holder whose tracer records grants both bits (the corpus WELCOME). A
/// granted TRACE_START and TRACE_STOP reach its tracer with their category
/// mask and budget; a refusal comes back to the link; and the recording a
/// link started stops when that link ends, as a Perfetto session ends with
/// its consumer. (In process: the tracer is the test's.)
#[test]
fn a_granted_link_starts_and_stops_the_holders_trace() {
    let dir = support::unique_dir("cmht");
    let socket = dir.join("h.sock");
    let listener = UnixListener::bind(&socket).unwrap();
    let (calls_tx, calls) = channel();
    let serving = std::thread::spawn(move || {
        let mut holder = Holder::new(listener, TOKEN).unwrap();
        holder.set_trace_control(Box::new(FakeTrace { calls: calls_tx, available: true }));
        holder.set_idle_exit(Duration::from_secs(2));
        holder.run().unwrap();
    });

    let asking = UnixStream::connect(&socket).unwrap();
    let mut reader = wire::Reader::default();
    wire::send_all(asking.as_raw_fd(), &corpus_hello(), &[]).unwrap();
    assert_eq!(raw_frame(&read_frame(&asking, &mut reader)), hex(CORPUS_WELCOME));
    drop(asking);

    let (link, _) = HolderLink::connect(&socket, &TOKEN, Box::new(|_| {})).unwrap();
    assert_eq!(link.capabilities(), capability::SUPPORTED);
    assert!(link.traced() && link.takes_write_flow());
    assert_eq!(link.trace_start(0x4400, CORPUS_BUDGET).unwrap(), TraceForward::Sent);
    let call = calls.recv_timeout(Duration::from_secs(10)).unwrap();
    let start = TraceStart { categories: 0x4400, budget_bytes: CORPUS_BUDGET };
    assert_eq!(call, TraceCall::Start(start));
    assert_eq!(link.trace_stop().unwrap(), TraceForward::Sent);
    assert_eq!(calls.recv_timeout(Duration::from_secs(10)).unwrap(), TraceCall::Stop);
    assert_eq!(link.trace_refusal(), None);

    // A start the tracer refuses (no room in the budget) is reported.
    assert_eq!(link.trace_start(0x4400, 1).unwrap(), TraceForward::Sent);
    calls.recv_timeout(Duration::from_secs(10)).unwrap();
    wait_for("the refusal", || link.trace_refusal().is_some());
    assert_eq!(link.trace_refusal().as_deref(), Some("no room"));

    // A recording runs when another daemon takes the holder: the link that
    // started it ends (SUPERSEDED), so the holder stops it, and the new
    // daemon, which never asked for one, inherits none.
    assert_eq!(link.trace_start(0x4400, 0).unwrap(), TraceForward::Sent);
    let start = TraceStart { categories: 0x4400, budget_bytes: 0 };
    assert_eq!(calls.recv_timeout(Duration::from_secs(10)).unwrap(), TraceCall::Start(start));
    let (taker, _) = HolderClient::connect(&socket, &TOKEN).unwrap();
    wait_for("the superseded link", || !link.is_open());
    assert_eq!(calls.recv_timeout(Duration::from_secs(10)).unwrap(), TraceCall::Stop);
    // The link's reader thread keeps its socket open: the taker leaves
    // too, so the holder has no link and no terminal and exits at its
    // idle exit.
    taker.end();
    drop(link);
    serving.join().unwrap();
    let _ = std::fs::remove_dir_all(&dir);
}

/// A holder whose tracer does not run grants only WRITE_FLOW, and a
/// TRACE_START from that link is an unknown kind that never reaches the
/// tracer. (In process: the tracer is the test's.)
#[test]
fn a_holder_without_a_tracer_grants_write_flow_only() {
    let dir = support::unique_dir("cmhu");
    let socket = dir.join("h.sock");
    let listener = UnixListener::bind(&socket).unwrap();
    let (calls_tx, calls) = channel();
    let serving = std::thread::spawn(move || {
        let mut holder = Holder::new(listener, TOKEN).unwrap();
        holder.set_trace_control(Box::new(FakeTrace { calls: calls_tx, available: false }));
        holder.set_idle_exit(Duration::from_secs(2));
        holder.run().unwrap();
    });

    let asking = UnixStream::connect(&socket).unwrap();
    let mut reader = wire::Reader::default();
    wire::send_all(asking.as_raw_fd(), &corpus_hello(), &[]).unwrap();
    assert_eq!(raw_frame(&read_frame(&asking, &mut reader)), hex(CORPUS_WELCOME_UNTRACED));
    wire::send_all(asking.as_raw_fd(), &hex(CORPUS_TRACE_START), &[]).unwrap();
    assert_eq!(
        refused(&asking, &mut reader),
        (Kind::TraceStart as u16, error_code::UNKNOWN_KIND),
        "a holder that cannot trace never takes TRACE_START"
    );
    drop(asking);
    serving.join().unwrap();
    assert!(calls.try_recv().is_err(), "the tracer got a call");
    let _ = std::fs::remove_dir_all(&dir);
}

#[derive(Default)]
struct Collect {
    bytes: Mutex<Vec<u8>>,
    exit: Mutex<Option<ExitStatus>>,
}

impl TerminalSink for Collect {
    fn data(&self, _offset: u64, bytes: &[u8]) {
        self.bytes.lock().unwrap().extend_from_slice(bytes);
    }
    fn gap(&self, _requested: u64, _oldest: u64) {}
    fn exit(&self, status: ExitStatus, _end: u64) {
        *self.exit.lock().unwrap() = Some(status);
    }
}

fn cat(chan: u32) -> SpawnRequest {
    let mut id = [0u8; 16];
    id[..4].copy_from_slice(&chan.to_le_bytes());
    SpawnRequest {
        id,
        cols: 80,
        rows: 24,
        cwd: b"/tmp".to_vec(),
        argv: vec![b"/bin/sh".to_vec(), b"-c".to_vec(), b"echo up; exec cat".to_vec()],
        env: vec![b"PATH=/usr/bin:/bin".to_vec()],
        ..SpawnRequest::default()
    }
}

/// WRITE_FLOW: the trailer never reaches the shell, and the first PTY
/// read after the input reached the master carries the flow
/// (`holder.pty.read` with flow 42 in the holder's flow marks), exactly
/// once. A flow mark with no input, sent before the daemon writes on its
/// custody master, marks the echo of that write the same way.
#[test]
fn a_write_flow_marks_the_next_read_and_never_reaches_the_shell() {
    let dir = support::unique_dir("cmhf");
    let socket = dir.join("h.sock");
    let marks = dir.join("marks");
    std::fs::create_dir_all(&marks).unwrap();
    let mut holder = launch_with(holder_binary(), &socket, &TOKEN, |command| {
        command.env("CMUX_TRACE_FLOWS", &marks);
    })
    .unwrap();
    let (link, _) = HolderLink::connect(&socket, &TOKEN, Box::new(|_| {})).unwrap();
    let sink = Arc::new(Collect::default());
    let spawned = link.spawn(1, &cat(1), sink.clone()).unwrap();
    let text = || String::from_utf8_lossy(&sink.bytes.lock().unwrap()).into_owned();
    wait_for("the first line", || text().contains("up"));
    let marks_file = marks.join(format!("flows-{}.jsonl", holder.id()));
    let reads_with = |flow: u64| {
        let marks = std::fs::read_to_string(&marks_file).unwrap_or_default();
        marks
            .lines()
            .filter(|line| {
                line.contains("\"hop\":\"holder.pty.read\"")
                    && line.contains(&format!("\"flow\":{flow},"))
            })
            .count()
    };

    link.write_flow(1, b"through-holder\n", 42).unwrap();
    wait_for("the echo", || text().contains("through-holder\r\nthrough-holder"));
    wait_for("the read marked with flow 42", || reads_with(42) > 0);

    link.write_flow(1, b"", 43).unwrap();
    // A SPAWN answered: the holder handled every frame before it, the mark
    // too, before the custody write below.
    let barrier = Arc::new(Collect::default());
    let _second = link.spawn(2, &cat(2), barrier.clone()).unwrap();
    let mut master = std::fs::File::from(spawned.master.try_clone().unwrap());
    master.write_all(b"on-master\n").unwrap();
    wait_for("the custody echo", || text().contains("on-master\r\non-master"));
    wait_for("the read marked with flow 43", || reads_with(43) > 0);
    assert_eq!((reads_with(42), reads_with(43)), (1, 1), "each flow marks one read");
    assert!(
        !text().contains('*') && !text().contains('+') && !text().contains('\0'),
        "a flow trailer reached the shell: {:?}",
        text()
    );

    link.close(1, 200).unwrap();
    link.close(2, 200).unwrap();
    wait_for("the exits", || {
        sink.exit.lock().unwrap().is_some() && barrier.exit.lock().unwrap().is_some()
    });
    let _ = holder.kill();
    let _ = holder.wait();
    let _ = std::fs::remove_dir_all(&dir);
}
