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
use super::inbound::{InboundRefused, serve_inbound, serve_inbound_watched};
use cmux_link::owner_session::{OwnerRefused, OwnerSession};

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
    std::fs::create_dir_all(entry_path.parent().unwrap()).unwrap();
    let entry = tokio::net::UnixListener::bind(&entry_path).unwrap();
    let (mut peer, link_side) = tokio::io::duplex(64 * 1024);
    let pairings = pairings();
    let session_for_task = session.clone();
    let task = tokio::spawn(async move {
        serve_inbound(link_side, [2; 32], peer_addr("inst_b"), &pairings, &session_for_task, None)
            .await
    });
    peer.write_all(b"{\"service\":\"daemon\"}\n{\"id\":1,\"cmd\":\"ping\"}\n").await.unwrap();
    let accepted = tokio::time::timeout(super::lines::HANDSHAKE_TIMEOUT, entry.accept()).await;
    assert!(
        matches!(admin.accept(), Err(error) if error.kind() == std::io::ErrorKind::WouldBlock),
        "a link stream reached the local admin socket"
    );
    let (mut daemon_side, _) = accepted.expect("the remote entry got the stream").unwrap();
    daemon_side.write_all(b"{\"remote_entry\":1}\n").await.unwrap();
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
    let refused =
        serve_inbound(link_side, [9; 32], peer_addr("inst_b"), &pairings, &session, None).await;
    assert_eq!(refused, Err(InboundRefused::UnknownPeer));
    let (_peer, link_side) = tokio::io::duplex(1024);
    let refused =
        serve_inbound(link_side, [2; 32], peer_addr("inst_c"), &pairings, &session, None).await;
    assert_eq!(refused, Err(InboundRefused::AddressMismatch));
    let (mut peer, link_side) = tokio::io::duplex(1024);
    peer.write_all(b"{\"service\":\"shell\"}\n").await.unwrap();
    let refused =
        serve_inbound(link_side, [2; 32], peer_addr("inst_b"), &pairings, &session, None).await;
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

    async fn sync_peers(&self, _pairings: &Pairings) -> std::io::Result<()> {
        Ok(())
    }

    async fn set_cloud_peer(
        &self,
        _host: &str,
        _key: [u8; 32],
        _info: &cmux_link::connect_info::ConnectInfo,
    ) -> std::io::Result<()> {
        Ok(())
    }

    async fn forget_cloud_peer(&self, _host: &str) -> std::io::Result<()> {
        Ok(())
    }

    async fn path_state(&self, _key: &[u8; 32]) -> cmux_link::dial::PathState {
        cmux_link::dial::PathState::Direct
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
    caller
        .write_all(b"{\"op\":\"link.dial\",\"host\":\"inst_b\",\"service\":\"daemon\"}\n")
        .await
        .unwrap();
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
    caller
        .write_all(b"{\"op\":\"link.dial\",\"host\":\"inst_x\",\"service\":\"daemon\"}\n")
        .await
        .unwrap();
    serve_dial(link_side, &overlay, &pairings).await;
    assert!(reply_line(&mut caller).await.contains("\"error_code\":\"unknown_host\""));
    assert!(overlay.connects.lock().unwrap().is_empty());

    let overlay = FakeOverlay { fail: true, ..FakeOverlay::default() };
    let (mut caller, link_side) = tokio::io::duplex(1024);
    caller
        .write_all(b"{\"op\":\"link.dial\",\"host\":\"inst_b\",\"service\":\"daemon\"}\n")
        .await
        .unwrap();
    serve_dial(link_side, &overlay, &pairings).await;
    assert_eq!(
        reply_line(&mut caller).await,
        "{\"ok\":false,\"path_state\":\"unreachable\",\"relay_available\":false,\"error_code\":\"unreachable\"}\n"
    );
}

/// RED (security): a socket at the entry path that does not greet with the
/// entry banner (for example a session whose local admin socket happens to
/// sit there) never receives the stamp or the peer's bytes.
#[tokio::test]
async fn a_socket_that_is_not_a_remote_entry_never_gets_the_peer_stream() {
    let directory = cmux_unix_socket::short_test_dir("linknot");
    let session = directory.path().join("s.sock");
    let entry_path = cmux_link::entry_path::remote_entry_socket_path(&session);
    std::fs::create_dir_all(entry_path.parent().unwrap()).unwrap();
    let impostor = tokio::net::UnixListener::bind(&entry_path).unwrap();
    let (mut peer, link_side) = tokio::io::duplex(1024);
    peer.write_all(b"{\"service\":\"daemon\"}\n{\"id\":1,\"cmd\":\"ping\"}\n").await.unwrap();
    let pairings = pairings();
    let task = tokio::spawn(async move {
        serve_inbound(link_side, [2; 32], peer_addr("inst_b"), &pairings, &session, None).await
    });
    let (impostor_side, _) = impostor.accept().await.unwrap();
    let mut first = String::new();
    let read = tokio::time::timeout(
        super::lines::HANDSHAKE_TIMEOUT * 2,
        BufReader::new(impostor_side).read_line(&mut first),
    )
    .await;
    assert!(
        matches!(read, Ok(Ok(0))),
        "the link wrote {first:?} to a socket that never sent the entry banner"
    );
    assert_eq!(task.await.unwrap(), Err(InboundRefused::NotAnEntry));
}

/// RED (security): the link entry's gate admits exactly the seven `fs-v1`
/// ops; every other frame (identify, admin commands, unknown fs ops) is
/// denied before anything parses it.
#[test]
fn the_link_entry_gate_admits_only_the_fs_ops() {
    let gate = super::link_entry_gate();
    let peer = cmux_link::stamp::LinkPeer {
        install: "inst_b".into(),
        user: "42".into(),
        team: "team_a".into(),
    };
    for cmd in cmux_tui_core::fs_ops::FS_COMMANDS {
        let frame = serde_json::json!({ "id": 1, "cmd": cmd, "path": "/home/cmux" }).to_string();
        assert!(gate.admit(&peer, &frame), "{cmd}");
    }
    for frame in [
        r#"{"id":1,"cmd":"identify"}"#,
        r#"{"id":1,"cmd":"shutdown-daemon"}"#,
        r#"{"id":1,"cmd":"new-tab","cwd":"/"}"#,
        r#"{"id":1,"cmd":"fs.trash","paths":["/x"]}"#,
        r#"{"id":1,"cmd":"fs.watch","path":"/x"}"#,
        r#"{"cmux":"protocol/2","id":1,"op":"session.snapshot"}"#,
    ] {
        assert!(!gate.admit(&peer, frame), "{frame}");
    }
}

const BRAIN_IDENTIFY: &str = "{\"id\":1,\"ok\":true,\"data\":{\"app\":\"cmux-tui\",\"capabilities\":[\"workspace-registry-v1\",\"agent-session-tabs-v1\"]}}\n";

/// A brain daemon at `<home>/daemon/s.sock` that answers the identify probe
/// with `identify`, then echoes one line of the spliced stream.
fn fake_brain(
    home: &std::path::Path,
    identify: &'static str,
) -> (std::path::PathBuf, tokio::task::JoinHandle<Option<String>>) {
    std::fs::create_dir_all(home.join("daemon")).unwrap();
    let socket = home.join("daemon/s.sock");
    let listener = tokio::net::UnixListener::bind(&socket).unwrap();
    let task = tokio::spawn(async move {
        let (probe, _) = listener.accept().await.ok()?;
        let mut probe = BufReader::new(probe);
        let mut line = String::new();
        probe.read_line(&mut line).await.ok()?;
        probe.get_mut().write_all(identify.as_bytes()).await.ok()?;
        drop(probe);
        let (session, _) = tokio::time::timeout(super::lines::HANDSHAKE_TIMEOUT, listener.accept())
            .await
            .ok()?
            .ok()?;
        let mut session = BufReader::new(session);
        let mut first = String::new();
        session.read_line(&mut first).await.ok()?;
        session.get_mut().write_all(first.as_bytes()).await.ok()?;
        Some(first)
    });
    (socket, task)
}

fn owner(socket: &std::path::Path, home: &std::path::Path, user: &str) -> OwnerSession {
    OwnerSession {
        owner_user: user.into(),
        owner_team: "team_a".into(),
        socket: socket.to_path_buf(),
        brain_home: home.to_path_buf(),
    }
}

/// RED (security): the server's owner reaches the brain daemon's trusted
/// socket with an owner session; nothing goes to the remote entry and no
/// stamp is written.
#[tokio::test]
async fn the_owner_reaches_the_brain_daemon_with_an_owner_session() {
    let directory = cmux_unix_socket::short_test_dir("ownok");
    let home = directory.path().join("brain");
    let (socket, brain) = fake_brain(&home, BRAIN_IDENTIFY);
    let session = directory.path().join("s.sock");
    let config = owner(&socket, &home, "42");
    let (mut peer, link_side) = tokio::io::duplex(64 * 1024);
    let pairings = pairings();
    let task = tokio::spawn(async move {
        serve_inbound(link_side, [2; 32], peer_addr("inst_b"), &pairings, &session, Some(&config))
            .await
    });
    peer.write_all(b"{\"service\":\"owner_session\"}\n{\"id\":7,\"cmd\":\"list-workspaces\"}\n")
        .await
        .unwrap();
    let mut peer = BufReader::new(peer);
    let mut echoed = String::new();
    tokio::time::timeout(super::lines::HANDSHAKE_TIMEOUT, peer.read_line(&mut echoed))
        .await
        .unwrap()
        .unwrap();
    assert_eq!(echoed, "{\"id\":7,\"cmd\":\"list-workspaces\"}\n");
    assert_eq!(brain.await.unwrap().as_deref(), Some("{\"id\":7,\"cmd\":\"list-workspaces\"}\n"));
    drop(peer);
    task.await.unwrap().unwrap();
}

/// RED (security): a paired peer that is not the owner, a server without an
/// owner_session block, and a socket that is not a brain daemon all get
/// nothing.
#[tokio::test]
async fn a_non_owner_or_a_non_brain_socket_gets_no_owner_session() {
    let directory = cmux_unix_socket::short_test_dir("ownno");
    let home = directory.path().join("brain");
    let session = directory.path().join("s.sock");
    let hello: &[u8] = b"{\"service\":\"owner_session\"}\n";

    let (socket, _brain) = fake_brain(&home, BRAIN_IDENTIFY);
    let not_owner = owner(&socket, &home, "someone_else");
    let (mut peer, link_side) = tokio::io::duplex(1024);
    peer.write_all(hello).await.unwrap();
    let refused = serve_inbound(
        link_side,
        [2; 32],
        peer_addr("inst_b"),
        &pairings(),
        &session,
        Some(&not_owner),
    )
    .await;
    assert_eq!(refused, Err(InboundRefused::Owner(OwnerRefused::NotOwner)));

    let (mut peer, link_side) = tokio::io::duplex(1024);
    peer.write_all(hello).await.unwrap();
    let refused =
        serve_inbound(link_side, [2; 32], peer_addr("inst_b"), &pairings(), &session, None).await;
    assert_eq!(refused, Err(InboundRefused::Owner(OwnerRefused::NotConfigured)));

    let other_home = directory.path().join("other");
    let (plain, _plain_task) = fake_brain(
        &other_home,
        "{\"id\":1,\"ok\":true,\"data\":{\"app\":\"cmux-tui\",\"capabilities\":[]}}\n",
    );
    let config = owner(&plain, &other_home, "42");
    let (mut peer, link_side) = tokio::io::duplex(1024);
    peer.write_all(hello).await.unwrap();
    let refused = serve_inbound(
        link_side,
        [2; 32],
        peer_addr("inst_b"),
        &pairings(),
        &session,
        Some(&config),
    )
    .await;
    assert_eq!(refused, Err(InboundRefused::Owner(OwnerRefused::NotABrain)));
}

/// RED (security): revoking the owner's pairing while its owner session is
/// open closes that session at once (event-driven, no heartbeat wait), and
/// a redial with the revoked key is refused.
#[tokio::test]
async fn a_revoked_pairing_closes_an_open_owner_session_and_refuses_a_redial() {
    let directory = cmux_unix_socket::short_test_dir("ownrev");
    let home = directory.path().join("brain");
    std::fs::create_dir_all(home.join("daemon")).unwrap();
    let socket = home.join("daemon/s.sock");
    let listener = tokio::net::UnixListener::bind(&socket).unwrap();
    // A brain that answers the probe, then holds the session open.
    let brain = tokio::spawn(async move {
        let (probe, _) = listener.accept().await.unwrap();
        let mut probe = BufReader::new(probe);
        let mut line = String::new();
        probe.read_line(&mut line).await.unwrap();
        probe.get_mut().write_all(BRAIN_IDENTIFY.as_bytes()).await.unwrap();
        drop(probe);
        let (session, _) = listener.accept().await.unwrap();
        let mut session = BufReader::new(session);
        let mut first = String::new();
        session.read_line(&mut first).await.unwrap();
        session.get_mut().write_all(first.as_bytes()).await.unwrap();
        let mut rest = String::new();
        let _ = session.read_line(&mut rest).await;
    });
    let config = owner(&socket, &home, "42");
    let session_socket = directory.path().join("s.sock");
    let (sender, receiver) = tokio::sync::watch::channel(std::sync::Arc::new(pairings()));
    let (mut peer, link_side) = tokio::io::duplex(64 * 1024);
    let task = {
        let (config, session_socket) = (config.clone(), session_socket.clone());
        tokio::spawn(async move {
            serve_inbound_watched(
                link_side,
                [2; 32],
                peer_addr("inst_b"),
                &pairings(),
                &session_socket,
                Some(&config),
                Some(super::inbound::Revocations {
                    view: receiver,
                    open: std::sync::Arc::default(),
                }),
            )
            .await
        })
    };
    peer.write_all(b"{\"service\":\"owner_session\"}\nhello\n").await.unwrap();
    let mut peer = BufReader::new(peer);
    let mut echoed = String::new();
    tokio::time::timeout(super::lines::HANDSHAKE_TIMEOUT, peer.read_line(&mut echoed))
        .await
        .unwrap()
        .unwrap();
    assert_eq!(echoed, "hello\n", "the owner session is open");
    // Revoke: the new view no longer pairs inst_b.
    sender.send_replace(std::sync::Arc::new(Pairings::default()));
    let mut tail = String::new();
    let eof = tokio::time::timeout(std::time::Duration::from_secs(1), peer.read_line(&mut tail))
        .await
        .expect("the session did not close")
        .unwrap();
    assert_eq!(eof, 0, "the peer's stream is closed");
    // The dialing side closes too, which the server waits for.
    drop(peer);
    let served = tokio::time::timeout(std::time::Duration::from_secs(1), task)
        .await
        .expect("the server did not end the session")
        .unwrap();
    assert_eq!(served, Err(InboundRefused::Owner(OwnerRefused::NotOwner)));
    brain.abort();
    // A redial with the revoked key reaches nothing.
    let (mut again, link_side) = tokio::io::duplex(1024);
    again.write_all(b"{\"service\":\"owner_session\"}\n").await.unwrap();
    let refused = serve_inbound(
        link_side,
        [2; 32],
        peer_addr("inst_b"),
        &Pairings::default(),
        &session_socket,
        Some(&config),
    )
    .await;
    assert_eq!(refused, Err(InboundRefused::UnknownPeer));
}

/// `cmux link show` names the pairing file, which the app watches so a peer
/// change re-resolves a paired server's route (bead cx-ysq).
#[test]
fn link_show_names_the_pairing_file() {
    let directory = cmux_unix_socket::short_test_dir("linkshow");
    let state = super::state::LinkState::open(Some(directory.path().join("link"))).unwrap();
    state.init(&super::state::LinkConfig { install: "inst_show".into(), port: 4101 }).unwrap();
    let shown = super::show_json(&state).unwrap();
    assert_eq!(shown["peers_file"].as_str(), state.peers_path().to_str());
    assert_eq!(shown["install"].as_str(), Some("inst_show"));
}
