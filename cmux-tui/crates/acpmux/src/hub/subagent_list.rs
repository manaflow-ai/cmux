//! A chat's subagents for the Background tasks panel (`_acpmux/subagents`): every running one and
//! the latest ended ones, from the subagent tree the hub's tap keeps for the chat
//! (`subagents_listed.rs`). Nothing is read from disk; the tree's lock is held only to copy the
//! list. Leo, 2026-11-24, on a coordinator's panel that said "Nothing runs in the background"
//! while its helpers ran: "this bugged? or had an ultra slow load".

use super::Hub;
use crate::rpc::RpcError;
use crate::subagents::listed::{LISTED_ENDED_DEFAULT, LISTED_ENDED_MAX};
use serde_json::Value;

/// `{sessionId, ended?}` → `{running, ended, endedOmitted, seen}`.
pub(crate) fn handle(hub: &std::sync::Arc<Hub>, params: &Value) -> Result<Value, RpcError> {
    let session = hub.resolve(crate::server::session_key(params)?)?;
    if session.purged.load(std::sync::atomic::Ordering::SeqCst) {
        return Err(RpcError::invalid_params("no such chat"));
    }
    let ended = params
        .get("ended")
        .and_then(Value::as_u64)
        .map_or(LISTED_ENDED_DEFAULT, |n| (n as usize).min(LISTED_ENDED_MAX));
    let turn_runs = session.turn().is_some();
    let listing = {
        let tree = session.subagents.lock().unwrap_or_else(|e| e.into_inner());
        tree.listing(turn_runs, ended)
    };
    serde_json::to_value(listing).map_err(|e| RpcError::internal(e.to_string()))
}
