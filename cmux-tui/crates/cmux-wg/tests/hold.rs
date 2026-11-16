//! `WgNet::hold`: a tunnel whose peer went silent on purpose (a phone the OS
//! suspends in the background) keeps its connections for the hold, sends the
//! peer nothing meanwhile, and works as before once released. Paused clock:
//! durations are simulated.

use std::net::SocketAddr;
use std::time::Duration;

use cmux_wg::testing::config_pair;
use cmux_wg::testing::sim::{LinkProfile, SimNet};
use cmux_wg::{SocketPath, WgNet, WgStream};
use tokio::io::{AsyncReadExt, AsyncWriteExt};

const PHONE: &str = "192.0.2.100:51820";
const MAC: &str = "192.0.2.101:51820";
/// Not the link port: these connections have the 60 s user timeout.
const PORT: u16 = 7420;

fn addr(text: &str) -> SocketAddr {
    text.parse().expect("literal address")
}

fn link(cut: bool) -> LinkProfile {
    LinkProfile { latency: Duration::from_millis(10), cut, ..LinkProfile::default() }
}

struct Pair {
    sim: SimNet,
    phone: WgNet,
    mac: WgNet,
    dialed: WgStream,
    accepted: WgStream,
}

/// A phone and a Mac with one exchanged connection; both send WireGuard
/// keepalives every 10 s, as a phone link's tunnel does.
async fn pair() -> Pair {
    let sim = SimNet::new();
    sim.set_link(addr(PHONE), addr(MAC), link(false));
    let mut configs = config_pair(addr(MAC));
    configs.client.persistent_keepalive = Some(10);
    configs.server.persistent_keepalive = Some(10);
    let phone_path = SocketPath::new(sim.bind(addr(PHONE)).unwrap(), Some(addr(MAC)));
    let mac_path = SocketPath::new(sim.bind(addr(MAC)).unwrap(), None);
    let phone = WgNet::start_with_underlay(configs.client, phone_path).unwrap();
    let mac = WgNet::start_with_underlay(configs.server, mac_path).unwrap();
    let mut listener = mac.listen(PORT).await.unwrap();
    let mut dialed = phone.connect(SocketAddr::new(configs.server_v4, PORT)).await.unwrap();
    let mut accepted = listener.accept().await.unwrap();
    dialed.write_all(b"hi").await.unwrap();
    let mut hi = [0u8; 2];
    accepted.read_exact(&mut hi).await.unwrap();
    Pair { sim, phone, mac, dialed, accepted }
}

/// Whether the connection still carries a round trip.
async fn alive(dialed: &mut WgStream, accepted: &mut WgStream) -> bool {
    let exchange = async {
        dialed.write_all(b"ping").await?;
        let mut ping = [0u8; 4];
        accepted.read_exact(&mut ping).await?;
        accepted.write_all(b"pong").await?;
        let mut pong = [0u8; 4];
        dialed.read_exact(&mut pong).await?;
        Ok::<_, std::io::Error>(&ping == b"ping" && &pong == b"pong")
    };
    matches!(tokio::time::timeout(Duration::from_secs(10), exchange).await, Ok(Ok(true)))
}

#[tokio::test(start_paused = true)]
async fn a_held_connection_survives_five_silent_minutes_and_works_after_release() {
    let mut pair = pair().await;
    pair.mac.hold(Some(Duration::from_secs(10 * 60))).await.unwrap();
    pair.phone.hold(Some(Duration::from_secs(10 * 60))).await.unwrap();
    pair.sim.set_link(addr(PHONE), addr(MAC), link(true));
    tokio::time::sleep(Duration::from_secs(5 * 60)).await;
    pair.sim.set_link(addr(PHONE), addr(MAC), link(false));
    // The phone comes back: a rebind reasserts the session (a new handshake,
    // the old session is past 120 s), then its first data goes out.
    pair.phone.refresh().await.unwrap();
    assert!(alive(&mut pair.dialed, &mut pair.accepted).await, "the held connection ended");
    pair.phone.hold(None).await.unwrap();
    pair.mac.hold(None).await.unwrap();
    // Released: the usual timeout and keepalive are back, and still alive.
    tokio::time::sleep(Duration::from_secs(30)).await;
    assert!(alive(&mut pair.dialed, &mut pair.accepted).await, "the released connection ended");
    pair.phone.shutdown().await;
    pair.mac.shutdown().await;
}

#[tokio::test(start_paused = true)]
async fn an_unheld_connection_ends_within_two_silent_minutes() {
    let mut pair = pair().await;
    pair.sim.set_link(addr(PHONE), addr(MAC), link(true));
    tokio::time::sleep(Duration::from_secs(2 * 60)).await;
    pair.sim.set_link(addr(PHONE), addr(MAC), link(false));
    pair.phone.refresh().await.unwrap();
    assert!(
        !alive(&mut pair.dialed, &mut pair.accepted).await,
        "an unheld connection outlived 60 s"
    );
    pair.phone.shutdown().await;
    pair.mac.shutdown().await;
}

#[tokio::test(start_paused = true)]
async fn a_held_connection_ends_after_its_hold() {
    let mut pair = pair().await;
    pair.mac.hold(Some(Duration::from_secs(2 * 60))).await.unwrap();
    pair.phone.hold(Some(Duration::from_secs(2 * 60))).await.unwrap();
    pair.sim.set_link(addr(PHONE), addr(MAC), link(true));
    tokio::time::sleep(Duration::from_secs(3 * 60)).await;
    pair.sim.set_link(addr(PHONE), addr(MAC), link(false));
    pair.phone.refresh().await.unwrap();
    assert!(
        !alive(&mut pair.dialed, &mut pair.accepted).await,
        "a held connection outlived its hold"
    );
    pair.phone.shutdown().await;
    pair.mac.shutdown().await;
}

/// The cost bound: a Mac holding a suspended phone's tunnel sends it nothing
/// at all, no TCP keepalive probe and no WireGuard keepalive. Unheld, the same
/// silence draws both (about 13 datagrams in the first 35 s on the 10 s and
/// 15 s periods).
#[tokio::test(start_paused = true)]
async fn a_held_tunnel_sends_its_silent_peer_nothing() {
    let pair = pair().await;
    // Let the exchange's own tail (ACKs, a passive keepalive) settle first.
    tokio::time::sleep(Duration::from_secs(1)).await;
    pair.mac.hold(Some(Duration::from_secs(10 * 60))).await.unwrap();
    pair.sim.set_link(addr(PHONE), addr(MAC), link(true));
    let before = pair.sim.sent_from(addr(MAC));
    tokio::time::sleep(Duration::from_secs(5 * 60)).await;
    let held = pair.sim.sent_from(addr(MAC)) - before;
    assert_eq!(held, 0, "a held Mac sent its suspended phone {held} datagrams in 5 minutes");

    pair.mac.hold(None).await.unwrap();
    let before = pair.sim.sent_from(addr(MAC));
    tokio::time::sleep(Duration::from_secs(35)).await;
    let unheld = pair.sim.sent_from(addr(MAC)) - before;
    assert!(unheld > 0, "an unheld Mac sent nothing in 35 s: the comparison proves nothing");
    pair.phone.shutdown().await;
    pair.mac.shutdown().await;
}

/// A connection idle through the whole hold (a link's input lane with no
/// keystroke yet) last heard its peer minutes ago. Releasing the hold must
/// not put its 60 s user timeout back at once, or it aborts at the next
/// poll and takes the link with it; the release probes it first.
#[tokio::test(start_paused = true)]
async fn an_idle_connection_survives_the_release() {
    let mut pair = pair().await;
    let server = SocketAddr::new(pair.accepted.local_addr().ip(), PORT + 1);
    let mut lane_listener = pair.mac.listen(PORT + 1).await.unwrap();
    let mut lane = pair.phone.connect(server).await.unwrap();
    let mut lane_accepted = lane_listener.accept().await.unwrap();
    pair.mac.hold(Some(Duration::from_secs(10 * 60))).await.unwrap();
    pair.phone.hold(Some(Duration::from_secs(10 * 60))).await.unwrap();
    pair.sim.set_link(addr(PHONE), addr(MAC), link(true));
    tokio::time::sleep(Duration::from_secs(5 * 60)).await;
    pair.sim.set_link(addr(PHONE), addr(MAC), link(false));
    pair.phone.refresh().await.unwrap();
    // The main connection carries the resume; then both ends release.
    assert!(alive(&mut pair.dialed, &mut pair.accepted).await, "the main connection ended");
    pair.mac.hold(None).await.unwrap();
    pair.phone.hold(None).await.unwrap();
    tokio::time::sleep(Duration::from_secs(1)).await;
    assert!(alive(&mut lane, &mut lane_accepted).await, "the idle connection ended at the release");
    // Past the grace too: the release's probe made the peer recent.
    tokio::time::sleep(Duration::from_secs(45)).await;
    assert!(
        alive(&mut lane, &mut lane_accepted).await,
        "the idle connection ended after the grace"
    );
    pair.phone.shutdown().await;
    pair.mac.shutdown().await;
}
