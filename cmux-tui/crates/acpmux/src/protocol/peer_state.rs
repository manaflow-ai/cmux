//! `_acpmux/peer_state_changed`: a peer link's state, pushed to every watching connection on
//! each change (`peer.rs` `report_states`), so a client never polls `_acpmux/peers` for it.

use schemars::JsonSchema;
use serde::{Deserialize, Serialize};

use super::require_all;

/// A peer link's state (`peer_link.rs` `PeerState`; `state` in `_acpmux/peers`).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "lowercase")]
pub enum PeerLinkState {
    /// Not reached yet, this run or a saved one.
    Connecting,
    /// The handshake finished and the peer answers.
    Connected,
    /// The WebSocket is open and the handshake runs, or a ping went unanswered.
    Degraded,
    /// Down after it was reached; its last-known sessions stay listed. Attempts go on.
    Reconnecting,
    /// Never reached and attempts failed, or removed (`error: "removed"`, its last note).
    Offline,
}

/// `_acpmux/peer_state_changed`, to every watching connection (`_acpmux/watch`) when a peer's
/// state changes, never twice for the same state: a peer that is added sends its first state,
/// and one that is removed a last `offline` with `error: "removed"`. Listed as the
/// `peerStateEvents` feature.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "camelCase")]
#[schemars(transform = require_all)]
pub struct PeerStateChanged {
    /// The peer's name, as in `_acpmux/peers`.
    pub peer: String,
    pub state: PeerLinkState,
    /// The last frame from the peer, ms since the epoch.
    pub last_seen: Option<u64>,
    /// Why the link is down, when it is.
    pub error: Option<String>,
    /// When the state changed, ms since the epoch.
    pub at: u64,
}
