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
use crate::no_panic::JsonExt;
use serde_json::{Value, json};
use std::sync::atomic::Ordering;
use std::time::Duration;

/// The param that asks a daemon for its own harnesses, without its peers'.
pub(crate) const LOCAL_ONLY: &str = "localOnly";

/// How long the peers together may take to list their harnesses (they are
/// asked at once); a peer that is not done by then only leaves its rows out.
const PEERS_BUDGET: Duration = Duration::from_secs(10);

/// The reply field that says the peers' harnesses were left out because
/// this daemon was already asking its peers (a remote asker in a cycle).
pub(crate) const PEERS_OMITTED: &str = "peersOmitted";

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
    if !asks_peers(origin, params, 0) {
        return;
    }
    // Counted before the check, so two askers that arrive together cannot
    // both see none in flight; the guard undoes it on every path.
    let in_flight = hub.models_fanouts.fetch_add(1, Ordering::SeqCst);
    let _in_flight = InFlight(&hub.models_fanouts);
    if !asks_peers(origin, params, in_flight) {
        cat.set(PEERS_OMITTED, Value::Bool(true));
        return;
    }
    let deadline = tokio::time::Instant::now() + PEERS_BUDGET;
    let peers = hub.connected_peers();
    let replies = futures::future::join_all(peers.iter().map(|peer| {
        tokio::time::timeout_at(deadline, peer.request("_acpmux/models", json!({LOCAL_ONLY: true})))
    }))
    .await;
    let Some(arr) = cat.get_mut("harnesses").and_then(Value::as_array_mut) else { return };
    for (peer, reply) in peers.iter().zip(replies) {
        let Ok(Ok(remote)) = reply else { continue };
        let Some(hs) = remote.get("harnesses").and_then(Value::as_array) else { continue };
        for h in hs {
            // An older peer may still have added its own peers' rows.
            // A row that is not an object cannot be marked as the peer's: leave it out.
            if h.get("peer").is_some() || !h.is_object() {
                continue;
            }
            let mut h = h.clone();
            let agent = h.get("harness").and_then(Value::as_str).unwrap_or("").to_owned();
            h.set("harness", Value::String(format!("{}/{}", peer.name, agent)));
            h.set("peer", Value::String(peer.name.clone()));
            h.set("isDefault", Value::Bool(false));
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
