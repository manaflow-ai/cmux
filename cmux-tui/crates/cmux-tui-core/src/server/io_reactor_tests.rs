//! The IO reactor's writes (p05-ipc-156): a full socket waits for
//! writability and resumes in order, a peer that stops reading holds up no
//! other connection and is ended at its write timeout, an idle reactor
//! wakes 0 times, and served connections share it with no writer thread.
//! A panic in one connection's end ends only that connection; a socket the
//! reactor cannot poll, and every connection after the reactor stopped, is
//! written by a writer thread of its own.

use std::io::{BufRead, BufReader, Read, Write};
use std::net::Shutdown;
use std::os::unix::net::UnixStream;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{Duration, Instant};

use serde_json::{Value, json};

use super::{IoReactor, LINE_OUT_THREAD, LineOutput};
use crate::diagnostics::IpcStats;
use crate::server::*;

/// Sets its flag when the reactor drops the connection's end.
struct Ended(Arc<AtomicBool>);

impl Drop for Ended {
    fn drop(&mut self) {
        self.0.store(true, Ordering::SeqCst);
    }
}

struct Output {
    outbound: Arc<BoundedOutbound>,
    ipc: Arc<IpcStats>,
    ended: Arc<AtomicBool>,
    client: UnixStream,
}

/// Panics when the writer drops the connection's end, after it set its
/// flag: a close callback that panics.
struct PanicsAtEnd(Ended);

impl Drop for PanicsAtEnd {
    fn drop(&mut self) {
        self.0.0.store(true, Ordering::SeqCst);
        panic!("a close callback panicked (injected)");
    }
}

/// A Unix socket that does not offer its descriptor, as a Windows socket
/// does not: the reactor cannot poll it.
struct Unpollable(UnixStream);

impl Read for Unpollable {
    fn read(&mut self, buf: &mut [u8]) -> std::io::Result<usize> {
        self.0.read(buf)
    }
}

impl Write for Unpollable {
    fn write(&mut self, buf: &[u8]) -> std::io::Result<usize> {
        self.0.write(buf)
    }

    fn flush(&mut self) -> std::io::Result<()> {
        self.0.flush()
    }
}

impl transport::Stream for Unpollable {
    fn try_clone_box(&self) -> std::io::Result<Box<dyn transport::Stream>> {
        Ok(Box::new(Self(self.0.try_clone()?)))
    }
    fn set_read_timeout(&self, timeout: Option<Duration>) -> std::io::Result<()> {
        self.0.set_read_timeout(timeout)
    }
    fn set_write_timeout(&self, timeout: Option<Duration>) -> std::io::Result<()> {
        self.0.set_write_timeout(timeout)
    }
    fn shutdown(&self, how: Shutdown) -> std::io::Result<()> {
        self.0.shutdown(how)
    }
}

/// How a test's connection is made.
#[derive(Clone, Copy, PartialEq, Eq)]
enum Kind {
    /// A Unix socket the reactor polls.
    Pollable,
    /// A socket the reactor cannot poll ([`Unpollable`]).
    Unpollable,
    /// A Unix socket whose end guard panics ([`PanicsAtEnd`]).
    PanicsAtEnd,
}

/// Hands a socket pair's server side to `reactor`; the client side stays.
fn adopt(reactor: &IoReactor, mux: &Mux, timeout: Option<Duration>) -> Output {
    open(reactor, mux, timeout, Kind::Pollable)
}

fn open(reactor: &IoReactor, mux: &Mux, timeout: Option<Duration>, kind: Kind) -> Output {
    let (client, server) = UnixStream::pair().unwrap();
    let outbound = Arc::new(BoundedOutbound::default());
    outbound.set_write_timeout(timeout);
    let ipc = Arc::new(IpcStats::default());
    let ended = Arc::new(AtomicBool::new(false));
    let socket: Box<dyn transport::Stream> = match kind {
        Kind::Unpollable => Box::new(Unpollable(server)),
        Kind::Pollable | Kind::PanicsAtEnd => Box::new(server),
    };
    let end: Box<dyn Send> = match kind {
        Kind::PanicsAtEnd => Box::new(PanicsAtEnd(Ended(ended.clone()))),
        Kind::Pollable | Kind::Unpollable => Box::new(Ended(ended.clone())),
    };
    reactor
        .serve(LineOutput {
            outbound: outbound.clone(),
            socket,
            ipc: ipc.clone(),
            hangs: mux.echo_watch(),
            _end: end,
        })
        .unwrap();
    client.set_read_timeout(Some(Duration::from_secs(10))).unwrap();
    Output { outbound, ipc, ended, client }
}

/// Queues reply `id` on `output` and reads it back within a second.
fn round_trip(service: &RenderService, output: &Output, id: usize) {
    let reply = service.serialize_control(&json!({"id": id, "ok": true})).unwrap();
    let started = Instant::now();
    output.outbound.push_control(reply).unwrap();
    let mut text = String::new();
    BufReader::new(&output.client).read_line(&mut text).unwrap();
    let reply: Value = serde_json::from_str(&text).unwrap();
    assert_eq!(reply["id"], id, "{reply}");
    assert!(started.elapsed() < Duration::from_secs(1), "reply {id}: {:?}", started.elapsed());
}

/// Live `mux-line-out` writer threads.
fn line_out_threads() -> usize {
    cmux_threads::snapshot().into_iter().filter(|row| row.name == LINE_OUT_THREAD).count()
}

/// Line `index` of `len` bytes (its `\n` excluded).
fn line(service: &RenderService, index: usize, len: usize) -> Arc<BudgetedText> {
    let prefix = format!("{index:06}");
    let text = service.serialize(&format!("{prefix}{}", "x".repeat(len - 2 - prefix.len())));
    let text = text.unwrap();
    assert_eq!(text.len(), len);
    text
}

/// Queues `count` lines of 64 KiB: far past a Unix socket's buffer.
fn fill(service: &RenderService, output: &Output, count: usize) -> Vec<u8> {
    let mut expected = Vec::new();
    for index in 0..count {
        let text = line(service, index, 64 * 1024);
        expected.extend_from_slice(text.as_bytes());
        expected.push(b'\n');
        output.outbound.push_control(text).unwrap();
    }
    expected
}

fn wait_until(what: &str, mut done: impl FnMut() -> bool) {
    let deadline = Instant::now() + Duration::from_secs(10);
    while !done() {
        assert!(Instant::now() < deadline, "timed out waiting until {what}");
        std::thread::sleep(Duration::from_millis(5));
    }
}

#[test]
fn io_reactor_resumes_a_full_socket_on_writability_in_order() {
    let mux = Mux::new_for_test("io-reactor-resume", crate::SurfaceOptions::default());
    let service = RenderService::new();
    let reactor = IoReactor::default();
    let mut output = adopt(&reactor, &mux, None);
    let expected = fill(&service, &output, 64);

    // The socket's buffer filled and the reactor waits for writability.
    wait_until("the write would block", || output.ipc.snapshot().writes.stalls > 0);
    output.outbound.close();
    let mut got = Vec::new();
    output.client.read_to_end(&mut got).unwrap();
    assert!(got == expected, "{} bytes arrived of {}, or out of order", got.len(), expected.len());
    wait_until("the output ended", || output.ended.load(Ordering::SeqCst));
    assert_eq!(output.ipc.snapshot().writes.messages, 64);
    wait_until("the reactor dropped it", || reactor.connections() == 0);
    drop(mux);
}

#[test]
fn io_reactor_a_peer_that_stops_reading_delays_no_other_connection() {
    let mux = Mux::new_for_test("io-reactor-stuck", crate::SurfaceOptions::default());
    let service = RenderService::new();
    let reactor = IoReactor::default();
    let stuck = adopt(&reactor, &mux, None);
    fill(&service, &stuck, 64);
    wait_until("the stuck peer's write would block", || stuck.ipc.snapshot().writes.stalls > 0);

    let mut other = BufReader::new(adopt(&reactor, &mux, None).client);
    let other_output = adopt(&reactor, &mux, None);
    for id in 0..100 {
        round_trip(&service, &other_output, id);
    }
    assert!(!stuck.ended.load(Ordering::SeqCst), "no write timeout: the stuck peer stays");
    assert!(stuck.outbound.is_open());
    // The idle connection was never written.
    other.get_mut().set_read_timeout(Some(Duration::from_millis(50))).unwrap();
    assert!(other.fill_buf().is_err(), "an empty queue writes nothing");
    drop(mux);
}

#[test]
fn io_reactor_ends_a_peer_that_takes_nothing_for_its_write_timeout() {
    let mux = Mux::new_for_test("io-reactor-timeout", crate::SurfaceOptions::default());
    let service = RenderService::new();
    let reactor = IoReactor::default();
    let mut stalled = adopt(&reactor, &mux, Some(Duration::from_millis(200)));
    fill(&service, &stalled, 64);
    let started = Instant::now();
    wait_until("the stalled peer is ended", || stalled.ended.load(Ordering::SeqCst));
    assert!(started.elapsed() >= Duration::from_millis(150), "{:?}", started.elapsed());
    assert!(!stalled.outbound.is_open(), "its queue closed");
    // The socket shut down: the client reads what was sent, then the end.
    let mut got = Vec::new();
    stalled.client.read_to_end(&mut got).unwrap();
    assert!(got.len() < 64 * (64 * 1024 + 1), "{} bytes", got.len());
    wait_until("the reactor dropped it", || reactor.connections() == 0);
    drop(mux);
}

#[test]
fn io_reactor_an_idle_reactor_wakes_zero_times() {
    let mux = Mux::new_for_test("io-reactor-idle", crate::SurfaceOptions::default());
    let service = RenderService::new();
    let reactor = IoReactor::default();
    let outputs: Vec<Output> = (0..10).map(|_| adopt(&reactor, &mux, None)).collect();
    for (id, output) in outputs.iter().enumerate() {
        let reply = service.serialize_control(&json!({"id": id, "ok": true})).unwrap();
        output.outbound.push_control(reply).unwrap();
        let mut text = String::new();
        BufReader::new(&output.client).read_line(&mut text).unwrap();
        assert!(text.contains(&format!("\"id\":{id}")), "{text}");
    }
    wait_until("the reactor has all ten", || reactor.connections() == 10);
    std::thread::sleep(Duration::from_millis(100));
    let idle = reactor.wakeups();
    std::thread::sleep(Duration::from_millis(500));
    assert_eq!(reactor.wakeups(), idle, "an idle reactor wakes 0 times");
    drop(outputs);
    drop(mux);
}

/// Twenty connections the daemon serves are written by one reactor: none
/// has a writer thread of its own (`mux-line-out` is gone), and each ends
/// when its client closes.
#[test]
fn io_reactor_twenty_served_connections_share_it_with_no_writer_thread() {
    let mux = Mux::new_for_test("io-reactor-served", crate::SurfaceOptions::default());
    let path = serve(mux.clone(), None).unwrap();
    let mut clients = Vec::new();
    for id in 0..20 {
        let mut socket = UnixStream::connect(&path).unwrap();
        socket.set_read_timeout(Some(Duration::from_secs(10))).unwrap();
        socket.write_all(format!("{}\n", json!({"id": id, "cmd": "ping"})).as_bytes()).unwrap();
        let mut replies = BufReader::new(socket.try_clone().unwrap());
        let mut text = String::new();
        replies.read_line(&mut text).unwrap();
        let reply: Value = serde_json::from_str(&text).unwrap();
        assert_eq!((reply["id"].clone(), reply["ok"].clone()), (json!(id), json!(true)), "{reply}");
        clients.push(socket);
    }
    assert_eq!(mux.io_reactor.connections(), 20);
    let writers: Vec<_> =
        cmux_threads::snapshot().into_iter().filter(|row| row.name == LINE_OUT_THREAD).collect();
    assert!(writers.is_empty(), "no connection has a writer thread: {writers:?}");

    // One at a time: twenty teardowns at once contend for the mux's
    // conversation store lock, a blocking-call panic on the reader while a
    // parallel test holds the detector in panic mode.
    for mut socket in clients {
        socket.shutdown(Shutdown::Write).unwrap();
        let mut rest = Vec::new();
        socket.read_to_end(&mut rest).unwrap();
    }
    wait_until("every output ended", || mux.io_reactor.connections() == 0);
    wait_until("every slot is free", || mux.connection_stats().active() == 0);
    cleanup(&path);
}

/// A connection whose end panics (a close callback, a blocking call in
/// Debug panic mode) ends alone: the reactor keeps writing the others and
/// adopts new ones. Before, the panic killed the reactor's thread, every
/// connection's output stopped, and every later connection was refused.
#[test]
fn io_reactor_a_panic_in_a_connections_end_ends_only_that_connection() {
    let mux = Mux::new_for_test("io-reactor-end-panic", crate::SurfaceOptions::default());
    let service = RenderService::new();
    let reactor = IoReactor::default();
    let panics = open(&reactor, &mux, None, Kind::PanicsAtEnd);
    let other = adopt(&reactor, &mux, None);
    round_trip(&service, &panics, 0);
    wait_until("the reactor has both", || reactor.connections() == 2);

    panics.outbound.close();
    wait_until("the panicking end ran", || panics.ended.load(Ordering::SeqCst));
    wait_until("the reactor dropped it", || reactor.connections() == 1);
    for id in 1..20 {
        round_trip(&service, &other, id);
    }
    let later = adopt(&reactor, &mux, None);
    round_trip(&service, &later, 20);
    assert_eq!(reactor.connections(), 2, "the reactor writes the later connection");
    drop(mux);
}

/// A socket the reactor cannot poll (a Windows socket) gets a writer
/// thread of its own, so a peer that stops reading on it holds up only that
/// thread: a reactor connection's replies still arrive at once.
#[test]
fn io_reactor_a_socket_it_cannot_poll_gets_its_own_writer_thread() {
    let mux = Mux::new_for_test("io-reactor-unpollable", crate::SurfaceOptions::default());
    let service = RenderService::new();
    let reactor = IoReactor::default();
    let unpollable = open(&reactor, &mux, None, Kind::Unpollable);
    round_trip(&service, &unpollable, 0);
    assert!(line_out_threads() >= 1, "it is written on a thread of its own");
    assert_eq!(reactor.connections(), 0, "the reactor does not write it");

    // Its peer stops reading: its writer blocks in a write.
    fill(&service, &unpollable, 64);
    let other = adopt(&reactor, &mux, None);
    for id in 1..100 {
        round_trip(&service, &other, id);
    }
    assert!(!unpollable.ended.load(Ordering::SeqCst));

    // Its peer goes away: the write fails and the output ends.
    let Output { ended, client, .. } = unpollable;
    client.shutdown(Shutdown::Both).unwrap();
    drop(client);
    wait_until("its output ended", || ended.load(Ordering::SeqCst));
    drop(mux);
}

/// After the reactor stopped (its poll failed, or it panicked), the daemon
/// keeps serving: a new connection is written by a thread of its own.
#[test]
fn io_reactor_a_stopped_reactor_hands_new_connections_to_writer_threads() {
    let mux = Mux::new_for_test("io-reactor-stopped", crate::SurfaceOptions::default());
    let service = RenderService::new();
    let reactor = IoReactor::default();
    let first = adopt(&reactor, &mux, None);
    round_trip(&service, &first, 0);
    first.outbound.close();
    wait_until("the reactor dropped it", || reactor.connections() == 0);
    reactor.stop_and_wait();

    let later = adopt(&reactor, &mux, None);
    round_trip(&service, &later, 1);
    assert_eq!(reactor.connections(), 0, "the stopped reactor does not write it");
    assert!(line_out_threads() >= 1, "it is written on a thread of its own");
    later.outbound.close();
    wait_until("its output ended", || later.ended.load(Ordering::SeqCst));
    drop(mux);
}
