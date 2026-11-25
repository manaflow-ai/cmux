//! Why this machine's own carrier registration cannot heal by retrying alone (split out of
//! `hub_carrier.rs`).

use super::HubCarrier;
use crate::protocol::peer_state::OfflineReason;

impl HubCarrier {
    /// Why this machine cannot be reached through the carrier and will not be until something
    /// changes (`credential-unavailable` while no Register ticket comes), or None. Registering
    /// goes on behind it; `_acpmux/machine_routes` carries it as `carrierReason`.
    pub fn serve_reason(&self) -> Option<OfflineReason> {
        *self.serve_reason.read().unwrap_or_else(|e| e.into_inner())
    }

    pub(super) fn set_serve_reason(&self, reason: Option<OfflineReason>) {
        let mut held = self.serve_reason.write().unwrap_or_else(|e| e.into_inner());
        if *held != reason {
            match reason {
                Some(reason) => tracing::warn!(
                    "hub carrier: {}: no Register ticket; registering goes on behind it",
                    reason.as_str()
                ),
                None => tracing::info!("hub carrier: registered"),
            }
        }
        *held = reason;
    }
}
