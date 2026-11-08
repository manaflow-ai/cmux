//! `_acpmux/review_queue`, `_acpmux/review_verdict` and `_acpmux/audit` (`hub/review_queue.rs`,
//! `hub/audit_log.rs`). What waits on the person and what they answered is their data, like the
//! stats: the local unix socket and the local app get it, a peer daemon gets this daemon's own
//! queue only (never its peers'), and the Web gets "Method not found".
//!
//! A queue read from the local socket or the app asks each connected peer once, at the same
//! time, for its own queue (`localOnly`), within [`PEERS_BUDGET`]; a peer's items carry `host`
//! (its name), and a peer that did not answer in time (or has no queue: an older daemon) is
//! named in `peersOmitted`. A peer's request, or one that says `localOnly`, is answered from this
//! daemon alone, so two daemons that list each other ask each other once and never in a cycle
//! (the `_acpmux/models` rule, `models_fanout.rs`).

use cmux_json::JsonSet as _;
use std::sync::Arc;
use std::time::Duration;

use serde_json::{Value, json};

use super::Origin;
use super::models_fanout::LOCAL_ONLY;
use crate::hub::Hub;
use crate::hub::audit_log::Query;
use crate::hub::review_queue::{DEFAULT_LIMIT, MAX_LIMIT, sort_items};
use crate::rpc::{RpcError, method};

/// How long the peers together may take to answer a queue read.
// timeout: a peer that misses it is named in peersOmitted; the local queue still answers.
const PEERS_BUDGET: Duration = Duration::from_secs(5);

/// The reply field naming the peers whose items are not in it.
pub(crate) const PEERS_OMITTED: &str = "peersOmitted";

/// Whether a read from `origin` with `params` asks the peers.
fn asks_peers(origin: Origin, params: &Value) -> bool {
    matches!(origin, Origin::Local | Origin::LocalApp)
        && params.get(LOCAL_ONLY).and_then(Value::as_bool) != Some(true)
}

fn local_only(origin: Origin, m: &str) -> Result<(), RpcError> {
    match origin {
        Origin::Local | Origin::LocalApp => Ok(()),
        _ => Err(RpcError::method_not_found(m)),
    }
}

/// The methods this module answers, by name; None for any other.
pub(super) async fn route(
    hub: &Arc<Hub>,
    origin: Origin,
    auth: super::ConnAuth,
    person: bool,
    m: &str,
    params: &Value,
) -> Option<Result<Value, RpcError>> {
    Some(match m {
        method::MUX_REVIEW_QUEUE => queue(hub, origin, auth, params).await,
        method::MUX_REVIEW_VERDICT => verdict(hub, origin, person, params).await,
        method::MUX_AUDIT => audit(hub, origin, params).await,
        _ => return None,
    })
}

/// Whether the queue is served to this caller: never to a Web client, nor to one a peer
/// forwards for its Web client (`via: web`) or an unauthenticated connection.
fn queue_served(origin: Origin, auth: super::ConnAuth, params: &Value) -> bool {
    super::remote_guard::control_of(origin, auth, params) != crate::hub::Control::Web
}

async fn queue(
    hub: &Arc<Hub>,
    origin: Origin,
    auth: super::ConnAuth,
    params: &Value,
) -> Result<Value, RpcError> {
    if !queue_served(origin, auth, params) {
        return Err(RpcError::method_not_found(method::MUX_REVIEW_QUEUE));
    }
    let limit = match params.get("limit") {
        None | Some(Value::Null) => DEFAULT_LIMIT,
        Some(v) => v
            .as_u64()
            .ok_or_else(|| RpcError::invalid_params("limit must be a number"))?
            .clamp(1, MAX_LIMIT as u64) as usize,
    };
    let now = crate::store::now_ms();
    let (mut items, _) = hub.review_queue_local(now);
    let mut omitted: Vec<String> = Vec::new();
    if asks_peers(origin, params) {
        let deadline = tokio::time::Instant::now() + PEERS_BUDGET;
        let peers = hub.connected_peers();
        let ask = json!({LOCAL_ONLY: true, "limit": limit});
        let replies = futures::future::join_all(peers.iter().map(|peer| {
            tokio::time::timeout_at(deadline, peer.request(method::MUX_REVIEW_QUEUE, ask.clone()))
        }))
        .await;
        for (peer, reply) in peers.iter().zip(replies) {
            let Some(remote) = reply.ok().and_then(Result::ok) else {
                omitted.push(peer.name.clone());
                continue;
            };
            let Some(list) = remote.get("items").and_then(Value::as_array) else {
                omitted.push(peer.name.clone());
                continue;
            };
            for item in list {
                // An item already marked as another machine's is that peer's peer's: left out.
                if !item.is_object() || item.get("host").is_some() {
                    continue;
                }
                let mut item = item.clone();
                item.set("host", json!(peer.name));
                items.push(item);
            }
        }
    }
    sort_items(&mut items, limit);
    let mut out = json!({"items": items, "now": now});
    if !omitted.is_empty() {
        omitted.sort();
        out.set(PEERS_OMITTED, json!(omitted));
    }
    Ok(out)
}

async fn verdict(
    hub: &Arc<Hub>,
    origin: Origin,
    person: bool,
    params: &Value,
) -> Result<Value, RpcError> {
    local_only(origin, method::MUX_REVIEW_VERDICT)?;
    if !person {
        return Err(crate::hub::person::person_required("a review verdict"));
    }
    let text = |k: &str| {
        params
            .get(k)
            .and_then(Value::as_str)
            .filter(|s| !s.is_empty())
            .ok_or_else(|| RpcError::invalid_params(format!("{k} is required")))
    };
    let (session_id, url, verdict) = (text("sessionId")?, text("prUrl")?, text("verdict")?);
    let accepted = match verdict {
        "accepted" => true,
        "changes" => false,
        _ => return Err(RpcError::invalid_params("verdict must be accepted or changes")),
    };
    let session = hub.resolve(session_id)?;
    let sid = session.id.clone();
    let (h, u, from_app) = (hub.clone(), url.to_owned(), origin == Origin::LocalApp);
    // The verdict answers once its audit line is on disk.
    let entry = tokio::task::spawn_blocking(move || {
        h.record_review_verdict(&session, &u, accepted, from_app)
    })
    .await
    .map_err(|e| RpcError::internal(e.to_string()))??;
    Ok(json!({"recorded": true, "sessionId": sid, "prUrl": url, "entry": entry}))
}

async fn audit(hub: &Arc<Hub>, origin: Origin, params: &Value) -> Result<Value, RpcError> {
    local_only(origin, method::MUX_AUDIT)?;
    let q = Query::from_params(params).map_err(RpcError::invalid_params)?;
    let hub = Arc::clone(hub);
    // Reads the file: off the runtime.
    tokio::task::spawn_blocking(move || hub.audit.page(&q))
        .await
        .map_err(|e| RpcError::internal(e.to_string()))?
        .map_err(|e| RpcError::internal(format!("audit: {e}")))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_this_daemons_own_clients_ask_the_peers() {
        assert!(asks_peers(Origin::Local, &json!({})));
        assert!(asks_peers(Origin::LocalApp, &json!({})));
        assert!(!asks_peers(Origin::Local, &json!({LOCAL_ONLY: true})));
        assert!(!asks_peers(Origin::Peer, &json!({})));
        assert!(!asks_peers(Origin::Web, &json!({})));
    }

    #[test]
    fn the_queue_is_never_a_web_clients_even_through_a_peer() {
        use super::super::ConnAuth;
        let web = json!({"_meta": {"acpmux": {"via": "web"}}});
        assert!(!queue_served(Origin::Peer, ConnAuth::PeerToken, &web));
        assert!(!queue_served(Origin::Peer, ConnAuth::Device, &web));
        assert!(!queue_served(Origin::Web, ConnAuth::ListenerToken, &json!({})));
        assert!(!queue_served(Origin::Local, ConnAuth::None, &json!({})));
        assert!(queue_served(Origin::Peer, ConnAuth::PeerToken, &json!({})));
        assert!(queue_served(Origin::Local, ConnAuth::LocalSocket, &json!({})));
        assert!(queue_served(Origin::LocalApp, ConnAuth::LocalApp, &json!({})));
    }

    #[test]
    fn the_audit_and_verdicts_are_local_only() {
        assert!(local_only(Origin::Local, "m").is_ok());
        assert!(local_only(Origin::LocalApp, "m").is_ok());
        assert!(local_only(Origin::Peer, "m").is_err());
        assert!(local_only(Origin::Web, "m").is_err());
    }
}
