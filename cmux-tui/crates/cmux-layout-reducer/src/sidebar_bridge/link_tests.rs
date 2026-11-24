use super::*;

/// Every acpmux state maps to exactly one sidebar state, and arrives by its wire word.
#[test]
fn every_acpmux_link_state_maps_to_exactly_one_sidebar_state() {
    let table = [
        ("connected", LinkState::Connected, false),
        ("connecting", LinkState::Connecting, false),
        ("reconnecting", LinkState::Connecting, false),
        ("restarting", LinkState::Connecting, false),
        ("degraded", LinkState::Connecting, false),
        ("offline", LinkState::Offline, true),
        ("authFailed", LinkState::Offline, false),
        ("updateRequired", LinkState::Offline, false),
        ("paused", LinkState::Paused, false),
    ];
    assert_eq!(table.len(), PeerLink::ALL.len(), "one row per acpmux state");
    for (link, (word, dot, reconnects)) in PeerLink::ALL.iter().zip(table) {
        let parsed: PeerLink = serde_json::from_value(serde_json::json!(word)).unwrap();
        assert_eq!(parsed, *link, "{word}");
        assert_eq!(peer_link(parsed), Shown { link: dot, reconnects_on_use: reconnects }, "{word}");
    }
}

/// The app's statuses keep the dots they had in Swift (`MachineLinkStateTests`).
#[test]
fn every_app_status_has_one_dot() {
    let links = status_links();
    assert_eq!(links.len(), STATUSES.len());
    let dot = |word: &str| links[word].link;
    assert_eq!(dot("updateAvailable"), LinkState::Connected);
    assert_eq!(dot("reconnecting"), LinkState::Connecting);
    assert_eq!(dot("authFailed"), LinkState::Offline);
    assert_eq!(dot("pausedIdle"), LinkState::Paused);
    assert_eq!(dot("disconnected"), LinkState::Attention);
    let reconnects: Vec<&str> = links
        .iter()
        .filter(|(_, shown)| shown.reconnects_on_use)
        .map(|(word, _)| word.as_str())
        .collect();
    assert_eq!(reconnects, ["disconnected", "failed", "offline", "unreachable"]);
}

/// A joined machine's heartbeat TTL counts only with no peer link.
#[test]
fn a_peer_link_outranks_the_hubs_heartbeat() {
    let dot = |hub, peer| joined_link(hub, peer).link;
    assert_eq!(dot(Joined::Offline, Some(PeerLink::Connected)), LinkState::Connected);
    assert_eq!(dot(Joined::Online, Some(PeerLink::Offline)), LinkState::Offline);
    assert_eq!(dot(Joined::Online, Some(PeerLink::Reconnecting)), LinkState::Connecting);
    assert_eq!(dot(Joined::Online, None), LinkState::Connected);
    assert_eq!(dot(Joined::Offline, None), LinkState::Offline);
    assert_eq!(dot(Joined::Revoked, Some(PeerLink::Connected)), LinkState::Offline);
}
