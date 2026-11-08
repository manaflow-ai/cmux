//! A lost reply with nothing sent after it.
//!
//! A keystroke's echo is often the last segment of a burst: no later
//! segment draws duplicate ACKs, so only the retransmission timeout resends
//! it. smoltcp's default floor under that timeout is RFC 6298's 1 s, even on
//! a 20 ms round trip, so one lost echo held the screen for over a second.
//!
//! The server's underlay below drops one echo segment, once. The echo must
//! arrive well before 1 s. The clock is Tokio's paused clock, so durations
//! are simulated.

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

const CLIENT: &str = "192.0.2.92:51820";
const SERVER: &str = "192.0.2.93:51820";
const DATA: u8 = 4;
/// Encrypted data messages longer than this carry echo bytes (a pure ACK
/// is a 40-byte packet plus 32 bytes of WireGuard overhead and padding).
const CARRIES_DATA: usize = 300;
/// Round trips before the dropped one, so the sender has measured the RTT.
const WARM_UP: usize = 10;

fn addr(text: &str) -> SocketAddr {
    text.parse().expect("literal address")
}

/// Drops the data-carrying datagram after `WARM_UP` of them, once.
struct DropOne<U> {
    inner: U,
    seen: usize,
    dropped: Arc<AtomicBool>,
}

impl<U: Underlay> DropOne<U> {
    fn outgoing(&mut self, datagram: &[u8], send: impl Fn(&mut U, &[u8])) {
        if datagram.first() == Some(&DATA) && datagram.len() > CARRIES_DATA {
            self.seen += 1;
            if self.seen == WARM_UP + 1 {
                self.dropped.store(true, Ordering::Relaxed);
                return;
            }
        }
        send(&mut self.inner, datagram);
    }
}

impl<U: Underlay> Underlay for DropOne<U> {
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
async fn a_lost_last_segment_is_resent_well_before_one_second() {
    let sim = SimNet::new();
    let link = LinkProfile { latency: Duration::from_millis(10), ..LinkProfile::default() };
    sim.set_link(addr(CLIENT), addr(SERVER), link);
    let configs = config_pair(addr(SERVER));
    let dropped = Arc::new(AtomicBool::new(false));
    let server_path = DropOne {
        inner: SocketPath::new(sim.bind(addr(SERVER)).unwrap(), None),
        seen: 0,
        dropped: Arc::clone(&dropped),
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
    let mut stream = client.connect(SocketAddr::new(configs.server_v4, 7000)).await.unwrap();

    // One 1000-byte request at a time, each answered before the next.
    const CHUNK: usize = 1000;
    let mut echo_times = Vec::new();
    let mut buffer = vec![0u8; CHUNK];
    for index in 0..=WARM_UP {
        let sent = Instant::now();
        stream.write_all(&[index as u8; CHUNK]).await.expect("write");
        tokio::time::timeout(Duration::from_secs(10), stream.read_exact(&mut buffer))
            .await
            .expect("echo within 10 s")
            .expect("read");
        echo_times.push(sent.elapsed());
    }
    assert!(dropped.load(Ordering::Relaxed), "an echo segment was dropped");
    let lost = echo_times[WARM_UP];
    eprintln!("echo round trips: {echo_times:?} (simulated)");
    // With smoltcp's default 1 s floor the lost echo took over 1 s.
    assert!(lost < Duration::from_millis(400), "the lost echo took {lost:?}");
    client.shutdown().await;
    server.shutdown().await;
}
