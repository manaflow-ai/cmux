//! `_acpmux/stats` (hq#1920): personal stats over every session log
//! (`crate::stats`). How a person works is their data (C5), like the chat
//! index: only the local unix socket gets it, and every WebSocket origin
//! (Web, LocalApp, Peer) gets "Method not found". Never forwarded to a peer.

use std::sync::Arc;

use serde_json::Value;

use super::super::Origin;
use crate::hub::Hub;
use crate::rpc::{RpcError, method};
use crate::stats::StatsOptions;

pub(super) async fn handle(
    hub: &Arc<Hub>,
    origin: Origin,
    params: &Value,
) -> Result<Value, RpcError> {
    if origin != Origin::Local {
        return Err(RpcError::method_not_found(method::MUX_STATS));
    }
    let options = StatsOptions::from_params(params, crate::store::now_ms());
    let hub = Arc::clone(hub);
    // One pass over every log in the range reads files: off the runtime.
    let summary = tokio::task::spawn_blocking(move || hub.stats(&options))
        .await
        .map_err(|e| RpcError::internal(e.to_string()))?
        .map_err(|e| RpcError::internal(format!("stats: {e}")))?;
    serde_json::to_value(summary).map_err(|e| RpcError::internal(e.to_string()))
}
