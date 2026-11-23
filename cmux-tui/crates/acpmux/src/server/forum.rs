//! The forum methods (`hub/forum.rs`), routed before peer forwarding
//! (`chats.rs`): the log lives on this daemon.
//!
//! - `_acpmux/forum/announce {key, body, topic?, urgent?, retire?, account?}`:
//!   the person (the proven app; `account` names them, else the OS user) or an
//!   agent session proven by its caller token. A request field never names an
//!   agent author.
//! - `_acpmux/forum/rules`: the current rules, with deliveries and acks.
//! - `_acpmux/forum/ack {postId}`: the calling session has read the post.
//! - `_acpmux/forum/post {space, title, body, kind?, labels?}`,
//!   `_acpmux/forum/reply {thread, body}`, `_acpmux/forum/search {query, space?}`: the
//!   team's hosted forum (`hub/forum_hosted.rs`), as the calling session (its caller token).
//! - `_acpmux/forum/digest {space, ack?, since?, areas?, budget?}` and
//!   `_acpmux/forum/digest_act {space, item, action}`: this Mac's person's digest of the team
//!   feed, and what they did with an item of it (`hub/forum_hosted.rs`).
//!
//! Web and peer connections are refused: rules are for this Mac's sessions.

use super::{Conn, str_param};
use crate::forum::{Author, MAX_KEY_BYTES};
use crate::hub::Hub;
use crate::hub::forum::AnnounceRequest;
use crate::hub::forum_hosted::{DigestActRequest, DigestRequest, PostRequest};
use crate::rpc::{RpcError, method};
use serde_json::{Value, json};
use std::sync::Arc;

/// The reply to a forum method, or None for any other method.
pub(super) async fn dispatch(
    hub: &Arc<Hub>,
    conn: &Arc<Conn>,
    m: &str,
    params: &Value,
) -> Option<Result<Value, RpcError>> {
    if !m.starts_with("_acpmux/forum/") {
        return None;
    }
    if conn.origin.web_class() {
        return Some(Err(RpcError::method_not_found(&format!("{m} (this Mac only)"))));
    }
    Some(handle(hub, conn, m, params).await)
}

fn author_required() -> RpcError {
    RpcError::invalid_params(
        "forum posts come from the person (the cmux app) or an agent session proven by its caller token (its cmux-forum MCP server, or the acpmux CLI inside the session)",
    )
    .with_data(json!({"reason": "forum.author_required"}))
}

/// The person's account: the one the app names, else the OS user.
fn account(params: &Value) -> Result<String, RpcError> {
    let named = str_param(params, "account").map(str::trim).filter(|a| !a.is_empty());
    let account = match named {
        Some(a) => a.to_owned(),
        None => std::env::var("USER")
            .or_else(|_| std::env::var("USERNAME"))
            .unwrap_or_else(|_| "person".to_owned()),
    };
    if account.len() > MAX_KEY_BYTES || account.contains(['\n', '\r']) {
        return Err(RpcError::invalid_params(format!(
            "account must be one line of at most {MAX_KEY_BYTES} bytes"
        )));
    }
    Ok(account)
}

async fn handle(
    hub: &Arc<Hub>,
    conn: &Arc<Conn>,
    m: &str,
    params: &Value,
) -> Result<Value, RpcError> {
    let flag = |k: &str| params.get(k).and_then(Value::as_bool).unwrap_or(false);
    match m {
        method::MUX_FORUM_ANNOUNCE => {
            let author = if conn.is_person() {
                Author::Person { account: account(params)? }
            } else if let Some(caller) = conn.caller() {
                let session = hub.resolve(caller)?;
                hub.forum_agent(&session)
            } else {
                return Err(author_required());
            };
            let text = |k: &str| str_param(params, k).unwrap_or_default().to_owned();
            let req = AnnounceRequest {
                key: text("key"),
                body: text("body"),
                topic: str_param(params, "topic").map(str::to_owned),
                urgent: flag("urgent"),
                retire: flag("retire"),
            };
            hub.forum_announce(author, req).await
        }
        method::MUX_FORUM_RULES => Ok(hub.forum_rules()),
        method::MUX_FORUM_ACK => {
            let caller = conn.caller().ok_or_else(|| {
                RpcError::invalid_params(
                    "an ack comes from the agent session that read the post (its caller token)",
                )
                .with_data(json!({"reason": "forum.caller_required"}))
            })?;
            let session = hub.resolve(caller)?;
            let post_id = str_param(params, "postId")
                .ok_or_else(|| RpcError::invalid_params("postId is required"))?;
            hub.forum_ack(&session, post_id)
        }
        method::MUX_FORUM_DIGEST | method::MUX_FORUM_DIGEST_ACT => {
            let caller = conn.caller().ok_or_else(|| {
                RpcError::invalid_params(
                    "a digest is read from an agent session (its caller token), for the person it works for",
                )
                .with_data(json!({"reason": "forum.caller_required"}))
            })?;
            let session = hub.resolve(caller)?;
            let text = |k: &str| str_param(params, k).unwrap_or_default().to_owned();
            // The person is this Mac's user, never a request field.
            let person = account(&json!({}))?;
            if m == method::MUX_FORUM_DIGEST {
                let areas = match params.get("areas") {
                    None | Some(Value::Null) => Vec::new(),
                    Some(Value::Array(a)) => a
                        .iter()
                        .map(|l| l.as_str().map(str::to_owned))
                        .collect::<Option<Vec<_>>>()
                        .ok_or_else(|| RpcError::invalid_params("areas must be strings"))?,
                    Some(_) => return Err(RpcError::invalid_params("areas must be a list")),
                };
                let req = DigestRequest {
                    space: text("space"),
                    ack: flag("ack"),
                    since: params.get("since").and_then(Value::as_u64).unwrap_or(0),
                    areas,
                    budget: params.get("budget").and_then(Value::as_u64).map(|b| b as usize),
                    person,
                };
                hub.forum_digest(&session, req).await
            } else {
                let req = DigestActRequest {
                    space: text("space"),
                    item: text("item"),
                    action: text("action"),
                    person,
                };
                hub.forum_digest_act(&session, req).await
            }
        }
        method::MUX_FORUM_POST | method::MUX_FORUM_REPLY | method::MUX_FORUM_SEARCH => {
            let caller = conn.caller().ok_or_else(|| {
                RpcError::invalid_params(
                    "the hosted forum is reached from an agent session (its caller token)",
                )
                .with_data(json!({"reason": "forum.caller_required"}))
            })?;
            let session = hub.resolve(caller)?;
            let text = |k: &str| str_param(params, k).unwrap_or_default().to_owned();
            match m {
                method::MUX_FORUM_POST => {
                    let labels = match params.get("labels") {
                        None | Some(Value::Null) => Vec::new(),
                        Some(Value::Array(a)) => a
                            .iter()
                            .map(|l| l.as_str().map(str::to_owned))
                            .collect::<Option<Vec<_>>>()
                            .ok_or_else(|| RpcError::invalid_params("labels must be strings"))?,
                        Some(_) => {
                            return Err(RpcError::invalid_params("labels must be a list"));
                        }
                    };
                    let req = PostRequest {
                        space: text("space"),
                        title: text("title"),
                        body: text("body"),
                        kind: str_param(params, "kind").map(str::to_owned),
                        labels,
                    };
                    hub.forum_post(&session, req).await
                }
                method::MUX_FORUM_REPLY => {
                    let thread = params
                        .get("thread")
                        .and_then(Value::as_u64)
                        .filter(|n| *n > 0)
                        .ok_or_else(|| {
                            RpcError::invalid_params("thread must be a thread number")
                        })?;
                    hub.forum_reply(&session, thread, &text("body")).await
                }
                _ => hub.forum_search(&session, &text("query"), str_param(params, "space")).await,
            }
        }
        other => Err(RpcError::method_not_found(other)),
    }
}
