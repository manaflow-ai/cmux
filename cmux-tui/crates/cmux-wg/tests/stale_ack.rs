//! A late segment whose ACK is already stale.
//!
//! When a path changes (a roam, a relay copy racing a direct copy, a
//! carrier resending what went into a dead route) a data segment can arrive
//! after newer segments of the same connection. Those newer segments carry
//! a newer ACK, so by the time the late one arrives its ACK is below what
//! the receiver already has acknowledged. RFC 9293 3.10.7.4 says to ignore
//! such an ACK and still take the segment's data; smoltcp drops the whole
//! segment, and with data flowing both ways (an echoing terminal) no pure
//! duplicate ACKs trigger a fast retransmit, so the hole waits for the 1 s
//! minimum retransmission timeout.
//!
//! The server's underlay below holds back one echo segment until three
//! later ones have left. The echo must not stall for a retransmission
//! timeout. The clock is Tokio's paused clock, so durations are simulated.

use std::io;
use std::net::SocketAddr;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::task::{Context, Poll};
use std::time::Duration;

use cmux_transport::PathId;
use cmux_wg::testing::config_pair;
use cmux_wg::testing::sim::{LinkProfile, SimNet};
use cmux_wg::{Origin, Received, SocketPath, Underlay, WgNet};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::time::Instant;

const CLIENT: &str = "192.0.2.90:51820";
const SERVER: &str = "192.0.2.91:51820";
const DATA: u8 = 4;
/// Encrypted data messages longer than this carry echo bytes (a pure ACK
/// is a 40-byte packet plus 32 bytes of WireGuard overhead and padding).
const CARRIES_DATA: usize = 300;
/// Which data-carrying datagram is held back, and how many later ones
/// leave before it.
const HELD: usize = 30;
const OVERTAKEN_BY: usize = 3;

fn addr(text: &str) -> SocketAddr {
    text.parse().expect("literal address")
}

/// Sends the `HELD`th data-carrying datagram after `OVERTAKEN_BY` later ones.
struct HoldOne<U> {
    inner: U,
    seen: usize,
    held: Option<Vec<u8>>,
    after_held: usize,
    released: Arc<AtomicBool>,
}

impl<U: Underlay> HoldOne<U> {
    fn outgoing(&mut self, datagram: &[u8], send: impl Fn(&mut U, &[u8])) {
        if datagram.first() != Some(&DATA) || datagram.len() <= CARRIES_DATA {
            send(&mut self.inner, datagram);
            return;
        }
        self.seen += 1;
        if self.seen == HELD {
            self.held = Some(datagram.to_vec());
            return;
        }
        send(&mut self.inner, datagram);
        if self.held.is_some() {
            self.after_held += 1;
            if self.after_held == OVERTAKEN_BY {
                let held = self.held.take().expect("held");
                send(&mut self.inner, &held);
                self.released.store(true, Ordering::Relaxed);
            }
        }
    }
}

impl<U: Underlay> Underlay for HoldOne<U> {
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
async fn a_late_segment_with_a_stale_ack_is_not_dropped() {
    let sim = SimNet::new();
    let link = LinkProfile { latency: Duration::from_millis(10), ..LinkProfile::default() };
    sim.set_link(addr(CLIENT), addr(SERVER), link);
    let configs = config_pair(addr(SERVER));
    let released = Arc::new(AtomicBool::new(false));
    let server_path = HoldOne {
        inner: SocketPath::new(sim.bind(addr(SERVER)).unwrap(), None),
        seen: 0,
        held: None,
        after_held: 0,
        released: Arc::clone(&released),
    };
    let server = WgNet::start_with_underlay(configs.server, server_path).unwrap();
    let mut listener = server.listen(7000).await.unwrap();
    tokio::spawn(async move {
        while let Some(mut stream) = listener.accept().await {
            tokio::spawn(async move {
                let mut buffer = vec![0u8; 16 * 1024];
                while let Ok(count @ 1..) = stream.read(&mut buffer).await {
                    if stream.write_all(&buffer[..count]).await.is_err() {
                        break;
                    }
                }
            });
        }
    });
    let client_path = SocketPath::new(sim.bind(addr(CLIENT)).unwrap(), Some(addr(SERVER)));
    let client = WgNet::start_with_underlay(configs.client, client_path).unwrap();
    let stream = client.connect(SocketAddr::new(configs.server_v4, 7000)).await.unwrap();
    let (mut reader, mut writer) = tokio::io::split(stream);

    // Terminal-like traffic both ways: 1000 bytes every 10 ms, echoed.
    const CHUNK: usize = 1000;
    const CHUNKS: usize = 150;
    let write = async {
        let mut tick = tokio::time::interval(Duration::from_millis(10));
        for index in 0..CHUNKS {
            tick.tick().await;
            writer.write_all(&[(index % 251) as u8; CHUNK]).await.expect("write");
        }
    };
    let read = async {
        let mut arrivals = Vec::new();
        let mut buffer = vec![0u8; 16 * 1024];
        let mut got = 0;
        while got < CHUNK * CHUNKS {
            let count = reader.read(&mut buffer).await.expect("read");
            assert!(count > 0, "the echo closed");
            got += count;
            arrivals.push(Instant::now());
        }
        arrivals
    };
    let (_, arrivals) =
        tokio::time::timeout(Duration::from_secs(30), async { tokio::join!(write, read) })
            .await
            .expect("every byte echoed");
    assert!(released.load(Ordering::Relaxed), "the held segment was sent");
    let stall = arrivals.windows(2).map(|pair| pair[1] - pair[0]).max().unwrap_or_default();
    eprintln!("longest gap between echo reads: {stall:?} (simulated)");
    // Without the fix the hole waits for the 1 s minimum RTO.
    assert!(stall < Duration::from_millis(300), "the echo stalled {stall:?}");
    client.shutdown().await;
    server.shutdown().await;
}
