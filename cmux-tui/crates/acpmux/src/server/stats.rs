//! `_acpmux/stats` (hq#1920): personal stats over every session log
//! (`crate::stats`). Local only: the unix socket and the app's own pane
//! connection; a remote WebSocket or a peer gets "Method not found", like
//! `_acpmux/directories`.

use std::sync::Arc;

use serde_json::Value;

use super::Origin;
use crate::hub::Hub;
use crate::rpc::{RpcError, method};
use crate::stats::StatsOptions;

pub(super) async fn handle(
    hub: &Arc<Hub>,
    origin: Origin,
    params: &Value,
) -> Result<Value, RpcError> {
    if !matches!(origin, Origin::Local | Origin::LocalApp) {
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
