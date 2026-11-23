//! A bulk transfer over an underlay path smaller than the tunnel MTU.
//!
//! At WireGuard's default MTU of 1420 a full segment leaves as a datagram
//! that fills a 1500 byte IPv6 path exactly. A path even a little smaller
//! (a tunnel, PPPoE, a mobile carrier) that drops oversized packets without
//! an ICMP error carries the handshake, ACKs and keystrokes, and loses every
//! full segment: a bulk transfer stalls for good. The link below models a
//! 1400 byte IPv6 path. Black-hole fallback in the tunnel's TCP must notice
//! the repeated timeouts of full segments and resend in 1280 byte packets.
//! The clock is Tokio's paused clock, so durations are simulated.

use std::net::{IpAddr, SocketAddr};
use std::time::Duration;

use cmux_wg::testing::config_pair;
use cmux_wg::testing::sim::{LinkProfile, SimNet};
use cmux_wg::{SocketPath, WgNet, WgStream};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::sync::watch;
use tokio::time::Instant;

const CLIENT: &str = "[2001:db8::10]:51820";
const SERVER: &str = "[2001:db8::20]:51820";
/// WireGuard's default interface MTU.
const TUNNEL_MTU: u16 = 1420;
/// The underlay path's MTU, less the outer IPv6 (40) and UDP (8) headers:
/// the longest WireGuard datagram it carries.
const PATH_MTU: usize = 1400;
const MAX_DATAGRAM: usize = PATH_MTU - 40 - 8;
const TOTAL: usize = 4 * 1024 * 1024;
const ONE_WAY: Duration = Duration::from_millis(10);
const LIMIT: Duration = Duration::from_secs(30);

fn addr(text: &str) -> SocketAddr {
    text.parse().expect("literal address")
}

fn payload() -> Vec<u8> {
    (0..TOTAL).map(|index| (index.wrapping_mul(2_654_435_761) >> 13) as u8).collect()
}

struct Pair {
    client: WgNet,
    server: WgNet,
    server_v4: IpAddr,
    server_v6: IpAddr,
}

fn pair(sim: &SimNet) -> Pair {
    let mut configs = config_pair(addr(SERVER));
    configs.client.mtu = TUNNEL_MTU;
    configs.server.mtu = TUNNEL_MTU;
    let client_path = SocketPath::new(sim.bind(addr(CLIENT)).unwrap(), Some(addr(SERVER)));
    let client = WgNet::start_with_underlay(configs.client.clone(), client_path).unwrap();
    let server_path = SocketPath::new(sim.bind(addr(SERVER)).unwrap(), None);
    let server = WgNet::start_with_underlay(configs.server.clone(), server_path).unwrap();
    Pair { client, server, server_v4: configs.server_v4, server_v6: configs.server_v6 }
}

/// Send `TOTAL` bytes from `from` to `to`, verify them, and report progress.
async fn bulk(mut from: WgStream, mut to: WgStream, progress: watch::Sender<usize>) {
    let data = payload();
    let write = async {
        from.write_all(&data).await.unwrap();
        from.shutdown().await.unwrap();
    };
    let read = async {
        let mut received = vec![0u8; TOTAL];
        let mut offset = 0;
        while offset < TOTAL {
            let count = to.read(&mut received[offset..]).await.unwrap();
            assert!(count > 0, "transfer ended at {offset} of {TOTAL}");
            offset += count;
            progress.send_replace(offset);
        }
        assert!(received == data, "transfer arrived damaged");
    };
    tokio::join!(write, read);
}

/// Move `TOTAL` bytes over a fresh tunnel on `sim`, to the server (upload,
/// inner IPv4) or from it (download, inner IPv6). Returns the bytes
/// delivered and the time taken, or `None` past `LIMIT`.
async fn transfer(sim: &SimNet, upload: bool) -> (usize, Option<Duration>) {
    let pair = pair(sim);
    let started = Instant::now();
    let mut listener = pair.server.listen(4200).await.unwrap();
    let target = if upload { pair.server_v4 } else { pair.server_v6 };
    let dialed = pair.client.connect(SocketAddr::new(target, 4200)).await.unwrap();
    let accepted = listener.accept().await.unwrap();
    let (from, to) = if upload { (dialed, accepted) } else { (accepted, dialed) };
    let (progress, seen) = watch::channel(0);
    let done = tokio::time::timeout(LIMIT, bulk(from, to, progress)).await.is_ok();
    let elapsed = done.then(|| started.elapsed());
    let delivered = *seen.borrow();
    pair.client.shutdown().await;
    pair.server.shutdown().await;
    (delivered, elapsed)
}

fn link(max_datagram: usize) -> LinkProfile {
    LinkProfile { latency: ONE_WAY, max_datagram, ..LinkProfile::default() }
}

/// The same transfer over a full 1500 byte path and over a 1400 byte one.
/// The small path must deliver everything, and soon: it pays two
/// retransmission timeouts and a fresh slow start, so it gets twice the full
/// path's time plus 2 s. Without fallback it delivers nothing.
async fn completes_over_a_small_path(upload: bool) {
    let full = SimNet::new();
    full.set_link(addr(CLIENT), addr(SERVER), link(0));
    let (_, full_time) = transfer(&full, upload).await;
    let full_time = full_time.expect("transfer over the full path finished");

    let small = SimNet::new();
    small.set_link(addr(CLIENT), addr(SERVER), link(MAX_DATAGRAM));
    let (delivered, small_time) = transfer(&small, upload).await;
    let direction = if upload { "upload" } else { "download" };
    eprintln!(
        "{direction} of {TOTAL} B at tunnel MTU {TUNNEL_MTU}: 1500 B path {full_time:?}; \
         {PATH_MTU} B path {small_time:?}, {delivered} B delivered, {} datagrams dropped",
        small.dropped()
    );
    let small_time = small_time.unwrap_or_else(|| {
        panic!(
            "{direction} stalled over a {PATH_MTU} B path: {delivered} of {TOTAL} B in {LIMIT:?}"
        )
    });
    assert!(
        small_time <= full_time * 2 + Duration::from_secs(2),
        "{direction} over a {PATH_MTU} B path took {small_time:?}, against {full_time:?}"
    );
}

#[tokio::test(start_paused = true)]
async fn an_upload_completes_over_a_path_smaller_than_the_tunnel_mtu() {
    completes_over_a_small_path(true).await;
}

#[tokio::test(start_paused = true)]
async fn a_download_completes_over_a_path_smaller_than_the_tunnel_mtu() {
    completes_over_a_small_path(false).await;
}
