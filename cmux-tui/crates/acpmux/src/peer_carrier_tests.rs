use super::*;

#[test]
fn a_refused_down_link_is_auth_failed_and_says_so() {
    assert_eq!(whole(PeerState::Offline, true), MachineLink::AuthFailed);
    assert_eq!(whole(PeerState::Reconnecting, true), MachineLink::AuthFailed);
    assert_eq!(whole(PeerState::Connected, true), MachineLink::Connected);
    assert_eq!(whole(PeerState::Restarting, false), MachineLink::Restarting);
    assert_eq!(cause(MachineLink::AuthFailed, None), Some(DownCause::Auth));
}

#[test]
fn a_down_link_names_this_hosts_network_only_for_an_error_that_never_left_it() {
    let down = MachineLink::Reconnecting;
    assert_eq!(
        cause(down, Some("IO error: Network is unreachable (os error 51)")),
        Some(DownCause::LocalNetwork)
    );
    assert_eq!(
        cause(down, Some("ssh: Could not resolve hostname box: nodename nor servname provided")),
        Some(DownCause::LocalNetwork)
    );
    assert_eq!(cause(down, Some("connect timed out after 5s")), Some(DownCause::PeerDown));
    assert_eq!(cause(MachineLink::Offline, None), Some(DownCause::PeerDown));
    for up in [MachineLink::Connected, MachineLink::Degraded, MachineLink::Connecting] {
        assert_eq!(cause(up, Some("Network is unreachable")), None);
    }
}

#[test]
fn since_holds_while_the_state_holds_and_moves_when_it_changes() {
    let mut facts = LinkFacts::default();
    assert_eq!(facts.observe(PeerState::Connecting, 10), (MachineLink::Connecting, 10));
    assert_eq!(facts.observe(PeerState::Connecting, 20), (MachineLink::Connecting, 10));
    assert_eq!(facts.observe(PeerState::Connected, 30), (MachineLink::Connected, 30));
    facts.carrier = Some(Carrier::Ssh);
    assert_eq!(facts.live_carrier(PeerState::Connected), Some(Carrier::Ssh));
    assert_eq!(facts.live_carrier(PeerState::Reconnecting), None);
}
