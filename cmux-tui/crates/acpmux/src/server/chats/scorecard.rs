//! `_acpmux/scorecard`: the harness-magic scorecard over every session log
//! (`crate::scorecard`). How a person's agents work is their data, like
//! `_acpmux/stats`: only the local unix socket gets it, and every WebSocket
//! origin gets "Method not found". Never forwarded to a peer: the fleet tool
//! asks each host's own CLI.

use std::sync::Arc;

use serde_json::Value;

use super::super::Origin;
use crate::hub::Hub;
use crate::rpc::{RpcError, method};
use crate::scorecard::ScorecardOptions;

pub(super) async fn handle(
    hub: &Arc<Hub>,
    origin: Origin,
    params: &Value,
) -> Result<Value, RpcError> {
    if origin != Origin::Local {
        return Err(RpcError::method_not_found(method::MUX_SCORECARD));
    }
    let options = ScorecardOptions::from_params(params, crate::store::now_ms());
    let hub = Arc::clone(hub);
    // One pass over every log in the range reads files: off the runtime.
    let card = tokio::task::spawn_blocking(move || hub.scorecard(&options))
        .await
        .map_err(|e| RpcError::internal(e.to_string()))?
        .map_err(|e| RpcError::internal(format!("scorecard: {e}")))?;
    Ok(crate::scorecard::to_value(&card))
}
