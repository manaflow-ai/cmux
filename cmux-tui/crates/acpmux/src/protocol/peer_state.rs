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

/// Why a peer's route last went down (`downReason`): what the failed dial or the dropped path
/// ran into, typed from the error that raised it (an `io::ErrorKind`, an HTTP status, ssh's
/// failure class), never guessed from its text. When every path of a cold connect failed with
/// different kinds, the one a person can act on first is kept ([`DialFail::rank`]). Null
/// before any route went down, or when no failure so far had a type.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "camelCase")]
pub enum DialFail {
    /// The dial or its upgrade ran past its deadline.
    Timeout,
    /// The machine answered and refused the connection (nothing listens there).
    Refused,
    /// The peer refused this daemon's token or this computer's ssh login.
    Auth,
    /// The path carrying the link died while another answered: the link moved there.
    PathChanged,
    /// No route to the machine: the network or host is unreachable, or its name did not
    /// resolve.
    Unreachable,
}

impl DialFail {
    /// Every kind, in the order of the enum: a renderer's table test walks it.
    pub const ALL: [Self; 5] =
        [Self::Timeout, Self::Refused, Self::Auth, Self::PathChanged, Self::Unreachable];

    /// Its wire word (`downReason`).
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Timeout => "timeout",
            Self::Refused => "refused",
            Self::Auth => "auth",
            Self::PathChanged => "pathChanged",
            Self::Unreachable => "unreachable",
        }
    }

    /// Which of several paths' failures names the connect's: a refused token or login first
    /// (a person must act), then a refusal, no route, a timeout (the least telling: a slow
    /// path and a dead one look the same).
    pub fn rank(self) -> u8 {
        match self {
            Self::Auth => 0,
            Self::Refused => 1,
            Self::Unreachable => 2,
            Self::Timeout => 3,
            Self::PathChanged => 4,
        }
    }
}

/// `downReason` as this build reads it: a word it does not know is null, never a refused note.
fn known_dial_fail<'de, D: serde::Deserializer<'de>>(
    deserializer: D,
) -> Result<Option<DialFail>, D::Error> {
    let word = Option::<serde_json::Value>::deserialize(deserializer)?;
    Ok(word.and_then(|word| serde_json::from_value(word).ok()))
}

/// What a dial writes first in its error when it could get no relay ticket (`hub_carrier.rs`):
/// the platform's ticket mint refused or did not answer. `credential-unavailable`.
pub const CREDENTIAL_UNAVAILABLE: &str = "credential-unavailable:";

/// Why a down link is `offline` and what a person does about it (`reason`): a terminal named
/// state, so a link that cannot heal on its own never reads as still connecting (design
/// `remote-cloud-durability.md` 4.3, handbook `connection-state-with-no-action-or-bound`).
/// Attempts go on behind it (`nextRetryAt`, hourly once parked); the reason only makes the
/// reported state true. Each has one [`OfflineAction`].
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "kebab-case")]
pub enum OfflineReason {
    /// No relay ticket or credential can be had: the ticket mint is down, or renewing an
    /// expiring ticket failed.
    CredentialUnavailable,
    /// The machine (or its Cloud VM) is stopped on purpose, not crashed.
    MachineStopped,
    /// The peer refused this daemon's token: a person must sign in again (`authFailed`).
    LoginNeeded,
    /// The machine's daemon stopped restarting after more stops than its budget allows.
    RestartBudgetExceeded,
    /// The machine's disk is full.
    DiskFull,
}

/// The one thing a person does about an [`OfflineReason`] (`action`).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "kebab-case")]
pub enum OfflineAction {
    /// Ask for a fresh ticket now (`_acpmux/peer_reconnect`).
    Reconnect,
    /// Start the machine.
    StartMachine,
    /// Sign in again.
    SignIn,
    /// Restart the machine's daemon by hand (its budget then starts over).
    RestartDaemon,
    /// Free space on the machine's disk.
    FreeDisk,
}

impl OfflineReason {
    /// Every reason, in the order of the enum: a renderer's table test walks it.
    pub const ALL: [Self; 5] = [
        Self::CredentialUnavailable,
        Self::MachineStopped,
        Self::LoginNeeded,
        Self::RestartBudgetExceeded,
        Self::DiskFull,
    ];

    pub fn action(self) -> OfflineAction {
        match self {
            Self::CredentialUnavailable => OfflineAction::Reconnect,
            Self::MachineStopped => OfflineAction::StartMachine,
            Self::LoginNeeded => OfflineAction::SignIn,
            Self::RestartBudgetExceeded => OfflineAction::RestartDaemon,
            Self::DiskFull => OfflineAction::FreeDisk,
        }
    }

    /// Its wire word (`reason`).
    pub fn as_str(self) -> &'static str {
        match self {
            Self::CredentialUnavailable => "credential-unavailable",
            Self::MachineStopped => "machine-stopped",
            Self::LoginNeeded => "login-needed",
            Self::RestartBudgetExceeded => "restart-budget-exceeded",
            Self::DiskFull => "disk-full",
        }
    }
}

/// `_acpmux/peer_state_changed`, to every watching connection (`_acpmux/watch`) when a peer's
/// link changes (`link`, `carrier`, `cause`, `reason`, `downReason` or `nextRetryAt`), never twice for the same one: a
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
    /// Why a down link is `offline` (or `authFailed`) and will not heal by retrying alone;
    /// null otherwise. Attempts still go on (`nextRetryAt`).
    #[serde(default)]
    pub reason: Option<OfflineReason>,
    /// What a person does about `reason`; null when there is none.
    #[serde(default)]
    pub action: Option<OfflineAction>,
    /// Why the route last went down (a failed dial, or a path that died while another
    /// answered); null before any did, or when no failure so far had a type. Kept while the
    /// link is up again, so a surface can say why it moved. A word this build does not know (a
    /// newer daemon's) reads as null, so the rest of the note still lands.
    #[serde(default, deserialize_with = "known_dial_fail")]
    pub down_reason: Option<DialFail>,
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

    /// Every down reason's wire word is serde's, and a note without one (an older daemon's)
    /// still parses.
    #[test]
    fn every_down_reason_has_one_wire_word() {
        for fail in DialFail::ALL {
            assert_eq!(serde_json::to_value(fail).unwrap(), fail.as_str());
        }
        let mut note = serde_json::to_value(PeerStateChanged {
            peer: "b".into(),
            state: PeerLinkState::Reconnecting,
            link: MachineLink::Reconnecting,
            carrier: None,
            cause: Some(DownCause::PeerDown),
            since: 1,
            next_retry_at: None,
            reason: None,
            action: None,
            down_reason: Some(DialFail::PathChanged),
            last_seen: None,
            error: None,
            at: 2,
        })
        .unwrap();
        assert_eq!(note["downReason"], "pathChanged");
        note.as_object_mut().unwrap().remove("downReason");
        let older: PeerStateChanged = serde_json::from_value(note.clone()).unwrap();
        assert_eq!(older.down_reason, None);
        // A newer daemon's word this build does not know: the note still parses.
        note["downReason"] = "proxyBlocked".into();
        let newer: PeerStateChanged = serde_json::from_value(note).unwrap();
        assert_eq!(newer.down_reason, None);
        assert_eq!(newer.state, PeerLinkState::Reconnecting);
    }

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

    /// Every reason has one wire word (the design's kebab-case words) and its own action.
    #[test]
    fn every_offline_reason_has_one_wire_word_and_an_action() {
        let mut actions = std::collections::HashSet::new();
        for reason in OfflineReason::ALL {
            let word = serde_json::to_value(reason).unwrap();
            assert_eq!(word, serde_json::json!(reason.as_str()));
            assert_eq!(serde_json::from_value::<OfflineReason>(word).unwrap(), reason);
            assert!(actions.insert(reason.action()), "{reason:?} shares its action");
        }
        assert_eq!(
            serde_json::to_value(OfflineReason::CredentialUnavailable.action()).unwrap(),
            serde_json::json!("reconnect")
        );
    }
}
