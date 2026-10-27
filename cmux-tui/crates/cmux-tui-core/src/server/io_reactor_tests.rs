//! The IO reactor's writes (p05-ipc-156): a full socket waits for
//! writability and resumes in order, a peer that stops reading holds up no
//! other connection and is ended at its write timeout, an idle reactor
//! wakes 0 times, and served connections share it with no writer thread.

use std::io::{BufRead, BufReader, Read, Write};
use std::net::Shutdown;
use std::os::unix::net::UnixStream;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{Duration, Instant};

use serde_json::{Value, json};

use super::{IoReactor, LineOutput};
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

/// Hands a socket pair's server side to `reactor`; the client side stays.
fn adopt(reactor: &IoReactor, mux: &Mux, timeout: Option<Duration>) -> Output {
    let (client, server) = UnixStream::pair().unwrap();
    let outbound = Arc::new(BoundedOutbound::default());
    outbound.set_write_timeout(timeout);
    let ipc = Arc::new(IpcStats::default());
    let ended = Arc::new(AtomicBool::new(false));
    reactor
        .adopt(LineOutput {
            outbound: outbound.clone(),
            socket: Box::new(server),
            ipc: ipc.clone(),
            hangs: mux.echo_watch(),
            _end: Box::new(Ended(ended.clone())),
        })
        .unwrap();
    client.set_read_timeout(Some(Duration::from_secs(10))).unwrap();
    Output { outbound, ipc, ended, client }
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
        let reply = service.serialize_control(&json!({"id": id, "ok": true})).unwrap();
        let started = Instant::now();
        other_output.outbound.push_control(reply).unwrap();
        let mut text = String::new();
        BufReader::new(&other_output.client).read_line(&mut text).unwrap();
        let reply: Value = serde_json::from_str(&text).unwrap();
        assert_eq!(reply["id"], id, "{reply}");
        assert!(started.elapsed() < Duration::from_secs(1), "reply {id}: {:?}", started.elapsed());
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
        cmux_threads::snapshot().into_iter().filter(|row| row.name == "mux-line-out").collect();
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
