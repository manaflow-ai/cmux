//! Revocation through the real, caller-verified local dial socket.

use std::net::SocketAddr;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::Duration;

use base64::Engine as _;
use cmux_link::connect_info::ConnectInfo;
use cmux_link::dial::PathState;
use cmux_link::pairing::{PairingRecord, Pairings};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader, DuplexStream};
use tokio::net::{UnixListener, UnixStream};
use tokio::sync::{Semaphore, mpsc};

use super::cloud::{CloudResolver, RelaySource};
use super::control::{Peers, serve_local};
use super::dial::Overlay;

fn pairings() -> Pairings {
    Pairings {
        peers: vec![PairingRecord {
            install: "inst_b".into(),
            user: "42".into(),
            team: "team_a".into(),
            public_key: base64::engine::general_purpose::STANDARD.encode([2; 32]),
            endpoint: None,
        }],
    }
}

/// A hang guard, not a latency budget. Each hand-off to the entry or the link
/// socket checks the caller's code signature on macOS (`cmux_link::caller`): for
/// an ad-hoc signed test binary that hashes the whole executable, about 1 s alone
/// and over 10 s when a full workspace run keeps every core busy (944d5cc59f05:
/// four of these tests at 12.5 s, each passing alone in 1.1 to 3.3 s). nextest
/// still ends a real hang at 120 s.
const HANG_GUARD: Duration = Duration::from_secs(60);

async fn within<T>(work: impl Future<Output = T>) -> T {
    tokio::time::timeout(HANG_GUARD, work).await.expect("within the hang guard")
}

struct DialOverlay {
    connected: mpsc::UnboundedSender<DuplexStream>,
    entered: mpsc::UnboundedSender<()>,
    release: Semaphore,
    remote_closed: AtomicBool,
    synced_after_close: AtomicBool,
}

impl Overlay for DialOverlay {
    type Stream = DuplexStream;

    async fn connect(&self, _remote: SocketAddr) -> std::io::Result<DuplexStream> {
        self.entered.send(()).unwrap();
        self.release.acquire().await.unwrap().forget();
        let (near, far) = tokio::io::duplex(4096);
        self.connected.send(far).unwrap();
        Ok(near)
    }

    async fn sync_peers(&self, _pairings: &Pairings) -> std::io::Result<()> {
        self.synced_after_close.store(self.remote_closed.load(Ordering::SeqCst), Ordering::SeqCst);
        Ok(())
    }

    async fn set_cloud_peer(
        &self,
        _host: &str,
        _key: [u8; 32],
        _info: &ConnectInfo,
    ) -> std::io::Result<()> {
        panic!("a paired dial must not request a Cloud peer")
    }

    async fn forget_cloud_peer(&self, _host: &str) -> std::io::Result<()> {
        panic!("a paired reload must not remove a Cloud peer")
    }

    async fn path_state(&self, _key: &[u8; 32]) -> PathState {
        PathState::Direct
    }
}

struct LocalLink {
    directory: cmux_unix_socket::TestDir,
    peers: Arc<Peers>,
    overlay: Arc<DialOverlay>,
    connected: mpsc::UnboundedReceiver<DuplexStream>,
    entered: mpsc::UnboundedReceiver<()>,
    task: tokio::task::JoinHandle<std::io::Result<()>>,
}

impl LocalLink {
    async fn start(block_connect: bool) -> Self {
        let directory = cmux_unix_socket::short_test_dir("outrev");
        let path = directory.path().join("peers.json");
        pairings().save(&path).unwrap();
        let peers = Arc::new(Peers::load(path).unwrap());
        let listener = UnixListener::bind(directory.path().join("l.sock")).unwrap();
        let (connected_tx, connected) = mpsc::unbounded_channel();
        let (entered_tx, entered) = mpsc::unbounded_channel();
        let overlay = Arc::new(DialOverlay {
            connected: connected_tx,
            entered: entered_tx,
            release: Semaphore::new(if block_connect { 0 } else { 16 }),
            remote_closed: AtomicBool::new(false),
            synced_after_close: AtomicBool::new(false),
        });
        let task = tokio::spawn(serve_local(
            listener,
            overlay.clone(),
            peers.clone(),
            Arc::new(CloudResolver::new(RelaySource::unavailable())),
            Arc::from("{}"),
        ));
        Self { directory, peers, overlay, connected, entered, task }
    }

    async fn request(&self, service: &str) -> BufReader<UnixStream> {
        let mut caller = UnixStream::connect(self.directory.path().join("l.sock")).await.unwrap();
        caller
            .write_all(
                format!("{{\"op\":\"link.dial\",\"host\":\"inst_b\",\"service\":\"{service}\"}}\n")
                    .as_bytes(),
            )
            .await
            .unwrap();
        BufReader::new(caller)
    }

    async fn open(&mut self, service: &str) -> (BufReader<UnixStream>, BufReader<DuplexStream>) {
        let mut caller = self.request(service).await;
        let mut reply = String::new();
        within(caller.read_line(&mut reply)).await.unwrap();
        assert_eq!(serde_json::from_str::<serde_json::Value>(&reply).unwrap()["ok"], true);
        let mut remote = BufReader::new(within(self.connected.recv()).await.unwrap());
        let mut hello = String::new();
        within(remote.read_line(&mut hello)).await.unwrap();
        assert_eq!(serde_json::from_str::<serde_json::Value>(&hello).unwrap()["service"], service);
        exchange(&mut caller, &mut remote).await;
        (caller, remote)
    }

    fn save(&self, fresh: &Pairings) {
        fresh.save(&self.directory.path().join("peers.json")).unwrap();
    }

    async fn closes(
        &self,
        mut caller: BufReader<UnixStream>,
        mut remote: BufReader<DuplexStream>,
    ) -> bool {
        let closing = async {
            let mut tail = String::new();
            let remote_eof =
                tokio::time::timeout(Duration::from_secs(1), remote.read_line(&mut tail)).await;
            let closed = matches!(remote_eof, Ok(Ok(0)));
            self.overlay.remote_closed.store(closed, Ordering::SeqCst);
            remote.get_mut().shutdown().await.unwrap();
            tail.clear();
            let caller_eof =
                tokio::time::timeout(Duration::from_secs(1), caller.read_line(&mut tail)).await;
            caller.get_mut().shutdown().await.unwrap();
            closed && matches!(caller_eof, Ok(Ok(0)))
        };
        let (reloaded, closed) =
            within(async { tokio::join!(self.peers.reload(&*self.overlay), closing) }).await;
        reloaded.unwrap();
        closed && self.overlay.synced_after_close.load(Ordering::SeqCst)
    }
}

impl Drop for LocalLink {
    fn drop(&mut self) {
        self.task.abort();
    }
}

async fn exchange(caller: &mut BufReader<UnixStream>, remote: &mut BufReader<DuplexStream>) {
    caller.get_mut().write_all(b"request\n").await.unwrap();
    let mut line = String::new();
    within(remote.read_line(&mut line)).await.unwrap();
    assert_eq!(line, "request\n");
    remote.get_mut().write_all(b"answer\n").await.unwrap();
    line.clear();
    within(caller.read_line(&mut line)).await.unwrap();
    assert_eq!(line, "answer\n");
}

#[tokio::test]
async fn outgoing_revocation_closes_daemon_and_owner_before_overlay_removal() {
    let mut failures = Vec::new();
    for service in ["daemon", "owner_session"] {
        let mut link = LocalLink::start(false).await;
        let (caller, remote) = link.open(service).await;
        link.save(&Pairings::default());
        if !link.closes(caller, remote).await {
            failures.push(service);
        }
    }
    assert!(failures.is_empty(), "revoked outgoing services stayed open: {failures:?}");
}

#[tokio::test]
async fn outgoing_revocation_closes_reassigned_identities_and_rotated_keys() {
    let mut failures = Vec::new();
    for field in ["install", "user", "team", "key"] {
        let mut link = LocalLink::start(false).await;
        let (caller, remote) = link.open("daemon").await;
        let mut fresh = pairings();
        match field {
            "install" => fresh.peers[0].install = "inst_c".into(),
            "user" => fresh.peers[0].user = "other-user".into(),
            "team" => fresh.peers[0].team = "other-team".into(),
            "key" => {
                fresh.peers[0].public_key =
                    base64::engine::general_purpose::STANDARD.encode([3; 32]);
            }
            _ => unreachable!(),
        }
        link.save(&fresh);
        if !link.closes(caller, remote).await {
            failures.push(field);
        }
    }
    assert!(failures.is_empty(), "old outgoing identities stayed open: {failures:?}");
}

#[tokio::test]
async fn outgoing_revocation_cancels_a_pending_connect_without_a_service_hello() {
    let mut link = LocalLink::start(true).await;
    let mut caller = link.request("daemon").await;
    within(link.entered.recv()).await.unwrap();
    link.save(&Pairings::default());
    within(link.peers.reload(&*link.overlay)).await.unwrap();
    let mut reply = String::new();
    let read = tokio::time::timeout(Duration::from_secs(1), caller.read_line(&mut reply)).await;
    // Release and hang up even on the old implementation, so the regression
    // reports a behavioral failure instead of leaking a blocked request.
    if let Err(error) = caller.get_mut().shutdown().await {
        // Darwin may already have observed the peer's close on this Unix socket.
        assert_eq!(error.kind(), std::io::ErrorKind::NotConnected);
    }
    link.overlay.release.add_permits(1);
    assert!(matches!(read, Ok(Ok(n)) if n > 0), "revocation left the connect pending");
    assert_eq!(
        serde_json::from_str::<serde_json::Value>(&reply).unwrap()["error_code"],
        "not_authorized"
    );
    assert!(link.connected.try_recv().is_err(), "a revoked dial opened an overlay stream");
}

#[tokio::test]
async fn outgoing_endpoint_updates_preserve_the_same_identity_and_payload() {
    let mut link = LocalLink::start(false).await;
    let (mut caller, mut remote) = link.open("daemon").await;
    let mut fresh = pairings();
    fresh.peers[0].endpoint = Some("127.0.0.1:4200".parse().unwrap());
    link.save(&fresh);
    within(link.peers.reload(&*link.overlay)).await.unwrap();
    exchange(&mut caller, &mut remote).await;
    caller.get_mut().shutdown().await.unwrap();
    remote.get_mut().shutdown().await.unwrap();
}

#[tokio::test]
async fn outgoing_revocation_refuses_a_stale_snapshot_before_contacting_the_peer() {
    let mut link = LocalLink::start(false).await;
    let stale = link.peers.snapshot();
    link.save(&Pairings::default());
    link.peers.reload(&*link.overlay).await.unwrap();
    let (caller, link_side) = tokio::io::duplex(4096);
    let mut caller = BufReader::new(caller);
    let resolver = CloudResolver::new(RelaySource::unavailable());
    let serve = super::dial::serve_dial_line(
        link_side,
        "{\"op\":\"link.dial\",\"host\":\"inst_b\",\"service\":\"daemon\"}",
        &*link.overlay,
        &stale,
        &resolver,
        Some(link.peers.revocations()),
    );
    let read = async {
        let mut reply = String::new();
        caller.read_line(&mut reply).await.unwrap();
        assert_eq!(
            serde_json::from_str::<serde_json::Value>(&reply).unwrap()["error_code"],
            "not_authorized"
        );
    };
    within(async { tokio::join!(serve, read) }).await;
    assert!(link.entered.try_recv().is_err(), "a stale view contacted the revoked peer");
}
