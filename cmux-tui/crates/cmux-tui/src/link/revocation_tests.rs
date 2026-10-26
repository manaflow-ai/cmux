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

/// A hang guard, not a latency budget. Each hand-off to the entry or the link
/// socket checks the caller's code signature on macOS (`cmux_link::caller`): for
/// an ad-hoc signed test binary that hashes the whole executable, about 1 s alone
/// and over 10 s when a full workspace run keeps every core busy (944d5cc59f05:
/// four of these tests at 12.5 s, each passing alone in 1.1 to 3.3 s). nextest
/// still ends a real hang at 120 s.
const HANG_GUARD: Duration = Duration::from_secs(60);

async fn within<T>(future: impl Future<Output = T>) -> T {
    tokio::time::timeout(HANG_GUARD, future).await.expect("within the hang guard")
}

struct OpenDaemon {
    _directory: cmux_unix_socket::TestDir,
    view: tokio::sync::watch::Sender<Arc<Pairings>>,
    peer: BufReader<DuplexStream>,
    entry: BufReader<UnixStream>,
    task: tokio::task::JoinHandle<Result<(), InboundRefused>>,
}

async fn open_daemon() -> OpenDaemon {
    open_daemon_with(None).await
}

async fn open_daemon_with(subscription: Option<Revocations>) -> OpenDaemon {
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
            Some(subscription.unwrap_or(Revocations { view: receiver, open: Arc::default() })),
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

#[tokio::test]
async fn losing_the_pairing_view_closes_an_existing_daemon_stream() {
    let mut daemon = open_daemon().await;
    drop(daemon.view);
    let mut tail = String::new();
    assert_eq!(within(daemon.peer.read_line(&mut tail)).await.unwrap(), 0);
    drop(daemon.peer);
    drop(daemon.entry);
    assert_eq!(within(daemon.task).await.unwrap(), Err(InboundRefused::UnknownPeer));
}

#[tokio::test]
async fn revocation_during_owner_identification_closes_the_probe_before_session_handoff() {
    let directory = cmux_unix_socket::short_test_dir("revprobe");
    let home = directory.path().join("brain");
    std::fs::create_dir_all(home.join("daemon")).unwrap();
    let socket = home.join("daemon/s.sock");
    let listener = tokio::net::UnixListener::bind(&socket).unwrap();
    let owner = OwnerSession {
        owner_user: "42".into(),
        owner_team: "team_a".into(),
        socket,
        brain_home: home,
    };
    let session = directory.path().join("s.sock");
    let (sender, view) = tokio::sync::watch::channel(Arc::new(pairings()));
    let (mut peer, stream) = tokio::io::duplex(1024);
    peer.write_all(b"{\"service\":\"owner_session\"}\nprivate-request\n").await.unwrap();
    let task = tokio::spawn(async move {
        serve_inbound_watched(
            stream,
            [2; 32],
            address(),
            &pairings(),
            &session,
            Some(&owner),
            Some(Revocations { view, open: Arc::default() }),
        )
        .await
    });
    let (probe, _) = within(listener.accept()).await.unwrap();
    let mut probe = BufReader::new(probe);
    let mut line = String::new();
    within(probe.read_line(&mut line)).await.unwrap();
    assert_eq!(line, cmux_link::owner_session::IDENTIFY_REQUEST);
    sender.send_replace(Arc::new(Pairings::default()));
    line.clear();
    assert_eq!(
        within(probe.read_line(&mut line)).await.unwrap(),
        0,
        "the pending identify probe must close"
    );
    drop(peer);
    assert_eq!(
        within(task).await.unwrap(),
        Err(InboundRefused::Owner(cmux_link::owner_session::OwnerRefused::NotOwner))
    );
}

struct StagedOverlay {
    entered: tokio::sync::mpsc::UnboundedSender<Pairings>,
    release: tokio::sync::Semaphore,
    fail: bool,
}

impl super::dial::Overlay for StagedOverlay {
    type Stream = DuplexStream;
    async fn connect(&self, _remote: SocketAddr) -> std::io::Result<Self::Stream> {
        Err(std::io::Error::new(std::io::ErrorKind::Unsupported, "fixture does not dial"))
    }
    async fn sync_peers(&self, pairings: &Pairings) -> std::io::Result<()> {
        self.entered.send(pairings.clone()).unwrap();
        self.release.acquire().await.unwrap().forget();
        if self.fail {
            return Err(std::io::Error::other("fixture sync failed"));
        }
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

#[tokio::test]
async fn failed_overlay_sync_never_restores_the_revoked_admission_view() {
    let directory = cmux_unix_socket::short_test_dir("revsync");
    let path = directory.path().join("peers.json");
    pairings().save(&path).unwrap();
    let peers = Arc::new(super::control::Peers::load(path.clone()).unwrap());
    let stale = peers.snapshot();
    Pairings::default().save(&path).unwrap();
    let (entered, mut updates) = tokio::sync::mpsc::unbounded_channel();
    let overlay =
        Arc::new(StagedOverlay { entered, release: tokio::sync::Semaphore::new(0), fail: true });
    let task = {
        let (peers, overlay) = (peers.clone(), overlay.clone());
        tokio::spawn(async move { peers.reload(&*overlay).await })
    };
    assert!(within(updates.recv()).await.unwrap().peers.is_empty());
    assert!(peers.snapshot().peers.is_empty(), "admission must change before overlay I/O finishes");
    overlay.release.add_permits(1);
    assert!(within(task).await.unwrap().is_err());
    assert!(peers.snapshot().peers.is_empty());
    let (mut peer, stream) = tokio::io::duplex(1024);
    peer.write_all(b"{\"service\":\"daemon\"}\n").await.unwrap();
    peer.shutdown().await.unwrap();
    let result = within(serve_inbound_watched(
        stream,
        [2; 32],
        address(),
        &stale,
        &directory.path().join("s.sock"),
        None,
        Some(peers.revocations()),
    ))
    .await;
    assert_eq!(result, Err(InboundRefused::UnknownPeer));
}

#[tokio::test]
async fn concurrent_reloads_apply_in_order_and_read_the_file_after_admission() {
    let directory = cmux_unix_socket::short_test_dir("revorder");
    let path = directory.path().join("peers.json");
    pairings().save(&path).unwrap();
    let peers = Arc::new(super::control::Peers::load(path.clone()).unwrap());
    Pairings::default().save(&path).unwrap();
    let (entered, mut updates) = tokio::sync::mpsc::unbounded_channel();
    let overlay =
        Arc::new(StagedOverlay { entered, release: tokio::sync::Semaphore::new(0), fail: false });
    let first = {
        let (peers, overlay) = (peers.clone(), overlay.clone());
        tokio::spawn(async move { peers.reload(&*overlay).await })
    };
    assert!(within(updates.recv()).await.unwrap().peers.is_empty());
    let mut fresh = pairings();
    fresh.peers[0].user = "new-owner".into();
    fresh.save(&path).unwrap();
    let second = peers.reload(&*overlay);
    tokio::pin!(second);
    std::future::poll_fn(|cx| {
        assert!(second.as_mut().poll(cx).is_pending());
        std::task::Poll::Ready(())
    })
    .await;
    assert!(
        updates.try_recv().is_err(),
        "a second reload reached overlay I/O before the first ended"
    );
    // A newer file arrives while the second caller waits for admission.
    fresh.peers[0].user = "newest-owner".into();
    fresh.save(&path).unwrap();
    overlay.release.add_permits(1);
    within(first).await.unwrap().unwrap();
    std::future::poll_fn(|cx| {
        assert!(second.as_mut().poll(cx).is_pending());
        std::task::Poll::Ready(())
    })
    .await;
    assert_eq!(within(updates.recv()).await.unwrap(), fresh);
    overlay.release.add_permits(1);
    within(second).await.unwrap();
    assert_eq!(*peers.snapshot(), fresh);
}

#[tokio::test]
async fn a_same_key_reassignment_closes_the_old_stream_before_overlay_sync() {
    let directory = cmux_unix_socket::short_test_dir("revpin");
    let path = directory.path().join("peers.json");
    pairings().save(&path).unwrap();
    let peers = Arc::new(super::control::Peers::load(path.clone()).unwrap());
    let mut daemon = open_daemon_with(Some(peers.revocations())).await;
    let mut fresh = pairings();
    fresh.peers[0].user = "new-owner".into();
    fresh.save(&path).unwrap();
    let (entered, mut updates) = tokio::sync::mpsc::unbounded_channel();
    let overlay =
        Arc::new(StagedOverlay { entered, release: tokio::sync::Semaphore::new(0), fail: false });
    let task = {
        let (peers, overlay) = (peers.clone(), overlay.clone());
        tokio::spawn(async move { peers.reload(&*overlay).await })
    };
    let mut tail = String::new();
    assert_eq!(within(daemon.peer.read_line(&mut tail)).await.unwrap(), 0);
    assert!(
        updates.try_recv().is_err(),
        "the old carrier must close before the peer is synchronized"
    );
    drop(daemon.peer);
    drop(daemon.entry);
    within(daemon.task).await.unwrap().unwrap_err();
    assert_eq!(within(updates.recv()).await.unwrap(), fresh);
    overlay.release.add_permits(1);
    within(task).await.unwrap().unwrap();
}

struct OneStream(Option<DuplexStream>);

impl super::control::OverlayListener for OneStream {
    type Stream = DuplexStream;
    async fn accept(&mut self) -> Option<(DuplexStream, [u8; 32], SocketAddr)> {
        match self.0.take() {
            Some(stream) => Some((stream, [2; 32], address())),
            None => std::future::pending().await,
        }
    }
}

#[tokio::test(flavor = "current_thread")]
async fn an_accepted_stream_is_registered_before_its_handler_first_polls() {
    let directory = cmux_unix_socket::short_test_dir("revpoll");
    let path = directory.path().join("peers.json");
    pairings().save(&path).unwrap();
    let peers = Arc::new(super::control::Peers::load(path.clone()).unwrap());
    let (peer, stream) = tokio::io::duplex(1024);
    let serving = super::control::serve_overlay(
        OneStream(Some(stream)),
        peers.clone(),
        Some(directory.path().join("s.sock")),
        None,
    );
    tokio::pin!(serving);
    // Poll acceptance in this task; the spawned handler has not run yet.
    std::future::poll_fn(|cx| {
        assert!(serving.as_mut().poll(cx).is_pending());
        std::task::Poll::Ready(())
    })
    .await;
    Pairings::default().save(&path).unwrap();
    let (entered, mut updates) = tokio::sync::mpsc::unbounded_channel();
    let overlay = StagedOverlay { entered, release: tokio::sync::Semaphore::new(0), fail: false };
    let reload = peers.reload(&overlay);
    tokio::pin!(reload);
    std::future::poll_fn(|cx| {
        assert!(reload.as_mut().poll(cx).is_pending());
        std::task::Poll::Ready(())
    })
    .await;
    assert!(updates.try_recv().is_err(), "peer removal raced an accepted but unpolled stream");
    drop(peer);
    // The queued handler sees the revoked current view and ends; only then
    // may the reload remove the WireGuard peer.
    let pending_reload = async {
        within(updates.recv()).await.unwrap();
        overlay.release.add_permits(1);
    };
    let (result, ()) = tokio::join!(reload, pending_reload);
    result.unwrap();
}
