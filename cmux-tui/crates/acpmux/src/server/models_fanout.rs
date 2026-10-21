//! The peers' harnesses in an `_acpmux/models` reply, labelled `peer/agent`.
//! Part of the request handler (`requests.rs`).
//!
//! Peers often list each other (huge-blue has cosmic-gray and cosmic-gray has
//! huge-blue). A reply that asked every peer for its full reply, whoever asked,
//! bounced between the two without end: every hop built a whole catalog and
//! held it while it waited up to the peer timeout, so one models read grew a
//! daemon by gigabytes within minutes. Now a peer is asked for its own
//! catalog only (`localOnly`); a peer's request, or one that says
//! `localOnly`, is answered from this daemon alone; and while this daemon
//! is asking its peers, a remote asker (an older peer that ignores
//! `localOnly` and asks back) gets this daemon's own catalog, which ends
//! the cycle when either side has this code.

use super::Origin;
use crate::hub::Hub;
use serde_json::{Value, json};
use std::sync::atomic::Ordering;
use std::time::Duration;

/// The param that asks a daemon for its own harnesses, without its peers'.
pub(crate) const LOCAL_ONLY: &str = "localOnly";

/// How long one peer may take to list its harnesses; a slow peer only
/// leaves its rows out.
const PEER_BUDGET: Duration = Duration::from_secs(10);

/// Whether a request from `origin` with `params` may ask the peers, given
/// that `in_flight` replies are asking them now.
fn asks_peers(origin: Origin, params: &Value, in_flight: usize) -> bool {
    if origin == Origin::Peer || params.get(LOCAL_ONLY).and_then(Value::as_bool) == Some(true) {
        return false;
    }
    matches!(origin, Origin::Local | Origin::LocalApp) || in_flight == 0
}

/// Counts one reply that is asking the peers, until it drops.
struct InFlight<'a>(&'a std::sync::atomic::AtomicUsize);
impl Drop for InFlight<'_> {
    fn drop(&mut self) {
        self.0.fetch_sub(1, Ordering::SeqCst);
    }
}

pub(super) async fn add_peer_harnesses(hub: &Hub, origin: Origin, params: &Value, cat: &mut Value) {
    if !asks_peers(origin, params, hub.models_fanouts.load(Ordering::SeqCst)) {
        return;
    }
    hub.models_fanouts.fetch_add(1, Ordering::SeqCst);
    let _in_flight = InFlight(&hub.models_fanouts);
    for peer in hub.connected_peers() {
        let asked = peer.request("_acpmux/models", json!({LOCAL_ONLY: true}));
        let Ok(Ok(remote)) = tokio::time::timeout(PEER_BUDGET, asked).await else { continue };
        let Some(hs) = remote.get("harnesses").and_then(Value::as_array) else { continue };
        let Some(arr) = cat.get_mut("harnesses").and_then(Value::as_array_mut) else { return };
        for h in hs {
            // An older peer may still have added its own peers' rows.
            if h.get("peer").is_some() {
                continue;
            }
            let mut h = h.clone();
            let agent = h.get("harness").and_then(Value::as_str).unwrap_or("").to_owned();
            h["harness"] = Value::String(format!("{}/{}", peer.name, agent));
            h["peer"] = Value::String(peer.name.clone());
            h["isDefault"] = Value::Bool(false);
            arr.push(h);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_peers_request_or_a_local_only_one_never_asks_the_peers() {
        assert!(!asks_peers(Origin::Peer, &json!({}), 0));
        for origin in [Origin::Local, Origin::LocalApp, Origin::Web] {
            assert!(!asks_peers(origin, &json!({LOCAL_ONLY: true}), 0));
        }
    }

    #[test]
    fn a_remote_asker_during_a_fan_out_gets_the_local_catalog() {
        assert!(asks_peers(Origin::Web, &json!({}), 0));
        assert!(!asks_peers(Origin::Web, &json!({}), 1));
        // This daemon's own clients are never part of a peer cycle.
        assert!(asks_peers(Origin::Local, &json!({}), 3));
        assert!(asks_peers(Origin::LocalApp, &json!({}), 3));
    }
}
