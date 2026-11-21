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
#[path = "peer_carrier_tests.rs"]
mod tests;
