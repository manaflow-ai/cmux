use std::net::{IpAddr, Ipv4Addr};

use std::time::Duration;

use tokio::sync::watch;

use super::{
    CloseState, FAST_FALLBACK_PROBE_TIMEOUT, NETWORK_CHANGE_PROBE_TIMEOUT, RouteSource,
    network_change_window, probe_by,
};

fn route_from(source: Option<IpAddr>) -> RouteSource {
    RouteSource { remote: None, source, direct: false }
}

#[test]
fn a_route_from_an_unassigned_address_is_gone_until_forgotten() {
    // TEST-NET-1 is never assigned to an interface: the address a link dialed from after
    // the kernel dropped it looks the same to the check.
    let mut route = route_from(Some(IpAddr::from(Ipv4Addr::new(192, 0, 2, 77))));
    assert!(route.is_gone());
    route.forget();
    assert!(!route.is_gone());
}

#[test]
fn a_route_from_a_live_address_or_an_unknown_one_is_not_gone() {
    assert!(!route_from(Some(IpAddr::from(Ipv4Addr::LOCALHOST))).is_gone());
    assert!(!route_from(None).is_gone());
}

/// A probe waiting on a route whose address went away ends at the change, not after the
/// two seconds a probe on a route that may have survived gets.
#[tokio::test(start_paused = true)]
async fn a_probe_ends_at_a_network_change_that_took_its_address() {
    let (network_tx, mut network) = watch::channel(0_u64);
    let (_close_tx, mut close_state) = watch::channel(CloseState::Pending);
    let mut deadline = tokio::time::Instant::now() + Duration::from_secs(4);
    network_tx.send_modify(|generation| *generation += 1);
    let started = tokio::time::Instant::now();
    let ended = probe_by(
        std::future::pending::<()>(),
        &mut deadline,
        NETWORK_CHANGE_PROBE_TIMEOUT,
        &mut network,
        &mut close_state,
        &|| true,
    )
    .await;
    assert!(matches!(ended, Ok(None)));
    assert!(started.elapsed() < Duration::from_millis(50));
}

#[tokio::test(start_paused = true)]
async fn a_probe_on_a_route_that_may_have_survived_gets_the_short_window() {
    let (network_tx, mut network) = watch::channel(0_u64);
    let (_close_tx, mut close_state) = watch::channel(CloseState::Pending);
    let mut deadline = tokio::time::Instant::now() + Duration::from_secs(4);
    network_tx.send_modify(|generation| *generation += 1);
    let started = tokio::time::Instant::now();
    let ended = probe_by(
        std::future::pending::<()>(),
        &mut deadline,
        NETWORK_CHANGE_PROBE_TIMEOUT,
        &mut network,
        &mut close_state,
        &|| false,
    )
    .await;
    assert!(matches!(ended, Ok(None)));
    assert_eq!(started.elapsed(), Duration::from_secs(2));
}

/// The fast fallback's window is for a direct path only, and only when it is on: a relay
/// keeps the ordinary window (it rode the change in the bench), and off is the old 2 s.
#[test]
fn the_fast_window_is_for_a_direct_path_with_the_fallback_on() {
    assert_eq!(network_change_window(true, true), FAST_FALLBACK_PROBE_TIMEOUT);
    assert_eq!(network_change_window(true, false), NETWORK_CHANGE_PROBE_TIMEOUT);
    assert_eq!(network_change_window(false, true), NETWORK_CHANGE_PROBE_TIMEOUT);
    assert_eq!(network_change_window(false, false), NETWORK_CHANGE_PROBE_TIMEOUT);
}

/// Before and after, one harness: a probe on a direct path whose mapping the change broke
/// (it never answers) holds the link 2000 ms before the redial with the fallback off, and
/// 250 ms with it on. The redial then takes the warm standby first.
#[tokio::test(start_paused = true)]
async fn a_dead_direct_path_is_left_8x_sooner_with_the_fast_fallback() {
    let mut stalls = Vec::new();
    for fast_fallback in [false, true] {
        let (network_tx, mut network) = watch::channel(0_u64);
        let (_close_tx, mut close_state) = watch::channel(CloseState::Pending);
        let mut deadline = tokio::time::Instant::now() + Duration::from_secs(4);
        network_tx.send_modify(|generation| *generation += 1);
        let started = tokio::time::Instant::now();
        let ended = probe_by(
            std::future::pending::<()>(),
            &mut deadline,
            network_change_window(true, fast_fallback),
            &mut network,
            &mut close_state,
            &|| false,
        )
        .await;
        assert!(matches!(ended, Ok(None)));
        stalls.push(started.elapsed());
    }
    assert_eq!(stalls, [Duration::from_millis(2000), Duration::from_millis(250)]);
}
