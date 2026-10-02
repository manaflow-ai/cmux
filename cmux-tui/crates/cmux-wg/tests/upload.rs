//! Bulk upload through the tunnel (client to server). Measured on a real
//! Freestyle tunnel, uploads through cmux-wg collapsed after about 256 KiB
//! while downloads ran at 228 Mbit/s: smoltcp sent its whole window at once,
//! and the driver dropped every datagram past a 64-entry queue whenever the
//! UDP socket was unwritable. These tests reproduce both halves on a
//! simulated network.

use std::net::SocketAddr;
use std::time::Duration;

use cmux_wg::testing::config_pair;
use cmux_wg::testing::sim::{LinkProfile, SimNet, SimSocket, SocketProfile};
use cmux_wg::{SocketPath, WgNet};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::time::Instant;

const CLIENT: &str = "192.0.2.10:51820";
const SERVER: &str = "192.0.2.20:51820";
const TOTAL: usize = 4 * 1024 * 1024;
/// TCP payload per segment at the tunnel MTU of 1200 over IPv4.
const MSS: usize = 1200 - 20 - 20;

fn addr(text: &str) -> SocketAddr {
    text.parse().expect("literal address")
}

fn payload() -> Vec<u8> {
    (0..TOTAL).map(|index| (index.wrapping_mul(2_654_435_761) >> 13) as u8).collect()
}

/// Upload `TOTAL` bytes from a client on `client_socket`; returns how long
/// it took. Panics if the bytes differ or the upload misses `limit`.
async fn upload(sim: &SimNet, client_socket: SimSocket, limit: Duration) -> Duration {
    let configs = config_pair(addr(SERVER));
    let client = WgNet::start_with_underlay(
        configs.client.clone(),
        SocketPath::new(client_socket, Some(addr(SERVER))),
    )
    .unwrap();
    let server_path = SocketPath::new(sim.bind(addr(SERVER)).unwrap(), None);
    let server = WgNet::start_with_underlay(configs.server.clone(), server_path).unwrap();
    let mut listener = server.listen(4100).await.unwrap();
    let data = payload();

    let started = Instant::now();
    let transfer = async {
        let mut stream = client.connect(SocketAddr::new(configs.server_v4, 4100)).await.unwrap();
        let mut accepted = listener.accept().await.unwrap();
        let write = async {
            stream.write_all(&data).await.unwrap();
            stream.shutdown().await.unwrap();
        };
        let read = async {
            let mut received = Vec::with_capacity(TOTAL);
            accepted.read_to_end(&mut received).await.unwrap();
            received
        };
        let ((), received) = tokio::join!(write, read);
        assert!(received == data, "upload arrived damaged ({} of {TOTAL} bytes)", received.len());
    };
    tokio::time::timeout(limit, transfer)
        .await
        .unwrap_or_else(|_| panic!("4 MiB upload did not finish within {limit:?}"));
    let elapsed = started.elapsed();
    client.shutdown().await;
    server.shutdown().await;
    elapsed
}

/// The client's socket accepts 16 datagrams and drains 20,000 a second
/// (about 190 Mbit/s); the link has no other limit. Every segment the
/// client's TCP emits must leave once: a datagram dropped inside the client
/// costs a retransmission that never had to happen.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn an_upload_through_a_full_socket_loses_nothing() {
    let sim = SimNet::new();
    let latency = LinkProfile { latency: Duration::from_millis(5), ..LinkProfile::default() };
    sim.set_link(addr(CLIENT), addr(SERVER), latency);
    let socket =
        sim.bind_with(addr(CLIENT), SocketProfile { send_buffer: 16, rate_pps: 20_000 }).unwrap();
    let elapsed = upload(&sim, socket, Duration::from_secs(20)).await;

    let segments = TOTAL.div_ceil(MSS) as u64;
    let sent = sim.sent_from(addr(CLIENT));
    eprintln!("full socket: {elapsed:?}, {sent} datagrams for {segments} segments");
    assert!(
        sent <= segments + segments / 50 + 64,
        "the client sent {sent} datagrams for {segments} segments: it dropped its own"
    );
}

/// A 20,000 datagram/s bottleneck with a 64-datagram drop-tail queue and a
/// 20 ms round trip, like a router on the way to a cloud region. 4 MiB needs
/// 0.2 s at that rate; a sender that bursts its whole window into the queue
/// loses most of it every round trip and stalls on retransmission timeouts.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn an_upload_through_a_bottleneck_completes() {
    let sim = SimNet::new();
    let bottleneck = LinkProfile {
        latency: Duration::from_millis(10),
        rate_pps: 20_000,
        queue: 64,
        ..LinkProfile::default()
    };
    sim.set_link(addr(CLIENT), addr(SERVER), bottleneck);
    let socket = sim.bind(addr(CLIENT)).unwrap();
    let elapsed = upload(&sim, socket, Duration::from_secs(15)).await;
    eprintln!("bottleneck: {elapsed:?}, {} dropped at the queue", sim.dropped());
}
