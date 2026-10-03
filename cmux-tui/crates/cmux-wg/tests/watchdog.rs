//! A session whose handshake completes but whose data is dropped.
//!
//! Measured on Freestyle: on a tunnel unused for more than about five
//! minutes, the first session's handshake completes but the gateway drops
//! its data, and the first echo takes about 15 s (WireGuard re-handshakes
//! only after KEEPALIVE + REKEY_TIMEOUT). The underlay below reproduces it:
//! it drops every data message (in both directions) until the client has
//! sent its second handshake initiation. Real time: boringtun's own timers
//! read the real clock, so the 15 s rule cannot be simulated.

use std::io;
use std::net::SocketAddr;
use std::sync::Arc;
use std::sync::atomic::{AtomicU32, AtomicU64, Ordering};
use std::task::{Context, Poll};
use std::time::Duration;

use cmux_transport::PathId;
use cmux_wg::testing::config_pair;
use cmux_wg::testing::sim::{LinkProfile, SimNet};
use cmux_wg::{Origin, Received, SocketPath, Underlay, WgNet};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::time::Instant;

const CLIENT: &str = "192.0.2.70:51820";
const SERVER: &str = "192.0.2.80:51820";
const DATA: u8 = 4;
const INITIATION: u8 = 1;

fn addr(text: &str) -> SocketAddr {
    text.parse().expect("literal address")
}

/// Drops data messages of the first session; handshakes pass.
struct FirstSessionDropsData<U> {
    inner: U,
    initiations: Arc<AtomicU32>,
    dropped: Arc<AtomicU64>,
}

impl<U: Underlay> FirstSessionDropsData<U> {
    fn first_session(&self) -> bool {
        self.initiations.load(Ordering::Relaxed) < 2
    }

    /// Whether to drop an outgoing datagram.
    fn drops(&self, datagram: &[u8]) -> bool {
        match datagram.first() {
            Some(&INITIATION) => {
                self.initiations.fetch_add(1, Ordering::Relaxed);
                false
            }
            Some(&DATA) if self.first_session() => {
                self.dropped.fetch_add(1, Ordering::Relaxed);
                true
            }
            _ => false,
        }
    }
}

impl<U: Underlay> Underlay for FirstSessionDropsData<U> {
    fn send(&mut self, datagram: &[u8]) {
        if !self.drops(datagram) {
            self.inner.send(datagram);
        }
    }

    fn send_on(&mut self, path: PathId, datagram: &[u8]) {
        if !self.drops(datagram) {
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
        loop {
            match self.inner.poll_recv(cx, buffer) {
                Poll::Ready(Ok(received))
                    if buffer.first() == Some(&DATA) && self.first_session() =>
                {
                    self.dropped.fetch_add(1, Ordering::Relaxed);
                    let _ = received;
                }
                other => return other,
            }
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

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_session_that_carries_no_data_is_replaced_within_seconds() {
    let sim = SimNet::new();
    let link = LinkProfile { latency: Duration::from_millis(10), ..LinkProfile::default() };
    sim.set_link(addr(CLIENT), addr(SERVER), link);
    let configs = config_pair(addr(SERVER));
    let dropped = Arc::new(AtomicU64::new(0));
    let client_path = FirstSessionDropsData {
        inner: SocketPath::new(sim.bind(addr(CLIENT)).unwrap(), Some(addr(SERVER))),
        initiations: Arc::new(AtomicU32::new(0)),
        dropped: Arc::clone(&dropped),
    };
    let server_path = SocketPath::new(sim.bind(addr(SERVER)).unwrap(), None);
    let server = WgNet::start_with_underlay(configs.server, server_path).unwrap();
    let mut listener = server.listen(7000).await.unwrap();
    tokio::spawn(async move {
        while let Some(mut stream) = listener.accept().await {
            tokio::spawn(async move {
                let mut buffer = [0u8; 64];
                while let Ok(count @ 1..) = stream.read(&mut buffer).await {
                    if stream.write_all(&buffer[..count]).await.is_err() {
                        break;
                    }
                }
            });
        }
    });

    let started = Instant::now();
    let client = WgNet::start_with_underlay(configs.client, client_path).unwrap();
    let first_echo = async {
        let mut stream = client.connect(SocketAddr::new(configs.server_v4, 7000)).await.unwrap();
        stream.write_all(b"ping").await.unwrap();
        let mut echo = [0u8; 4];
        stream.read_exact(&mut echo).await.unwrap();
        assert_eq!(&echo, b"ping");
    };
    tokio::time::timeout(Duration::from_secs(40), first_echo).await.expect("an echo at all");
    let took = started.elapsed();
    eprintln!(
        "first good echo after {took:?} ({} datagrams of the first session dropped)",
        dropped.load(Ordering::Relaxed)
    );
    assert!(took <= Duration::from_secs(4), "first good echo after {took:?}");
    client.shutdown().await;
    server.shutdown().await;
}
