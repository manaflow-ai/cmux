use super::*;

#[test]
fn a_refused_down_link_is_auth_failed_and_says_so() {
    assert_eq!(whole(PeerState::Offline, true, None), MachineLink::AuthFailed);
    assert_eq!(whole(PeerState::Reconnecting, true, None), MachineLink::AuthFailed);
    assert_eq!(whole(PeerState::Connected, true, None), MachineLink::Connected);
    assert_eq!(whole(PeerState::Restarting, false, None), MachineLink::Restarting);
    assert_eq!(reason(PeerState::Reconnecting, true, None), Some(OfflineReason::LoginNeeded));
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
    assert_eq!(facts.observe(PeerState::Connecting, None, 10), (MachineLink::Connecting, 10));
    assert_eq!(facts.observe(PeerState::Connecting, None, 20), (MachineLink::Connecting, 10));
    assert_eq!(facts.observe(PeerState::Connected, None, 30), (MachineLink::Connected, 30));
    facts.carrier = Some(Carrier::Ssh);
    assert_eq!(facts.live_carrier(PeerState::Connected), Some(Carrier::Ssh));
    assert_eq!(facts.live_carrier(PeerState::Reconnecting), None);
}

/// A down link whose error names a reason is `offline` with it, never `reconnecting`; an
/// error a retry may fix names none, and a link that is up has none whatever its error.
#[test]
fn a_down_link_with_a_named_reason_is_offline_with_it() {
    let cases = [
        ("credential-unavailable: the hub answered 503", OfflineReason::CredentialUnavailable),
        // A dial the relay refused: the machine's Register ticket ran out unrenewed
        // (cmux-remote `relay_unavailable`, relay code `credential-unavailable`).
        (
            "relay allocation is temporarily unavailable: credential-unavailable: the \
                 machine's relay ticket expired and was not renewed (relay code \
                 credential-unavailable)",
            OfflineReason::CredentialUnavailable,
        ),
        ("relay credential source callback failed", OfflineReason::CredentialUnavailable),
        ("write: No space left on device (os error 28)", OfflineReason::DiskFull),
        ("relay refused: vm.agent_stopping", OfflineReason::MachineStopped),
        ("daemon: restart-budget-exceeded (5 stops today)", OfflineReason::RestartBudgetExceeded),
    ];
    for (error, want) in cases {
        for state in [PeerState::Reconnecting, PeerState::Offline] {
            let got = reason(state, false, Some(error));
            assert_eq!(got, Some(want), "{error}");
            assert_eq!(whole(state, false, got), MachineLink::Offline, "{error}");
        }
        assert_eq!(reason(PeerState::Connected, false, Some(error)), None);
        assert_eq!(reason(PeerState::Connecting, false, Some(error)), None);
    }
    assert_eq!(reason(PeerState::Reconnecting, false, Some("connect timed out after 5s")), None);
    assert_eq!(whole(PeerState::Reconnecting, false, None), MachineLink::Reconnecting);
}
