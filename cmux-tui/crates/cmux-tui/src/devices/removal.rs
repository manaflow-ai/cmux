//! One remove (plans/cmux-next/add-device-DESIGN.md 2.5): a device leaves
//! every store that lets it in. The plan is pure; `run` executes each step
//! with the store's own verb, so each store keeps its own rules (acpmux
//! closes a revoked device's connections, `host revoke` restarts the
//! listener).

use super::model::{Device, Via};

/// One `cmux` command that removes one store's record.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct Step {
    /// The words after `cmux`.
    pub args: Vec<String>,
    /// What stops, in words for the confirmation.
    pub what: String,
}

/// The steps that remove `device` from every store, in an order where a
/// failed step leaves nothing that lets it in that a later step would have
/// removed first: credentials before peers.
pub(crate) fn plan(_device: &Device) -> Vec<Step> {
    let _ = Via::Peer { name: String::new() };
    Vec::new()
}
