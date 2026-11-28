//! After a network change or a wake from sleep the session must be usable
//! at once. Measured on a real tunnel, a hub stopped for 190 s (past the
//! 180 s session lifetime) needed 5.15 s for its next connection: the first
//! handshake initiation was lost and nothing was sent again until boringtun's
//! 5 s retry. A rebind or refresh must start a fresh handshake immediately
//! when the session is not usable, instead of waiting for that retry.

use std::net::SocketAddr;
use std::time::Duration;

use cmux_wg::testing::config_pair;
use cmux_wg::testing::sim::{LinkProfile, SimNet};
use cmux_wg::{SocketPath, WgNet};

const CLIENT: &str = "192.0.2.30:51820";
const MOVED: &str = "192.0.2.31:51820";
const SERVER: &str = "192.0.2.40:51820";
/// Well under boringtun's 5 s handshake retry.
const AT_ONCE: Duration = Duration::from_secs(2);

fn addr(text: &str) -> SocketAddr {
    text.parse().expect("literal address")
}

/// A client whose first handshake initiation is lost on a cut link.
async fn client_with_a_lost_handshake(sim: &SimNet) -> (WgNet, WgNet) {
    let cut = LinkProfile { cut: true, ..LinkProfile::default() };
    sim.set_link(addr(CLIENT), addr(SERVER), cut);
    let configs = config_pair(addr(SERVER));
    let client_path = SocketPath::new(sim.bind(addr(CLIENT)).unwrap(), Some(addr(SERVER)));
    let server_path = SocketPath::new(sim.bind(addr(SERVER)).unwrap(), None);
    let client = WgNet::start_with_underlay(configs.client, client_path).unwrap();
    let server = WgNet::start_with_underlay(configs.server, server_path).unwrap();
    sim.wait_dropped(1).await;
    (client, server)
}

#[tokio::test]
async fn a_rebind_restarts_a_lost_handshake_at_once() {
    let sim = SimNet::new();
    let (client, server) = client_with_a_lost_handshake(&sim).await;
    let moved = SocketPath::new(sim.bind(addr(MOVED)).unwrap(), Some(addr(SERVER)));
    client.rebind(moved).await.unwrap();
    client.wait_for_handshake(AT_ONCE).await.expect("handshake right after the rebind");
    client.shutdown().await;
    server.shutdown().await;
}

#[tokio::test]
async fn a_refresh_restarts_a_lost_handshake_at_once() {
    let sim = SimNet::new();
    let (client, server) = client_with_a_lost_handshake(&sim).await;
    sim.set_link(addr(CLIENT), addr(SERVER), LinkProfile::default());
    client.refresh().await.unwrap();
    client.wait_for_handshake(AT_ONCE).await.expect("handshake right after the refresh");
    client.shutdown().await;
    server.shutdown().await;
}
