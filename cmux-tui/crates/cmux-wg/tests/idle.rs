//! An idle tunnel costs no wakeups (plans/cmux-next/idle-wakeups.md), and
//! boringtun's timers still run while they can fire.

use std::net::SocketAddr;
use std::time::Duration;

use cmux_transport::{PathKind, SelectorConfig};
use cmux_wg::testing::sim::{LinkProfile, SimNet};
use cmux_wg::testing::{ConfigPair, config_pair};
use cmux_wg::{Multipath, ProbeConfig, SocketPath, WgNet};
use tokio::io::{AsyncReadExt, AsyncWriteExt};

const CLIENT: &str = "192.0.2.1:51820";
const SERVER: &str = "192.0.2.2:51820";

fn addr(text: &str) -> SocketAddr {
    text.parse().expect("literal address")
}

/// Client and server on one zero-latency simulated link.
fn pair(sim: &SimNet, keepalive: Option<u16>) -> (WgNet, WgNet, ConfigPair) {
    let mut configs = config_pair(addr(SERVER));
    configs.client.persistent_keepalive = keepalive;
    let client_path = SocketPath::new(sim.bind(addr(CLIENT)).unwrap(), Some(addr(SERVER)));
    let server_path = SocketPath::new(sim.bind(addr(SERVER)).unwrap(), None);
    let client = WgNet::start_with_underlay(configs.client.clone(), client_path).unwrap();
    let server = WgNet::start_with_underlay(configs.server.clone(), server_path).unwrap();
    (client, server, configs)
}

/// One TCP exchange through the tunnel, then both ends close.
async fn exchange(client: &WgNet, server: &WgNet, configs: &ConfigPair, port: u16) {
    let mut listener = server.listen(port).await.unwrap();
    let mut dialed = client.connect(SocketAddr::new(configs.server_v4, port)).await.unwrap();
    let mut accepted = listener.accept().await.unwrap();
    dialed.write_all(b"ping").await.unwrap();
    let mut ping = [0u8; 4];
    accepted.read_exact(&mut ping).await.unwrap();
    assert_eq!(&ping, b"ping");
    dialed.shutdown().await.unwrap();
    accepted.shutdown().await.unwrap();
    let mut end = [0u8; 1];
    assert_eq!(dialed.read(&mut end).await.unwrap(), 0);
    assert_eq!(accepted.read(&mut end).await.unwrap(), 0);
}

#[tokio::test(start_paused = true)]
async fn an_idle_tunnel_stops_waking() {
    let sim = SimNet::new();
    let (client, server, configs) = pair(&sim, None);
    exchange(&client, &server, &configs, 7).await;

    // Ten minutes: boringtun's active window, the TCP close (TIME_WAIT) and
    // the key-expiry sweep all end inside it.
    tokio::time::sleep(Duration::from_secs(600)).await;
    let (client_settled, server_settled) = (client.wakeups(), server.wakeups());
    assert!(client_settled < 300, "client woke {client_settled} times settling");
    assert!(server_settled < 300, "server woke {server_settled} times settling");

    tokio::time::sleep(Duration::from_secs(3600)).await;
    assert_eq!(client.wakeups(), client_settled, "an idle client must not wake");
    assert_eq!(server.wakeups(), server_settled, "an idle server must not wake");

    // The tunnel still works after the idle hour.
    exchange(&client, &server, &configs, 8).await;
    client.shutdown().await;
    server.shutdown().await;
}

#[tokio::test(start_paused = true)]
async fn a_persistent_keepalive_keeps_a_slow_tick() {
    let sim = SimNet::new();
    let (client, server, _configs) = pair(&sim, Some(25));
    client.wait_for_handshake(Duration::from_secs(5)).await.unwrap();
    tokio::time::sleep(Duration::from_secs(600)).await;
    let settled = client.wakeups();
    tokio::time::sleep(Duration::from_secs(60)).await;
    let ticks = client.wakeups() - settled;
    assert!((55..=65).contains(&ticks), "about one wakeup a second, got {ticks}");
    client.shutdown().await;
    server.shutdown().await;
}

/// Probes are not activity: two probing endpoints must not keep each other
/// awake once their traffic stops.
#[tokio::test(start_paused = true)]
async fn probing_paths_stop_when_traffic_stops() {
    let sim = SimNet::new();
    let mut configs = config_pair(addr(SERVER));
    configs.client.persistent_keepalive = None;
    let probes = ProbeConfig { current_interval: Duration::from_millis(100), ..Default::default() };
    let mut sides = Vec::new();
    for (config, local, remote, spare) in [
        (configs.client.clone(), CLIENT, SERVER, "192.0.2.3:51820"),
        (configs.server.clone(), SERVER, CLIENT, "192.0.2.4:51820"),
    ] {
        let (underlay, control) = Multipath::with_probes(SelectorConfig::default(), probes);
        let main = SocketPath::new(sim.bind(addr(local)).unwrap(), Some(addr(remote)));
        control.add_path(PathKind::DirectLan, main);
        // A second path whose peer never answers: it is probed and dies.
        let dark = SocketPath::new(sim.bind(addr(spare)).unwrap(), Some(addr("192.0.2.99:1")));
        control.add_path(PathKind::DoRelay, dark);
        sides.push(WgNet::start_with_underlay(config, underlay).unwrap());
    }
    let (client, server) = (&sides[0], &sides[1]);
    exchange(client, server, &configs, 9).await;
    tokio::time::sleep(Duration::from_secs(600)).await;
    let settled = (client.wakeups(), server.wakeups());
    tokio::time::sleep(Duration::from_secs(3600)).await;
    assert_eq!((client.wakeups(), server.wakeups()), settled, "probes kept the tunnel awake");
}

/// Real time: boringtun's own clock decides when a handshake is retried.
#[tokio::test]
async fn a_lost_handshake_is_retried() {
    let sim = SimNet::new();
    let cut = LinkProfile { latency: Duration::ZERO, cut: true, ..LinkProfile::default() };
    sim.set_link(addr(CLIENT), addr(SERVER), cut);
    let (client, server, _configs) = pair(&sim, None);
    sim.wait_dropped(1).await;
    sim.set_link(addr(CLIENT), addr(SERVER), LinkProfile::default());
    // REKEY_TIMEOUT is 5 s: the retry needs the timers to keep running
    // although nothing else happens on the tunnel.
    client.wait_for_handshake(Duration::from_secs(8)).await.unwrap();
    server.wait_for_handshake(Duration::from_secs(1)).await.unwrap();
    client.shutdown().await;
    server.shutdown().await;
}
