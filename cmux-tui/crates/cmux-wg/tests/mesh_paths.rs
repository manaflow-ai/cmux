//! A mesh peer reachable at several addresses: the path selector picks one,
//! and a cut path fails over to another without ending the stream.

mod mesh_support;

use std::net::{IpAddr, SocketAddr};
use std::time::Duration;

use cmux_wg::testing::random_keypair;
use cmux_wg::{PathKind, PathState, PeerCandidate, WgMesh, WgStream};
use mesh_support::*;
use tokio::time::Instant;

/// One echo round trip, timed.
async fn timed_round_trip(stream: &mut WgStream) -> Duration {
    let started = Instant::now();
    echo_round_trip(stream, 256).await;
    started.elapsed()
}

/// Keep the session busy for `span` (probes run only while it carries
/// traffic).
async fn traffic_for(stream: &mut WgStream, span: Duration) {
    let until = Instant::now() + span;
    while Instant::now() < until {
        echo_round_trip(stream, 256).await;
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
}

/// The address `mesh` sends to `peer` on alone now, if one.
async fn current_path(mesh: &WgMesh, peer: [u8; 32]) -> Option<SocketAddr> {
    let paths = mesh.peer_paths(peer).await.unwrap().expect("a peer");
    paths.iter().find(|path| path.current).map(|path| path.address)
}

#[tokio::test]
async fn a_cut_fast_path_fails_over_to_the_other_candidate_mid_stream() {
    let a = node(&[overlay(1)]).await;
    let b = node(&[overlay(2)]).await;
    let (fast, cut_fast) = cuttable_link(b.udp, Duration::from_millis(1)).await;
    let (slow, _cut_slow) = cuttable_link(b.udp, Duration::from_millis(15)).await;
    let mut to_b = peer_of(&b, &[overlay(2)], false);
    to_b.route = Some(fast.into());
    to_b.candidates = vec![
        PeerCandidate { address: fast, kind: Some(PathKind::DirectLan) },
        PeerCandidate { address: slow, kind: Some(PathKind::DoRelay) },
    ];
    within(a.mesh.add_peer(to_b)).await.unwrap();
    within(b.mesh.add_peer(peer_of(&a, &[overlay(1)], false))).await.unwrap();
    let (_echo, _accepted) = spawn_echo(within(b.mesh.listen(LINK_PORT)).await.unwrap());
    let mut stream = within(a.mesh.connect(SocketAddr::new(overlay(2), LINK_PORT))).await.unwrap();

    traffic_for(&mut stream, Duration::from_millis(1500)).await;
    assert_eq!(current_path(&a.mesh, b.public).await, Some(fast), "the direct path wins");

    cut_fast.store(true, std::sync::atomic::Ordering::Relaxed);
    // The first round trip after the cut waits out the quiet-path windows
    // and the inner TCP's retransmission; the stream itself survives.
    let first = timed_round_trip(&mut stream).await;
    assert!(first < Duration::from_secs(3), "first round trip after the cut took {first:?}");
    traffic_for(&mut stream, Duration::from_secs(4)).await;
    assert_eq!(current_path(&a.mesh, b.public).await, Some(slow), "the relay carries it now");
    let paths = a.mesh.peer_paths(b.public).await.unwrap().unwrap();
    let dead = paths.iter().find(|path| path.address == fast).map(|path| path.state);
    assert_eq!(dead, Some(PathState::Dead));
}

/// Whether this machine has an IPv4 address another machine could reach.
fn has_advertisable_address() -> bool {
    cmux_transport::local_networks().into_iter().any(|network| match network.address {
        IpAddr::V4(v4) => !(v4.is_loopback() || v4.is_link_local() || v4.is_unspecified()),
        IpAddr::V6(_) => false,
    })
}

#[tokio::test]
async fn a_peer_learns_the_other_sides_addresses_inside_the_session_and_fails_over_to_them() {
    if !has_advertisable_address() {
        eprintln!("skipped: this machine has no non-loopback IPv4 address to advertise");
        return;
    }
    let (a_private, a_public) = random_keypair();
    let (b_private, b_public) = random_keypair();
    let a = node_bound(&[overlay(1)], a_private, a_public, 1380, "0.0.0.0:0").await;
    let b = node_bound(&[overlay(2)], b_private, b_public, 1380, "0.0.0.0:0").await;
    // A knows B only behind a relay link, as a pairing that knows one
    // address; B learns A from its datagrams.
    let (relayed, cut) = cuttable_link(
        SocketAddr::new([127, 0, 0, 1].into(), b.udp.port()),
        Duration::from_millis(15),
    )
    .await;
    let mut to_b = peer_of(&b, &[overlay(2)], false);
    to_b.route = Some(relayed.into());
    to_b.candidates = vec![PeerCandidate { address: relayed, kind: Some(PathKind::DoRelay) }];
    within(a.mesh.add_peer(to_b)).await.unwrap();
    within(b.mesh.add_peer(peer_of(&a, &[overlay(1)], false))).await.unwrap();
    let (_echo, _accepted) = spawn_echo(within(b.mesh.listen(LINK_PORT)).await.unwrap());
    let mut stream = within(a.mesh.connect(SocketAddr::new(overlay(2), LINK_PORT))).await.unwrap();

    // B advertises its interface addresses; A probes them and moves to a
    // direct one, which beats the relay.
    let deadline = Instant::now() + Duration::from_secs(8);
    loop {
        let current = current_path(&a.mesh, b.public).await;
        if current.is_some_and(|path| path != relayed && path.port() == b.udp.port()) {
            break;
        }
        assert!(Instant::now() < deadline, "A never moved to an address B advertised");
        traffic_for(&mut stream, Duration::from_millis(200)).await;
    }

    cut.store(true, std::sync::atomic::Ordering::Relaxed);
    let first = timed_round_trip(&mut stream).await;
    assert!(first < Duration::from_secs(3), "first round trip after the cut took {first:?}");
    traffic_for(&mut stream, Duration::from_secs(1)).await;
}

#[tokio::test]
async fn a_peer_with_one_address_roams_to_its_latest_source_as_before() {
    let a = node(&[overlay(1)]).await;
    let b = node(&[overlay(2)]).await;
    within(a.mesh.add_peer(peer_of(&b, &[overlay(2)], true))).await.unwrap();
    within(b.mesh.add_peer(peer_of(&a, &[overlay(1)], false))).await.unwrap();
    let (_echo, _accepted) = spawn_echo(within(b.mesh.listen(LINK_PORT)).await.unwrap());
    let mut stream = within(a.mesh.connect(SocketAddr::new(overlay(2), LINK_PORT))).await.unwrap();
    traffic_for(&mut stream, Duration::from_millis(500)).await;
    // B holds one address for A (no advertisements from a socket bound to
    // one address), so it sends no probes and simply follows A.
    let paths = b.mesh.peer_paths(a.public).await.unwrap().unwrap();
    assert_eq!(paths.len(), 1);
    assert_eq!(paths[0].address, a.udp);
    assert!(paths[0].current);
    assert_eq!(b.mesh.peer_paths([7; 32]).await.unwrap(), None, "not a peer");
}
