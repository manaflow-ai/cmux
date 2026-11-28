//! `_acpmux/asks/search {q?, status?, limit?}`, `_acpmux/asks/get {id}` and
//! `_acpmux/asks/link {id, kind, to? | repo?, number? | reason?}` (RFD 0010 piece 5): the
//! person's asks, from the default-off ask ledger (`hub/ask_ledger`), for the `asks_*` MCP tools.
//!
//! Like `_acpmux/ask_ledger`, served only on this machine (the local socket and the app's
//! pane): the asks are the person's words, so a remote WebSocket device and a peer are refused.
//! A link is recorded as the chat the connection proved it runs in, else as the person.

use super::{Conn, str_param};
use crate::conn_origin::Origin;
use crate::hub::Hub;
use crate::hub::ask_ledger::{Kind, query};
use crate::rpc::{RpcError, method};
use serde_json::{Value, json};
use std::sync::Arc;

/// The reply to an asks method, or None for any other method.
pub(super) fn dispatch(
    hub: &Arc<Hub>,
    conn: &Arc<Conn>,
    m: &str,
    params: &Value,
) -> Option<Result<Value, RpcError>> {
    if !matches!(m, method::MUX_ASKS_SEARCH | method::MUX_ASKS_GET | method::MUX_ASKS_LINK) {
        return None;
    }
    if !matches!(conn.origin, Origin::Local | Origin::LocalApp) {
        return Some(Err(RpcError::method_not_found(&format!(
            "{m} (served only on this machine)"
        ))));
    }
    let by = conn.caller().map(str::to_owned).unwrap_or_else(crate::hub::ask_ledger::person);
    Some(handle(hub, m, params, &by))
}

pub(super) fn handle(hub: &Hub, m: &str, params: &Value, by: &str) -> Result<Value, RpcError> {
    let ledger = &hub.ask_ledger;
    match m {
        method::MUX_ASKS_SEARCH => {
            let status = str_param(params, "status");
            if let Some(s) = status
                && !query::STATUSES.contains(&s)
            {
                return Err(RpcError::invalid_params(&format!(
                    "status must be one of {}",
                    query::STATUSES.join(", ")
                )));
            }
            let limit = params.get("limit").and_then(Value::as_u64).map(|n| n as usize);
            Ok(ledger.search(str_param(params, "q").unwrap_or_default(), status, limit))
        }
        method::MUX_ASKS_GET => {
            let id = id(params)?;
            ledger.get(id).ok_or_else(|| {
                RpcError::invalid_params(&format!("no ask {id} in this machine's ledger"))
            })
        }
        _ => {
            let id = id(params)?;
            let mut event = params.clone();
            if let Some(fields) = event.as_object_mut() {
                fields.remove("id");
            }
            let kind: Kind = serde_json::from_value(event).map_err(|e| {
                RpcError::invalid_params(&format!(
                    "kind must be routed {{to}}, picked, prOpened {{repo, number}}, prMerged {{repo, number}}, answered, reopened or dropped {{reason}}: {e}"
                ))
            })?;
            let ask = ledger.link(id, by, kind).map_err(|e| RpcError::invalid_params(&e))?;
            Ok(json!({"ask": ask}))
        }
    }
}

fn id(params: &Value) -> Result<&str, RpcError> {
    str_param(params, "id")
        .filter(|s| !s.trim().is_empty())
        .ok_or_else(|| RpcError::invalid_params("id is required"))
}

#[cfg(test)]
#[path = "asks_tests.rs"]
mod tests;
