//! TCP user timeouts (transport.md section 12a): a link connection (overlay
//! port 4100) survives up to 10 minutes of a silent peer, for example a
//! phone in the background; every other connection keeps the 60 s timeout.
//! Keepalive probes stay at 15 s. Paused clock: durations are simulated.

use std::net::SocketAddr;
use std::time::Duration;

use cmux_wg::testing::config_pair;
use cmux_wg::testing::sim::{LinkProfile, SimNet};
use cmux_wg::{SocketPath, WgNet, WgStream};
use tokio::io::{AsyncReadExt, AsyncWriteExt};

const CLIENT: &str = "192.0.2.90:51820";
const SERVER: &str = "192.0.2.91:51820";
const LINK_PORT: u16 = 4100;
const OTHER_PORT: u16 = 7000;

fn addr(text: &str) -> SocketAddr {
    text.parse().expect("literal address")
}

fn link(cut: bool) -> LinkProfile {
    LinkProfile { latency: Duration::from_millis(10), cut, ..LinkProfile::default() }
}

/// A connected pair with one exchanged connection on `port`; then the peer
/// goes silent (the link drops everything) for `silence`.
async fn silent_for(port: u16, silence: Duration) -> (WgNet, WgNet, WgStream, WgStream) {
    let sim = SimNet::new();
    sim.set_link(addr(CLIENT), addr(SERVER), link(false));
    let configs = config_pair(addr(SERVER));
    let client_path = SocketPath::new(sim.bind(addr(CLIENT)).unwrap(), Some(addr(SERVER)));
    let server_path = SocketPath::new(sim.bind(addr(SERVER)).unwrap(), None);
    let client = WgNet::start_with_underlay(configs.client, client_path).unwrap();
    let server = WgNet::start_with_underlay(configs.server, server_path).unwrap();
    let mut listener = server.listen(port).await.unwrap();
    let mut dialed = client.connect(SocketAddr::new(configs.server_v4, port)).await.unwrap();
    let mut accepted = listener.accept().await.unwrap();
    dialed.write_all(b"hi").await.unwrap();
    let mut hi = [0u8; 2];
    accepted.read_exact(&mut hi).await.unwrap();

    sim.set_link(addr(CLIENT), addr(SERVER), link(true));
    tokio::time::sleep(silence).await;
    sim.set_link(addr(CLIENT), addr(SERVER), link(false));
    (client, server, dialed, accepted)
}

/// Whether the connection still carries a round trip.
async fn alive(dialed: &mut WgStream, accepted: &mut WgStream) -> bool {
    let exchange = async {
        dialed.write_all(b"ping").await?;
        let mut ping = [0u8; 4];
        accepted.read_exact(&mut ping).await?;
        Ok::<_, std::io::Error>(&ping == b"ping")
    };
    matches!(tokio::time::timeout(Duration::from_secs(10), exchange).await, Ok(Ok(true)))
}

#[tokio::test(start_paused = true)]
async fn a_link_connection_survives_five_silent_minutes() {
    let (client, server, mut dialed, mut accepted) =
        silent_for(LINK_PORT, Duration::from_secs(5 * 60)).await;
    assert!(alive(&mut dialed, &mut accepted).await, "the link connection ended");
    client.shutdown().await;
    server.shutdown().await;
}

#[tokio::test(start_paused = true)]
async fn a_link_connection_ends_after_eleven_silent_minutes() {
    let (client, server, mut dialed, mut accepted) =
        silent_for(LINK_PORT, Duration::from_secs(11 * 60)).await;
    assert!(!alive(&mut dialed, &mut accepted).await, "the link connection outlived 10 minutes");
    client.shutdown().await;
    server.shutdown().await;
}

#[tokio::test(start_paused = true)]
async fn another_connection_ends_after_two_silent_minutes() {
    let (client, server, mut dialed, mut accepted) =
        silent_for(OTHER_PORT, Duration::from_secs(2 * 60)).await;
    assert!(!alive(&mut dialed, &mut accepted).await, "a non-link connection outlived 60 s");
    client.shutdown().await;
    server.shutdown().await;
}
