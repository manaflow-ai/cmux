//! Bulk upload through the tunnel (client to server), on Tokio's paused
//! clock so every duration below is simulated time and deterministic.
//!
//! Measured on a real Freestyle tunnel, uploads through cmux-wg collapsed
//! after about 256 KiB while downloads ran at 228 Mbit/s: smoltcp sent its
//! whole window at once, and the driver dropped every datagram past a
//! 64-entry queue whenever the UDP socket was unwritable. These tests
//! reproduce both halves, the cost of window-sized bursts into a shallow
//! router queue, and the wait of a keystroke behind a bulk transfer.

use std::net::SocketAddr;
use std::time::Duration;

use cmux_wg::testing::sim::{LinkProfile, SimNet, SimSocket, SocketProfile};
use cmux_wg::testing::{ConfigPair, config_pair};
use cmux_wg::{SocketPath, WgNet, WgStream};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::sync::{oneshot, watch};
use tokio::time::Instant;

const CLIENT: &str = "192.0.2.10:51820";
const SERVER: &str = "192.0.2.20:51820";
const TOTAL: usize = 4 * 1024 * 1024;
/// TCP payload per segment at the tunnel MTU of 1200 over IPv4.
const MSS: usize = 1200 - 20 - 20;
/// 20,000 datagrams/s is about 190 Mbit/s of tunnel payload.
const RATE_PPS: u32 = 20_000;
const ONE_WAY: Duration = Duration::from_millis(10);
const LIMIT: Duration = Duration::from_secs(60);

fn addr(text: &str) -> SocketAddr {
    text.parse().expect("literal address")
}

fn payload() -> Vec<u8> {
    (0..TOTAL).map(|index| (index.wrapping_mul(2_654_435_761) >> 13) as u8).collect()
}

fn bottleneck(queue: u32) -> LinkProfile {
    LinkProfile { latency: ONE_WAY, rate_pps: RATE_PPS, queue, ..LinkProfile::default() }
}

struct Pair {
    client: WgNet,
    server: WgNet,
    configs: ConfigPair,
}

fn pair(sim: &SimNet, client_socket: SimSocket) -> Pair {
    let configs = config_pair(addr(SERVER));
    let client_path = SocketPath::new(client_socket, Some(addr(SERVER)));
    let client = WgNet::start_with_underlay(configs.client.clone(), client_path).unwrap();
    let server_path = SocketPath::new(sim.bind(addr(SERVER)).unwrap(), None);
    let server = WgNet::start_with_underlay(configs.server.clone(), server_path).unwrap();
    Pair { client, server, configs }
}

/// One connection from client to server on `port`.
async fn connect(pair: &Pair, port: u16) -> (WgStream, WgStream) {
    let mut listener = pair.server.listen(port).await.unwrap();
    let target = SocketAddr::new(pair.configs.server_v4, port);
    let dialed = pair.client.connect(target).await.unwrap();
    let accepted = listener.accept().await.unwrap();
    (dialed, accepted)
}

/// Upload `TOTAL` bytes on one connection, verify them, and report progress.
async fn bulk(mut dialed: WgStream, mut accepted: WgStream, progress: watch::Sender<usize>) {
    let data = payload();
    let write = async {
        dialed.write_all(&data).await.unwrap();
        dialed.shutdown().await.unwrap();
    };
    let read = async {
        let mut received = vec![0u8; TOTAL];
        let mut offset = 0;
        while offset < TOTAL {
            let count = accepted.read(&mut received[offset..]).await.unwrap();
            assert!(count > 0, "upload ended at {offset} of {TOTAL}");
            offset += count;
            progress.send_replace(offset);
        }
        assert!(received == data, "upload arrived damaged");
    };
    tokio::join!(write, read);
}

/// The time to upload `TOTAL` bytes from a client on `client_socket`.
async fn upload(sim: &SimNet, client_socket: SimSocket) -> Duration {
    let pair = pair(sim, client_socket);
    let started = Instant::now();
    let (dialed, accepted) = connect(&pair, 4100).await;
    let (progress, _) = watch::channel(0);
    tokio::time::timeout(LIMIT, bulk(dialed, accepted, progress)).await.expect("upload finished");
    let elapsed = started.elapsed();
    pair.client.shutdown().await;
    pair.server.shutdown().await;
    elapsed
}

/// The client's socket accepts 16 datagrams and drains 20,000 a second; the
/// link has no other limit. Every segment the client's TCP emits must leave
/// once: a datagram dropped inside the client costs a retransmission that
/// never had to happen.
#[tokio::test(start_paused = true)]
async fn an_upload_through_a_full_socket_loses_nothing() {
    let sim = SimNet::new();
    let latency = LinkProfile { latency: Duration::from_millis(5), ..LinkProfile::default() };
    sim.set_link(addr(CLIENT), addr(SERVER), latency);
    let profile = SocketProfile { send_buffer: 16, rate_pps: RATE_PPS };
    let elapsed = upload(&sim, sim.bind_with(addr(CLIENT), profile).unwrap()).await;

    let segments = TOTAL.div_ceil(MSS) as u64;
    let sent = sim.sent_from(addr(CLIENT));
    eprintln!("full socket: {elapsed:?}, {sent} datagrams for {segments} segments");
    assert!(
        sent <= segments + segments / 50 + 64,
        "the client sent {sent} datagrams for {segments} segments: it dropped its own"
    );
}

/// A 20,000 datagram/s bottleneck with a 20 ms round trip. Its queue holds
/// 400 datagrams (one bandwidth-delay product) or 64 (a shallow router
/// buffer). A sender that bursts whole windows into the shallow queue loses
/// segments every round trip, and smoltcp recovers slowly (go-back-N, no
/// SACK, 1 s minimum RTO). Paced, the shallow queue must cost little more
/// than the deep one.
#[tokio::test(start_paused = true)]
async fn an_upload_through_a_shallow_bottleneck_is_paced() {
    let deep = SimNet::new();
    deep.set_link(addr(CLIENT), addr(SERVER), bottleneck(400));
    let deep_time = upload(&deep, deep.bind(addr(CLIENT)).unwrap()).await;

    let shallow = SimNet::new();
    shallow.set_link(addr(CLIENT), addr(SERVER), bottleneck(64));
    let shallow_time = upload(&shallow, shallow.bind(addr(CLIENT)).unwrap()).await;
    eprintln!(
        "bottleneck: deep queue {deep_time:?} ({} drops), shallow queue {shallow_time:?} ({} drops)",
        deep.dropped(),
        shallow.dropped()
    );
    assert!(
        shallow_time <= deep_time + deep_time / 2,
        "shallow queue {shallow_time:?} against {deep_time:?} with a deep one"
    );
}

/// An interactive connection shares the session with a bulk upload through
/// the shallow bottleneck. A keystroke written mid-upload must reach the
/// peer within one round trip plus a little queueing: it may not wait
/// behind the bulk connection's queued window.
#[tokio::test(start_paused = true)]
async fn a_keystroke_does_not_wait_behind_a_bulk_upload() {
    let sim = SimNet::new();
    sim.set_link(addr(CLIENT), addr(SERVER), bottleneck(64));
    let pair = pair(&sim, sim.bind(addr(CLIENT)).unwrap());
    let (mut keys, mut echo) = connect(&pair, 4101).await;
    let (dialed, accepted) = connect(&pair, 4100).await;
    let (progress, mut seen) = watch::channel(0);
    let upload = tokio::spawn(bulk(dialed, accepted, progress));

    let (arrived_tx, arrived) = oneshot::channel();
    tokio::spawn(async move {
        let mut key = [0u8; 1];
        echo.read_exact(&mut key).await.unwrap();
        let _ = arrived_tx.send(Instant::now());
    });
    seen.wait_for(|offset| *offset >= TOTAL / 4).await.unwrap();
    let typed = Instant::now();
    keys.write_all(b"k").await.unwrap();
    let latency = arrived.await.unwrap() - typed;
    eprintln!("keystroke during upload: {latency:?} (one-way link latency {ONE_WAY:?})");
    assert!(*seen.borrow() < TOTAL, "the keystroke went out mid-upload");
    assert!(latency <= 2 * ONE_WAY + Duration::from_millis(5), "keystroke took {latency:?}");

    tokio::time::timeout(LIMIT, upload).await.expect("upload finished").unwrap();
    pair.client.shutdown().await;
    pair.server.shutdown().await;
}
