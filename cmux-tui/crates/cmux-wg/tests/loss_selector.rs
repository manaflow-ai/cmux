//! A lossy direct path hands the session to the relay (the selector's loss
//! rule, `cmux_transport::selector`).
//!
//! cmux-wg's TCP holds about `MSS / RTT * 1.22 / sqrt(p)` on a lossy path:
//! at 50 ms and 2 % that is 1.6 Mbit/s and a desktop stream collapses to 0.1
//! on-time frames a second (cmuxterm-hq connectivity-map 3.2). A relay on
//! kernel TCP repairs its own loss, so the tunnel's TCP sees none there.
//!
//! Two ends, each a multipath underlay with a direct path (25 ms each way,
//! every 20th datagram the peer sends dropped on arrival: 5 %) and a relay
//! path (30 ms each way, no loss). The direct path wins first, as it always
//! does; the download's datagrams (or its ACKs) then show its loss, the end
//! that measured it moves to the relay, and the other end follows it. The clock is Tokio's
//! paused clock.

use std::io;
use std::net::SocketAddr;
use std::task::{Context, Poll};
use std::time::Duration;

use cmux_transport::{LossRule, PathId, PathKind, SelectorConfig};
use cmux_wg::testing::config_pair;
use cmux_wg::testing::sim::{LinkProfile, SimNet};
use cmux_wg::{
    Multipath, MultipathControl, Origin, ProbeConfig, Received, SocketPath, Underlay, WgNet,
};
use tokio::io::{AsyncReadExt, AsyncWriteExt};

const A_DIRECT: &str = "192.0.2.10:51820";
const B_DIRECT: &str = "192.0.2.20:51820";
const A_RELAY: &str = "198.51.100.10:40000";
const B_RELAY: &str = "198.51.100.20:40000";
const DOWNLOAD: usize = 2 * 1024 * 1024;
const DROP_EVERY: usize = 20;

fn addr(text: &str) -> SocketAddr {
    text.parse().expect("literal address")
}

/// Drops every [`DROP_EVERY`]th WireGuard transport datagram that arrives.
struct LossyArrivals<U> {
    inner: U,
    seen: usize,
}

impl<U: Underlay> Underlay for LossyArrivals<U> {
    fn send(&mut self, datagram: &[u8]) {
        self.inner.send(datagram);
    }

    fn send_on(&mut self, path: PathId, datagram: &[u8]) {
        self.inner.send_on(path, datagram);
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
        loop {
            let ready = self.inner.poll_recv(cx, buffer);
            if let Poll::Ready(Ok(received)) = &ready
                && buffer[..received.len].first() == Some(&4)
            {
                self.seen += 1;
                if self.seen.is_multiple_of(DROP_EVERY) {
                    continue;
                }
            }
            return ready;
        }
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

/// The loss rule with fewer samples, so the test's short download judges.
fn config() -> SelectorConfig {
    let loss = LossRule { min_samples: 128, ..LossRule::default() };
    SelectorConfig { loss: Some(loss), ..SelectorConfig::default() }
}

fn end(
    sim: &SimNet,
    direct: (&str, &str),
    relay: (&str, &str),
) -> (Multipath, MultipathControl, PathId, PathId) {
    let (underlay, control) = Multipath::with_probes(config(), ProbeConfig::default());
    let direct_socket = sim.bind(addr(direct.0)).expect("bind direct");
    let relay_socket = sim.bind(addr(relay.0)).expect("bind relay");
    let direct = control.add_path(
        PathKind::DirectWan,
        LossyArrivals { inner: SocketPath::new(direct_socket, Some(addr(direct.1))), seen: 0 },
    );
    let relay =
        control.add_path(PathKind::DoRelay, SocketPath::new(relay_socket, Some(addr(relay.1))));
    (underlay, control, direct, relay)
}

#[tokio::test(start_paused = true)]
async fn a_lossy_direct_path_moves_both_ends_to_the_relay() {
    let sim = SimNet::new();
    let direct = LinkProfile { latency: Duration::from_millis(25), ..LinkProfile::default() };
    let relay = LinkProfile { latency: Duration::from_millis(30), ..LinkProfile::default() };
    sim.set_link(addr(A_DIRECT), addr(B_DIRECT), direct);
    sim.set_link(addr(A_RELAY), addr(B_RELAY), relay);
    let configs = config_pair(addr(B_DIRECT));
    let (a_underlay, a, a_direct, a_relay) = end(&sim, (A_DIRECT, B_DIRECT), (A_RELAY, B_RELAY));
    let (b_underlay, b, b_direct, b_relay) = end(&sim, (B_DIRECT, A_DIRECT), (B_RELAY, A_RELAY));
    let client = WgNet::start_with_underlay(configs.client, a_underlay).unwrap();
    let server = WgNet::start_with_underlay(configs.server, b_underlay).unwrap();

    let mut listener = server.listen(7000).await.unwrap();
    tokio::spawn(async move {
        while let Some(mut stream) = listener.accept().await {
            tokio::spawn(async move {
                let mut request = [0u8; 1];
                if stream.read_exact(&mut request).await.is_ok() {
                    let _ = stream.write_all(&vec![7u8; DOWNLOAD]).await;
                }
            });
        }
    });
    let mut stream = client.connect(SocketAddr::new(configs.server_v4, 7000)).await.unwrap();
    let mut current = a.watch_current();
    tokio::time::timeout(Duration::from_secs(10), current.wait_for(|id| *id == Some(a_direct)))
        .await
        .expect("the direct path answers within 10 s")
        .unwrap();

    stream.write_all(&[1]).await.expect("request");
    let mut body = vec![0u8; DOWNLOAD];
    tokio::time::timeout(Duration::from_secs(120), stream.read_exact(&mut body))
        .await
        .expect("download within 120 s")
        .expect("read");
    assert!(body.iter().all(|&byte| byte == 7), "the body arrived intact");

    // Each end sees the loss of what it receives (the download one way, its
    // ACKs the other); whichever judges first moves, the other follows.
    let a_view = a.path(a_direct).unwrap().view;
    let b_view = b.path(b_direct).unwrap().view;
    assert!(a_view.lossy && b_view.lossy, "both left the direct path: {a_view:?} {b_view:?}");
    let judged: Vec<u32> = [a_view.loss_ppm, b_view.loss_ppm].into_iter().flatten().collect();
    assert!(!judged.is_empty(), "one end measured the loss");
    for loss in judged {
        // At least the 5 % dropped; the end that follows may also count the
        // peer's last datagrams before it left as gaps.
        assert!((30_000..150_000).contains(&loss), "about 5 % lost: {loss} ppm");
    }
    assert_eq!(a.current(), Some(a_relay));
    assert_eq!(b.current(), Some(b_relay));
    assert!(
        b.path(b_relay).unwrap().sent > 1_000,
        "the download moved to the relay: {:?}",
        b.path(b_relay)
    );
    client.shutdown().await;
    server.shutdown().await;
}
