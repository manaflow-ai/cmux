//! `_acpmux/agent_home {sessionId}` and `_acpmux/agent_home_resolve {sessionId, accept, drop}`:
//! Session Info's carried agent memory (`crate::agent_home`). Anyone who may read the chat reads
//! the listing; only the person accepts or drops: a chat's own agent, another agent, a peer and a
//! remote WebSocket device are refused, as `memory_resolve` refuses them.

use super::Conn;
use crate::agent_home::{Head, head_dir};
use crate::rpc::{RpcError, method};
use serde_json::{Value, json};
use std::sync::Arc;

/// The reply to `agent_home` or `agent_home_resolve`, or None for any other method.
pub(super) async fn dispatch(
    conn: &Arc<Conn>,
    m: &str,
    params: &Value,
) -> Option<Result<Value, RpcError>> {
    match m {
        method::MUX_AGENT_HOME => Some(listing(head_dir()).await),
        method::MUX_AGENT_HOME_RESOLVE => {
            if conn.origin.web_class() || !conn.is_person() {
                return Some(Err(RpcError::invalid_params(
                    "only the person accepts or drops a change to their carried memory",
                )));
            }
            Some(resolve(head_dir(), params).await)
        }
        _ => None,
    }
}

async fn listing(dir: Option<std::path::PathBuf>) -> Result<Value, RpcError> {
    let Some(dir) = dir else {
        return Ok(json!({
            "configured": false, "generation": 0, "revision": null, "carried": [], "proposals": [],
        }));
    };
    tokio::task::spawn_blocking(move || Head::at(dir).listing())
        .await
        .map_err(|error| RpcError::internal(error.to_string()))?
        .map_err(|error| RpcError::internal(format!("reading carried memory: {error}")))
}

async fn resolve(dir: Option<std::path::PathBuf>, params: &Value) -> Result<Value, RpcError> {
    let accept = ids(params, "accept")?;
    let drop = ids(params, "drop")?;
    if accept.is_empty() && drop.is_empty() {
        return Err(RpcError::invalid_params("accept or drop at least one proposal"));
    }
    let dir = dir.ok_or_else(|| RpcError::invalid_params("carried memory is not set up here"))?;
    tokio::task::spawn_blocking(move || Head::at(dir).resolve(&accept, &drop))
        .await
        .map_err(|error| RpcError::internal(error.to_string()))?
        .map_err(|error| RpcError::internal(format!("writing carried memory: {error}")))
}

/// A list of proposal ids; at most 256 in one batch.
fn ids(params: &Value, key: &str) -> Result<Vec<String>, RpcError> {
    let list = match params.get(key) {
        None | Some(Value::Null) => return Ok(Vec::new()),
        Some(Value::Array(list)) if list.len() <= 256 => list,
        Some(_) => {
            return Err(RpcError::invalid_params(format!("{key} is a list of proposal ids")));
        }
    };
    list.iter()
        .map(|v| {
            v.as_str()
                .map(str::to_owned)
                .ok_or_else(|| RpcError::invalid_params(format!("{key} holds proposal ids")))
        })
        .collect()
}
