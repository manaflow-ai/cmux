//! The last-good memory: order, freshness, forget and the off switch.

use std::time::Duration;

use super::LastGood;

#[test]
fn the_remembered_winner_goes_first_and_the_rest_keep_their_order() {
    let memory = LastGood::new(Duration::from_secs(60));
    assert_eq!(memory.order(&"peer", &["v6", "v4", "v6b"]), (vec!["v6", "v4", "v6b"], None));
    memory.record("peer", "v4", Duration::from_millis(40));
    assert_eq!(
        memory.order(&"peer", &["v6", "v4", "v6b"]),
        (vec!["v4", "v6", "v6b"], Some(Duration::from_millis(40)))
    );
    // Another peer is unaffected.
    assert_eq!(memory.order(&"other", &["v6", "v4"]), (vec!["v6", "v4"], None));
}

#[test]
fn a_winner_the_resolver_no_longer_returns_changes_nothing() {
    let memory = LastGood::new(Duration::from_secs(60));
    memory.record("peer", "gone", Duration::from_millis(40));
    assert_eq!(memory.order(&"peer", &["v6", "v4"]), (vec!["v6", "v4"], None));
}

#[test]
fn a_stale_or_forgotten_winner_is_not_used() {
    let memory = LastGood::new(Duration::ZERO);
    memory.record("peer", "v4", Duration::from_millis(40));
    assert_eq!(memory.order(&"peer", &["v6", "v4"]), (vec!["v6", "v4"], None));
    let memory = LastGood::new(Duration::from_secs(60));
    memory.record("peer", "v4", Duration::from_millis(40));
    memory.forget(&"peer");
    assert!(memory.get(&"peer").is_none());
}

/// A network a test switches by hand.
fn switchable()
-> (std::sync::Arc<std::sync::atomic::AtomicU64>, LastGood<&'static str, &'static str>) {
    let now = std::sync::Arc::new(std::sync::atomic::AtomicU64::new(1));
    let read = now.clone();
    let memory = LastGood::new(Duration::from_secs(600)).on_network(move || {
        let network = read.load(std::sync::atomic::Ordering::SeqCst) as u32;
        crate::Fingerprint::of(Some(std::net::Ipv4Addr::from(network)), None)
    });
    (now, memory)
}

#[test]
fn each_network_keeps_its_own_winner() {
    let (network, memory) = switchable();
    memory.record("peer", "tcp", Duration::from_millis(40));
    network.store(2, std::sync::atomic::Ordering::SeqCst);
    // A new network: the home winner is not assumed here.
    assert_eq!(memory.order(&"peer", &["quic", "tcp"]), (vec!["quic", "tcp"], None));
    memory.record("peer", "quic", Duration::from_millis(20));
    network.store(1, std::sync::atomic::Ordering::SeqCst);
    // Back home: the home winner leads again.
    assert_eq!(
        memory.order(&"peer", &["quic", "tcp"]),
        (vec!["tcp", "quic"], Some(Duration::from_millis(40)))
    );
}

#[tokio::test(start_paused = true)]
async fn a_broken_route_is_raced_late_backs_off_and_clears_on_success() {
    let memory = LastGood::new(Duration::from_secs(600));
    memory.record("peer", "quic", Duration::from_millis(20));
    memory.failed(&"peer", &"quic");
    // Late, not skipped; and no longer the winner.
    assert_eq!(memory.order(&"peer", &["quic", "tcp", "ws"]), (vec!["tcp", "ws", "quic"], None));
    assert!(memory.is_broken(&"peer", &"quic"));
    tokio::time::advance(super::BROKEN_FIRST).await;
    assert!(!memory.is_broken(&"peer", &"quic"));
    assert_eq!(memory.order(&"peer", &["quic", "tcp"]).0, vec!["quic", "tcp"]);
    // A second failure doubles the backoff.
    memory.failed(&"peer", &"quic");
    tokio::time::advance(super::BROKEN_FIRST + Duration::from_secs(1)).await;
    assert!(memory.is_broken(&"peer", &"quic"));
    tokio::time::advance(super::BROKEN_FIRST).await;
    assert!(!memory.is_broken(&"peer", &"quic"));
    // A success clears the mark at once.
    memory.failed(&"peer", &"quic");
    assert!(memory.is_broken(&"peer", &"quic"));
    memory.record("peer", "quic", Duration::from_millis(20));
    assert!(!memory.is_broken(&"peer", &"quic"));
    assert_eq!(memory.order(&"peer", &["tcp", "quic"]).0, vec!["quic", "tcp"]);
}

#[test]
fn backoff_doubles_from_five_minutes_and_stops_doubling() {
    assert_eq!(super::broken_for(1), Duration::from_secs(300));
    assert_eq!(super::broken_for(2), Duration::from_secs(600));
    assert_eq!(super::broken_for(3), Duration::from_secs(1200));
    assert_eq!(super::broken_for(9), super::BROKEN_LONGEST);
    assert_eq!(super::broken_for(u32::MAX), super::BROKEN_LONGEST);
}

#[test]
fn a_network_change_clears_every_broken_mark() {
    let (network, memory) = switchable();
    memory.failed(&"peer", &"quic");
    assert!(memory.is_broken(&"peer", &"quic"));
    network.store(2, std::sync::atomic::Ordering::SeqCst);
    assert!(!memory.is_broken(&"peer", &"quic"));
    assert_eq!(memory.order(&"peer", &["quic", "tcp"]).0, vec!["quic", "tcp"]);
    // Back on the first network the mark stays cleared: a change is a fresh try.
    network.store(1, std::sync::atomic::Ordering::SeqCst);
    assert!(!memory.is_broken(&"peer", &"quic"));
}
