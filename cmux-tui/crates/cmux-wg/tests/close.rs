//! A close must reach the peer even when the network drops it once.
//! Reported through the hub: a close was lost and the host kept the TCP
//! connection established until its keepalive gave up (15 s probes, 60 s
//! timeout). The link here drops everything for 300 ms around the close.

use std::net::SocketAddr;
use std::time::Duration;

use cmux_wg::testing::config_pair;
use cmux_wg::testing::sim::{LinkProfile, SimNet};
use cmux_wg::{SocketPath, WgNet, WgStream};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::time::Instant;

const CLIENT: &str = "192.0.2.50:51820";
const SERVER: &str = "192.0.2.60:51820";
const OUTAGE: Duration = Duration::from_millis(300);
/// A few retransmission timeouts (smoltcp's minimum is 1 s).
const NOTICED_WITHIN: Duration = Duration::from_secs(4);

fn addr(text: &str) -> SocketAddr {
    text.parse().expect("literal address")
}

fn link(cut: bool) -> LinkProfile {
    LinkProfile { latency: Duration::from_millis(10), cut, ..LinkProfile::default() }
}

/// A connected pair with one open connection, client to server.
async fn connected(sim: &SimNet) -> (WgNet, WgNet, WgStream, WgStream) {
    sim.set_link(addr(CLIENT), addr(SERVER), link(false));
    let configs = config_pair(addr(SERVER));
    let client_path = SocketPath::new(sim.bind(addr(CLIENT)).unwrap(), Some(addr(SERVER)));
    let server_path = SocketPath::new(sim.bind(addr(SERVER)).unwrap(), None);
    let client = WgNet::start_with_underlay(configs.client, client_path).unwrap();
    let server = WgNet::start_with_underlay(configs.server, server_path).unwrap();
    let mut listener = server.listen(4100).await.unwrap();
    let mut dialed = client.connect(SocketAddr::new(configs.server_v4, 4100)).await.unwrap();
    let mut accepted = listener.accept().await.unwrap();
    dialed.write_all(b"hello").await.unwrap();
    let mut hello = [0u8; 5];
    accepted.read_exact(&mut hello).await.unwrap();
    (client, server, dialed, accepted)
}

/// The time until `stream` sees its end (EOF or reset).
async fn time_to_end(stream: &mut WgStream, since: Instant) -> Duration {
    let mut byte = [0u8; 1];
    let end = tokio::time::timeout(Duration::from_secs(120), stream.read(&mut byte)).await;
    assert!(matches!(end, Ok(Ok(0) | Err(_))), "the stream did not end: {end:?}");
    since.elapsed()
}

async fn restore_after_outage(sim: &SimNet) {
    tokio::time::sleep(OUTAGE).await;
    sim.set_link(addr(CLIENT), addr(SERVER), link(false));
}

#[tokio::test(start_paused = true)]
async fn a_lost_fin_is_retransmitted() {
    let sim = SimNet::new();
    let (client, server, mut dialed, mut accepted) = connected(&sim).await;
    sim.set_link(addr(CLIENT), addr(SERVER), link(true));
    let closed = Instant::now();
    dialed.shutdown().await.unwrap();
    drop(dialed);
    restore_after_outage(&sim).await;
    let took = time_to_end(&mut accepted, closed).await;
    eprintln!("lost FIN: the peer saw EOF after {took:?}");
    assert!(took <= NOTICED_WITHIN, "EOF after {took:?}");
    client.shutdown().await;
    server.shutdown().await;
}

#[tokio::test(start_paused = true)]
async fn a_close_lost_at_tunnel_shutdown_still_ends_the_peer_connection() {
    let sim = SimNet::new();
    let (client, server, dialed, mut accepted) = connected(&sim).await;
    sim.set_link(addr(CLIENT), addr(SERVER), link(true));
    let closed = Instant::now();
    drop(dialed);
    let restored = tokio::spawn({
        let sim = sim.clone();
        async move { restore_after_outage(&sim).await }
    });
    client.shutdown().await;
    restored.await.unwrap();
    let took = time_to_end(&mut accepted, closed).await;
    eprintln!("close lost at tunnel shutdown: the peer saw the end after {took:?}");
    assert!(took <= NOTICED_WITHIN, "the peer saw the end after {took:?}");
    server.shutdown().await;
}
