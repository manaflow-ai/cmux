//! Behavior of `loopback-forward-v1`: opt-in, loopback-only targets, port
//! policy, byte streams with half close, flow control both ways, limits, and
//! cleanup when the control connection ends.

use std::collections::VecDeque;
use std::io::{BufRead, BufReader, Read, Write};
use std::net::{Shutdown, TcpListener};
use std::time::{Duration, Instant};

use base64::Engine;
use serde_json::{Value, json};

use super::loopback_forward::{
    DAEMON_RECEIVE_WINDOW, LoopbackForwardPolicy, LoopbackTarget, MAX_FRAME_BYTES,
    MAX_STREAMS_PER_CLIENT, classify_target,
};
use super::*;

const WAIT: Duration = Duration::from_secs(5);

fn b64(bytes: &[u8]) -> String {
    base64::engine::general_purpose::STANDARD.encode(bytes)
}

fn unb64(text: &str) -> Vec<u8> {
    base64::engine::general_purpose::STANDARD.decode(text).unwrap()
}

/// One control connection served by `handle_connection` on a private socket.
struct Client {
    writer: Box<dyn transport::Stream>,
    reader: BufReader<Box<dyn transport::Stream>>,
    events: VecDeque<Value>,
    next_id: u64,
    directory: PathBuf,
    handler: Option<JoinHandle<()>>,
}

impl Client {
    fn connect(mux: &Arc<Mux>, label: &str) -> Self {
        static SEQUENCE: AtomicU64 = AtomicU64::new(0);
        let directory = std::env::temp_dir().join(format!(
            "cmux-loopback-{label}-{}-{}",
            std::process::id(),
            SEQUENCE.fetch_add(1, Ordering::Relaxed)
        ));
        std::fs::create_dir_all(&directory).unwrap();
        let path = directory.join("s.sock");
        let listener = transport::listen(&path).unwrap();
        let client = transport::connect(&path).unwrap();
        let server = listener.accept().unwrap();
        let server_mux = mux.clone();
        let handler = std::thread::spawn(move || handle_connection(server_mux, server));
        let reader = client.try_clone_box().unwrap();
        reader.set_read_timeout(Some(Duration::from_millis(100))).unwrap();
        Self {
            writer: client,
            reader: BufReader::new(reader),
            events: VecDeque::new(),
            next_id: 1,
            directory,
            handler: Some(handler),
        }
    }

    fn send(&mut self, value: Value) {
        writeln!(self.writer, "{value}").unwrap();
        self.writer.flush().unwrap();
    }

    fn read_line(&mut self, deadline: Instant) -> Option<Value> {
        let mut line = String::new();
        while Instant::now() < deadline {
            match self.reader.read_line(&mut line) {
                Ok(0) => return None,
                Ok(_) if line.ends_with('\n') => return Some(serde_json::from_str(&line).unwrap()),
                Ok(_) => continue,
                Err(error)
                    if matches!(
                        error.kind(),
                        std::io::ErrorKind::WouldBlock | std::io::ErrorKind::TimedOut
                    ) =>
                {
                    continue;
                }
                Err(error) => panic!("read failed: {error}"),
            }
        }
        None
    }

    fn request(&mut self, mut value: Value) -> Value {
        let id = self.next_id;
        self.next_id += 1;
        value["id"] = json!(id);
        self.send(value);
        let deadline = Instant::now() + WAIT;
        loop {
            let line = self.read_line(deadline).expect("no response before the deadline");
            if line.get("event").is_some() {
                self.events.push_back(line);
            } else if line["id"] == json!(id) {
                return line;
            }
        }
    }

    fn opt_in(&mut self) {
        let reply = self.request(json!({
            "cmd": "set-client-info",
            "name": "loopback-test",
            "capabilities": [LOOPBACK_FORWARD_CAPABILITY],
        }));
        assert_eq!(reply["ok"], true, "{reply}");
    }

    /// Next event (buffered first), or None after `timeout`.
    fn event(&mut self, timeout: Duration) -> Option<Value> {
        if let Some(event) = self.events.pop_front() {
            return Some(event);
        }
        let deadline = Instant::now() + timeout;
        loop {
            let line = self.read_line(deadline)?;
            if line.get("event").is_some() {
                return Some(line);
            }
        }
    }

    fn open(&mut self, stream: u64, host: &str, port: u16) -> Value {
        self.request(json!({"cmd": "loopback-open", "stream": stream, "host": host, "port": port}))
    }
}

impl Drop for Client {
    fn drop(&mut self) {
        let _ = self.writer.shutdown(Shutdown::Both);
        if let Some(handler) = self.handler.take() {
            let _ = handler.join();
        }
        let _ = std::fs::remove_dir_all(&self.directory);
    }
}

fn mux(label: &str) -> Arc<Mux> {
    Mux::new_for_test(label, crate::SurfaceOptions::default())
}

fn target() -> (TcpListener, u16) {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let port = listener.local_addr().unwrap().port();
    (listener, port)
}

fn assert_no_accept(listener: &TcpListener) {
    listener.set_nonblocking(true).unwrap();
    assert!(
        matches!(listener.accept(), Err(error) if error.kind() == std::io::ErrorKind::WouldBlock),
        "the daemon connected although it must refuse"
    );
}

// MARK: Capability and opt-in

#[test]
fn loopback_forward_capability_is_advertised() {
    let mux = mux("loopback-identify");
    let (writer, _) = tests::captured_writer();
    let identity =
        handle_command(&mux, mux.local_test_client(0), Command::Identify, &writer).unwrap();
    assert!(
        identity["capabilities"]
            .as_array()
            .unwrap()
            .iter()
            .any(|value| value == LOOPBACK_FORWARD_CAPABILITY)
    );
}

#[test]
fn loopback_open_is_refused_until_the_client_opts_in() {
    let mux = mux("loopback-opt-in");
    let (listener, port) = target();
    let mut client = Client::connect(&mux, "opt-in");
    let reply = client.open(1, "127.0.0.1", port);
    assert_eq!(reply["ok"], false);
    assert_eq!(reply["error_code"], "loopback.not-enabled");
    assert_no_accept(&listener);
}

#[test]
fn loopback_forwarding_can_be_turned_off_by_policy() {
    let mux = mux("loopback-disabled");
    mux.set_loopback_forward_policy(LoopbackForwardPolicy::disabled());
    let (listener, port) = target();
    let mut client = Client::connect(&mux, "disabled");
    client.opt_in();
    let reply = client.open(1, "localhost", port);
    assert_eq!(reply["error_code"], "loopback.disabled");
    assert_no_accept(&listener);
}

// MARK: Loopback-only targets

#[test]
fn loopback_targets_are_classified_without_dns() {
    for host in [
        "localhost",
        "LocalHost",
        "localhost.",
        "app.localhost",
        "a-b.c.localhost",
        "127.0.0.1",
        "127.12.34.56",
        "::1",
        "[::1]",
        "::ffff:127.0.0.1",
    ] {
        assert!(classify_target(host).is_some(), "{host} must be forwarded");
    }
    assert_eq!(classify_target("localhost"), Some(LoopbackTarget::Localhost));
    for host in [
        "",
        "example.com",
        "localhost.example.com",
        "127.0.0.1.nip.io",
        "localtest.me",
        "10.0.0.1",
        "192.168.1.1",
        "169.254.169.254",
        "8.8.8.8",
        "0.0.0.0",
        "::",
        "[::ffff:10.0.0.1]",
        "fe80::1",
        "127.1",
        "0x7f.0.0.1",
        "2130706433",
        "-a.localhost",
        "a..localhost",
        "a_b.localhost",
        "[localhost]",
        "localhost:80",
    ] {
        assert!(classify_target(host).is_none(), "{host:?} must not be forwarded");
    }
}

#[test]
fn loopback_open_refuses_hosts_that_are_not_loopback() {
    let mux = mux("loopback-hosts");
    let (listener, port) = target();
    let mut client = Client::connect(&mux, "hosts");
    client.opt_in();
    for (stream, host) in
        ["10.0.0.1", "example.com", "127.0.0.1.nip.io", "0.0.0.0", "169.254.169.254"]
            .into_iter()
            .enumerate()
    {
        let reply = client.open(stream as u64 + 1, host, port);
        assert_eq!(reply["error_code"], "loopback.denied-host", "{host}: {reply}");
    }
    assert_no_accept(&listener);
}

// MARK: Port policy

#[test]
fn loopback_port_policy_parses_and_denies() {
    let default = LoopbackForwardPolicy::default();
    assert!(default.is_enabled());
    assert!(default.permits_port(3000));
    assert!(default.permits_port(80));
    assert!(!default.permits_port(0));

    let off = LoopbackForwardPolicy::from_config_value(&json!(false)).unwrap();
    assert!(!off.is_enabled());

    let policy = LoopbackForwardPolicy::from_config_value(&json!({
        "allow_ports": ["3000-3999", 8080],
        "deny_ports": [3306, "3500-3510"],
    }))
    .unwrap();
    assert!(policy.permits_port(3000));
    assert!(policy.permits_port(8080));
    assert!(!policy.permits_port(22));
    assert!(!policy.permits_port(3306));
    assert!(!policy.permits_port(3505));

    for bad in [
        json!({"allow": [80]}),
        json!({"deny_ports": ["10-5"]}),
        json!({"deny_ports": [0]}),
        json!({"deny_ports": [70000]}),
        json!({"enabled": "yes"}),
        json!("on"),
    ] {
        assert!(LoopbackForwardPolicy::from_config_value(&bad).is_err(), "{bad} must fail");
    }
}

#[test]
fn loopback_open_refuses_denied_ports() {
    let mux = mux("loopback-ports");
    let (listener, port) = target();
    let mut policy = LoopbackForwardPolicy::default();
    policy.deny_port(port);
    mux.set_loopback_forward_policy(policy);
    let mut client = Client::connect(&mux, "ports");
    client.opt_in();
    let reply = client.open(1, "127.0.0.1", port);
    assert_eq!(reply["error_code"], "loopback.denied-port");
    assert_no_accept(&listener);
}

#[test]
fn loopback_open_reports_nothing_listening() {
    let mux = mux("loopback-refused");
    let (listener, port) = target();
    drop(listener);
    let mut client = Client::connect(&mux, "refused");
    client.opt_in();
    let reply = client.open(1, "127.0.0.1", port);
    assert_eq!(reply["error_code"], "loopback.refused", "{reply}");
}

// MARK: Streams

#[test]
fn loopback_stream_round_trips_with_half_close() {
    let mux = mux("loopback-roundtrip");
    let (listener, port) = target();
    let server = std::thread::spawn(move || {
        let (mut socket, _) = listener.accept().unwrap();
        let mut received = Vec::new();
        socket.read_to_end(&mut received).unwrap();
        socket.write_all(b"pong:").unwrap();
        socket.write_all(&received).unwrap();
        received
    });
    let mut client = Client::connect(&mux, "roundtrip");
    client.opt_in();
    let reply = client.open(7, "localhost", port);
    assert_eq!(reply["ok"], true, "{reply}");
    assert_eq!(reply["data"]["stream"], 7);
    assert_eq!(reply["data"]["address"], format!("127.0.0.1:{port}"));
    assert_eq!(reply["data"]["window"], DAEMON_RECEIVE_WINDOW);

    client.send(json!({"cmd": "loopback-data", "stream": 7, "data": b64(b"ping")}));
    client.send(json!({"cmd": "loopback-shutdown", "stream": 7}));

    let mut body = Vec::new();
    let mut saw_eof = false;
    loop {
        let event = client.event(WAIT).expect("stream ended without loopback-closed");
        assert_eq!(event["stream"], 7, "{event}");
        match event["event"].as_str().unwrap() {
            "loopback-data" => {
                assert!(!saw_eof, "data after EOF");
                body.extend(unb64(event["data"].as_str().unwrap()));
            }
            "loopback-eof" => saw_eof = true,
            "loopback-credit" => {}
            "loopback-closed" => {
                assert!(event.get("error").is_none_or(Value::is_null), "{event}");
                break;
            }
            other => panic!("unexpected event {other}"),
        }
    }
    assert!(saw_eof);
    assert_eq!(body, b"pong:ping");
    assert_eq!(server.join().unwrap(), b"ping");
}

#[test]
fn loopback_stream_sends_no_more_than_the_client_window() {
    let mux = mux("loopback-window");
    let (listener, port) = target();
    let server = std::thread::spawn(move || {
        let (mut socket, _) = listener.accept().unwrap();
        // Blocks once the daemon stops reading; ends when the stream closes.
        let _ = socket.write_all(&vec![b'x'; 4 * 1024 * 1024]);
    });
    let mut client = Client::connect(&mux, "window");
    client.opt_in();
    let window = 16 * 1024;
    let reply = client.request(json!({
        "cmd": "loopback-open", "stream": 1, "host": "127.0.0.1", "port": port, "window": window,
    }));
    assert_eq!(reply["ok"], true, "{reply}");

    let received = |client: &mut Client, quiet: Duration| {
        let mut total = 0;
        while let Some(event) = client.event(quiet) {
            if event["event"] == "loopback-data" {
                total += unb64(event["data"].as_str().unwrap()).len();
            }
        }
        total
    };
    let first = received(&mut client, Duration::from_millis(400));
    assert_eq!(first, window, "the daemon must stop at the granted window");

    client.send(json!({"cmd": "loopback-credit", "stream": 1, "bytes": window}));
    let second = received(&mut client, Duration::from_millis(400));
    assert_eq!(second, window, "credit must release exactly the granted bytes");

    client.send(json!({"cmd": "loopback-close", "stream": 1}));
    drop(client);
    server.join().unwrap();
}

#[test]
fn loopback_stream_returns_credit_for_bytes_it_wrote() {
    let mux = mux("loopback-credit");
    let (listener, port) = target();
    let total = DAEMON_RECEIVE_WINDOW * 3;
    let server = std::thread::spawn(move || {
        let (mut socket, _) = listener.accept().unwrap();
        let mut received = Vec::new();
        socket.read_to_end(&mut received).unwrap();
        received.len()
    });
    let mut client = Client::connect(&mux, "credit");
    client.opt_in();
    assert_eq!(client.open(1, "127.0.0.1", port)["ok"], true);

    // Honor the daemon window: send only while credit allows.
    let mut credit = DAEMON_RECEIVE_WINDOW;
    let mut sent = 0;
    let frame = vec![b'y'; MAX_FRAME_BYTES];
    while sent < total {
        while credit < MAX_FRAME_BYTES {
            let event = client.event(WAIT).expect("no credit came back");
            if event["event"] == "loopback-credit" {
                credit += event["bytes"].as_u64().unwrap() as usize;
            }
        }
        client.send(json!({"cmd": "loopback-data", "stream": 1, "data": b64(&frame)}));
        credit -= MAX_FRAME_BYTES;
        sent += MAX_FRAME_BYTES;
    }
    client.send(json!({"cmd": "loopback-shutdown", "stream": 1}));
    assert_eq!(server.join().unwrap(), total);
}

#[test]
fn loopback_stream_ends_when_the_client_exceeds_the_daemon_window() {
    let forwarder = loopback_forward::window_probe();
    for _ in 0..DAEMON_RECEIVE_WINDOW / MAX_FRAME_BYTES {
        assert!(forwarder.push(MAX_FRAME_BYTES), "within the window must be accepted");
    }
    assert!(!forwarder.push(1), "one byte beyond the window must end the stream");
    assert_eq!(forwarder.closed_reason().as_deref(), Some("window-exceeded"));
}

#[test]
fn loopback_streams_close_when_the_control_connection_ends() {
    let mux = mux("loopback-disconnect");
    let (listener, port) = target();
    let mut client = Client::connect(&mux, "disconnect");
    client.opt_in();
    assert_eq!(client.open(1, "127.0.0.1", port)["ok"], true);
    let (mut socket, _) = listener.accept().unwrap();
    drop(client);
    socket.set_read_timeout(Some(WAIT)).unwrap();
    let mut buffer = [0_u8; 16];
    let read = socket.read(&mut buffer);
    assert!(matches!(read, Ok(0)) || read.is_err(), "the target must see the stream end");
}

#[test]
fn loopback_streams_are_limited_per_client() {
    let forwarder = loopback_forward::LoopbackForwarder::default();
    for stream in 0..MAX_STREAMS_PER_CLIENT as u64 {
        assert!(forwarder.reserve_for_test(1, stream), "slot {stream} must be free");
    }
    assert!(!forwarder.reserve_for_test(1, 10_000), "the per-client limit must hold");
    assert!(forwarder.reserve_for_test(2, 0), "another client has its own budget");
    forwarder.release_for_test(1);
    assert!(forwarder.reserve_for_test(1, 10_001), "a released slot is reusable");
}

#[test]
fn loopback_data_for_an_unknown_stream_is_refused() {
    let mux = mux("loopback-unknown");
    let mut client = Client::connect(&mux, "unknown");
    client.opt_in();
    client.send(json!({"cmd": "loopback-data", "stream": 99, "data": b64(b"x")}));
    let event = client.event(WAIT).expect("no refusal event");
    assert_eq!(event["event"], "loopback-closed");
    assert_eq!(event["stream"], 99);
    assert_eq!(event["error"], "unknown-stream");
}

#[test]
fn loopback_status_reports_limits_and_audit() {
    let mux = mux("loopback-status");
    let (listener, port) = target();
    drop(listener);
    let mut client = Client::connect(&mux, "status");
    client.opt_in();
    let _ = client.open(1, "127.0.0.1", port);
    let _ = client.open(2, "example.com", port);
    let status = client.request(json!({"cmd": "loopback-status"}));
    assert_eq!(status["ok"], true, "{status}");
    assert_eq!(status["data"]["enabled"], true);
    assert_eq!(status["data"]["limits"]["per_client"], MAX_STREAMS_PER_CLIENT);
    let outcomes: Vec<String> = status["data"]["audit"]
        .as_array()
        .unwrap()
        .iter()
        .map(|record| record["outcome"].as_str().unwrap().to_string())
        .collect();
    assert!(outcomes.contains(&"loopback.refused".to_string()), "{outcomes:?}");
    assert!(outcomes.contains(&"loopback.denied-host".to_string()), "{outcomes:?}");
}
