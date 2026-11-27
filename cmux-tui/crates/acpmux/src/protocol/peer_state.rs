//! `_acpmux/peer_state_changed`: a peer link's state, pushed to every watching connection on
//! each change (`peer.rs` `report_states`), so a client never polls `_acpmux/peers` for it.
//!
//! acpmux owns the machine link state. `link` is the whole of it (`MachineLink`); the sidebar,
//! the agent pane and the web render it and keep no clock of their own (`cmux-layout-reducer`
//! `sidebar_bridge::link`). `state` is the same value folded to the five words an older app
//! knows (`MachineLink::folded`).

use schemars::JsonSchema;
use serde::{Deserialize, Serialize};

use super::require_all;

/// A peer link's state, folded for older apps (`state`): read `link` for the whole of it.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "lowercase")]
pub enum PeerLinkState {
    /// Not reached yet, this run or a saved one.
    Connecting,
    /// The handshake finished and the peer answers.
    Connected,
    /// The WebSocket is open and the handshake runs, or a ping went unanswered.
    Degraded,
    /// Down after it was reached (or restarting); its last-known sessions stay listed.
    Reconnecting,
    /// Never reached and attempts failed, the peer refused this daemon's token, or removed
    /// (`error: "removed"`, its last note).
    Offline,
}

/// A machine link's whole state (`link`): what every surface draws, from acpmux alone.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "camelCase")]
pub enum MachineLink {
    /// The handshake finished and the peer answers.
    Connected,
    /// Not reached yet, this run or a saved one; the first attempt runs.
    Connecting,
    /// Down after it was reached; its last-known sessions stay listed. Attempts go on
    /// (`nextRetryAt`).
    Reconnecting,
    /// The peer's daemon announced a restart (an update); it is dialed again at once.
    Restarting,
    /// The WebSocket is open and the handshake runs, or a ping went unanswered: slow, not gone.
    Degraded,
    /// Never reached and attempts failed, or removed. Attempts go on (`nextRetryAt`).
    Offline,
    /// The peer refused this daemon's token (HTTP 401 or 403): a person must sign in again.
    AuthFailed,
    /// The peer is too old to link with: a person must update it. Not sent by acpmux yet; a
    /// renderer draws it when a carrier reports it.
    UpdateRequired,
    /// A Cloud machine that is paused; it resumes on use. Not sent by acpmux yet (the Cloud
    /// carrier does not carry acpmux until carrier slice 3); a renderer draws it when sent.
    Paused,
}

impl MachineLink {
    /// Every state, in the order of the enum: a renderer's table test walks it.
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

    /// Its `state` for an app that knows only the five older words.
    pub fn folded(self) -> PeerLinkState {
        match self {
            Self::Connected => PeerLinkState::Connected,
            Self::Connecting => PeerLinkState::Connecting,
            Self::Reconnecting | Self::Restarting => PeerLinkState::Reconnecting,
            Self::Degraded => PeerLinkState::Degraded,
            Self::Offline | Self::AuthFailed | Self::UpdateRequired | Self::Paused => {
                PeerLinkState::Offline
            }
        }
    }

    /// Its wire word (`link`, and `_acpmux/peers` `link`).
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Connected => "connected",
            Self::Connecting => "connecting",
            Self::Reconnecting => "reconnecting",
            Self::Restarting => "restarting",
            Self::Degraded => "degraded",
            Self::Offline => "offline",
            Self::AuthFailed => "authFailed",
            Self::UpdateRequired => "updateRequired",
            Self::Paused => "paused",
        }
    }
}

/// The carrier a live link runs over (`carrier`); null while no link is open.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "lowercase")]
pub enum Carrier {
    /// Straight to the peer: its WebSocket URL, or the paired machines' WireGuard link.
    Direct,
    /// An `ssh -W` tunnel to the peer's daemon.
    Ssh,
    /// Relayed by the team hub. Not sent by acpmux yet (carrier slice 3).
    Hub,
    /// cmux Cloud's relay. Not sent by acpmux yet (carrier slice 3).
    Cloud,
}

/// Why a link is down (`cause`), so a surface can tell this Mac's network apart from the
/// machine. Null while the link is up or on its way the first time.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "camelCase")]
pub enum DownCause {
    /// This machine's own network is down: the last attempt failed before it left this host
    /// (no route, no DNS).
    LocalNetwork,
    /// The team hub does not answer, so a relayed link cannot be made. Not sent yet: it needs
    /// the hub carrier's probe (carrier slice 3).
    HubDown,
    /// This machine's network works, and the peer (or its daemon) does not answer.
    PeerDown,
    /// The peer refused this daemon's token.
    Auth,
}

/// `_acpmux/peer_state_changed`, to every watching connection (`_acpmux/watch`) when a peer's
/// link changes (`link`, `carrier`, `cause` or `nextRetryAt`), never twice for the same one: a
/// peer that is added sends its first state, and one that is removed a last `offline` with
/// `error: "removed"`. Listed as the `peerStateEvents` feature.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "camelCase")]
#[schemars(transform = require_all)]
pub struct PeerStateChanged {
    /// The peer's name, as in `_acpmux/peers`.
    pub peer: String,
    /// `link` folded to the older five words, for an app that predates `link`.
    pub state: PeerLinkState,
    /// The link's whole state: what a surface draws.
    pub link: MachineLink,
    /// The carrier the open link runs over; null while none is open.
    pub carrier: Option<Carrier>,
    /// Why the link is down; null while it is up or on its way the first time.
    pub cause: Option<DownCause>,
    /// When `link` took its value, ms since the epoch.
    pub since: u64,
    /// When acpmux dials again on its own, ms since the epoch; null while it is not waiting.
    pub next_retry_at: Option<u64>,
    /// The last frame from the peer, ms since the epoch.
    pub last_seen: Option<u64>,
    /// Why the link is down, when it is.
    pub error: Option<String>,
    /// When the note was made, ms since the epoch.
    pub at: u64,
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Every whole state folds to exactly one older word, and the wire word is serde's.
    #[test]
    fn every_link_state_has_one_wire_word_and_one_folded_word() {
        for link in MachineLink::ALL {
            let word = serde_json::to_value(link).unwrap();
            assert_eq!(word, serde_json::json!(link.as_str()));
            let back: MachineLink = serde_json::from_value(word).unwrap();
            assert_eq!(back, link);
            let _ = link.folded();
        }
        assert_eq!(MachineLink::Restarting.folded(), PeerLinkState::Reconnecting);
        assert_eq!(MachineLink::AuthFailed.folded(), PeerLinkState::Offline);
    }
}
