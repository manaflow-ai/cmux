//! A lost handshake initiation while data waits for the session.
//!
//! Measured on a real tunnel (scoreboard row "Cloud pause 190 s, Mac to
//! Cloud VM, resume"): after the hub was paused 190 s, past WireGuard's
//! 180 s session lifetime, the client had no session, the initiation that
//! would have made one was lost, and nothing was sent again until
//! boringtun's 5 s REKEY_TIMEOUT retry: 5.15 s to the next connection. No
//! network change happened on the client, so `rebind`/`refresh` (tests/wake.rs)
//! never ran, and the watchdog arms only on a session that exists.
//!
//! Each test below drops exactly one initiation of the client while its
//! first segment (a SYN) waits for the session, then times the connection
//! from `connect` to the SYN-ACK, the first authenticated data back. It must
//! open well under a second, not at boringtun's 5 s retry.
//!
//! The clock is real: boringtun times its retries on its own monotonic
//! clock, which Tokio's paused clock does not move.

use std::io;
use std::net::SocketAddr;
use std::sync::Arc;
use std::sync::atomic::{AtomicU32, Ordering};
use std::task::{Context, Poll};
use std::time::Duration;

use cmux_transport::PathId;
use cmux_wg::testing::config_pair;
use cmux_wg::testing::sim::{LinkProfile, SimNet};
use cmux_wg::{Origin, Received, SocketPath, Underlay, WgNet};
use tokio::net::UdpSocket;
use tokio::time::Instant;

const CLIENT: &str = "192.0.2.96:51820";
const SERVER: &str = "192.0.2.97:51820";
const PORT: u16 = 7000;
/// The bound the tests guard: boringtun's own retry made this 5 s.
const BOUND: Duration = Duration::from_secs(1);
/// WireGuard message type 1, a handshake initiation.
const INITIATION: u8 = 1;

fn addr(text: &str) -> SocketAddr {
    text.parse().expect("literal address")
}

/// Drops the next `pending` handshake initiations the client sends.
struct DropInitiations<U> {
    inner: U,
    pending: Arc<AtomicU32>,
}

impl<U: Underlay> DropInitiations<U> {
    fn lose(&self, datagram: &[u8]) -> bool {
        datagram.first() == Some(&INITIATION)
            && self
                .pending
                .fetch_update(Ordering::SeqCst, Ordering::SeqCst, |left| left.checked_sub(1))
                .is_ok()
    }
}

impl<U: Underlay> Underlay for DropInitiations<U> {
    fn send(&mut self, datagram: &[u8]) {
        if !self.lose(datagram) {
            self.inner.send(datagram);
        }
    }

    fn send_on(&mut self, path: PathId, datagram: &[u8]) {
        if !self.lose(datagram) {
            self.inner.send_on(path, datagram);
        }
    }

    fn flush(&mut self) {
        self.inner.flush();
    }

    fn backlogged(&self) -> bool {
        self.inner.backlogged()
    }

    fn poll_flush(&mut self, cx: &mut Context<'_>) -> Poll<()> {
        self.inner.poll_flush(cx)
    }

    fn poll_recv(&mut self, cx: &mut Context<'_>, buffer: &mut [u8]) -> Poll<io::Result<Received>> {
        self.inner.poll_recv(cx, buffer)
    }

    fn authenticated(&mut self, origin: Origin) {
        self.inner.authenticated(origin);
    }

    fn has_peer(&self) -> bool {
        self.inner.has_peer()
    }

    fn peer_hint(&self) -> Option<SocketAddr> {
        self.inner.peer_hint()
    }
}

async fn wait_lost(pending: &AtomicU32) {
    let deadline = Instant::now() + Duration::from_secs(5);
    while pending.load(Ordering::SeqCst) > 0 {
        assert!(Instant::now() < deadline, "the initiation was never sent");
        tokio::time::sleep(Duration::from_millis(5)).await;
    }
}

/// Time `connect` to the server's listener, which must succeed.
async fn time_connect(client: &WgNet, server: SocketAddr) -> Duration {
    let started = Instant::now();
    let stream = tokio::time::timeout(Duration::from_secs(15), client.connect(server))
        .await
        .expect("connect within 15 s")
        .expect("connect");
    let opened = started.elapsed();
    drop(stream);
    opened
}

async fn accept_all(server: &WgNet) {
    let mut listener = server.listen(PORT).await.unwrap();
    tokio::spawn(async move { while listener.accept().await.is_some() {} });
}

/// The client starts, its first initiation is lost, and a connection waits
/// for the session at once.
#[tokio::test]
async fn a_lost_initiation_with_data_waiting_is_resent_within_a_second() {
    let sim = SimNet::new();
    let link = LinkProfile { latency: Duration::from_millis(10), ..LinkProfile::default() };
    sim.set_link(addr(CLIENT), addr(SERVER), link);
    let configs = config_pair(addr(SERVER));
    let server_path = SocketPath::new(sim.bind(addr(SERVER)).unwrap(), None);
    let server = WgNet::start_with_underlay(configs.server, server_path).unwrap();
    accept_all(&server).await;
    let pending = Arc::new(AtomicU32::new(1));
    let client_path = DropInitiations {
        inner: SocketPath::new(sim.bind(addr(CLIENT)).unwrap(), Some(addr(SERVER))),
        pending: Arc::clone(&pending),
    };
    let client = WgNet::start_with_underlay(configs.client, client_path).unwrap();
    wait_lost(&pending).await;

    let opened = time_connect(&client, SocketAddr::new(configs.server_v4, PORT)).await;
    eprintln!("lost initiation, sim 10 ms link: connection open after {opened:?}");
    assert!(opened < BOUND, "open after {opened:?}: waited for boringtun's 5 s retry");
    client.shutdown().await;
    server.shutdown().await;
}

/// The same over real UDP sockets on loopback.
#[tokio::test]
async fn a_lost_initiation_over_loopback_udp_is_resent_within_a_second() {
    let client_socket = UdpSocket::bind("127.0.0.1:0").await.unwrap();
    let server_socket = UdpSocket::bind("127.0.0.1:0").await.unwrap();
    let server_addr = server_socket.local_addr().unwrap();
    let configs = config_pair(server_addr);
    let server =
        WgNet::start_with_underlay(configs.server, SocketPath::new(server_socket, None)).unwrap();
    accept_all(&server).await;
    let pending = Arc::new(AtomicU32::new(1));
    let client_path = DropInitiations {
        inner: SocketPath::new(client_socket, Some(server_addr)),
        pending: Arc::clone(&pending),
    };
    let client = WgNet::start_with_underlay(configs.client, client_path).unwrap();
    wait_lost(&pending).await;

    let opened = time_connect(&client, SocketAddr::new(configs.server_v4, PORT)).await;
    eprintln!("lost initiation, loopback UDP: connection open after {opened:?}");
    assert!(opened < BOUND, "open after {opened:?}: waited for boringtun's 5 s retry");
    client.shutdown().await;
    server.shutdown().await;
}

/// The measured case in full, in real time (over three minutes, so not in
/// the default run): a working tunnel, the server unreachable for 190 s,
/// the link back, and the client's next initiation lost.
#[tokio::test]
#[ignore = "takes 190 s of real time; run with --ignored to measure"]
async fn after_a_190_s_pause_the_next_connection_opens_within_a_second() {
    let sim = SimNet::new();
    let link = LinkProfile { latency: Duration::from_millis(10), ..LinkProfile::default() };
    sim.set_link(addr(CLIENT), addr(SERVER), link);
    let configs = config_pair(addr(SERVER));
    let server_path = SocketPath::new(sim.bind(addr(SERVER)).unwrap(), None);
    let server = WgNet::start_with_underlay(configs.server, server_path).unwrap();
    accept_all(&server).await;
    let pending = Arc::new(AtomicU32::new(0));
    let client_path = DropInitiations {
        inner: SocketPath::new(sim.bind(addr(CLIENT)).unwrap(), Some(addr(SERVER))),
        pending: Arc::clone(&pending),
    };
    let client = WgNet::start_with_underlay(configs.client, client_path).unwrap();
    let target = SocketAddr::new(configs.server_v4, PORT);
    let warm = time_connect(&client, target).await;
    eprintln!("warm connection open after {warm:?}");

    sim.set_link(addr(CLIENT), addr(SERVER), LinkProfile { cut: true, ..link });
    tokio::time::sleep(Duration::from_secs(190)).await;
    sim.set_link(addr(CLIENT), addr(SERVER), link);
    pending.store(1, Ordering::SeqCst);

    let opened = time_connect(&client, target).await;
    eprintln!("after a 190 s pause: connection open after {opened:?}");
    assert!(opened < BOUND, "open after {opened:?}: waited for boringtun's 5 s retry");
    client.shutdown().await;
    server.shutdown().await;
}
