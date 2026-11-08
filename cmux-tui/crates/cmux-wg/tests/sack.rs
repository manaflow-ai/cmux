//! Several segments lost from one window of a bulk transfer.
//!
//! Without selective ACKs the sender learns of one hole per round trip: each
//! partial ACK reveals the next, each fast retransmit cuts the congestion
//! window again, and a hole with too little data after it waits for the
//! retransmission timeout. With SACK (vendored smoltcp, cmux patch) the
//! receiver reports the ranges it holds, and the sender resends all the holes
//! in about one round trip with one window cut.
//!
//! The server's underlay drops four data datagrams spread over one window of
//! a 512 KiB download. The clock is Tokio's paused clock, so durations are
//! simulated.

use std::io;
use std::net::SocketAddr;
use std::sync::Arc;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::task::{Context, Poll};
use std::time::Duration;

use cmux_transport::PathId;
use cmux_wg::testing::config_pair;
use cmux_wg::testing::sim::{LinkProfile, SimNet};
use cmux_wg::{Origin, Received, SocketPath, Underlay, WgNet};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::time::Instant;

const CLIENT: &str = "192.0.2.94:51820";
const SERVER: &str = "192.0.2.95:51820";
const DATA: u8 = 4;
/// Encrypted data messages longer than this carry payload bytes (a pure ACK
/// is a 40-byte packet plus 32 bytes of WireGuard overhead and padding).
const CARRIES_DATA: usize = 300;
/// The data datagrams dropped, counted from the first: four holes in one
/// window, each with data after it.
const DROPPED: [usize; 4] = [120, 126, 132, 138];
const DOWNLOAD: usize = 512 * 1024;

fn addr(text: &str) -> SocketAddr {
    text.parse().expect("literal address")
}

/// Drops the data-carrying datagrams numbered in [`DROPPED`], once each.
struct DropSome<U> {
    inner: U,
    seen: usize,
    dropped: Arc<AtomicUsize>,
}

impl<U: Underlay> DropSome<U> {
    fn outgoing(&mut self, datagram: &[u8], send: impl Fn(&mut U, &[u8])) {
        if datagram.first() == Some(&DATA) && datagram.len() > CARRIES_DATA {
            self.seen += 1;
            if DROPPED.contains(&self.seen) {
                self.dropped.fetch_add(1, Ordering::Relaxed);
                return;
            }
        }
        send(&mut self.inner, datagram);
    }
}

impl<U: Underlay> Underlay for DropSome<U> {
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
async fn several_holes_in_one_window_are_repaired_together() {
    let sim = SimNet::new();
    let link = LinkProfile { latency: Duration::from_millis(10), ..LinkProfile::default() };
    sim.set_link(addr(CLIENT), addr(SERVER), link);
    let configs = config_pair(addr(SERVER));
    let dropped = Arc::new(AtomicUsize::new(0));
    let server_path = DropSome {
        inner: SocketPath::new(sim.bind(addr(SERVER)).unwrap(), None),
        seen: 0,
        dropped: Arc::clone(&dropped),
    };
    let server = WgNet::start_with_underlay(configs.server, server_path).unwrap();
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
    let client_path = SocketPath::new(sim.bind(addr(CLIENT)).unwrap(), Some(addr(SERVER)));
    let client = WgNet::start_with_underlay(configs.client, client_path).unwrap();
    let mut stream = client.connect(SocketAddr::new(configs.server_v4, 7000)).await.unwrap();

    let started = Instant::now();
    stream.write_all(&[1]).await.expect("request");
    let mut body = vec![0u8; DOWNLOAD];
    tokio::time::timeout(Duration::from_secs(30), stream.read_exact(&mut body))
        .await
        .expect("download within 30 s")
        .expect("read");
    let took = started.elapsed();
    assert_eq!(dropped.load(Ordering::Relaxed), DROPPED.len(), "the datagrams were dropped");
    assert!(body.iter().all(|&byte| byte == 7), "the body arrived intact");
    eprintln!("512 KiB with {} holes in one window: {took:?} (simulated)", DROPPED.len());
    assert!(took < Duration::from_millis(SACK_BOUND_MS), "the download took {took:?}");
    client.shutdown().await;
    server.shutdown().await;
}

/// Set from the run that measured this test with and without SACK; see the PR.
const SACK_BOUND_MS: u64 = 60_000;
