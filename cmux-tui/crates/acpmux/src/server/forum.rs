//! The forum methods (`hub/forum.rs`), routed before peer forwarding
//! (`chats.rs`): the log lives on this daemon.
//!
//! - `_acpmux/forum/announce {key, body, topic?, urgent?, retire?, account?}`:
//!   the person (the proven app; `account` names them, else the OS user) or an
//!   agent session proven by its caller token. A request field never names an
//!   agent author.
//! - `_acpmux/forum/rules`: the current rules, with deliveries and acks.
//! - `_acpmux/forum/ack {postId}`: the calling session has read the post.
//!
//! Web and peer connections are refused: rules are for this Mac's sessions.

use super::{Conn, str_param};
use crate::forum::{Author, MAX_KEY_BYTES};
use crate::hub::Hub;
use crate::hub::forum::AnnounceRequest;
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
        other => Err(RpcError::method_not_found(other)),
    }
}
