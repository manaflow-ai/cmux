//! A lost SYN on a fresh tunnel connection.
//!
//! Before a connection has an RTT sample, smoltcp resends on its initial
//! retransmission timeout, RFC 6298's 1 s. A connection's first segment is
//! its SYN, so one lost SYN (3% of them on the `lossy-3` phone profile) held
//! a cold dial for a full second. The tunnel sets the initial timeout to
//! 300 ms.
//!
//! The client's underlay below drops the first data message that carries a
//! segment (the SYN), with any copy sent beside it, once. The connection must open about 300 ms later, not
//! 1 s. The clock is Tokio's paused clock, so durations
//! are simulated.

use std::io;
use std::net::SocketAddr;
use std::sync::{Arc, Mutex};
use std::task::{Context, Poll};
use std::time::Duration;

use cmux_transport::PathId;
use cmux_wg::testing::config_pair;
use cmux_wg::testing::sim::{LinkProfile, SimNet};
use cmux_wg::{Origin, Received, SocketPath, Underlay, WgNet};
use tokio::time::Instant;

const CLIENT: &str = "192.0.2.94:51820";
const SERVER: &str = "192.0.2.95:51820";
const DATA: u8 = 4;
/// A WireGuard keepalive is a 32-byte data message; anything longer carries
/// an IP packet.
const KEEPALIVE: usize = 32;

fn addr(text: &str) -> SocketAddr {
    text.parse().expect("literal address")
}

/// Copies of one send leave together (the tunnel may send a packet twice);
/// anything within this of the first is the same send.
const SAME_SEND: Duration = Duration::from_millis(5);

/// Records when each segment-carrying data message leaves; drops the first
/// send's copies.
struct DropFirstSegment<U> {
    inner: U,
    sent: Arc<Mutex<Vec<Instant>>>,
}

impl<U: Underlay> DropFirstSegment<U> {
    fn outgoing(&mut self, datagram: &[u8], send: impl Fn(&mut U, &[u8])) {
        if datagram.first() == Some(&DATA) && datagram.len() > KEEPALIVE {
            let now = Instant::now();
            let mut sent = self.sent.lock().unwrap();
            let first = *sent.first().unwrap_or(&now);
            if now - first <= SAME_SEND {
                if sent.is_empty() {
                    sent.push(now);
                }
                return;
            }
            sent.push(now);
        }
        send(&mut self.inner, datagram);
    }
}

impl<U: Underlay> Underlay for DropFirstSegment<U> {
    fn send(&mut self, datagram: &[u8]) {
        self.outgoing(datagram, |inner, datagram| inner.send(datagram));
    }

    fn send_on(&mut self, path: PathId, datagram: &[u8]) {
        self.outgoing(datagram, |inner, datagram| inner.send_on(path, datagram));
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

#[tokio::test(start_paused = true)]
async fn a_lost_syn_is_resent_after_300_ms_not_one_second() {
    let sim = SimNet::new();
    let link = LinkProfile { latency: Duration::from_millis(10), ..LinkProfile::default() };
    sim.set_link(addr(CLIENT), addr(SERVER), link);
    let configs = config_pair(addr(SERVER));
    let server_path = SocketPath::new(sim.bind(addr(SERVER)).unwrap(), None);
    let server = WgNet::start_with_underlay(configs.server, server_path).unwrap();
    let mut listener = server.listen(7000).await.unwrap();
    tokio::spawn(async move { while listener.accept().await.is_some() {} });
    let sent = Arc::new(Mutex::new(Vec::new()));
    let client_path = DropFirstSegment {
        inner: SocketPath::new(sim.bind(addr(CLIENT)).unwrap(), Some(addr(SERVER))),
        sent: Arc::clone(&sent),
    };
    let client = WgNet::start_with_underlay(configs.client, client_path).unwrap();

    let started = Instant::now();
    let stream = tokio::time::timeout(
        Duration::from_secs(10),
        client.connect(SocketAddr::new(configs.server_v4, 7000)),
    )
    .await
    .expect("connect within 10 s")
    .expect("connect");
    let opened = started.elapsed();
    let dropped = sent.lock().unwrap().len();
    eprintln!("connection open after {opened:?} (simulated)");
    assert!(dropped >= 1, "no SYN was dropped");
    // The handshake and one round trip take about 40 ms on this link; the
    // dropped SYN adds the initial RTO. smoltcp's default made this 1.02 s.
    assert!(opened >= Duration::from_millis(300), "open after {opened:?}: the SYN was not lost");
    assert!(
        opened < Duration::from_millis(400),
        "open after {opened:?}, not 300 ms plus the round trip"
    );
    drop(stream);
    client.shutdown().await;
    server.shutdown().await;
}
