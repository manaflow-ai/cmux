//! Ultra mode's Auto at a long round trip: the first loss costs about one
//! round trip, not the congestion window.
//!
//! Auto starts with repair off and turns it on at the first loss, so that
//! loss itself still reaches TCP. Before, TCP took it as congestion: the
//! window was cut in slow start, and at 300 ms a stream that needed the
//! old window fell seconds behind (5.6 s to 2.3 s at 1% loss, against
//! 0.3 s with repair always on). Now the tunnel tells its TCP that the link
//! repairs its own losses once repair turns on (vendored smoltcp, cmux
//! patch), so the loss is resent and nothing is cut.
//!
//! The server's underlay drops one data datagram early in a download, while
//! the window is still growing. The clock is Tokio's paused clock, so
//! durations are simulated.

use std::io;
use std::net::SocketAddr;
use std::sync::Arc;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::task::{Context, Poll};
use std::time::Duration;

use cmux_transport::{PathId, PathKind, SelectorConfig};
use cmux_wg::testing::config_pair;
use cmux_wg::testing::sim::{LinkProfile, SimNet};
use cmux_wg::{
    Multipath, Origin, ProbeConfig, Received, SocketPath, UltraChoice, UltraStats, Underlay, WgNet,
};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::time::Instant;

const CLIENT: &str = "192.0.2.96:51820";
const SERVER: &str = "192.0.2.97:51820";
const DATA: u8 = 4;
/// Encrypted data messages longer than this carry payload bytes.
const CARRIES_DATA: usize = 300;
/// One way: a 300 ms round trip.
const ONE_WAY: Duration = Duration::from_millis(150);
const RTT: Duration = Duration::from_millis(300);
const DOWNLOAD: usize = 1024 * 1024;

fn addr(text: &str) -> SocketAddr {
    text.parse().expect("literal address")
}

/// Drops the data-carrying datagram numbered `drop` (from 1), once.
struct DropOne<U> {
    inner: U,
    seen: usize,
    drop: Option<usize>,
    dropped: Arc<AtomicUsize>,
}

impl<U: Underlay> DropOne<U> {
    fn outgoing(&mut self, datagram: &[u8], send: impl Fn(&mut U, &[u8])) {
        if datagram.first() == Some(&DATA) && datagram.len() > CARRIES_DATA {
            self.seen += 1;
            if self.drop == Some(self.seen) {
                self.dropped.fetch_add(1, Ordering::Relaxed);
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

/// How long a [`DOWNLOAD`] takes from request to last byte, with both ends
/// on `choice` and the server's `drop`-th data datagram lost, and the
/// server's ultra counters.
async fn download(choice: UltraChoice, drop: Option<usize>) -> (Duration, UltraStats) {
    let sim = SimNet::new();
    let link = LinkProfile { latency: ONE_WAY, ..LinkProfile::default() };
    sim.set_link(addr(CLIENT), addr(SERVER), link);
    let configs = config_pair(addr(SERVER));
    let dropped = Arc::new(AtomicUsize::new(0));
    let server_path = DropOne {
        inner: SocketPath::new(sim.bind(addr(SERVER)).unwrap(), None),
        seen: 0,
        drop,
        dropped: Arc::clone(&dropped),
    };
    let server = WgNet::start_with_choice(configs.server, server_path, choice).unwrap();
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
    let client = WgNet::start_with_choice(configs.client, client_path, choice).unwrap();
    let mut stream = client.connect(SocketAddr::new(configs.server_v4, 7000)).await.unwrap();

    let started = Instant::now();
    stream.write_all(&[1]).await.expect("request");
    let mut body = vec![0u8; DOWNLOAD];
    tokio::time::timeout(Duration::from_secs(120), stream.read_exact(&mut body))
        .await
        .expect("download within 120 s")
        .expect("read");
    let took = started.elapsed();
    assert_eq!(dropped.load(Ordering::Relaxed), usize::from(drop.is_some()), "dropped as asked");
    assert!(body.iter().all(|&byte| byte == 7), "the body arrived intact");
    let stats = server.ultra_stats();
    client.shutdown().await;
    server.shutdown().await;
    (took, stats)
}

/// The 30th data datagram: the third round trip of slow start.
const EARLY: usize = 30;

#[tokio::test(start_paused = true)]
async fn auto_adds_nothing_on_a_clean_link() {
    let (clean_off, _) = download(UltraChoice::Off, None).await;
    let (clean_auto, stats) = download(UltraChoice::AUTO, None).await;
    eprintln!("clean 1 MiB at 300 ms: off {clean_off:?}, auto {clean_auto:?}, auto {stats:?}");
    assert_eq!(stats.auto_on, 0, "Auto stays off on a clean link: {stats:?}");
    assert_eq!(stats.overhead_bytes, 0, "and sends no extra bytes: {stats:?}");
    // Scheduling under a busy test run moves a simulated finish by a few
    // milliseconds either way.
    let slack = Duration::from_millis(50);
    assert!(
        clean_auto <= clean_off + slack && clean_off <= clean_auto + slack,
        "a clean link behaves as with ultra mode off: {clean_auto:?} against {clean_off:?}"
    );
}

#[tokio::test(start_paused = true)]
async fn the_first_loss_costs_auto_about_one_round_trip() {
    let (clean, _) = download(UltraChoice::Off, None).await;
    let (always, _) = download(UltraChoice::ALWAYS, Some(EARLY)).await;
    let (off, _) = download(UltraChoice::Off, Some(EARLY)).await;
    let (auto, stats) = download(UltraChoice::AUTO, Some(EARLY)).await;
    eprintln!(
        "1 MiB at 300 ms, datagram {EARLY} lost: clean {clean:?}, off {off:?}, \
         auto {auto:?}, always {always:?}; auto {stats:?}"
    );
    assert_eq!(stats.auto_on, 1, "Auto turned on once: {stats:?}");
    // The loss is resent about one round trip after it happened (the SACK
    // that reports it), and the window it would have cut is kept.
    assert!(
        auto <= clean + RTT + RTT / 2,
        "Auto took {auto:?} against {clean:?} clean: more than about one round trip lost"
    );
    // Without repair the same loss cuts the window in slow start: the
    // check above is not passing for want of a loss.
    assert!(off > auto + RTT, "off {off:?} against auto {auto:?}: the loss cut nothing");
}

const CLIENT_DEAD: &str = "192.0.2.98:51820";
const SERVER_DEAD: &str = "192.0.2.99:51820";

/// Both ends on two paths with path probes: the clean one, and a candidate
/// whose link drops everything, which each side keeps probing every 100 ms
/// (the dial interval) as production underlays do. Returns the client's and
/// the server's ultra counters, and the datagrams sent on the dead path.
async fn download_beside_a_dead_candidate(choice: UltraChoice) -> (UltraStats, UltraStats, u64) {
    let sim = SimNet::new();
    let link = LinkProfile { latency: ONE_WAY, ..LinkProfile::default() };
    sim.set_link(addr(CLIENT), addr(SERVER), link);
    let dead = LinkProfile { cut: true, ..link };
    sim.set_link(addr(CLIENT_DEAD), addr(SERVER_DEAD), dead);
    let configs = config_pair(addr(SERVER));
    let paths = |good: (&str, &str), dead: (&str, &str)| {
        let (underlay, control) =
            Multipath::with_probes(SelectorConfig::default(), ProbeConfig::default());
        let socket = SocketPath::new(sim.bind(addr(good.0)).unwrap(), Some(addr(good.1)));
        control.add_path(PathKind::DirectLan, socket);
        let socket = SocketPath::new(sim.bind(addr(dead.0)).unwrap(), Some(addr(dead.1)));
        control.add_path(PathKind::DirectWan, socket);
        (underlay, control)
    };
    let (server_paths, _server_control) = paths((SERVER, CLIENT), (SERVER_DEAD, CLIENT_DEAD));
    let server = WgNet::start_with_choice(configs.server, server_paths, choice).unwrap();
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
    let (client_paths, _client_control) = paths((CLIENT, SERVER), (CLIENT_DEAD, SERVER_DEAD));
    let client = WgNet::start_with_choice(configs.client, client_paths, choice).unwrap();
    let mut stream = client.connect(SocketAddr::new(configs.server_v4, 7000)).await.unwrap();
    stream.write_all(&[1]).await.expect("request");
    let mut body = vec![0u8; DOWNLOAD];
    tokio::time::timeout(Duration::from_secs(120), stream.read_exact(&mut body))
        .await
        .expect("download within 120 s")
        .expect("read");
    assert!(body.iter().all(|&byte| byte == 7), "the body arrived intact");
    let dead_sent = sim.sent_from(addr(CLIENT_DEAD)) + sim.sent_from(addr(SERVER_DEAD));
    let stats = (client.ultra_stats(), server.ultra_stats());
    client.shutdown().await;
    server.shutdown().await;
    (stats.0, stats.1, dead_sent)
}

/// Path probes take WireGuard counters but leave on their own path: a
/// candidate that never delivers one must not look like loss on the clean
/// path the data takes, or Auto would send repair data on a clean link for
/// as long as the candidate is probed.
#[tokio::test(start_paused = true)]
async fn probes_on_a_dead_candidate_leave_auto_off() {
    let (client, server, dead_sent) = download_beside_a_dead_candidate(UltraChoice::AUTO).await;
    eprintln!("dead candidate: {dead_sent} datagrams on it; client {client:?}; server {server:?}");
    assert!(dead_sent >= 20, "the dead candidate was probed throughout: {dead_sent}");
    for stats in [client, server] {
        assert_eq!(stats.auto_on, 0, "Auto stays off beside a dead candidate: {stats:?}");
        assert_eq!(stats.overhead_bytes, 0, "and sends no repair bytes: {stats:?}");
    }
}
