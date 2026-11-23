//! A machine's link as the sidebar, the agent pane and the web draw it (`MachineLinkState`).
//! acpmux owns the link state (`_acpmux/peer_state_changed` `link`, acpmux
//! `protocol::peer_state::MachineLink`); these rules only map it to a dot, with no clock of
//! their own. The app's own machine statuses (`SidebarMachine.Status`) map here too, so the
//! Swift side keeps no table of its own (`status_links`, read once per launch).

use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;

use super::{LinkState, MachineStatus};

/// acpmux's whole link state, word for word as it arrives (`link`).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum PeerLink {
    Connected,
    Connecting,
    Reconnecting,
    Restarting,
    Degraded,
    Offline,
    AuthFailed,
    UpdateRequired,
    Paused,
}

impl PeerLink {
    /// Every state acpmux sends, in its enum's order.
    pub const ALL: [Self; 9] = [
        Self::Connected,
        Self::Connecting,
        Self::Reconnecting,
        Self::Restarting,
        Self::Degraded,
        Self::Offline,
        Self::AuthFailed,
        Self::UpdateRequired,
        Self::Paused,
    ];
}

/// A link as one dot and whether using the machine may reconnect it on its own.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct Shown {
    pub link: LinkState,
    pub reconnects_on_use: bool,
}

/// An acpmux link as the dot draws it: green only once the handshake finished; a link on its
/// way (the first attempt, a redial, a restart, a handshake still running or a ping unanswered)
/// spins; one a person must fix (sign-in, an update) or that is down is red; a paused Cloud
/// machine is grey. Only a down link reconnects on use: one on its way already does, and a
/// refused token or an old build waits for a person.
pub fn peer_link(link: PeerLink) -> Shown {
    let (link, reconnects_on_use) = match link {
        PeerLink::Connected => (LinkState::Connected, false),
        PeerLink::Connecting
        | PeerLink::Reconnecting
        | PeerLink::Restarting
        | PeerLink::Degraded => (LinkState::Connecting, false),
        PeerLink::Offline => (LinkState::Offline, true),
        PeerLink::AuthFailed | PeerLink::UpdateRequired => (LinkState::Offline, false),
        PeerLink::Paused => (LinkState::Paused, false),
    };
    Shown { link, reconnects_on_use }
}

/// The app's statuses, in `SidebarMachine.Status`'s order.
pub const STATUSES: [MachineStatus; 17] = [
    MachineStatus::Connected,
    MachineStatus::Connecting,
    MachineStatus::Reconnecting,
    MachineStatus::Offline,
    MachineStatus::UpdateAvailable,
    MachineStatus::UpdateRequired,
    MachineStatus::InstallRequired,
    MachineStatus::Installing,
    MachineStatus::AuthFailed,
    MachineStatus::Unreachable,
    MachineStatus::Failed,
    MachineStatus::Disconnected,
    MachineStatus::Paused,
    MachineStatus::PausedIdle,
    MachineStatus::Pausing,
    MachineStatus::Resuming,
    MachineStatus::Deleting,
];

/// A machine header's status as the dot draws it (`SidebarMachine.Status.linkState`): green
/// once its daemon finished the handshake (an optional update too); a spinner on its way; red
/// when down; grey when paused; the attention dot when cmux-tui must be installed or the Cloud
/// link ended. Only a link that dropped or never came up reconnects on use, never one a person
/// must fix (sign-in, an update) or one already on its way.
pub fn status_link(status: MachineStatus) -> Shown {
    use MachineStatus as S;
    let link = match status {
        S::Connected | S::UpdateAvailable => LinkState::Connected,
        S::Connecting
        | S::Reconnecting
        | S::Installing
        | S::Pausing
        | S::Resuming
        | S::Deleting => LinkState::Connecting,
        S::Offline | S::Unreachable | S::AuthFailed | S::Failed | S::UpdateRequired => {
            LinkState::Offline
        }
        S::Paused | S::PausedIdle => LinkState::Paused,
        S::InstallRequired | S::Disconnected => LinkState::Attention,
    };
    let reconnects_on_use =
        matches!(status, S::Offline | S::Unreachable | S::Failed | S::Disconnected);
    Shown { link, reconnects_on_use }
}

/// Every status's dot, keyed by its word: the app reads it once per launch.
pub fn status_links() -> BTreeMap<String, Shown> {
    STATUSES
        .iter()
        .filter_map(|status| {
            let word = serde_json::to_value(status).ok()?.as_str()?.to_owned();
            Some((word, status_link(*status)))
        })
        .collect()
}

/// A hub-joined machine's row as the hub lists it (`JoinedMachine.State`).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Joined {
    /// Its last heartbeat is within the hub's row TTL (90 s).
    Online,
    Offline,
    /// Its credential was revoked: it left.
    Revoked,
}

/// A hub-joined machine's dot. A peer link acpmux holds to it says everything: the hub's
/// heartbeat TTL counts only when there is none, since a heartbeat up to 90 s old is no
/// liveness next to a link that answers pings. A revoked machine is offline whatever its link.
pub fn joined_link(hub: Joined, peer: Option<PeerLink>) -> Shown {
    match (hub, peer) {
        (Joined::Revoked, _) => Shown { link: LinkState::Offline, reconnects_on_use: false },
        (_, Some(link)) => peer_link(link),
        (Joined::Online, None) => Shown { link: LinkState::Connected, reconnects_on_use: false },
        (Joined::Offline, None) => Shown { link: LinkState::Offline, reconnects_on_use: false },
    }
}

#[cfg(test)]
mod tests {
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
            assert_eq!(
                peer_link(parsed),
                Shown { link: dot, reconnects_on_use: reconnects },
                "{word}"
            );
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
}
