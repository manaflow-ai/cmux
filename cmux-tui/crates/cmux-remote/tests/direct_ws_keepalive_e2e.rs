//! Dead-peer detection on the direct CMXR WebSocket listener (`--remote-ws`),
//! observed through a TCP proxy between a real client and the daemon. The
//! proxy can freeze: it stops carrying bytes both ways but keeps both sockets
//! open, as a peer that vanished behind a NAT or a sleeping laptop does.

use std::net::SocketAddr;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::time::Duration;

use bytes::Bytes;
use cmux_remote::connection::{ClientConnection, ClientConnectionConfig, ReconnectPolicy};
use cmux_remote::crypto::{ClientAuthMode, StaticIdentity};
use cmux_remote::daemon::{
    DaemonSessionPolicy, DirectWebSocketOptions, DirectWebSocketServer, RemoteDaemon,
    ServerConnection, WebSocketKeepalive, serve_direct_websocket_with_options,
};
use cmux_remote::identity::AuthDatabase;
use cmux_remote::provider::{ConnectRequest, DirectWebSocketProvider, TransportProvider};
use cmux_remote::session::SessionLimits;
use cmux_remote_protocol::{FrameFlags, Lane, LanePolicy, SessionId};
use tempfile::{TempDir, tempdir};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::tcp::{OwnedReadHalf, OwnedWriteHalf};
use tokio::net::{TcpListener, TcpStream};
use tokio::sync::mpsc;
use tokio::time::Instant;
use url::Url;

/// One physical WebSocket per lane under the isolated lane policy.
const ISOLATED_LINKS: usize = 4;

/// A Ping after 300 ms of silence, a close after 1.5 s (five unanswered
/// intervals, so a loaded CI runner does not close the healthy client).
const KEEPALIVE: WebSocketKeepalive = WebSocketKeepalive {
    ping_interval: Duration::from_millis(300),
    dead_peer_timeout: Duration::from_millis(1_500),
};

/// How long the daemon keeps a disconnected session for a reconnect.
const RESUME_LEASE: Duration = Duration::from_secs(1);

struct Proxy {
    address: SocketAddr,
    frozen: Arc<AtomicBool>,
    accepted: Arc<AtomicUsize>,
    /// WebSocket Pings the daemon sent toward the client.
    pings: Arc<AtomicUsize>,
    /// One instant per upstream (daemon-side) socket the daemon closed.
    upstream_closed: mpsc::UnboundedReceiver<Instant>,
}

async fn start_proxy(upstream: SocketAddr) -> Proxy {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let address = listener.local_addr().unwrap();
    let frozen = Arc::new(AtomicBool::new(false));
    let accepted = Arc::new(AtomicUsize::new(0));
    let pings = Arc::new(AtomicUsize::new(0));
    let (closed_tx, upstream_closed) = mpsc::unbounded_channel();
    tokio::spawn({
        let frozen = frozen.clone();
        let accepted = accepted.clone();
        let pings = pings.clone();
        async move {
            loop {
                let Ok((client, _)) = listener.accept().await else { return };
                if frozen.load(Ordering::Acquire) {
                    // The network is gone: a reconnect never reaches the daemon.
                    std::mem::forget(client);
                    continue;
                }
                accepted.fetch_add(1, Ordering::AcqRel);
                let daemon = TcpStream::connect(upstream).await.unwrap();
                let (client_read, client_write) = client.into_split();
                let (daemon_read, daemon_write) = daemon.into_split();
                tokio::spawn(pump(client_read, daemon_write, frozen.clone(), None, None));
                tokio::spawn(pump(
                    daemon_read,
                    client_write,
                    frozen.clone(),
                    Some(pings.clone()),
                    Some(closed_tx.clone()),
                ));
            }
        }
    });
    Proxy { address, frozen, accepted, pings, upstream_closed }
}

/// Carry bytes until `from` closes. While frozen, bytes are read and dropped
/// and `to` is never closed: a vanished peer sends no FIN.
async fn pump(
    mut from: OwnedReadHalf,
    mut to: OwnedWriteHalf,
    frozen: Arc<AtomicBool>,
    pings: Option<Arc<AtomicUsize>>,
    closed: Option<mpsc::UnboundedSender<Instant>>,
) {
    let mut buffer = vec![0_u8; 64 * 1024];
    let mut frames = ServerFrames::default();
    loop {
        match from.read(&mut buffer).await {
            Ok(0) | Err(_) => break,
            Ok(read) => {
                if let Some(pings) = &pings {
                    pings.fetch_add(frames.count_pings(&buffer[..read]), Ordering::AcqRel);
                }
                if !frozen.load(Ordering::Acquire) && to.write_all(&buffer[..read]).await.is_err() {
                    break;
                }
            }
        }
    }
    if let Some(closed) = closed {
        let _ = closed.send(Instant::now());
    }
    if frozen.load(Ordering::Acquire) {
        std::future::pending::<()>().await;
    }
}

/// Reads the daemon's side of one WebSocket connection: the HTTP upgrade
/// response, then unmasked server frames.
#[derive(Default)]
struct ServerFrames {
    pending: Vec<u8>,
    upgraded: bool,
}

impl ServerFrames {
    /// Pings among the complete frames `bytes` finishes.
    fn count_pings(&mut self, bytes: &[u8]) -> usize {
        self.pending.extend_from_slice(bytes);
        if !self.upgraded {
            let Some(end) = self.pending.windows(4).position(|window| window == b"\r\n\r\n") else {
                return 0;
            };
            self.pending.drain(..end + 4);
            self.upgraded = true;
        }
        let mut pings = 0;
        loop {
            let frame = &self.pending;
            if frame.len() < 2 {
                return pings;
            }
            let (length, header) = match frame[1] & 0x7f {
                126 if frame.len() >= 4 => (u16::from_be_bytes([frame[2], frame[3]]) as usize, 4),
                127 if frame.len() >= 10 => {
                    let mut length = [0_u8; 8];
                    length.copy_from_slice(&frame[2..10]);
                    (u64::from_be_bytes(length) as usize, 10)
                }
                126 | 127 => return pings,
                length => (length as usize, 2),
            };
            if frame.len() < header + length {
                return pings;
            }
            if frame[0] & 0x0f == 0x9 {
                pings += 1;
            }
            self.pending.drain(..header + length);
        }
    }
}

struct Session {
    _state: TempDir,
    server: DirectWebSocketServer,
    proxy: Proxy,
    client: Arc<ClientConnection>,
    daemon_client: Arc<ServerConnection>,
}

/// A trusted-carrier daemon with [`KEEPALIVE`], and a client that sends no
/// heartbeats (only the Pongs its WebSocket answers with) connected through
/// a proxy.
async fn connect_through_proxy(name: &str, session: SessionId) -> Session {
    let state = tempdir().unwrap();
    let auth = AuthDatabase::load_or_create(state.path(), name, false).unwrap();
    let (daemon, mut accepted) = RemoteDaemon::with_policy(
        auth,
        SessionLimits::default(),
        DaemonSessionPolicy { resume_lease: RESUME_LEASE },
    )
    .unwrap();
    let server = serve_direct_websocket_with_options(
        daemon,
        "127.0.0.1:0".parse().unwrap(),
        65_535,
        DirectWebSocketOptions {
            trusted_carrier: true,
            keepalive: KEEPALIVE,
            ..Default::default()
        },
    )
    .await
    .unwrap();
    let proxy = start_proxy(server.local_addr()).await;
    let endpoint = Url::parse(&format!("ws://{}/v1/link", proxy.address)).unwrap();
    let group = DirectWebSocketProvider::new(65_535)
        .with_carrier_auth(true)
        .connect(ConnectRequest {
            endpoint,
            session,
            lane_policy: LanePolicy::Isolated,
            routing: Default::default(),
        })
        .await
        .unwrap();
    let client = tokio::time::timeout(
        Duration::from_secs(5),
        ClientConnection::connect(
            group,
            ClientConnectionConfig {
                identity: StaticIdentity::generate().unwrap(),
                expected_daemon: None,
                auth: ClientAuthMode::Carrier,
                device_name: "keepalive-client".into(),
                session,
                lane_policy: LanePolicy::Isolated,
                limits: SessionLimits::default(),
                reconnect: ReconnectPolicy { heartbeat_interval: None, ..Default::default() },
            },
        ),
    )
    .await
    .expect("carrier dial timed out")
    .expect("trusted listener refused the carrier dial");
    let daemon_client =
        tokio::time::timeout(Duration::from_secs(5), accepted.recv()).await.unwrap().unwrap();
    round_trip(&client, &daemon_client).await;
    Session { _state: state, server, proxy, client, daemon_client }
}

async fn round_trip(client: &ClientConnection, daemon_client: &ServerConnection) {
    client
        .send(Lane::Interactive, 1, Bytes::from_static(b"input"), FrameFlags::empty())
        .await
        .unwrap();
    let received = tokio::time::timeout(Duration::from_secs(5), daemon_client.receive())
        .await
        .expect("daemon did not receive the client frame")
        .unwrap()
        .unwrap();
    assert_eq!(received.payload, b"input".as_slice());
}

/// The daemon's first silent link fails after the dead-peer timeout, which
/// ends the session's transport like any disconnect; the session then waits
/// out its resume lease and closes the remaining links.
#[tokio::test]
async fn direct_websocket_keepalive_closes_a_peer_that_vanished() {
    let started = Instant::now();
    let mut session = connect_through_proxy("keepalive-dead-peer", SessionId([91; 16])).await;
    assert_eq!(session.proxy.accepted.load(Ordering::Acquire), ISOLATED_LINKS);
    // The daemon's service reads its connection, as the remote runtime does.
    let service = tokio::spawn({
        let daemon_client = session.daemon_client.clone();
        async move { while let Ok(Some(_)) = daemon_client.receive().await {} }
    });

    session.proxy.frozen.store(true, Ordering::Release);
    let frozen_at = Instant::now();
    let first = tokio::time::timeout(
        KEEPALIVE.dead_peer_timeout + Duration::from_secs(4),
        session.proxy.upstream_closed.recv(),
    )
    .await
    .expect("daemon kept every link of a vanished peer open")
    .unwrap();
    // Every frame of the session arrived after `started`.
    assert!(
        first >= started + KEEPALIVE.dead_peer_timeout,
        "daemon closed a link {:?} after connect, before the dead-peer timeout",
        first - started
    );
    for link in 1..ISOLATED_LINKS {
        tokio::time::timeout_at(
            frozen_at + KEEPALIVE.dead_peer_timeout + RESUME_LEASE + Duration::from_secs(5),
            session.proxy.upstream_closed.recv(),
        )
        .await
        .unwrap_or_else(|_| panic!("daemon kept {link} of {ISOLATED_LINKS} links open"))
        .unwrap();
    }
    tokio::time::timeout(Duration::from_secs(5), service)
        .await
        .expect("the daemon connection stayed open after its resume lease")
        .unwrap();
    drop(session.client);
    session.server.shutdown().await.unwrap();
}

#[tokio::test]
async fn direct_websocket_keepalive_keeps_a_peer_that_answers_pings() {
    let mut session = connect_through_proxy("keepalive-live-peer", SessionId([92; 16])).await;
    let before = session.proxy.pings.load(Ordering::Acquire);

    // No data and no heartbeats, only Pings and the client's Pongs, for
    // twice the dead-peer timeout.
    tokio::time::sleep(KEEPALIVE.dead_peer_timeout * 2).await;

    assert!(
        session.proxy.upstream_closed.try_recv().is_err(),
        "daemon closed a link of a peer that answers pings"
    );
    let pings = session.proxy.pings.load(Ordering::Acquire) - before;
    assert!(
        pings >= ISOLATED_LINKS * 2,
        "daemon sent {pings} Pings to {ISOLATED_LINKS} idle links"
    );
    round_trip(&session.client, &session.daemon_client).await;
    assert_eq!(
        session.proxy.accepted.load(Ordering::Acquire),
        ISOLATED_LINKS,
        "the client had to reconnect"
    );
    session.client.close().await.unwrap();
    session.server.shutdown().await.unwrap();
}
