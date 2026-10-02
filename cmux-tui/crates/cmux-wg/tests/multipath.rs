//! One WireGuard session moves between paths without dropping its TCP
//! streams (plans/cmux-next/transport.md sections 0.2 and 4).
//!
//! Two in-process endpoints share a simulated network with two links: a
//! "relay" link with added latency and a "direct" link. The test drives each
//! side's path selector the way probe answers would, and moves one TCP
//! stream's bytes through every change. The writer is gated by the harness,
//! so every change happens while data is in flight and before the transfer
//! ends; nothing waits on a timer.

use std::net::SocketAddr;
use std::time::Duration;

use cmux_transport::{PathId, PathKind, ProbeOutcome, SelectorConfig};
use cmux_wg::testing::sim::{LinkProfile, SimNet};
use cmux_wg::testing::{ConfigPair, config_pair};
use cmux_wg::{Multipath, MultipathControl, SocketPath, Underlay, WgConfig, WgNet, WgStream};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::sync::watch;

const TIMEOUT: Duration = Duration::from_secs(60);
const MIB: u64 = 1024 * 1024;
const TOTAL: u64 = 8 * MIB;
const LINK_PORT: u16 = 4100;
const RELAY_LATENCY: Duration = Duration::from_millis(8);
const DIRECT_LATENCY: Duration = Duration::from_millis(1);

async fn within<T>(future: impl Future<Output = T>) -> T {
    tokio::time::timeout(TIMEOUT, future).await.expect("timed out")
}

fn addr(text: &str) -> SocketAddr {
    text.parse().expect("literal address")
}

/// Byte `index` of the transfer: a hash of the 8-byte block it falls in, so
/// a duplicated, dropped or reordered segment shows up at its offset.
fn byte_at(index: u64) -> u8 {
    let mut x = (index / 8).wrapping_add(0x9E37_79B9_7F4A_7C15);
    x = (x ^ (x >> 30)).wrapping_mul(0xBF58_476D_1CE4_E5B9);
    x = (x ^ (x >> 27)).wrapping_mul(0x94D0_49BB_1331_11EB);
    x ^= x >> 31;
    (x >> ((index % 8) * 8)) as u8
}

fn fnv1a(hash: u64, bytes: &[u8]) -> u64 {
    bytes.iter().fold(hash, |hash, byte| (hash ^ u64::from(*byte)).wrapping_mul(0x100_0000_01B3))
}
const FNV_OFFSET: u64 = 0xCBF2_9CE4_8422_2325;

/// One endpoint: a tunnel on a two-path underlay.
struct Side {
    net: WgNet,
    control: MultipathControl,
    relay: PathId,
    direct: PathId,
}

/// A two-path underlay: relay and direct sockets on `sim`, each aimed at the
/// peer's address on the same link.
fn two_paths(
    sim: &SimNet,
    relay: (SocketAddr, SocketAddr),
    direct: (SocketAddr, SocketAddr),
) -> (Multipath, MultipathControl, PathId, PathId) {
    let (underlay, control) = Multipath::new(SelectorConfig::default());
    let relay_socket = sim.bind(relay.0).expect("bind relay");
    let direct_socket = sim.bind(direct.0).expect("bind direct");
    let relay = control.add_path(PathKind::DoRelay, SocketPath::new(relay_socket, Some(relay.1)));
    let direct =
        control.add_path(PathKind::DirectLan, SocketPath::new(direct_socket, Some(direct.1)));
    (underlay, control, relay, direct)
}

fn side(
    sim: &SimNet,
    config: WgConfig,
    relay: (SocketAddr, SocketAddr),
    direct: (SocketAddr, SocketAddr),
) -> Side {
    let (underlay, control, relay, direct) = two_paths(sim, relay, direct);
    let net = WgNet::start_with_underlay(config, underlay).expect("start");
    Side { net, control, relay, direct }
}

fn answer(control: &MultipathControl, path: PathId, rtt: Duration) {
    let rtt_us = u64::try_from(rtt.as_micros()).unwrap();
    control.on_probe(path, ProbeOutcome::Answered { rtt_us }).expect("known path");
}

fn lose(control: &MultipathControl, path: PathId) {
    for _ in 0..SelectorConfig::default().dead_after_lost {
        control.on_probe(path, ProbeOutcome::Lost).expect("known path");
    }
}

fn received(control: &MultipathControl, path: PathId) -> u64 {
    control.path(path).expect("known path").received
}

/// Write `TOTAL` bytes, but never past what the harness allowed; then read
/// the receiver's digest and return (ours, theirs).
async fn write_gated(mut stream: WgStream, mut allowed: watch::Receiver<u64>) -> (u64, u64) {
    let mut written = 0u64;
    let mut digest = FNV_OFFSET;
    let mut chunk = Vec::with_capacity(64 * 1024);
    while written < TOTAL {
        let limit = *allowed.wait_for(|limit| *limit > written).await.expect("harness alive");
        let end = limit.min(TOTAL).min(written + 64 * 1024);
        chunk.clear();
        chunk.extend((written..end).map(byte_at));
        stream.write_all(&chunk).await.expect("write");
        digest = fnv1a(digest, &chunk);
        written = end;
    }
    let mut theirs = [0u8; 8];
    stream.read_exact(&mut theirs).await.expect("digest");
    (digest, u64::from_be_bytes(theirs))
}

/// Read `TOTAL` bytes, checking every byte at its offset and publishing
/// progress; then answer with the digest.
async fn read_verified(mut stream: WgStream, progress: watch::Sender<u64>) {
    let mut offset = 0u64;
    let mut digest = FNV_OFFSET;
    let mut buffer = vec![0u8; 64 * 1024];
    while offset < TOTAL {
        let count = stream.read(&mut buffer).await.expect("read");
        assert!(count > 0, "stream ended at {offset} of {TOTAL}");
        for (index, byte) in buffer[..count].iter().enumerate() {
            let at = offset + index as u64;
            assert_eq!(*byte, byte_at(at), "byte {at} differs");
        }
        digest = fnv1a(digest, &buffer[..count]);
        offset += count as u64;
        progress.send_replace(offset);
    }
    stream.write_all(&digest.to_be_bytes()).await.expect("digest");
    let mut end = [0u8; 1];
    let _ = stream.read(&mut end).await;
}

struct World {
    sim: SimNet,
    client: Side,
    server: Side,
    progress: watch::Receiver<u64>,
    allow: watch::Sender<u64>,
    transfer: tokio::task::JoinHandle<(u64, u64)>,
    reader: tokio::task::JoinHandle<()>,
}

const A_RELAY: &str = "198.51.100.1:40000";
const B_RELAY: &str = "198.51.100.2:40000";
const A_DIRECT: &str = "192.168.7.1:51820";
const B_DIRECT: &str = "192.168.7.2:51820";

/// Both sides up on the relay only, one stream open, nothing sent yet.
async fn world() -> World {
    let sim = SimNet::new();
    sim.set_link(addr(A_RELAY), addr(B_RELAY), LinkProfile { latency: RELAY_LATENCY, cut: false });
    sim.set_link(
        addr(A_DIRECT),
        addr(B_DIRECT),
        LinkProfile { latency: DIRECT_LATENCY, cut: false },
    );
    let ConfigPair { client, server, server_v6, .. } = config_pair(addr(B_RELAY));
    let client =
        side(&sim, client, (addr(A_RELAY), addr(B_RELAY)), (addr(A_DIRECT), addr(B_DIRECT)));
    let server =
        side(&sim, server, (addr(B_RELAY), addr(A_RELAY)), (addr(B_DIRECT), addr(A_DIRECT)));
    // The relay answers first, as it does on a dial; the direct path exists
    // but has not answered a probe yet.
    for side in [&client, &server] {
        answer(&side.control, side.relay, 2 * RELAY_LATENCY);
        assert_eq!(side.control.current(), Some(side.relay));
    }

    let mut listener = server.net.listen(LINK_PORT).await.expect("listen");
    let stream =
        within(client.net.connect(SocketAddr::new(server_v6, LINK_PORT))).await.expect("connect");
    let accepted = within(listener.accept()).await.expect("accepted");
    let (progress_tx, progress) = watch::channel(0);
    let (allow, allowed) = watch::channel(0);
    let reader = tokio::spawn(read_verified(accepted, progress_tx));
    let transfer = tokio::spawn(write_gated(stream, allowed));
    World { sim, client, server, progress, allow, transfer, reader }
}

impl World {
    /// Let the writer reach `allow` bytes, and wait until the reader has
    /// `reached` of them.
    async fn run_until(&mut self, allow: u64, reached: u64) {
        self.allow.send_replace(allow);
        within(self.progress.wait_for(|offset| *offset >= reached)).await.expect("reader alive");
    }

    async fn finish(self) {
        self.allow.send_replace(TOTAL);
        let (ours, theirs) = within(self.transfer).await.expect("writer");
        within(self.reader).await.expect("reader");
        assert_eq!(ours, theirs, "checksums differ");
        self.client.net.shutdown().await;
        self.server.net.shutdown().await;
    }

    /// (a) Probes answer on the direct path: both sides move there at once.
    async fn switch_to_direct(&mut self) {
        let before = received(&self.server.control, self.server.direct);
        for side in [&self.client, &self.server] {
            answer(&side.control, side.direct, 2 * DIRECT_LATENCY);
            assert_eq!(side.control.current(), Some(side.direct), "direct beats relay");
        }
        let progress = *self.progress.borrow();
        self.run_until(progress + 2 * MIB, progress + MIB).await;
        assert!(
            received(&self.server.control, self.server.direct) > before + 100,
            "the stream's datagrams moved to the direct path"
        );
    }

    /// (b) The direct link goes dark. Its probes are lost, both selectors
    /// fall back to the relay, and the stream continues there.
    async fn cut_direct(&mut self, a_direct: SocketAddr) {
        self.sim.set_link(a_direct, addr(B_DIRECT), LinkProfile { latency: DIRECT_LATENCY, cut: true });
        for side in [&self.client, &self.server] {
            lose(&side.control, side.direct);
            assert_eq!(side.control.current(), Some(side.relay), "fell back to the relay");
        }
        let before = received(&self.server.control, self.server.relay);
        let progress = *self.progress.borrow();
        self.run_until(progress + 2 * MIB, progress + MIB).await;
        assert!(
            received(&self.server.control, self.server.relay) > before + 100,
            "the stream's datagrams moved back to the relay"
        );
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn one_session_survives_a_path_switch_and_a_cut_path() {
    let mut world = world().await;
    world.run_until(2 * MIB, MIB).await;
    world.switch_to_direct().await;
    world.cut_direct(addr(A_DIRECT)).await;
    world.finish().await;
}

#[tokio::test]
async fn datagrams_go_on_every_path_until_one_answers() {
    let sim = SimNet::new();
    let (mut underlay, control, relay, direct) =
        two_paths(&sim, (addr(A_RELAY), addr(B_RELAY)), (addr(A_DIRECT), addr(B_DIRECT)));
    underlay.send(b"dial");
    assert_eq!(control.path(relay).unwrap().sent, 1);
    assert_eq!(control.path(direct).unwrap().sent, 1);

    answer(&control, relay, RELAY_LATENCY);
    underlay.send(b"on the relay");
    assert_eq!(control.path(relay).unwrap().sent, 2);
    assert_eq!(control.path(direct).unwrap().sent, 1, "only the current path carries it");

    answer(&control, direct, DIRECT_LATENCY);
    underlay.send(b"direct");
    assert_eq!(control.path(direct).unwrap().sent, 2);
    assert_eq!(control.path(relay).unwrap().sent, 2);

    lose(&control, direct);
    lose(&control, relay);
    assert_eq!(control.current(), None);
    underlay.send(b"every path again");
    assert_eq!(control.path(relay).unwrap().sent, 3);
    assert_eq!(control.path(direct).unwrap().sent, 3);
}
