//! Who's here, machine-wide (`hub/here.rs`): `_acpmux/here/beat`, a client's heartbeat for its
//! person on one device, and `_acpmux/here`, every person and agent present now, with the agents
//! in a turn on this daemon folded in. In memory only, never in a log or an export.

use schemars::JsonSchema;
use serde::{Deserialize, Serialize};

use super::presence::AuthorMeta;
use super::require_all;

/// The kind of device a heartbeat comes from.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "camelCase")]
pub enum HereDeviceKind {
    Mac,
    Vm,
    Phone,
    Web,
    Other,
}

/// What the person on a device is doing, as its client sees it.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "camelCase")]
pub enum HereActivity {
    /// The app is in front; `idleMs` says how long since the last input.
    Present,
    /// The person is typing or driving a terminal.
    Working,
    /// The app is in the background, the screen locked or asleep.
    Away,
}

/// `_acpmux/here/beat`: send about every 10 s while the app runs (a beat lives 30 s) and once
/// with `leave` when it quits. At most 64 devices are held; `seq` grows per device, so a beat
/// that arrives late or twice changes nothing.
#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "camelCase")]
#[schemars(deny_unknown_fields)]
pub struct HereBeatParams {
    /// The device's stable id, one line of at most 128 bytes.
    pub device: String,
    pub device_kind: HereDeviceKind,
    pub seq: u64,
    pub activity: HereActivity,
    /// Milliseconds since the person's last input on this device.
    #[serde(default)]
    pub idle_ms: u64,
    /// The chats or workspaces the device shows; at most 16, each at most 256 bytes.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub scopes: Vec<String>,
    /// The device is going away: drop its beat now.
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub leave: bool,
    /// The person, when a peer forwards for one of its own; none is this machine's owner.
    #[serde(rename = "_meta", skip_serializing_if = "Option::is_none")]
    pub meta: Option<AuthorMeta>,
}

#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "camelCase")]
#[schemars(transform = require_all)]
pub struct HereBeatDone {
    /// Whether the beat changed what `_acpmux/here` answers.
    pub changed: bool,
}

/// `_acpmux/here`.
#[derive(Debug, Clone, Default, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "camelCase")]
#[schemars(deny_unknown_fields)]
pub struct HereParams {
    /// Only who shows this chat or workspace; agents match by session id.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub scope: Option<String>,
    /// Include acknowledgement state for peers this daemon has exchanged chat state with.
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub include_sync: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "camelCase")]
pub enum HereKind {
    Person,
    Agent,
}

/// Best first.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "camelCase")]
pub enum HereStatus {
    Active,
    Idle,
    Away,
}

#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "camelCase")]
#[schemars(transform = require_all)]
pub struct HereDevice {
    pub device: String,
    pub device_kind: HereDeviceKind,
    pub status: HereStatus,
    pub working: bool,
    /// Milliseconds since its last beat, on this daemon's clock.
    pub age_ms: u64,
}

/// One person or agent, across their devices.
#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "camelCase")]
#[schemars(transform = require_all)]
pub struct HereMember {
    /// `owner` for this machine's person, an author id for another, the session id for an agent.
    pub id: String,
    pub name: String,
    pub kind: HereKind,
    /// The best status across devices.
    pub status: HereStatus,
    /// Typing, driving a terminal, or (an agent) in a turn.
    pub working: bool,
    pub devices: Vec<HereDevice>,
}

#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct HereResult {
    /// Active first, then idle, then away; people before agents; then by name.
    pub here: Vec<HereMember>,
    /// Absent unless requested. Empty means no peer has exchanged yet, not globally synced.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub sync: Option<Vec<HereSyncPeer>>,
    /// What the sidebar's status icon shows (RFD 0140), reduced here so no client re-derives it.
    /// Present exactly when `sync` is.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub summary: Option<HereSummary>,
}

/// The sync state the status icon draws, most urgent first.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "camelCase")]
pub enum HereSyncState {
    /// No peer is connected and some have edits they have not acknowledged: they queue and merge on reconnect.
    Offline,
    /// A connected peer has not acknowledged every local edit yet.
    Syncing,
    /// Every connected peer acknowledged every local edit. A disconnected one can still have unseen offline edits.
    Synced,
    /// No peer has exchanged state yet: nothing to sync with.
    Alone,
}

/// `HereResult::summary`: the one sync state, the edits it counts, and who else is here.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "camelCase")]
#[schemars(transform = require_all)]
pub struct HereSummary {
    pub sync: HereSyncState,
    /// Offline: the most edits any peer is missing. Syncing: the most any connected peer is missing. Else 0.
    pub pending_edits: u64,
    /// People here besides this machine's own person.
    pub others: u32,
    /// Agents here, in a turn on this daemon or beating from elsewhere.
    pub agents: u32,
}

impl HereSummary {
    /// The reduction. Offline needs every peer down: a sleeping phone must not mark a Mac with a live VM offline.
    pub fn of(here: &[HereMember], sync: &[HereSyncPeer], own_id: &str) -> Self {
        let max = |it: &mut dyn Iterator<Item = &HereSyncPeer>| {
            it.map(|p| p.unacknowledged_edits).max().unwrap_or(0)
        };
        let (state, pending_edits) = if sync.is_empty() {
            (HereSyncState::Alone, 0)
        } else if !sync.iter().any(|p| p.connected) {
            let n = max(&mut sync.iter());
            (if n > 0 { HereSyncState::Offline } else { HereSyncState::Synced }, n)
        } else {
            let n = max(&mut sync.iter().filter(|p| p.connected));
            let behind =
                sync.iter().any(|p| p.connected && (!p.acknowledged || p.unacknowledged_edits > 0));
            (if behind { HereSyncState::Syncing } else { HereSyncState::Synced }, n)
        };
        let count = |kind: HereKind| {
            here.iter().filter(|m| m.kind == kind && m.id != own_id).count() as u32
        };
        Self {
            sync: state,
            pending_edits,
            others: count(HereKind::Person),
            agents: count(HereKind::Agent),
        }
    }
}

/// A peer's last acknowledged chat-state vector, separate from its current connectivity.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "camelCase")]
#[schemars(transform = require_all)]
pub struct HereSyncPeer {
    pub peer: String,
    pub connected: bool,
    /// Both vectors were equal at this read. A disconnected peer can still have new offline edits.
    pub acknowledged: bool,
    /// Local edit sequences not covered by the peer's last acknowledgement; not a chunk count.
    pub unacknowledged_edits: u64,
}
