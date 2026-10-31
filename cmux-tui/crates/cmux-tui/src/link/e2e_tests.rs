//! End to end on one machine: a dial on link B crosses two real WireGuard
//! meshes on loopback UDP and reaches link A's daemon remote entry, stamped
//! with B's paired identity; bytes flow both ways.

use std::net::{IpAddr, Ipv6Addr, SocketAddr};
use std::sync::Arc;
use std::time::Duration;

use base64::Engine as _;
use base64::engine::general_purpose::STANDARD;
use cmux_link::overlay_addr::overlay_address;
use cmux_link::pairing::{PairingRecord, Pairings};
use cmux_wg::{InterfaceAddress, WgMesh, WgMeshConfig};
use serde_json::{Value, json};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::net::UdpSocket;
use zeroize::Zeroizing;

use super::control::{Peers, serve_overlay};
use super::dial::{Overlay, serve_dial};
use super::mesh::MeshOverlay;

struct Node {
    install: &'static str,
    private: [u8; 32],
    public: [u8; 32],
    socket: UdpSocket,
}

async fn node(install: &'static str) -> Node {
    let (private, public) = cmux_wg::testing::random_keypair();
    let socket = UdpSocket::bind(SocketAddr::from((Ipv6Addr::LOCALHOST, 0))).await.unwrap();
    Node { install, private, public, socket }
}

fn record(node: &Node, endpoint: SocketAddr) -> PairingRecord {
    PairingRecord {
        install: node.install.into(),
        user: "42".into(),
        team: "team_a".into(),
        public_key: STANDARD.encode(node.public),
        endpoint: Some(endpoint),
    }
}

fn mesh(node: Node) -> MeshOverlay {
    let config = WgMeshConfig {
        private_key: Zeroizing::new(node.private),
        addresses: vec![InterfaceAddress {
            address: IpAddr::V6(overlay_address(node.install)),
            prefix: 128,
        }],
        mtu: super::state::LINK_MTU,
    };
    MeshOverlay::new(WgMesh::start(config, node.socket).unwrap(), Zeroizing::new(node.private))
}

async fn within<T>(future: impl Future<Output = T>) -> T {
    tokio::time::timeout(Duration::from_secs(10), future).await.expect("within 10 s")
}

#[tokio::test]
async fn a_dial_crosses_two_meshes_and_reaches_the_peer_daemon_entry_stamped() {
    let a = node("inst_a").await;
    let b = node("inst_b").await;
    exchange(a, b).await;
}

async fn exchange(a: Node, b: Node) {
    let server_install = a.install;
    let (a_udp, b_udp) = (a.socket.local_addr().unwrap(), b.socket.local_addr().unwrap());
    let directory = cmux_unix_socket::short_test_dir("linke2e");

    let mut pairings_a = Pairings::default();
    pairings_a.upsert(record(&b, b_udp)).unwrap();
    let peers_path = directory.path().join("peers.json");
    pairings_a.save(&peers_path).unwrap();
    let mut pairings_b = Pairings::default();
    pairings_b.upsert(record(&a, a_udp)).unwrap();

    let overlay_a = mesh(a);
    let overlay_b = mesh(b);
    overlay_a.sync_peers(&pairings_a).await.unwrap();
    overlay_b.sync_peers(&pairings_b).await.unwrap();

    let session = directory.path().join("s.sock");
    let entry_path = cmux_link::entry_path::remote_entry_socket_path(&session);
    std::fs::create_dir_all(entry_path.parent().unwrap()).unwrap();
    let entry = tokio::net::UnixListener::bind(&entry_path).unwrap();
    let listener = overlay_a.listen(cmux_link::LINK_PORT).await.unwrap();
    let peers = Arc::new(Peers::load(peers_path).unwrap());
    let server = tokio::spawn(serve_overlay(listener, peers, Some(session), None));

    let (mut caller, link_side) = tokio::io::duplex(64 * 1024);
    let dial = tokio::spawn(async move { serve_dial(link_side, &overlay_b, &pairings_b).await });
    caller
        .write_all(format!("{{\"op\":\"link.dial\",\"host\":\"{server_install}\",\"service\":\"daemon\"}}\nping\n").as_bytes())
        .await
        .unwrap();
    let mut caller = BufReader::new(caller);
    let mut reply = String::new();
    within(caller.read_line(&mut reply)).await.unwrap();
    assert_eq!(reply, "{\"ok\":true,\"path_state\":\"direct\",\"relay_available\":false}\n");

    let (mut daemon_side, _) = within(entry.accept()).await.unwrap();
    daemon_side.write_all(b"{\"remote_entry\":1}\n").await.unwrap();
    let mut daemon = BufReader::new(daemon_side);
    let mut stamp = String::new();
    within(daemon.read_line(&mut stamp)).await.unwrap();
    assert_eq!(
        stamp,
        "{\"link_peer\":{\"install\":\"inst_b\",\"user\":\"42\",\"team\":\"team_a\"}}\n"
    );
    let mut ping = String::new();
    within(daemon.read_line(&mut ping)).await.unwrap();
    assert_eq!(ping, "ping\n");
    daemon.get_mut().write_all(b"pong\n").await.unwrap();
    let mut pong = String::new();
    within(caller.read_line(&mut pong)).await.unwrap();
    assert_eq!(pong, "pong\n");

    drop(caller);
    drop(daemon);
    within(dial).await.unwrap();
    server.abort();
}

/// A controlled, admitted entry verifies payload transport with the enrollment
/// key. The public CLI test separately checks the real daemon's unchecked-peer
/// refusal; this fixture does not mint a control-plane grant.
#[tokio::test]
async fn paired_server_link_enrolled_key_exchanges_bytes_over_two_meshes() {
    use cmux_server::pairing::{self, Transport};
    use cmux_server_core::pairing::enrollment::{Begun, Paired, Waited, jwk_thumbprint};

    const INSTALL: &str = "inst_00000000000000000001";
    const NOW: u64 = 1_790_978_474_000;
    #[derive(Default)]
    struct Api(std::sync::Mutex<Option<String>>);
    impl Transport for Api {
        fn health(&self, _: &str) -> cmux_server::Result<Value> {
            Ok(json!({"environment":"staging"}))
        }
        fn begin(&self, _: &str, body: &Value) -> cmux_server::Result<Value> {
            *self.0.lock().unwrap() = Some(body["wg_public_key"].as_str().unwrap().into());
            Ok(json!({"code":"7KQ4M2XD","expires_at":NOW+600_000,
                "thumbprint":jwk_thumbprint(&body["public_jwk"]).unwrap(),
                "collect_secret":"AAAAAAAAAAAAAAAAAAAAAA.aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}))
        }
        fn wait(&self, _: &str, _: &Begun) -> cmux_server::Result<Waited> {
            Ok(Waited::Paired(Paired {
                host: "host_00000000000000000001".into(),
                team: "team_00000000000000000001".into(),
                user: "user_00000000000000000001".into(),
                install: INSTALL.into(),
            }))
        }
    }
    let home = cmux_unix_socket::short_test_dir("pairedmesh");
    let identity = home.path().join("pairing/identity.json");
    let api = Api::default();
    pairing::enroll(&identity, "https://api.example.test",
        json!({"name":"Fixture server","platform":"linux","os_version":"test","arch":"aarch64","cmux_version":"1.0.0"}),
        None, &api, NOW, |_| Ok(())).unwrap();
    let saved = std::fs::read(&identity).unwrap();
    let state = super::state::LinkState::open(Some(home.path().join("link"))).unwrap();
    state
        .init(&super::state::LinkConfig {
            install: INSTALL.into(),
            port: 0,
            server_identity: Some(identity.clone()),
        })
        .unwrap();
    let private = *state.private_key().unwrap();
    let public = super::state::public_key(&private);
    assert_eq!(STANDARD.encode(public), api.0.lock().unwrap().as_deref().unwrap());
    let socket = UdpSocket::bind(SocketAddr::from((Ipv6Addr::LOCALHOST, 0))).await.unwrap();
    exchange(Node { install: INSTALL, private, public, socket }, node("inst_b").await).await;
    assert!(!state.dir().join("private.key").exists());
    assert!(std::fs::read(&identity).unwrap() == saved, "enrollment record changed");
}

/// A paired install that rotates its key keeps its overlay `/128`; the sync
/// removes the old key before it adds the new one, so the reload succeeds
/// (review P2-2), and syncing the same file again changes nothing.
#[tokio::test]
async fn a_rotated_peer_key_syncs_cleanly() {
    let a = node("inst_a").await;
    let b_old = node("inst_b").await;
    let b_new = node("inst_b").await;
    let endpoint = b_old.socket.local_addr().unwrap();
    let overlay_a = mesh(a);
    let mut pairings = Pairings::default();
    pairings.upsert(record(&b_old, endpoint)).unwrap();
    within(overlay_a.sync_peers(&pairings)).await.unwrap();
    within(overlay_a.sync_peers(&pairings)).await.unwrap();
    pairings.upsert(record(&b_new, endpoint)).unwrap();
    assert_eq!(pairings.peers.len(), 1);
    within(overlay_a.sync_peers(&pairings)).await.expect("a rotated key must sync");
    within(overlay_a.sync_peers(&Pairings::default())).await.unwrap();
}

const BRAIN_IDENTIFY: &str = "{\"id\":1,\"ok\":true,\"data\":{\"app\":\"cmux-tui\",\"capabilities\":[\"workspace-registry-v1\",\"agent-session-tabs-v1\"]}}\n";

/// RED (security, real mesh): revoking the owner's pairing while its owner
/// session is open closes the stream on the DIALING side too. The server
/// must close the session before it removes the WireGuard peer: once the
/// peer is gone its FIN can no longer reach the client.
#[tokio::test]
async fn a_revoke_closes_the_owner_session_on_the_dialing_side() {
    let a = node("inst_a").await;
    let b = node("inst_b").await;
    let (a_udp, b_udp) = (a.socket.local_addr().unwrap(), b.socket.local_addr().unwrap());
    let directory = cmux_unix_socket::short_test_dir("linkrev");
    let mut pairings_a = Pairings::default();
    pairings_a.upsert(record(&b, b_udp)).unwrap();
    let peers_path = directory.path().join("peers.json");
    pairings_a.save(&peers_path).unwrap();
    let mut pairings_b = Pairings::default();
    pairings_b.upsert(record(&a, a_udp)).unwrap();
    let overlay_a = Arc::new(mesh(a));
    let overlay_b = mesh(b);
    overlay_a.sync_peers(&pairings_a).await.unwrap();
    overlay_b.sync_peers(&pairings_b).await.unwrap();

    // The brain daemon: answers the identify probe, then holds the session.
    let home = directory.path().join("brain");
    std::fs::create_dir_all(home.join("daemon")).unwrap();
    let brain_socket = home.join("daemon/s.sock");
    let brain = tokio::net::UnixListener::bind(&brain_socket).unwrap();
    let brain_task = tokio::spawn(async move {
        let (probe, _) = brain.accept().await.unwrap();
        let mut probe = BufReader::new(probe);
        let mut line = String::new();
        probe.read_line(&mut line).await.unwrap();
        probe.get_mut().write_all(BRAIN_IDENTIFY.as_bytes()).await.unwrap();
        drop(probe);
        let (session, _) = brain.accept().await.unwrap();
        let mut session = BufReader::new(session);
        let mut first = String::new();
        session.read_line(&mut first).await.unwrap();
        session.get_mut().write_all(first.as_bytes()).await.unwrap();
        // Everything the brain receives after the first line: must be nothing.
        let mut rest = Vec::new();
        let _ = tokio::io::AsyncReadExt::read_to_end(&mut session, &mut rest).await;
        rest
    });
    let owner = cmux_link::owner_session::OwnerSession {
        owner_user: "42".into(),
        owner_team: "team_a".into(),
        socket: brain_socket,
        brain_home: home,
    };
    let session = directory.path().join("s.sock");
    let listener = overlay_a.listen(cmux_link::LINK_PORT).await.unwrap();
    let peers = Arc::new(Peers::load(peers_path.clone()).unwrap());
    let server =
        tokio::spawn(serve_overlay(listener, peers.clone(), Some(session), Some(Arc::new(owner))));

    let (mut caller, link_side) = tokio::io::duplex(64 * 1024);
    let dial = tokio::spawn(async move { serve_dial(link_side, &overlay_b, &pairings_b).await });
    caller
        .write_all(
            b"{\"op\":\"link.dial\",\"host\":\"inst_a\",\"service\":\"owner_session\"}\nhello\n",
        )
        .await
        .unwrap();
    let mut caller = BufReader::new(caller);
    let mut reply = String::new();
    within(caller.read_line(&mut reply)).await.unwrap();
    assert!(reply.starts_with("{\"ok\":true"), "{reply}");
    let mut echoed = String::new();
    within(caller.read_line(&mut echoed)).await.unwrap();
    assert_eq!(echoed, "hello\n", "the owner session is open over the real mesh");

    // Revoke: the pairing file loses inst_b and the link reloads it.
    Pairings::default().save(&peers_path).unwrap();
    within(peers.reload(&*overlay_a)).await.unwrap();
    let mut tail = String::new();
    let closed = tokio::time::timeout(Duration::from_secs(3), caller.read_line(&mut tail)).await;
    assert!(
        matches!(closed, Ok(Ok(0))),
        "the dialing side must see the session end, got {closed:?} {tail:?}"
    );
    // No access leak: bytes the revoked dialer still writes never reach the
    // brain socket (its session there has ended, and the peer is gone).
    let _ = caller.get_mut().write_all(b"after-revoke\n").await;
    let leaked = within(brain_task).await.unwrap();
    assert!(
        leaked.is_empty(),
        "the brain received {:?} after the revoke",
        String::from_utf8_lossy(&leaked)
    );
    drop(caller);
    let _ = within(dial).await;
    server.abort();
}

#[tokio::test]
async fn a_revoke_closes_the_daemon_stream_before_removing_its_wireguard_peer() {
    let a = node("inst_a").await;
    let b = node("inst_b").await;
    let (a_udp, b_udp) = (a.socket.local_addr().unwrap(), b.socket.local_addr().unwrap());
    let directory = cmux_unix_socket::short_test_dir("revwg");
    let mut pairings_a = Pairings::default();
    pairings_a.upsert(record(&b, b_udp)).unwrap();
    let path = directory.path().join("peers.json");
    pairings_a.save(&path).unwrap();
    let mut pairings_b = Pairings::default();
    pairings_b.upsert(record(&a, a_udp)).unwrap();
    let overlay_a = Arc::new(mesh(a));
    let overlay_b = mesh(b);
    overlay_a.sync_peers(&pairings_a).await.unwrap();
    overlay_b.sync_peers(&pairings_b).await.unwrap();
    let session = directory.path().join("s.sock");
    let entry_path = cmux_link::entry_path::remote_entry_socket_path(&session);
    std::fs::create_dir_all(entry_path.parent().unwrap()).unwrap();
    let entry = tokio::net::UnixListener::bind(entry_path).unwrap();
    let endpoint = tokio::spawn(async move {
        let (mut stream, _) = entry.accept().await.unwrap();
        stream.write_all(b"{\"remote_entry\":1}\n").await.unwrap();
        let mut stream = BufReader::new(stream);
        let mut line = String::new();
        stream.read_line(&mut line).await.unwrap();
        assert_eq!(cmux_link::stamp::parse(&line).unwrap().peer.install, "inst_b");
        line.clear();
        stream.read_line(&mut line).await.unwrap();
        stream.get_mut().write_all(line.as_bytes()).await.unwrap();
        let mut rest = Vec::new();
        let _ = tokio::io::AsyncReadExt::read_to_end(&mut stream, &mut rest).await;
        rest
    });
    let listener = overlay_a.listen(cmux_link::LINK_PORT).await.unwrap();
    let peers = Arc::new(Peers::load(path.clone()).unwrap());
    let server = tokio::spawn(serve_overlay(listener, peers.clone(), Some(session), None));
    let (mut caller, link_side) = tokio::io::duplex(64 * 1024);
    let dial = tokio::spawn(async move { serve_dial(link_side, &overlay_b, &pairings_b).await });
    caller
        .write_all(b"{\"op\":\"link.dial\",\"host\":\"inst_a\",\"service\":\"daemon\"}\nhello\n")
        .await
        .unwrap();
    let mut caller = BufReader::new(caller);
    let mut line = String::new();
    within(caller.read_line(&mut line)).await.unwrap();
    assert!(line.starts_with("{\"ok\":true"));
    line.clear();
    within(caller.read_line(&mut line)).await.unwrap();
    assert_eq!(line, "hello\n");
    Pairings::default().save(&path).unwrap();
    within(peers.reload(&*overlay_a)).await.unwrap();
    line.clear();
    let closed = tokio::time::timeout(Duration::from_secs(3), caller.read_line(&mut line)).await;
    assert!(matches!(closed, Ok(Ok(0))), "the dialing side did not receive the close: {closed:?}");
    let _ = caller.get_mut().write_all(b"after-revoke\n").await;
    assert!(within(endpoint).await.unwrap().is_empty(), "revoked bytes reached the daemon entry");
    drop(caller);
    let _ = within(dial).await;
    server.abort();
}

#[tokio::test]
async fn outgoing_revocation_and_endpoint_updates_work_across_two_real_meshes() {
    let a = node("inst_a").await;
    let b = node("inst_b").await;
    let (a_udp, b_udp) = (a.socket.local_addr().unwrap(), b.socket.local_addr().unwrap());
    let directory = cmux_unix_socket::short_test_dir("outwg");
    let mut pairings_a = Pairings::default();
    pairings_a.upsert(record(&b, b_udp)).unwrap();
    let path_a = directory.path().join("a.json");
    pairings_a.save(&path_a).unwrap();
    let mut pairings_b = Pairings::default();
    pairings_b.upsert(record(&a, a_udp)).unwrap();
    let path_b = directory.path().join("b.json");
    pairings_b.save(&path_b).unwrap();
    let overlay_a = Arc::new(mesh(a));
    let overlay_b = Arc::new(mesh(b));
    overlay_a.sync_peers(&pairings_a).await.unwrap();
    overlay_b.sync_peers(&pairings_b).await.unwrap();

    let session = directory.path().join("s.sock");
    let entry_path = cmux_link::entry_path::remote_entry_socket_path(&session);
    std::fs::create_dir_all(entry_path.parent().unwrap()).unwrap();
    let entry = tokio::net::UnixListener::bind(entry_path).unwrap();
    let endpoint = tokio::spawn(async move {
        let (mut stream, _) = entry.accept().await.unwrap();
        stream.write_all(b"{\"remote_entry\":1}\n").await.unwrap();
        let mut stream = BufReader::new(stream);
        let mut line = String::new();
        stream.read_line(&mut line).await.unwrap();
        assert_eq!(cmux_link::stamp::parse(&line).unwrap().peer.install, "inst_b");
        line.clear();
        stream.read_line(&mut line).await.unwrap();
        assert_eq!(line, "hello\n");
        stream.get_mut().write_all(b"answer\n").await.unwrap();
        line.clear();
        stream.read_line(&mut line).await.unwrap();
        assert_eq!(line, "after-endpoint-update\n");
        stream.get_mut().write_all(line.as_bytes()).await.unwrap();
        let mut rest = Vec::new();
        tokio::io::AsyncReadExt::read_to_end(&mut stream, &mut rest).await.unwrap();
        rest
    });
    let listener = overlay_a.listen(cmux_link::LINK_PORT).await.unwrap();
    let incoming = tokio::spawn(serve_overlay(
        listener,
        Arc::new(Peers::load(path_a).unwrap()),
        Some(session),
        None,
    ));
    let local_path = directory.path().join("l.sock");
    let local = tokio::net::UnixListener::bind(&local_path).unwrap();
    let peers_b = Arc::new(Peers::load(path_b.clone()).unwrap());
    let outgoing = tokio::spawn(super::control::serve_local(
        local,
        overlay_b.clone(),
        peers_b.clone(),
        Arc::new(super::cloud::CloudResolver::new(super::cloud::RelaySource::unavailable())),
        Arc::from("{}"),
    ));
    let mut caller = tokio::net::UnixStream::connect(local_path).await.unwrap();
    caller
        .write_all(b"{\"op\":\"link.dial\",\"host\":\"inst_a\",\"service\":\"daemon\"}\nhello\n")
        .await
        .unwrap();
    let mut caller = BufReader::new(caller);
    let mut line = String::new();
    within(caller.read_line(&mut line)).await.unwrap();
    assert!(line.starts_with("{\"ok\":true"));
    line.clear();
    within(caller.read_line(&mut line)).await.unwrap();
    assert_eq!(line, "answer\n");

    // Clearing a configured endpoint keeps the route authenticated traffic
    // already established; it must not abort this stream during peer sync.
    pairings_b.peers[0].endpoint = None;
    pairings_b.save(&path_b).unwrap();
    within(peers_b.reload(&*overlay_b)).await.unwrap();
    caller.get_mut().write_all(b"after-endpoint-update\n").await.unwrap();
    line.clear();
    within(caller.read_line(&mut line)).await.unwrap();
    assert_eq!(line, "after-endpoint-update\n");

    Pairings::default().save(&path_b).unwrap();
    let closed = async {
        line.clear();
        assert_eq!(caller.read_line(&mut line).await.unwrap(), 0);
        let _ = caller.get_mut().write_all(b"after-revoke\n").await;
        assert!(endpoint.await.unwrap().is_empty(), "revoked bytes reached the remote entry");
    };
    let (reloaded, ()) = within(async { tokio::join!(peers_b.reload(&*overlay_b), closed) }).await;
    reloaded.unwrap();
    incoming.abort();
    outgoing.abort();
}
