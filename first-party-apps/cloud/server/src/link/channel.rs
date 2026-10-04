//! The link supervisor's carrier and its events. These are Cloud types, not
//! interface types: the connector (`crate::connector`) maps them to the
//! shared `cmux.terminal.connector/1` shapes (`cmux-terminal-iface`).

use std::path::PathBuf;

/// The byte carrier to the far session host. Until the app host passes a
/// stream (or a socketpair fd), this is the local socket of the link
/// process (owner-only directory).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Carrier {
    /// The channel: `<kind>/<target>#<generation>`; a new one after every reconnect.
    pub id: String,
    pub target: String,
    pub generation: u64,
    pub socket: PathBuf,
}

/// The channel id of the link to `target` of `generation` (`cloud-vm/<target>#<generation>`).
pub fn channel_id(kind: &str, target: &str, generation: u64) -> String {
    format!("{kind}/{target}#{generation}")
}

/// Link supervisor events (the serve loop sends them as
/// `cloud.link.changed`; the connector maps them to `end`).
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum CarrierEvent {
    Up {
        carrier: Carrier,
    },
    /// The link ended. `opened`: it was up, so a connect answered its
    /// channel (false: a connect that failed before the ready line).
    Down {
        target: String,
        generation: u64,
        retryable: bool,
        reason: String,
        opened: bool,
    },
    /// Access to `target` ended. `generation`: the up link (open channel)
    /// this ended, `None` when no link was up.
    Revoked {
        target: String,
        reason: String,
        generation: Option<u64>,
    },
}
