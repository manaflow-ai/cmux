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
//!
//! A queue reply's `total` counts the items before the `limit` cut, a peer's own cut included, so
//! a page can say more wait. A verdict of `changes` may carry a `comment`: kept in the audit entry
//! and sent to the chat as a prompt, under the folder's trust rule both when it is sent and when a
//! queued one is dispatched. `commentDelivered` says the chat accepted it (queued or started).

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
    // Items a peer counted but cut at the same `limit` before it answered.
    let mut peers_cut = 0usize;
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
            peers_cut += peer_cut(&remote, list.len());
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
    // How many there were before the cut, so a page showing `limit` can say more wait: a peer's
    // own cut counts too.
    let total = items.len() + peers_cut;
    sort_items(&mut items, limit);
    let mut out = json!({"items": items, "now": now, "total": total});
    if !omitted.is_empty() {
        omitted.sort();
        out.set(PEERS_OMITTED, json!(omitted));
    }
    Ok(out)
}

/// How many items a peer counted (its `total`) beyond the `sent` it answered with: cut at the same
/// limit before this daemon saw them. A peer that sends no `total` (an older daemon) cut nothing
/// this daemon can know of.
fn peer_cut(remote: &Value, sent: usize) -> usize {
    let reported = remote.get("total").and_then(Value::as_u64).unwrap_or(0);
    usize::try_from(reported).unwrap_or(usize::MAX).saturating_sub(sent)
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
    let comment = review_comment(params, accepted)?;
    let session = hub.resolve(session_id)?;
    let sid = session.id.clone();
    // The comment goes to the chat as a prompt: the folder's trust rule holds for it as for
    // any prompt, checked before the verdict is recorded so a refusal records nothing.
    let prompt = comment.as_deref().map(|c| changes_prompt(url, c));
    if let Some(text) = &prompt {
        let prompt_params = json!({"sessionId": sid, "prompt": [{"type": "text", "text": text}]});
        super::trust_gate::check(
            hub,
            origin,
            method::SESSION_PROMPT,
            &prompt_params,
            Some(&session),
        )
        .await?;
    }
    let (h, s, u, from_app) =
        (hub.clone(), session.clone(), url.to_owned(), origin == Origin::LocalApp);
    // The verdict answers once its audit line is on disk.
    let entry = tokio::task::spawn_blocking(move || {
        h.record_review_verdict(&s, &u, accepted, comment.as_deref(), from_app)
    })
    .await
    .map_err(|e| RpcError::internal(e.to_string()))??;
    // Then the chat gets the comment, after any turn it is running. The reply waits only until
    // the prompt is accepted (queued or started) or refused, and says which.
    let mut delivered = false;
    if let Some(text) = prompt {
        let (tx, rx) = tokio::sync::oneshot::channel::<bool>();
        let tx = Arc::new(std::sync::Mutex::new(Some(tx)));
        let send = move |ok: bool| {
            if let Some(tx) = tx.lock().ok().and_then(|mut t| t.take()) {
                let _ = tx.send(ok);
            }
        };
        let (accepted, refused) = (send.clone(), send);
        let opts = crate::hub::PromptOptions {
            // A comment that waits behind a running turn meets the folder's trust rule again
            // when it is dispatched, as the app's own prompt does.
            trust_gate: super::trust_gate::gated(origin, params),
            on_accepted: Some(Box::new(move |_| accepted(true))),
            ..Default::default()
        };
        let hub = hub.clone();
        tokio::spawn(async move {
            let blocks = vec![json!({"type": "text", "text": text})];
            if let Err(e) = hub.prompt_with(&session, blocks, "review", false, opts).await {
                tracing::warn!(session = %session.id, "review: the comment was not delivered: {e}");
            }
            refused(false);
        });
        delivered =
            tokio::time::timeout(ACCEPT_WAIT, rx).await.ok().and_then(Result::ok) == Some(true);
    }
    Ok(json!({"recorded": true, "sessionId": sid, "prUrl": url, "entry": entry,
              "commentDelivered": delivered}))
}

/// How long a verdict's reply waits for its comment's prompt to be accepted; past it the reply
/// says not delivered, and the page opens the chat.
const ACCEPT_WAIT: Duration = Duration::from_secs(10);

/// The most bytes a Request changes comment may have.
const COMMENT_BYTES: usize = 16 * 1024;

/// A verdict's optional `comment`: only with `changes`, nonempty once trimmed, at most
/// [`COMMENT_BYTES`].
fn review_comment(params: &Value, accepted: bool) -> Result<Option<String>, RpcError> {
    let comment = match params.get("comment") {
        None | Some(Value::Null) => return Ok(None),
        Some(Value::String(s)) => s.trim(),
        Some(_) => return Err(RpcError::invalid_params("comment must be a string")),
    };
    if comment.is_empty() {
        return Ok(None);
    }
    if accepted {
        return Err(RpcError::invalid_params("a comment goes with verdict changes only"));
    }
    if comment.len() > COMMENT_BYTES {
        return Err(RpcError::invalid_params(format!(
            "comment must be at most {COMMENT_BYTES} bytes"
        )));
    }
    Ok(Some(comment.to_owned()))
}

/// The prompt a Request changes comment reaches the chat as.
fn changes_prompt(url: &str, comment: &str) -> String {
    format!("Changes requested on {url}:\n\n{comment}")
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
    fn a_comment_goes_with_changes_only_and_is_bounded() {
        let p = |c: Value| json!({"comment": c});
        assert_eq!(review_comment(&json!({}), false).unwrap(), None);
        assert_eq!(review_comment(&p(json!("  ")), false).unwrap(), None);
        assert_eq!(
            review_comment(&p(json!(" Add a test. ")), false).unwrap().as_deref(),
            Some("Add a test.")
        );
        assert!(review_comment(&p(json!("Nice")), true).is_err());
        assert!(review_comment(&p(json!(3)), false).is_err());
        assert!(review_comment(&p(json!("x".repeat(COMMENT_BYTES + 1))), false).is_err());
        assert_eq!(
            changes_prompt("https://github.com/o/r/pull/7", "Add a test."),
            "Changes requested on https://github.com/o/r/pull/7:\n\nAdd a test."
        );
    }

    #[test]
    fn a_peers_own_cut_counts_in_the_total() {
        assert_eq!(peer_cut(&json!({"items": [], "total": 250}), 200), 50);
        assert_eq!(peer_cut(&json!({"items": []}), 200), 0);
        assert_eq!(peer_cut(&json!({"total": 3}), 3), 0);
        assert_eq!(peer_cut(&json!({"total": "many"}), 3), 0);
    }

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
