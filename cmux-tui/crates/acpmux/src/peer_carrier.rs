//! What a peer's link knows besides its `Link` history, for `_acpmux/peer_state_changed`
//! (`protocol/peer_state.rs`): the carrier the open link runs over, whether the peer refused
//! this daemon's token, why it is down, and since when its state holds. acpmux owns this
//! state; every surface renders it and keeps no clock of its own.

use crate::protocol::peer_state::{
    CREDENTIAL_UNAVAILABLE, Carrier, DownCause, MachineLink, OfflineReason,
};

use crate::no_panic::LockExt;
use crate::peer_link::{Link, PeerState};

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
    /// The whole state of a link in `state` whose last attempt failed with `reason` (if any),
    /// and when it began (`now` when it just changed).
    pub fn observe(
        &mut self,
        state: PeerState,
        reason: Option<OfflineReason>,
        now: u64,
    ) -> (MachineLink, u64) {
        let link = whole(state, self.refused, reason);
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

impl super::Peer {
    /// The link's whole state now, as the peer's state notes carry it.
    pub(super) fn observed(&self, link: &Link) -> crate::peer_states::Observed {
        let error = self.last_error.lock_or_recover().clone();
        let state = link.state();
        let mut facts = self.facts.lock_or_recover();
        let reason = reason(state, facts.refused, error.as_deref());
        // The reason is always reported; a down link turns `offline` for it only with the
        // preview switch on (default off). Read only when a reason is named, which is rare.
        let offline_for = reason.filter(|_| reasons_turn_offline());
        let (whole, since) = facts.observe(state, offline_for, crate::store::now_ms());
        crate::peer_states::Observed {
            link: whole,
            carrier: facts.live_carrier(state),
            cause: cause(whole, error.as_deref()),
            reason,
            since,
            next_retry_at: link.retry_at.filter(|_| !link.is_ready()),
            last_seen: link.last_seen,
            error,
        }
    }
}

/// `state` as the whole link state: a down link whose last attempt was refused for its token
/// is `authFailed`, which a person fixes, not a retry. A down link with an [`OfflineReason`] is
/// `offline`, never `reconnecting`: retrying alone will not heal it, and the reason says what
/// will (attempts still go on behind it).
pub(crate) fn whole(state: PeerState, refused: bool, reason: Option<OfflineReason>) -> MachineLink {
    match state {
        PeerState::Reconnecting | PeerState::Offline if refused => MachineLink::AuthFailed,
        PeerState::Reconnecting | PeerState::Offline if reason.is_some() => MachineLink::Offline,
        other => other.wire(),
    }
}

/// Why a down link will not heal by retrying alone, from what acpmux knows: a refused token
/// (`login-needed`), or its last attempt's error. Null for a link that is up or on its way, and
/// for an error a retry may well fix (a timeout, a refused connection).
pub(crate) fn reason(
    state: PeerState,
    refused: bool,
    error: Option<&str>,
) -> Option<OfflineReason> {
    if !matches!(state, PeerState::Reconnecting | PeerState::Offline) {
        return None;
    }
    if refused {
        return Some(OfflineReason::LoginNeeded);
    }
    let error = error?.to_ascii_lowercase();
    let named = |needles: &[&str]| needles.iter().any(|n| error.contains(n));
    // The words each reason's producer writes into the attempt's error.
    if named(&["no space left on device", "os error 28)", "disk-full"]) {
        Some(OfflineReason::DiskFull)
    } else if named(&["restart-budget-exceeded"]) {
        Some(OfflineReason::RestartBudgetExceeded)
    } else if named(&["vm.agent_stopping", "machine-stopped", "machine is stopped"]) {
        Some(OfflineReason::MachineStopped)
    } else if named(&[CREDENTIAL_UNAVAILABLE, "relay credential source "]) {
        Some(OfflineReason::CredentialUnavailable)
    } else {
        None
    }
}

/// Whether a named [`OfflineReason`] turns a down link `offline` (instead of `reconnecting`):
/// Settings > Experimental > Labs > Show Preview Features (`labs.previewFeatures`), off by
/// default. The reason itself is reported either way.
pub(crate) fn reasons_turn_offline() -> bool {
    use crate::user_settings::{self, Settings};
    matches!(user_settings::read(), Settings::Parsed(doc)
        if user_settings::value(&doc, "labs.previewFeatures") == Some(serde_json::Value::Bool(true)))
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
            ("relay credential source callback failed", OfflineReason::CredentialUnavailable),
            ("write: No space left on device (os error 28)", OfflineReason::DiskFull),
            ("relay refused: vm.agent_stopping", OfflineReason::MachineStopped),
            (
                "daemon: restart-budget-exceeded (5 stops today)",
                OfflineReason::RestartBudgetExceeded,
            ),
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
        assert_eq!(
            reason(PeerState::Reconnecting, false, Some("connect timed out after 5s")),
            None
        );
        assert_eq!(whole(PeerState::Reconnecting, false, None), MachineLink::Reconnecting);
    }
}
