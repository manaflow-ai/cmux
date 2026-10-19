//! Actual paired carrier bytes and local entry sockets across view changes.
use std::future::Future;
use std::net::{IpAddr, SocketAddr};
use std::sync::Arc;
use std::time::Duration;

use base64::Engine as _;
use base64::engine::general_purpose::STANDARD;
use cmux_link::owner_session::OwnerSession;
use cmux_link::pairing::{PairingRecord, Pairings};
use tokio::io::{AsyncBufReadExt, AsyncReadExt, AsyncWriteExt, BufReader, DuplexStream};
use tokio::net::UnixStream;

use super::inbound::{InboundRefused, Revocations, serve_inbound_watched};

fn pairings() -> Pairings {
    Pairings {
        peers: vec![PairingRecord {
            install: "inst_b".into(),
            user: "42".into(),
            team: "team_a".into(),
            public_key: STANDARD.encode([2u8; 32]),
            endpoint: None,
        }],
    }
}

fn address() -> SocketAddr {
    SocketAddr::new(IpAddr::V6(cmux_link::overlay_addr::overlay_address("inst_b")), 40000)
}

async fn within<T>(future: impl Future<Output = T>) -> T {
    tokio::time::timeout(Duration::from_secs(10), future).await.expect("within 10 seconds")
}

struct OpenDaemon {
    _directory: cmux_unix_socket::TestDir,
    view: tokio::sync::watch::Sender<Arc<Pairings>>,
    peer: BufReader<DuplexStream>,
    entry: BufReader<UnixStream>,
    task: tokio::task::JoinHandle<Result<(), InboundRefused>>,
}

async fn open_daemon() -> OpenDaemon {
    let directory = cmux_unix_socket::short_test_dir("linkrev");
    let session = directory.path().join("s.sock");
    let entry_path = cmux_link::entry_path::remote_entry_socket_path(&session);
    std::fs::create_dir_all(entry_path.parent().unwrap()).unwrap();
    let listener = tokio::net::UnixListener::bind(entry_path).unwrap();
    let (view, receiver) = tokio::sync::watch::channel(Arc::new(pairings()));
    let (mut peer, stream) = tokio::io::duplex(64 * 1024);
    peer.write_all(b"{\"service\":\"daemon\"}\nhello\n").await.unwrap();
    let task = tokio::spawn(async move {
        serve_inbound_watched(
            stream,
            [2; 32],
            address(),
            &pairings(),
            &session,
            None,
            Some(Revocations { view: receiver, open: Arc::default() }),
        )
        .await
    });
    let (mut entry, _) = within(listener.accept()).await.unwrap();
    entry.write_all(cmux_link::entry_path::ENTRY_BANNER.as_bytes()).await.unwrap();
    entry.write_all(b"\n").await.unwrap();
    let mut entry = BufReader::new(entry);
    let mut stamp = String::new();
    within(entry.read_line(&mut stamp)).await.unwrap();
    assert_eq!(cmux_link::stamp::parse(&stamp).unwrap().peer, pairings().peers[0].peer());
    let mut hello = String::new();
    within(entry.read_line(&mut hello)).await.unwrap();
    assert_eq!(hello, "hello\n");
    OpenDaemon { _directory: directory, view, peer: BufReader::new(peer), entry, task }
}

impl OpenDaemon {
    async fn changed(mut self, fresh: Pairings) -> (bool, Vec<u8>, Result<(), InboundRefused>) {
        self.view.send_replace(Arc::new(fresh));
        let mut tail = String::new();
        let closed =
            tokio::time::timeout(Duration::from_secs(1), self.peer.read_line(&mut tail)).await;
        let _ = self.peer.get_mut().write_all(b"after-update\n").await;
        drop(self.peer);
        let mut leaked = Vec::new();
        within(self.entry.read_to_end(&mut leaked)).await.unwrap();
        drop(self.entry);
        let served = within(self.task).await.unwrap();
        (matches!(closed, Ok(Ok(0))), leaked, served)
    }
}

#[tokio::test]
async fn peer_revocation_closes_an_open_daemon_stream_and_its_entry() {
    let (closed, leaked, served) = open_daemon().await.changed(Pairings::default()).await;
    assert!(closed, "the revoked daemon carrier stayed open");
    assert!(leaked.is_empty(), "bytes reached the entry after revocation");
    assert_eq!(served, Err(InboundRefused::UnknownPeer));
}

#[tokio::test]
async fn a_same_key_identity_change_closes_the_old_daemon_stream() {
    let mut failures = Vec::new();
    for field in ["install", "user", "team"] {
        let mut fresh = pairings();
        match field {
            "install" => fresh.peers[0].install = "inst_changed".into(),
            "user" => fresh.peers[0].user = "changed".into(),
            "team" => fresh.peers[0].team = "team_changed".into(),
            _ => unreachable!(),
        }
        let (closed, leaked, _) = open_daemon().await.changed(fresh).await;
        if !closed || !leaked.is_empty() {
            failures.push(field);
        }
    }
    assert!(failures.is_empty(), "old streams survived changed identities: {failures:?}");
}

#[tokio::test]
async fn an_endpoint_only_update_keeps_the_same_daemon_identity_connected() {
    let mut daemon = open_daemon().await;
    let mut fresh = pairings();
    fresh.peers[0].endpoint = Some("127.0.0.1:4101".parse().unwrap());
    daemon.view.send_replace(Arc::new(fresh));
    daemon.peer.get_mut().write_all(b"still-open\n").await.unwrap();
    let mut line = String::new();
    within(daemon.entry.read_line(&mut line)).await.unwrap();
    assert_eq!(line, "still-open\n");
    daemon.entry.get_mut().write_all(b"reply\n").await.unwrap();
    line.clear();
    within(daemon.peer.read_line(&mut line)).await.unwrap();
    assert_eq!(line, "reply\n");
    drop(daemon.peer);
    drop(daemon.entry);
    within(daemon.task).await.unwrap().unwrap();
}

#[tokio::test]
async fn a_stale_pairing_snapshot_cannot_reopen_a_revoked_daemon_or_owner() {
    let mut failures = Vec::new();
    for service in ["daemon", "owner_session"] {
        let directory = cmux_unix_socket::short_test_dir("revstart");
        let session = directory.path().join("s.sock");
        let home = directory.path().join("brain");
        std::fs::create_dir_all(home.join("daemon")).unwrap();
        let brain = home.join("daemon/s.sock");
        let target = if service == "daemon" {
            cmux_link::entry_path::remote_entry_socket_path(&session)
        } else {
            brain.clone()
        };
        std::fs::create_dir_all(target.parent().unwrap()).unwrap();
        let listener = tokio::net::UnixListener::bind(target).unwrap();
        let touched = Arc::new(std::sync::atomic::AtomicBool::new(false));
        let observed = touched.clone();
        let entry = tokio::spawn(async move {
            let (mut socket, _) = listener.accept().await.unwrap();
            observed.store(true, std::sync::atomic::Ordering::SeqCst);
            if service == "owner_session" {
                let mut probe = BufReader::new(socket);
                let mut request = String::new();
                probe.read_line(&mut request).await.unwrap();
                probe.get_mut().write_all(b"{\"id\":1,\"ok\":true,\"data\":{\"app\":\"cmux-tui\",\"capabilities\":[\"workspace-registry-v1\",\"agent-session-tabs-v1\"]}}\n").await.unwrap();
                drop(probe);
                (socket, _) = listener.accept().await.unwrap();
            } else {
                socket.write_all(b"{\"remote_entry\":1}\n").await.unwrap();
            }
            let mut socket = BufReader::new(socket);
            let mut line = String::new();
            if service == "daemon" {
                socket.read_line(&mut line).await.unwrap();
                line.clear();
            }
            socket.read_line(&mut line).await.unwrap();
        });
        // The subscription already sees revocation. Its next changed() alone
        // will not wake: admission must inspect the current view too.
        let (_sender, view) = tokio::sync::watch::channel(Arc::new(Pairings::default()));
        let (mut peer, stream) = tokio::io::duplex(1024);
        peer.write_all(format!("{{\"service\":\"{service}\"}}\npayload\n").as_bytes())
            .await
            .unwrap();
        peer.shutdown().await.unwrap();
        let owner = OwnerSession {
            owner_user: "42".into(),
            owner_team: "team_a".into(),
            socket: brain,
            brain_home: home,
        };
        let served = within(serve_inbound_watched(
            stream,
            [2; 32],
            address(),
            &pairings(),
            &session,
            Some(&owner),
            Some(Revocations { view, open: Arc::default() }),
        ))
        .await;
        if served != Err(InboundRefused::UnknownPeer)
            || touched.load(std::sync::atomic::Ordering::SeqCst)
        {
            failures.push(service);
        }
        entry.abort();
    }
    assert!(failures.is_empty(), "stale snapshots reached local endpoints: {failures:?}");
}
