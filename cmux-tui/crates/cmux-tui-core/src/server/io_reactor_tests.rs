//! The IO reactor over real accepted sockets (p05-ipc-155): connections
//! read on no thread of their own, lines are served in order and as the
//! reader thread served them, a connection ends cleanly, and idle
//! connections wake the reactor 0 times.

use std::io::{BufRead, BufReader, Write};
use std::net::Shutdown;
use std::os::unix::net::UnixStream;
use std::path::PathBuf;
use std::time::{Duration, Instant};

use serde_json::{Value, json};

use crate::server::listen::ServedSession;
use crate::server::*;

struct Served {
    mux: Arc<Mux>,
    session: ServedSession,
    listener: transport::Listener,
    path: PathBuf,
    _directory: cmux_unix_socket::TestDir,
}

impl Served {
    fn new(label: &str) -> Self {
        let mux =
            Mux::new_for_test(format!("io-reactor-{label}"), crate::SurfaceOptions::default());
        let directory = cmux_unix_socket::short_test_dir("io-reactor");
        let path = directory.path().join("s.sock");
        let listener = transport::listen(&path).unwrap();
        let session = ServedSession::new(mux.clone(), Arc::new(RenderService::new()));
        assert!(session.reactor.is_some(), "the reactor starts");
        Served { mux, session, listener, path, _directory: directory }
    }

    fn reactor(&self) -> &io_reactor::IoReactor {
        self.session.reactor.as_deref().unwrap()
    }

    /// A client whose accepted end the session serves.
    fn connect(&self) -> Client {
        let socket = UnixStream::connect(&self.path).unwrap();
        self.session.serve(self.listener.accept().unwrap());
        let read_half = socket.try_clone().unwrap();
        read_half.set_read_timeout(Some(Duration::from_secs(10))).unwrap();
        Client { socket, replies: BufReader::new(read_half) }
    }

    /// Waits until the reactor reads `count` connections.
    fn wait_connections(&self, count: usize) {
        let deadline = Instant::now() + Duration::from_secs(10);
        while self.reactor().connections() != count {
            assert!(Instant::now() < deadline, "{} connections", self.reactor().connections());
            std::thread::sleep(Duration::from_millis(5));
        }
    }

    /// The reactor's wakeups once they stop changing.
    fn settled_wakeups(&self) -> u64 {
        let deadline = Instant::now() + Duration::from_secs(10);
        let mut last = self.reactor().wakeups();
        loop {
            std::thread::sleep(Duration::from_millis(200));
            let now = self.reactor().wakeups();
            if now == last {
                return now;
            }
            assert!(Instant::now() < deadline, "the reactor never settled");
            last = now;
        }
    }
}

impl Drop for Served {
    fn drop(&mut self) {
        self.mux.shutdown();
    }
}

struct Client {
    socket: UnixStream,
    replies: BufReader<UnixStream>,
}

impl Client {
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

    fn ping(&mut self, id: u64) {
        self.send(&ping(id));
        let reply = self.reply().expect("a reply");
        assert_eq!((reply["id"].clone(), reply["ok"].clone()), (json!(id), json!(true)), "{reply}");
    }
}

fn ping(id: u64) -> Vec<u8> {
    format!("{}\n", json!({"id": id, "cmd": "ping"})).into_bytes()
}

/// Threads of `name` in the process now.
fn threads_named(name: &str) -> usize {
    cmux_threads::snapshot().into_iter().filter(|row| row.name == name).count()
}

/// The acceptance: CLI connections, held open together up to the
/// connection limit and then 100 one after another as the CLI makes them,
/// start no reader thread; the reactor reads them all.
#[test]
fn io_reactor_cli_connections_add_no_reader_thread() {
    let served = Served::new("threads");
    let mut held: Vec<Client> = (0..60).map(|_| served.connect()).collect();
    for (id, client) in held.iter_mut().enumerate() {
        client.ping(id as u64);
    }
    served.wait_connections(60);
    assert_eq!(threads_named("mux-conn"), 0, "no connection has a reader thread");
    for client in &held {
        client.socket.shutdown(Shutdown::Both).unwrap();
    }
    held.clear();
    served.wait_connections(0);

    for id in 0..100 {
        let mut client = served.connect();
        client.ping(id);
        assert_eq!(threads_named("mux-conn"), 0, "connection {id} has a reader thread");
        client.socket.shutdown(Shutdown::Both).unwrap();
    }
    served.wait_connections(0);
    assert!(threads_named(io_reactor::REACTOR_THREAD) >= 1, "the reactor runs");
}

/// p14-energy: open connections that send nothing wake the reactor 0 times.
#[test]
fn io_reactor_idle_connections_wake_nothing() {
    let served = Served::new("idle");
    let mut clients: Vec<Client> = (0..10).map(|_| served.connect()).collect();
    for (id, client) in clients.iter_mut().enumerate() {
        client.ping(id as u64);
    }
    let idle = served.settled_wakeups();
    std::thread::sleep(Duration::from_secs(1));
    assert_eq!(served.reactor().wakeups(), idle, "10 idle connections woke the reactor");
}

/// Pipelined messages in one write, past the read-ahead bound and the batch
/// size, are handled once each, in order: blank lines (handled and
/// skipped) between pings, the pings within the connection's request cap
/// (`CONNECTION_SURFACE_QUEUE_CAPACITY`, past which a request is refused).
#[test]
fn io_reactor_pipelined_lines_are_answered_in_order() {
    let served = Served::new("pipelined");
    let mut client = served.connect();
    let count = 200;
    let blanks = io_reactor::MAX_QUEUED_MESSAGES * 3 / 200 + 1;
    let writer = {
        let mut socket = client.socket.try_clone().unwrap();
        std::thread::spawn(move || {
            let mut bytes = Vec::new();
            for id in 0..count {
                bytes.extend(std::iter::repeat_n(b'\n', blanks));
                bytes.extend(ping(id));
            }
            socket.write_all(&bytes).unwrap();
        })
    };
    for id in 0..count {
        let reply = client.reply().expect("a reply");
        assert_eq!(reply["id"], json!(id), "{reply}");
    }
    writer.join().unwrap();
}

/// A last line with no `\n` is served when the peer closes, then the
/// connection ends: its client leaves the registry and the reactor.
#[test]
fn io_reactor_an_unterminated_last_line_is_served_at_eof_then_the_connection_ends() {
    let served = Served::new("eof");
    let mut client = served.connect();
    client.ping(1);
    let line = ping(2);
    client.send(&line[..line.len() - 1]);
    client.socket.shutdown(Shutdown::Write).unwrap();
    assert_eq!(client.reply().unwrap()["id"], json!(2));
    assert_eq!(client.reply(), None, "the daemon closes after the last reply");
    served.wait_connections(0);
    let deadline = Instant::now() + Duration::from_secs(10);
    while !served.mux.control_clients.client_ids().is_empty() {
        assert!(Instant::now() < deadline, "the client was never disconnected");
        std::thread::sleep(Duration::from_millis(5));
    }
}

/// A frame from a client that never negotiated frames closes the
/// connection as a bad message; nothing after it is served.
#[test]
fn io_reactor_a_frame_before_negotiation_closes_with_bad_message() {
    let served = Served::new("frame");
    let bad_before = served.mux.ipc_stats().snapshot().bad_message;
    let mut client = served.connect();
    let header = cmux_ipc::FrameHeader::new(
        cmux_ipc::FrameKind::Request,
        0,
        2,
        cmux_ipc::Aux::Call(cmux_ipc::CallAux {
            request_id: 1,
            method_id: 0x0101,
            priority: cmux_ipc::PriorityHint::Control,
            flags: cmux_ipc::CallFlags::empty(),
        }),
    )
    .unwrap();
    client.ping(1);
    let mut bytes = header.encode().to_vec();
    bytes.extend(b"{}");
    bytes.extend(ping(2));
    client.send(&bytes);
    assert_eq!(client.reply(), None, "nothing after the frame is served");
    served.wait_connections(0);
    assert_eq!(served.mux.ipc_stats().snapshot().bad_message, bad_before + 1);
}

/// A descriptor sent with a line closes the connection as a bad message
/// before the line is served.
#[test]
fn io_reactor_a_descriptor_closes_with_bad_message() {
    use std::os::fd::AsRawFd;

    let served = Served::new("fds");
    let mut client = served.connect();
    client.ping(1);
    let (passed, _other) = UnixStream::pair().unwrap();
    cmux_ipc::fds::send_all(client.socket.as_raw_fd(), &ping(2), &[passed.as_raw_fd()]).unwrap();
    assert_eq!(client.reply(), None);
    served.wait_connections(0);
}
