//! What a client said it understands, in its `initialize` params (`_meta.acpmux.features`: the
//! feature ids of `peer::PEER_FEATURES` and the capability ids of `capabilities::CAPABILITIES` it
//! reads). A gated notification goes to a connection only once it listed the gate.
//!
//! A client that sends no `features` key predates the list: it keeps hearing every notification
//! this daemon sent before the list existed (the NIGHTLY's Swift app and web panes, and older peer
//! links, list nothing yet and rely on them). A client that sends the key hears only what it
//! listed. A notification added from now on is gated on its own id with no such fallback.

use serde_json::Value;
use std::collections::BTreeSet;
use std::sync::Mutex;

/// `_acpmux/unsent {sessionId, seq}` (`server/mod.rs`): a record this daemon did not send a
/// peer daemon's link, so its copy of the chat continues past it (`hub/peer_snapshot.rs`).
pub const UNSENT_FEATURE: &str = "unsentSeq";

/// The `initialize` params key a client lists its features in.
pub const FIELD: &str = "features";

#[derive(Default)]
pub(crate) struct ClientFeatures(Mutex<Option<BTreeSet<String>>>);

impl ClientFeatures {
    /// Reads `initialize` params: the list, or none when the key is absent or not a list.
    pub(crate) fn note(&self, params: &Value) {
        let listed = params.pointer(&format!("/_meta/acpmux/{FIELD}")).and_then(Value::as_array);
        let listed =
            listed.map(|ids| ids.iter().filter_map(Value::as_str).map(str::to_owned).collect());
        *self.0.lock().unwrap_or_else(std::sync::PoisonError::into_inner) = listed;
    }

    /// Whether this client may be sent a notification gated by any of `ids`: it listed one, or it
    /// sent no list (a client from before the list, which hears what it always heard).
    pub(crate) fn hears_any(&self, ids: &[&str]) -> bool {
        match &*self.0.lock().unwrap_or_else(std::sync::PoisonError::into_inner) {
            None => true,
            Some(listed) => ids.iter().any(|id| listed.contains(*id)),
        }
    }

    /// Whether this client sent a `features` list at all.
    #[cfg(test)]
    pub(crate) fn listed(&self) -> bool {
        self.0.lock().unwrap_or_else(std::sync::PoisonError::into_inner).is_some()
    }
}

/// What this build understands, as its own peer link lists it in `initialize`: every feature and
/// capability id its daemon would list.
pub fn own() -> Vec<&'static str> {
    let mut ids: Vec<&'static str> = crate::peer::PEER_FEATURES.iter().map(|f| f.id).collect();
    ids.extend(crate::capabilities::ids());
    ids.sort_unstable();
    ids.dedup();
    ids
}

#[cfg(test)]
#[path = "client_features_tests.rs"]
mod tests;
