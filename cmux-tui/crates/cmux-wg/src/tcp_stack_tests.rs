//! Unit tests of the stack's peer tags: an accepted connection carries the
//! key of the session that delivered its SYN, never one guessed from its
//! address, and removing a peer fails its streams.

use std::net::{IpAddr, SocketAddr};

use tokio::io::AsyncReadExt;

use super::*;

const SERVER: &str = "fd7c:6d78::1";
const CLIENT: &str = "fd7c:6d78::2";
const KEY: PeerKey = [7; 32];

fn address(text: &str) -> IpAddr {
    text.parse().unwrap()
}

fn stack(own: &str, tagged: bool) -> TcpStack {
    let addresses = [InterfaceAddress { address: address(own), prefix: 128 }];
    TcpStack::new(&addresses, 1380, Arc::new(Notify::new()), tagged).unwrap()
}

#[test]
fn syn_origins_stay_bounded() {
    let mut server = stack(SERVER, true);
    let _incoming = server.begin_listen(4100).unwrap();
    for port in 0..(MAX_SYN_ORIGINS as u16 + 500) {
        let mut client = stack(CLIENT, false);
        let (reply, _answer) = oneshot::channel();
        client.next_port = 10_000 + port;
        client.begin_connect(address(CLIENT), SocketAddr::new(address(SERVER), 4100), None, reply);
        client.step();
        while let Some(packet) = client.pop_tx() {
            server.push_rx(packet, Some(KEY));
        }
        // The SYNs are never processed: the device keeps them, the map may not.
        assert!(server.syn_origins.as_ref().unwrap().len() <= MAX_SYN_ORIGINS);
    }
}

#[test]
fn stream_window_parses_bytes_and_suffixes_within_bounds() {
    use crate::tcp_stack::{MAX_STREAM_WINDOW, MIN_STREAM_WINDOW, parse_window};
    assert_eq!(parse_window("262144"), Some(256 * 1024));
    assert_eq!(parse_window("256K"), Some(256 * 1024));
    assert_eq!(parse_window(" 2m "), Some(2 << 20));
    assert_eq!(parse_window("1"), Some(MIN_STREAM_WINDOW));
    assert_eq!(parse_window("1024M"), Some(MAX_STREAM_WINDOW));
    assert_eq!(parse_window("lots"), None);
    assert_eq!(parse_window(""), None);
}

#[test]
fn a_new_connection_buffers_one_stream_window() {
    let socket = TcpStack::new_socket(
        std::time::Duration::from_secs(60),
        smoltcp::socket::tcp::CongestionControl::Cubic,
        crate::tcp_stack::DEFAULT_STREAM_WINDOW,
    );
    assert_eq!(socket.recv_capacity(), crate::tcp_stack::DEFAULT_STREAM_WINDOW);
    assert_eq!(socket.send_capacity(), crate::tcp_stack::DEFAULT_STREAM_WINDOW);
    assert!(crate::tcp_stack::DEFAULT_STREAM_WINDOW > 256 * 1024);
}
