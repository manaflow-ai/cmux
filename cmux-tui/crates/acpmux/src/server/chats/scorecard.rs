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
    switched_off().await?;
    let options = ScorecardOptions::from_params(params, crate::store::now_ms());
    let hub = Arc::clone(hub);
    // One pass over every log in the range reads files: off the runtime.
    let card = tokio::task::spawn_blocking(move || hub.scorecard(&options))
        .await
        .map_err(|e| RpcError::internal(e.to_string()))?
        .map_err(|e| RpcError::internal(format!("scorecard: {e}")))?;
    Ok(crate::scorecard::to_value(&card))
}

/// The scorecard's off switch (RFD 0161): `agents.harnessMagic.scorecard.enabled: false` or
/// `ACPMUX_HM_SCORECARD=0`, read at each call; on by default.
async fn switched_off() -> Result<(), RpcError> {
    let on = tokio::task::spawn_blocking(|| crate::hub::harness_magic::enabled("scorecard"))
        .await
        .unwrap_or(true);
    if on {
        return Ok(());
    }
    Err(RpcError::invalid_params(
        "the scorecard is off (agents.harnessMagic.scorecard.enabled is false or ACPMUX_HM_SCORECARD=0); \
         turn it back on by removing that setting or the variable",
    ))
}

/// `_acpmux/scorecard_replay {sessions: [id, prefix or name, ...]}`: RFD 0161's replay of
/// recorded logs against its invariants (`crate::scorecard_replay`), every session when the
/// list is empty. Local only, like the scorecard.
pub(super) async fn replay(
    hub: &Arc<Hub>,
    origin: Origin,
    params: &Value,
) -> Result<Value, RpcError> {
    if origin != Origin::Local {
        return Err(RpcError::method_not_found(method::MUX_SCORECARD_REPLAY));
    }
    switched_off().await?;
    let sessions: Vec<String> = params["sessions"]
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(|s| s.as_str().map(str::to_owned))
        .collect();
    let hub = Arc::clone(hub);
    let answer = tokio::task::spawn_blocking(move || hub.scorecard_replay(&sessions))
        .await
        .map_err(|e| RpcError::internal(e.to_string()))?
        .map_err(|e| RpcError::internal(format!("scorecard replay: {e}")))?;
    Ok(crate::scorecard_replay::to_value(&answer))
}
