//! The app launch contract of `--serve` (src/launch.rs): the readiness line
//! the Mac app parses and the stdin lifeline that ends the host.

use std::io::{Cursor, Read};
use std::net::{SocketAddr, TcpListener};

use cmux_rd_proto::control::Control as RdControl;
use cmux_remote_browser_host::launch::{
    LISTENING_KEY, authorize, listening_line, loopback_only, read_secret, watch_lifeline,
};

#[test]
fn listening_line_names_the_port_the_os_bound() {
    let listener = TcpListener::bind("127.0.0.1:0").expect("bind");
    let bound = listener.local_addr().expect("addr");
    assert_ne!(bound.port(), 0);
    let line = listening_line(bound);
    assert!(!line.contains('\n'), "one line: {line}");
    let value: serde_json::Value = serde_json::from_str(&line).expect("json");
    let text = value[LISTENING_KEY].as_str().expect("listening field");
    assert_eq!(text.parse::<SocketAddr>().expect("addr"), bound);
}

/// The literal the Mac app's parser test uses
/// (LocalRemoteBrowserHostTests.parsesListeningLine).
#[test]
fn listening_line_matches_the_app_vector() {
    let bound: SocketAddr = "127.0.0.1:52144".parse().expect("addr");
    assert_eq!(listening_line(bound), r#"{"listening":"127.0.0.1:52144"}"#);
}

#[test]
fn lifeline_fires_once_at_end_of_file() {
    let mut fired = 0;
    watch_lifeline(Cursor::new(b"ignored bytes".to_vec()), || fired += 1);
    assert_eq!(fired, 1);
}

struct Failing;

impl Read for Failing {
    fn read(&mut self, _: &mut [u8]) -> std::io::Result<usize> {
        Err(std::io::Error::other("closed"))
    }
}

#[test]
fn lifeline_fires_on_a_read_error() {
    let mut fired = false;
    watch_lifeline(Failing, || fired = true);
    assert!(fired);
}

fn hello(token: Option<&str>) -> RdControl {
    serde_json::from_value(serde_json::json!({
        "t": "hello", "user": "u", "install": "i", "class": "c", "interactive": true,
        "udp_port": null, "max_datagram": 1200, "token": token, "service": "rb/1", "caps": ["input.service"],
    }))
    .expect("hello")
}

#[test]
fn the_secret_is_the_first_lifeline_line() {
    let mut input = Cursor::new(b"s3cret-0123\nlater bytes are the lifeline\n".to_vec());
    assert_eq!(read_secret(&mut input).as_deref(), Some("s3cret-0123"));
    assert_eq!(read_secret(&mut Cursor::new(b"\n".to_vec())), None, "empty line");
    assert_eq!(read_secret(&mut Cursor::new(Vec::new())), None, "end of file");
}

#[test]
fn a_viewer_without_the_right_secret_is_refused() {
    let good = "ab".repeat(32);
    assert!(authorize(Some(&good), &hello(Some(&good))).is_ok());
    assert!(authorize(Some(&good), &hello(Some(&"cd".repeat(32)))).is_err(), "wrong secret");
    assert!(authorize(Some(&good), &hello(None)).is_err(), "no secret");
    assert!(authorize(Some(&good), &hello(Some(&format!("{good}00")))).is_err(), "longer secret");
    assert!(authorize(Some(&good), &RdControl::Stop).is_err(), "not a hello");
    // A host started by hand (no lifeline secret) keeps the open dev behavior.
    assert!(authorize(None, &hello(None)).is_ok());
}

#[test]
fn the_host_listens_on_loopback_only() {
    for ok in ["127.0.0.1:0", "127.0.0.1:4103", "[::1]:0"] {
        assert!(loopback_only(ok.parse().expect("addr")).is_ok(), "{ok}");
    }
    for bad in ["0.0.0.0:4103", "[::]:0", "192.168.1.5:4103", "10.0.0.2:0"] {
        assert!(loopback_only(bad.parse().expect("addr")).is_err(), "{bad}");
    }
}
