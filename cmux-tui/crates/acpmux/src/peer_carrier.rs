//! What a peer's link knows besides its `Link` history, for `_acpmux/peer_state_changed`
//! (`protocol/peer_state.rs`): the carrier the open link runs over, whether the peer refused
//! this daemon's token, why it is down, and since when its state holds. acpmux owns this
//! state; every surface renders it and keeps no clock of its own.

use crate::protocol::peer_state::{Carrier, DownCause, MachineLink};

use crate::peer_link::PeerState;

/// One peer instance's link facts, kept under one lock (`Peer::facts`).
#[derive(Debug, Default)]
pub(crate) struct LinkFacts {
    /// The carrier of the link that is open now, or of the attempt running now.
    pub carrier: Option<Carrier>,
    /// The last attempt was refused for its token (HTTP 401 or 403).
    pub refused: bool,
    /// The whole state last reported and when it began.
    since: Option<(MachineLink, u64)>,
}

impl LinkFacts {
    /// The whole state of a link in `state`, and when it began (`now` when it just changed).
    pub fn observe(&mut self, state: PeerState, now: u64) -> (MachineLink, u64) {
        let link = whole(state, self.refused);
        match self.since {
            Some((was, at)) if was == link => (link, at),
            _ => {
                self.since = Some((link, now));
                (link, now)
            }
        }
    }

    /// The carrier to report: only an open link has one.
    pub fn live_carrier(&self, state: PeerState) -> Option<Carrier> {
        matches!(state, PeerState::Connected | PeerState::Degraded)
            .then_some(self.carrier)
            .flatten()
    }
}

/// `state` as the whole link state: a down link whose last attempt was refused for its token
/// is `authFailed`, which a person fixes, not a retry.
pub(crate) fn whole(state: PeerState, refused: bool) -> MachineLink {
    match state {
        PeerState::Reconnecting | PeerState::Offline if refused => MachineLink::AuthFailed,
        other => other.wire(),
    }
}

/// Why a link in `link` is down, from what acpmux knows today: its last attempt's error, and
/// whether the peer refused the token. A link that is up, or on its way the first time, has
/// no cause.
///
/// TODO(carrier slice 3): decide `localNetwork` against `peerDown` with a test request over a
/// second carrier (the hub or Cloud relay), and report `hubDown` from the hub carrier's probe.
/// Until then `localNetwork` comes from an error that never left this host.
pub(crate) fn cause(link: MachineLink, error: Option<&str>) -> Option<DownCause> {
    match link {
        MachineLink::AuthFailed => Some(DownCause::Auth),
        MachineLink::Reconnecting | MachineLink::Offline => Some(if error.is_some_and(local) {
            DownCause::LocalNetwork
        } else {
            DownCause::PeerDown
        }),
        _ => None,
    }
}

/// An error raised before a packet could leave this host: no route out, or no name service.
fn local(error: &str) -> bool {
    const LOCAL: [&str; 6] = [
        "network is unreachable",
        "os error 51",
        "os error 101",
        "failed to lookup address",
        "nodename nor servname",
        "could not resolve hostname",
    ];
    let error = error.to_ascii_lowercase();
    LOCAL.iter().any(|needle| error.contains(needle))
}

#[cfg(test)]
mod tests {
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
            cause(
                down,
                Some("ssh: Could not resolve hostname box: nodename nor servname provided")
            ),
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
}
