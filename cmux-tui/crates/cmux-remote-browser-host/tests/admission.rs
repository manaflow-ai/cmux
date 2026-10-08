//! The `--serve` listener's admission over a real loopback socket
//! (src/launch.rs `admit`): only a viewer whose first frame is an rd hello
//! carrying the per-launch secret reaches the welcome. Every other caller,
//! including a browser page that sends HTTP to the port, is turned away
//! before the host opens a tab or reads input.

use std::io::{Read, Write};
use std::net::{TcpListener, TcpStream};
use std::sync::mpsc;
use std::thread;
use std::time::Duration;

use cmux_rd_proto::control::Control as RdControl;
use cmux_rd_proto::{STREAM_CONTROL, STREAM_DATAGRAM, StreamDeframer, encode_stream_frame};
use cmux_remote_browser_host::launch::{Admission, admit_within};

const SECRET: &str = "5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a";

/// What the host decided, with the reason when it refused.
#[derive(Debug, PartialEq, Eq)]
enum Outcome {
    Admitted,
    Refused,
}

/// Starts one admission on a fresh loopback listener. The receiver yields
/// the outcome; it stays empty while the host still waits.
fn host(secret: Option<&'static str>, deadline: Duration) -> (u16, mpsc::Receiver<Outcome>) {
    let listener = TcpListener::bind("127.0.0.1:0").expect("bind");
    let port = listener.local_addr().expect("addr").port();
    let (tx, rx) = mpsc::channel();
    thread::spawn(move || {
        let (mut stream, _) = listener.accept().expect("accept");
        stream.set_read_timeout(Some(Duration::from_secs(10))).expect("timeout");
        let outcome = match admit_within(&mut stream, secret, deadline) {
            Ok(Admission::Admitted { .. }) => Outcome::Admitted,
            Ok(Admission::Refused(_)) | Err(_) => Outcome::Refused,
        };
        let _ = tx.send(outcome);
    });
    (port, rx)
}

fn hello(token: Option<&str>) -> Vec<u8> {
    let hello: RdControl = serde_json::from_value(serde_json::json!({
        "t": "hello", "user": "u", "install": "i", "class": "c", "interactive": true,
        "udp_port": null, "max_datagram": 1200, "token": token, "service": "rb/1",
        "caps": ["input.service"],
    }))
    .expect("hello");
    frame(STREAM_CONTROL, &serde_json::to_vec(&hello).expect("json"))
}

fn frame(kind: u8, payload: &[u8]) -> Vec<u8> {
    let mut out = Vec::new();
    encode_stream_frame(kind, payload, &mut out).expect("frame");
    out
}

/// Connects, sends `bytes`, and keeps the connection open.
fn connect(port: u16, bytes: &[u8]) -> TcpStream {
    let mut client = TcpStream::connect(("127.0.0.1", port)).expect("connect");
    client.write_all(bytes).expect("write");
    client
}

fn outcome(rx: &mpsc::Receiver<Outcome>) -> Option<Outcome> {
    rx.recv_timeout(Duration::from_secs(3)).ok()
}

/// The control frames the host wrote before it closed the connection.
fn replies(client: &mut TcpStream) -> Vec<RdControl> {
    client.set_read_timeout(Some(Duration::from_secs(3))).expect("timeout");
    let mut bytes = Vec::new();
    let _ = client.read_to_end(&mut bytes);
    let mut deframer = StreamDeframer::default();
    deframer.extend(&bytes);
    let mut out = Vec::new();
    while let Ok(Some((kind, payload))) = deframer.next_frame() {
        assert_eq!(kind, STREAM_CONTROL);
        out.push(serde_json::from_slice(&payload).expect("control"));
    }
    out
}

fn refused(replies: &[RdControl]) -> bool {
    matches!(replies, [RdControl::Refused { .. }])
}

#[test]
fn a_viewer_with_the_secret_is_admitted() {
    let (port, rx) = host(Some(SECRET), Duration::from_secs(5));
    let _client = connect(port, &hello(Some(SECRET)));
    assert_eq!(outcome(&rx), Some(Outcome::Admitted));
}

#[test]
fn a_viewer_without_a_token_is_refused() {
    let (port, rx) = host(Some(SECRET), Duration::from_secs(5));
    let mut client = connect(port, &hello(None));
    assert_eq!(outcome(&rx), Some(Outcome::Refused));
    assert!(refused(&replies(&mut client)));
}

#[test]
fn a_viewer_with_a_wrong_token_is_refused() {
    let (port, rx) = host(Some(SECRET), Duration::from_secs(5));
    let mut client = connect(port, &hello(Some(&"a5".repeat(32))));
    assert_eq!(outcome(&rx), Some(Outcome::Refused));
    assert!(refused(&replies(&mut client)));
}

/// A host that got no per-launch secret serves nobody (no open mode).
#[test]
fn a_host_without_a_secret_admits_nobody() {
    for token in [None, Some(SECRET)] {
        let (port, rx) = host(None, Duration::from_secs(5));
        let mut client = connect(port, &hello(token));
        assert_eq!(outcome(&rx), Some(Outcome::Refused), "token {token:?}");
        assert!(refused(&replies(&mut client)));
    }
}

/// A browser page can send HTTP to any loopback port (a no-cors fetch, or a
/// DNS-rebound name). The host closes it at once and answers nothing, even
/// while the page keeps the connection open.
#[test]
fn an_http_request_is_closed_without_a_reply() {
    for request in [
        "GET / HTTP/1.1\r\nHost: 127.0.0.1\r\nOrigin: https://evil.example\r\n\r\n".to_string(),
        format!(
            "POST / HTTP/1.1\r\nHost: rebind.evil.example\r\nContent-Length: 300\r\n\r\n{}",
            String::from_utf8_lossy(&hello(Some(SECRET)))
        ),
    ] {
        let (port, rx) = host(Some(SECRET), Duration::from_secs(5));
        let mut client = connect(port, request.as_bytes());
        assert_eq!(outcome(&rx), Some(Outcome::Refused), "{request:?}");
        assert!(replies(&mut client).is_empty());
    }
}

/// The first frame must be the hello: a viewer cannot send datagrams (input
/// or media) before it is admitted.
#[test]
fn a_frame_before_the_hello_is_refused() {
    let (port, rx) = host(Some(SECRET), Duration::from_secs(5));
    let mut bytes = frame(STREAM_DATAGRAM, b"early");
    bytes.extend(hello(Some(SECRET)));
    let mut client = connect(port, &bytes);
    assert_eq!(outcome(&rx), Some(Outcome::Refused));
    assert!(refused(&replies(&mut client)));
}

/// The host accepts one viewer at a time, so a caller that trickles bytes
/// must not hold the port: the hello has a total deadline, not only a
/// per-read timeout.
#[test]
fn a_trickled_hello_is_refused_at_the_deadline() {
    let (port, rx) = host(Some(SECRET), Duration::from_millis(300));
    let bytes = hello(Some(SECRET));
    let mut client = TcpStream::connect(("127.0.0.1", port)).expect("connect");
    for byte in &bytes[..bytes.len() - 1] {
        if client.write_all(std::slice::from_ref(byte)).is_err() {
            break;
        }
        if let Ok(outcome) = rx.try_recv() {
            assert_eq!(outcome, Outcome::Refused);
            return;
        }
        thread::sleep(Duration::from_millis(40));
    }
    assert_eq!(outcome(&rx), Some(Outcome::Refused));
}
