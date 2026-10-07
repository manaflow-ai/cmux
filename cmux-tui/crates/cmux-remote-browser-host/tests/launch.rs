//! The app launch contract of `--serve` (src/launch.rs): the readiness line
//! the Mac app parses and the stdin lifeline that ends the host.

use std::io::{Cursor, Read};
use std::net::{SocketAddr, TcpListener};

use cmux_remote_browser_host::launch::{LISTENING_KEY, listening_line, watch_lifeline};

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
