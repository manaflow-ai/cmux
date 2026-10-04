//! The link hands a peer stream only to the daemon's remote entry, stamped
//! with the identity of the WireGuard key it came from, and dials only
//! paired hosts.

use std::net::{IpAddr, SocketAddr};
use std::sync::Mutex;

use base64::Engine as _;
use base64::engine::general_purpose::STANDARD;
use cmux_link::overlay_addr::overlay_address;
use cmux_link::pairing::{PairingRecord, Pairings};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader, DuplexStream};

use super::dial::{Overlay, serve_dial};
use super::inbound::{InboundRefused, serve_inbound};

fn pairings() -> Pairings {
    let mut pairings = Pairings::default();
    pairings
        .upsert(PairingRecord {
            install: "inst_b".into(),
            user: "42".into(),
            team: "team_a".into(),
            public_key: STANDARD.encode([2u8; 32]),
            endpoint: None,
        })
        .unwrap();
    pairings
}

fn peer_addr(install: &str) -> SocketAddr {
    SocketAddr::new(IpAddr::V6(overlay_address(install)), 40000)
}

const STAMP_B: &str = r#"{"link_peer":{"install":"inst_b","user":"42","team":"team_a"}}"#;

/// RED (security): an inbound link stream goes to the daemon's remote entry,
/// stamped, and never to the session's local (admin) socket.
#[tokio::test]
async fn an_inbound_stream_reaches_only_the_remote_entry_never_the_local_socket() {
    let directory = cmux_unix_socket::short_test_dir("linkin");
    let session = directory.path().join("s.sock");
    let admin = std::os::unix::net::UnixListener::bind(&session).unwrap();
    admin.set_nonblocking(true).unwrap();
    let entry_path = cmux_link::entry_path::remote_entry_socket_path(&session);
    let entry = tokio::net::UnixListener::bind(&entry_path).unwrap();
    let (mut peer, link_side) = tokio::io::duplex(64 * 1024);
    let pairings = pairings();
    let session_for_task = session.clone();
    let task = tokio::spawn(async move {
        serve_inbound(link_side, [2; 32], peer_addr("inst_b"), &pairings, &session_for_task).await
    });
    peer.write_all(b"{\"service\":\"daemon\"}\n{\"id\":1,\"cmd\":\"ping\"}\n").await.unwrap();
    let accepted = tokio::time::timeout(super::lines::HANDSHAKE_TIMEOUT, entry.accept()).await;
    assert!(
        matches!(admin.accept(), Err(error) if error.kind() == std::io::ErrorKind::WouldBlock),
        "a link stream reached the local admin socket"
    );
    let (daemon_side, _) = accepted.expect("the remote entry got the stream").unwrap();
    let mut lines = BufReader::new(daemon_side).lines();
    assert_eq!(lines.next_line().await.unwrap().unwrap(), STAMP_B);
    assert_eq!(lines.next_line().await.unwrap().unwrap(), r#"{"id":1,"cmd":"ping"}"#);
    drop(peer);
    drop(lines);
    task.await.unwrap().unwrap();
}

#[tokio::test]
async fn an_unpaired_key_or_a_foreign_source_never_reaches_the_daemon() {
    let directory = cmux_unix_socket::short_test_dir("linkno");
    let session = directory.path().join("s.sock");
    let pairings = pairings();
    let (_peer, link_side) = tokio::io::duplex(1024);
    let refused = serve_inbound(link_side, [9; 32], peer_addr("inst_b"), &pairings, &session).await;
    assert_eq!(refused, Err(InboundRefused::UnknownPeer));
    let (_peer, link_side) = tokio::io::duplex(1024);
    let refused = serve_inbound(link_side, [2; 32], peer_addr("inst_c"), &pairings, &session).await;
    assert_eq!(refused, Err(InboundRefused::AddressMismatch));
    let (mut peer, link_side) = tokio::io::duplex(1024);
    peer.write_all(b"{\"service\":\"shell\"}\n").await.unwrap();
    let refused = serve_inbound(link_side, [2; 32], peer_addr("inst_b"), &pairings, &session).await;
    assert_eq!(refused, Err(InboundRefused::BadHello));
}

#[derive(Default)]
struct FakeOverlay {
    connects: Mutex<Vec<SocketAddr>>,
    far_end: Mutex<Option<DuplexStream>>,
    fail: bool,
}

impl Overlay for FakeOverlay {
    type Stream = DuplexStream;

    async fn connect(&self, remote: SocketAddr) -> std::io::Result<DuplexStream> {
        self.connects.lock().unwrap().push(remote);
        if self.fail {
            return Err(std::io::Error::new(std::io::ErrorKind::TimedOut, "no path"));
        }
        let (near, far) = tokio::io::duplex(64 * 1024);
        *self.far_end.lock().unwrap() = Some(far);
        Ok(near)
    }
}

async fn reply_line(caller: &mut DuplexStream) -> String {
    let mut reader = BufReader::new(caller);
    let mut line = String::new();
    reader.read_line(&mut line).await.unwrap();
    line
}

#[tokio::test]
async fn a_dial_to_a_paired_host_opens_its_link_port_and_reports_a_direct_path() {
    let overlay = FakeOverlay::default();
    let (mut caller, link_side) = tokio::io::duplex(64 * 1024);
    caller.write_all(b"{\"op\":\"link.dial\",\"host\":\"inst_b\",\"service\":\"daemon\"}\n").await.unwrap();
    let pairings = pairings();
    let dial = serve_dial(link_side, &overlay, &pairings);
    let check = async {
        assert_eq!(
            reply_line(&mut caller).await,
            "{\"ok\":true,\"path_state\":\"direct\",\"relay_available\":false}\n"
        );
        caller.write_all(b"hello server\n").await.unwrap();
        let far = overlay.far_end.lock().unwrap().take().unwrap();
        let mut far = BufReader::new(far);
        let mut hello = String::new();
        far.read_line(&mut hello).await.unwrap();
        assert_eq!(hello, "{\"service\":\"daemon\"}\n");
        let mut bytes = String::new();
        far.read_line(&mut bytes).await.unwrap();
        assert_eq!(bytes, "hello server\n");
        drop(caller);
    };
    tokio::join!(dial, check);
    assert_eq!(
        overlay.connects.lock().unwrap().as_slice(),
        &[SocketAddr::new(IpAddr::V6(overlay_address("inst_b")), cmux_link::LINK_PORT)]
    );
}

#[tokio::test]
async fn a_dial_to_an_unknown_or_unreachable_host_says_so_and_names_no_relay() {
    let pairings = pairings();
    let overlay = FakeOverlay::default();
    let (mut caller, link_side) = tokio::io::duplex(1024);
    caller.write_all(b"{\"op\":\"link.dial\",\"host\":\"inst_x\",\"service\":\"daemon\"}\n").await.unwrap();
    serve_dial(link_side, &overlay, &pairings).await;
    assert!(reply_line(&mut caller).await.contains("\"error_code\":\"unknown_host\""));
    assert!(overlay.connects.lock().unwrap().is_empty());

    let overlay = FakeOverlay { fail: true, ..FakeOverlay::default() };
    let (mut caller, link_side) = tokio::io::duplex(1024);
    caller.write_all(b"{\"op\":\"link.dial\",\"host\":\"inst_b\",\"service\":\"daemon\"}\n").await.unwrap();
    serve_dial(link_side, &overlay, &pairings).await;
    assert_eq!(
        reply_line(&mut caller).await,
        "{\"ok\":false,\"path_state\":\"unreachable\",\"relay_available\":false,\"error_code\":\"unreachable\"}\n"
    );
}
