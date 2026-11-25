//! `WgNet::hold`: a tunnel whose peer went silent on purpose (a phone the OS
//! suspends in the background) keeps its connections for the hold, sends the
//! peer nothing meanwhile, and works as before once released. Paused clock:
//! durations are simulated.

use std::net::SocketAddr;
use std::time::Duration;

use cmux_wg::testing::config_pair;
use cmux_wg::testing::sim::{LinkProfile, SimNet};
use cmux_wg::{
    Multipath, MultipathControl, PathKind, ProbeConfig, SelectorConfig, SocketPath, WgNet, WgStream,
};
use tokio::io::{AsyncReadExt, AsyncWriteExt};

const PHONE: &str = "192.0.2.100:51820";
const MAC: &str = "192.0.2.101:51820";
/// Where the Mac moves to after a network change.
const MAC_MOVED: &str = "192.0.2.102:51820";
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
    /// The path selectors of a `probed_pair`, kept alive with the tunnels.
    _controls: Vec<MultipathControl>,
}

/// A phone and a Mac with one exchanged connection; both send WireGuard
/// keepalives every 10 s, as a phone link's tunnel does.
async fn pair() -> Pair {
    let sim = SimNet::new();
    let phone_path = SocketPath::new(sim.bind(addr(PHONE)).unwrap(), Some(addr(MAC)));
    let mac_path = SocketPath::new(sim.bind(addr(MAC)).unwrap(), None);
    connected(sim, phone_path, mac_path, Vec::new()).await
}

/// `pair`, with each side on a path selector that probes its path as a phone
/// link's does (`ProbeConfig::default()`: the current path every 5 s while
/// the session is active).
async fn probed_pair() -> Pair {
    let sim = SimNet::new();
    let mut controls = Vec::new();
    let mut probed = |local: &str, remote: &str| {
        let (underlay, control) =
            Multipath::with_probes(SelectorConfig::default(), ProbeConfig::default());
        let socket = sim.bind(addr(local)).unwrap();
        control.add_path(PathKind::DirectLan, SocketPath::new(socket, Some(addr(remote))));
        controls.push(control);
        underlay
    };
    let phone_path = probed(PHONE, MAC);
    let mac_path = probed(MAC, PHONE);
    connected(sim, phone_path, mac_path, controls).await
}

async fn connected(
    sim: SimNet,
    phone_path: impl cmux_wg::Underlay,
    mac_path: impl cmux_wg::Underlay,
    controls: Vec<MultipathControl>,
) -> Pair {
    sim.set_link(addr(PHONE), addr(MAC), link(false));
    let mut configs = config_pair(addr(MAC));
    configs.client.persistent_keepalive = Some(10);
    configs.server.persistent_keepalive = Some(10);
    let phone = WgNet::start_with_underlay(configs.client, phone_path).unwrap();
    let mac = WgNet::start_with_underlay(configs.server, mac_path).unwrap();
    let mut listener = mac.listen(PORT).await.unwrap();
    let mut dialed = phone.connect(SocketAddr::new(configs.server_v4, PORT)).await.unwrap();
    let mut accepted = listener.accept().await.unwrap();
    dialed.write_all(b"hi").await.unwrap();
    let mut hi = [0u8; 2];
    accepted.read_exact(&mut hi).await.unwrap();
    Pair { sim, phone, mac, dialed, accepted, _controls: controls }
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
    // The phone comes back: its first data starts a new handshake (the old
    // session is past 120 s; a refresh while still held waits for the
    // release), then goes out.
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
/// at all: no TCP keepalive probe, no WireGuard keepalive and no path probe.
/// Unheld, the same silence draws them (on the 5 s, 10 s and 15 s periods).
/// The counts are printed for the PR's cost table (`--nocapture`).
async fn held_tunnel_sends_its_silent_peer_nothing(pair: Pair, what: &str) {
    // Let the exchange's own tail (ACKs, a passive keepalive) settle first.
    tokio::time::sleep(Duration::from_secs(1)).await;
    pair.mac.hold(Some(Duration::from_secs(10 * 60))).await.unwrap();
    pair.sim.set_link(addr(PHONE), addr(MAC), link(true));
    let sent = |sim: &SimNet| (sim.sent_from(addr(MAC)), sim.sent_bytes_from(addr(MAC)));
    let before = sent(&pair.sim);
    tokio::time::sleep(Duration::from_secs(5 * 60)).await;
    let after = sent(&pair.sim);
    let (held, held_bytes) = (after.0 - before.0, after.1 - before.1);
    println!("{what}: held 5 min: {held} datagrams, {held_bytes} bytes");
    assert_eq!(held, 0, "a held Mac sent its suspended phone {held} datagrams in 5 minutes");

    pair.mac.hold(None).await.unwrap();
    let before = sent(&pair.sim);
    tokio::time::sleep(Duration::from_secs(35)).await;
    let after = sent(&pair.sim);
    let (unheld, unheld_bytes) = (after.0 - before.0, after.1 - before.1);
    println!("{what}: released, next 35 s: {unheld} datagrams, {unheld_bytes} bytes");
    assert!(unheld > 0, "an unheld Mac sent nothing in 35 s: the comparison proves nothing");
    pair.phone.shutdown().await;
    pair.mac.shutdown().await;
}

#[tokio::test(start_paused = true)]
async fn a_held_tunnel_sends_its_silent_peer_nothing() {
    held_tunnel_sends_its_silent_peer_nothing(pair().await, "one socket").await;
}

/// As a phone link runs: each side on a path selector probing its path every
/// 5 s while the session is active. The park itself is traffic, so the probe
/// schedule is still active when the hold starts.
#[tokio::test(start_paused = true)]
async fn a_held_tunnel_with_path_probes_sends_its_silent_peer_nothing() {
    held_tunnel_sends_its_silent_peer_nothing(probed_pair().await, "path probes").await;
}

/// The same silence with no hold, measured the same way: what a suspended
/// phone's tunnel costs today in its first 35 s.
#[tokio::test(start_paused = true)]
async fn an_unheld_tunnel_with_path_probes_sends_its_silent_peer_datagrams() {
    let pair = probed_pair().await;
    tokio::time::sleep(Duration::from_secs(1)).await;
    pair.sim.set_link(addr(PHONE), addr(MAC), link(true));
    let (datagrams, bytes) = (pair.sim.sent_from(addr(MAC)), pair.sim.sent_bytes_from(addr(MAC)));
    tokio::time::sleep(Duration::from_secs(35)).await;
    let datagrams = pair.sim.sent_from(addr(MAC)) - datagrams;
    let bytes = pair.sim.sent_bytes_from(addr(MAC)) - bytes;
    println!("path probes: unheld, first 35 s of silence: {datagrams} datagrams, {bytes} bytes");
    assert!(datagrams > 0, "an unheld Mac sent nothing in 35 s");
    pair.phone.shutdown().await;
    pair.mac.shutdown().await;
}

/// Output the Mac sent just as the phone went silent is never acknowledged
/// (its ACK is lost with the phone). Held, the Mac does not retransmit it
/// through the hold: no RTO, no tail-loss probe. Released, with the phone
/// back, it resends at once and the output arrives. The counts are printed
/// for the PR's cost table (`--nocapture`).
#[tokio::test(start_paused = true)]
async fn a_held_tunnel_does_not_retransmit_unacknowledged_output() {
    let mut pair = pair().await;
    tokio::time::sleep(Duration::from_secs(1)).await;
    pair.sim.set_link(addr(PHONE), addr(MAC), link(true));
    pair.accepted.write_all(b"late output").await.unwrap();
    // Its first transmission goes out (and is lost) before the hold.
    tokio::time::sleep(Duration::from_millis(5)).await;
    // Both ends hold, as a parked link's do: unheld, the phone's own idle
    // connection would end on its 60 s user timeout during the silence.
    pair.mac.hold(Some(Duration::from_secs(10 * 60))).await.unwrap();
    pair.phone.hold(Some(Duration::from_secs(10 * 60))).await.unwrap();
    let sent = |sim: &SimNet| (sim.sent_from(addr(MAC)), sim.sent_bytes_from(addr(MAC)));
    let before = sent(&pair.sim);
    tokio::time::sleep(Duration::from_secs(5 * 60)).await;
    let after = sent(&pair.sim);
    let (held, held_bytes) = (after.0 - before.0, after.1 - before.1);
    println!("outstanding data: held 5 min: {held} datagrams, {held_bytes} bytes");
    assert_eq!(
        held, 0,
        "a held Mac retransmitted to its suspended phone: {held} datagrams in 5 minutes"
    );

    // The phone is back: the output arrives.
    pair.sim.set_link(addr(PHONE), addr(MAC), link(false));
    pair.phone.refresh().await.unwrap();
    pair.mac.hold(None).await.unwrap();
    pair.phone.hold(None).await.unwrap();
    let mut late = [0u8; 11];
    tokio::time::timeout(Duration::from_secs(10), pair.dialed.read_exact(&mut late))
        .await
        .expect("the held output arrives after the release")
        .unwrap();
    assert_eq!(&late, b"late output");
    assert!(
        alive(&mut pair.dialed, &mut pair.accepted).await,
        "the connection ended at the release"
    );
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

/// The Mac's network changes while its phone is parked: a wake that may have
/// changed the network (`refresh`) and a move to a new socket (`rebind`).
/// Held, neither reasserts the session toward the suspended phone: the
/// reassertion waits for the release, then goes out from the new socket and
/// the phone follows it there. The counts are printed for the PR's cost
/// table (`--nocapture`).
#[tokio::test(start_paused = true)]
async fn a_held_tunnel_does_not_reassert_to_its_parked_peer_across_a_rebind() {
    let mut pair = pair().await;
    tokio::time::sleep(Duration::from_secs(1)).await;
    pair.mac.hold(Some(Duration::from_secs(10 * 60))).await.unwrap();
    pair.phone.hold(Some(Duration::from_secs(10 * 60))).await.unwrap();
    pair.sim.set_link(addr(PHONE), addr(MAC), link(true));
    pair.sim.set_link(addr(PHONE), addr(MAC_MOVED), link(true));
    let sent = |sim: &SimNet| {
        let (old, new) = (addr(MAC), addr(MAC_MOVED));
        (
            sim.sent_from(old) + sim.sent_from(new),
            sim.sent_bytes_from(old) + sim.sent_bytes_from(new),
        )
    };
    let before = sent(&pair.sim);
    tokio::time::sleep(Duration::from_secs(60)).await;
    pair.mac.refresh().await.unwrap();
    tokio::time::sleep(Duration::from_secs(60)).await;
    let moved = SocketPath::new(pair.sim.bind(addr(MAC_MOVED)).unwrap(), Some(addr(PHONE)));
    pair.mac.rebind(moved).await.unwrap();
    tokio::time::sleep(Duration::from_secs(3 * 60)).await;
    let after = sent(&pair.sim);
    let (held, held_bytes) = (after.0 - before.0, after.1 - before.1);
    println!(
        "mac rebind: held 5 min, a refresh and a rebind: {held} datagrams, {held_bytes} bytes"
    );
    assert_eq!(held, 0, "a held Mac reasserted to its suspended phone: {held} datagrams");

    // The phone is back, and the Mac is on its new address: the release
    // reasserts from there, the phone follows, and the connection carries a
    // round trip.
    pair.sim.set_link(addr(PHONE), addr(MAC_MOVED), link(false));
    pair.mac.hold(None).await.unwrap();
    tokio::time::sleep(Duration::from_millis(50)).await;
    let released = pair.sim.sent_from(addr(MAC_MOVED));
    println!("mac rebind: released: {released} datagrams from the new address");
    assert!(released > 0, "the release did not reassert from the new address");
    pair.phone.hold(None).await.unwrap();
    assert!(
        alive(&mut pair.dialed, &mut pair.accepted).await,
        "the connection did not follow the Mac to its new address"
    );
    pair.phone.shutdown().await;
    pair.mac.shutdown().await;
}

/// A connection the Mac accepts after the park (a link's input lane opened
/// late, its SYN behind the park) is held like the ones before it: through
/// five silent minutes it sends the phone nothing and is not aborted on its
/// 60 s user timeout, and it works after the release.
#[tokio::test(start_paused = true)]
async fn a_connection_accepted_after_the_hold_is_held_too() {
    let mut pair = pair().await;
    pair.mac.hold(Some(Duration::from_secs(10 * 60))).await.unwrap();
    pair.phone.hold(Some(Duration::from_secs(10 * 60))).await.unwrap();
    let server = SocketAddr::new(pair.accepted.local_addr().ip(), PORT + 1);
    let mut lane_listener = pair.mac.listen(PORT + 1).await.unwrap();
    let mut lane = pair.phone.connect(server).await.unwrap();
    let mut lane_accepted = lane_listener.accept().await.unwrap();
    lane.write_all(b"hi").await.unwrap();
    let mut hi = [0u8; 2];
    lane_accepted.read_exact(&mut hi).await.unwrap();
    tokio::time::sleep(Duration::from_secs(1)).await;

    pair.sim.set_link(addr(PHONE), addr(MAC), link(true));
    let sent = |sim: &SimNet| (sim.sent_from(addr(MAC)), sim.sent_bytes_from(addr(MAC)));
    let before = sent(&pair.sim);
    tokio::time::sleep(Duration::from_secs(5 * 60)).await;
    let after = sent(&pair.sim);
    let (held, held_bytes) = (after.0 - before.0, after.1 - before.1);
    println!("late accept: held 5 min: {held} datagrams, {held_bytes} bytes");
    assert_eq!(
        held, 0,
        "a held Mac sent its suspended phone {held} datagrams for a late connection"
    );

    pair.sim.set_link(addr(PHONE), addr(MAC), link(false));
    pair.phone.refresh().await.unwrap();
    assert!(alive(&mut pair.dialed, &mut pair.accepted).await, "the main connection ended");
    pair.mac.hold(None).await.unwrap();
    pair.phone.hold(None).await.unwrap();
    assert!(
        alive(&mut lane, &mut lane_accepted).await,
        "the late connection ended during the hold"
    );
    pair.phone.shutdown().await;
    pair.mac.shutdown().await;
}
