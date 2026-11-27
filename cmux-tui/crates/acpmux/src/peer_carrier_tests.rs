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

/// A dial's kind comes from its error's type: the I/O error's kind, a 401 or 403, a
/// deadline. A kind that says nothing about the route has none.
#[test]
fn a_dial_error_is_typed_from_the_error_that_raised_it() {
    use std::io::{Error, ErrorKind};
    let io = |kind| DialError::io(&Error::new(kind, "x")).fail;
    assert_eq!(io(ErrorKind::ConnectionRefused), Some(DialFail::Refused));
    assert_eq!(io(ErrorKind::TimedOut), Some(DialFail::Timeout));
    for kind in [
        ErrorKind::NetworkUnreachable,
        ErrorKind::HostUnreachable,
        ErrorKind::AddrNotAvailable,
        ErrorKind::NotFound,
    ] {
        assert_eq!(io(kind), Some(DialFail::Unreachable), "{kind:?}");
    }
    assert_eq!(io(ErrorKind::ConnectionReset), None);
    assert_eq!(io(ErrorKind::BrokenPipe), None);
    // An OS error by its number, as a socket raises it.
    let refused = Error::from(ErrorKind::ConnectionRefused);
    assert_eq!(DialError::io(&refused).text, refused.to_string());

    use tokio_tungstenite::tungstenite::Error as Ws;
    let status = |code: u16| {
        let response = tokio_tungstenite::tungstenite::http::Response::builder()
            .status(code)
            .body(None)
            .unwrap();
        DialError::ws(&Ws::Http(Box::new(response))).fail
    };
    assert_eq!(status(401), Some(DialFail::Auth));
    assert_eq!(status(403), Some(DialFail::Auth));
    assert_eq!(status(502), None);
    assert_eq!(
        DialError::ws(&Ws::Io(Error::from(ErrorKind::ConnectionRefused))).fail,
        Some(DialFail::Refused)
    );
    assert_eq!(DialError::ws(&Ws::ConnectionClosed).fail, None);

    let wrapped = anyhow::Error::from(Error::from(ErrorKind::HostUnreachable)).context("wg");
    assert_eq!(fail_of_chain(&wrapped), Some(DialFail::Unreachable));
    assert_eq!(fail_of_chain(&anyhow::anyhow!("WireGuard transport stopped")), None);

    let timed = DialError::timeout("connect timed out after 5s".into());
    assert_eq!(timed.fail, Some(DialFail::Timeout));
    // Text-only steps convert both ways, untyped.
    let plain: DialError = "no token for the peer yet".to_owned().into();
    assert_eq!(plain.fail, None);
    assert_eq!(String::from(plain), "no token for the peer yet");
}

/// Every path failed: the connect names the most telling kind, whatever order they came.
#[test]
fn a_failed_connect_names_its_most_telling_kind() {
    let e = |fail| DialError::new(fail, "x");
    let failed = [
        e(Some(DialFail::Timeout)),
        e(None),
        e(Some(DialFail::Unreachable)),
        e(Some(DialFail::Refused)),
    ];
    assert_eq!(connect_fail(&failed), Some(DialFail::Refused));
    assert_eq!(connect_fail(&failed[..3]), Some(DialFail::Unreachable));
    assert_eq!(
        connect_fail(&[e(Some(DialFail::Timeout)), e(Some(DialFail::Auth))]),
        Some(DialFail::Auth)
    );
    assert_eq!(connect_fail(&[e(None)]), None);
    assert_eq!(connect_fail(&[]), None);
    // Every kind has its own rank, so the pick never depends on the order.
    let mut ranks: Vec<_> = DialFail::ALL.iter().map(|fail| fail.rank()).collect();
    ranks.sort_unstable();
    ranks.dedup();
    assert_eq!(ranks.len(), DialFail::ALL.len());
}
